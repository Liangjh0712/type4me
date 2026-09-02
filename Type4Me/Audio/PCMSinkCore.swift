import AVFoundation

/// The audio-source-agnostic tail of the capture pipeline: journal the bytes,
/// accumulate the full recording, cut it into 3200-byte chunks, and measure level.
///
/// Both audio sources share this. `AudioCaptureEngine` feeds it the output of an
/// `AVAudioConverter`; an external device feeds its frames straight in, since they
/// already arrive as 16 kHz mono Int16 in 100 ms pieces. Keeping one copy means
/// crash recovery, history archiving, batch fallback and the speech-detection
/// threshold behave identically no matter where the audio came from.
///
/// Thread-safe: callers may feed from any queue. Callbacks fire synchronously on
/// the feeding queue.
final class PCMSinkCore: @unchecked Sendable {

    /// Emits one `AudioCaptureEngine.chunkByteSize` chunk at a time.
    var onAudioChunk: ((Data) -> Void)?
    /// Emits a normalized 0..1 level.
    var onAudioLevel: ((Float) -> Void)?

    private let bufferLock = NSLock()
    private var buffer = Data()
    private var accumulatedAudio = Data()

    private let journalLock = NSLock()
    private var journalWriter: AudioJournalWriter?

    // MARK: - Feeding

    /// Append 16 kHz mono Int16 PCM. Journals it, accumulates it, and emits every
    /// complete chunk it completes. Any trailing partial chunk waits for more data
    /// or for `flushRemaining()`.
    func append(_ pcm: Data) {
        guard !pcm.isEmpty else { return }

        let journal = journalLock.withLock { journalWriter }
        journal?.append(pcm)

        bufferLock.lock()
        accumulatedAudio.append(pcm)
        buffer.append(pcm)
        let chunks = drainFullChunksLocked()
        bufferLock.unlock()

        for chunk in chunks {
            onAudioChunk?(chunk)
        }
    }

    /// Emit whatever is left, even if it is shorter than a full chunk. Call on stop.
    func flushRemaining() {
        bufferLock.lock()
        let remaining = buffer
        buffer = Data()
        bufferLock.unlock()

        if !remaining.isEmpty {
            onAudioChunk?(remaining)
        }
    }

    /// Drop the buffered and accumulated audio, ready for the next `start()`.
    func reset() {
        bufferLock.lock()
        buffer = Data()
        accumulatedAudio = Data()
        bufferLock.unlock()
    }

    /// Clear both callbacks. Called on stop so a stale closure cannot fire.
    func clearCallbacks() {
        bufferLock.lock()
        onAudioChunk = nil
        onAudioLevel = nil
        bufferLock.unlock()
    }

    /// The full PCM recorded since the last `reset()`.
    func getRecordedAudio() -> Data {
        bufferLock.lock()
        let data = accumulatedAudio
        bufferLock.unlock()
        return data
    }

    /// Bytes waiting in the partial-chunk buffer. For diagnostics only.
    var bufferedByteCount: Int {
        bufferLock.lock()
        let size = buffer.count
        bufferLock.unlock()
        return size
    }

    /// Collect every complete chunk. Must be called with `bufferLock` held; the
    /// chunks are emitted after unlocking so a callback cannot re-enter the lock.
    private func drainFullChunksLocked() -> [Data] {
        var chunks: [Data] = []
        while buffer.count >= AudioCaptureEngine.chunkByteSize {
            chunks.append(Data(buffer.prefix(AudioCaptureEngine.chunkByteSize)))
            buffer.removeFirst(AudioCaptureEngine.chunkByteSize)
        }
        return chunks
    }

    // MARK: - Level

    /// RMS → normalized 0..1 level from interleaved Int16 PCM.
    ///
    /// Deliberately mirrors `AudioCaptureEngine.calculateLevel(from:)` — same
    /// 256-sample decimation, same dB conversion, same -50dB..0dB mapping — so
    /// that `RecognitionSession.speechLevelThreshold` means the same thing for
    /// every source. Diverging here would make speech detection fire for the
    /// microphone but not for an external device.
    static func level(fromInt16 pcm: Data) -> Float {
        let sampleCount = pcm.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 0 }

        // Sample every Nth frame for efficiency (256 samples max)
        let step = max(1, sampleCount / 256)
        let (sum, counted) = pcm.withUnsafeBytes { raw -> (Float, Int) in
            let samples = raw.bindMemory(to: Int16.self)
            var total: Float = 0
            var count = 0
            var i = 0
            while i < sampleCount {
                let normalized = Float(samples[i]) / 32768.0
                total += normalized * normalized
                count += 1
                i += step
            }
            return (total, count)
        }
        guard counted > 0 else { return 0 }

        let rms = (sum / Float(counted)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        // Map -50dB..0dB → 0..1
        return max(0, min(1, (db + 50) / 50))
    }

    // MARK: - Audio journal

    func prepareAudioJournal(metadata: AudioJournalMetadata) throws {
        let writer = try AudioArchive.shared.beginJournal(metadata: metadata)
        journalLock.withLock {
            journalWriter?.discard()
            journalWriter = writer
        }
    }

    func updateAudioJournalPartialTranscript(_ text: String) {
        let writer = journalLock.withLock { journalWriter }
        writer?.updatePartialTranscript(text)
    }

    func finalizeAudioJournal() -> ArchivedAudio? {
        let writer = journalLock.withLock { journalWriter }
        return writer?.finalize()
    }

    func commitAudioJournal() {
        let writer = journalLock.withLock { () -> AudioJournalWriter? in
            defer { journalWriter = nil }
            return journalWriter
        }
        writer?.commit()
    }

    /// Hand the journal off to the recovery path: forget the writer without
    /// finalizing, so the on-disk file survives for the next launch to find.
    func preserveAudioJournalForRecovery() {
        journalLock.withLock {
            journalWriter = nil
        }
    }

    func discardAudioJournal() {
        let writer = journalLock.withLock { () -> AudioJournalWriter? in
            defer { journalWriter = nil }
            return journalWriter
        }
        writer?.discard()
    }
}
