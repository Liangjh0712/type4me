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
        /// Which pipe is carrying the session.
        var transport: Kind?

        enum Kind: String, Sendable {
            case usb
            case bluetooth
        }
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
        /// The record key went down; start a recording. `isNote` means the device's
        /// OK key was used, so the text should be kept rather than typed.
        case recordingRequested(isNote: Bool)
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
    /// Last open failure, so discovery retries do not repeat one message forever.
    private var lastOpenFailure: String?
    /// A BLE transport is scanning, so discovery should not start a second one.
    private var isBluetoothScanning = false
    /// Whether this link has announced itself connected.
    private var didReportConnected = false

    /// Per-session recording state.
    private var sessionActive = false
    /// Guards the `agent.status` obligation: whichever exit path runs first wins.
    private var didFinishSession = true
    private var hostAudioFrames = 0
    /// Backstop for the `agent.status` obligation. The explicit call sites cover
    /// the paths we know about; this covers the ones added later. Fires well inside
    /// the device's own 30-second timeout so the user never sees the freeze.
    private var finishTimeoutTask: Task<Void, Never>?
    private static let finishTimeout = Duration.seconds(20)

    private init() {}

    /// Watch for the device appearing, so plugging in after launch connects and a
    /// port that was busy at startup is retried.
    ///
    /// Polling rather than `IOServiceAddMatchingNotification`: the check is a
    /// registry query costing microseconds, and it also recovers from the
    /// port-busy case, where the device never re-enumerates and so no matching
    /// notification would ever fire.
    private var discoveryTask: Task<Void, Never>?
    private static let discoveryInterval = Duration.seconds(3)

    func startDiscovery() {
        guard discoveryTask == nil else { return }
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.connectIfDevicePresent()
                try? await Task.sleep(for: Self.discoveryInterval)
            }
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
    }

    /// One discovery tick: attach if nothing is attached.
    ///
    /// Deliberately does not pre-check for a serial port — that would make the
    /// wireless path unreachable, since a BLE device is only discoverable by
    /// scanning. `connect()` picks the pipe.
    private func connectIfDevicePresent() async {
        guard transport == nil else { return }
        await connect()
    }

    // MARK: - Connect / disconnect

    /// Attach to a device, preferring the wired link when one is plugged in.
    ///
    /// USB wins because it is strictly better when available — uncompressed audio,
    /// a console for diagnostics, and no radio contention — but BLE is the everyday
    /// case, so it is tried whenever no cable is present.
    func connect() async {
        guard transport == nil else { return }

        if let port = PassportSerialDiscovery.preferredPort() {
            // The wired transport is up as soon as `open()` returns.
            await attach(PassportUSBTransport(port: port), describing: port.path, isReady: true)
        } else if bluetoothEnabled, !isBluetoothScanning {
            // BLE only starts scanning here; readiness arrives with the first frame.
            isBluetoothScanning = true
            await attach(
                PassportBLETransport(), describing: PassportBLETransport.advertisedName, isReady: false)
        }
    }

    /// Whether to look for the device over the air. Wired-only is useful while
    /// debugging, and turning the radio off avoids a pairing prompt for anyone who
    /// does not own the hardware.
    private var bluetoothEnabled: Bool {
        PassportLinkPreferences.isBluetoothEnabled
    }

    /// Open a transport and adopt it.
    ///
    /// `isReady` distinguishes the two pipes: a wired port is live the moment it
    /// opens, whereas `open()` on BLE only starts scanning — the device may be out of
    /// range or off. So a BLE transport is held without claiming to be connected, and
    /// the first inbound frame promotes it (`markReadyIfNeeded`). Reporting connected
    /// too early would show "connected" for a card sitting in a drawer.
    private func attach(
        _ candidate: any PassportTransport, describing name: String, isReady: Bool
    ) async {
        linkGeneration += 1
        let generation = linkGeneration

        candidate.onFrame = { [weak self] frame in
            Task { await self?.handle(frame, generation: generation) }
        }
        candidate.onReady = { [weak self] in
            Task { await self?.handleReady(generation: generation) }
        }
        candidate.onDisconnect = { [weak self] in
            Task { await self?.handleDisconnect(generation: generation) }
        }

        do {
            try candidate.open()
        } catch {
            // Discovery retries every few seconds, so only log a change of reason —
            // otherwise a device left plugged into a busy port fills the log.
            let description = error.localizedDescription
            if description != lastOpenFailure {
                lastOpenFailure = description
                logger.warning("open failed: \(description, privacy: .public)")
                DebugFileLogger.log("passport link open failed error=\(description)")
            }
            isBluetoothScanning = false
            return
        }
        lastOpenFailure = nil

        transport = candidate
        intentionalDisconnect = false
        didReportConnected = false

        if isReady {
            reportConnected(name: name, candidate: candidate)
        } else {
            DebugFileLogger.log("passport link scanning transport=ble")
        }
    }

    /// Announce the link as usable and prime the device.
    private func reportConnected(name: String, candidate: any PassportTransport) {
        guard !didReportConnected else { return }
        didReportConnected = true

        publish { state in
            state.isConnected = true
            state.deviceName = candidate.displayName
            state.transport = candidate is PassportBLETransport ? .bluetooth : .usb
        }

        // The device has no clock of its own, so its logs and screen start at the
        // epoch until we tell it the time.
        candidate.send(.control, text: PassportProtocol.timeSet(epoch: Int(Date().timeIntervalSince1970)))
        candidate.send(.control, text: PassportProtocol.agentStatus(.ready))

        logger.info("connected \(name, privacy: .public)")
        DebugFileLogger.log("passport link connected device=\(name)")
        eventContinuation?.yield(.connected(deviceName: candidate.displayName))
    }

    /// A frame arrived, so whatever transport delivered it is genuinely live.
    private func markReadyIfNeeded() {
        guard !didReportConnected, let transport else { return }
        reportConnected(name: transport.displayName, candidate: transport)
    }

    /// The transport reported itself usable — BLE finished scanning, connecting and
    /// subscribing.
    private func handleReady(generation: Int) {
        guard generation == linkGeneration else { return }
        isBluetoothScanning = false
        markReadyIfNeeded()
    }

    /// Detach deliberately. Suppresses reconnection.
    func disconnect() {
        intentionalDisconnect = true
        transport?.close()
        transport = nil
        isBluetoothScanning = false
        didReportConnected = false
        publish { state in
            state.isConnected = false
            state.deviceName = nil
            state.isStreaming = false
            state.transport = nil
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
        isBluetoothScanning = false
        didReportConnected = false
        publish { state in
            state.isConnected = false
            state.deviceName = nil
            state.isStreaming = false
            state.transport = nil
        }
        logger.info("disconnected intentional=\(self.intentionalDisconnect)")
        DebugFileLogger.log("passport link disconnected intentional=\(intentionalDisconnect)")
        eventContinuation?.yield(.disconnected)

        // Reconnection is discovery's job: it already polls for the port and covers
        // both unplugging and a port that was busy. A second retry loop here would
        // race it for the exclusive open.
    }

    // MARK: - Inbound frames

    private func handle(_ frame: PassportFrame.Message, generation: Int) {
        guard generation == linkGeneration else { return }
        // Any frame proves the transport is live, which is how a scanning BLE link
        // learns it actually found the device.
        markReadyIfNeeded()

        switch frame.kind {
        case .audio:
            guard sessionActive else { return }
            hostAudioFrames += 1
            // Already 16 kHz mono Int16: the wired transport receives PCM outright,
            // and the wireless one reassembles and decodes ADPCM before publishing.
            // Decoding again here would treat PCM as ADPCM and destroy the audio.
            audioSink?(frame.payload)

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

    private func handle(_ event: PassportProtocol.Event) {
        switch event {
        case .hello(let proto):
            logger.info("device hello proto=\(proto)")
            DebugFileLogger.log("passport link hello proto=\(proto)")

        case .voiceStart(let encoding, let isNote):
            sessionActive = true
            didFinishSession = false
            hostAudioFrames = 0
            transport?.beginSession()
            publish { $0.isStreaming = true }
            DebugFileLogger.log(
                "passport link voice.start encoding=\(encoding.rawValue) note=\(isNote)")
            eventContinuation?.yield(.recordingRequested(isNote: isNote))

        case .voiceEnd:
            sessionActive = false
            publish { $0.isStreaming = false }
            DebugFileLogger.log("passport link voice.end hostFrames=\(hostAudioFrames)")
            armFinishTimeout()
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
    /// "it froze after I finished speaking". `armFinishTimeout` is the backstop for
    /// a path nobody remembered to cover.
    func finishSession(state: PassportProtocol.AgentState = .done, reason: String? = nil) {
        guard !didFinishSession else { return }
        didFinishSession = true
        sessionActive = false
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil
        publish { $0.isStreaming = false }

        transport?.send(.control, text: PassportProtocol.agentStatus(state, message: reason ?? ""))
        DebugFileLogger.log("passport link session finished state=\(state.rawValue) reason=\(reason ?? "-")")
    }

    /// Start the watchdog that reports the session over if nothing else does.
    ///
    /// Relying on every call site to remember is how the reference client shipped a
    /// frozen device: two failure paths returned without sending anything. Rather
    /// than trust an exhaustive list of exits, assume one will be missed.
    private func armFinishTimeout() {
        finishTimeoutTask?.cancel()
        finishTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.finishTimeout)
            guard !Task.isCancelled, let self else { return }
            await self.finishByTimeout()
        }
    }

    private func finishByTimeout() {
        guard !didFinishSession else { return }
        logger.warning("no terminal status sent within \(Self.finishTimeout); reporting done")
        DebugFileLogger.log("passport link finish timeout — host never reported session end")
        finishSession(state: .done, reason: "timeout")
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
