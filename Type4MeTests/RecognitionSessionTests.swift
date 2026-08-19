import XCTest

@testable import Type4Me

private actor LLMInvocationCounter {
  private(set) var value = 0

  func increment() {
    value += 1
  }
}

final class RecognitionSessionTests: XCTestCase {
  override func tearDown() {
    CredentialStore.selectedASRProvider = .volcano
    UserDefaults.standard.removeObject(forKey: "tf_preserveCJKLatinSpacing")
  }

  func testInitialStateIsIdle() async {
    let session = RecognitionSession()
    let state = await session.state
    XCTAssertEqual(state, .idle)
  }

  func testSetState() async {
    let session = RecognitionSession()
    await session.setState(.recording)
    let state = await session.state
    XCTAssertEqual(state, .recording)
    await session.setState(.idle)
  }

  func testCanStartRecordingOnlyWhenIdle() async {
    let session = RecognitionSession()
    var canStart = await session.canStartRecording
    XCTAssertTrue(canStart)

    await session.setState(.recording)
    canStart = await session.canStartRecording
    XCTAssertFalse(canStart)

    await session.setState(.recovering)
    canStart = await session.canStartRecording
    XCTAssertFalse(canStart)
    await session.setState(.idle)
  }

  func testRecoveryHotkeyRequiresSecondPressToInterrupt() async {
    let session = RecognitionSession()
    await session.setState(.recovering)

    let first = await session.handleRecoveryHotkeyPress()
    XCTAssertEqual(first, .prompted)
    let stateAfterFirstPress = await session.state
    XCTAssertEqual(stateAfterFirstPress, .recovering)

    let second = await session.handleRecoveryHotkeyPress()
    XCTAssertEqual(second, .interrupted)
    let stateAfterSecondPress = await session.state
    XCTAssertEqual(stateAfterSecondPress, .idle)
  }

  func testSwitchModeAppliesToDirect() async {
    CredentialStore.selectedASRProvider = .volcano
    let session = RecognitionSession()

    await session.switchMode(to: .direct)

    let mode = await session.currentModeForTesting()
    XCTAssertEqual(mode.id, ProcessingMode.directId)
  }

  func testSwitchModeDirectWorksForSoniox() async {
    CredentialStore.selectedASRProvider = .soniox
    let session = RecognitionSession()

    await session.switchMode(to: .direct)

    let mode = await session.currentModeForTesting()
    XCTAssertEqual(mode.id, ProcessingMode.directId)
  }

  func testSwitchModeUpdatesActiveRecordingMode() async {
    CredentialStore.selectedASRProvider = .volcano
    let session = RecognitionSession()
    await session.setState(.recording)

    await session.switchMode(to: .formalWriting)

    let mode = await session.currentModeForTesting()
    XCTAssertEqual(mode.id, ProcessingMode.formalWritingId)
    await session.setState(.idle)
  }

  func testFinalPolishRequiresRequestForNonEmptyText() {
    let previous = UserDefaults.standard.object(forKey: "tf_shortTextExemption")
    UserDefaults.standard.set("50", forKey: "tf_shortTextExemption")
    defer {
      if let previous {
        UserDefaults.standard.set(previous, forKey: "tf_shortTextExemption")
      } else {
        UserDefaults.standard.removeObject(forKey: "tf_shortTextExemption")
      }
    }

    XCTAssertTrue(
      RecognitionSession.requiresFinalLLM(
        needsLLM: true,
        finalText: "短句"
      ))
    XCTAssertFalse(
      RecognitionSession.requiresFinalLLM(
        needsLLM: false,
        finalText: "最终 ASR 文本"
      ))
    XCTAssertFalse(
      RecognitionSession.requiresFinalLLM(
        needsLLM: true,
        finalText: "   "
      ))
  }

  func testConversationalMetaResponseIsRejectedUnlessPresentInSource() {
    XCTAssertTrue(
      RecognitionSession.isConversationalMetaResponse(
        "好的，我会按照上述规则对文本进行整理。",
        sourceText: "重新帮我设置一下 UI"
      ))
    XCTAssertFalse(
      RecognitionSession.isConversationalMetaResponse(
        "好的，下午 3 点的周会我能参加。",
        sourceText: "好的，下午三点的周会我能参加"
      ))
    XCTAssertFalse(
      RecognitionSession.isConversationalMetaResponse(
        "重新帮我设置一下 UI。",
        sourceText: "重新帮我设置一下 UI"
      ))
  }

  func testLLMRateLimitClassifierRecognizes429Only() {
    XCTAssertTrue(RecognitionSession.isLLMRateLimit(LLMError.requestFailed(429)))
    XCTAssertFalse(RecognitionSession.isLLMRateLimit(LLMError.requestFailed(500)))
  }

  func testShouldAttemptBatchFallbackWhenStreamingErrorWasObserved() {
    let shouldFallback = RecognitionSession.shouldAttemptBatchFallback(
      uploadFailed: false,
      asrTeardownClean: true,
      streamingError: DeepgramASRError.closed(code: 1008, reason: "policy violation")
    )

    XCTAssertTrue(shouldFallback)
  }

  // MARK: - CJK / Latin spacing (issue #186)

  /// The space between a CJK character and an adjacent Latin word or digit
  /// (Pangu spacing) must survive normalization. Regression test for #186,
  /// where "我已经把最新的 prompt 提交并更新" was collapsed to "...的prompt提交...".
  func testRemovingCJKLatinSpaces_preservesPanguSpacing() {
    UserDefaults.standard.set(true, forKey: "tf_preserveCJKLatinSpacing")

    // The reported case: CJK ↔ Latin spaces are kept.
    XCTAssertEqual(
      "我已经把最新的 prompt 提交并更新".removingCJKLatinSpaces,
      "我已经把最新的 prompt 提交并更新"
    )
    // CJK ↔ Latin word, both boundaries.
    XCTAssertEqual("Max 你好".removingCJKLatinSpaces, "Max 你好")
    XCTAssertEqual("发布 v1.9.5 版本".removingCJKLatinSpaces, "发布 v1.9.5 版本")
    // CJK ↔ digit.
    XCTAssertEqual("第 3 个".removingCJKLatinSpaces, "第 3 个")
    // Pure English is untouched.
    XCTAssertEqual("hello world".removingCJKLatinSpaces, "hello world")
  }

  /// Spaces between two CJK characters, or between a CJK character and
  /// punctuation, are ASR/LLM noise and must still be removed.
  func testRemovingCJKLatinSpaces_stripsCJKAndPunctuationNoise() {
    UserDefaults.standard.set(true, forKey: "tf_preserveCJKLatinSpacing")

    // CJK ↔ CJK noise from ASR token boundaries.
    XCTAssertEqual("你 好".removingCJKLatinSpaces, "你好")
    XCTAssertEqual("你  好".removingCJKLatinSpaces, "你好")
    // CJK ↔ punctuation (full-width and ASCII).
    XCTAssertEqual("你好 ，世界".removingCJKLatinSpaces, "你好，世界")
    XCTAssertEqual("你好 , 世界".removingCJKLatinSpaces, "你好,世界")
  }

  func testRemovingCJKLatinSpaces_canStripPanguSpacingWhenDisabled() {
    UserDefaults.standard.set(false, forKey: "tf_preserveCJKLatinSpacing")

    XCTAssertEqual(
      "我已经把最新的 prompt 提交并更新".removingCJKLatinSpaces,
      "我已经把最新的prompt提交并更新"
    )
    XCTAssertEqual("第 3 个".removingCJKLatinSpaces, "第3个")
  }

  // MARK: - Canonical live optimization state

  private func optimizationKey(
    text: String = "今天下午三点开会",
    prompt: String = "整理原文",
    modeID: UUID,
    model: String = "deepseek-v4-flash"
  ) -> OptimizationRequestKey {
    OptimizationRequestKey(
      text: text,
      prompt: prompt,
      modeID: modeID,
      provider: "deepseek",
      model: model,
      baseURL: "https://example.com"
    )
  }

  func testTranscriptRevisionKeepsFormattingOnlyRewriteOnSameRevision() {
    var tracker = TranscriptRevisionTracker()

    XCTAssertEqual(tracker.update("今天下午三点开会"), 1)
    XCTAssertEqual(tracker.update("今天下午三点，开会。"), 1)
    XCTAssertEqual(tracker.update("今天下午四点开会"), 2)
  }

  func testArtifactCannotBeRelabeledByNewerInFlightRequest() {
    let mode = UUID()
    let first = LiveOptimizationRequest(
      key: optimizationKey(modeID: mode),
      displaySourceText: "今天下午三点开会",
      sourceRevision: 1,
      modeID: mode
    )
    let second = LiveOptimizationRequest(
      key: optimizationKey(text: "今天下午四点开会", modeID: mode),
      displaySourceText: "今天下午四点开会",
      sourceRevision: 2,
      modeID: mode
    )
    var coordinator = LiveOptimizationCoordinator()

    coordinator.begin(first)
    XCTAssertNotNil(coordinator.complete(first, result: "三点开会。"))
    coordinator.begin(second)

    XCTAssertEqual(coordinator.committableArtifact(revision: 1, modeID: mode)?.result, "三点开会。")
    XCTAssertNil(coordinator.committableArtifact(revision: 2, modeID: mode))
    XCTAssertEqual(coordinator.matchingActiveRequest(revision: 2, modeID: mode), second)
  }

  func testReadyArtifactLocksOnlyMatchingRevisionAndMode() {
    let mode = UUID()
    let request = LiveOptimizationRequest(
      key: optimizationKey(modeID: mode),
      displaySourceText: "今天下午三点开会",
      sourceRevision: 7,
      modeID: mode
    )
    var coordinator = LiveOptimizationCoordinator()
    coordinator.begin(request)
    _ = coordinator.complete(request, result: "优化后的稿子。")

    XCTAssertEqual(
      coordinator.committableArtifact(revision: 7, modeID: mode)?.result,
      "优化后的稿子。"
    )
    XCTAssertNil(coordinator.committableArtifact(revision: 8, modeID: mode))
    XCTAssertNil(coordinator.committableArtifact(revision: 7, modeID: UUID()))
  }

  func testLLMResultCacheHitsWithinTTLAndExpires() {
    let mode = UUID()
    let key = optimizationKey(modeID: mode)
    let start = ContinuousClock.now
    var cache = LLMResultCache(ttl: .seconds(30), maximumEntryCount: 2)

    cache.insert("优化后的稿子。", for: key, now: start)

    XCTAssertEqual(cache.value(for: key, now: start + .seconds(29)), "优化后的稿子。")
    XCTAssertNil(cache.value(for: key, now: start + .seconds(30)))
  }

  func testLLMResultCacheKeyIncludesPromptAndModel() {
    let mode = UUID()
    let original = optimizationKey(modeID: mode)
    let changedPrompt = optimizationKey(prompt: "翻译原文", modeID: mode)
    let changedModel = optimizationKey(modeID: mode, model: "another-model")
    var cache = LLMResultCache()

    cache.insert("优化后的稿子。", for: original)

    XCTAssertNil(cache.value(for: changedPrompt))
    XCTAssertNil(cache.value(for: changedModel))
  }

  func testLLMRequestMemoizerCoalescesInFlightAndCachesCompletion() async throws {
    let mode = UUID()
    let key = optimizationKey(modeID: mode)
    let memoizer = LLMRequestMemoizer()
    let counter = LLMInvocationCounter()

    async let first = memoizer.value(for: key) {
      await counter.increment()
      try await Task.sleep(for: .milliseconds(50))
      return "唯一网络结果"
    }
    try await Task.sleep(for: .milliseconds(10))
    async let second = memoizer.value(for: key) {
      await counter.increment()
      return "不应执行"
  }

    let (firstLookup, secondLookup) = try await (first, second)
    XCTAssertEqual(firstLookup.result, "唯一网络结果")
    XCTAssertEqual(secondLookup.result, "唯一网络结果")
    XCTAssertEqual(Set([firstLookup.source, secondLookup.source]), Set([.network, .inFlight]))
    let countAfterJoin = await counter.value
    XCTAssertEqual(countAfterJoin, 1)

    let cached = try await memoizer.value(for: key) {
      await counter.increment()
      return "不应执行"
    }
    XCTAssertEqual(cached.source, .cache)
    XCTAssertEqual(cached.result, "唯一网络结果")
    let countAfterCache = await counter.value
    XCTAssertEqual(countAfterCache, 1)
  }
}
