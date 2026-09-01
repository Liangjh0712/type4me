import SwiftUI

/// Cached font for text measurement (module-level to avoid generic-type static restriction).
private let floatingBarFont = NSFont.systemFont(ofSize: 14, weight: .medium)

/// Scroll anchor for the transcript columns' tail-following behaviour.
private let transcriptTailAnchor = "transcript-tail"

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
  var inputDeviceName: String { get }
  var pinsTranscriptPopup: Bool { get }
  var liveOptimizedText: String { get }
  var liveOptimizationPhase: LiveOptimizationPhase { get }
  var asrPanelPhase: ASRPanelPhase { get }
  var asrPanelStatusLabel: String { get }
  var asrRevision: Int { get }
  var liveOptimizationRevision: Int? { get }
  var lockedOptimizationRevision: Int? { get }
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

extension FloatingBarState {
  /// Mode switching from a panel is only meaningful while capturing.
  var canSelectPanelMode: Bool {
    barPhase == .preparing || barPhase == .recording
  }

  func panelModeShortcutLabel(_ mode: ProcessingMode) -> String? {
    guard let binding = mode.hotkeyBindings.first else { return nil }
    return HotkeyRecorderView.keyDisplayName(
      keyCode: binding.keyCode,
      modifiers: binding.modifiers
    )
  }
}

/// LED tone for a deck status cluster (column headers, bottom card status).
enum DeckMetaTone {
  case live, working, ok, failed, idle

  var ledColor: Color {
    switch self {
    case .live, .ok: return TF.signalTeal
    case .working: return TF.lampAmber
    case .failed: return TF.settingsAccentRed
    case .idle: return TF.frostTextFaint.opacity(0.7)
    }
  }

  var pulsing: Bool { self == .working }

  var textColor: Color {
    switch self {
    case .working: return TF.lampAmber.opacity(0.85)
    case .failed: return TF.settingsAccentRed.opacity(0.9)
    default: return TF.frostTextFaint
    }
  }
}

/// Shared copy for the "optimized" transcript surface, used by both the top
/// deck's EDIT column and the style-2 bottom card so the two never diverge.
/// View-layer only (returns SwiftUI.Text) — kept out of AppState and named
/// distinctly from the `optimizedPanelText: String` state property.
@MainActor
enum OptimizedPanelCopy {
  static func string<S: FloatingBarState>(for state: S) -> String {
    if state.supportsLiveOptimizationPreview {
      let text = state.optimizedPanelText
      if !text.isEmpty { return text }
      switch state.liveOptimizationPhase {
      case .waiting, .stale:
        return state.transcriptionText.isEmpty
          ? L("等待语音…", "Waiting for speech…")
          : L("等待停顿后优化…", "Waiting for a pause to optimize…")
      case .updating:
        return L("正在生成优化稿…", "Generating optimized text…")
      case .unavailable(let message), .failed(let message):
        return message
      case .ready:
        return L("等待优化结果…", "Waiting for optimization result…")
      case .inactive:
        return L("此模式不支持实时优化", "Live optimization is unavailable for this mode")
      }
    }
    let direct =
      state.processingResultText.isEmpty ? state.transcriptionText : state.processingResultText
    return direct.isEmpty ? L("此模式将直接插入原文", "This mode inserts the raw transcript") : direct
  }

  static func text<S: FloatingBarState>(for state: S) -> Text {
    Text(string(for: state))
  }

  /// Style-2 bottom card copy. Errors and transcript-less status feedback
  /// (e.g. Mac Action results, "Cancelled") have no optimized text — the card
  /// shows the feedback message itself instead of a placeholder.
  static func bottomCardString<S: FloatingBarState>(for state: S) -> String {
    if state.barPhase == .error {
      return state.feedbackMessage
    }
    if state.barPhase == .done,
      state.transcriptionText.isEmpty,
      state.optimizedPanelText.isEmpty
    {
      return state.feedbackMessage
    }
    return string(for: state)
  }

  static func bottomCardText<S: FloatingBarState>(for state: S) -> Text {
    Text(bottomCardString(for: state))
  }

  /// Terse optimization status for deck headers / the style-2 status row
  /// ("等待停顿", "优化中", "已优化", "提交中", "优化失败", "原文"…).
  ///
  /// Revision numbers were dropped: `R3`, `R2→R3` are internal pipeline
  /// bookkeeping. No user acts on them, and the digits churned in the corner
  /// of the eye while the transcript — the thing being read — sat still.
  static func status<S: FloatingBarState>(for state: S) -> String {
    if state.finalOptimizationFailureMessage != nil {
      return L("优化失败", "FAILED")
    }
    if state.barPhase == .processing, state.lockedOptimizationRevision != nil {
      return L("提交中", "COMMITTING")
    }

    switch state.liveOptimizationPhase {
    case .waiting:
      return L("等待停顿", "WAITING")
    case .stale:
      return L("待更新", "UPDATE PENDING")
    case .updating:
      return L("优化中", "UPDATING")
    case .ready:
      return L("已优化", "READY")
    case .unavailable:
      return L("不可用", "UNAVAILABLE")
    case .failed:
      return L("优化失败", "FAILED")
    case .inactive:
      return L("原文", "RAW")
    }
  }

  /// LED tone matching `status(for:)`.
  static func tone<S: FloatingBarState>(for state: S) -> DeckMetaTone {
    if state.finalOptimizationFailureMessage != nil { return .failed }
    switch state.liveOptimizationPhase {
    case .updating: return .working
    case .ready: return .ok
    case .failed, .unavailable: return .failed
    case .waiting, .stale, .inactive: return .idle
    }
  }

  /// True when the bottom card copy is a status hint ("等待停顿后优化…",
  /// "此模式将直接插入原文", …) rather than actual transcript content, so the
  /// view can dim it — same-color placeholders read as if text had already
  /// been recognized before the user spoke.
  static func bottomCardIsPlaceholder<S: FloatingBarState>(for state: S) -> Bool {
    if state.barPhase == .error { return false }
    if state.barPhase == .done,
      state.transcriptionText.isEmpty,
      state.optimizedPanelText.isEmpty
    {
      return false
    }
    if state.supportsLiveOptimizationPreview {
      // Any produced optimized text is content; everything else is a
      // phase hint (waiting / updating / unavailable / …).
      return state.optimizedPanelText.isEmpty
    }
    let direct =
      state.processingResultText.isEmpty ? state.transcriptionText : state.processingResultText
    return direct.isEmpty
  }
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
  @AppStorage(TranscriptPanelStyle.storageKey) private var panelStyle =
    TranscriptPanelStyle.top.rawValue

  private var panelStyleValue: TranscriptPanelStyle {
    TranscriptPanelStyle(rawValue: panelStyle) ?? .top
  }

  // MARK: - Transcript Popup

  private var showExpandedRecording: Bool {
    // Optimization failure is an exceptional state with no auto-hide: every
    // style falls back to the top deck, whose retry/insert-raw actions are
    // the only way out.
    if state.finalOptimizationFailureMessage != nil { return true }
    guard panelStyleValue == .top else { return false }
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
    if panelStyleValue != .top,
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
      // The phase border used to be computed and then never applied — the
      // capsule shipped strokeless while a whole state machine sat unused
      // below. Wired up, and the shadow that stood in for it is gone.
      .overlay { Capsule().strokeBorder(borderColor, lineWidth: TF.frostBorderWidth) }
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
      return ("checkmark.circle.fill", TF.signalTeal)
    case .macActionFailure:
      return ("xmark.circle.fill", TF.settingsAccentRed)
    case .macActionUnsure:
      return ("questionmark.circle.fill", TF.lampAmber)
    }
  }

  // MARK: - Expanded Live Transcript

  private var expandedRecordingCard: some View {
    let width =
      state.isTranscriptPanelCollapsed
      ? TF.topTranscriptPanelCollapsedWidth
      : expandedPanelWidth

    return VStack(spacing: 0) {
      if state.isTranscriptPanelCollapsed {
        collapsedPanelHeader
      } else {
        topPanelHeader
        meterBridge
        topPanelColumns
      }
    }
    .frame(width: width)
    // Clip first: the header's tint and the column wells run edge to edge
    // and would otherwise square off the corners.
    .clipShape(RoundedRectangle(cornerRadius: TF.frostPanel, style: .continuous))
    // Frost, not ink. This panel was the only surface in the dark family
    // carrying drop shadows; both are gone — overlapping overlays stacked
    // them, and they fought the "sits in the desktop" read.
    .frostSurface(cornerRadius: TF.frostPanel)
  }

  // MARK: - Meter Bridge

  /// Live VU hairline strip between the channel strip and the transcript columns.
  private var meterBridge: some View {
    MeterBridge(meter: state.audioLevel, active: state.barPhase == .recording)
      .frame(height: TF.topTranscriptPanelMeterBridgeHeight)
      .background(Color.black.opacity(0.22))
      .overlay(alignment: .top) { Rectangle().fill(TF.frostRule).frame(height: 0.5) }
      .overlay(alignment: .bottom) { Rectangle().fill(TF.frostRule).frame(height: 0.5) }
  }

  /// Collapsed: dot + one summary line + clock, on 380pt. Cramming the full
  /// expanded header into that width overflowed it — the device chip and LLM
  /// status had nowhere to go and got clipped mid-glyph.
  private var collapsedPanelHeader: some View {
    HStack(spacing: 9) {
      deckTally

      if !state.transcriptionText.isEmpty {
        Text(L("\(state.transcriptionText.count)字", "\(state.transcriptionText.count) ch"))
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(TF.frostTextFaint)
          .fixedSize()
      }

      Spacer(minLength: 4)

      topPanelButton(
        systemName: "chevron.down",
        accessibilityLabel: L("展开面板", "Expand panel")
      ) {
        state.toggleTranscriptPanelCollapsed()
      }
    }
    .padding(.horizontal, 12)
    .frame(height: TF.topTranscriptPanelHeaderHeight)
  }

  private var topPanelHeader: some View {
    HStack(spacing: 9) {
      deckTally

      panelModeMenu

      if !state.inputDeviceName.isEmpty {
        inputDeviceIndicator
      }

      Spacer(minLength: 8)

      llmTimingStatus

      topPanelButton(
        systemName: "chevron.up",
        accessibilityLabel: L("收缩面板", "Collapse panel")
      ) {
        state.toggleTranscriptPanelCollapsed()
      }

      if state.barPhase == .recording || state.barPhase == .preparing {
        // Separated from the chevron: ✕ discards the whole recording, and
        // sitting flush against a harmless collapse toggle at the same tint
        // made the destructive action the easiest one to hit by accident.
        Rectangle()
          .fill(TF.frostRule)
          .frame(width: 0.5, height: 14)
          .padding(.horizontal, 3)

        topPanelButton(
          systemName: "xmark",
          accessibilityLabel: L("撤销并丢弃本次录音", "Cancel and discard this recording"),
          tint: TF.frostTextDim
        ) {
          state.requestPanelCancel()
        }

        topPanelButton(
          systemName: "checkmark",
          accessibilityLabel: L("停止并插入", "Stop and insert"),
          tint: TF.signalTeal
        ) {
          state.requestPanelStop()
        }
      }
    }
    .padding(.horizontal, 12)
    .frame(height: TF.topTranscriptPanelHeaderHeight)
  }

  /// Phase status cluster at the left of the channel strip:
  /// state dot + mono label + recording clock.
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
          .foregroundStyle(TF.signalTeal)
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
        .foregroundStyle(TF.frostText)
      }
    }
    .font(.system(size: 10, weight: .semibold, design: .monospaced))
    .tracking(1.2)
    .foregroundStyle(TF.frostTextDim)
    .lineLimit(1)
    .fixedSize()
  }

  /// Capture-device chip in the channel strip, styled like the LLM deck status.
  private var inputDeviceIndicator: some View {
    HStack(spacing: 5) {
      Image(systemName: "mic.fill")
        .font(.system(size: 8.5))
      Text(state.inputDeviceName)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
    .tracking(0.5)
    .foregroundStyle(TF.frostTextFaint)
    .frame(maxWidth: 150)
    .help(state.inputDeviceName)
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
            if let shortcut = state.panelModeShortcutLabel(mode) {
              Spacer()
              Text(shortcut)
            }
          }
        }
      }
    } label: {
      // Plain text, no chip. Boxing it made the header read as a toolbar of
      // controls competing with the tally; the chevron is enough affordance.
      HStack(spacing: 4) {
        Text(state.currentMode.name)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .tracking(1)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 6, weight: .bold))
          .opacity(state.canSelectPanelMode ? 0.6 : 0.25)
      }
      .foregroundStyle(TF.frostTextDim.opacity(state.canSelectPanelMode ? 1 : 0.55))
      .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(!state.canSelectPanelMode)
    .accessibilityLabel(L("切换处理模式", "Switch processing mode"))
  }

  private var emptyPreviewStatusLabel: String? {
    guard state.optimizedPanelText.isEmpty else { return nil }
    // Deliberately silent before the first word: the tally already says REC
    // and the RAW column already shows "等待语音…". Saying it a third time
    // here made "nothing has happened yet" the loudest thing on the panel.
    if state.transcriptionText.isEmpty { return nil }
    return state.liveOptimizationPhase.statusLabel
  }

  @ViewBuilder
  private var llmTimingStatus: some View {
    if let active = state.activeLLMCall {
      TimelineView(.periodic(from: .now, by: 0.1)) { context in
        let elapsed = max(0, context.date.timeIntervalSince(active.startedAt))
        deckStatus(
          led: TF.lampAmber,
          ledOpacity: 0.55 + 0.45
            * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 4)),
          text: active.model,
          trailing: String(format: "%.1fs", elapsed),
          tone: TF.lampAmber.opacity(0.9)
        )
      }
    } else if let status = emptyPreviewStatusLabel {
      deckStatus(
        led: TF.frostTextFaint.opacity(0.7),
        ledOpacity: 1,
        text: status,
        trailing: nil,
        tone: TF.frostTextFaint
      )
    } else if let attempt = state.llmCallAttempts.last {
      deckStatus(
        led: attempt.succeeded ? TF.signalTeal : TF.settingsAccentRed,
        ledOpacity: 1,
        text: attempt.model,
        trailing: String(format: "%.1fs", attempt.durationSeconds),
        tone: attempt.succeeded ? TF.frostTextDim : TF.settingsAccentRed
      )
    } else {
      deckStatus(
        led: TF.frostTextFaint.opacity(0.7),
        ledOpacity: 1,
        text: state.effectiveProcessingLabel,
        trailing: nil,
        tone: TF.frostTextFaint
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
        metadata: state.asrPanelStatusLabel,
        tone: rawMetaTone,
        width: leftWidth,
        content: rawPanelText,
        isOptimized: false
      )

      Rectangle()
        .fill(TF.frostRule)
        .frame(width: dividerWidth)
        .frame(maxHeight: .infinity)

      topPanelColumn(
        title: L("优化稿", "EDIT"),
        metadata: OptimizedPanelCopy.status(for: state),
        tone: OptimizedPanelCopy.tone(for: state),
        width: rightWidth,
        content: OptimizedPanelCopy.text(for: state),
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
    return Text(stable) + Text(pending).foregroundColor(TF.lampAmber)
  }

  private var rawMetaTone: DeckMetaTone {
    switch state.asrPanelPhase {
    case .connecting, .temporary: return .idle
    case .recognizing, .finishing, .recovering: return .working
    case .stable, .locked: return .ok
    case .failed: return .failed
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
      // LED leads the row: it's the column's state light, so it reads with
      // the title rather than with the trailing metadata.
      HStack(spacing: 8) {
        StatusLED(color: tone.ledColor, pulsing: tone.pulsing)
        Text(title.uppercased())
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
          .tracking(2.2)
          .foregroundStyle(TF.frostTextFaint)
        Spacer()
        Text(metadata)
          .font(.system(size: 8.5, weight: .medium, design: .monospaced))
          .tracking(1)
          .foregroundStyle(tone.textColor)
      }
      .padding(.horizontal, TF.topTranscriptPanelHorizontalPadding)
      .frame(height: TF.topTranscriptPanelColumnHeaderHeight)
      .overlay(alignment: .bottom) {
        Rectangle().fill(TF.frostRule).frame(height: 0.5)
      }

      // Tail-following scroll. The panel height is capped at the screen, and
      // a dictation longer than that used to be cut mid-line by the card's
      // clipShape — no scrollbar, no fade, just a severed glyph that read as
      // a rendering failure. Long transcripts are the whole point of this
      // panel, so the tail has to stay visible.
      ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
          content
            .font(.system(size: TF.topTranscriptPanelBodyFontSize, weight: .regular))
            .foregroundStyle(
              isOptimized ? TF.frostText.opacity(0.95) : TF.frostTextDim.opacity(0.88)
            )
            .lineSpacing(TF.topTranscriptPanelBodyLineSpacing)
            .textSelection(.disabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, TF.topTranscriptPanelHorizontalPadding)
            .padding(.top, TF.topTranscriptPanelBodyTopPadding)
            .padding(.bottom, TF.topTranscriptPanelBodyBottomPadding)
            .id(transcriptTailAnchor)
        }
        .onChange(of: state.transcriptionText) { _, _ in
          withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(transcriptTailAnchor, anchor: .bottom)
          }
        }
        .onChange(of: state.optimizedPanelText) { _, _ in
          withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(transcriptTailAnchor, anchor: .bottom)
          }
        }
      }

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
            .foregroundStyle(TF.frostText)
          Text(message)
            .font(.system(size: 9))
            .foregroundStyle(TF.frostTextFaint)
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
        .foregroundStyle(TF.frostTextFaint)
      }

      HStack(spacing: 8) {
        Button(L("重试优化", "Retry optimization")) {
          state.retryFinalOptimization()
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Color.black.opacity(0.82))
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: TF.frostKey).fill(TF.lampAmber))

        Button(L("插入原文", "Insert raw text")) {
          state.insertRawAfterOptimizationFailure()
        }
        .buttonStyle(.plain)
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(TF.frostTextDim)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: TF.frostKey).fill(TF.frostWell))
        .overlay {
          RoundedRectangle(cornerRadius: TF.frostKey).stroke(TF.frostBorder, lineWidth: TF.frostBorderWidth)
        }
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: TF.frostKey, style: .continuous)
        .fill(TF.settingsAccentRed.opacity(0.05))
    )
    .overlay {
      RoundedRectangle(cornerRadius: TF.frostKey, style: .continuous)
        .stroke(TF.settingsAccentRed.opacity(0.22), lineWidth: 1)
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
  }

  /// Circular ghost action, matching the style-3 capsule's cancel/done pair.
  /// Borderless by default; the fill only appears under the pointer, so a
  /// header of four controls reads as one cluster instead of four boxes.
  private func topPanelButton(
    systemName: String,
    accessibilityLabel: String,
    tint: Color = TF.frostTextFaint,
    action: @escaping () -> Void
  ) -> some View {
    TopPanelGhostButton(
      systemName: systemName,
      accessibilityLabel: accessibilityLabel,
      tint: tint,
      action: action
    )
  }

  // MARK: - Background & Border

  /// Dark frosted-glass fill shared by the capsule and the transcript popup.
  /// Shape-agnostic: the caller clips it (Capsule / RoundedRectangle).
  private var glassBackground: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
      Rectangle().fill(TF.frostTint)
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

  /// Phase-tinted hairline. Sits at the shared frost weight except while
  /// recording, where it breathes, and in the terminal phases, where it
  /// carries the outcome color.
  private var borderColor: Color {
    switch state.barPhase {
    case .preparing:
      TF.frostBorder
    case .recording:
      .white.opacity(breathe ? 0.22 : 0.11)
    case .processing:
      TF.frostBorder
    case .recovering:
      .white.opacity(0.16)
    case .done:
      switch state.feedbackKind {
      case .macActionUnsure:
        TF.lampAmber.opacity(0.30)
      case .macActionSuccess, .macActionFailure, .standard:
        TF.signalTeal.opacity(doneGlow ? 0.35 : 0.10)
      }
    case .error:
      TF.settingsAccentRed.opacity(0.30)
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
    .frostSurface(cornerRadius: TF.frostPanel)
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
      .onAppear { syncPulse() }
      // The view's identity is stable across tone changes, so onAppear fires
      // exactly once — a column going idle → working never started breathing
      // without this.
      .onChange(of: pulsing) { _, _ in syncPulse() }
  }

  private func syncPulse() {
    guard pulsing else {
      // Drop the repeating animation, otherwise it keeps running against a
      // now-static opacity and the LED flickers at the wrong tone.
      withAnimation(.easeOut(duration: 0.15)) { lit = false }
      return
    }
    lit = false
    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
      lit = true
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
          let histIdx = min(
            Int(CGFloat(i) / CGFloat(columns) * CGFloat(bufCount - 1)), bufCount - 1)
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
            with: .color(TF.signalTeal.opacity(Double(alpha)))
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

/// Screen-bottom recording surface. In every style it renders the status
/// pill; in style 2 (.bottom) it additionally floats an optimized-transcript
/// card above it. Reads state directly so the controller never has to
/// rebuild the root view.
///
/// Content is anchored to the bottom of the panel frame: when the controller
/// grows the frame upward for the card, the pill stays exactly where the user
/// dragged it.
struct ScreenBottomIndicatorView<S: FloatingBarState>: View {
  let state: S

  @State private var pulsing = false

  @AppStorage(TranscriptPanelStyle.storageKey) private var panelStyle =
    TranscriptPanelStyle.top.rawValue

  private var style: TranscriptPanelStyle {
    TranscriptPanelStyle(rawValue: panelStyle) ?? .top
  }

  private var showsOptimizedCard: Bool {
    style == .bottom && state.barPhase != .hidden
  }

  var body: some View {
    VStack(spacing: 10) {
      if showsOptimizedCard {
        optimizedCard
      }
      statusPill
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      L("正在使用\(state.currentMode.name)录音", "Recording in \(state.currentMode.name)")
    )
  }

  // MARK: - Status Pill

  /// Breathing dot + live level meter + phase label + frozen clock, on one
  /// frosted pill. Replaces the 96×96 machined tally lamp: the dial was a
  /// beautiful object but it belonged to a different design language, took
  /// a 96pt square of screen to say what a 32pt strip says, and its VU ring
  /// duplicated the meter that now sits inline.
  private var statusPill: some View {
    HStack(spacing: 9) {
      Circle()
        .fill(pillTone)
        .frame(width: 6, height: 6)
        .shadow(color: pillTone.opacity(0.9), radius: 4)
        .opacity(pulsing ? 0.35 : 1.0)

      LevelMeter(meter: state.audioLevel, active: state.barPhase == .recording)
        .frame(width: 26, height: 14)

      Text(pillLabel)
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(TF.frostText)
        .lineLimit(1)

      if let start = state.recordingStartDate {
        RecordingTimer(
          startDate: start,
          endDate: state.barPhase == .recording || state.barPhase == .preparing
            ? nil : state.recordingStopDate
        )
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(TF.frostTextFaint)
      }

      // Style 2 folds the mode into the card's status row; the lamp-only
      // styles have no card, so the pill carries it.
      if style != .bottom {
        Text(CursorOverlayMetrics.secondarySeparator)
          .font(.system(size: 10, design: .monospaced))
          .foregroundStyle(TF.frostTextFaint)
        Text(state.currentMode.name)
          .font(.system(size: 10, weight: .medium, design: .monospaced))
          .foregroundStyle(TF.frostTextFaint)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, 16)
    .frame(height: TF.screenBottomIndicatorHeight)
    .fixedSize(horizontal: true, vertical: false)
    .frostSurface(Capsule(), backlight: pillTone)
    .onAppear {
      withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
        pulsing = true
      }
    }
  }

  private var pillTone: Color {
    switch state.barPhase {
    case .processing, .recovering: return TF.lampAmber
    case .error: return TF.settingsAccentRed
    case .done: return TF.signalTeal
    default: return TF.signalTeal
    }
  }

  private var pillLabel: String {
    switch state.barPhase {
    case .preparing: return L("准备中", "Preparing")
    case .recording: return L("正在聆听", "Listening")
    case .processing, .recovering: return state.effectiveProcessingLabel
    case .done: return L("已完成", "Done")
    case .error: return L("失败", "Failed")
    case .hidden: return ""
    }
  }

  // MARK: - Optimized Transcript Card (style 2)

  private var optimizedCard: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        StatusLED(color: optimizedTone.ledColor, pulsing: optimizedTone.pulsing)
        Text(OptimizedPanelCopy.status(for: state))
          .font(.system(size: 8.5, weight: .medium, design: .monospaced))
          .tracking(1)
          .foregroundStyle(optimizedTone.textColor)
          .lineLimit(1)
        Spacer(minLength: 8)
        cardModeMenu
        if !state.inputDeviceName.isEmpty {
          Text("· \(state.inputDeviceName)")
            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
            .tracking(1)
            .foregroundStyle(TF.frostTextFaint)
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      OptimizedPanelCopy.bottomCardText(for: state)
        .font(.system(size: TF.topTranscriptPanelBodyFontSize))
        .lineSpacing(TF.topTranscriptPanelBodyLineSpacing)
        .multilineTextAlignment(.leading)
        .foregroundStyle(cardForeground)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, TF.topTranscriptPanelHorizontalPadding)
    .padding(.vertical, 9)
    .frostSurface(cornerRadius: TF.frostPanel)
    .padding(.horizontal, 2)
  }

  private var optimizedTone: DeckMetaTone {
    OptimizedPanelCopy.tone(for: state)
  }

  /// Compact mode switcher in the card's status row, mirroring the top deck's
  /// panelModeMenu. The device name stays a static label next to it.
  private var cardModeMenu: some View {
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
            if let shortcut = state.panelModeShortcutLabel(mode) {
              Spacer()
              Text(shortcut)
            }
          }
        }
      }
    } label: {
      HStack(spacing: 3) {
        Text(state.currentMode.name)
          .lineLimit(1)
        Image(systemName: "chevron.down")
          .font(.system(size: 6, weight: .bold))
          .opacity(state.canSelectPanelMode ? 0.6 : 0.25)
      }
      .font(.system(size: 8.5, weight: .medium, design: .monospaced))
      .tracking(1)
      .foregroundStyle(TF.frostTextFaint.opacity(state.canSelectPanelMode ? 1 : 0.6))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .disabled(!state.canSelectPanelMode)
    .accessibilityLabel(L("切换处理模式", "Switch processing mode"))
  }

  /// Errors are red; status hints ("等待语音…", "此模式将直接插入原文") are
  /// dimmed so they can't be mistaken for recognized content; real content
  /// is the plain body ramp. It used to be an IME-candidate green (#7EF214),
  /// which was the loudest color in the app and belonged to no other surface.
  private var cardForeground: Color {
    if state.barPhase == .error { return TF.settingsAccentRed }
    if OptimizedPanelCopy.bottomCardIsPlaceholder(for: state) { return TF.frostTextFaint }
    return TF.frostText
  }
}

/// Borderless circular header action. Idle is glyph-only; hover brings in a
/// faint fill. Mirrors the style-3 capsule's cancel/done buttons.
private struct TopPanelGhostButton: View {
  let systemName: String
  let accessibilityLabel: String
  let tint: Color
  let action: () -> Void

  @State private var isHovered = false

  var body: some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(isHovered ? TF.frostText : tint)
        .frame(width: 22, height: 22)
        .background {
          Circle().fill(Color.white.opacity(isHovered ? 0.12 : 0))
        }
    }
    .buttonStyle(.plain)
    .onHover { isHovered = $0 }
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .accessibilityLabel(accessibilityLabel)
  }
}

/// Compact live level meter: five bars driven by the smoothed input level,
/// sized for the bottom status pill. The tally lamp's 64-tick VU ring used
/// to do this job in a 96pt circle.
private struct LevelMeter: View {
  let meter: AudioLevelMeter
  var active: Bool
  @State private var smoother = LevelSmoother(timeConstant: 0.11)

  private static let barCount = 5
  /// Per-bar response curve, so the bars don't move as one block.
  private static let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.78, 0.48]

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
      bars(time: timeline.date.timeIntervalSinceReferenceDate)
    }
  }

  private func bars(time: Double) -> some View {
    smoother.target = CGFloat(max(0, min(1, meter.current)))
    let level = active ? smoother.update(time: time) : 0
    let energy = pow(max(0, (level - 0.02) / 0.6), 0.6)

    return GeometryReader { geo in
      let height = geo.size.height
      let spacing: CGFloat = 2
      let width = (geo.size.width - spacing * CGFloat(Self.barCount - 1))
        / CGFloat(Self.barCount)
      HStack(alignment: .center, spacing: spacing) {
        ForEach(0..<Self.barCount, id: \.self) { index in
          let weight = Self.weights[index]
          // Idle bars keep a visible floor so the meter still reads as a
          // meter when nothing is being said.
          let filled = max(0.14, min(1, energy * weight))
          // White, not teal: the pill's dot already carries the state color,
          // and a second teal element made the strip read as two accents.
          Capsule()
            .fill(Color.white.opacity(active ? 0.35 + 0.45 * filled : 0.18))
            .frame(width: width, height: max(2, height * filled))
        }
      }
      .frame(width: geo.size.width, height: height, alignment: .center)
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
