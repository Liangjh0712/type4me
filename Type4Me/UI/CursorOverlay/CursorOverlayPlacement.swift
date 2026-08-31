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
