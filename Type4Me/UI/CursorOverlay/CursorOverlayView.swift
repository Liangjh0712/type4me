import SwiftUI

/// Layout constants (module-level: generic types can't have static stored properties).
enum CursorOverlayMetrics {
  /// Cap on the text run. The capsule hugs short text and grows with the
  /// transcript up to this width before head-truncating.
  static let textMaxWidth: CGFloat = 560
  /// Per-item cap for the secondary cluster (device / mode names).
  static let secondaryItemMaxWidth: CGFloat = 90
  /// Item separator in the secondary cluster.
  static let secondarySeparator = "·"
  /// Backlit accent for live recognized text, shared with the shortcut deck.
  static let liveTeal = Color(red: 0.38, green: 0.85, blue: 0.76)

  /// Cancel / send buttons only exist while capturing (matches the top
  /// panel's rule); processing and later phases are display-only.
  static func showsActionButtons(_ phase: FloatingBarPhase) -> Bool {
    phase == .preparing || phase == .recording
  }

  /// Text cap shrinks by the two buttons' footprint when they're visible.
  static func textMaxWidth(buttonsVisible: Bool) -> CGFloat {
    buttonsVisible ? 508 : 560
  }

  /// Meta row indent: aligns under the text, past the dot (and the close
  /// button when present).
  static func metaIndent(buttonsVisible: Bool) -> CGFloat {
    buttonsVisible ? 38 : 12
  }
}

/// Font the transcript text renders with; used to detect head-truncation.
private let cursorTranscriptFont = NSFont.systemFont(ofSize: 13, weight: .medium)

/// Shared copy for the capsule, used by both the view and the controller's
/// text measurement (same reason OptimizedPanelCopy exists: the controller
/// measures with NSString and must agree with what the view renders).
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

  /// Right-side secondary cluster content (device · mode · char count).
  /// The ticking recording timer is a live SwiftUI Text and stays view-side.
  struct Secondary {
    let device: String?
    let mode: String
    let charCount: String
  }

  static func secondary<S: FloatingBarState>(for state: S) -> Secondary {
    Secondary(
      device: state.inputDeviceName.isEmpty ? nil : state.inputDeviceName,
      mode: state.currentMode.name,
      charCount: L("\(state.transcriptionText.count)字", "\(state.transcriptionText.count) ch")
    )
  }
}

/// Borderless capsule at a fixed, user-draggable position (style 3 · 悬浮胶囊).
/// Two stacked bars: the main capsule carries cancel / done buttons (while
/// capturing), the status dot and the live transcript tail; an ultra-thin
/// strip below it permanently shows the meta cluster (device · mode ·
/// length · timer). The teal accent is the "this is what would be inserted"
/// cue (it replaced the IME-candidate green, which clashed with the dark
/// island palette); the underline is a nod to marked text. Presses outside
/// the two buttons drag the panel.
struct CursorOverlayView<S: FloatingBarState>: View {
  var state: S
  /// Done button: forwards to `state.requestPanelStop()` (stop & insert).
  let onSend: () -> Void

  @State private var pulsing = false
  /// Trailing typewriter buffer. ASR partials arrive in bursts of several
  /// characters, and rendering the raw string makes them pop in as chunks.
  /// Pure appends (the common case for cumulative partials) are revealed one
  /// character at a time; corrections that rewrite earlier text swap at once.
  @State private var revealedText = ""
  @State private var revealTask: Task<Void, Never>?

  private enum Tone {
    /// Placeholder copy ("Listening…") — dimmed, no underline.
    case hint
    /// Live recognized text — teal + underline.
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
    VStack(alignment: .leading, spacing: 4) {
      // Main capsule: cancel / send buttons (while capturing) + dot + text.
      HStack(spacing: 8) {
        if buttonsVisible {
          capsuleButton(
            symbol: "xmark",
            tint: .white,
            help: L("取消并丢弃本次录音", "Cancel and discard this recording"),
            accessibilityLabel: L("取消", "Cancel")
          ) {
            state.requestPanelCancel()
          }
        }

        HStack(spacing: 6) {
          Circle()
            .fill(dotColor)
            .frame(width: 6, height: 6)
            .shadow(color: dotColor.opacity(0.9), radius: 4)
            .opacity(pulsing ? 0.35 : 1.0)
          transcriptText
        }

        if buttonsVisible {
          Spacer(minLength: 0)
          capsuleButton(
            symbol: "checkmark",
            tint: CursorOverlayMetrics.liveTeal,
            help: L("停止并插入", "Stop and insert"),
            accessibilityLabel: L("完成", "Done")
          ) {
            onSend()
          }
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      // The capsule fills the panel's width: resizing happens only in the
      // controller's animated setFrame, so chrome and content stay in sync.
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Capsule()
          .fill(.ultraThinMaterial)
          .overlay(
            // Dark tint over frosted glass: the wallpaper's hue bleeds through
            // (ambient, not stark black) while text contrast stays stable over
            // busy or bright backgrounds.
            Capsule()
              .fill(
                LinearGradient(
                  colors: [.black.opacity(0.38), .black.opacity(0.50)],
                  startPoint: .top,
                  endPoint: .bottom
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

      // Secondary strip: a permanently visible, ultra-thin bar under the main
      // capsule carrying the meta cluster (device · mode · length · timer).
      secondaryCluster
        .padding(.leading, CursorOverlayMetrics.metaIndent(buttonsVisible: buttonsVisible) + 12)
        .padding(.trailing, 12)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
          Capsule()
            .fill(.ultraThinMaterial)
            .overlay(Capsule().fill(.black.opacity(0.32)))
        )
        .overlay(
          Capsule()
            .strokeBorder(.white.opacity(0.09), lineWidth: 0.5)
        )
    }
    .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
    .padding(6)
    // Pin to the panel's top edge so resize animations stay anchored.
    .frame(maxHeight: .infinity, alignment: .top)
    .animation(.easeOut(duration: 0.16), value: buttonsVisible)
    .onAppear {
      revealedText = displayText
      withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
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
          try? await Task.sleep(for: .milliseconds(30))
          if Task.isCancelled { return }
          // Catch up when a long burst lands: never trail the ASR stream.
          let take = remaining.count > 14 ? 2 : 1
          text.append(contentsOf: remaining.prefix(take))
          remaining = remaining.dropFirst(take)
          revealedText = text
        }
      }
    }
  }

  /// Transcript tail. The leading-edge fade is only applied once the text
  /// actually overflows the width cap and head-truncation kicks in — an
  /// always-on mask shades the first glyphs of every short utterance.
  @ViewBuilder private var transcriptText: some View {
    let base = Text(revealedText)
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(textColor)
      .underline(tone == .live, color: CursorOverlayMetrics.liveTeal.opacity(0.5))
      .lineLimit(1)
      .truncationMode(.head)
      .frame(
        maxWidth: CursorOverlayMetrics.textMaxWidth(buttonsVisible: buttonsVisible),
        alignment: .leading
      )
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
    ) > CursorOverlayMetrics.textMaxWidth(buttonsVisible: buttonsVisible)
  }

  /// Small circular action button at either end of the capsule. The click
  /// target is a real NSButton: the panel's sendEvent hit-tests it directly,
  /// so clicks never depend on hand-computed rects that can drift away from
  /// SwiftUI's actual layout (the bug where ✓ clicks fell through to drag).
  private func capsuleButton(
    symbol: String,
    tint: Color,
    help: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Circle()
      .fill(.white.opacity(0.08))
      .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
      .frame(width: 18, height: 18)
      .overlay {
        CapsuleClickButton(
          symbol: symbol,
          tint: NSColor(tint.opacity(0.85)),
          toolTip: help,
          accessibilityLabel: accessibilityLabel,
          action: action
        )
      }
  }

  /// Meta row: input device · mode · char count · timer.
  /// Children order and spacing must match the controller's secondaryWidth().
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
    case .live: return CursorOverlayMetrics.liveTeal
    case .working: return .white.opacity(0.7)
    case .hint: return .white.opacity(0.45)
    }
  }
}

// MARK: - Capsule Click Button

/// Real AppKit button for the capsule's end actions. Unlike a SwiftUI
/// Button, an NSButton shows up in the panel's hit-test, so the window can
/// let its clicks through and drag everything else.
private struct CapsuleClickButton: NSViewRepresentable {
  let symbol: String
  let tint: NSColor
  let toolTip: String
  let accessibilityLabel: String
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
    let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)?
      .withSymbolConfiguration(config)
    button.imagePosition = .imageOnly
    button.isBordered = false
    button.setButtonType(.momentaryPushIn)
    button.focusRingType = .none
    button.contentTintColor = tint
    button.toolTip = toolTip
    button.setAccessibilityLabel(accessibilityLabel)
    button.onClick = action
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
  private let clickTarget = CapsuleClickTarget()

  init() {
    super.init(frame: .zero)
    target = clickTarget
    action = #selector(CapsuleClickTarget.clicked(_:))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
