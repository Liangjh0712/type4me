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
        UserDefaults.standard.set(RecordingVisualStyle.hidden.rawValue, forKey: RecordingVisualStyle.storageKey)
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
        XCTAssertEqual(appState.transcriptionText, "测试文本")
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

        appState.beginLiveOptimization(sourceText: "预算 30 万")
        appState.showLiveOptimizationResult("预算为 30 万。", sourceText: "预算 30 万")

        XCTAssertEqual(appState.liveOptimizationPhase, .ready)
        XCTAssertEqual(appState.liveOptimizedText, "预算为 30 万。")

        appState.setLiveTranscript(makeTranscript("预算 30 万，改成 50 万"))

        XCTAssertEqual(appState.liveOptimizationPhase, .stale)
        XCTAssertEqual(appState.liveOptimizedText, "预算为 30 万。")
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


    func testTranscriptArrivalReconcilesEarlyOptimizationResult() {
        let appState = AppState()
        appState.currentMode = .formalWriting
        appState.startRecording()
        appState.markRecordingReady()
        appState.setLiveTranscript(makeTranscript("第一版原文"))

        appState.showLiveOptimizationResult("第二版优化稿", sourceText: "第二版原文")
        XCTAssertEqual(appState.liveOptimizationPhase, .stale)

        appState.setLiveTranscript(makeTranscript("第二版原文"))

        XCTAssertEqual(appState.liveOptimizationPhase, .ready)
        XCTAssertEqual(appState.liveOptimizedText, "第二版优化稿")
    }
    private func makeTranscript(_ text: String) -> RecognitionTranscript {
        RecognitionTranscript(
            confirmedSegments: [text],
            partialText: "",
            authoritativeText: text,
            isFinal: false
        )
    }

    func testTranscriptDisplayDefaultsToExpanded() throws {
        let suiteName = "TranscriptDisplayModeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(TranscriptDisplayMode.current(userDefaults: defaults), .expanded)
        defaults.set(TranscriptDisplayMode.compact.rawValue, forKey: TranscriptDisplayMode.storageKey)
        XCTAssertEqual(TranscriptDisplayMode.current(userDefaults: defaults), .compact)
    }
}
