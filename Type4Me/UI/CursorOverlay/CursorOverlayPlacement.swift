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
}
