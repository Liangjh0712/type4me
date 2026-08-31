import AVFoundation
import XCTest

@testable import Type4Me

final class AudioCaptureEngineTests: XCTestCase {

    /// 100ms of 16kHz mono int16 audio — the streaming ASR partial-latency
    /// budget. Halved from the original 200ms chunk; keep the two constants
    /// consistent (2 bytes per int16 sample).
    func testAudioChunkSize() {
        XCTAssertEqual(AudioCaptureEngine.chunkByteSize, 3200)
        XCTAssertEqual(
            AudioCaptureEngine.chunkByteSize,
            AudioCaptureEngine.samplesPerChunk * MemoryLayout<Int16>.size
        )
    }

    func testSamplesPerChunk() {
        XCTAssertEqual(AudioCaptureEngine.samplesPerChunk, 1600)
        XCTAssertEqual(
            Double(AudioCaptureEngine.samplesPerChunk)
                / AudioCaptureEngine.targetFormat.sampleRate,
            0.1,
            accuracy: 0.0001
        )
    }

    func testTargetAudioFormat() {
        let format = AudioCaptureEngine.targetFormat
        XCTAssertEqual(format.sampleRate, 16000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.commonFormat, .pcmFormatInt16)
    }
}
