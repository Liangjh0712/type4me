import AVFoundation

/// A source of 16 kHz mono Int16 PCM for the recognition pipeline.
///
/// `RecognitionSession` drives recording entirely through this protocol, so the
/// audio can come from the local microphone (`AudioCaptureEngine`) or from an
/// external device streaming frames over USB/BLE. Implementations must deliver
/// `Data` in `AudioCaptureEngine.chunkByteSize` pieces and report a level, or the
/// session's speech-detection gate discards the recording — see `onAudioLevel`.
protocol AudioSource: AnyObject, Sendable {

    // MARK: - Delivery

    /// Called with one 3200-byte chunk (100 ms of 16 kHz mono Int16) per emit.
    /// Invoked on the implementation's own queue, never on the main thread.
    var onAudioChunk: ((Data) -> Void)? { get set }

    /// Called with a normalized 0..1 RMS level, roughly 20 times per second.
    ///
    /// This is **not optional**: the level drives `RecognitionSession`'s
    /// `speechDetected` flag, and `stopRecording()` throws away any session that
    /// never crossed the threshold. A source that stays silent here records fine
    /// and then loses every transcript.
    var onAudioLevel: ((Float) -> Void)? { get set }

    // MARK: - Lifecycle

    /// Prepare expensive resources ahead of the first recording. Cheap to call twice.
    func warmUp()

    /// Begin delivering audio. Resets the accumulated recording.
    func start() throws

    /// Stop delivering audio, flush any partial chunk, and clear both callbacks.
    func stop()

    /// The full PCM recorded since the last `start()`, used by batch fallback and
    /// mid-stream recovery. Must keep accumulating for the whole session.
    func getRecordedAudio() -> Data

    // MARK: - Device selection

    /// Which capture device to use, when the source has a choice.
    /// Set before `start()`; nil or empty means the source picks its default.
    var selectedDeviceUID: String? { get set }

    // MARK: - Audio journal (crash recovery + history)

    func prepareAudioJournal(metadata: AudioJournalMetadata) throws
    func updateAudioJournalPartialTranscript(_ text: String)
    func finalizeAudioJournal() -> ArchivedAudio?
    func commitAudioJournal()
    func preserveAudioJournalForRecovery()
    func discardAudioJournal()
}
