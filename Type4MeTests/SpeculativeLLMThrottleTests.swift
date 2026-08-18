import XCTest
@testable import Type4Me

final class SpeculativeLLMThrottleTests: XCTestCase {
    func testMinimumTextLengthWaitsForMeaningfulShortPhrase() {
        var throttle = SpeculativeLLMThrottle()

        XCTAssertEqual(throttle.submit("测试呀"), .tooShort)
        XCTAssertEqual(throttle.submit("测试一下"), .debounce)
    }

    func testMinimumCharacterIncrementIsTwentyMeaningfulCharacters() {
        var throttle = SpeculativeLLMThrottle()
        let start = ContinuousClock.now
        let first = "测试一下"
        XCTAssertEqual(throttle.submit(first, now: start), .debounce)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: first, now: start))
        _ = throttle.requestCompleted(input: first)

        XCTAssertEqual(
            throttle.submit(first + String(repeating: "增", count: 19), now: start + .seconds(5)),
            .deltaTooSmall
        )
        XCTAssertEqual(
            throttle.submit(first + String(repeating: "增", count: 20), now: start + .seconds(5)),
            .debounce
        )
    }

    func testDebounceKeepsNewestCandidateBeforeRequestStarts() {
        var throttle = SpeculativeLLMThrottle()

        XCTAssertEqual(throttle.submit("测试一下"), .debounce)
        XCTAssertEqual(throttle.submit("换一份候选文本"), .debounce)

        XCTAssertFalse(throttle.beginDebouncedRequest(for: "测试一下"))
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "换一份候选文本"))
    }

    func testDoesNotRunConcurrentRequestsAndKeepsNewestPendingText() {
        var throttle = SpeculativeLLMThrottle()
        let start = ContinuousClock.now
        let first = "测试一下"
        let second = first + String(repeating: "二", count: 20)
        let latest = second + String(repeating: "三", count: 20)
        _ = throttle.submit(first, now: start)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: first, now: start))

        XCTAssertEqual(throttle.submit(second, now: start + .seconds(1)), .queued)
        XCTAssertEqual(throttle.submit(latest, now: start + .seconds(2)), .queued)
        XCTAssertFalse(throttle.beginDebouncedRequest(for: latest, now: start + .seconds(2)))

        XCTAssertEqual(throttle.requestCompleted(input: first), latest)
    }

    func testCooldownDefersNextRequestForFiveSeconds() {
        var throttle = SpeculativeLLMThrottle()
        let start = ContinuousClock.now
        let first = "测试一下"
        let second = first + String(repeating: "增", count: 20)
        _ = throttle.submit(first, now: start)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: first, now: start))
        _ = throttle.requestCompleted(input: first)

        XCTAssertEqual(
            throttle.submit(second, now: start + .seconds(2)),
            .cooldown(.seconds(3))
        )
        XCTAssertEqual(throttle.submit(second, now: start + .seconds(5)), .debounce)
    }

    func testExplicitCorrectionBypassesIncrementButNotCooldown() {
        var throttle = SpeculativeLLMThrottle()
        let start = ContinuousClock.now
        let original = "预算确定为三十万"
        let corrected = original + "，不对，改成五十万"
        _ = throttle.submit(original, now: start)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: original, now: start))
        _ = throttle.requestCompleted(input: original)

        XCTAssertEqual(
            throttle.submit(corrected, now: start + .seconds(2)),
            .cooldown(.seconds(3))
        )
        XCTAssertEqual(throttle.submit(corrected, now: start + .seconds(5)), .debounce)
    }

    func testSmallASRRewriteDoesNotBypassIncrement() {
        var throttle = SpeculativeLLMThrottle()
        let start = ContinuousClock.now
        let original = "今天下午三点开会"
        _ = throttle.submit(original, now: start)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: original, now: start))
        _ = throttle.requestCompleted(input: original)

        XCTAssertEqual(
            throttle.submit("今天下午四点开会", now: start + .seconds(5)),
            .deltaTooSmall
        )
    }

    func testWhitespaceAndPunctuationVariantsAreDuplicates() {
        var throttle = SpeculativeLLMThrottle()
        let start = ContinuousClock.now
        let source = "同一份原始语音文本"
        _ = throttle.submit(source, now: start)
        XCTAssertTrue(throttle.beginDebouncedRequest(for: source, now: start))
        _ = throttle.requestCompleted(input: source)

        XCTAssertEqual(
            throttle.submit("同一份 原始语音文本。", now: start + .seconds(5)),
            .duplicate
        )
    }

    func testSessionRequestCapStopsAfterThreePreviews() {
        var throttle = SpeculativeLLMThrottle()
        let start = ContinuousClock.now
        var text = "测试一下"
        for index in 0..<SpeculativeLLMThrottle.maximumRequestsPerSession {
            if index > 0 { text += String(repeating: "增", count: 20) }
            let now = start + .seconds(index * 5)
            XCTAssertEqual(throttle.submit(text, now: now), .debounce)
            XCTAssertTrue(throttle.beginDebouncedRequest(for: text, now: now))
            _ = throttle.requestCompleted(input: text)
        }

        let extra = text + String(repeating: "额", count: 20)
        XCTAssertEqual(throttle.submit(extra, now: start + .seconds(15)), .limitReached)
        XCTAssertEqual(throttle.requestCount, 3)
    }

    func testRateLimitCircuitSuppressesRemainingPreviewsUntilReset() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("测试一下")
        XCTAssertTrue(throttle.beginDebouncedRequest(for: "测试一下"))

        throttle.tripCircuit()

        XCTAssertTrue(throttle.isCircuitOpen)
        XCTAssertFalse(throttle.inFlight)
        XCTAssertEqual(throttle.submit("测试一下再补充很多内容"), .circuitOpen)

        throttle.reset()
        XCTAssertFalse(throttle.isCircuitOpen)
        XCTAssertEqual(throttle.submit("测试一下"), .debounce)
    }

    func testResetClearsRequestBudgetAndPendingState() {
        var throttle = SpeculativeLLMThrottle()
        _ = throttle.submit("测试一下")
        _ = throttle.beginDebouncedRequest(for: "测试一下")
        _ = throttle.submit("测试一下" + String(repeating: "增", count: 20))

        throttle.reset()

        XCTAssertFalse(throttle.inFlight)
        XCTAssertNil(throttle.pendingText)
        XCTAssertEqual(throttle.requestCount, 0)
        XCTAssertEqual(throttle.submit("测试一下"), .debounce)
    }
}
