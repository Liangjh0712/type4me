import XCTest

@testable import Type4Me

final class TranscriptDiffTests: XCTestCase {
  func testExactMatchCanReuseLLMResult() {
    let diff = TranscriptDiff.classify(source: "你好", final: "你好")

    XCTAssertEqual(diff.type, .exactMatch)
    XCTAssertTrue(diff.canReuseLLMResult)
  }

  func testWhitespaceOnlyCanReuseLLMResult() {
    let diff = TranscriptDiff.classify(source: "你 好", final: "你好\n")

    XCTAssertEqual(diff.type, .whitespaceOnly)
    XCTAssertTrue(diff.canReuseLLMResult)
  }

  func testPunctuationWidthOnlyCanReuseLLMResult() {
    let diff = TranscriptDiff.classify(source: "你好。继续", final: "你好.继续")

    XCTAssertEqual(diff.type, .punctuationOnly)
    XCTAssertTrue(diff.canReuseLLMResult)
  }

  func testConfirmedInternalPunctuationCanReuseLLMResult() {
    let source = "感觉现在的效果会稍微好一点但是可能还是有一些 bug 我感觉"
    let final = "感觉现在的效果会稍微好一点，但是可能还是有一些 bug，我感觉。"
    let diff = TranscriptDiff.classify(source: source, final: final)

    XCTAssertEqual(diff.type, .punctuationOnly)
    XCTAssertTrue(diff.canReuseLLMResult)
  }

  func testTrailingPunctuationOnlyCanReuseLLMResult() {
    let diff = TranscriptDiff.classify(source: "你好", final: "你好。")

    XCTAssertEqual(diff.type, .trailingPunctuationOnly)
    XCTAssertEqual(diff.addedSuffixUnicode, ["U+3002"])
    XCTAssertTrue(diff.canReuseLLMResult)
  }

  func testSuffixAddedRequiresFreshLLMResult() {
    let diff = TranscriptDiff.classify(source: "你好", final: "你好啊")

    XCTAssertEqual(diff.type, .suffixAdded)
    XCTAssertFalse(diff.canReuseLLMResult)
  }

  func testPrefixAddedRequiresFreshLLMResult() {
    let diff = TranscriptDiff.classify(source: "开会", final: "今天开会")

    XCTAssertEqual(diff.type, .prefixAdded)
    XCTAssertFalse(diff.canReuseLLMResult)
  }

  func testSemanticChangeRequiresFreshLLMResult() {
    let diff = TranscriptDiff.classify(source: "今天开会", final: "明天开会")

    XCTAssertEqual(diff.type, .semanticChange)
    XCTAssertTrue(diff.changedInMiddle)
    XCTAssertFalse(diff.canReuseLLMResult)
  }
}
