import XCTest

@testable import Type4Me

final class HistoryRetranscriptionServiceTests: XCTestCase {

  private func transcript(
    _ text: String,
    isFinal: Bool = false,
    partial: String = ""
  ) -> RecognitionTranscript {
    RecognitionTranscript(
      confirmedSegments: text.isEmpty ? [] : [text],
      partialText: partial,
      authoritativeText: text,
      isFinal: isFinal
    )
  }

  /// Regression: the first utterance-level isFinal used to end the session.
  /// An early endpointed utterance (e.g. the retained start chime) can carry
  /// empty text — recognition must continue until the stream terminates.
  func testSessionFinalTextSurvivesEmptyEarlyFinal() async {
    let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
    continuation.yield(.transcript(transcript("如果")))
    continuation.yield(.transcript(transcript("", isFinal: true)))
    continuation.yield(.transcript(transcript("如果有个表格确实可以")))
    continuation.yield(.transcript(transcript("如果有个表格确实可以做这种补充处理", isFinal: true)))
    continuation.yield(.completed)
    continuation.finish()

    let text = await HistoryRetranscriptionService.sessionFinalText(from: stream)

    XCTAssertEqual(text, "如果有个表格确实可以做这种补充处理")
  }

  /// Multi-utterance sessions emit several finals; the last cumulative
  /// snapshot wins, not the first.
  func testSessionFinalTextKeepsLatestAcrossMultipleFinals() async {
    let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
    continuation.yield(.transcript(transcript("第一句。", isFinal: true)))
    continuation.yield(.transcript(transcript("第一句。第二句。", isFinal: true)))
    continuation.yield(.completed)
    continuation.finish()

    let text = await HistoryRetranscriptionService.sessionFinalText(from: stream)

    XCTAssertEqual(text, "第一句。第二句。")
  }

  func testSessionFinalTextReturnsNilWhenEverythingIsEmpty() async {
    let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
    continuation.yield(.transcript(transcript("", isFinal: true)))
    continuation.yield(.completed)
    continuation.finish()

    let text = await HistoryRetranscriptionService.sessionFinalText(from: stream)

    XCTAssertNil(text)
  }

  func testSessionFinalTextSalvagesTextBeforeError() async {
    let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
    continuation.yield(.transcript(transcript("部分结果")))
    continuation.yield(.error(CancellationError()))
    continuation.finish()

    let text = await HistoryRetranscriptionService.sessionFinalText(from: stream)

    XCTAssertEqual(text, "部分结果")
  }

  func testSessionFinalTextFallsBackToComposedTextWhenAuthoritativeIsEmpty() async {
    let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
    continuation.yield(
      .transcript(
        RecognitionTranscript(
          confirmedSegments: ["已确认"],
          partialText: "进行中",
          authoritativeText: "",
          isFinal: false
        )))
    continuation.yield(.completed)
    continuation.finish()

    let text = await HistoryRetranscriptionService.sessionFinalText(from: stream)

    XCTAssertEqual(text, "已确认进行中")
  }

  /// Stream finishing without a terminal event (batch clients) still yields
  /// the accumulated text.
  func testSessionFinalTextReturnsAccumulatedTextOnStreamEnd() async {
    let (stream, continuation) = AsyncStream<RecognitionEvent>.makeStream()
    continuation.yield(.transcript(transcript("完整结果", isFinal: true)))
    continuation.finish()

    let text = await HistoryRetranscriptionService.sessionFinalText(from: stream)

    XCTAssertEqual(text, "完整结果")
  }
}
