import SwiftUI

/// Cached font for text measurement (module-level to avoid generic-type static restriction).
private let floatingBarFont = NSFont.systemFont(ofSize: 14, weight: .medium)

// MARK: - FloatingBarState Protocol

@MainActor
protocol FloatingBarState: AnyObject, Observable {
  var barPhase: FloatingBarPhase { get }
  var segments: [TranscriptionSegment] { get }
  var audioLevel: AudioLevelMeter { get }
  var currentMode: ProcessingMode { get }
  var selectablePanelModes: [ProcessingMode] { get }
  var feedbackMessage: String { get }
  var feedbackKind: FeedbackKind { get }
  var processingFinishTime: Date? { get }
  var transcriptionText: String { get }
  var recordingStartDate: Date? { get }
  var pinsTranscriptPopup: Bool { get }
  var liveOptimizedText: String { get }
  var liveOptimizationPhase: LiveOptimizationPhase { get }
  var supportsLiveOptimizationPreview: Bool { get }
  /// True when recording without SenseVoice streaming (Qwen3-only).
  var isQwen3OnlyMode: Bool { get }
  var effectiveProcessingLabel: String { get }
  var optimizedPanelText: String { get }
  var recordingStopDate: Date? { get }
  var pendingOptimizationTail: String { get }
  var processingResultText: String { get }
  var isTranscriptPanelCollapsed: Bool { get }
  var activeLLMCall: ActiveLLMCall? { get }
  var llmCallAttempts: [LLMCallAttempt] { get }
  var finalOptimizationFailureMessage: String? { get }
  func selectPanelMode(_ mode: ProcessingMode)
  func toggleTranscriptPanelCollapsed()
  func requestPanelStop()
  func requestPanelCancel()
  func retryFinalOptimization()
  func insertRawAfterOptimizationFailure()
}

/// Dark-themed floating transcription bar with smooth morphing between states.
///
/// Design: single capsule container that animates width + content transitions.
/// - Recording: audio-reactive dot + live text + timer, breathing border
/// - Processing: rotating orb with breathing glow + "AI" badge
/// - Done: full progress bar + centered text
struct FloatingBarView<S: FloatingBarState>: View {

  let state: S
  let expandedPanelWidth: CGFloat

  init(
    state: S,
    expandedPanelWidth: CGFloat = TF.topTranscriptPanelMaxWidth
  ) {
    self.state = state
    self.expandedPanelWidth = expandedPanelWidth
  }

  @State private var breathe = false
  @State private var doneGlow = true
  /// High-water mark: only grows during recording, never shrinks (prevents ASR correction jitter)
  @State private var recordingPeakWidth: CGFloat = TF.barHeight
  @State private var processingStartDate: Date?
  @State private var doneStartDate: Date?
  @AppStorage(RecordingPanelPreference.storageKey) private var showsRecordingPanel = true

  // MARK: - Transcript Popup

  private var showExpandedRecording: Bool {
    if state.finalOptimizationFailureMessage != nil { return true }
    guard showsRecordingPanel else { return false }
    switch state.barPhase {
    case .preparing, .recording, .processing:
      return true
    case .done, .error:
      return !state.transcriptionText.isEmpty || !state.optimizedPanelText.isEmpty
    case .recovering, .hidden:
      return false
    }
  }

  private var shouldRenderCapsule: Bool {
    guard state.barPhase != .hidden else { return false }
    if showExpandedRecording { return false }
    if !showsRecordingPanel,
      state.barPhase == .preparing || state.barPhase == .recording
    {
      return false
    }
    return true
  }

  private var showTranscriptPopup: Bool {
    if state.pinsTranscriptPopup || state.barPhase == .recovering {
      return !state.segments.isEmpty
    }
    return false
  }

  private var capsuleWidth: CGFloat {
    switch state.barPhase {
    case .preparing:
      return TF.barHeight
    case .recording:
      if state.segments.isEmpty {
        return state.isQwen3OnlyMode ? 110 : TF.barHeight
      }
      return recordingPeakWidth
    case .processing:
      return measureText(state.effectiveProcessingLabel) + 66.0
    case .recovering:
      return min(TF.barWidth, measureText(state.effectiveProcessingLabel) + 86.0)
    case .done:
      return feedbackWidth(for: state.feedbackMessage)
    case .error:
      return feedbackWidth(for: state.feedbackMessage)
    case .hidden:
      return TF.barHeight
    }
  }

  var body: some View {
    Group {
      if showExpandedRecording {
        expandedRecordingCard
          .transition(.opacity)
      } else {
        VStack(spacing: TF.transcriptPopupGap) {
          if showTranscriptPopup {
            transcriptPopup
              .transition(.opacity)
          }
          if shouldRenderCapsule {
            capsuleBar
              .transition(.opacity)
          }
        }
      }
    }
    .fixedSize(horizontal: true, vertical: true)
    .padding(TF.topTranscriptPanelOuterInset / 2)
    .animation(TF.easeQuick, value: state.barPhase)
    .animation(TF.easeQuick, value: state.isTranscriptPanelCollapsed)
    .onChange(of: state.barPhase) { _, newPhase in
      handlePhaseChange(newPhase)
    }
  }

  // MARK: - Capsule Container

  private var capsuleBar: some View {
    barContent
      .animation(TF.springSnappy, value: state.barPhase)
      .frame(width: capsuleWidth, height: TF.barHeight)
      .clipShape(Capsule())
      .background {
        capsuleBackground
          .clipShape(Capsule())
      }
      .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 3)
      .animation(TF.springSnappy, value: state.barPhase)
  }

  // MARK: - Content by Phase

  @ViewBuilder
  private var barContent: some View {
    switch state.barPhase {
    case .preparing:
      preparingContent
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.92).combined(with: .opacity),
            removal: .opacity
          ))
    case .recording:
      recordingContent
        .transition(
          .asymmetric(
            insertion: .opacity,
            removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)
          ))
    case .processing:
      processingContent
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.85).combined(with: .opacity),
            removal: .scale(scale: 0.9).combined(with: .opacity)
          ))
    case .recovering:
      recoveringContent
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.85).combined(with: .opacity),
            removal: .scale(scale: 0.9).combined(with: .opacity)
          ))
    case .done:
      doneContent
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.85).combined(with: .opacity),
            removal: .opacity
          ))
    case .error:
      errorContent
        .transition(
          .asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .opacity
          ))
    case .hidden:
      EmptyView()
    }
  }

  private var preparingContent: some View {
    HStack(spacing: 0) {
      PreparingDot()
    }
    .frame(maxWidth: .infinity)
  }

  private var recordingContent: some View {
    HStack(spacing: 10) {
      // Module 1: dot (fixed position, 14pt from left edge)
      RecordingDot(meter: state.audioLevel)

      // Module 2: text container (fills remaining space, grows with frame)
      // Uses overlay so text sizing never affects HStack layout
      if state.segments.isEmpty && state.isQwen3OnlyMode {
        Text(L("录音中", "Recording"))
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.white)
      } else if !state.segments.isEmpty {
        Color.clear
          .overlay(alignment: .trailing) {
            Text(state.transcriptionText)
              .font(.system(size: 14, weight: .medium))
              .foregroundStyle(.white)
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
          }
          .mask {
            if recordingPeakWidth >= TF.barWidth {
              HStack(spacing: 0) {
                LinearGradient(
                  colors: [.clear, .white],
                  startPoint: .leading,
                  endPoint: .trailing
                )
                .frame(width: 12)
                Rectangle()
              }
            } else {
              Rectangle()
            }
          }
          .padding(.trailing, 4)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .padding(.horizontal, 14)
  }

  private var processingContent: some View {
    ZStack {
      Text(state.effectiveProcessingLabel)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
    }
    .frame(maxWidth: .infinity)
  }

  private var recoveringContent: some View {
    HStack(spacing: 10) {
      PreparingDot()

      Text(state.effectiveProcessingLabel)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 14)
  }

  private var doneContent: some View {
    Group {
      if let icon = feedbackIcon {
        HStack(spacing: 10) {
          Image(systemName: icon.symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(icon.color)
          Text(state.feedbackMessage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
      } else {
        Text(state.feedbackMessage)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
      }
    }
  }

  private var errorContent: some View {
    HStack(spacing: 10) {
      if let icon = feedbackIcon {
        Image(systemName: icon.symbol)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(icon.color)
      } else {
        ErrorDot()
      }

      Text(state.feedbackMessage)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
        .lineLimit(1)
    }
    .padding(.horizontal, 14)
  }

  /// SF Symbol + tint for the current feedback kind, or nil for the standard
  /// look (no leading icon, centered text — the existing `.done`/`.error` UI).
  private var feedbackIcon: (symbol: String, color: Color)? {
    switch state.feedbackKind {
    case .standard:
      return nil
    case .macActionSuccess:
      return ("checkmark.circle.fill", TF.success)
    case .macActionFailure:
      return ("xmark.circle.fill", TF.settingsAccentRed)
    case .macActionUnsure:
      return ("questionmark.circle.fill", TF.amber)
    }
  }

  // MARK: - Expanded Live Transcript

  private var expandedRecordingCard: some View {
    let width =
      state.isTranscriptPanelCollapsed
      ? TF.topTranscriptPanelCollapsedWidth
      : expandedPanelWidth

    return VStack(spacing: 0) {
      topPanelHeader
      if !state.isTranscriptPanelCollapsed {
        meterBridge
        topPanelColumns
      }
    }
    .frame(width: width)
    .background(deckGlassBackground)
    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(TF.deckLineStrong, lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.30), radius: 22, y: 9)
    .shadow(color: .black.opacity(0.20), radius: 5, y: 2)
  }

  // MARK: - Meter Bridge

  /// Live VU hairline strip between the channel strip and the transcript columns.
  private var meterBridge: some View {
    MeterBridge(meter: state.audioLevel, active: state.barPhase == .recording)
      .frame(height: TF.topTranscriptPanelMeterBridgeHeight)
      .background(Color.black.opacity(0.22))
      .overlay(alignment: .top) { Rectangle().fill(TF.deckLine).frame(height: 1) }
      .overlay(alignment: .bottom) { Rectangle().fill(TF.deckLine).frame(height: 1) }
  }

  private var topPanelHeader: some View {
    HStack(spacing: 10) {
      deckTally

      headerHairline

      panelModeMenu

      headerHairline

      llmTimingStatus

      Spacer(minLength: 4)

      topPanelButton(
        systemName: state.isTranscriptPanelCollapsed ? "chevron.down" : "chevron.up",
        accessibilityLabel: state.isTranscriptPanelCollapsed
          ? L("展开面板", "Expand panel")
          : L("收缩面板", "Collapse panel")
      ) {
        state.toggleTranscriptPanelCollapsed()
      }

      if state.barPhase == .recording || state.barPhase == .preparing {
        topPanelButton(
          systemName: "xmark",
          accessibilityLabel: L("撤销并丢弃本次录音", "Cancel and discard this recording")
        ) {
          state.requestPanelCancel()
        }

        topPanelButton(
          systemName: "stop.fill",
          accessibilityLabel: L("停止并插入", "Stop and insert"),
          tint: TF.recording
        ) {
          state.requestPanelStop()
        }
      }
    }
    .padding(.horizontal, 12)
    .frame(
      height: state.isTranscriptPanelCollapsed
        ? TF.topTranscriptPanelCollapsedHeaderHeight
        : TF.topTranscriptPanelHeaderHeight
    )
    .background(
      LinearGradient(
        colors: [.white.opacity(0.035), .black.opacity(0.10)],
        startPoint: .top,
        endPoint: .bottom
      )
    )
  }

  /// Phase status cluster at the left of the channel strip:
  /// tally lamp + mono label + recording clock.
  @ViewBuilder
  private var deckTally: some View {
    HStack(spacing: 7) {
      switch state.barPhase {
      case .preparing, .recording:
        TallyDot()
        tallyLabel(L("录音", "REC"))
      case .done:
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 11))
          .foregroundStyle(TF.success)
        tallyLabel(L("完成", "DONE"))
      case .error:
        Image(systemName: "exclamationmark.circle.fill")
          .font(.system(size: 11))
          .foregroundStyle(TF.settingsAccentRed)
        tallyLabel(L("失败", "ERROR"))
      case .processing, .recovering:
        if state.finalOptimizationFailureMessage != nil {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 11))
            .foregroundStyle(TF.settingsAccentRed)
          tallyLabel(L("失败", "ERROR"))
        } else {
          PreparingDot(color: TF.signalTeal)
            .scaleEffect(0.5)
            .frame(width: 12, height: 12)
          tallyLabel(L("优化", "PROC"))
        }
      case .hidden:
        EmptyView()
      }
    }
  }

  private func tallyLabel(_ label: String) -> some View {
    HStack(spacing: 6) {
      Text(label)
      if let startDate = state.recordingStartDate {
        RecordingTimer(
          startDate: startDate,
          endDate: state.barPhase == .recording || state.barPhase == .preparing
            ? nil : state.recordingStopDate
        )
        .foregroundStyle(TF.paper)
      }
    }
    .font(.system(size: 10, weight: .semibold, design: .monospaced))
    .tracking(1.2)
    .foregroundStyle(TF.paperDim)
    .lineLimit(1)
    .fixedSize()
  }

  private var headerHairline: some View {
    Rectangle()
      .fill(TF.deckLine)
      .frame(width: 1, height: 14)
  }

  private var panelModeMenu: some View {
    Menu {
      ForEach(state.selectablePanelModes) { mode in
        Button {
          state.selectPanelMode(mode)
        } label: {
          HStack {
            if mode.id == state.currentMode.id {
              Image(systemName: "checkmark")
            }
            Text(mode.name)
            if let shortcut = modeShortcutLabel(mode) {
              Spacer()
              Text(shortcut)
            }
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        Text(state.currentMode.name)
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
          .tracking(1.2)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .bold))
          .opacity(canSelectPanelMode ? 0.6 : 0.25)
      }
      .foregroundStyle(TF.paper.opacity(canSelectPanelMode ? 1 : 0.55))
      .padding(.horizontal, 9)
      .frame(height: 22)
      .background {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(
            LinearGradient(
              colors: [TF.ink2, TF.ink1],
              startPoint: .top,
              endPoint: .bottom
            )
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .stroke(TF.deckLine, lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(!canSelectPanelMode)
    .accessibilityLabel(L("切换处理模式", "Switch processing mode"))
  }

  private var canSelectPanelMode: Bool {
    state.barPhase == .preparing || state.barPhase == .recording
  }

  private func modeShortcutLabel(_ mode: ProcessingMode) -> String? {
    guard let binding = mode.hotkeyBindings.first else { return nil }
    return HotkeyRecorderView.keyDisplayName(
      keyCode: binding.keyCode,
      modifiers: binding.modifiers
    )
  }

  private var emptyPreviewStatusLabel: String? {
    guard state.optimizedPanelText.isEmpty else { return nil }
    if state.transcriptionText.isEmpty {
      return L("等待语音", "WAITING FOR SPEECH")
    }
    return state.liveOptimizationPhase.statusLabel
  }

  @ViewBuilder
  private var llmTimingStatus: some View {
    if let active = state.activeLLMCall {
      TimelineView(.periodic(from: .now, by: 0.1)) { context in
        let elapsed = max(0, context.date.timeIntervalSince(active.startedAt))
        deckStatus(
          led: TF.lampAmber,
          ledOpacity: 0.55 + 0.45 * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4)),
          text: state.isTranscriptPanelCollapsed ? active.model : "\(active.provider) / \(active.model)",
          trailing: String(format: "%.2fs", elapsed),
          tone: TF.lampAmber.opacity(0.9)
        )
      }
    } else if let status = emptyPreviewStatusLabel {
      deckStatus(
        led: TF.paper.opacity(0.25),
        ledOpacity: 1,
        text: status,
        trailing: nil,
        tone: TF.paperFaint
      )
    } else if let attempt = state.llmCallAttempts.last {
      deckStatus(
        led: attempt.succeeded ? TF.signalTeal : TF.settingsAccentRed,
        ledOpacity: 1,
        text: state.isTranscriptPanelCollapsed
          ? attempt.model : "\(attempt.provider) / \(attempt.model)",
        trailing: String(format: "%.2fs", attempt.durationSeconds),
        tone: attempt.succeeded ? TF.paperDim : TF.settingsAccentRed
      )
    } else {
      deckStatus(
        led: TF.paper.opacity(0.25),
        ledOpacity: 1,
        text: state.effectiveProcessingLabel,
        trailing: nil,
        tone: TF.paperFaint
      )
    }
  }

  /// Mono LED + label + optional tabular reading, used in the channel strip.
  private func deckStatus(
    led: Color,
    ledOpacity: Double,
    text: String,
    trailing: String?,
    tone: Color
  ) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(led)
        .opacity(ledOpacity)
        .frame(width: 5, height: 5)
        .shadow(color: led.opacity(0.8), radius: 2.5)
      Text(text)
        .lineLimit(1)
      if let trailing {
        Text(trailing)
          .monospacedDigit()
      }
    }
    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
    .tracking(0.5)
    .foregroundStyle(tone)
  }

  private var topPanelColumns: some View {
    let dividerWidth: CGFloat = 1
    let leftWidth = (expandedPanelWidth - dividerWidth) * 0.45
    let rightWidth = expandedPanelWidth - dividerWidth - leftWidth

    return HStack(alignment: .top, spacing: 0) {
      topPanelColumn(
        title: L("原文", "RAW"),
        metadata: L("实时转写", "LIVE"),
        tone: .live,
        width: leftWidth,
        content: rawPanelText,
        isOptimized: false
      )

      Rectangle()
        .fill(TF.deckLine)
        .frame(width: dividerWidth)
        .frame(maxHeight: .infinity)

      topPanelColumn(
        title: L("优化稿", "EDIT"),
        metadata: optimizedColumnStatus,
        tone: optimizedMetaTone,
        width: rightWidth,
        content: optimizedPanelText,
        isOptimized: true
      )
    }
  }

  private var rawPanelText: Text {
    let fullText = state.transcriptionText
    let pending = state.pendingOptimizationTail
    guard !pending.isEmpty, fullText.hasSuffix(pending) else {
      return Text(fullText.isEmpty ? L("等待语音…", "Waiting for speech…") : fullText)
    }
    let stable = String(fullText.dropLast(pending.count))
    return Text(stable) + Text(pending).foregroundColor(TF.amber)
  }

  private var optimizedPanelText: Text {
    if state.supportsLiveOptimizationPreview {
      let text = state.optimizedPanelText
      if !text.isEmpty { return Text(text) }
      switch state.liveOptimizationPhase {
      case .waiting, .stale:
        return Text(
          state.transcriptionText.isEmpty
            ? L("等待语音…", "Waiting for speech…")
            : L("等待停顿后优化…", "Waiting for a pause to optimize…")
        )
      case .updating:
        return Text(L("正在生成优化稿…", "Generating optimized text…"))
      case .unavailable(let message), .failed(let message):
        return Text(message)
      case .ready:
        return Text(L("等待优化结果…", "Waiting for optimization result…"))
      case .inactive:
        return Text(L("此模式不支持实时优化", "Live optimization is unavailable for this mode"))
      }
    }
    let direct =
      state.processingResultText.isEmpty ? state.transcriptionText : state.processingResultText
    return Text(direct.isEmpty ? L("此模式将直接插入原文", "This mode inserts the raw transcript") : direct)
  }

  private var optimizedColumnStatus: String {
    if state.finalOptimizationFailureMessage != nil {
      return L("优化失败", "FAILED")
    }
    if !state.pendingOptimizationTail.isEmpty {
      return L("待更新", "UPDATE PENDING")
    }
    switch state.liveOptimizationPhase {
    case .waiting:
      return L("等待停顿", "WAITING")
    case .stale:
      return L("待更新", "UPDATE PENDING")
    case .updating:
      return L("优化中", "UPDATING")
    case .ready:
      return L("已同步", "CURRENT")
    case .unavailable:
      return L("不可用", "UNAVAILABLE")
    case .failed:
      return L("优化失败", "FAILED")
    case .inactive:
      return L("原文", "RAW")
    }
  }

  private enum DeckMetaTone {
    case live, working, ok, failed, idle

    var ledColor: Color {
      switch self {
      case .live, .ok: return TF.signalTeal
      case .working: return TF.lampAmber
      case .failed: return TF.settingsAccentRed
      case .idle: return TF.paper.opacity(0.25)
      }
    }

    var pulsing: Bool { self == .working }

    var textColor: Color {
      switch self {
      case .working: return TF.lampAmber.opacity(0.85)
      case .failed: return TF.settingsAccentRed.opacity(0.9)
      default: return TF.paperFaint
      }
    }
  }

  private var optimizedMetaTone: DeckMetaTone {
    if state.finalOptimizationFailureMessage != nil { return .failed }
    switch state.liveOptimizationPhase {
    case .updating: return .working
    case .ready: return .ok
    case .failed, .unavailable: return .failed
    case .waiting, .stale, .inactive: return .idle
    }
  }

  private func topPanelColumn(
    title: String,
    metadata: String,
    tone: DeckMetaTone,
    width: CGFloat,
    content: Text,
    isOptimized: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(title.uppercased())
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
          .tracking(2.2)
          .foregroundStyle(TF.paperFaint)
        Spacer()
        StatusLED(color: tone.ledColor, pulsing: tone.pulsing)
        Text(metadata)
          .font(.system(size: 8.5, weight: .medium, design: .monospaced))
          .tracking(1)
          .foregroundStyle(tone.textColor)
      }
      .padding(.horizontal, TF.topTranscriptPanelHorizontalPadding)
      .frame(height: TF.topTranscriptPanelColumnHeaderHeight)
      .overlay(alignment: .bottom) {
        Rectangle().fill(TF.deckLine).frame(height: 1)
      }

      content
        .font(.system(size: TF.topTranscriptPanelBodyFontSize, weight: .regular))
        .foregroundStyle(isOptimized ? TF.paper.opacity(0.85) : TF.paperDim)
        .lineSpacing(TF.topTranscriptPanelBodyLineSpacing)
        .textSelection(.disabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.horizontal, TF.topTranscriptPanelHorizontalPadding)
        .padding(.top, TF.topTranscriptPanelBodyTopPadding)
        .padding(.bottom, TF.topTranscriptPanelBodyBottomPadding)

      if isOptimized, let failure = state.finalOptimizationFailureMessage {
        finalOptimizationFailureActions(message: failure)
      }
    }
    .frame(width: width, alignment: .topLeading)
    .background(Color.white.opacity(isOptimized ? 0.016 : 0.004))
  }

  private func finalOptimizationFailureActions(message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 7) {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(TF.settingsAccentRed)
        VStack(alignment: .leading, spacing: 2) {
          Text(L("优化失败，原文仍已保留", "Optimization failed; raw text is retained"))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(TF.paper)
          Text(message)
            .font(.system(size: 9))
            .foregroundStyle(TF.paperFaint)
        }
      }

      ForEach(state.llmCallAttempts.filter { !$0.succeeded }) { attempt in
        HStack {
          Text("#\(attempt.attempt) · \(attempt.provider) / \(attempt.model)")
          Spacer()
          Text(String(format: "%.2fs", attempt.durationSeconds))
            .monospacedDigit()
        }
        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
        .foregroundStyle(TF.paper.opacity(0.30))
      }

      HStack(spacing: 8) {
        Button(L("重试优化", "Retry optimization")) {
          state.retryFinalOptimization()
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(TF.ink0.opacity(0.9))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(TF.lampAmber))

        Button(L("插入原文", "Insert raw text")) {
          state.insertRawAfterOptimizationFailure()
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(TF.paperDim)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.04)))
        .overlay {
          RoundedRectangle(cornerRadius: 6).stroke(TF.deckLineStrong, lineWidth: 1)
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(TF.settingsAccentRed.opacity(0.05))
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(TF.settingsAccentRed.opacity(0.22), lineWidth: 1)
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
  }

  private func topPanelButton(
    systemName: String,
    accessibilityLabel: String,
    tint: Color = TF.paperFaint,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 8.5, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.05)))
        .overlay {
          RoundedRectangle(cornerRadius: 5, style: .continuous)
            .stroke(TF.deckLine, lineWidth: 1)
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }

  /// Signal Desk glass: teal-ink gradient over frosted material with a top sheen.
  private var deckGlassBackground: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
      LinearGradient(
        colors: [
          TF.ink3.opacity(0.82),
          TF.ink1.opacity(0.92),
          TF.ink0.opacity(0.96),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      LinearGradient(
        colors: [.white.opacity(0.05), .clear],
        startPoint: .top,
        endPoint: UnitPoint(x: 0.5, y: 0.4)
      )
    }
  }

  // MARK: - Background & Border

  /// Dark frosted-glass fill shared by the capsule and the transcript popup.
  /// Shape-agnostic: the caller clips it (Capsule / RoundedRectangle).
  private var glassBackground: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
      LinearGradient(
        colors: [
          Color(red: 0.08, green: 0.10, blue: 0.12).opacity(0.22),
          Color(red: 0.025, green: 0.03, blue: 0.04).opacity(0.36),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
      LinearGradient(
        colors: [.white.opacity(0.07), .clear],
        startPoint: .top,
        endPoint: .center
      )
    }
  }

  private var capsuleBackground: some View {
    ZStack {
      glassBackground

      if state.barPhase == .processing || state.barPhase == .recovering || state.barPhase == .done {
        ProcessingProgress(
          finishTime: state.processingFinishTime,
          processingStartDate: processingStartDate,
          doneStartDate: doneStartDate
        )
        .transition(.opacity)
      }

      if state.barPhase == .error {
        LinearGradient(
          colors: [TF.settingsAccentRed.opacity(0.16), .clear],
          startPoint: .leading,
          endPoint: UnitPoint(x: 0.45, y: 0.5)
        )
        .transition(.opacity)
      }
    }
  }

  private var capsuleBorder: some View {
    Capsule()
      .stroke(borderColor, lineWidth: 1)
  }

  private var borderColor: Color {
    switch state.barPhase {
    case .preparing:
      .white.opacity(0.08)
    case .recording:
      .white.opacity(breathe ? 0.20 : 0.10)
    case .processing:
      .white.opacity(0.12)
    case .recovering:
      .white.opacity(0.16)
    case .done:
      switch state.feedbackKind {
      case .macActionUnsure:
        TF.amber.opacity(0.30)
      case .macActionSuccess, .macActionFailure, .standard:
        TF.success.opacity(doneGlow ? 0.3 : 0.08)
      }
    case .error:
      TF.settingsAccentRed.opacity(0.22)
    case .hidden:
      .clear
    }
  }

  // MARK: - Phase Transitions

  private func handlePhaseChange(_ phase: FloatingBarPhase) {
    switch phase {
    case .preparing:
      recordingPeakWidth = TF.barHeight
      processingStartDate = nil
      doneStartDate = nil
      breathe = false
      withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
        breathe = true
      }
    case .recording:
      recordingPeakWidth = TF.barHeight
      breathe = false
      withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
        breathe = true
      }
    case .processing:
      processingStartDate = Date()
      doneStartDate = nil
      breathe = false
    case .recovering:
      processingStartDate = Date()
      doneStartDate = nil
      breathe = false
    case .done:
      doneStartDate = Date()
      breathe = false
      doneGlow = true
      withAnimation(.easeOut(duration: 1.0)) { doneGlow = false }
    case .error:
      breathe = false
      doneGlow = false
    default:
      breathe = false
    }
  }

  private func feedbackWidth(for message: String) -> CGFloat {
    // Reserve extra room when an SF Symbol icon is shown (icon + spacing).
    let iconExtra: CGFloat = feedbackIcon == nil ? 0 : 26
    return measureText(message) + 66.0 + iconExtra
  }

  /// Measure actual rendered width using the same font as the floating bar text.
  private func measureText(_ string: String) -> CGFloat {
    ceil((string as NSString).size(withAttributes: [.font: floatingBarFont]).width)
  }

  // MARK: - Transcript Popup View

  private var transcriptPopup: some View {
    ScrollView(.vertical) {
      Text(state.transcriptionText)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
    .frame(width: TF.barWidth)
    .frame(maxHeight: TF.transcriptPopupMaxHeight)
    .background(glassBackground)
    .clipShape(RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous))
    .shadow(color: Color.black.opacity(0.3), radius: 8, y: -2)
  }
}

// MARK: - Preparing Dot

struct PreparingDot: View {

  var color: Color = TF.recording
  @State private var rotation = 0.0

  var body: some View {
    ZStack {
      Circle()
        .stroke(color.opacity(0.16), lineWidth: 1.6)
        .frame(width: 14, height: 14)

      Circle()
        .trim(from: 0.16, to: 0.76)
        .stroke(
          color,
          style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
        )
        .frame(width: 14, height: 14)
        .rotationEffect(.degrees(rotation))
    }
    .frame(width: 24, height: 24)
    .onAppear {
      rotation = 0
      withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
        rotation = 360
      }
    }
  }
}

// MARK: - Tally Dot

/// Pulsing red lamp shown in the deck header while recording.
struct TallyDot: View {

  @State private var pulse = false

  var body: some View {
    Circle()
      .fill(TF.recording)
      .frame(width: 8, height: 8)
      .shadow(color: TF.recording.opacity(0.9), radius: pulse ? 5 : 2)
      .opacity(pulse ? 1 : 0.55)
      .onAppear {
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
          pulse = true
        }
      }
  }
}

// MARK: - Status LED

/// 5pt indicator LED used by deck column headers.
struct StatusLED: View {

  let color: Color
  var pulsing: Bool = false
  @State private var lit = false

  var body: some View {
    Circle()
      .fill(color.opacity(pulsing && !lit ? 0.35 : 1))
      .frame(width: 5, height: 5)
      .shadow(color: color.opacity(0.8), radius: 3)
      .onAppear {
        guard pulsing else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
          lit = true
        }
      }
  }
}

// MARK: - Meter Bridge

/// Scrolling VU tick strip: right edge is now, history drifts left.
struct MeterBridge: View {

  let meter: AudioLevelMeter
  var active: Bool = true

  @State private var smoother = LevelSmoother(timeConstant: 0.09)
  @State private var history = LevelTimeline(bufferSize: 320, scrollSpeed: 110)

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      Canvas { context, size in
        let time = timeline.date.timeIntervalSinceReferenceDate
        smoother.target = max(0.005, CGFloat(max(0, min(1, meter.current))))
        let level = smoother.update(time: time)
        let levels = history.update(time: time, currentLevel: level)

        let step: CGFloat = 3
        let columns = max(1, Int(size.width / step))
        let base = size.height * 0.5
        let bufCount = levels.count

        for i in 0..<columns {
          let histIdx = min(Int(CGFloat(i) / CGFloat(columns) * CGFloat(bufCount - 1)), bufCount - 1)
          let amp = pow(max(0, (levels[histIdx] - 0.015) / 0.7), 0.8)
          let tickHeight = max(1, amp * size.height * 0.86)
          let fresh = CGFloat(i) / CGFloat(columns)
          let alpha = 0.10 + 0.72 * amp * (0.4 + 0.6 * fresh)
          let rect = CGRect(
            x: CGFloat(i) * step,
            y: base - tickHeight / 2,
            width: 1.8,
            height: tickHeight
          )
          context.fill(
            Path(rect),
            with: .color(Color(red: 0.78, green: 0.96, blue: 0.90).opacity(Double(alpha)))
          )
        }
      }
    }
    .drawingGroup()
    .opacity(active ? 1 : 0.35)
  }
}

// MARK: - Recording Dot

/// Audio-reactive red dot with dual concentric pulse rings.
struct RecordingDot: View {

  let meter: AudioLevelMeter

  @State private var outerPulse = false
  @State private var innerPulse = false

  var body: some View {
    TimelineView(.animation) { _ in
      let level = CGFloat(max(0.05, min(1.0, meter.current)))
      let levelSize: CGFloat = 10 + level * 12

      ZStack {
        // Outer slow pulse ring
        Circle()
          .fill(TF.recording.opacity(outerPulse ? 0.0 : 0.25))
          .frame(width: outerPulse ? 24 : 10, height: outerPulse ? 24 : 10)

        // Audio-reactive ring (smooth following)
        Circle()
          .fill(TF.recording.opacity(0.18))
          .frame(width: levelSize, height: levelSize)

        // Inner faster pulse ring (offset phase)
        Circle()
          .stroke(TF.recording.opacity(innerPulse ? 0.2 : 0.0), lineWidth: 1)
          .frame(width: innerPulse ? 18 : 12, height: innerPulse ? 18 : 12)

        // Core dot
        Circle()
          .fill(TF.recording)
          .frame(width: 10, height: 10)
          .shadow(color: TF.recording.opacity(0.4), radius: 3)
      }
    }
    .frame(width: 24, height: 24)
    .onAppear {
      withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
        outerPulse = true
      }
      withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(0.15)) {
        innerPulse = true
      }
    }
  }
}

// MARK: - Screen Bottom Recording Indicator

/// Signal Desk tally lamp shown independently at screen bottom.
/// A machined dial with a VU tick ring around a breathing filament core.
struct ScreenBottomRecordingIndicator: View {
  let meter: AudioLevelMeter
  let modeName: String

  var body: some View {
    VStack(spacing: 7) {
      TallyLampOrb(meter: meter)
        .frame(width: 96, height: 96)

      HStack(spacing: 6) {
        StatusLED(color: TF.lampAmber, pulsing: true)
        Text(modeName)
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
          .tracking(2)
          .foregroundStyle(TF.paperDim)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      .padding(.horizontal, 10)
      .frame(height: 19)
      .background {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(
            LinearGradient(
              colors: [TF.ink2, TF.ink1],
              startPoint: .top,
              endPoint: .bottom
            )
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .stroke(TF.deckLine, lineWidth: 1)
      }
      .frame(maxWidth: TF.screenBottomIndicatorWidth - 24)
    }
    .frame(width: TF.screenBottomIndicatorWidth, height: TF.screenBottomIndicatorHeight)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L("正在使用\(modeName)录音", "Recording in \(modeName)"))
  }
}

/// Machined dial + VU tick ring + incandescent filament core.
private struct TallyLampOrb: View {
  let meter: AudioLevelMeter
  @State private var smoother = LevelSmoother(timeConstant: 0.11)
  @State private var peakTracker = LevelPeak()

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      lampFace(time: timeline.date.timeIntervalSinceReferenceDate)
    }
  }

  private func lampFace(time: Double) -> some View {
    smoother.target = CGFloat(max(0, min(1, meter.current)))
    let level = smoother.update(time: time)
    let peak = peakTracker.update(time: time, level: level)
    let breath = CGFloat(sin(time * (.pi * 2 / 3.6)) * 0.5 + 0.5)
    let energy = CGFloat(pow(max(0, (level - 0.02) / 0.6), 0.6))
    let glow = min(1.25, 0.30 + 0.22 * breath + 0.75 * energy)

    return ZStack {
      dialPlate
      tickRing(peak: peak)
      bezelRing
      filamentCore(glow: glow, breath: breath, time: time)
    }
  }

  // MARK: Layers

  /// Dark instrument face so the tick ring reads on any wallpaper.
  private var dialPlate: some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [TF.ink3, TF.ink1, TF.ink0],
          center: .center,
          startRadius: 2,
          endRadius: 45
        )
      )
      .overlay {
        Circle()
          .fill(
            RadialGradient(
              colors: [.white.opacity(0.06), .clear],
              center: UnitPoint(x: 0.34, y: 0.24),
              startRadius: 1,
              endRadius: 40
            )
          )
      }
      .overlay {
        Circle().stroke(TF.deckLineStrong, lineWidth: 1)
      }
      .padding(3)
  }

  /// 64 engraved ticks; the lit arc follows the peak-held voice level.
  private func tickRing(peak: CGFloat) -> some View {
    Canvas { context, size in
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      let tickCount = 64
      let lit = peak * CGFloat(tickCount) * 0.78  // never pegs full, like a VU
      for i in 0..<tickCount {
        let angle = Double(i) / Double(tickCount) * 2 * .pi - .pi / 2
        let on = CGFloat(i) < lit
        let head = on ? min(1, max(0.12, (CGFloat(i) - (lit - 10)) / 10 + 0.25)) : 0
        let inner: CGFloat = 39.5
        let outer: CGFloat = on ? 43.0 : 41.8
        var path = Path()
        path.move(to: CGPoint(
          x: center.x + CGFloat(cos(angle)) * inner,
          y: center.y + CGFloat(sin(angle)) * inner
        ))
        path.addLine(to: CGPoint(
          x: center.x + CGFloat(cos(angle)) * outer,
          y: center.y + CGFloat(sin(angle)) * outer
        ))
        if on {
          let color = Color(
            red: 1.0,
            green: Double(0.73 + 0.16 * head),
            blue: Double(0.31 + 0.35 * head)
          )
          context.stroke(
            path,
            with: .color(color.opacity(Double(0.22 * head))),
            style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
          )
          context.stroke(
            path,
            with: .color(color.opacity(Double(0.42 + 0.5 * head))),
            style: StrokeStyle(lineWidth: 1.9, lineCap: .round)
          )
        } else {
          context.stroke(
            path,
            with: .color(TF.paper.opacity(0.16)),
            style: StrokeStyle(lineWidth: 1)
          )
        }
      }
    }
  }

  /// Machined conic bezel between the tick ring and the core.
  private var bezelRing: some View {
    Circle()
      .fill(
        AngularGradient(
          colors: [TF.ink3, TF.ink1, TF.ink2, TF.ink0, TF.ink3],
          center: .center,
          startAngle: .degrees(210),
          endAngle: .degrees(570)
        )
      )
      .overlay {
        // recessed inner edge
        Circle()
          .fill(
            RadialGradient(
              colors: [.clear, .black.opacity(0.5)],
              center: .center,
              startRadius: 22,
              endRadius: 34
            )
          )
      }
      .overlay {
        Circle().stroke(TF.deckLineStrong, lineWidth: 1)
      }
      .overlay {
        Circle()
          .fill(
            RadialGradient(
              colors: [.white.opacity(0.09), .clear],
              center: UnitPoint(x: 0.32, y: 0.26),
              startRadius: 1,
              endRadius: 26
            )
          )
      }
      .padding(14)
  }

  /// Warm incandescent core; brightness = slow breath + speech energy.
  private func filamentCore(glow: CGFloat, breath: CGFloat, time: Double) -> some View {
    let g = Double(glow)
    return ZStack {
      Circle()
        .fill(
          RadialGradient(
            colors: [
              Color(red: 1.0, green: 0.96, blue: 0.86).opacity(0.28 + 0.66 * g),
              Color(red: 1.0, green: 0.80, blue: 0.47).opacity(0.24 + 0.58 * g),
              Color(red: 0.91, green: 0.52, blue: 0.18).opacity(0.20 + 0.48 * g),
              Color(red: 0.47, green: 0.20, blue: 0.07).opacity(0.30 + 0.30 * g),
              Color(red: 0.16, green: 0.07, blue: 0.03).opacity(0.92),
            ],
            center: UnitPoint(x: 0.42, y: 0.38),
            startRadius: 1,
            endRadius: 27
          )
        )
      // drifting filament hot-spot
      Circle()
        .fill(
          RadialGradient(
            colors: [.white.opacity(0.75 * g), .clear],
            center: UnitPoint(
              x: 0.58 + 0.05 * sin(time * 0.7),
              y: 0.30 + 0.04 * cos(time * 0.9)
            ),
            startRadius: 0,
            endRadius: 14
          )
        )
      Circle()
        .stroke(TF.lampAmberHot.opacity(0.18 + 0.3 * g), lineWidth: 1)
    }
    .padding(21)
    .shadow(color: TF.lampAmber.opacity(0.20 + 0.28 * g), radius: 5 + 9 * glow)
    .scaleEffect(0.97 + 0.045 * breath + 0.05 * glow)
  }
}

struct ErrorDot: View {

  var body: some View {
    ZStack {
      Circle()
        .fill(TF.settingsAccentRed.opacity(0.18))
        .frame(width: 16, height: 16)

      Text("!")
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(TF.settingsAccentRed)
        .offset(y: -0.5)
    }
    .frame(width: 24, height: 24)
  }
}

// MARK: - Recording Timer

/// Shows elapsed time since recording started, updates every second.
struct RecordingTimer: View {
  let startDate: Date?
  let endDate: Date?

  init(startDate: Date?, endDate: Date? = nil) {
    self.startDate = startDate
    self.endDate = endDate
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { timeline in
      let referenceDate = endDate ?? timeline.date
      let elapsed = startDate.map { max(0, referenceDate.timeIntervalSince($0)) } ?? 0
      let minutes = Int(elapsed) / 60
      let seconds = Int(elapsed) % 60
      Text(String(format: "%02d:%02d", minutes, seconds))
    }
  }
}

// MARK: - Processing Progress

/// Particle progress bar with two-phase fill:
/// - Fast phase: 0% → 70% in 1.5s (ease-out)
/// - Slow cruise: 70% → 95% asymptotically (never stalls, always creeping)
/// When processingFinishTime is set, sprints toward 100% in 0.3s.
/// When doneStartDate is set, fills remaining gap to 100% in 0.15s.
/// All timing comes from parent — no @State, so view recreation is harmless.
struct ProcessingProgress: View {

  let finishTime: Date?
  var processingStartDate: Date?
  var doneStartDate: Date?

  var body: some View {
    TimelineView(.animation) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, size in
        let startRef = processingStartDate?.timeIntervalSinceReferenceDate ?? time
        let elapsed = time - startRef

        var progress: CGFloat
        let cruiseProgress: CGFloat
        if elapsed <= 1.5 {
          // Fast phase: ease-out to 70%
          let t = min(1.0, CGFloat(elapsed / 1.5))
          cruiseProgress = t * 0.7 * (2.0 - t)
        } else {
          // Slow cruise: 70% → 95%, exponential approach (τ=6s)
          let slowT = 1.0 - exp(-(elapsed - 1.5) / 6.0)
          cruiseProgress = 0.7 + CGFloat(slowT) * 0.25
        }

        if let finishTime {
          let finishElapsed = time - finishTime.timeIntervalSinceReferenceDate
          let sprintT = min(1.0, CGFloat(finishElapsed / 0.3))
          progress = cruiseProgress + (1.0 - cruiseProgress) * sprintT
        } else {
          progress = cruiseProgress
        }

        // Done: fill remaining gap to 100% in 0.15s
        if let doneStartDate {
          let doneElapsed = time - doneStartDate.timeIntervalSinceReferenceDate
          let doneT = min(1.0, CGFloat(doneElapsed / 0.15))
          let base = max(progress, 0.7)
          progress = base + (1.0 - base) * doneT
        }

        // Push soft leading edge past visible boundary when full
        let fillEdge = progress * size.width + (progress >= 0.99 ? 20 : 0)
        let center = size.height / 2

        var col = 0
        var xi: CGFloat = 0
        while xi <= size.width {
          let nx = xi / size.width

          // Color: white (left) → blue (right)
          let t = min(1.0, max(0, nx))
          let cr = 0.82 - t * 0.42
          let cg = 0.85 - t * 0.25
          let coreColor = Color(red: cr, green: cg, blue: 1.0)

          // Density: filled region is dense, edge has a soft falloff
          let distToEdge = fillEdge - xi
          let edgeFade: CGFloat
          if distToEdge > 20 {
            edgeFade = 1.0  // fully filled
          } else if distToEdge > 0 {
            edgeFade = distToEdge / 20  // soft leading edge
          } else if distToEdge > -15 {
            edgeFade = max(0, (distToEdge + 15) / 15) * 0.3  // sparse scatter ahead
          } else {
            col += 1
            xi += 2
            continue
          }

          let count = Int(edgeFade * 200)
          for j in 0..<count {
            let h1 = hash(col, j)
            let h2 = hash(col, j &+ 53)
            let h3 = hash(col, j &+ 137)

            // Scatter vertically, dense at center
            let scatter = (h1 - 0.5) * 2
            let py = center + scatter * abs(scatter) * size.height * 0.48

            // Fade from center outward
            let distFromCenter = abs(py - center)
            let distFade = pow(max(0, 1.0 - distFromCenter / (size.height * 0.48)), 1.3)

            // Twinkle
            let freq = 3.0 + Double(h2) * 10.0
            let twinkle = CGFloat(0.5 + 0.5 * sin(time * freq + Double(h3) * .pi * 2))

            let op = Double(distFade * twinkle * edgeFade * 0.85)
            guard op > 0.03 else { continue }

            let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
            context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(op)))
          }

          col += 1
          xi += 2
        }
      }
    }
    .drawingGroup()
  }

  private func hash(_ a: Int, _ b: Int) -> CGFloat {
    var h = a &* 374_761_393 &+ b &* 668_265_263
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h = h ^ (h >> 16)
    return CGFloat(abs(h) % 10000) / 10000.0
  }
}


/// Frame-rate-independent exponential smoothing for audio level.
private final class LevelSmoother {
  var current: CGFloat = 0
  var target: CGFloat = 0
  private var lastTime: Double = 0
  private let timeConstant: Double

  init(timeConstant: Double = 0.8) {
    self.timeConstant = timeConstant
  }

  func update(time: Double) -> CGFloat {
    if lastTime == 0 {
      lastTime = time
      return current
    }
    let dt = min(time - lastTime, 0.05)
    lastTime = time
    if timeConstant <= 0 {
      current = target
    } else {
      let alpha = CGFloat(1.0 - exp(-dt / timeConstant))
      current += (target - current) * alpha
    }
    return current
  }
}

/// Scrolling level history: newest on right, drifts left over time.
/// Index 0 = oldest (leftmost), last = newest (rightmost).
private final class LevelTimeline {
  private let bufferSize: Int
  private let scrollSpeed: Double  // entries shifted per second
  private var levels: [CGFloat]
  private var lastTime: Double = 0
  private var accumulator: Double = 0

  init(bufferSize: Int = 200, scrollSpeed: Double = 50) {
    self.bufferSize = bufferSize
    self.scrollSpeed = scrollSpeed
    levels = Array(repeating: 0, count: bufferSize)
  }

  func update(time: Double, currentLevel: CGFloat) -> [CGFloat] {
    if lastTime == 0 {
      lastTime = time
      return levels
    }
    let dt = min(time - lastTime, 0.05)
    lastTime = time

    accumulator += dt * scrollSpeed
    let shift = Int(accumulator)
    if shift > 0 {
      accumulator -= Double(shift)
      let actual = min(shift, bufferSize)
      levels.removeFirst(actual)
      for _ in 0..<actual {
        levels.append(currentLevel)
      }
    }
    levels[levels.count - 1] = currentLevel
    return levels
  }
}

/// Peak-hold tracker: jumps up with the level instantly, decays linearly.
private final class LevelPeak {
  private(set) var value: CGFloat = 0
  private var lastTime: Double = 0
  private let decayPerSecond: CGFloat

  init(decayPerSecond: CGFloat = 0.9) {
    self.decayPerSecond = decayPerSecond
  }

  func update(time: Double, level: CGFloat) -> CGFloat {
    if lastTime == 0 {
      lastTime = time
      value = level
      return value
    }
    let dt = min(CGFloat(time - lastTime), 0.05)
    lastTime = time
    value = max(value - dt * decayPerSecond, level)
    return value
  }
}
