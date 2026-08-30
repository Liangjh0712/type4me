import AppKit
import SwiftUI

/// Borderless capsule panel for the fixed-position transcript overlay. Same
/// NSPanel idioms as the other floating surfaces (see HeadsetButtonToastPanel /
/// FloatingBarPanel), except it accepts mouse events: the capsule is
/// draggable so the user can park it where they want it.
final class CursorOverlayPanel: NSPanel {
  /// Called after any press-drag on the capsule (performDrag blocks until
  /// mouse-up, so this fires once the move is complete).
  var onUserDrag: (() -> Void)?

  init() {
    super.init(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 160, height: 61)),
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
      // Real NSButtons (the capsule's end actions) get their clicks via the
      // normal hit-test — never hand-computed rects, which drifted away from
      // SwiftUI's layout and swallowed clicks into drags. Everything else
      // drags. Non-activating panel: focus stays with the target app.
      if let hit = contentView?.hitTest(event.locationInWindow), hit is NSButton {
        super.sendEvent(event)
        return
      }
      performDrag(with: event)
      onUserDrag?()
      return
    }
    super.sendEvent(event)
  }
}

/// Drives the style-3 transcript capsule: shows it while recording and
/// post-processing, hides on completion.
///
/// Placement is FIXED, not pointer-anchored: the capsule appears at a
/// persisted position every time (bottom-center of the active screen on
/// first run). Dragging it stores the new origin in UserDefaults; the
/// pointer-follow anchoring was dropped because a moving target made the
/// status harder, not easier, to glance at. Until the first drag, the
/// capsule re-centers as its width grows with the transcript; afterwards the
/// user's origin wins and only the size tracks the text.
///
/// Subscribes to AppState via Swift Observation (withObservationTracking) so
/// the existing single-assignment panel closures stay owned by
/// FloatingBarController.
@MainActor
final class CursorOverlayController {
  private static let positionXKey = "tf_cursorOverlayPositionX"
  private static let positionYKey = "tf_cursorOverlayPositionY"

  private let state: AppState
  private let userDefaults: UserDefaults
  private let panel = CursorOverlayPanel()
  private let hosting: NSHostingView<CursorOverlayView<AppState>>

  private var lastPhase: FloatingBarPhase = .hidden

  init(state: AppState, userDefaults: UserDefaults = .standard) {
    self.state = state
    self.userDefaults = userDefaults
    hosting = NSHostingView(
      rootView: CursorOverlayView(state: state, onSend: {})
    )
    hosting.sizingOptions = []
    // The capsule view fills the hosting view, so AppKit's animated frame
    // changes drive the whole resize — no SwiftUI/AppKit sync issues.
    hosting.autoresizingMask = [.width, .height]
    hosting.frame = NSRect(origin: .zero, size: NSSize(width: 160, height: 61))
    panel.contentView = hosting
    panel.onUserDrag = { [weak self] in
      MainActor.assumeIsolated { self?.savePosition() }
    }
    // Real send closure can only capture self after full initialization.
    hosting.rootView = CursorOverlayView(state: state) { [weak self] in
      MainActor.assumeIsolated { self?.handleSend() }
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

    guard TranscriptPanelStyle.current(userDefaults: userDefaults) == .cursor else {
      if panel.isVisible { hide() }
      return
    }

    if enteredRecording {
      show()
    }

    switch phase {
    case .hidden, .done, .error:
      hide()
    default:
      // Re-fit the capsule as the transcript grows.
      if panel.isVisible { updateFrame() }
    }
  }

  // MARK: - Done button

  /// Done button: stop & insert (no trailing keypresses).
  private func handleSend() {
    state.requestPanelStop()
  }

  // MARK: - Show / hide

  private func show() {
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

  // MARK: - Position persistence

  private func loadPosition() -> NSPoint? {
    guard userDefaults.object(forKey: Self.positionXKey) != nil,
      userDefaults.object(forKey: Self.positionYKey) != nil
    else { return nil }
    return NSPoint(
      x: userDefaults.double(forKey: Self.positionXKey),
      y: userDefaults.double(forKey: Self.positionYKey)
    )
  }

  private func savePosition() {
    let origin = panel.frame.origin
    userDefaults.set(origin.x, forKey: Self.positionXKey)
    userDefaults.set(origin.y, forKey: Self.positionYKey)
  }

  // MARK: - Geometry

  private func updateFrame() {
    let size = measuredSize()
    let origin: NSPoint
    if let saved = loadPosition() {
      let screen = CursorOverlayPlacement.screen(
        containing: panel.isVisible ? panel.frame.origin : saved
      )
      let proposed: NSPoint
      if panel.isVisible {
        // Resize in place: left and top edges anchored to the current frame,
        // so bucket crossings glide around a stable anchor.
        proposed = NSPoint(x: panel.frame.origin.x, y: panel.frame.maxY - size.height)
      } else {
        // User-parked position wins on first show. A stale position (e.g.
        // disconnected display) clamps onto the primary screen via
        // screen(containing:)'s fallback.
        proposed = saved
      }
      origin = screen.map {
        CursorOverlayPlacement.clamped(proposed, size: size, visibleFrame: $0.visibleFrame)
      } ?? proposed
    } else {
      // Never dragged: keep the bottom-center default, re-centering as the
      // capsule grows.
      guard let screen = CursorOverlayPlacement.screen(containing: NSEvent.mouseLocation)
      else { return }
      origin = CursorOverlayPlacement.defaultOrigin(size: size, visibleFrame: screen.visibleFrame)
    }

    let target = NSRect(origin: origin, size: size)
    guard !target.equalTo(panel.frame) else { return }
    if panel.isVisible, !target.size.equalTo(panel.frame.size) {
      // Width is bucket-quantized, so this fires only a handful of times per
      // utterance (bucket crossings / button show-hide) — each one glides.
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(target, display: true)
      }
    } else {
      panel.setFrame(target, display: true)
    }
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
    let buttonsVisible = CursorOverlayMetrics.showsActionButtons(state.barPhase)
    let text = CursorOverlayCopy.displayText(for: state)
    // Cap at the view's textMaxWidth: the view head-truncates beyond it, so
    // the capsule content stops growing there.
    let textWidth = min(
      ceil((text as NSString).size(withAttributes: [.font: Self.textFont]).width),
      CursorOverlayMetrics.textMaxWidth(buttonsVisible: buttonsVisible)
    )
    // Two always-visible bars: main row (dot+spacing+text, plus the two 18pt
    // end buttons and their gaps while capturing) and the meta strip below
    // (indented to align under the text). Width hugs the wider of the two.
    let textRowWidth = (buttonsVisible ? 64 : 12) + textWidth
    let metaRowWidth =
      CursorOverlayMetrics.metaIndent(buttonsVisible: buttonsVisible) + secondaryWidth()
    let contentWidth = max(textRowWidth, metaRowWidth)
    // 12pt horizontal padding ×2 + 12pt shadow padding (6pt/side).
    let width = Self.quantizedWidth(contentWidth + 36)
    // Main capsule 30 + 4pt gap + meta strip 15 + 12pt shadow padding.
    return NSSize(width: width, height: 61)
  }

  /// Width grows in fixed buckets instead of tracking every glyph: transcript
  /// revisions arrive several times a second, and hugging the text made the
  /// capsule step wider each time (the "jittery" feel). Crossing a bucket is
  /// rare, and each crossing is an animated glide.
  private static func quantizedWidth(_ raw: CGFloat) -> CGFloat {
    let minWidth: CGFloat = 160
    let step: CGFloat = 96
    let cap: CGFloat = 640
    guard raw > minWidth else { return minWidth }
    return min(minWidth + ceil((raw - minWidth) / step) * step, cap)
  }

  /// Width of the bottom meta cluster, measured with the same font,
  /// children order and spacing the view uses.
  private func secondaryWidth() -> CGFloat {
    func measure(_ s: String) -> CGFloat {
      ceil((s as NSString).size(withAttributes: [.font: Self.secondaryFont]).width)
    }
    let secondary = CursorOverlayCopy.secondary(for: state)
    let sep = CursorOverlayMetrics.secondarySeparator
    var children: [CGFloat] = []
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
