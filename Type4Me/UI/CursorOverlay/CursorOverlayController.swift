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

  /// Dwell timer for the .error state, so a failure is actually seen.
  private var pendingErrorDismiss: DispatchWorkItem?
  /// True from the moment `hide()` starts its fade until the fade completes.
  /// `panel.isVisible` stays true for that whole 0.15s, so it cannot be used to
  /// answer "is the capsule up?" — see `show()`.
  private var isFadingOut = false
  /// Bumped on every show/hide. A fade-out completion only gets to call
  /// `orderOut` if nothing has happened since it was scheduled; without this,
  /// a stop-then-start inside the fade window tore down the panel that the new
  /// recording had just brought up. The top deck and the headset toast already
  /// guard their completions this way.
  private var visibilityGeneration = 0

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
      // The capsule renders this on .error; without it the message can land
      // after the phase change and never trigger a redraw.
      _ = state.feedbackMessage
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
    let action = CursorOverlayVisibility.action(
      phase: phase,
      styleIsCursor: TranscriptPanelStyle.current(userDefaults: userDefaults) == .cursor,
      panel: CursorOverlayVisibility.PanelState(
        isVisible: panel.isVisible, isFadingOut: isFadingOut)
    )

    if phase == .error {
      if action == .refit { scheduleErrorDismiss() }
    } else {
      pendingErrorDismiss?.cancel()
      pendingErrorDismiss = nil
    }

    switch action {
    case .show:
      show()
    case .hide:
      hide()
    case .refit:
      updateFrame()
    case .none:
      break
    }
  }

  /// Errors linger, then fade — matching the other styles' dwell.
  private func scheduleErrorDismiss() {
    pendingErrorDismiss?.cancel()
    let work = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.state.barPhase == .error else { return }
        self.hide()
      }
    }
    pendingErrorDismiss = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
  }

  // MARK: - Done button

  /// Done button: stop & insert (no trailing keypresses).
  private func handleSend() {
    state.requestPanelStop()
  }

  // MARK: - Show / hide

  /// Brings the capsule up, including when it is mid-fade from the previous
  /// utterance. Always a cold show — `CursorOverlayVisibility` only asks for one
  /// when the old frame's utterance is over — so the active display and the
  /// parked anchor are re-resolved rather than resized around.
  private func show() {
    updateFrame(coldShow: true)
    let wasFadingOut = isFadingOut
    isFadingOut = false
    // Disarms any in-flight fade completion, which would otherwise order the
    // panel out from under the recording that just started.
    visibilityGeneration &+= 1
    guard wasFadingOut || !panel.isVisible else { return }
    // Assigning alphaValue cancels the fade-out's animation outright, so the two
    // never interleave. Resume from wherever the fade got to rather than from 0:
    // restarting at 0 would darken an almost-opaque capsule before brightening
    // it again, which is a visible dip on a fast stop-start.
    let from = wasFadingOut ? panel.alphaValue : 0
    panel.alphaValue = from
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      // Scale the fade-in to the distance left to travel, so a near-opaque
      // resume snaps rather than crawling back up over the full 0.12s.
      context.duration = 0.12 * Double(1 - from)
      panel.animator().alphaValue = 1
    }
  }

  private func hide() {
    guard panel.isVisible, !isFadingOut else { return }
    isFadingOut = true
    visibilityGeneration &+= 1
    let expectedGeneration = visibilityGeneration
    let panelRef = panel
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.15
        panelRef.animator().alphaValue = 0
      },
      completionHandler: { [weak self] in
        MainActor.assumeIsolated {
          // A show() landed while this fade was running: leave the panel alone.
          guard let self, self.visibilityGeneration == expectedGeneration else { return }
          self.isFadingOut = false
          panelRef.orderOut(nil)
        }
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

  /// - Parameter coldShow: forces the "landing fresh" path even though the
  ///   panel is technically still onscreen. Set when resuming from a fade-out:
  ///   the utterance that owned the old position is over, so the capsule should
  ///   re-resolve the active display instead of resizing around a stale frame.
  private func updateFrame(coldShow: Bool = false) {
    let size = measuredSize()
    let origin: NSPoint

    if panel.isVisible && !coldShow {
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

  /// FIXED panel size (capsule width; the ghost buttons sit INSIDE the
  /// capsule row, so nothing sticks out sideways). The capsule never grows
  /// with the transcript: a moving frame edge makes the reader's gaze drift,
  /// while a fixed layout keeps the text tail — the one thing being read —
  /// at a stable screen position. Text overflow is handled view-side by
  /// head-truncation.
  private func measuredSize() -> NSSize {
    // 38pt capsule (13.5pt text + 8pt vertical padding, floored by the 22pt
    // ghost buttons) + 4pt gap + 18pt hover meta row (9pt text + 3pt padding
    // ×2, plus room for the scrim's 6pt blur to fade out) + 2×2pt padding.
    // The meta row keeps its slot even while hidden so revealing it on hover
    // never resizes the panel — only its opacity changes.
    NSSize(width: CursorOverlayMetrics.panelWidth, height: 68)
  }
}
