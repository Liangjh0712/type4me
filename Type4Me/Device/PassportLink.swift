import Foundation
import os

/// Owns the connection to an AI Passport device and translates its protocol into
/// app-level events.
///
/// Transport-agnostic: it sees decoded frames, not bytes, so USB and BLE differ
/// only in which `PassportTransport` is attached. Audio is republished as 16 kHz
/// mono Int16 chunks for `PassportAudioSource` to hand to the recognition session.
///
/// The one hard obligation is `agent.status`. After `voice.end` the device sits in
/// TRANSCRIBING and leaves **only** when a terminal status arrives; miss it and the
/// device is stuck for its full 30-second timeout and cannot start another session.
/// `done` means "the session is over", not "recognition succeeded" — so it must be
/// sent on failure paths too, which is why `finishSession` is the single exit and
/// is idempotent.
actor PassportLink {

    static let shared = PassportLink()

    // MARK: - Cross-actor readable state

    /// Whether a device is attached. Read from the main actor and background
    /// callbacks, so it lives behind a lock rather than actor isolation.
    private static let stateBox = OSAllocatedUnfairLock(initialState: LinkSnapshot())

    struct LinkSnapshot: Sendable, Equatable {
        var isConnected = false
        var deviceName: String?
        var isStreaming = false
        /// Frames the device reported dropping in the last session.
        var lastDeviceDrop = 0
    }

    static var snapshot: LinkSnapshot { stateBox.withLock { $0 } }
    static var isConnected: Bool { stateBox.withLock { $0.isConnected } }

    /// Posted on the main queue whenever `snapshot` changes.
    static let stateDidChange = Notification.Name("com.type4me.passportLinkStateDidChange")

    // MARK: - Event output

    /// What the app needs to act on. Consumed by one long-lived task on the main
    /// actor, mirroring how `RecognitionSession` publishes its ASR events.
    enum Event: Sendable {
        case connected(deviceName: String)
        case disconnected
        /// The record key went down; start a recording.
        case recordingRequested
        /// The record key came up; stop and process.
        case recordingFinished
        /// Submit the current input field.
        case submitRequested
        /// Clear the current input field.
        case clearRequested
    }

    private var eventContinuation: AsyncStream<Event>.Continuation?

    /// The app-level event stream. Call once during launch.
    func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        eventContinuation = continuation
        return stream
    }

    // MARK: - Audio output

    /// Set by `PassportAudioSource`; receives decoded 3200-byte PCM chunks.
    private var audioSink: ((Data) -> Void)?

    func setAudioSink(_ sink: ((Data) -> Void)?) {
        audioSink = sink
    }

    // MARK: - Private state

    private let logger = Logger(subsystem: "com.type4me.device", category: "PassportLink")

    private var transport: (any PassportTransport)?
    /// Bumped per connection so a callback from a replaced transport is ignored —
    /// unplugging and replugging otherwise lets a stale reader drive live state.
    private var linkGeneration = 0
    private var intentionalDisconnect = false
    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 3

    /// Per-session recording state.
    private var sessionEncoding: PassportAudioEncoding = .pcm
    private var sessionActive = false
    /// Guards the `agent.status` obligation: whichever exit path runs first wins.
    private var didFinishSession = true
    private var hostAudioFrames = 0

    private init() {}

    // MARK: - Connect / disconnect

    /// Attach to a device if one is present. Safe to call when already connected.
    func connect() async {
        guard transport == nil else { return }

        guard let port = PassportSerialDiscovery.preferredPort() else {
            logger.debug("no device present")
            return
        }

        let usb = PassportUSBTransport(port: port)
        linkGeneration += 1
        let generation = linkGeneration

        usb.onFrame = { [weak self] frame in
            Task { await self?.handle(frame, generation: generation) }
        }
        usb.onDisconnect = { [weak self] in
            Task { await self?.handleDisconnect(generation: generation) }
        }

        do {
            try usb.open()
        } catch {
            logger.warning("open failed: \(error.localizedDescription, privacy: .public)")
            DebugFileLogger.log("passport link open failed error=\(error.localizedDescription)")
            return
        }

        transport = usb
        intentionalDisconnect = false
        reconnectAttempts = 0
        publish { state in
            state.isConnected = true
            state.deviceName = usb.displayName
        }

        // The device has no clock of its own, so its logs and screen start at the
        // epoch until we tell it the time.
        usb.send(.control, text: PassportProtocol.timeSet(epoch: Int(Date().timeIntervalSince1970)))
        usb.send(.control, text: PassportProtocol.agentStatus(.ready))

        logger.info("connected \(usb.displayName, privacy: .public)")
        DebugFileLogger.log("passport link connected device=\(usb.displayName)")
        eventContinuation?.yield(.connected(deviceName: usb.displayName))
    }

    /// Detach deliberately. Suppresses reconnection.
    func disconnect() {
        intentionalDisconnect = true
        transport?.close()
        transport = nil
        publish { state in
            state.isConnected = false
            state.deviceName = nil
            state.isStreaming = false
        }
    }

    /// Synchronous teardown for `applicationWillTerminate`, which returns straight
    /// into `exit()` — anything left in a `Task` never runs.
    nonisolated static func closeAllLinksSynchronously() {
        stateBox.withLock { state in
            state.isConnected = false
            state.isStreaming = false
        }
        // The port is released by the OS on exit; this only stops us from reporting
        // a live link to a UI that is already going away.
    }

    private func handleDisconnect(generation: Int) async {
        guard generation == linkGeneration else { return }

        // A device that vanishes mid-recording must not leave the session hanging.
        if sessionActive {
            finishSession(state: .error, reason: "link lost")
            eventContinuation?.yield(.recordingFinished)
        }

        transport = nil
        publish { state in
            state.isConnected = false
            state.deviceName = nil
            state.isStreaming = false
        }
        logger.info("disconnected intentional=\(self.intentionalDisconnect)")
        DebugFileLogger.log("passport link disconnected intentional=\(intentionalDisconnect)")
        eventContinuation?.yield(.disconnected)

        guard !intentionalDisconnect, reconnectAttempts < Self.maxReconnectAttempts else { return }
        reconnectAttempts += 1
        let attempt = reconnectAttempts
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            DebugFileLogger.log("passport link reconnect attempt=\(attempt)")
            await self.connect()
        }
    }

    // MARK: - Inbound frames

    private func handle(_ frame: PassportFrame.Message, generation: Int) {
        guard generation == linkGeneration else { return }

        switch frame.kind {
        case .audio:
            guard sessionActive else { return }
            hostAudioFrames += 1
            audioSink?(decodeAudio(frame.payload))

        case .event:
            guard let line = String(data: frame.payload, encoding: .utf8),
                  let event = PassportProtocol.parseEvent(line)
            else { return }
            handle(event)

        case .sysResponse:
            let text = String(data: frame.payload, encoding: .utf8) ?? ""
            DebugFileLogger.log("passport link sysresp bytes=\(frame.payload.count)")
            logger.debug("console: \(text, privacy: .public)")

        case .control, .sys:
            // Outbound-only; the decoder already rejects these.
            break
        }
    }

    private func decodeAudio(_ payload: Data) -> Data {
        switch sessionEncoding {
        case .pcm:
            // Already one recognition chunk: 3200 bytes of 16 kHz mono Int16.
            return payload
        case .imaADPCM:
            // BLE only; wired sessions never take this path.
            return PassportADPCM.decodeBlock(payload) ?? Data()
        }
    }

    private func handle(_ event: PassportProtocol.Event) {
        switch event {
        case .hello(let proto):
            logger.info("device hello proto=\(proto)")
            DebugFileLogger.log("passport link hello proto=\(proto)")

        case .voiceStart(let encoding):
            sessionEncoding = encoding
            sessionActive = true
            didFinishSession = false
            hostAudioFrames = 0
            publish { $0.isStreaming = true }
            DebugFileLogger.log("passport link voice.start encoding=\(encoding.rawValue)")
            eventContinuation?.yield(.recordingRequested)

        case .voiceEnd:
            sessionActive = false
            publish { $0.isStreaming = false }
            DebugFileLogger.log("passport link voice.end hostFrames=\(hostAudioFrames)")
            eventContinuation?.yield(.recordingFinished)

        case .status(let drop):
            // Two independent counters: what the device dropped at the source, and
            // what we received. A mismatch means loss we would otherwise not see.
            publish { $0.lastDeviceDrop = drop }
            if drop > 0 {
                logger.warning("device dropped \(drop) frames (received \(self.hostAudioFrames))")
            }
            DebugFileLogger.log("passport link status deviceDrop=\(drop) hostFrames=\(hostAudioFrames)")

        case .keyAction(.enter):
            eventContinuation?.yield(.submitRequested)

        case .keyAction(.clear):
            eventContinuation?.yield(.clearRequested)

        case .agentAction(let taskID, let action):
            // The approval screen is not wired up for voice input; acknowledge so
            // the device does not wait on us.
            logger.debug("agent action task=\(taskID, privacy: .public) action=\(action, privacy: .public)")
            finishSession(state: .done)
        }
    }

    // MARK: - Session lifecycle

    /// Push live text to the device screen during recognition.
    func showTranscript(_ text: String, final: Bool) {
        guard let transport, !text.isEmpty else { return }
        for segment in PassportProtocol.splitForDisplay(text) {
            transport.send(.control, text: PassportProtocol.transcript(segment, final: final))
        }
    }

    /// End the device's view of the session. **The one exit that matters.**
    ///
    /// Idempotent per session: the first caller wins, so it is safe to call from
    /// every terminal path — success, ASR failure, cancellation, injection failure,
    /// and the silent-recording fast exit. Skipping any one of them leaves the
    /// device stuck in TRANSCRIBING for 30 seconds, which reads to the user as
    /// "it froze after I finished speaking".
    func finishSession(state: PassportProtocol.AgentState = .done, reason: String? = nil) {
        guard !didFinishSession else { return }
        didFinishSession = true
        sessionActive = false
        publish { $0.isStreaming = false }

        transport?.send(.control, text: PassportProtocol.agentStatus(state, message: reason ?? ""))
        DebugFileLogger.log("passport link session finished state=\(state.rawValue) reason=\(reason ?? "-")")
    }

    // MARK: - State publishing

    private func publish(_ mutate: (inout LinkSnapshot) -> Void) {
        let changed: Bool = Self.stateBox.withLock { state in
            let before = state
            mutate(&state)
            return before != state
        }
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.stateDidChange, object: nil)
        }
    }
}
