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
  @AppStorage(RecordingVisualStyle.storageKey) private var visualStyle = RecordingVisualStyle
    .defaultValue

  // MARK: - Transcript Popup

  private var recordingVisualStyle: RecordingVisualStyle {
    RecordingVisualStyle(rawValue: visualStyle) ?? .timeline
  }

  private var showExpandedRecording: Bool {
    if state.finalOptimizationFailureMessage != nil { return true }
    guard recordingVisualStyle.showsRecordingPanel else { return false }
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
    if !recordingVisualStyle.showsRecordingPanel,
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
        Divider().overlay(.white.opacity(0.08))
        topPanelColumns
      }
    }
    .frame(width: width)
    .background(topPanelGlassBackground)
    .clipShape(
      RoundedRectangle(cornerRadius: state.isTranscriptPanelCollapsed ? 10 : 12, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: state.isTranscriptPanelCollapsed ? 10 : 12, style: .continuous)
        .stroke(
          LinearGradient(
            colors: [.white.opacity(0.24), .white.opacity(0.07), TF.amber.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          ),
          lineWidth: 1
        )
    }
    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
  }

  private var topPanelHeader: some View {
    HStack(spacing: 6) {
      if state.barPhase == .recording || state.barPhase == .preparing {
        RecordingDot(meter: state.audioLevel)
          .scaleEffect(0.42)
          .frame(width: 12, height: 12)
      } else if state.barPhase == .done {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(TF.success)
      } else if state.finalOptimizationFailureMessage != nil || state.barPhase == .error {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(TF.settingsAccentRed)
      } else {
        ProcessingOrb()
          .scaleEffect(0.42)
          .frame(width: 12, height: 12)
      }

      panelModeMenu

      Rectangle()
        .fill(.white.opacity(0.10))
        .frame(width: 1, height: 14)

      llmTimingStatus

      Spacer(minLength: 4)

      if let startDate = state.recordingStartDate {
        HStack(spacing: 4) {
          Text(state.barPhase == .recording ? L("录音", "REC") : L("已停止", "STOPPED"))
          RecordingTimer(
            startDate: startDate,
            endDate: state.barPhase == .recording ? nil : state.recordingStopDate
          )
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.white.opacity(0.48))
      }

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
          systemName: "stop.fill",
          accessibilityLabel: L("停止并插入", "Stop and insert"),
          tint: TF.settingsAccentRed
        ) {
          state.requestPanelStop()
        }
      }
    }
    .padding(.horizontal, 10)
    .frame(
      height: state.isTranscriptPanelCollapsed
        ? TF.topTranscriptPanelCollapsedHeaderHeight
        : TF.topTranscriptPanelHeaderHeight
    )
    .background(.black.opacity(0.035))
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
      HStack(spacing: 4) {
        Text(state.currentMode.name)
          .font(.system(size: 10, weight: .semibold))
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 7, weight: .bold))
          .opacity(canSelectPanelMode ? 0.7 : 0.25)
      }
      .foregroundStyle(.white.opacity(0.86))
      .padding(.horizontal, 6)
      .frame(height: 22)
      .background(
        Capsule()
          .fill(.white.opacity(canSelectPanelMode ? 0.055 : 0.025))
      )
      .contentShape(Capsule())
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
        HStack(spacing: 6) {
          Text(
            state.isTranscriptPanelCollapsed ? active.model : "\(active.provider) / \(active.model)"
          )
          .lineLimit(1)
          Text(String(format: "%.2fs", elapsed))
            .monospacedDigit()
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(TF.amber.opacity(0.92))
      }
    } else if let status = emptyPreviewStatusLabel {
      Text(status)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(TF.amber.opacity(0.88))
        .lineLimit(1)
    } else if let attempt = state.llmCallAttempts.last {
      HStack(spacing: 6) {
        Text(
          state.isTranscriptPanelCollapsed
            ? attempt.model : "\(attempt.provider) / \(attempt.model)"
        )
        .lineLimit(1)
        Text(String(format: "%.2fs", attempt.durationSeconds))
          .monospacedDigit()
      }
      .font(.system(size: 9, weight: .medium))
      .foregroundStyle(attempt.succeeded ? .white.opacity(0.60) : TF.settingsAccentRed)
    } else {
      Text(state.effectiveProcessingLabel)
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.white.opacity(0.48))
        .lineLimit(1)
    }
  }

  private var topPanelColumns: some View {
    let dividerWidth: CGFloat = 1
    let leftWidth = (expandedPanelWidth - dividerWidth) * 0.45
    let rightWidth = expandedPanelWidth - dividerWidth - leftWidth

    return HStack(alignment: .top, spacing: 0) {
      topPanelColumn(
        title: L("原文", "RAW"),
        metadata: L("实时转写", "LIVE"),
        width: leftWidth,
        content: rawPanelText,
        isOptimized: false
      )

      Rectangle()
        .fill(.white.opacity(0.08))
        .frame(width: dividerWidth)
        .frame(maxHeight: .infinity)

      topPanelColumn(
        title: L("优化稿", "EDIT"),
        metadata: optimizedColumnStatus,
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

  private func topPanelColumn(
    title: String,
    metadata: String,
    width: CGFloat,
    content: Text,
    isOptimized: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 6) {
        Text(title.uppercased())
          .font(.system(size: 8.5, weight: .semibold))
          .tracking(0.7)
        Spacer()
        Text(metadata)
          .font(.system(size: 8, weight: .medium))
      }
      .foregroundStyle(.white.opacity(0.44))
      .padding(.horizontal, TF.topTranscriptPanelHorizontalPadding)
      .frame(height: TF.topTranscriptPanelColumnHeaderHeight)
      .overlay(alignment: .bottom) {
        Rectangle().fill(.white.opacity(0.06)).frame(height: 1)
      }

      content
        .font(.system(size: TF.topTranscriptPanelBodyFontSize, weight: .regular))
        .foregroundStyle(isOptimized ? .white.opacity(0.96) : .white.opacity(0.78))
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
    .background(Color.white.opacity(isOptimized ? 0.012 : 0.004))
  }

  private func finalOptimizationFailureActions(message: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider().overlay(.white.opacity(0.08))
      HStack(alignment: .top, spacing: 7) {
        Image(systemName: "exclamationmark.circle.fill")
          .foregroundStyle(TF.settingsAccentRed)
        VStack(alignment: .leading, spacing: 2) {
          Text(L("优化失败，原文仍已保留", "Optimization failed; raw text is retained"))
            .font(.system(size: 11, weight: .semibold))
          Text(message)
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.5))
        }
      }

      ForEach(state.llmCallAttempts.filter { !$0.succeeded }) { attempt in
        HStack {
          Text("#\(attempt.attempt) · \(attempt.provider) / \(attempt.model)")
          Spacer()
          Text(String(format: "%.2fs", attempt.durationSeconds))
            .monospacedDigit()
        }
        .font(.system(size: 8.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.38))
      }

      HStack(spacing: 7) {
        Button(L("重试优化", "Retry optimization")) {
          state.retryFinalOptimization()
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(Color.black.opacity(0.82))
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(TF.amber))

        Button(L("插入原文", "Insert raw text")) {
          state.insertRawAfterOptimizationFailure()
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 11)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.06)))
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
  }

  private func topPanelButton(
    systemName: String,
    accessibilityLabel: String,
    tint: Color = .white.opacity(0.64),
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 8.5, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 22, height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.055)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }

  private var topPanelGlassBackground: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
      Color(red: 0.15, green: 0.19, blue: 0.23).opacity(0.88)
      LinearGradient(
        colors: [.white.opacity(0.075), .clear, Color.black.opacity(0.10)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
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

      if state.barPhase == .recording {
        AudioRipple(meter: state.audioLevel, style: recordingVisualStyle)
          .id(recordingVisualStyle.rawValue)
          .transition(.opacity)
      }

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

// MARK: - Recording Dot

struct PreparingDot: View {

  @State private var rotation = 0.0

  var body: some View {
    ZStack {
      Circle()
        .stroke(TF.recording.opacity(0.16), lineWidth: 1.6)
        .frame(width: 14, height: 14)

      Circle()
        .trim(from: 0.16, to: 0.76)
        .stroke(
          TF.recording,
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

/// Siri-style recording feedback shown independently at screen bottom.
/// It stays subtly animated while listening and responds strongly to speech energy.
struct ScreenBottomRecordingIndicator: View {
  let meter: AudioLevelMeter
  let modeName: String
  let onCancel: () -> Void

  var body: some View {
    VStack(spacing: 3) {
      SiriRecordingOrb(meter: meter)

      Text(modeName)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.84))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background {
          Capsule()
            .fill(Color(red: 0.10, green: 0.13, blue: 0.16).opacity(0.80))
            .overlay {
              Capsule().stroke(.white.opacity(0.12), lineWidth: 0.8)
            }
        }
    }
    .frame(width: TF.screenBottomIndicatorWidth, height: TF.screenBottomIndicatorHeight)
    .overlay(alignment: .topTrailing) {
      Button(action: onCancel) {
        Image(systemName: "xmark")
          .font(.system(size: 8, weight: .bold))
          .foregroundStyle(.white.opacity(0.74))
          .frame(width: 20, height: 20)
          .background {
            Circle()
              .fill(Color(red: 0.10, green: 0.13, blue: 0.16).opacity(0.88))
              .overlay { Circle().stroke(.white.opacity(0.16), lineWidth: 0.8) }
          }
      }
      .buttonStyle(.plain)
      .help(L("撤销并丢弃本次录音", "Cancel and discard this recording"))
      .accessibilityLabel(L("撤销本次录音", "Cancel recording"))
      .padding(.top, 3)
      .padding(.trailing, 8)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(L("正在使用\(modeName)录音", "Recording in \(modeName)"))
  }
}

private struct SiriRecordingOrb: View {
  let meter: AudioLevelMeter
  @State private var levelSmoother = LevelSmoother(timeConstant: 0.48)

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      let rawLevel = CGFloat(max(0, min(1, meter.current)))
      let smoothedLevel: CGFloat = {
        levelSmoother.target = rawLevel
        return levelSmoother.update(time: time)
      }()
      let energy = min(1, pow(max(0, (smoothedLevel - 0.008) / 0.30), 0.52))
      let breath = CGFloat(sin(time * 1.1) * 0.5 + 0.5)
      ZStack {
        Circle()
          .fill(Color(red: 0.035, green: 0.055, blue: 0.085))

        Circle()
          .fill(
            AngularGradient(
              colors: [
                Color(red: 0.12, green: 0.86, blue: 1.00),
                Color(red: 0.27, green: 0.42, blue: 1.00),
                Color(red: 0.72, green: 0.25, blue: 1.00),
                Color(red: 1.00, green: 0.24, blue: 0.66),
                Color(red: 0.12, green: 0.86, blue: 1.00),
              ],
              center: .center,
              startAngle: .degrees(time * 14),
              endAngle: .degrees(time * 14 + 360)
            )
          )
          .opacity(0.66 + Double(energy) * 0.30)

        Circle()
          .fill(
            RadialGradient(
              colors: [Color.cyan.opacity(0.94), .clear],
              center: UnitPoint(
                x: 0.5 + 0.24 * sin(time * 0.55),
                y: 0.5 + 0.22 * cos(time * 0.48)
              ),
              startRadius: 1,
              endRadius: 34
            )
          )
          .blendMode(.plusLighter)

        Circle()
          .fill(
            RadialGradient(
              colors: [Color.pink.opacity(0.78), .clear],
              center: UnitPoint(
                x: 0.5 + 0.25 * cos(time * 0.42 + 1.2),
                y: 0.5 + 0.24 * sin(time * 0.62 + 0.7)
              ),
              startRadius: 0,
              endRadius: 30
            )
          )
          .blendMode(.screen)

      }
      .frame(width: 64, height: 64)
      .clipShape(Circle())
      .overlay {
        Circle()
          .stroke(
            LinearGradient(
              colors: [.white.opacity(0.58), .white.opacity(0.12), .cyan.opacity(0.46)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            ),
            lineWidth: 1
          )
      }
      .overlay {
        Circle()
          .stroke(Color.cyan.opacity(0.18 + Double(energy) * 0.42), lineWidth: 1.2)
          .scaleEffect(1.02 + energy * 0.16 + breath * 0.02)
      }
      .scaleEffect(0.91 + energy * 0.17 + breath * 0.02)
    }
    .frame(width: 88, height: 88)
  }
}

// MARK: - Processing Orb

/// Purple/blue gradient sphere with rotation + breathing glow.
struct ProcessingOrb: View {

  @State private var rotation: Double = 0
  @State private var breathe = false

  var body: some View {
    Circle()
      .fill(
        AngularGradient(
          colors: [
            Color(red: 0.40, green: 0.30, blue: 0.90),
            Color(red: 0.30, green: 0.55, blue: 1.00),
            Color(red: 0.40, green: 0.30, blue: 0.90),
          ],
          center: .center,
          startAngle: .degrees(rotation),
          endAngle: .degrees(rotation + 360)
        )
      )
      .frame(width: 22, height: 22)
      .scaleEffect(breathe ? 1.08 : 0.95)
      .shadow(
        color: Color(red: 0.35, green: 0.35, blue: 0.90).opacity(breathe ? 0.6 : 0.3),
        radius: breathe ? 10 : 5
      )
      .onAppear {
        withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
          rotation = 360
        }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
          breathe = true
        }
      }
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

// MARK: - Audio Ripple

/// Audio visualizer with three selectable styles:
/// - classic: two sine-wave stroke lines
/// - dual: particles clustered around two sine-wave spines
/// - timeline: scrolling level history, right = now
struct AudioRipple: View {

  let meter: AudioLevelMeter
  let style: RecordingVisualStyle
  @State private var smootherSlow = LevelSmoother(timeConstant: 0.8)
  @State private var smootherFast = LevelSmoother(timeConstant: 0)
  @State private var startTime: Double = 0
  @State private var levelTimeline = LevelTimeline()

  var body: some View {
    TimelineView(.animation) { timeline in
      let time = timeline.date.timeIntervalSinceReferenceDate
      Canvas { context, size in
        switch style {
        case .classic: drawClassicWaves(context: &context, size: size, time: time)
        case .dual: drawDualSpine(context: &context, size: size, time: time)
        case .timeline, .hidden: drawTimeline(context: &context, size: size, time: time)
        }
      }
    }
    .drawingGroup()
  }

  // MARK: - Classic Waves (stroke lines only)

  private func drawClassicWaves(context: inout GraphicsContext, size: CGSize, time: Double) {
    let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
    smootherSlow.target = max(0.012, rawLevel)
    let level = smootherSlow.update(time: time)
    let amp = min(1.0, pow(max(0, (level - 0.012) / 0.45), 0.7))
    let center = size.height / 2
    let maxAmp = size.height * (0.15 + amp * 0.35)
    let opacity = 0.4 + Double(amp) * 0.4

    for w in 0..<2 {
      let period: Double = w == 0 ? 130.0 : 90.0
      let speed: Double = w == 0 ? 1.0 : 0.7
      let phase: Double = w == 0 ? 0.0 : 1.3

      var path = Path()
      var first = true
      var xi: CGFloat = 0
      while xi <= size.width {
        let nx = Double(xi / size.width)
        let env = 0.07 + pow(nx, 1.5) * (0.10 + Double(amp))
        let y =
          center + CGFloat(sin(Double(xi) / period * .pi * 2 + time * speed * .pi + phase) * env)
          * maxAmp
        if first {
          path.move(to: CGPoint(x: xi, y: y))
          first = false
        } else {
          path.addLine(to: CGPoint(x: xi, y: y))
        }
        xi += 2
      }

      context.stroke(
        path,
        with: .linearGradient(
          Gradient(colors: [
            Color(red: 0.82, green: 0.85, blue: 1.0).opacity(opacity * 0.7),
            Color(red: 0.40, green: 0.60, blue: 1.0).opacity(opacity),
          ]),
          startPoint: CGPoint(x: 0, y: center),
          endPoint: CGPoint(x: size.width, y: center)
        ), lineWidth: 1.5)
    }
  }

  // MARK: - Dual Spine Particles

  private func drawDualSpine(context: inout GraphicsContext, size: CGSize, time: Double) {
    let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
    smootherSlow.target = max(0.012, rawLevel)
    let level = smootherSlow.update(time: time)
    let amp = min(1.0, pow(max(0, (level - 0.012) / 0.45), 0.7))
    let center = size.height / 2
    let maxAmp = size.height * (0.15 + amp * 0.35)
    let levelBright: CGFloat = 0.75 + amp * 0.25
    let bandHalf: CGFloat = size.height * (0.2 + amp * 0.3)

    var xi: CGFloat = 0
    var col = 0
    while xi <= size.width {
      let nx = xi / size.width
      let env = 0.07 + pow(Double(nx), 1.5) * (0.10 + Double(amp))
      let s1y = center + CGFloat(sin(Double(xi) / 130.0 * .pi * 2 + time * .pi) * env) * maxAmp
      let s2y = center + CGFloat(sin(Double(xi) / 90.0 * .pi * 2 + time * 0.7 * .pi) * env) * maxAmp
      let localAmp = (abs(s1y - center) + abs(s2y - center)) / 2
      let localIntensity = min(1.0, localAmp / max(maxAmp * 0.5, 1))
      let posBright: CGFloat = 0.6 + pow(nx, 0.8) * 0.4

      let cr: Double = 0.82 - Double(nx) * 0.42
      let cg: Double = 0.85 - Double(nx) * 0.25
      let coreColor = Color(red: cr, green: cg, blue: 1.0)

      let count = 160 + Int(localIntensity * 120)
      let posScale: CGFloat = 0.4 + pow(nx, 0.8) * 0.6
      let localBand = bandHalf * posScale * (0.5 + amp * 1.0)

      for j in 0..<count {
        let h1 = hash(col, j)
        let h2 = hash(col, j &+ 53)
        let h3 = hash(col, j &+ 137)
        let h5 = hash(col, j &+ 293)

        let spineY = h5 > 0.5 ? s1y : s2y
        let scatter = (h1 - 0.5) * 2
        let py = spineY + scatter * abs(scatter) * localBand

        let distFromSpine = abs(py - spineY)
        let normDist = distFromSpine / max(localBand, 1)
        let distFade: CGFloat = normDist < 0.25 ? 1.0 : max(0, 1.0 - (normDist - 0.25) / 0.75)

        let freq = 3.0 + Double(h2) * 10.0
        let twinkle: CGFloat = 0.45 + 0.55 * CGFloat(sin(time * freq + Double(h3) * .pi * 2))

        let baseOp = posBright * distFade * twinkle * levelBright
        guard baseOp > 0.02 else { continue }

        let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
        context.fill(
          Circle().path(in: dotR), with: .color(coreColor.opacity(Double(min(1.0, baseOp)))))
      }

      col += 1
      xi += 2
    }
  }

  // MARK: - Timeline Particles (scrolling history)

  private func drawTimeline(context: inout GraphicsContext, size: CGSize, time: Double) {
    if startTime == 0 { DispatchQueue.main.async { startTime = time } }
    let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
    smootherFast.target = max(0.005, rawLevel)
    let smoothed = smootherFast.update(time: time)
    let levels = levelTimeline.update(time: time, currentLevel: smoothed)

    let center = size.height / 2
    let bufCount = levels.count
    let colCount = Int(size.width / 2) + 1

    for col in 0..<colCount {
      let xi = CGFloat(col) * 2
      let nx = xi / size.width

      let histIdx = min(Int(nx * CGFloat(bufCount - 1)), bufCount - 1)
      let histLevel = levels[histIdx]
      let amp = min(1.0, pow(max(0, (histLevel - 0.08) / 0.62), 0.85))

      let bandHalf = size.height * (0.03 + amp * 0.45)
      let posBright: CGFloat = 0.4 + pow(nx, 0.8) * 0.3
      let levelBright: CGFloat = 0.45 + amp * 0.35

      let cr: Double = 0.82 - Double(nx) * 0.42
      let cg: Double = 0.85 - Double(nx) * 0.25
      let coreColor = Color(red: cr, green: cg, blue: 1.0)

      for j in 0..<180 {
        let h1 = hash(col, j)
        let h2 = hash(col, j &+ 53)
        let h3 = hash(col, j &+ 137)

        let scatter = (h1 - 0.5) * 2
        let py = center + scatter * abs(scatter) * bandHalf

        let freq = 3.0 + Double(h2) * 10.0
        let twinkle: CGFloat = 0.45 + 0.55 * CGFloat(sin(time * freq + Double(h3) * .pi * 2))

        let baseOp = posBright * twinkle * levelBright
        guard baseOp > 0.02 else { continue }

        let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
        context.fill(
          Circle().path(in: dotR), with: .color(coreColor.opacity(Double(min(1.0, baseOp)))))
      }
    }
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
  private static let bufferSize = 200
  private var levels: [CGFloat]
  private var lastTime: Double = 0
  private var accumulator: Double = 0
  private let scrollSpeed: Double = 50  // entries shifted per second

  init() {
    levels = Array(repeating: 0, count: Self.bufferSize)
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
      let actual = min(shift, Self.bufferSize)
      levels.removeFirst(actual)
      for _ in 0..<actual {
        levels.append(currentLevel)
      }
    }
    levels[levels.count - 1] = currentLevel
    return levels
  }
}
