import SwiftUI

/// Layout constants (module-level: generic types can't have static stored properties).
enum CursorOverlayMetrics {
  /// Fixed text-capsule width. Never grows with the transcript (a moving
  /// frame edge makes the reader's gaze drift); 460 leaves ~28 CJK chars
  /// visible before head-truncation.
  static let capsuleWidth: CGFloat = 460
  /// Whole panel == capsule width: the hover meta strip is narrower and
  /// centered underneath, so nothing ever sticks out sideways.
  static var panelWidth: CGFloat { capsuleWidth }
  /// Text cap inside the capsule: 460 − 2×17 padding − 6 dot − 10 gap.
  /// The clock and action buttons moved to the hover row, so the transcript
  /// gets the whole line instead of the 66% it had while sharing it.
  static let textMaxWidth: CGFloat = 410
  /// Per-item cap for the secondary cluster (device / mode names).
  static let secondaryItemMaxWidth: CGFloat = 90
  /// Item separator in the secondary cluster.
  static let secondarySeparator = "·"
  /// Backlit accent for live state, shared with every other overlay.
  static var liveTeal: Color { TF.signalTeal }

  /// Cancel / done buttons only exist while capturing; processing and later
  /// phases are display-only.
  static func showsActionButtons(_ phase: FloatingBarPhase) -> Bool {
    phase == .preparing || phase == .recording
  }
}

/// Font the transcript text renders with; used to detect head-truncation.
private let cursorTranscriptFont = NSFont.systemFont(ofSize: 13.5, weight: .regular)

/// Shared copy for the capsule, used by both the view and the controller.
@MainActor
enum CursorOverlayCopy {
  static func displayText<S: FloatingBarState>(for state: S) -> String {
    // The failure message wins over the transcript: on .error the transcript
    // is what was lost, and showing it as though nothing happened is worse
    // than showing nothing.
    if state.barPhase == .error {
      return state.feedbackMessage.isEmpty ? L("识别失败", "Recognition failed") : state.feedbackMessage
    }
    if !state.transcriptionText.isEmpty { return state.transcriptionText }
    switch state.barPhase {
    case .preparing: return L("准备中…", "Preparing…")
    case .recording: return L("正在聆听…", "Listening…")
    case .processing, .recovering: return state.effectiveProcessingLabel
    default: return ""
    }
  }

  /// Bottom meta strip content (device · mode · length · timer · speed).
  struct Secondary {
    let device: String?
    let mode: String
    let charCount: String
    /// Average input speed ("142字/分"), nil until 2s of speech.
    let speed: String?
  }

  static func secondary<S: FloatingBarState>(for state: S) -> Secondary {
    let speed: String? = {
      let count = state.transcriptionText.count
      guard let start = state.recordingStartDate, count > 0 else { return nil }
      // Freeze at stop time so the rate doesn't decay through processing.
      let end = state.recordingStopDate ?? Date()
      let elapsed = end.timeIntervalSince(start)
      guard elapsed >= 2 else { return nil }
      let perMinute = Int(Double(count) / elapsed * 60)
      return L("\(perMinute)字/分", "\(perMinute)/min")
    }()
    return Secondary(
      device: state.inputDeviceName.isEmpty ? nil : state.inputDeviceName,
      mode: state.currentMode.name,
      charCount: L("\(state.transcriptionText.count)字", "\(state.transcriptionText.count) ch"),
      speed: speed
    )
  }
}

/// Single-row transcript overlay (style 3 · 悬浮胶囊). Everything lives on one
/// line: breathing dot, transcript, frozen timer, and two ghost buttons
/// (✕ cancel, ✓ done) that exist only while capturing. The meta strip
/// (device · mode · length · speed) is NOT always-on — it fades in under the
/// capsule on hover, because during dictation the eye is on the text and a
/// permanently visible second row of 9pt monospace was just noise.
///
/// The capsule width is FIXED — a moving frame edge makes the reader's gaze
/// drift — and overflow head-truncates with a leading fade. The breathing
/// dot's halo bleeds into the capsule as a backlight (teal while listening,
/// amber while working). Presses outside the buttons drag the panel;
/// double-click re-centers it.
struct CursorOverlayView<S: FloatingBarState>: View {
  var state: S
  /// Done button: forwards to `state.requestPanelStop()` (stop & insert).
  let onSend: () -> Void

  @State private var pulsing = false
  @State private var metaVisible = false
  /// Delays the hover row's dismissal so the pointer can travel to its
  /// buttons without them vanishing en route.
  @State private var hoverDismiss: DispatchWorkItem?
  /// Trailing typewriter buffer. ASR partials arrive in bursts of several
  /// characters, and rendering the raw string makes them pop in as chunks.
  /// Pure appends (the common case for cumulative partials) are revealed one
  /// character at a time; corrections that rewrite earlier text swap at once.
  @State private var revealedText = ""
  @State private var revealTask: Task<Void, Never>?

  private enum Tone {
    /// Placeholder copy ("Listening…") — dimmed.
    case hint
    /// Live recognized text.
    case live
    /// Post-processing under way — amber dot, frozen text.
    case working
    /// Something failed — red dot, no pulse.
    case failed
  }

  private var tone: Tone {
    switch state.barPhase {
    case .recording:
      return state.transcriptionText.isEmpty ? .hint : .live
    case .processing, .recovering:
      // A pending final-optimization failure keeps the panel up in these
      // phases, so the dot has to be able to say "failed" here too.
      return state.finalOptimizationFailureMessage == nil ? .working : .failed
    case .error:
      return .failed
    default:
      return state.transcriptionText.isEmpty ? .hint : .live
    }
  }

  private var displayText: String {
    CursorOverlayCopy.displayText(for: state)
  }

  private var buttonsVisible: Bool {
    CursorOverlayMetrics.showsActionButtons(state.barPhase)
  }

  var body: some View {
    VStack(alignment: .center, spacing: 4) {
      mainCapsule

      // Hover-revealed meta. Always occupies its row so the capsule never
      // shifts when it appears — only its opacity changes.
      secondaryCluster
        .opacity(metaVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.18), value: metaVisible)
    }
    .padding(2)
    // Pin to the panel's top edge so resize animations stay anchored.
    .frame(maxHeight: .infinity, alignment: .top)
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: buttonsVisible)
    .onHover { inside in
      hoverDismiss?.cancel()
      hoverDismiss = nil
      if inside {
        metaVisible = true
        return
      }
      // Grace period: the row holds ✕ and ✓, so hiding it the instant the
      // pointer leaves the capsule would snatch the buttons away mid-reach.
      let work = DispatchWorkItem { metaVisible = false }
      hoverDismiss = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }
    .onAppear {
      revealedText = displayText
      withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
        pulsing = true
      }
    }
    .onChange(of: displayText) { _, newText in
      revealTask?.cancel()
      let current = revealedText
      // Typewriter only a pure append on top of what's already visible;
      // anything else (correction, reset, phase label) swaps instantly.
      guard newText != current, newText.hasPrefix(current) else {
        revealedText = newText
        return
      }
      let suffix = newText.dropFirst(current.count)
      revealTask = Task { @MainActor in
        var text = current
        var remaining = suffix
        while !remaining.isEmpty {
          try? await Task.sleep(for: .milliseconds(24))
          if Task.isCancelled { return }
          // Catch-up gradient: the further behind the ASR stream, the more
          // characters per tick — smooth acceleration instead of one jump.
          let take = remaining.count > 30 ? 3 : remaining.count > 12 ? 2 : 1
          text.append(contentsOf: remaining.prefix(take))
          remaining = remaining.dropFirst(take)
          revealedText = text
        }
      }
    }
  }

  // MARK: - Center capsule

  /// Dot + transcript, and nothing else. The clock and the two ghost buttons
  /// used to ride along here, which put 114pt of chrome on the right against
  /// a 6pt dot on the left — the capsule visibly leaned, and the text (the
  /// entire point of the surface) was squeezed to 66% of the width while
  /// still head-truncating. They live in the hover row now; this row is the
  /// transcript's.
  private var mainCapsule: some View {
    HStack(spacing: 10) {
      Circle()
        .fill(dotColor)
        .frame(width: 6, height: 6)
        .shadow(color: dotColor.opacity(0.9), radius: 4)
        // A failed state holds steady — a breathing red dot reads as "still
        // working on it" when the opposite is true.
        .opacity(pulsing && tone != .failed ? 0.35 : 1.0)
      transcriptText
      Spacer(minLength: 0)
    }
    // Symmetric now that nothing hangs off the trailing edge.
    .padding(.horizontal, 17)
    .padding(.vertical, 8)
    .frame(width: CursorOverlayMetrics.capsuleWidth)
    .frostSurface(Capsule(), backlight: dotColor)
  }

  /// Phase readout for the hover row: elapsed clock while capturing, the
  /// processing label once it ends.
  @ViewBuilder private var inlineStatus: some View {
    Group {
      switch state.barPhase {
      case .processing, .recovering:
        Text(state.effectiveProcessingLabel)
          .foregroundStyle(TF.lampAmber.opacity(0.9))
          .lineLimit(1)
      default:
        if let start = state.recordingStartDate {
          RecordingTimer(
            startDate: start,
            endDate: state.barPhase == .recording || state.barPhase == .preparing
              ? nil : state.recordingStopDate
          )
          .foregroundStyle(TF.frostTextDim)
        }
      }
    }
    .font(.system(size: 9, weight: .medium, design: .monospaced))
    .fixedSize()
  }

  /// Transcript tail. The leading-edge fade is only applied once the text
  /// actually overflows the width cap and head-truncation kicks in — an
  /// always-on mask shades the first glyphs of every short utterance. (The
  /// old marked-text underline was removed: it never changed with state, so
  /// it communicated nothing; liveness is the dot's job now.)
  @ViewBuilder private var transcriptText: some View {
    let base = Text(revealedText)
      .font(.system(size: 13.5, weight: .regular))
      .foregroundStyle(textColor)
      .lineLimit(1)
      .truncationMode(.head)
      .frame(maxWidth: CursorOverlayMetrics.textMaxWidth, alignment: .leading)
    if needsHeadFade {
      base.mask {
        HStack(spacing: 0) {
          LinearGradient(
            colors: [.clear, .white],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: 12)
          Rectangle()
        }
      }
    } else {
      base
    }
  }

  private var needsHeadFade: Bool {
    ceil(
      (revealedText as NSString).size(withAttributes: [.font: cursorTranscriptFont]).width
    ) > CursorOverlayMetrics.textMaxWidth
  }

  /// Hover row: device · mode · length · speed · clock, then the two actions.
  /// This row holds real controls now, so it can't blink out the instant the
  /// pointer crosses a gap — see `metaVisible`'s grace period.
  ///
  /// No pill of its own: a second chromed object under the capsule read as
  /// two competing surfaces. But bare text needs *some* floor — over a white
  /// document 9pt at 0.34 alpha measured 1.0:1, i.e. perfectly invisible at
  /// exactly the moment the user hovered to read it. A soft blurred scrim
  /// gives contrast without becoming an object: no edge, no corner radius.
  private var secondaryCluster: some View {
    let secondary = CursorOverlayCopy.secondary(for: state)
    return HStack(spacing: 7) {
      HStack(spacing: 5) {
        if let device = secondary.device {
          Text(device)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: CursorOverlayMetrics.secondaryItemMaxWidth)
          Text(CursorOverlayMetrics.secondarySeparator)
        }
        Text(secondary.mode)
          .lineLimit(1)
          .truncationMode(.tail)
          .frame(maxWidth: CursorOverlayMetrics.secondaryItemMaxWidth)
        Text(CursorOverlayMetrics.secondarySeparator)
        Text(secondary.charCount)
        if let speed = secondary.speed {
          Text(CursorOverlayMetrics.secondarySeparator)
          Text(speed)
        }
      }
      .font(.system(size: 9, weight: .medium, design: .monospaced))
      .foregroundStyle(TF.frostTextDim)

      inlineStatus

      if buttonsVisible {
        GhostButton(
          symbol: "xmark",
          primary: false,
          help: L("取消并丢弃本次录音", "Cancel and discard this recording"),
          accessibilityLabel: L("取消", "Cancel")
        ) {
          state.requestPanelCancel()
        }
        GhostButton(
          symbol: "checkmark",
          primary: true,
          help: L("停止并插入", "Stop and insert"),
          accessibilityLabel: L("完成", "Done")
        ) {
          onSend()
        }
      }
    }
    .fixedSize()
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
    .background {
      Capsule()
        .fill(.black.opacity(0.45))
        .blur(radius: 6)
    }
  }

  private var dotColor: Color {
    switch tone {
    case .live: return TF.signalTeal
    case .working: return TF.lampAmber
    case .failed: return TF.settingsAccentRed
    case .hint: return .white.opacity(0.4)
    }
  }

  private var textColor: Color {
    switch tone {
    // Warm white body text; the teal is reserved for accents (dot, ✓ button,
    // backlight). A full run of teal read like IME candidate text.
    case .live: return TF.frostText
    case .working, .failed: return TF.frostTextDim
    case .hint: return .white.opacity(0.45)
    }
  }
}

// MARK: - Ghost Button

/// Icon-only circular action inside the capsule (✕ cancel / ✓ done).
/// Deliberately understated — labels alongside the transcript competed with
/// it for the same reading line, and the 30pt flanking orbs before that were
/// louder still. Real NSButton overlay so the panel's hit-test treats it as
/// clickable rather than as drag surface.
private struct GhostButton: View {
  let symbol: String
  let primary: Bool
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  @State private var isHovered = false

  private var tint: Color {
    primary ? TF.signalTeal : .white
  }

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(tint.opacity(isHovered ? 1.0 : primary ? 0.85 : 0.45))
      .frame(width: 22, height: 22)
      .background {
        Circle().fill(
          primary
            ? TF.signalTeal.opacity(isHovered ? 0.22 : 0.11)
            : Color.white.opacity(isHovered ? 0.14 : 0.06)
        )
      }
      .overlay {
        CapsuleClickButton(
          toolTip: help,
          accessibilityLabel: accessibilityLabel,
          onHoverChanged: { isHovered = $0 },
          action: action
        )
      }
      .animation(.easeOut(duration: 0.12), value: isHovered)
  }
}

// MARK: - Capsule Click Button

/// Transparent real NSButton for the ghost actions. Unlike a SwiftUI Button, an
/// NSButton shows up in the panel's hit-test, so the window can let its
/// clicks through and drag everything else. Title explicitly emptied —
/// NSButton's default title is the literal string "Button".
private struct CapsuleClickButton: NSViewRepresentable {
  let toolTip: String
  let accessibilityLabel: String
  let onHoverChanged: ((Bool) -> Void)?
  let action: () -> Void

  func makeNSView(context: Context) -> CapsuleCircleNSButton {
    let button = CapsuleCircleNSButton()
    configure(button)
    return button
  }

  func updateNSView(_ nsView: CapsuleCircleNSButton, context: Context) {
    configure(nsView)
  }

  private func configure(_ button: CapsuleCircleNSButton) {
    button.title = ""
    button.image = nil
    button.isBordered = false
    button.setButtonType(.momentaryPushIn)
    button.focusRingType = .none
    button.toolTip = toolTip
    button.setAccessibilityLabel(accessibilityLabel)
    button.onClick = action
    button.onHoverChanged = onHoverChanged
  }
}

/// Action target for CapsuleCircleNSButton. NSButton consumes the mouse-up
/// inside its own tracking loop, so an overridden mouseUp(with:) never
/// fires — the click must flow through the classic target/action mechanism.
private final class CapsuleClickTarget: NSObject {
  var handler: (() -> Void)?
  @objc func clicked(_ sender: Any?) { handler?() }
}

private final class CapsuleCircleNSButton: NSButton {
  var onClick: (() -> Void)? {
    get { clickTarget.handler }
    set { clickTarget.handler = newValue }
  }
  var onHoverChanged: ((Bool) -> Void)?
  private let clickTarget = CapsuleClickTarget()

  init() {
    super.init(frame: .zero)
    target = clickTarget
    action = #selector(CapsuleClickTarget.clicked(_:))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self
      )
    )
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
  override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}
