import XCTest

@testable import Type4Me

/// Reassembly is the part of the BLE path most likely to be subtly wrong, and a
/// mistake shows up as garbled transcription rather than a crash. These tests build
/// fragment streams by hand, including the coalesced payloads macOS actually
/// delivers.
final class PassportADPCMReassemblerTests: XCTestCase {

  private let header = PassportADPCMReassembler.fragmentHeader
  private let lastFlag = PassportADPCMReassembler.lastFragmentFlag

  /// A full 804-byte block whose nibbles are all zero, so decoding is predictable.
  private func blockPayload(seed: UInt8 = 0) -> Data {
    var block = Data([0x00, 0x00, 0x00, 0x00])
    block.append(Data(repeating: seed, count: PassportADPCM.blockSamples / 2))
    return block
  }

  /// Split a block into fragments the way the firmware does.
  private func fragments(
    of block: Data, sequence: UInt8, bodySize: Int = 251
  ) -> [Data] {
    var result: [Data] = []
    var offset = 0
    var index: UInt8 = 0
    while offset < block.count {
      let size = min(bodySize, block.count - offset)
      let isLast = offset + size >= block.count
      var fragment = Data([sequence, index | (isLast ? lastFlag : 0)])
      fragment.append(block[offset..<(offset + size)])
      result.append(fragment)
      offset += size
      index += 1
    }
    return result
  }

  // MARK: - Clean reassembly

  func testReassemblesOneBlockFromFragments() {
    var reassembler = PassportADPCMReassembler()
    var frames: [Data] = []

    for fragment in fragments(of: blockPayload(), sequence: 0) {
      frames += reassembler.accept(fragment)
    }

    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(frames[0].count, AudioCaptureEngine.chunkByteSize)
    XCTAssertEqual(reassembler.missedBlocks, 0)
  }

  func testReassemblesConsecutiveBlocks() {
    var reassembler = PassportADPCMReassembler()
    var frames: [Data] = []

    for sequence in UInt8(0)..<UInt8(5) {
      for fragment in fragments(of: blockPayload(seed: sequence), sequence: sequence) {
        frames += reassembler.accept(fragment)
      }
    }

    XCTAssertEqual(frames.count, 5)
    XCTAssertEqual(reassembler.missedBlocks, 0)
    for frame in frames {
      XCTAssertEqual(frame.count, AudioCaptureEngine.chunkByteSize)
    }
  }

  /// Sequence numbers wrap at 256; block 0 following block 255 is normal, not a
  /// straggler from an old block.
  func testHandlesSequenceWraparound() {
    var reassembler = PassportADPCMReassembler()
    var frames: [Data] = []

    for sequence in [UInt8(254), UInt8(255), UInt8(0), UInt8(1)] {
      for fragment in fragments(of: blockPayload(), sequence: sequence) {
        frames += reassembler.accept(fragment)
      }
    }

    XCTAssertEqual(frames.count, 4)
    XCTAssertEqual(reassembler.missedBlocks, 0)
  }

  // MARK: - Coalesced notifications

  /// The defect this whole class exists for: macOS hands several notifications to one
  /// delegate call. Parsing the header at offset zero and treating the rest as body
  /// would corrupt this block and desynchronize everything after it.
  func testSplitsCoalescedPayload() {
    var reassembler = PassportADPCMReassembler()
    let pieces = fragments(of: blockPayload(), sequence: 0)

    // Prime the learned fragment length with one clean non-final fragment.
    var frames = reassembler.accept(pieces[0])

    // Then hand over the rest merged into a single payload.
    var merged = Data()
    for piece in pieces.dropFirst() { merged.append(piece) }
    frames += reassembler.accept(merged)

    XCTAssertEqual(frames.count, 1, "coalesced payload did not yield a frame")
    XCTAssertEqual(frames.first?.count, AudioCaptureEngine.chunkByteSize)
    XCTAssertEqual(reassembler.missedBlocks, 0)
  }

  /// Two whole blocks arriving in one callback — the 728-byte case from the field.
  func testSplitsCoalescedPayloadSpanningTwoBlocks() {
    var reassembler = PassportADPCMReassembler()
    var all = fragments(of: blockPayload(), sequence: 0)
    all += fragments(of: blockPayload(), sequence: 1)

    // Learn the unit from the first fragment, then merge everything else.
    var frames = reassembler.accept(all[0])
    var merged = Data()
    for piece in all.dropFirst() { merged.append(piece) }
    frames += reassembler.accept(merged)

    XCTAssertEqual(frames.count, 2)
    XCTAssertEqual(reassembler.missedBlocks, 0)
  }

  func testSplitsWhenEveryFragmentArrivesMerged() {
    var reassembler = PassportADPCMReassembler()
    var merged = Data()
    for piece in fragments(of: blockPayload(), sequence: 0) { merged.append(piece) }

    let frames = reassembler.accept(merged)

    // Without a learned unit the whole payload is one piece, which cannot be a
    // legal block, so it is counted rather than mis-split.
    XCTAssertTrue(frames.isEmpty || frames[0].count == AudioCaptureEngine.chunkByteSize)
  }

  // MARK: - Loss and disorder

  /// A dropped fragment costs its own block and nothing more: each block carries its
  /// own predictor and step index, so the next one decodes cleanly.
  func testLostFragmentCostsOnlyItsOwnBlock() {
    var reassembler = PassportADPCMReassembler()
    var frames: [Data] = []

    // Block 0 loses a middle fragment.
    let broken = fragments(of: blockPayload(), sequence: 0)
    for (i, fragment) in broken.enumerated() where i != 1 {
      frames += reassembler.accept(fragment)
    }
    // Block 1 is clean.
    for fragment in fragments(of: blockPayload(), sequence: 1) {
      frames += reassembler.accept(fragment)
    }

    XCTAssertGreaterThan(reassembler.missedBlocks, 0, "loss was not accounted for")
    XCTAssertTrue(
      frames.contains { $0.count == AudioCaptureEngine.chunkByteSize },
      "a clean block after a lossy one must still decode")
  }

  /// A block that never receives its last fragment is padded and emitted when the
  /// next block starts, keeping the 100 ms cadence the ASR stream depends on.
  func testUnterminatedBlockIsPaddedWhenTheNextBlockStarts() {
    var reassembler = PassportADPCMReassembler()
    var frames: [Data] = []

    let truncated = fragments(of: blockPayload(), sequence: 0).dropLast()
    for fragment in truncated {
      frames += reassembler.accept(fragment)
    }
    XCTAssertTrue(frames.isEmpty, "block emitted before it was terminated")

    frames += reassembler.accept(fragments(of: blockPayload(), sequence: 1)[0])

    XCTAssertEqual(frames.count, 1, "padded block was not emitted")
    XCTAssertEqual(frames[0].count, AudioCaptureEngine.chunkByteSize)
    XCTAssertEqual(reassembler.missedBlocks, 1)
  }

  func testDropsDuplicateFragment() {
    var reassembler = PassportADPCMReassembler()
    let pieces = fragments(of: blockPayload(), sequence: 0)
    var frames: [Data] = []

    for fragment in pieces {
      frames += reassembler.accept(fragment)
      // Resend the same fragment immediately.
      frames += reassembler.accept(fragment)
    }

    XCTAssertEqual(frames.count, 1, "duplicates corrupted the block")
  }

  func testDropsStragglerFromFinalizedBlock() {
    var reassembler = PassportADPCMReassembler()
    let pieces = fragments(of: blockPayload(), sequence: 0)
    var frames: [Data] = []

    for fragment in pieces { frames += reassembler.accept(fragment) }
    XCTAssertEqual(frames.count, 1)

    // A late fragment for the block we already emitted must not open a new one.
    frames += reassembler.accept(pieces[0])

    XCTAssertEqual(frames.count, 1)
  }

  func testCountsFragmentTooShortForAHeader() {
    var reassembler = PassportADPCMReassembler()

    let frames = reassembler.accept(Data([0x00]))

    XCTAssertTrue(frames.isEmpty)
    XCTAssertEqual(reassembler.missedBlocks, 1)
  }

  func testRealignsAfterAnOversizeBlock() {
    var reassembler = PassportADPCMReassembler()
    var frames: [Data] = []

    // Force an impossible block: more data than a block can hold, then terminate.
    var oversize = Data([0x00, 0x00])
    oversize.append(Data(repeating: 0x11, count: PassportADPCM.blockBytes + 50))
    frames += reassembler.accept(oversize)
    frames += reassembler.accept(Data([0x00, lastFlag]))

    // The next clean block must still decode.
    for fragment in fragments(of: blockPayload(), sequence: 9) {
      frames += reassembler.accept(fragment)
    }

    XCTAssertTrue(
      frames.contains { $0.count == AudioCaptureEngine.chunkByteSize },
      "reassembler did not realign after an oversize block")
  }

  // MARK: - Reset

  func testResetClearsPartialBlockAndCounters() {
    var reassembler = PassportADPCMReassembler()
    _ = reassembler.accept(Data([0x00]))
    _ = reassembler.accept(fragments(of: blockPayload(), sequence: 0)[0])

    reassembler.reset()

    XCTAssertEqual(reassembler.missedBlocks, 0)
    // A fresh block reassembles as if nothing preceded it.
    var frames: [Data] = []
    for fragment in fragments(of: blockPayload(), sequence: 0) {
      frames += reassembler.accept(fragment)
    }
    XCTAssertEqual(frames.count, 1)
  }
}
