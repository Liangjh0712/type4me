import AppKit
import ApplicationServices

/// Resolves "the display the user is currently working on" for the floating
/// surfaces (transcript deck, style-3 capsule).
///
/// Priority: the frontmost app's focused window, then the pointer, then the
/// primary screen. Window-before-pointer matters because the pointer is often
/// parked on a different display than the text field being dictated into.
enum ActiveScreenResolver {

  static func preferredScreen() -> NSScreen? {
    if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
      if let focusedBounds = focusedWindowBounds(for: pid),
        let screen = screen(containingQuartzBounds: focusedBounds)
      {
        return screen
      }

      if let info = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]],
        let frontWindow = info.lazy
          .filter({ ($0[kCGWindowOwnerPID as String] as? pid_t) == pid })
          .filter({ ($0[kCGWindowLayer as String] as? Int) == 0 })
          .compactMap({ entry -> CGRect? in
            guard let bounds = entry[kCGWindowBounds as String] as? [String: Any] else {
              return nil
            }
            return CGRect(dictionaryRepresentation: bounds as CFDictionary)
          })
          .first,
        let screen = screen(containingQuartzBounds: frontWindow)
      {
        return screen
      }
    }

    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
  }

  private static func focusedWindowBounds(for pid: pid_t) -> CGRect? {
    let application = AXUIElementCreateApplication(pid)
    var focusedWindowValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        application,
        kAXFocusedWindowAttribute as CFString,
        &focusedWindowValue
      ) == .success,
      let focusedWindowValue,
      CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID()
    else { return nil }
    let focusedWindow = unsafeBitCast(focusedWindowValue, to: AXUIElement.self)

    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        focusedWindow,
        kAXPositionAttribute as CFString,
        &positionValue
      ) == .success,
      AXUIElementCopyAttributeValue(
        focusedWindow,
        kAXSizeAttribute as CFString,
        &sizeValue
      ) == .success,
      let positionValue,
      let sizeValue,
      CFGetTypeID(positionValue) == AXValueGetTypeID(),
      CFGetTypeID(sizeValue) == AXValueGetTypeID()
    else { return nil }

    let positionAXValue = unsafeBitCast(positionValue, to: AXValue.self)
    let sizeAXValue = unsafeBitCast(sizeValue, to: AXValue.self)
    var origin = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionAXValue, .cgPoint, &origin),
      AXValueGetValue(sizeAXValue, .cgSize, &size),
      size.width > 1,
      size.height > 1
    else { return nil }
    return CGRect(origin: origin, size: size)
  }

  /// AX and CGWindowList report top-left-origin Quartz coordinates; NSScreen
  /// frames are bottom-left-origin. Flip through the primary screen's height.
  private static func screen(containingQuartzBounds bounds: CGRect) -> NSScreen? {
    let primaryHeight =
      NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
      ?? NSScreen.main?.frame.height
      ?? 0
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    return NSScreen.screens.first { screen in
      let frame = screen.frame
      let quartzFrame = CGRect(
        x: frame.minX,
        y: primaryHeight - frame.maxY,
        width: frame.width,
        height: frame.height
      )
      return quartzFrame.contains(center)
    }
  }
}
