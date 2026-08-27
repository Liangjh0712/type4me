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
}

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

/// Borderless capsule anchored at the text caret (style 3 · 光标跟随).
/// Shows the live transcript tail in the IME-candidate green
/// (`TF.bottomCardLive` — the established "this is what would be inserted"
/// color) with an underline nod to marked text. Non-interactive: the hosting
/// panel ignores mouse events.
struct CursorOverlayView<S: FloatingBarState>: View {
  var state: S

  @State private var pulsing = false

  private enum Tone {
    /// Placeholder copy ("Listening…") — dimmed, no underline.
    case hint
    /// Live recognized text — candidate green + underline.
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

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(dotColor)
        .frame(width: 6, height: 6)
        .opacity(pulsing ? 0.35 : 1.0)
      Text(displayText)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(textColor)
        .underline(tone == .live, color: TF.bottomCardLive.opacity(0.55))
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: CursorOverlayMetrics.textMaxWidth, alignment: .leading)
      secondaryCluster
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 3)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(TF.ink1.opacity(0.92))
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(TF.deckLine, lineWidth: 1)
        )
    )
    .onAppear {
      withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
        pulsing = true
      }
    }
  }

  /// Right-side secondary info: input device · mode · char count · timer.
  /// Children order and spacing must match the controller's secondaryWidth().
  private var secondaryCluster: some View {
    let secondary = CursorOverlayCopy.secondary(for: state)
    return HStack(spacing: 5) {
      Rectangle()
        .fill(TF.deckLine)
        .frame(width: 1, height: 10)
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
        Text(start, style: .timer)
      }
    }
    .font(.system(size: 9, weight: .medium, design: .monospaced))
    .foregroundStyle(TF.paperFaint)
    .fixedSize()
  }

  private var dotColor: Color {
    switch tone {
    case .live: return TF.bottomCardLive
    case .working: return TF.lampAmber
    case .hint: return TF.paperFaint
    }
  }

  private var textColor: Color {
    switch tone {
    case .live: return TF.bottomCardLive
    case .working: return TF.paperDim
    case .hint: return TF.paperFaint
    }
  }
}
