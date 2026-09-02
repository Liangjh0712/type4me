import AppKit

/// Pure placement math for the fixed-position transcript capsule, kept free
/// of AX/AppKit-window dependencies so it is unit-testable without a running
/// app.
enum CursorOverlayPlacement {
  /// Minimum inset from the screen's visible frame.
  static let screenMargin: CGFloat = 8
  /// Lift above the visible frame's bottom edge for the first-run default
  /// (horizontally centered, floating over the Dock area).
  static let defaultBottomLift: CGFloat = 36

  /// A parked position stored independently of any particular display: the
  /// origin as a fraction of the screen's free space, where 0 sits flush
  /// against the left/bottom margin, 1 against the right/top margin, and 0.5
  /// is centered. Storing this instead of a global point is what lets the
  /// capsule follow the user across displays: the same anchor re-resolves
  /// onto whichever screen is active, at whatever resolution it runs.
  struct RelativeAnchor: Equatable {
    var x: Double
    var y: Double
  }

  /// Clamp an origin so the panel stays fully inside the visible frame.
  static func clamped(_ origin: NSPoint, size: NSSize, visibleFrame: CGRect) -> NSPoint {
    let minX = visibleFrame.minX + screenMargin
    let maxX = max(minX, visibleFrame.maxX - screenMargin - size.width)
    let minY = visibleFrame.minY + screenMargin
    let maxY = max(minY, visibleFrame.maxY - screenMargin - size.height)
    return NSPoint(
      x: min(max(origin.x, minX), maxX),
      y: min(max(origin.y, minY), maxY)
    )
  }

  /// Bottom-centered origin used until the user drags the capsule elsewhere.
  static func defaultOrigin(size: NSSize, visibleFrame: CGRect) -> NSPoint {
    clamped(
      NSPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.minY + defaultBottomLift),
      size: size,
      visibleFrame: visibleFrame
    )
  }

  /// Screen whose frame contains the point; falls back to the primary screen.
  static func screen(containing point: NSPoint) -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.screens.first
  }

  // MARK: - Display-independent anchoring

  /// Free travel available to the panel on each axis, after margins.
  private static func freeSpace(size: NSSize, visibleFrame: CGRect) -> CGSize {
    CGSize(
      width: max(0, visibleFrame.width - 2 * screenMargin - size.width),
      height: max(0, visibleFrame.height - 2 * screenMargin - size.height)
    )
  }

  /// Convert a concrete origin on one screen into a display-independent anchor.
  static func relativeAnchor(
    origin: NSPoint, size: NSSize, visibleFrame: CGRect
  ) -> RelativeAnchor {
    let free = freeSpace(size: size, visibleFrame: visibleFrame)
    let clampedOrigin = clamped(origin, size: size, visibleFrame: visibleFrame)
    let x =
      free.width > 0
      ? (clampedOrigin.x - visibleFrame.minX - screenMargin) / free.width : 0.5
    let y =
      free.height > 0
      ? (clampedOrigin.y - visibleFrame.minY - screenMargin) / free.height : 0.5
    return RelativeAnchor(
      x: Double(min(max(x, 0), 1)),
      y: Double(min(max(y, 0), 1))
    )
  }

  /// Resolve an anchor back onto a concrete screen.
  static func origin(
    anchor: RelativeAnchor, size: NSSize, visibleFrame: CGRect
  ) -> NSPoint {
    let free = freeSpace(size: size, visibleFrame: visibleFrame)
    let x = min(max(anchor.x, 0), 1)
    let y = min(max(anchor.y, 0), 1)
    return clamped(
      NSPoint(
        x: visibleFrame.minX + screenMargin + CGFloat(x) * free.width,
        y: visibleFrame.minY + screenMargin + CGFloat(y) * free.height
      ),
      size: size,
      visibleFrame: visibleFrame
    )
  }
}

// MARK: - Visibility

/// Pure decision layer for "should the capsule be onscreen, and how should it
/// get there" — split out from the controller so the fade-window edge cases can
/// be tested without a window server.
///
/// It exists because `NSWindow.isVisible` is not the same question as "is the
/// capsule up": it stays true for the whole 0.15s fade-out. Reading it as
/// though it meant "shown" made a recording started within 150ms of the
/// previous one ending produce no capsule at all — the show was skipped as
/// redundant, and the in-flight fade then ordered the panel out from under the
/// live recording. Intermittent by construction, and indistinguishable from the
/// overlay being hidden behind the frontmost window.
enum CursorOverlayVisibility {

  /// What the controller should do with the panel for a given phase.
  enum Action: Equatable {
    /// Bring the panel up, re-resolving the active display and the parked
    /// anchor. Always a cold show: this is only emitted when the panel is down
    /// or on its way down, and in both cases the utterance that owned the old
    /// frame is over — resizing around that frame would leave the capsule on
    /// whichever display the last recording happened on.
    case show
    /// Start (or leave running) the fade-out.
    case hide
    /// Re-fit the existing frame to new content, in place.
    case refit
    /// Leave the panel exactly as it is.
    case none
  }

  /// The panel's own state, as the controller knows it.
  struct PanelState: Equatable {
    /// `NSWindow.isVisible` — true during a fade-out too.
    var isVisible: Bool
    /// True between the start of the fade-out and its completion.
    var isFadingOut: Bool

    /// The question the controller actually needs answered, and the one
    /// `isVisible` silently gets wrong for 150ms after every utterance.
    var isUp: Bool { isVisible && !isFadingOut }
  }

  static func action(
    phase: FloatingBarPhase,
    styleIsCursor: Bool,
    panel: PanelState
  ) -> Action {
    guard styleIsCursor else {
      return panel.isVisible ? .hide : .none
    }

    switch phase {
    case .preparing, .recording:
      // Stated as an invariant ("capture is live ⇒ the capsule is up") rather
      // than as a reaction to entering the phase. The transition-based form
      // left the capsule hidden for a whole utterance whenever it happened to
      // be down for any reason other than the previous phase.
      return panel.isUp ? .refit : .show
    case .hidden, .done:
      return .hide
    case .processing, .recovering, .error:
      // Never re-fit a fading panel: that frame belongs to the utterance that
      // ended, and an error arriving after the capsule is gone must not
      // resurrect it — this surface is not an alert.
      return panel.isUp ? .refit : .none
    }
  }
}
