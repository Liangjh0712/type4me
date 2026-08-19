import XCTest

@testable import Type4Me

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

  func testFinalPolishAlwaysRequiresAuthoritativeRequestForNonEmptyText() {
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
      RecognitionSession.requiresAuthoritativeFinalLLM(
        needsLLM: true,
        finalText: "短句"
      ))
    XCTAssertFalse(
      RecognitionSession.requiresAuthoritativeFinalLLM(
        needsLLM: false,
        finalText: "最终 ASR 文本"
      ))
    XCTAssertFalse(
      RecognitionSession.requiresAuthoritativeFinalLLM(
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

  // MARK: - Speculative preview reuse at stop

  private func reuse(
    result: String? = "优化后的稿子。",
    source: String = "优化后的稿子",
    final: String = "优化后的稿子",
    speculativeMode: UUID? = UUID(),
    currentMode: UUID = UUID()
  ) -> String? {
    RecognitionSession.reusableSpeculativeResult(
      result: result,
      sourceText: source,
      finalText: final,
      speculativeModeID: speculativeMode,
      currentModeID: currentMode
    )
  }

  func testSpeculativePreviewReusedWhenTranscriptUnchanged() {
    let mode = UUID()
    XCTAssertEqual(
      reuse(source: "今天下午三点开会", final: "今天下午三点开会", speculativeMode: mode, currentMode: mode),
      "优化后的稿子。"
    )
  }

  func testSpeculativePreviewReusedWhenOnlyPunctuationDrifted() {
    let mode = UUID()
    XCTAssertEqual(
      reuse(source: "今天下午三点开会", final: "今天下午三点开会。", speculativeMode: mode, currentMode: mode),
      "优化后的稿子。"
    )
  }

  func testSpeculativePreviewNotReusedWhenTranscriptSemanticallyChanged() {
    let mode = UUID()
    XCTAssertNil(
      reuse(source: "今天下午三点开会", final: "今天下午四点开会", speculativeMode: mode, currentMode: mode)
    )
  }

  func testSpeculativePreviewNotReusedAfterModeSwitch() {
    XCTAssertNil(reuse(speculativeMode: UUID(), currentMode: UUID()))
  }

  func testSpeculativePreviewNotReusedWhenMissing() {
    let mode = UUID()
    XCTAssertNil(reuse(result: nil, speculativeMode: mode, currentMode: mode))
    XCTAssertNil(reuse(result: "", speculativeMode: mode, currentMode: mode))
    XCTAssertNil(reuse(source: "", speculativeMode: mode, currentMode: mode))
  }

  func testSpeculativePreviewNeverReusedForMacAction() {
    XCTAssertNil(
      reuse(speculativeMode: ProcessingMode.macActionId, currentMode: ProcessingMode.macActionId)
    )
  }
}
