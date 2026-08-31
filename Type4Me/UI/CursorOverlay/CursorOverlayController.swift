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
  /// Double-click anywhere off the buttons: re-center the capsule.
  var onDoubleClick: (() -> Void)?

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
      if event.clickCount >= 2 {
        onDoubleClick?()
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
/// persisted position every time (bottom-center on first run). Dragging it
/// stores the new position in UserDefaults; the pointer-follow anchoring was
/// dropped because a moving target made the status harder, not easier, to
/// glance at. Until the first drag, the capsule re-centers as its width grows
/// with the transcript; afterwards the user's position wins and only the size
/// tracks the text.
///
/// The parked position is stored as a display-independent anchor (a fraction
/// of the screen's free space), not a global point, so on every cold show the
/// capsule resolves onto whichever display the user is working on — same
/// screen resolution the top deck uses (focused window, then pointer). A
/// global point would have pinned it to whichever display it was last dragged
/// on, which is wrong on a multi-monitor desk.
///
/// Subscribes to AppState via Swift Observation (withObservationTracking) so
/// the existing single-assignment panel closures stay owned by
/// FloatingBarController.
@MainActor
final class CursorOverlayController {
  /// Legacy absolute-point keys, migrated to the relative anchor on first read.
  private static let positionXKey = "tf_cursorOverlayPosition3X"
  private static let positionYKey = "tf_cursorOverlayPosition3Y"
  private static let anchorXKey = "tf_cursorOverlayAnchor3X"
  private static let anchorYKey = "tf_cursorOverlayAnchor3Y"

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
    panel.onDoubleClick = { [weak self] in
      MainActor.assumeIsolated { self?.recenter() }
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

  /// Parked position as a display-independent anchor. Migrates the legacy
  /// absolute point (written before multi-monitor support) by reinterpreting
  /// it against the screen it was saved on, then dropping the old keys.
  private func loadAnchor() -> CursorOverlayPlacement.RelativeAnchor? {
    if userDefaults.object(forKey: Self.anchorXKey) != nil,
      userDefaults.object(forKey: Self.anchorYKey) != nil
    {
      return CursorOverlayPlacement.RelativeAnchor(
        x: userDefaults.double(forKey: Self.anchorXKey),
        y: userDefaults.double(forKey: Self.anchorYKey)
      )
    }
    return migrateLegacyPosition()
  }

  private func migrateLegacyPosition() -> CursorOverlayPlacement.RelativeAnchor? {
    guard userDefaults.object(forKey: Self.positionXKey) != nil,
      userDefaults.object(forKey: Self.positionYKey) != nil
    else { return nil }
    let legacy = NSPoint(
      x: userDefaults.double(forKey: Self.positionXKey),
      y: userDefaults.double(forKey: Self.positionYKey)
    )
    userDefaults.removeObject(forKey: Self.positionXKey)
    userDefaults.removeObject(forKey: Self.positionYKey)
    guard let screen = CursorOverlayPlacement.screen(containing: legacy) else { return nil }
    let anchor = CursorOverlayPlacement.relativeAnchor(
      origin: legacy, size: measuredSize(), visibleFrame: screen.visibleFrame
    )
    saveAnchor(anchor)
    return anchor
  }

  private func saveAnchor(_ anchor: CursorOverlayPlacement.RelativeAnchor) {
    userDefaults.set(anchor.x, forKey: Self.anchorXKey)
    userDefaults.set(anchor.y, forKey: Self.anchorYKey)
  }

  /// Drag finished: record where the capsule landed, relative to the screen it
  /// was dropped on — so the same spot is reused on every other display too.
  private func savePosition() {
    let frame = panel.frame
    guard let screen = CursorOverlayPlacement.screen(
      containing: NSPoint(x: frame.midX, y: frame.midY)
    ) else { return }
    saveAnchor(
      CursorOverlayPlacement.relativeAnchor(
        origin: frame.origin, size: frame.size, visibleFrame: screen.visibleFrame
      )
    )
  }

  /// Double-click gesture: forget the parked position and glide back to the
  /// default (bottom-center of the current screen).
  private func recenter() {
    userDefaults.removeObject(forKey: Self.anchorXKey)
    userDefaults.removeObject(forKey: Self.anchorYKey)
    userDefaults.removeObject(forKey: Self.positionXKey)
    userDefaults.removeObject(forKey: Self.positionYKey)
    guard let screen = CursorOverlayPlacement.screen(
      containing: NSPoint(x: panel.frame.midX, y: panel.frame.midY)
    ) else { return }
    let size = measuredSize()
    let origin = CursorOverlayPlacement.defaultOrigin(
      size: size, visibleFrame: screen.visibleFrame
    )
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.25
      context.timingFunction = CAMediaTimingFunction(name: .easeOut)
      panel.animator().setFrame(NSRect(origin: origin, size: size), display: true)
    }
  }

  // MARK: - Geometry

  private func updateFrame() {
    let size = measuredSize()
    let origin: NSPoint

    if panel.isVisible {
      // Resize in place: left and top edges anchored to the current frame, so
      // bucket crossings glide around a stable anchor. Never re-resolve the
      // screen mid-utterance — that would teleport the capsule if the user
      // moved the pointer while dictating.
      let proposed = NSPoint(x: panel.frame.origin.x, y: panel.frame.maxY - size.height)
      let screen = CursorOverlayPlacement.screen(
        containing: NSPoint(x: panel.frame.midX, y: panel.frame.midY)
      )
      origin = screen.map {
        CursorOverlayPlacement.clamped(proposed, size: size, visibleFrame: $0.visibleFrame)
      } ?? proposed
    } else {
      // Cold show: land on the display the user is actually working on.
      guard let screen = ActiveScreenResolver.preferredScreen() else { return }
      if let anchor = loadAnchor() {
        origin = CursorOverlayPlacement.origin(
          anchor: anchor, size: size, visibleFrame: screen.visibleFrame
        )
      } else {
        origin = CursorOverlayPlacement.defaultOrigin(
          size: size, visibleFrame: screen.visibleFrame
        )
      }
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

  /// FIXED panel size (capsule width; the action pills live INSIDE the meta
  /// row at its edges, so nothing sticks out sideways). The capsule never
  /// grows with the transcript: a moving frame edge makes the reader's gaze
  /// drift, while a fixed layout keeps the text tail — the one thing being
  /// read — at a stable screen position. Text overflow is handled view-side
  /// by head-truncation.
  private func measuredSize() -> NSSize {
    // 38pt capsule (13.5pt text + 8pt vertical padding, floored by the 22pt
    // ghost buttons) + 4pt gap + 12pt hover meta row + 2×2pt safety padding.
    // The meta row keeps its slot even while hidden so revealing it on hover
    // never resizes the panel — only its opacity changes.
    NSSize(width: CursorOverlayMetrics.panelWidth, height: 58)
  }
}
