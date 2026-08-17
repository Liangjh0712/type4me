import XCTest
@testable import Type4Me

final class SpeculativeLLMThrottleTests: XCTestCase {
    func testMinimumTextLength() {
        var throttle = SpeculativeLLMThrottle()

        XCTAssertEqual(throttle.submit("1234567"), .tooShort)
        XCTAssertEqual(throttle.submit("12345678"), .debounce)
    }

    func testMinimumCharacterIncrement() {
        var throttle = SpeculativeLLMThrottle()
        XCTAssertEqual(throttle.submit("12345678"), .debounce)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "12345678"))
        _ = throttle.requestCompleted(input: "12345678")

        XCTAssertEqual(throttle.submit("123456789012345"), .deltaTooSmall)
        XCTAssertEqual(throttle.submit("1234567890123456"), .debounce)
    }

    func testDebounceKeepsNewestCandidateBeforeRequestStarts() {
        var throttle = SpeculativeLLMThrottle()

        XCTAssertEqual(throttle.submit("12345678"), .debounce)
        XCTAssertEqual(throttle.submit("abcdefgh"), .debounce)

        XCTAssertFalse(throttle.beginDebouncedRequest(for: "12345678"))
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "abcdefgh"))
    }

    func testDoesNotRunConcurrentRequests() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("12345678")
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "12345678"))

        XCTAssertEqual(throttle.submit("1234567890123456"), .queued)
        XCTAssertFalse(throttle.beginDebouncedRequest(for: "1234567890123456"))
    }

    func testNewestPendingTranscriptIsReturnedAfterCompletion() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("12345678")
        _ = throttle.beginDebouncedRequest(for: "12345678")
        XCTAssertEqual(throttle.submit("1234567890123456"), .queued)
        XCTAssertEqual(throttle.submit("123456789012345678901234"), .queued)

        let pending = throttle.requestCompleted(input: "12345678")

        XCTAssertEqual(pending, "123456789012345678901234")
    }

    func testResetClearsInFlightAndPendingState() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("12345678")
        _ = throttle.beginDebouncedRequest(for: "12345678")
        _ = throttle.submit("1234567890123456")

        throttle.reset()

        XCTAssertFalse(throttle.inFlight)
        XCTAssertNil(throttle.pendingText)
        XCTAssertEqual(throttle.submit("12345678"), .debounce)
    }

    func testShortExplicitCorrectionBypassesCharacterIncrement() {
        var throttle = SpeculativeLLMThrottle()
        let original = "预算已经确定为 30 万"
        XCTAssertEqual(throttle.submit(original), .debounce)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: original))
        _ = throttle.requestCompleted(input: original)

        let corrected = original + "改成 50 万"

        XCTAssertLessThan(corrected.count - original.count, SpeculativeLLMThrottle.minimumCharacterIncrement)
        XCTAssertEqual(throttle.submit(corrected), .debounce)
    }

    func testStableASRRewriteIsNewSourceData() {
        var throttle = SpeculativeLLMThrottle()
        let original = "今天下午三点开会"
        XCTAssertEqual(throttle.submit(original), .debounce)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: original))
        _ = throttle.requestCompleted(input: original)

        XCTAssertEqual(throttle.submit("今天下午四点开会"), .debounce)
    }

    func testCompletedSnapshotIsNotOptimizedAgain() {
        var throttle = SpeculativeLLMThrottle()
        let source = "同一份原始语音文本"
        XCTAssertEqual(throttle.submit(source), .debounce)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: source))
        _ = throttle.requestCompleted(input: source)

        XCTAssertEqual(throttle.submit(source), .duplicate)
    }

    func testNonconsecutiveSnapshotIsNotOptimizedAgain() {
        var throttle = SpeculativeLLMThrottle()
        let first = "第一份稳定语音文本"
        let second = "第二份稳定语音文本"

        XCTAssertEqual(throttle.submit(first), .debounce)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: first))
        _ = throttle.requestCompleted(input: first)
        XCTAssertEqual(throttle.submit(second), .debounce)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: second))
        _ = throttle.requestCompleted(input: second)

        XCTAssertEqual(throttle.submit(first), .duplicate)
    }
}
