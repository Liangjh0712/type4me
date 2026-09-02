import XCTest

@testable import Type4Me

/// The wired framing is shared byte-for-byte with the device firmware
/// (`main/usb_link_framing.c`) and the reference Python client
/// (`companion/serial_frame.py`). These vectors come from that Python
/// implementation, so a drift on either side breaks here rather than turning into
/// silent audio corruption on the wire.
final class PassportFrameProtocolTests: XCTestCase {

  private func decodeAll(_ bytes: [UInt8]) -> (frames: [PassportFrame.Message], errors: [PassportFrame.DecodeError]) {
    var decoder = PassportFrameDecoder()
    var errors: [PassportFrame.DecodeError] = []
    let frames = decoder.decode(Data(bytes)) { errors.append($0) }
    return (frames, errors)
  }

  // MARK: - Encoding

  /// Byte 0-1: magic A5 5A. Byte 2: type. Bytes 3-4: length little-endian.
  /// Last byte: checksum making the whole frame sum to 0 mod 256.
  func testEncodesSysPing() {
    let frame = PassportFrame.encode(.sys, text: "ping")

    XCTAssertEqual(
      Array(frame),
      [0xa5, 0x5a, 0x04, 0x04, 0x00, 0x70, 0x69, 0x6e, 0x67, 0x4b])
    XCTAssertEqual(frame.count, PassportFrame.overhead + 4)
  }

  func testEncodesControlJSON() {
    let frame = PassportFrame.encode(.control, text: #"{"type":"agent.status","state":"done"}"#)

    XCTAssertEqual(Array(frame.prefix(5)), [0xa5, 0x5a, 0x03, 0x26, 0x00])
    XCTAssertEqual(frame.last, 0xc6)
    XCTAssertEqual(frame.count, 44)
  }

  func testEncodesEmptyPayload() {
    XCTAssertEqual(Array(PassportFrame.encode(.event, Data())), [0xa5, 0x5a, 0x01, 0x00, 0x00, 0x00])
  }

  /// Length is little-endian, so 3200 (0x0C80) is `80 0c` — getting this backwards
  /// is the single most likely porting mistake, and the firmware warns about it.
  func testEncodesLengthLittleEndian() {
    let frame = PassportFrame.encode(.audio, Data(count: 3200))

    XCTAssertEqual(Array(frame.prefix(5)), [0xa5, 0x5a, 0x02, 0x80, 0x0c])
    XCTAssertEqual(frame.count, 3206)
  }

  func testEncodedFrameSumsToZero() {
    for kind in PassportFrame.Kind.allCases {
      let frame = PassportFrame.encode(kind, Data([1, 2, 3, 250, 251]))
      let sum = frame.reduce(0) { ($0 + Int($1)) & 0xFF }
      XCTAssertEqual(sum, 0, "checksum invariant broken for \(kind)")
    }
  }

  // MARK: - Decoding

  func testDecodesDeviceHello() {
    let hello = #"{"event":"device.hello","proto":2}"# + "\n"
    let (frames, errors) = decodeAll(Array(PassportFrame.encode(.event, text: hello)))

    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(frames.first?.kind, .event)
    XCTAssertEqual(String(data: frames[0].payload, encoding: .utf8), hello)
    XCTAssertTrue(errors.isEmpty)
  }

  func testDecodesEmptyPayloadFrame() {
    let (frames, errors) = decodeAll([0xa5, 0x5a, 0x01, 0x00, 0x00, 0x00])

    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(frames[0].payload, Data())
    XCTAssertTrue(errors.isEmpty)
  }

  func testDecodesFullAudioFrame() {
    let pcm = Data((0..<3200).map { UInt8($0 % 256) })
    let (frames, _) = decodeAll(Array(PassportFrame.encode(.audio, pcm)))

    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(frames[0].kind, .audio)
    XCTAssertEqual(frames[0].payload, pcm)
    XCTAssertEqual(frames[0].payload.count, AudioCaptureEngine.chunkByteSize)
  }

  func testDecodesBackToBackFrames() {
    var bytes = Array(PassportFrame.encode(.event, text: "a"))
    bytes += Array(PassportFrame.encode(.audio, Data(count: 3200)))
    bytes += Array(PassportFrame.encode(.event, text: "b"))

    let (frames, errors) = decodeAll(bytes)

    XCTAssertEqual(frames.map(\.kind), [.event, .audio, .event])
    XCTAssertTrue(errors.isEmpty)
  }

  /// A serial read returns an arbitrary slice, so a frame routinely spans reads.
  /// Feeding one byte per call is the worst case.
  func testDecodesFrameSplitAcrossEveryByte() {
    let encoded = PassportFrame.encode(.event, text: #"{"event":"voice.end"}"#)
    var decoder = PassportFrameDecoder()
    var frames: [PassportFrame.Message] = []

    for byte in encoded {
      frames += decoder.decode(Data([byte]))
    }

    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(String(data: frames[0].payload, encoding: .utf8), #"{"event":"voice.end"}"#)
  }

  func testDecoderStateSurvivesSplitAtEveryOffset() {
    let encoded = PassportFrame.encode(.audio, Data(count: 3200))

    for split in [1, 2, 3, 5, 6, 7, 100, 1600, 3205] {
      var decoder = PassportFrameDecoder()
      var frames = decoder.decode(encoded.prefix(split))
      frames += decoder.decode(encoded.dropFirst(split))
      XCTAssertEqual(frames.count, 1, "split at \(split) lost the frame")
    }
  }

  // MARK: - Resynchronization

  /// Boot-time log noise precedes the first frame; it must be skipped, not fatal.
  func testSkipsLeadingGarbage() {
    var bytes: [UInt8] = Array("I (252) main_task: started\n".utf8)
    bytes += Array(PassportFrame.encode(.event, text: "x"))

    let (frames, _) = decodeAll(bytes)

    XCTAssertEqual(frames.count, 1)
  }

  /// `A5 A5 5A ...`: the first 0xA5 fails the magic1 check, but the byte that
  /// failed is itself 0xA5 and must be reconsidered as the new frame start. A
  /// decoder that discarded it would eat the frame that follows.
  func testFalseAnchorDoesNotSwallowTheNextFrame() {
    var bytes: [UInt8] = [0xa5]
    bytes += Array(PassportFrame.encode(.event, text: "hi"))

    let (frames, errors) = decodeAll(bytes)

    XCTAssertEqual(frames.count, 1, "leading 0xA5 consumed the real frame")
    XCTAssertEqual(String(data: frames[0].payload, encoding: .utf8), "hi")
    XCTAssertTrue(errors.isEmpty)
  }

  func testRepeatedFalseAnchors() {
    var bytes: [UInt8] = [0xa5, 0xa5, 0xa5, 0xa5]
    bytes += Array(PassportFrame.encode(.event, text: "z"))

    let (frames, _) = decodeAll(bytes)

    XCTAssertEqual(frames.count, 1)
  }

  func testRecoversAfterCorruptFrame() {
    var bytes = Array(PassportFrame.encode(.event, text: "first"))
    bytes[bytes.count - 1] ^= 0xFF  // break the checksum
    bytes += Array(PassportFrame.encode(.event, text: "second"))

    let (frames, errors) = decodeAll(bytes)

    XCTAssertEqual(errors, [.checksumMismatch])
    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(String(data: frames[0].payload, encoding: .utf8), "second")
  }

  // MARK: - Direction filtering and limits

  /// A host receives only device→host types. Rejecting `control`/`sys` at the type
  /// byte — before any payload is buffered — is what makes the read path safe
  /// against a mis-wired or echoing peer.
  func testRejectsOutboundOnlyTypes() {
    for kind in [PassportFrame.Kind.control, .sys] {
      let (frames, errors) = decodeAll(Array(PassportFrame.encode(kind, Data([0x41]))))

      XCTAssertTrue(frames.isEmpty, "\(kind) should not decode on the host")
      XCTAssertEqual(errors.first, .badType(kind.rawValue))
    }
  }

  func testRejectsUnknownType() {
    let (frames, errors) = decodeAll([0xa5, 0x5a, 0x09, 0x00, 0x00, 0x00])

    XCTAssertTrue(frames.isEmpty)
    XCTAssertEqual(errors.first, .badType(0x09))
  }

  /// An absurd declared length must be refused at the header, not allocated for.
  func testRejectsOversizeLength() {
    // EVENT caps at 512; declare 0xFFFF.
    let (frames, errors) = decodeAll([0xa5, 0x5a, 0x01, 0xff, 0xff, 0x00])

    XCTAssertTrue(frames.isEmpty)
    XCTAssertEqual(errors.first, .oversize(kind: .event, length: 0xFFFF))
  }

  func testAcceptsExactlyMaxPayload() {
    let (frames, errors) = decodeAll(Array(PassportFrame.encode(.event, Data(count: 512))))

    XCTAssertEqual(frames.count, 1)
    XCTAssertEqual(frames[0].payload.count, 512)
    XCTAssertTrue(errors.isEmpty)
  }

  func testRejectsOnePastMaxPayload() {
    // Hand-build the header: the encoder does not enforce caps.
    let (frames, errors) = decodeAll([0xa5, 0x5a, 0x01, 0x01, 0x02, 0x00])

    XCTAssertTrue(frames.isEmpty)
    XCTAssertEqual(errors.first, .oversize(kind: .event, length: 513))
  }

  func testAudioPayloadCapMatchesChunkSize() {
    // The device sends exactly one recognition chunk per audio frame.
    XCTAssertEqual(PassportFrame.Kind.audio.maxPayload, AudioCaptureEngine.chunkByteSize)
  }

  // MARK: - Round trip

  func testRoundTripsEveryInboundType() {
    for kind in PassportFrame.Kind.allCases where kind.isInbound {
      let payload = Data((0..<min(kind.maxPayload, 700)).map { UInt8($0 % 256) })
      let (frames, errors) = decodeAll(Array(PassportFrame.encode(kind, payload)))

      XCTAssertEqual(frames.count, 1, "\(kind) failed to round trip")
      XCTAssertEqual(frames.first?.kind, kind)
      XCTAssertEqual(frames.first?.payload, payload)
      XCTAssertTrue(errors.isEmpty)
    }
  }
}
