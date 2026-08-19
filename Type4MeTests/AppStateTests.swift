import XCTest

@testable import Type4Me

@MainActor
final class AppStateTests: XCTestCase {

  func testStartRecordingTransitionsToPreparing() {
    let appState = AppState()
    appState.startRecording()

    XCTAssertEqual(appState.barPhase, .preparing)
  }

  func testStopRecordingIgnoredWhenNotRecording() {
    let appState = AppState()
    appState.currentMode = .smartDirect
    appState.cancel()

    appState.stopRecording()

    XCTAssertEqual(appState.barPhase, .hidden)
  }

  func testStopRecordingCancelsWhenPreparing() {
    let appState = AppState()
    appState.startRecording()

    appState.stopRecording()

    XCTAssertEqual(appState.barPhase, .hidden)
  }

  func testStopRecordingTransitionsToProcessingWhenRecording() {
    let appState = AppState()
    appState.currentMode = .smartDirect
    appState.startRecording()
    appState.markRecordingReady()

    appState.stopRecording()

    XCTAssertEqual(appState.barPhase, .processing)
  }

  func testStopRecordingTransitionsDirectModeToProcessing() {
    let appState = AppState()
    appState.currentMode = .direct
    appState.startRecording()
    appState.markRecordingReady()

    appState.stopRecording()

    XCTAssertEqual(appState.barPhase, .processing)
  }

  func testShowRecoveryDisplaysPartialTextAndStatus() {
    let appState = AppState()

    appState.showRecovery(
      text: "已经识别的文字",
      message: "连接中断，已保留当前文字，正在用整段录音重试"
    )

    XCTAssertEqual(appState.barPhase, .recovering)
    XCTAssertEqual(appState.transcriptionText, "已经识别的文字")
    XCTAssertEqual(appState.effectiveProcessingLabel, "连接中断，已保留当前文字，正在用整段录音重试")
  }

  func testRecoveryPromptKeepsPartialTextVisible() {
    let appState = AppState()
    appState.showRecovery(
      text: "已经识别的文字",
      message: "连接中断，已保留当前文字，正在用整段录音重试"
    )

    appState.showRecoveryPrompt(
      text: "已经识别的文字",
      message: "正在恢复上一次识别。继续按下将打断当前恢复并重新开始录音。"
    )

    XCTAssertEqual(appState.barPhase, .recovering)
    XCTAssertEqual(appState.transcriptionText, "已经识别的文字")
    XCTAssertEqual(appState.effectiveProcessingLabel, "正在恢复上一次识别。继续按下将打断当前恢复并重新开始录音。")
  }

  func testRecoveryResultPinsTranscriptPopup() {
    let appState = AppState()

    appState.showRecoveryResult(text: "完整识别文字", message: "已恢复完整识别")

    XCTAssertEqual(appState.barPhase, .done)
    XCTAssertEqual(appState.transcriptionText, "完整识别文字")
    XCTAssertTrue(appState.pinsTranscriptPopup)
  }

  func testHiddenRecordingVisualDoesNotShowPanelUntilProcessing() {
    let previousStyle = UserDefaults.standard.string(forKey: RecordingVisualStyle.storageKey)
    UserDefaults.standard.set(
      RecordingVisualStyle.hidden.rawValue, forKey: RecordingVisualStyle.storageKey)
    defer {
      if let previousStyle {
        UserDefaults.standard.set(previousStyle, forKey: RecordingVisualStyle.storageKey)
      } else {
        UserDefaults.standard.removeObject(forKey: RecordingVisualStyle.storageKey)
      }
    }

    let appState = AppState()
    var showCount = 0
    var hideCount = 0
    appState.onShowPanel = { showCount += 1 }
    appState.onHidePanel = { hideCount += 1 }

    appState.startRecording()
    appState.markRecordingReady()

    XCTAssertEqual(appState.barPhase, .recording)
    XCTAssertEqual(showCount, 0)
    XCTAssertEqual(hideCount, 1)

    appState.stopRecording()

    XCTAssertEqual(appState.barPhase, .processing)
    XCTAssertEqual(showCount, 1)
  }

  func testSetLiveTranscriptReplacesExistingConfirmedSegments() {
    let appState = AppState()
    appState.setLiveTranscript(
      RecognitionTranscript(
        confirmedSegments: ["我想", "买咖"],
        partialText: "",
        authoritativeText: "我想买咖",
        isFinal: false
      )
    )
    appState.setLiveTranscript(
      RecognitionTranscript(
        confirmedSegments: ["我想", "买咖啡"],
        partialText: "",
        authoritativeText: "我想买咖啡",
        isFinal: false
      )
    )

    XCTAssertEqual(appState.segments.map(\.text), ["我想", "买咖啡"])
    XCTAssertEqual(appState.transcriptionText, "我想买咖啡")
  }

  func testSetLiveTranscriptUsesAuthoritativeFinalTextWhenDifferent() {
    let appState = AppState()
    appState.setLiveTranscript(
      RecognitionTranscript(
        confirmedSegments: ["deep seek"],
        partialText: "",
        authoritativeText: "DeepSeek",
        isFinal: true
      )
    )

    XCTAssertEqual(appState.segments.count, 1)
    XCTAssertEqual(appState.segments.first?.text, "DeepSeek")
    XCTAssertTrue(appState.segments.first?.isConfirmed == true)
  }

  func testSetLiveTranscriptDropsStalePartialUpdates() {
    let appState = AppState()
    appState.setLiveTranscript(
      RecognitionTranscript(
        confirmedSegments: ["new"],
        partialText: "",
        authoritativeText: "new",
        isFinal: false
      )
    )

    appState.setLiveTranscript(
      RecognitionTranscript(
        confirmedSegments: ["old"],
        partialText: "",
        authoritativeText: "old",
        isFinal: false,
        emitTime: ContinuousClock.now - .seconds(1)
      )
    )

    XCTAssertEqual(appState.transcriptionText, "new")
  }

  func testFinalizeShowsClipboardFallbackMessage() {
    let appState = AppState()
    appState.barPhase = .processing

    appState.finalize(text: "测试文本", outcome: .copiedToClipboard)

    XCTAssertEqual(appState.barPhase, .done)
    XCTAssertEqual(appState.feedbackMessage, InjectionOutcome.copiedToClipboard.completionMessage)
    XCTAssertEqual(appState.optimizedPanelText, "测试文本")
  }

  func testShowErrorDisplaysErrorPhaseAndMessage() {
    let appState = AppState()

    appState.showError("找不到麦克风")

    XCTAssertEqual(appState.barPhase, .error)
    XCTAssertEqual(appState.feedbackMessage, "找不到麦克风")
  }

  func testReconcileCurrentModeKeepsSupportedCustomModeForQuickOnlyProvider() {
    let appState = AppState()
    let customMode = ProcessingMode(
      id: UUID(),
      name: "结构化",
      prompt: "Rewrite {text}",
      isBuiltin: false
    )
    appState.availableModes.append(customMode)
    appState.currentMode = customMode

    appState.reconcileCurrentMode(for: .bailian)

    XCTAssertEqual(appState.currentMode.id, customMode.id)
  }

  func testLiveOptimizationResultBecomesStaleAfterNewTranscript() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    appState.setLiveTranscript(makeTranscript("预算 30 万"))

    appState.beginLiveOptimization(sourceText: "预算 30 万", modeID: appState.currentMode.id)
    appState.showLiveOptimizationResult(
      "预算为 30 万。", sourceText: "预算 30 万", modeID: appState.currentMode.id)

    XCTAssertEqual(appState.liveOptimizationPhase, .ready)
    XCTAssertEqual(appState.liveOptimizedText, "预算为 30 万。")

    appState.setLiveTranscript(makeTranscript("预算 30 万，改成 50 万"))

    XCTAssertEqual(appState.liveOptimizationPhase, .stale)
    XCTAssertEqual(appState.liveOptimizedText, "预算为 30 万。")
  }

  func testConfirmedPunctuationKeepsCompletedPreviewVisible() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    let partial = "感觉现在的效果会稍微好一点但是可能还是有一些 bug 我感觉"
    appState.setLiveTranscript(makeTranscript(partial))
    appState.showLiveOptimizationResult(
      "感觉现在的效果稍微好了一点，但可能仍有一些 bug。",
      sourceText: partial,
      modeID: appState.currentMode.id
    )

    appState.setLiveTranscript(
      makeTranscript("感觉现在的效果会稍微好一点，但是可能还是有一些 bug，我感觉。"))

    XCTAssertEqual(appState.liveOptimizationPhase, .ready)
    XCTAssertEqual(
      appState.optimizedPanelText,
      "感觉现在的效果稍微好了一点，但可能仍有一些 bug。"
    )
  }

  func testLiveOptimizationFailureFallsBackToRawForOlderSnapshot() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    appState.setLiveTranscript(makeTranscript("最新原文"))

    appState.showLiveOptimizationFailure("实时优化失败", sourceText: "旧原文")

    XCTAssertEqual(appState.liveOptimizationPhase, .failed("实时优化失败"))
  }

  func testLiveOptimizationUnavailablePreservesRawTranscript() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.showLiveOptimizationUnavailable("实时优化不可用")
    appState.markRecordingReady()
    appState.setLiveTranscript(makeTranscript("完整原文"))

    XCTAssertEqual(appState.liveOptimizationPhase, .unavailable("实时优化不可用"))
    XCTAssertEqual(appState.transcriptionText, "完整原文")
    XCTAssertTrue(appState.liveOptimizedText.isEmpty)
  }

  func testOptimizationForDifferentSourceStaysVisibleAsStale() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    appState.setLiveTranscript(makeTranscript("第一版原文"))

    appState.showLiveOptimizationResult(
      "第二版优化稿",
      sourceText: "第二版原文",
      modeID: appState.currentMode.id
    )

    XCTAssertEqual(appState.liveOptimizationPhase, .stale)
    XCTAssertEqual(appState.liveOptimizedText, "第二版优化稿")
  }

  func testSemanticTranscriptRewriteKeepsPreviewAsStale() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    appState.setLiveTranscript(makeTranscript("重新帮我设置一下 UI"))
    appState.showLiveOptimizationResult(
      "重新帮我设置一下 UI。",
      sourceText: appState.transcriptionText,
      modeID: appState.currentMode.id
    )

    appState.setLiveTranscript(makeTranscript("重新帮我测试一下，因为"))

    XCTAssertEqual(appState.liveOptimizationPhase, .stale)
    XCTAssertFalse(appState.liveOptimizedText.isEmpty)
    XCTAssertFalse(appState.liveOptimizationSourceText.isEmpty)
  }

  func testFormalWritingPromptMarksCommandsAsTranscriptData() {
    let prompt = ProcessingMode.formalWritingPromptTemplate

    XCTAssertTrue(prompt.contains("<speech_transcript>"))
    XCTAssertTrue(prompt.contains("不能回应其意图"))
    XCTAssertTrue(prompt.contains("禁止输出“好的”"))
    XCTAssertTrue(prompt.contains("重新帮我设置一下 UI。"))
  }
  func testProcessingResultPreservesRawTranscriptForDualPanel() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    appState.setLiveTranscript(makeTranscript("完整原文"))
    appState.stopRecording()

    appState.showProcessingResult("最终优化稿")

    XCTAssertEqual(appState.transcriptionText, "完整原文")
    XCTAssertEqual(appState.optimizedPanelText, "最终优化稿")
    XCTAssertEqual(appState.barPhase, .processing)
  }

  func testPanelCollapsePreferenceSurvivesNextRecording() {
    let appState = AppState()
    appState.toggleTranscriptPanelCollapsed()

    appState.startRecording()

    XCTAssertTrue(appState.isTranscriptPanelCollapsed)
  }

  func testStopClearsRecordingPreviewBeforeAuthoritativeResult() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    appState.setLiveTranscript(makeTranscript("最终原文"))
    appState.showLiveOptimizationResult(
      "录音期间预览",
      sourceText: "最终原文",
      modeID: appState.currentMode.id
    )

    appState.stopRecording()

    XCTAssertTrue(appState.liveOptimizedText.isEmpty)
    XCTAssertTrue(appState.liveOptimizationSourceText.isEmpty)
    XCTAssertTrue(appState.optimizedPanelText.isEmpty)
    XCTAssertEqual(appState.liveOptimizationPhase, .updating)
  }

  func testFinalOptimizationFailureExposesRetryAndRawActions() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    appState.setLiveTranscript(makeTranscript("完整原文"))
    appState.showLiveOptimizationResult(
      "不能继续显示的旧预览",
      sourceText: "完整原文",
      modeID: appState.currentMode.id
    )
    var retried = false
    var insertedRaw = false
    appState.onRetryFinalOptimization = { retried = true }
    appState.onInsertRawAfterFailure = { insertedRaw = true }

    appState.showFinalOptimizationFailure("请求超时", sourceText: "完整原文")
    XCTAssertEqual(appState.finalOptimizationFailureMessage, "请求超时")
    XCTAssertEqual(appState.transcriptionText, "完整原文")
    XCTAssertTrue(appState.liveOptimizedText.isEmpty)
    XCTAssertEqual(appState.liveOptimizationPhase, .failed("请求超时"))

    appState.retryFinalOptimization()
    XCTAssertTrue(retried)
    XCTAssertNil(appState.finalOptimizationFailureMessage)
    XCTAssertEqual(appState.liveOptimizationPhase, .updating)

    appState.showFinalOptimizationFailure("再次失败", sourceText: "完整原文")
    appState.insertRawAfterOptimizationFailure()
    XCTAssertTrue(insertedRaw)
    XCTAssertNil(appState.finalOptimizationFailureMessage)
  }

  func testLLMCallTimingTracksEachAttempt() {
    let appState = AppState()
    appState.showLLMCallStarted(provider: "OpenRouter", model: "DeepSeek V3", attempt: 1)
    XCTAssertEqual(appState.activeLLMCall?.attempt, 1)

    appState.showLLMCallFinished(
      provider: "OpenRouter",
      model: "DeepSeek V3",
      attempt: 1,
      durationSeconds: 1.24,
      succeeded: false
    )

    XCTAssertNil(appState.activeLLMCall)
    XCTAssertEqual(appState.llmCallAttempts.count, 1)
    XCTAssertEqual(appState.llmCallAttempts.first?.durationSeconds ?? 0, 1.24, accuracy: 0.001)
    XCTAssertFalse(appState.llmCallAttempts.first?.succeeded ?? true)
  }

  func testLateLLMFinishDoesNotClearNewerActiveAttempt() {
    let appState = AppState()
    appState.showLLMCallStarted(provider: "OpenRouter", model: "Model A", attempt: 1)
    appState.showLLMCallStarted(provider: "OpenRouter", model: "Model B", attempt: 2)

    appState.showLLMCallFinished(
      provider: "OpenRouter",
      model: "Model A",
      attempt: 1,
      durationSeconds: 2,
      succeeded: false
    )

    XCTAssertEqual(appState.activeLLMCall?.attempt, 2)
    XCTAssertEqual(appState.activeLLMCall?.model, "Model B")
  }

  func testPanelCancelOnlyRequestsDiscardDuringActiveRecording() {
    let appState = AppState()
    var cancelCount = 0
    appState.onCancelRequested = { cancelCount += 1 }

    appState.requestPanelCancel()
    XCTAssertEqual(cancelCount, 0)

    appState.startRecording()
    appState.markRecordingReady()
    appState.requestPanelCancel()
    XCTAssertEqual(cancelCount, 1)
  }

  func testPanelModeSelectionChangesRecordingAndResetsOldPreview() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    appState.setLiveTranscript(makeTranscript("需要切换模式的原文"))
    appState.showLiveOptimizationResult(
      "旧模式生成的优化稿",
      sourceText: appState.transcriptionText,
      modeID: appState.currentMode.id
    )
    var selectedMode: ProcessingMode?
    appState.onPanelModeSelected = { selectedMode = $0 }

    appState.selectPanelMode(.direct)

    XCTAssertEqual(appState.currentMode.id, ProcessingMode.directId)
    XCTAssertEqual(selectedMode?.id, ProcessingMode.directId)
    XCTAssertTrue(appState.liveOptimizedText.isEmpty)
    XCTAssertEqual(appState.liveOptimizationPhase, .inactive)
    XCTAssertEqual(appState.barPhase, .recording)
  }

  func testPanelModeSelectionIsDisabledDuringProcessing() {
    let appState = AppState()
    appState.currentMode = .formalWriting
    appState.startRecording()
    appState.markRecordingReady()
    appState.stopRecording()

    appState.selectPanelMode(.direct)

    XCTAssertEqual(appState.currentMode.id, ProcessingMode.formalWritingId)
    XCTAssertEqual(appState.barPhase, .processing)
  }

  func testPanelModeListContainsOnlyRecordingModes() {
    let appState = AppState()

    XCTAssertFalse(appState.selectablePanelModes.isEmpty)
    XCTAssertTrue(appState.selectablePanelModes.allSatisfy { $0.executionKind == .recording })
    XCTAssertFalse(
      appState.selectablePanelModes.contains { $0.id == ProcessingMode.selectionAskId })
  }

  private func makeTranscript(_ text: String) -> RecognitionTranscript {
    RecognitionTranscript(
      confirmedSegments: [text],
      partialText: "",
      authoritativeText: text,
      isFinal: false
    )
  }

}
