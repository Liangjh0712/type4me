import SwiftUI

/// Layout constants (module-level: generic types can't have static stored properties).
enum CursorOverlayMetrics {
  /// Fixed text-capsule width. Never grows with the transcript (a moving
  /// frame edge makes the reader's gaze drift); 480 leaves ~30 CJK chars
  /// visible before head-truncation.
  static let capsuleWidth: CGFloat = 480
  /// Whole panel == capsule width: the action pills live in the meta row,
  /// pinned to its left/right edges, so nothing sticks out sideways.
  static var panelWidth: CGFloat { capsuleWidth }
  /// Text cap inside the capsule (padding + dot + slack).
  static let textMaxWidth: CGFloat = 436
  /// Per-item cap for the secondary cluster (device / mode names).
  static let secondaryItemMaxWidth: CGFloat = 90
  /// Item separator in the secondary cluster.
  static let secondarySeparator = "·"
  /// Backlit accent for live state, shared with the shortcut deck.
  static let liveTeal = Color(red: 0.38, green: 0.85, blue: 0.76)

  /// Cancel / done orbs only exist while capturing; processing and later
  /// phases are display-only.
  static func showsActionButtons(_ phase: FloatingBarPhase) -> Bool {
    phase == .preparing || phase == .recording
  }
}

/// Font the transcript text renders with; used to detect head-truncation.
private let cursorTranscriptFont = NSFont.systemFont(ofSize: 13, weight: .medium)

/// Shared copy for the capsule, used by both the view and the controller.
@MainActor
enum CursorOverlayCopy {
  static func displayText<S: FloatingBarState>(for state: S) -> String {
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

/// Three-island transcript overlay (style 3 · 悬浮胶囊): the text capsule
/// sits center stage, flanked by two detached action orbs (× cancel left,
/// ✓ done right) that exist only while capturing. Detaching the buttons is
/// what finally killed the perennial "gap" complaint: inside the capsule
/// there is only dot + text, so short text leaves quiet capacity instead of
/// a visible void between text and ✓. The capsule width is FIXED — a moving
/// frame edge makes the reader's gaze drift — and overflow head-truncates
/// with a leading fade. The breathing dot's halo bleeds into the capsule as
/// a backlight (teal while listening, amber while working). Presses outside
/// the orbs drag the panel; double-click re-centers it.
struct CursorOverlayView<S: FloatingBarState>: View {
  var state: S
  /// Done orb: forwards to `state.requestPanelStop()` (stop & insert).
  let onSend: () -> Void

  @State private var pulsing = false
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
  }

  private var tone: Tone {
    switch state.barPhase {
    case .recording:
      return state.transcriptionText.isEmpty ? .hint : .live
    case .processing, .recovering:
      return .working
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

      // Second row: cancel pill pinned to the LEFT edge, meta strip dead
      // center, done pill pinned RIGHT. All three hold fixed positions —
      // the strip grows/shrinks around its own center without moving the
      // pills, and the pills' show/hide never shifts the strip.
      ZStack {
        // Meta strip: hugs its content, centered under the capsule.
        secondaryCluster
          .padding(.horizontal, 12)
          .padding(.vertical, 2)
          .background(
            Capsule()
              .fill(.ultraThinMaterial)
              .overlay(Capsule().fill(.black.opacity(0.32)))
          )
          .overlay(
            Capsule()
              .strokeBorder(.white.opacity(0.09), lineWidth: 0.5)
          )

        HStack(spacing: 0) {
          if buttonsVisible {
            ActionPill(
              symbol: "xmark",
              label: L("取消", "Cancel"),
              primary: false,
              help: L("取消并丢弃本次录音", "Cancel and discard this recording"),
              accessibilityLabel: L("取消", "Cancel")
            ) {
              state.requestPanelCancel()
            }
            .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
          }
          Spacer(minLength: 0)
          if buttonsVisible {
            ActionPill(
              symbol: "checkmark",
              label: L("完成", "Done"),
              primary: true,
              help: L("停止并插入", "Stop and insert"),
              accessibilityLabel: L("完成", "Done")
            ) {
              onSend()
            }
            .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .trailing)))
          }
        }
      }
      .frame(width: CursorOverlayMetrics.capsuleWidth)
    }
    .padding(2)
    // Pin to the panel's top edge so resize animations stay anchored.
    .frame(maxHeight: .infinity, alignment: .top)
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: buttonsVisible)
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

  /// Dot + transcript, left-aligned. The empty region to the right of short
  /// text is deliberate capacity, exactly like a half-filled text field.
  private var mainCapsule: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(dotColor)
        .frame(width: 6, height: 6)
        .shadow(color: dotColor.opacity(0.9), radius: 4)
        .opacity(pulsing ? 0.35 : 1.0)
      transcriptText
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 6)
    .frame(width: CursorOverlayMetrics.capsuleWidth)
    .background(
      Capsule()
        .fill(.ultraThinMaterial)
        .overlay(
          // Dark tint over frosted glass: the wallpaper's hue bleeds through
          // while text contrast stays stable over busy backgrounds.
          Capsule()
            .fill(
              LinearGradient(
                colors: [.black.opacity(0.38), .black.opacity(0.50)],
                startPoint: .top,
                endPoint: .bottom
              )
            )
        )
        .overlay(
          // Backlight: the status dot's halo bleeds into the capsule body,
          // carrying the state color (teal listening / amber working).
          Capsule()
            .fill(
              RadialGradient(
                colors: [dotColor.opacity(0.12), .clear],
                center: .leading,
                startRadius: 0,
                endRadius: 140
              )
            )
        )
    )
    .overlay(
      Capsule()
        .strokeBorder(
          LinearGradient(
            colors: [.white.opacity(0.16), .white.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 0.5
        )
    )
  }

  /// Transcript tail. The leading-edge fade is only applied once the text
  /// actually overflows the width cap and head-truncation kicks in — an
  /// always-on mask shades the first glyphs of every short utterance. (The
  /// old marked-text underline was removed: it never changed with state, so
  /// it communicated nothing; liveness is the dot's job now.)
  @ViewBuilder private var transcriptText: some View {
    let base = Text(revealedText)
      .font(.system(size: 13, weight: .medium))
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

  /// Meta row: input device · mode · char count · timer · average speed.
  private var secondaryCluster: some View {
    let secondary = CursorOverlayCopy.secondary(for: state)
    return HStack(spacing: 5) {
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
      if let start = state.recordingStartDate {
        Text(CursorOverlayMetrics.secondarySeparator)
        // Freeze the clock once capture ends — the strip is always visible,
        // so a timer that keeps counting through processing reads as a bug.
        RecordingTimer(
          startDate: start,
          endDate: state.barPhase == .recording || state.barPhase == .preparing
            ? nil : state.recordingStopDate
        )
      }
      if let speed = secondary.speed {
        Text(CursorOverlayMetrics.secondarySeparator)
        Text(speed)
      }
    }
    .font(.system(size: 9, weight: .medium, design: .monospaced))
    .foregroundStyle(.white.opacity(0.42))
    .fixedSize()
  }

  private var dotColor: Color {
    switch tone {
    case .live: return CursorOverlayMetrics.liveTeal
    case .working: return TF.lampAmber
    case .hint: return .white.opacity(0.4)
    }
  }

  private var textColor: Color {
    switch tone {
    // Warm white body text; the teal is reserved for accents (dot, ✓ orb,
    // backlight). A full run of teal read like IME candidate text.
    case .live: return .white.opacity(0.92)
    case .working: return .white.opacity(0.7)
    case .hint: return .white.opacity(0.45)
    }
  }
}

// MARK: - Action Pill

/// Small text pill in the meta row (✕ 取消 / ✓ 完成). Deliberately
/// understated — the 30pt orbs flanking the capsule felt too loud — while
/// the teal tint preserves the done action's primacy. Real NSButton overlay
/// so the panel's hit-test treats it as clickable.
private struct ActionPill: View {
  let symbol: String
  let label: String
  let primary: Bool
  let help: String
  let accessibilityLabel: String
  let action: () -> Void

  @State private var isHovered = false

  private var tint: Color {
    primary ? CursorOverlayMetrics.liveTeal : .white
  }

  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: symbol)
        .font(.system(size: 7, weight: .bold))
      Text(label)
        .font(.system(size: 9, weight: .semibold))
    }
    .foregroundStyle(tint.opacity(isHovered ? 1.0 : primary ? 0.9 : 0.6))
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      Capsule()
        .fill(.ultraThinMaterial)
        .overlay(Capsule().fill(.black.opacity(isHovered ? 0.45 : 0.32)))
    )
    .overlay(
      Capsule()
        .strokeBorder(
          primary
            ? CursorOverlayMetrics.liveTeal.opacity(isHovered ? 0.45 : 0.30)
            : .white.opacity(isHovered ? 0.20 : 0.12),
          lineWidth: 0.5
        )
    )
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

/// Transparent real NSButton for the orbs. Unlike a SwiftUI Button, an
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
