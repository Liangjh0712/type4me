import AVFoundation

/// An `AudioSource` fed by an attached AI Passport device instead of a microphone.
///
/// The device already delivers exactly what the pipeline wants — 16 kHz mono Int16
/// in 100 ms pieces — so there is no format conversion here, only the shared
/// journalling and level measurement every source needs.
///
/// One difference from the microphone matters: `start()` cannot fail on a
/// permission check and does not open anything. The link is already up before a
/// recording begins (the device's own key press is what starts it), so `start()`
/// only opens the gate that lets frames through.
final class PassportAudioSource: AudioSource, @unchecked Sendable {

    /// Ignored: the device has one microphone, and it is not selectable from here.
    var selectedDeviceUID: String?

    var onAudioChunk: ((Data) -> Void)? {
        get { sink.onAudioChunk }
        set { sink.onAudioChunk = newValue }
    }

    var onAudioLevel: ((Float) -> Void)? {
        get { sink.onAudioLevel }
        set { sink.onAudioLevel = newValue }
    }

    private let sink = PCMSinkCore()
    private let stateLock = NSLock()
    private var isRunning = false
    private var framesAccepted = 0

    init() {}

    // MARK: - Frame intake

    /// Feed one decoded frame from the link. Frames arriving outside a recording
    /// are dropped: the device can send a tail after we have already stopped, and
    /// letting it into the next session would prepend the previous one's audio.
    func accept(_ pcm: Data) {
        let running = stateLock.withLock { isRunning }
        guard running, !pcm.isEmpty else { return }

        stateLock.withLock { framesAccepted += 1 }

        // The level gate is what decides whether the session survives
        // `stopRecording()`, so it has to be driven from the same bytes.
        sink.onAudioLevel?(PCMSinkCore.level(fromInt16: pcm))
        sink.append(pcm)
    }

    // MARK: - AudioSource

    /// Nothing to pre-warm: there is no capture graph and no permission prompt.
    func warmUp() {}

    func start() throws {
        sink.reset()
        stateLock.withLock {
            isRunning = true
            framesAccepted = 0
        }
        DebugFileLogger.log("passport audio source started")
    }

    func stop() {
        let frames: Int = stateLock.withLock {
            isRunning = false
            return framesAccepted
        }
        sink.flushRemaining()
        sink.clearCallbacks()
        DebugFileLogger.log("passport audio source stopped frames=\(frames)")
    }

    func getRecordedAudio() -> Data {
        sink.getRecordedAudio()
    }

    // MARK: - Audio journal

    func prepareAudioJournal(metadata: AudioJournalMetadata) throws {
        try sink.prepareAudioJournal(metadata: metadata)
    }

    func updateAudioJournalPartialTranscript(_ text: String) {
        sink.updateAudioJournalPartialTranscript(text)
    }

    func finalizeAudioJournal() -> ArchivedAudio? {
        sink.finalizeAudioJournal()
    }

    func commitAudioJournal() {
        sink.commitAudioJournal()
    }

    func preserveAudioJournalForRecovery() {
        sink.preserveAudioJournalForRecovery()
    }

    func discardAudioJournal() {
        sink.discardAudioJournal()
    }
}
