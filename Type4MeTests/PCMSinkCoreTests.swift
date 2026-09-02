import AVFoundation
import XCTest

@testable import Type4Me

/// `PCMSinkCore` is the shared tail of both audio sources, so a regression here
/// silently breaks device audio, batch fallback, crash recovery, or the speech
/// gate. These tests pin the chunking arithmetic and the level curve.
final class PCMSinkCoreTests: XCTestCase {

  private func pcm(sampleCount: Int, value: Int16 = 1000) -> Data {
    var samples = [Int16](repeating: value, count: sampleCount)
    return samples.withUnsafeMutableBufferPointer {
      Data(buffer: $0)
    }
  }

  // MARK: - Chunking

  func testEmitsNothingBelowOneChunk() {
    let sink = PCMSinkCore()
    var chunks: [Data] = []
    sink.onAudioChunk = { chunks.append($0) }

    sink.append(pcm(sampleCount: 1599))  // 3198 bytes, two short

    XCTAssertTrue(chunks.isEmpty)
    XCTAssertEqual(sink.bufferedByteCount, 3198)
  }

  func testEmitsExactlyOneChunkAtThreshold() {
    let sink = PCMSinkCore()
    var chunks: [Data] = []
    sink.onAudioChunk = { chunks.append($0) }

    sink.append(pcm(sampleCount: AudioCaptureEngine.samplesPerChunk))

    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks[0].count, AudioCaptureEngine.chunkByteSize)
    XCTAssertEqual(sink.bufferedByteCount, 0)
  }

  /// A device frame is already exactly one chunk, so feeding frames must produce
  /// one chunk per frame with nothing left over.
  func testDeviceSizedFramesMapOneToOne() {
    let sink = PCMSinkCore()
    var chunks: [Data] = []
    sink.onAudioChunk = { chunks.append($0) }

    for _ in 0..<5 {
      sink.append(pcm(sampleCount: AudioCaptureEngine.samplesPerChunk))
    }

    XCTAssertEqual(chunks.count, 5)
    XCTAssertEqual(sink.bufferedByteCount, 0)
  }

  /// Microphone callbacks arrive at arbitrary sizes, so the remainder has to carry
  /// across appends instead of being dropped or emitted short.
  func testRemainderCarriesAcrossAppends() {
    let sink = PCMSinkCore()
    var chunks: [Data] = []
    sink.onAudioChunk = { chunks.append($0) }

    sink.append(pcm(sampleCount: 1000))  // 2000 bytes
    XCTAssertEqual(chunks.count, 0)

    sink.append(pcm(sampleCount: 1000))  // 4000 bytes total → one chunk + 800
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks[0].count, AudioCaptureEngine.chunkByteSize)
    XCTAssertEqual(sink.bufferedByteCount, 800)
  }

  func testOneAppendCanEmitMultipleChunks() {
    let sink = PCMSinkCore()
    var chunks: [Data] = []
    sink.onAudioChunk = { chunks.append($0) }

    sink.append(pcm(sampleCount: AudioCaptureEngine.samplesPerChunk * 3 + 100))

    XCTAssertEqual(chunks.count, 3)
    XCTAssertEqual(sink.bufferedByteCount, 200)
  }

  func testFlushRemainingEmitsShortTail() {
    let sink = PCMSinkCore()
    var chunks: [Data] = []
    sink.onAudioChunk = { chunks.append($0) }

    sink.append(pcm(sampleCount: 500))
    sink.flushRemaining()

    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks[0].count, 1000)
    XCTAssertEqual(sink.bufferedByteCount, 0)
  }

  func testFlushRemainingIsSilentWhenEmpty() {
    let sink = PCMSinkCore()
    var chunks: [Data] = []
    sink.onAudioChunk = { chunks.append($0) }

    sink.flushRemaining()

    XCTAssertTrue(chunks.isEmpty)
  }

  // MARK: - Recorded audio

  /// Batch fallback (`RecognitionSession` streaming failure) and mid-stream
  /// recovery both re-transcribe this, so it must accumulate the whole session
  /// including bytes still sitting in the partial-chunk buffer.
  func testGetRecordedAudioAccumulatesEverything() {
    let sink = PCMSinkCore()
    sink.append(pcm(sampleCount: 1000))
    sink.append(pcm(sampleCount: 1000))

    XCTAssertEqual(sink.getRecordedAudio().count, 4000)
  }

  func testResetClearsBothBuffers() {
    let sink = PCMSinkCore()
    sink.append(pcm(sampleCount: 2000))
    sink.reset()

    XCTAssertEqual(sink.getRecordedAudio().count, 0)
    XCTAssertEqual(sink.bufferedByteCount, 0)
  }

  func testClearCallbacksStopsDelivery() {
    let sink = PCMSinkCore()
    var chunks: [Data] = []
    sink.onAudioChunk = { chunks.append($0) }

    sink.clearCallbacks()
    sink.append(pcm(sampleCount: AudioCaptureEngine.samplesPerChunk))

    XCTAssertTrue(chunks.isEmpty)
    // The bytes are still recorded — only delivery stopped.
    XCTAssertEqual(sink.getRecordedAudio().count, AudioCaptureEngine.chunkByteSize)
  }

  // MARK: - Level

  func testSilenceIsZeroLevel() {
    XCTAssertEqual(PCMSinkCore.level(fromInt16: pcm(sampleCount: 1600, value: 0)), 0)
  }

  func testEmptyDataIsZeroLevel() {
    XCTAssertEqual(PCMSinkCore.level(fromInt16: Data()), 0)
  }

  func testFullScaleIsOne() {
    // 0 dBFS maps to the top of the -50dB..0dB window.
    XCTAssertEqual(PCMSinkCore.level(fromInt16: pcm(sampleCount: 1600, value: 32767)), 1, accuracy: 0.01)
  }

  /// The Int16 curve must match `AudioCaptureEngine.calculateLevel(from:)`, which
  /// operates on Float samples. If these diverge,
  /// `RecognitionSession.speechLevelThreshold` (0.15) means one thing for the
  /// microphone and another for an external device — and a session whose level
  /// never crosses it is discarded outright at `stopRecording()`.
  func testMatchesFloatBufferLevelForTheSameSignal() throws {
    let sampleCount = 1600
    let amplitude: Int16 = 8000

    let int16Level = PCMSinkCore.level(fromInt16: pcm(sampleCount: sampleCount, value: amplitude))

    let floatFormat = try XCTUnwrap(
      AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(sampleCount)))
    buffer.frameLength = AVAudioFrameCount(sampleCount)
    let channel = try XCTUnwrap(buffer.floatChannelData)
    for i in 0..<sampleCount {
      channel[0][i] = Float(amplitude) / 32768.0
    }

    let floatLevel = AudioCaptureEngine.calculateLevel(from: buffer)
    XCTAssertEqual(int16Level, floatLevel, accuracy: 0.001)
  }

  /// A normal speaking level must clear the speech gate.
  func testSpeechAmplitudeCrossesTheSpeechThreshold() {
    let level = PCMSinkCore.level(fromInt16: pcm(sampleCount: 1600, value: 3000))
    XCTAssertGreaterThan(level, RecognitionSession.speechLevelThreshold)
  }
}
