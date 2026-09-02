import XCTest

@testable import Type4Me

/// The uplink and downlink JSON layers use different keys — `"event"` going up,
/// `"type"` coming down — and the device silently rejects a line whose fields it
/// cannot read. These tests pin both directions against the firmware's
/// `main/app_protocol.c`.
final class PassportProtocolTests: XCTestCase {

  // MARK: - Uplink parsing

  func testParsesDeviceHello() {
    let event = PassportProtocol.parseEvent(#"{"event":"device.hello","proto":2}"#)

    XCTAssertEqual(event, .hello(proto: 2))
  }

  func testParsesVoiceStartWithPCM() {
    let event = PassportProtocol.parseEvent(#"{"event":"voice.start","audio":"pcm"}"#)

    XCTAssertEqual(event, .voiceStart(encoding: .pcm, isNote: false))
  }

  func testParsesVoiceStartWithADPCM() {
    let event = PassportProtocol.parseEvent(#"{"event":"voice.start","audio":"ima_adpcm"}"#)

    XCTAssertEqual(event, .voiceStart(encoding: .imaADPCM, isNote: false))
  }

  /// The OK key records the same way but the text is kept rather than typed.
  func testParsesQuickNoteSession() {
    let event = PassportProtocol.parseEvent(#"{"event":"voice.start","audio":"pcm","note":true}"#)

    XCTAssertEqual(event, .voiceStart(encoding: .pcm, isNote: true))
  }

  /// Older firmware omits the field entirely, so its absence must read as a normal
  /// recording rather than failing to parse.
  func testMissingNoteFieldMeansNormalRecording() {
    let event = PassportProtocol.parseEvent(#"{"event":"voice.start","audio":"pcm"}"#)

    XCTAssertEqual(event, .voiceStart(encoding: .pcm, isNote: false))
  }

  /// The same firmware sends PCM over USB and ADPCM over BLE, so the announced
  /// encoding — not the transport's default — decides which decoder runs.
  func testUnknownEncodingIsRejectedRatherThanGuessed() {
    XCTAssertNil(PassportProtocol.parseEvent(#"{"event":"voice.start","audio":"opus"}"#))
  }

  func testParsesVoiceEnd() {
    XCTAssertEqual(PassportProtocol.parseEvent(#"{"event":"voice.end"}"#), .voiceEnd)
  }

  func testParsesStatusDrop() {
    XCTAssertEqual(PassportProtocol.parseEvent(#"{"event":"status","drop":7}"#), .status(drop: 7))
  }

  func testParsesKeyActions() {
    XCTAssertEqual(
      PassportProtocol.parseEvent(#"{"event":"key.action","action":"enter"}"#), .keyAction(.enter))
    XCTAssertEqual(
      PassportProtocol.parseEvent(#"{"event":"key.action","action":"clear"}"#), .keyAction(.clear))
  }

  func testParsesTrailingNewline() {
    // Event frames carry their newline, unlike control frames.
    XCTAssertEqual(PassportProtocol.parseEvent("{\"event\":\"voice.end\"}\n"), .voiceEnd)
  }

  /// New firmware may add events; an unrecognized one is not a failure.
  func testIgnoresUnknownEvent() {
    XCTAssertNil(PassportProtocol.parseEvent(#"{"event":"battery.low","soc":5}"#))
  }

  func testIgnoresMalformedInput() {
    XCTAssertNil(PassportProtocol.parseEvent(""))
    XCTAssertNil(PassportProtocol.parseEvent("not json"))
    XCTAssertNil(PassportProtocol.parseEvent("{}"))
    XCTAssertNil(PassportProtocol.parseEvent(#"{"type":"transcript"}"#))  // downlink key
  }

  func testIgnoresKeyActionWithUnknownAction() {
    XCTAssertNil(PassportProtocol.parseEvent(#"{"event":"key.action","action":"reboot"}"#))
  }

  // MARK: - Downlink encoding

  func testEncodesAgentStatus() {
    let line = PassportProtocol.agentStatus(.done)

    XCTAssertTrue(line.contains(#""type":"agent.status""#))
    XCTAssertTrue(line.contains(#""state":"done""#))
  }

  func testEncodesTranscriptPreviewAndFinal() {
    XCTAssertTrue(PassportProtocol.transcript("hi", final: false).contains(#""final":false"#))
    XCTAssertTrue(PassportProtocol.transcript("hi", final: true).contains(#""final":true"#))
  }

  func testEncodesTimeSet() {
    let line = PassportProtocol.timeSet(epoch: 1_767_225_600)

    XCTAssertTrue(line.contains(#""type":"time.set""#))
    XCTAssertTrue(line.contains("1767225600"))
  }

  func testDownlinkLinesFitTheDeviceParser() {
    let long = String(repeating: "字", count: 100)
    for line in [
      PassportProtocol.agentStatus(.error, message: long),
      PassportProtocol.transcript(long, final: true),
    ] {
      XCTAssertLessThanOrEqual(line.utf8.count, PassportProtocol.downlinkLineCap)
    }
  }

  // MARK: - Display splitting

  func testShortTextIsNotSplit() {
    XCTAssertEqual(PassportProtocol.splitForDisplay("hello"), ["hello"])
  }

  func testEmptyTextProducesNoSegments() {
    XCTAssertTrue(PassportProtocol.splitForDisplay("").isEmpty)
  }

  func testTextAtExactlyTheCapIsNotSplit() {
    let text = String(repeating: "a", count: PassportProtocol.displayTextCap)

    XCTAssertEqual(PassportProtocol.splitForDisplay(text), [text])
  }

  func testSplitsOneBytePastTheCap() {
    let text = String(repeating: "a", count: PassportProtocol.displayTextCap + 1)

    XCTAssertEqual(PassportProtocol.splitForDisplay(text).count, 2)
  }

  /// The device's `text` field is a byte buffer, so Chinese costs three bytes a
  /// glyph — splitting on character count would overflow it, and splitting on raw
  /// bytes would cut a glyph in half and render as mojibake.
  func testSplitsChineseOnCharacterBoundaries() {
    let text = String(repeating: "语音输入", count: 20)  // 80 glyphs, 240 bytes

    let segments = PassportProtocol.splitForDisplay(text)

    XCTAssertGreaterThan(segments.count, 1)
    for segment in segments {
      XCTAssertLessThanOrEqual(segment.utf8.count, PassportProtocol.displayTextCap)
    }
    XCTAssertEqual(segments.joined(), text, "splitting must not lose or reorder text")
  }

  func testSplitsEmojiWithoutBreakingThem() {
    let text = String(repeating: "🎙️", count: 40)

    let segments = PassportProtocol.splitForDisplay(text)

    for segment in segments {
      XCTAssertLessThanOrEqual(segment.utf8.count, PassportProtocol.displayTextCap)
    }
    XCTAssertEqual(segments.joined(), text)
  }

  /// A single grapheme larger than the cap cannot be split further; it must still
  /// come back rather than being dropped.
  func testOversizeSingleCharacterIsStillEmitted() {
    let segments = PassportProtocol.splitForDisplay("语", cap: 1)

    XCTAssertEqual(segments, ["语"])
  }
}
