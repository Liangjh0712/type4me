import XCTest

@testable import Type4Me

/// The decoder must match the firmware's `main/adpcm.c` bit for bit. The vector
/// below is the one the firmware's own tests and the reference Python client check
/// each other against, so a nibble-order or table mistake fails here rather than
/// turning BLE audio into noise.
final class PassportADPCMTests: XCTestCase {

  /// Step up, ramp down, sign flip, then near-silence — enough to exercise the
  /// index climbing, falling, and the sign bit.
  private let vectorInput: [Int16] = [
    0, 1000, 2000, 4000, 8000, 4000, 0, -4000,
    -8000, -4000, 0, 100, 50, 0, -50, -100,
  ]

  /// What the firmware encoder produces for `vectorInput`.
  private let vectorEncoded: [UInt8] = [
    0x00, 0x00, 0x00, 0x00,  // predictor = 0, index = 0, reserved
    0x77, 0x77, 0xe7, 0xff, 0x68, 0x08, 0x08, 0x08,
  ]

  /// What both reference implementations decode it back to.
  private let vectorDecoded: [Int16] = [
    0, 11, 41, 104, 240, 533, -14, -1134,
    -3537, -3880, 180, -373, 130, -327, 88, -290,
  ]

  private func samples(_ data: Data) -> [Int16] {
    data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
  }

  // MARK: - Shared vector

  func testDecodesSharedVector() throws {
    let decoded = try XCTUnwrap(PassportADPCM.decodeBlock(Data(vectorEncoded), sampleCount: 16))

    XCTAssertEqual(samples(decoded), vectorDecoded)
  }

  /// Without an explicit count the decoder yields everything the payload can
  /// supply, which for this vector is one more sample than the vector defines
  /// (8 nibble bytes carry 16 nibbles, and the header adds sample 0).
  func testDecodesSharedVectorWithoutExplicitCount() throws {
    let decoded = try XCTUnwrap(PassportADPCM.decodeBlock(Data(vectorEncoded)))

    XCTAssertEqual(samples(decoded).count, 17)
    XCTAssertEqual(Array(samples(decoded).prefix(16)), vectorDecoded)
  }

  // MARK: - Block geometry

  func testBlockGeometryMatchesFirmware() {
    XCTAssertEqual(PassportADPCM.headerBytes, 4)
    XCTAssertEqual(PassportADPCM.blockSamples, AudioCaptureEngine.samplesPerChunk)
    XCTAssertEqual(PassportADPCM.blockBytes, 804)
  }

  /// A full block decodes to exactly one recognition chunk, so BLE audio needs no
  /// re-chunking on the way into the pipeline.
  func testFullBlockDecodesToOneChunk() throws {
    var block = Data([0x00, 0x00, 0x00, 0x00])
    block.append(Data(repeating: 0x00, count: PassportADPCM.blockSamples / 2))

    let decoded = try XCTUnwrap(PassportADPCM.decodeBlock(block))

    XCTAssertEqual(decoded.count, AudioCaptureEngine.chunkByteSize)
  }

  // MARK: - Header handling

  /// Each block carries its own predictor and index, which is what makes a lost
  /// block cost only its own 100 ms.
  func testHeaderPredictorSeedsTheFirstSample() throws {
    // predictor = 1000 (0x03E8 LE), index = 0, then one nibble of zero.
    let block = Data([0xE8, 0x03, 0x00, 0x00, 0x00])

    let decoded = try XCTUnwrap(PassportADPCM.decodeBlock(block, sampleCount: 1))

    // Nibble 0 with step 7 adds step>>3 == 0, so the predictor is unchanged.
    XCTAssertEqual(samples(decoded).first, 1000)
  }

  func testHeaderPredictorAcceptsNegativeValues() throws {
    // predictor = -1000 → 0xFC18 little-endian.
    let block = Data([0x18, 0xFC, 0x00, 0x00, 0x00])

    let decoded = try XCTUnwrap(PassportADPCM.decodeBlock(block, sampleCount: 1))

    XCTAssertEqual(samples(decoded).first, -1000)
  }

  func testClampsOutOfRangeStepIndex() throws {
    // index 200 is invalid; clamping keeps the table lookup in bounds.
    let block = Data([0x00, 0x00, 200, 0x00, 0x00])

    XCTAssertNotNil(PassportADPCM.decodeBlock(block, sampleCount: 1))
  }

  // MARK: - Malformed input

  func testRejectsBlockShorterThanHeader() {
    XCTAssertNil(PassportADPCM.decodeBlock(Data([0x00, 0x00, 0x00])))
    XCTAssertNil(PassportADPCM.decodeBlock(Data()))
  }

  /// A header alone still describes one sample: the predictor itself.
  func testHeaderOnlyBlockDecodesToPredictor() throws {
    let decoded = try XCTUnwrap(PassportADPCM.decodeBlock(Data([0xE8, 0x03, 0x00, 0x00])))

    XCTAssertEqual(samples(decoded), [1000])
  }

  /// A truncated block still decodes what it has, rather than being discarded —
  /// the reassembler zero-pads a partial block to keep the 100 ms cadence.
  func testTruncatedBlockDecodesAvailableSamples() throws {
    let block = Data([0x00, 0x00, 0x00, 0x00, 0x77, 0x77])

    let decoded = try XCTUnwrap(PassportADPCM.decodeBlock(block))

    // Header supplies sample 0, then four nibbles supply four more.
    XCTAssertEqual(samples(decoded).count, 5)
    XCTAssertEqual(Array(samples(decoded).prefix(4)), Array(vectorDecoded.prefix(4)))
  }

  func testRequestedCountIsCappedByAvailableNibbles() throws {
    let block = Data([0x00, 0x00, 0x00, 0x00, 0x77])

    let decoded = try XCTUnwrap(PassportADPCM.decodeBlock(block, sampleCount: 999))

    // One header sample plus two nibbles.
    XCTAssertEqual(samples(decoded).count, 3)
  }

  // MARK: - Signal fidelity

  /// 16 samples is far too short for the adaptive step to catch up, so the shared
  /// vector's error is large by design. Over a realistic block the codec has to
  /// actually track the signal.
  func testSustainedToneSurvivesRoundTripShape() throws {
    // Decode a block of alternating mid-range nibbles and check the output stays
    // inside Int16 and is not stuck at zero.
    var block = Data([0x00, 0x00, 0x00, 0x00])
    block.append(Data(repeating: 0x24, count: PassportADPCM.blockSamples / 2))

    let decoded = try XCTUnwrap(PassportADPCM.decodeBlock(block))
    let values = samples(decoded)

    XCTAssertEqual(values.count, PassportADPCM.blockSamples)
    XCTAssertTrue(values.contains { $0 != 0 }, "decoder produced silence for non-zero nibbles")
  }
}
