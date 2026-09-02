@preconcurrency import AVFoundation

enum AudioCaptureError: Error, LocalizedError {
    case converterCreationFailed
    case microphonePermissionDenied
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .converterCreationFailed:
            return L("录音启动失败", "Failed to start recording")
        case .microphonePermissionDenied:
            return L("未授予麦克风权限", "Microphone permission not granted")
        case .noInputDevice:
            return L("找不到麦克风", "No microphone found")
        }
    }
}

final class AudioCaptureEngine: NSObject, AudioSource, @unchecked Sendable, AVCaptureAudioDataOutputSampleBufferDelegate {

    // MARK: - Static properties

    static let sampleRate: Double = 16000
    static let channels: AVAudioChannelCount = 1
    /// 100ms packets: streaming ASR servers (volcano/deepgram/…) answer per
    /// packet, so smaller packets roughly halve partial-result latency and
    /// make the live transcript feel silky instead of stepping every ~400ms.
    static let chunkDurationMs: Int = 100
    static let samplesPerChunk: Int = 1600
    static let chunkByteSize: Int = 3200
    static let targetFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    static func makePCMBuffer(from pcmData: Data) -> AVAudioPCMBuffer? {
        guard pcmData.count.isMultiple(of: MemoryLayout<Int16>.size) else { return nil }

        let frameCount = AVAudioFrameCount(pcmData.count / MemoryLayout<Int16>.size)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
            return nil
        }

        buffer.frameLength = frameCount
        guard let mData = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
            return nil
        }

        pcmData.copyBytes(to: mData.assumingMemoryBound(to: UInt8.self), count: pcmData.count)
        buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize = UInt32(pcmData.count)
        return buffer
    }

    // MARK: - Device Selection

    /// Set before calling `start()`. Empty string or nil means system default.
    var selectedDeviceUID: String?

    /// Returns rich metadata for available audio input devices.
    static func availableAudioInputDevices() -> [AudioInputDevice] {
        AudioInputDeviceDiscovery.availableInputDevices()
    }

    /// Returns a list of available audio input devices (UID + display name).
    static func availableAudioDevices() -> [(uid: String, name: String)] {
        availableAudioInputDevices().map { (uid: $0.uid, name: $0.name) }
    }

    /// Resolve the capture device: use selectedDeviceUID if set and valid, otherwise system default.
    private func resolveDevice() -> AVCaptureDevice? {
        if let uid = selectedDeviceUID, !uid.isEmpty,
           let device = AVCaptureDevice(uniqueID: uid) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    // MARK: - Public

    /// Forwarded to `sink`, which owns the chunking and journalling. The engine's
    /// own job ends at handing converted PCM to the sink.
    var onAudioChunk: ((Data) -> Void)? {
        get { sink.onAudioChunk }
        set { sink.onAudioChunk = newValue }
    }

    var onAudioLevel: ((Float) -> Void)? {
        get { sink.onAudioLevel }
        set { sink.onAudioLevel = newValue }
    }

    // MARK: - Private

    /// The audio-source-agnostic tail: journal → accumulate → cut into chunks.
    private let sink = PCMSinkCore()

    private var captureSession: AVCaptureSession?
    private let stateLock = NSLock()
    private var converterLock = NSLock()
    private var converter: AVAudioConverter?
    private let outputQueue = DispatchQueue(label: "com.type4me.audiocapture")
    private let outputQueueKey = DispatchSpecificKey<UInt8>()
    private let outputQueueTag: UInt8 = 1
    private var activeOutput: AVCaptureAudioDataOutput?
    private var levelCounter = 0

    // MARK: - Warm-up

    private var isWarmedUp = false
    override init() {
        super.init()
        outputQueue.setSpecific(key: outputQueueKey, value: outputQueueTag)
    }

    /// Pre-initialize the audio capture pipeline so the first real recording starts instantly.
    func warmUp() {
        guard !isWarmedUp else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            NSLog("[Audio] Warm-up skipped: microphone permission not granted")
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Loading AVAudioEngine and its input node primes the framework without
            // opening the microphone. Starting a warm-up capture here would push a
            // Bluetooth headset into call mode while the app is merely launching.
            let engine = AVAudioEngine()
            _ = engine.inputNode
            self?.isWarmedUp = true
            NSLog("[Audio] Warm-up complete (AVAudioEngine graph initialized)")
        }
    }

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

    // MARK: - Start / Stop

    func start() throws {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard authStatus == .authorized else {
            throw AudioCaptureError.microphonePermissionDenied
        }

        // Reset state
        sink.reset()
        converterLock.withLock { converter = nil }

        try startWithAVCapture()
    }

    private func startWithAVCapture() throws {
        let session = AVCaptureSession()

        guard let device = resolveDevice() else {
            throw AudioCaptureError.noInputDevice
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw AudioCaptureError.converterCreationFailed
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(output) else {
            throw AudioCaptureError.converterCreationFailed
        }
        session.addOutput(output)
        stateLock.withLock {
            activeOutput = output
        }

        session.startRunning()
        captureSession = session
        isWarmedUp = true
        NSLog("[Audio] Capture session started (AVCapture), device: %@", device.localizedName)
        DebugFileLogger.log("audio capture started device=\(device.localizedName)")
    }

    func stop() {
        guard let session = captureSession else {
            clearCaptureState()
            return
        }

        session.stopRunning()
        drainOutputQueue()

        let output = stateLock.withLock { () -> AVCaptureAudioDataOutput? in
            let current = activeOutput
            activeOutput = nil
            return current
        }
        output?.setSampleBufferDelegate(nil, queue: nil)

        // stopRunning() stops delivery, but explicitly detaching every graph node
        // releases the AVCaptureDeviceInput immediately. This is important for a
        // Bluetooth headset: CoreAudio can leave the HFP input route alive while
        // a stopped session still owns its device input.
        session.beginConfiguration()
        for captureOutput in session.outputs {
            session.removeOutput(captureOutput)
        }
        for captureInput in session.inputs {
            session.removeInput(captureInput)
        }
        session.commitConfiguration()
        captureSession = nil

        sink.flushRemaining()
        clearCaptureState()
        NSLog("[Audio] Capture session stopped and graph detached")
        DebugFileLogger.log("audio capture stopped; AVCapture graph detached")
    }

    private func clearCaptureState() {
        converterLock.withLock { converter = nil }
        sink.clearCallbacks()
        levelCounter = 0
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let isActiveOutput = stateLock.withLock { activeOutput === output }
        guard isActiveOutput else { return }
        guard let pcmBuffer = sampleBuffer.toPCMBuffer() else { return }

        // Emit audio level ~20 times/sec (every 3rd callback at typical 60Hz buffer rate)
        levelCounter += 1
        if levelCounter % 3 == 0, let onAudioLevel {
            let level = Self.calculateLevel(from: pcmBuffer)
            onAudioLevel(level)
        }

        // Heartbeat log every ~5s (300 callbacks at ~60Hz)
        if levelCounter % 300 == 0 {
            let level = Self.calculateLevel(from: pcmBuffer)
            DebugFileLogger.log("audio heartbeat callback=\(levelCounter) bufferSize=\(sink.bufferedByteCount) level=\(String(format: "%.3f", level))")
        }

        // Create or recreate converter when source format changes
        converterLock.lock()
        let sourceFormat = pcmBuffer.format
        if converter == nil || converter?.inputFormat != sourceFormat {
            if converter != nil {
                NSLog("[Audio] Input format changed, rebuilding converter: %@", sourceFormat.description)
            }
            converter = AVAudioConverter(from: sourceFormat, to: Self.targetFormat)
            NSLog("[Audio] Input format: %@", sourceFormat.description)
            DebugFileLogger.log(
                "audio input format rate=\(sourceFormat.sampleRate) channels=\(sourceFormat.channelCount) interleaved=\(sourceFormat.isInterleaved)"
            )
        }
        guard let conv = converter else {
            converterLock.unlock()
            return
        }
        converterLock.unlock()
        convert(buffer: pcmBuffer, using: conv)
    }

    // MARK: - Internal

    private func convert(buffer pcmBuffer: AVAudioPCMBuffer, using converter: AVAudioConverter) {
        let frameCapacity = AVAudioFrameCount(
            Double(pcmBuffer.frameLength) * Self.sampleRate / pcmBuffer.format.sampleRate
        )
        guard frameCapacity > 0 else { return }
        guard let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: Self.targetFormat,
            frameCapacity: frameCapacity
        ) else { return }

        var error: NSError?
        nonisolated(unsafe) var hasData = true
        let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return pcmBuffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        guard status != .error, error == nil else { return }

        let byteCount = Int(convertedBuffer.frameLength) * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return }

        let audioBuffer = convertedBuffer.audioBufferList.pointee.mBuffers
        guard let mData = audioBuffer.mData else { return }
        sink.append(Data(bytes: mData, count: byteCount))
    }

    /// Returns the full recorded PCM audio since the last start().
    func getRecordedAudio() -> Data {
        sink.getRecordedAudio()
    }

    /// RMS → normalized 0..1 level from float PCM buffer.
    /// Exposed for testing so `PCMSinkCore.level(fromInt16:)` can be pinned against it.
    static func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        let ptr = channelData[0]
        var sum: Float = 0
        // Sample every 16th frame for efficiency (256 samples max)
        let stride = max(1, frames / 256)
        var count = 0
        var i = 0
        while i < frames {
            sum += ptr[i] * ptr[i]
            count += 1
            i += stride
        }
        let rms = sqrt(sum / Float(count))
        let db = 20 * log10(max(rms, 1e-7))
        // Map -50dB..0dB → 0..1
        return max(0, min(1, (db + 50) / 50))
    }

    private func drainOutputQueue() {
        if DispatchQueue.getSpecific(key: outputQueueKey) == outputQueueTag {
            return  // already on outputQueue, skip to avoid deadlock
        }
        outputQueue.sync {}
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

private extension CMSampleBuffer {
    func toPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }

        guard let avFormat = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }

        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)

        if let floatData = pcmBuffer.floatChannelData {
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: floatData[0])
        } else if let int16Data = pcmBuffer.int16ChannelData {
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: int16Data[0])
        } else {
            return nil
        }

        return pcmBuffer
    }
}
