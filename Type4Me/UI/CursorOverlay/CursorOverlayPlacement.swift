import AppKit

/// Pure placement math for the cursor overlay, kept free of AX/AppKit-window
/// dependencies so it is unit-testable without a running app.
enum CursorOverlayPlacement {
  /// Vertical gap between the caret line and the panel.
  static let gap: CGFloat = 4
  /// Minimum inset from the screen's visible frame.
  static let screenMargin: CGFloat = 8

  /// Panel origin (Cocoa coords) anchored to a caret rect. Prefers below the
  /// caret line (where the next line of text would go), flips above when
  /// there's no room, and clamps into the visible frame. Degenerate cases
  /// (panel larger than the screen) clamp instead of overflowing.
  static func origin(
    anchor: CGRect,
    panelSize: NSSize,
    visibleFrame: CGRect
  ) -> NSPoint {
    let minY = visibleFrame.minY + screenMargin
    let maxY = max(minY, visibleFrame.maxY - screenMargin - panelSize.height)
    let minX = visibleFrame.minX + screenMargin
    let maxX = max(minX, visibleFrame.maxX - screenMargin - panelSize.width)

    let belowY = anchor.minY - gap - panelSize.height
    let aboveY = anchor.maxY + gap

    let unclampedY: CGFloat
    if belowY >= minY {
      unclampedY = belowY
    } else if aboveY <= maxY {
      unclampedY = aboveY
    } else {
      // Neither fits — clamp the below position into the screen.
      unclampedY = belowY
    }

    return NSPoint(
      x: min(max(anchor.minX, minX), maxX),
      y: min(max(unclampedY, minY), maxY)
    )
  }

  /// Convenience overload resolving the visible frame from an NSScreen.
  static func origin(anchor: CGRect, panelSize: NSSize, in screen: NSScreen) -> NSPoint {
    origin(anchor: anchor, panelSize: panelSize, visibleFrame: screen.visibleFrame)
  }

  /// Screen whose visible frame contains the anchor; falls back to the
  /// primary screen. Multi-display setups place the overlay next to the
  /// caret's own display, never on another one.
  static func screen(containing anchor: CGRect) -> NSScreen? {
    let anchorPoint = NSPoint(x: anchor.midX, y: anchor.midY)
    return NSScreen.screens.first { $0.frame.contains(anchorPoint) }
      ?? NSScreen.screens.first
  }
}
