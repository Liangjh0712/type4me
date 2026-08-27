import AppKit
import SwiftUI

/// Borderless capsule panel for the cursor overlay. Same NSPanel idioms as
/// the other floating surfaces (see HeadsetButtonToastPanel /
/// FloatingBarPanel), except it accepts mouse events: the capsule is
/// draggable so the user can move it when it occludes content.
final class CursorOverlayPanel: NSPanel {
  /// Called after any press-drag on the capsule.
  var onUserDrag: (() -> Void)?

  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 160, height: 30)),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    level = .floating
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    ignoresMouseEvents = false
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    animationBehavior = .none
    appearance = NSAppearance(named: .darkAqua)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown {
      // No interactive controls — every press is a drag (the occlusion
      // escape hatch). Non-activating panel: focus stays with the target app.
      performDrag(with: event)
      onUserDrag?()
      return
    }
    super.sendEvent(event)
  }
}

/// Drives the style-3 cursor overlay: shows the capsule next to the mouse
/// pointer when recording starts, keeps it through post-processing, hides on
/// completion.
///
/// Anchoring is deliberately mouse-only, captured ONCE per recording: the
/// pointer sits where the user just clicked (almost always the target
/// field), and it never lies — caret geometry via accessibility was tried
/// and abandoned (multi-channel probing still proved unreliable across real
/// apps). The capsule never re-anchors on its own, but the user can drag
/// it; manual placement wins over auto-layout for the rest of the session.
///
/// Subscribes to AppState via Swift Observation (withObservationTracking) so
/// the existing single-assignment panel closures stay owned by
/// FloatingBarController.
@MainActor
final class CursorOverlayController {
  private let state: AppState
  private let panel = CursorOverlayPanel()
  private let hosting: NSHostingView<CursorOverlayView<AppState>>

  /// Anchor captured once at recording start, in Cocoa screen coordinates.
  private var anchor: CGRect?
  /// Set when the user drags the capsule: auto-placement stops overriding
  /// the origin (size still tracks the transcript).
  private var userHasRepositioned = false
  private var lastPhase: FloatingBarPhase = .hidden

  init(state: AppState) {
    self.state = state
    hosting = NSHostingView(rootView: CursorOverlayView(state: state))
    hosting.sizingOptions = []
    panel.contentView = hosting
    panel.onUserDrag = { [weak self] in
      MainActor.assumeIsolated { self?.userHasRepositioned = true }
    }
    startObserving()
  }

  // MARK: - Observation

  private func startObserving() {
    withObservationTracking {
      _ = state.barPhase
      _ = state.transcriptionText
    } onChange: { [weak self] in
      // onChange fires from willSet — hop a runloop tick for fresh values.
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated { self?.handleStateChange() }
      }
    }
  }

  private func handleStateChange() {
    startObserving()  // one-shot: re-register before reading

    let phase = state.barPhase
    let wasActive = lastPhase == .preparing || lastPhase == .recording
    let isActive = phase == .preparing || phase == .recording
    let enteredRecording = isActive && !wasActive
    lastPhase = phase

    guard TranscriptPanelStyle.current() == .cursor else {
      if panel.isVisible { hide() }
      return
    }

    if enteredRecording {
      captureAnchorAndShow()
    }

    switch phase {
    case .hidden, .done, .error:
      hide()
    default:
      // Re-fit the capsule as the transcript grows; the anchor is static.
      if panel.isVisible { updateFrame() }
    }
  }

  // MARK: - Show / hide

  private func captureAnchorAndShow() {
    // Tooltip geometry: anchor just right of the pointer tip, capsule hangs
    // below it (flips above near the screen bottom via placement rules).
    let mouse = NSEvent.mouseLocation
    anchor = CGRect(x: mouse.x + 14, y: mouse.y - 16, width: 1, height: 16)
    userHasRepositioned = false
    updateFrame()
    guard !panel.isVisible else { return }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      panel.animator().alphaValue = 1
    }
  }

  private func hide() {
    anchor = nil
    guard panel.isVisible else { return }
    let panelRef = panel
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.15
        panelRef.animator().alphaValue = 0
      },
      completionHandler: {
        MainActor.assumeIsolated { panelRef.orderOut(nil) }
      }
    )
  }

  // MARK: - Geometry

  private func updateFrame() {
    let size = measuredSize()
    let origin: NSPoint
    if userHasRepositioned, panel.isVisible {
      // Manual placement wins: keep the user's origin, track only size.
      origin = panel.frame.origin
    } else {
      guard let anchor,
        let screen = CursorOverlayPlacement.screen(containing: anchor)
      else { return }
      origin = CursorOverlayPlacement.origin(anchor: anchor, panelSize: size, in: screen)
    }
    hosting.frame = NSRect(origin: .zero, size: size)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
  }

  /// Font the capsule view renders text with; measurement must match.
  private static let textFont = NSFont.systemFont(ofSize: 13, weight: .medium)
  /// Monospaced font the secondary cluster renders with.
  private static let secondaryFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)

  /// Manual text measurement. NSHostingView.fittingSize measures with the
  /// view's CURRENT frame as the size proposal, which creates a fixed point
  /// (narrow frame → truncated text → narrow measurement) that kept the
  /// capsule stuck at its initial width.
  private func measuredSize() -> NSSize {
    let text = CursorOverlayCopy.displayText(for: state)
    let textWidth = ceil(
      (text as NSString).size(withAttributes: [.font: Self.textFont]).width)
    // 10pt padding ×2 + 6pt dot + 6pt dot-text spacing + 6pt text-cluster spacing.
    let width = textWidth + 38 + secondaryWidth()
    return NSSize(width: min(max(width, 80), Self.maxPanelWidth), height: 24)
  }

  /// Absolute panel cap: text cap + horizontal chrome + widest secondary cluster.
  private static var maxPanelWidth: CGFloat {
    CursorOverlayMetrics.textMaxWidth + 38 + 320
  }

  /// Width of the right-side secondary cluster, measured with the same
  /// font, children order and spacing the view uses.
  private func secondaryWidth() -> CGFloat {
    func measure(_ s: String) -> CGFloat {
      ceil((s as NSString).size(withAttributes: [.font: Self.secondaryFont]).width)
    }
    let secondary = CursorOverlayCopy.secondary(for: state)
    let sep = CursorOverlayMetrics.secondarySeparator
    var children: [CGFloat] = [1]  // divider
    if let device = secondary.device {
      children.append(min(measure(device), CursorOverlayMetrics.secondaryItemMaxWidth))
      children.append(measure(sep))
    }
    children.append(min(measure(secondary.mode), CursorOverlayMetrics.secondaryItemMaxWidth))
    children.append(measure(sep))
    children.append(measure(secondary.charCount))
    if state.recordingStartDate != nil {
      children.append(measure(sep))
      children.append(measure("88:88"))  // fixed estimate; timer maxes at 20:00
    }
    return children.reduce(0, +) + CGFloat(children.count - 1) * 5
  }
}
