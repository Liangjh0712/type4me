import AppKit
import SwiftUI

struct FloatingShortcutButtonConfiguration: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var title: String
  var keyCode: Int?
  var modifiers: UInt64?

  init(id: UUID = UUID(), title: String, keyCode: Int?, modifiers: UInt64? = nil) {
    self.id = id
    self.title = title
    self.keyCode = keyCode
    self.modifiers = modifiers
  }
}

enum FloatingShortcutPreferences {
  static let isEnabledKey = "tf_floatingShortcutPanelEnabled"
  static let buttonsKey = "tf_floatingShortcutButtons"
  static let isCollapsedKey = "tf_floatingShortcutPanelCollapsed"
  static let positionXKey = "tf_floatingShortcutPanelPositionX"
  static let positionYKey = "tf_floatingShortcutPanelPositionY"
  static let maximumButtonCount = 6

  static let defaultButtons = [
    FloatingShortcutButtonConfiguration(title: "Return", keyCode: 36),
    FloatingShortcutButtonConfiguration(title: "Fn", keyCode: 63),
  ]

  static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
    userDefaults.bool(forKey: isEnabledKey)
  }

  static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
    userDefaults.set(enabled, forKey: isEnabledKey)
    NotificationCenter.default.post(name: .floatingShortcutsDidChange, object: nil)
  }
  static func isCollapsed(userDefaults: UserDefaults = .standard) -> Bool {
    userDefaults.bool(forKey: isCollapsedKey)
  }

  static func setCollapsed(_ collapsed: Bool, userDefaults: UserDefaults = .standard) {
    userDefaults.set(collapsed, forKey: isCollapsedKey)
    NotificationCenter.default.post(name: .floatingShortcutsDidChange, object: nil)
  }


  static func loadButtons(userDefaults: UserDefaults = .standard)
    -> [FloatingShortcutButtonConfiguration]
  {
    guard let data = userDefaults.data(forKey: buttonsKey),
      let buttons = try? JSONDecoder().decode(
        [FloatingShortcutButtonConfiguration].self,
        from: data
      )
    else {
      return defaultButtons
    }
    return Array(buttons.prefix(maximumButtonCount))
  }

  static func saveButtons(
    _ buttons: [FloatingShortcutButtonConfiguration],
    userDefaults: UserDefaults = .standard
  ) {
    let limited = Array(buttons.prefix(maximumButtonCount))
    guard let data = try? JSONEncoder().encode(limited) else { return }
    userDefaults.set(data, forKey: buttonsKey)
    NotificationCenter.default.post(name: .floatingShortcutsDidChange, object: nil)
  }

  static func loadPosition(userDefaults: UserDefaults = .standard) -> NSPoint? {
    guard userDefaults.object(forKey: positionXKey) != nil,
      userDefaults.object(forKey: positionYKey) != nil
    else { return nil }
    return NSPoint(
      x: userDefaults.double(forKey: positionXKey),
      y: userDefaults.double(forKey: positionYKey)
    )
  }

  static func savePosition(_ origin: NSPoint, userDefaults: UserDefaults = .standard) {
    userDefaults.set(origin.x, forKey: positionXKey)
    userDefaults.set(origin.y, forKey: positionYKey)
  }
}

extension Notification.Name {
  static let floatingShortcutsDidChange = Notification.Name("Type4MeFloatingShortcutsDidChange")
}

final class FloatingShortcutExecutor {
  typealias EventPoster = (_ keyCode: CGKeyCode, _ modifiers: CGEventFlags, _ pressed: Bool) -> Void

  private struct PressedShortcut {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags
  }

  private let eventPoster: EventPoster
  private var pressedShortcuts: [UUID: PressedShortcut] = [:]

  init(eventPoster: @escaping EventPoster = FloatingShortcutExecutor.postKeyboardEvent) {
    self.eventPoster = eventPoster
  }

  func setPressed(_ pressed: Bool, for button: FloatingShortcutButtonConfiguration) {
    if pressed {
      guard pressedShortcuts[button.id] == nil, let rawKeyCode = button.keyCode else { return }
      let shortcut = PressedShortcut(
        keyCode: CGKeyCode(rawKeyCode),
        modifiers: CGEventFlags(rawValue: button.modifiers ?? 0)
      )
      pressedShortcuts[button.id] = shortcut
      eventPoster(
        shortcut.keyCode,
        Self.eventFlags(for: shortcut, pressed: true),
        true
      )
      return
    }

    guard let shortcut = pressedShortcuts.removeValue(forKey: button.id) else { return }
    eventPoster(
      shortcut.keyCode,
      Self.eventFlags(for: shortcut, pressed: false),
      false
    )
  }

  func releaseAll() {
    let shortcuts = pressedShortcuts.values
    pressedShortcuts.removeAll()
    for shortcut in shortcuts {
      eventPoster(
        shortcut.keyCode,
        Self.eventFlags(for: shortcut, pressed: false),
        false
      )
    }
  }

  private static func eventFlags(
    for shortcut: PressedShortcut,
    pressed: Bool
  ) -> CGEventFlags {
    var flags = shortcut.modifiers
    guard let ownFlag = ModeBinding.modifierEventFlag(for: Int(shortcut.keyCode)) else {
      return flags
    }
    if pressed {
      flags.insert(ownFlag)
    } else {
      flags.remove(ownFlag)
    }
    return flags
  }

  private static func postKeyboardEvent(
    keyCode: CGKeyCode,
    modifiers: CGEventFlags,
    pressed: Bool
  ) {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard let event = CGEvent(
      keyboardEventSource: source,
      virtualKey: keyCode,
      keyDown: pressed
    ) else { return }
    event.flags = modifiers
    event.post(tap: .cghidEventTap)
  }
}

private final class FloatingShortcutPanel: NSPanel {
  /// Window-coordinate rects that stay clickable (keys, utility buttons).
  /// A left mouse-down anywhere else drags the panel.
  var interactiveRects: [NSRect] = []

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 140, height: 52),
      styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    identifier = NSUserInterfaceItemIdentifier("Type4Me.FloatingShortcuts")
    isFloatingPanel = true
    level = .floating
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    hidesOnDeactivate = false
    animationBehavior = .utilityWindow
    appearance = NSAppearance(named: .darkAqua)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown,
      !interactiveRects.contains(where: { $0.contains(event.locationInWindow) })
    {
      performDrag(with: event)
      return
    }
    super.sendEvent(event)
  }
}

private enum FloatingShortcutDeckStyle {
  static let accent = Color(red: 0.38, green: 0.85, blue: 0.76)
  static let latch = Color(red: 1.00, green: 0.74, blue: 0.34)
  static let keyHeight: CGFloat = 28
  static let deckCornerRadius: CGFloat = 13
  static let keyCornerRadius: CGFloat = 7
}

extension FloatingShortcutButtonConfiguration {
  var compactKeyLabel: String {
    guard let keyCode else { return "—" }
    switch keyCode {
    case 36: return "↵"
    case 49: return "SPACE"
    case 53: return "ESC"
    case 63: return "fn"
    default:
      return HotkeyRecorderView.keyDisplayName(keyCode: keyCode, modifiers: modifiers)
    }
  }

  var latchesAcrossClicks: Bool {
    keyCode == 63 && (modifiers ?? 0) == 0
  }

  /// Deterministic key width shared by the view and the panel-size calculation.
  var compactKeyWidth: CGFloat {
    let count = compactKeyLabel.count
    let perChar: CGFloat = count > 3 ? 7 : 9
    return min(92, max(34, 20 + CGFloat(count) * perChar))
  }
}

private struct FloatingShortcutPanelView: View {
  let buttons: [FloatingShortcutButtonConfiguration]
  let isCollapsed: Bool
  let onPressedChanged: (FloatingShortcutButtonConfiguration, Bool) -> Void
  let onToggleCollapsed: () -> Void
  let onClose: () -> Void

  @State private var isDeckHovered = false

  var body: some View {
    Group {
      if isCollapsed {
        collapsedDeck
      } else {
        expandedDeck
      }
    }
    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isCollapsed)
  }

  private var expandedDeck: some View {
    deckChrome {
      HStack(spacing: 6) {
        if buttons.isEmpty {
          emptySlot
        }

        ForEach(buttons) { button in
          FloatingShortcutKeyButton(button: button) { pressed in
            onPressedChanged(button, pressed)
          }
        }

        Button(action: onToggleCollapsed) {
          Image(systemName: "chevron.compact.left")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))
            .frame(width: 16, height: FloatingShortcutDeckStyle.keyHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("折叠快捷键", "Collapse shortcuts"))
      }
      .padding(.leading, 5)
      .padding(.trailing, 6)
      .padding(.vertical, 6)
    }
  }

  private var collapsedDeck: some View {
    deckChrome {
      Button(action: onToggleCollapsed) {
        Image(systemName: "keyboard")
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white.opacity(0.85))
          .frame(width: 26, height: 24)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(L("展开快捷键", "Expand shortcuts"))
      .padding(.leading, 5)
      .padding(.trailing, 6)
      .padding(.vertical, 5)
    }
  }

  private func deckChrome<Content: View>(
    @ViewBuilder content: () -> Content
  ) -> some View {
    content()
      .background {
        RoundedRectangle(
          cornerRadius: FloatingShortcutDeckStyle.deckCornerRadius,
          style: .continuous
        )
        .fill(
          LinearGradient(
            colors: [Color(white: 0.105), Color(white: 0.055)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
      }
      .overlay(
        RoundedRectangle(
          cornerRadius: FloatingShortcutDeckStyle.deckCornerRadius,
          style: .continuous
        )
        .strokeBorder(
          LinearGradient(
            colors: [.white.opacity(0.16), .white.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom
          ),
          lineWidth: 0.5
        )
      )
      .overlay(alignment: .topTrailing) { closeBadge }
      .onHover { isDeckHovered = $0 }
      .animation(.easeOut(duration: 0.15), value: isDeckHovered)
      .contextMenu {
        Button(
          isCollapsed
            ? L("展开快捷键", "Expand shortcuts")
            : L("折叠快捷键", "Collapse shortcuts"),
          action: onToggleCollapsed
        )
        Divider()
        Button(L("关闭悬浮快捷键", "Close floating shortcuts"), action: onClose)
      }
      .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
      .padding(6)
  }

  @ViewBuilder private var closeBadge: some View {
    if isDeckHovered {
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 7, weight: .bold))
          .foregroundStyle(.white.opacity(0.75))
          .frame(width: 14, height: 14)
          .background(Circle().fill(Color(white: 0.13)))
          .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
      }
      .buttonStyle(.plain)
      .help(L("关闭悬浮快捷键", "Close floating shortcuts"))
      .offset(x: 3, y: -3)
      .transition(.scale(scale: 0.5).combined(with: .opacity))
    }
  }

  private var emptySlot: some View {
    HStack(spacing: 5) {
      Image(systemName: "keyboard.badge.ellipsis")
        .font(.system(size: 11))
      Text(L("待配置", "UNMAPPED"))
        .font(.system(size: 10, weight: .medium))
    }
    .foregroundStyle(.white.opacity(0.45))
    .padding(.horizontal, 10)
    .frame(height: FloatingShortcutDeckStyle.keyHeight)
    .overlay(
      RoundedRectangle(cornerRadius: FloatingShortcutDeckStyle.keyCornerRadius, style: .continuous)
        .strokeBorder(.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
    )
  }
}

struct FloatingShortcutPressState: Equatable {
  private(set) var isActive = false

  mutating func consume(pointerPressed: Bool, latchesAcrossClicks: Bool) -> Bool? {
    if latchesAcrossClicks {
      guard pointerPressed else { return nil }
      isActive.toggle()
      return isActive
    }

    guard isActive != pointerPressed else { return nil }
    isActive = pointerPressed
    return isActive
  }
}

private struct FloatingShortcutKeyButton: View {
  let button: FloatingShortcutButtonConfiguration
  let onPressedChanged: (Bool) -> Void

  @State private var pressState = FloatingShortcutPressState()
  @State private var isHovered = false

  private var title: String {
    let trimmed = button.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? L("快捷键", "SHORTCUT") : trimmed
  }

  private var accent: Color {
    button.latchesAcrossClicks && pressState.isActive
      ? FloatingShortcutDeckStyle.latch
      : FloatingShortcutDeckStyle.accent
  }

  private var fill: Color {
    if pressState.isActive { return accent.opacity(0.16) }
    return .white.opacity(isHovered ? 0.10 : 0.06)
  }

  private var glyphColor: Color {
    if pressState.isActive { return accent }
    return .white.opacity(isHovered ? 0.95 : 0.80)
  }

  private var edgeGradient: LinearGradient {
    LinearGradient(
      colors: pressState.isActive
        ? [accent.opacity(0.55), accent.opacity(0.22)]
        : [.white.opacity(0.14), .white.opacity(0.05)],
      startPoint: .top,
      endPoint: .bottom
    )
  }

  var body: some View {
    Text(button.compactKeyLabel)
      .font(
        .system(
          size: button.compactKeyLabel.count > 3 ? 10.5 : 13,
          weight: .semibold,
          design: .rounded
        )
      )
      .foregroundStyle(glyphColor)
      .shadow(color: pressState.isActive ? accent.opacity(0.9) : .clear, radius: 6)
      .lineLimit(1)
      .minimumScaleFactor(0.7)
      .frame(width: button.compactKeyWidth, height: FloatingShortcutDeckStyle.keyHeight)
      .background(
        RoundedRectangle(
          cornerRadius: FloatingShortcutDeckStyle.keyCornerRadius,
          style: .continuous
        )
        .fill(fill)
      )
      .overlay(
        RoundedRectangle(
          cornerRadius: FloatingShortcutDeckStyle.keyCornerRadius,
          style: .continuous
        )
        .strokeBorder(edgeGradient, lineWidth: 0.5)
      )
      .shadow(color: pressState.isActive ? accent.opacity(0.35) : .clear, radius: 8)
      .scaleEffect(pressState.isActive ? 0.94 : 1)
      .animation(.spring(response: 0.18, dampingFraction: 0.7), value: pressState.isActive)
      .animation(.easeOut(duration: 0.12), value: isHovered)
      .contentShape(
        RoundedRectangle(cornerRadius: FloatingShortcutDeckStyle.keyCornerRadius, style: .continuous)
      )
      .overlay {
        FloatingShortcutPressInteraction(
          help: title,
          onHoverChanged: { isHovered = $0 },
          onPressedChanged: { pointerPressed in
            guard let logicalPressed = pressState.consume(
              pointerPressed: pointerPressed,
              latchesAcrossClicks: button.latchesAcrossClicks
            ) else { return }
            onPressedChanged(logicalPressed)
          }
        )
      }
      .accessibilityLabel(title)
      .accessibilityValue(button.compactKeyLabel)
  }
}

private struct FloatingShortcutPressInteraction: NSViewRepresentable {
  let help: String
  let onHoverChanged: (Bool) -> Void
  let onPressedChanged: (Bool) -> Void

  func makeNSView(context: Context) -> FloatingShortcutPressNSView {
    let view = FloatingShortcutPressNSView()
    view.title = ""
    view.isBordered = false
    view.focusRingType = .none
    view.setButtonType(.momentaryPushIn)
    view.toolTip = help
    view.onHoverChanged = onHoverChanged
    view.onPressedChanged = onPressedChanged
    return view
  }

  func updateNSView(_ nsView: FloatingShortcutPressNSView, context: Context) {
    nsView.toolTip = help
    nsView.onHoverChanged = onHoverChanged
    nsView.onPressedChanged = onPressedChanged
  }

  static func dismantleNSView(_ nsView: FloatingShortcutPressNSView, coordinator: ()) {
    nsView.releaseIfNeeded()
  }
}

private final class FloatingShortcutPressNSView: NSButton {
  var onHoverChanged: ((Bool) -> Void)?
  var onPressedChanged: ((Bool) -> Void)?
  private var isShortcutPressed = false

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self
      )
    )
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    onHoverChanged?(true)
  }

  override func mouseExited(with event: NSEvent) {
    onHoverChanged?(false)
  }

  override func mouseDown(with event: NSEvent) {
    guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
    setShortcutPressed(true)
    defer { releaseIfNeeded() }
    super.mouseDown(with: event)
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      releaseIfNeeded()
      onHoverChanged?(false)
    }
    super.viewWillMove(toWindow: newWindow)
  }

  func releaseIfNeeded() {
    setShortcutPressed(false)
  }

  private func setShortcutPressed(_ pressed: Bool) {
    guard isShortcutPressed != pressed else { return }
    isShortcutPressed = pressed
    onPressedChanged?(pressed)
  }
}

@MainActor
final class FloatingShortcutPanelController: NSObject, NSWindowDelegate {
  private let panel = FloatingShortcutPanel()
  private let userDefaults: UserDefaults
  private let executor: FloatingShortcutExecutor
  private var hostingView: NSHostingView<FloatingShortcutPanelView>?
  private var preferencesObserver: NSObjectProtocol?
  private var isApplyingFrame = false
  private var hasPositionedPanel = false

  init(
    userDefaults: UserDefaults = .standard,
    executor: FloatingShortcutExecutor = FloatingShortcutExecutor()
  ) {
    self.userDefaults = userDefaults
    self.executor = executor
    super.init()

    panel.delegate = self
    preferencesObserver = NotificationCenter.default.addObserver(
      forName: .floatingShortcutsDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { [weak self] in
        self?.syncFromPreferences()
      }
    }
    syncFromPreferences()
  }

  deinit {
    if let preferencesObserver {
      NotificationCenter.default.removeObserver(preferencesObserver)
    }
  }

  func syncFromPreferences() {
    executor.releaseAll()
    guard FloatingShortcutPreferences.isEnabled(userDefaults: userDefaults) else {
      panel.orderOut(nil)
      return
    }

    let buttons = FloatingShortcutPreferences.loadButtons(userDefaults: userDefaults)
      .filter { $0.keyCode != nil }
    let isCollapsed = FloatingShortcutPreferences.isCollapsed(userDefaults: userDefaults)
    let view = FloatingShortcutPanelView(
      buttons: buttons,
      isCollapsed: isCollapsed,
      onPressedChanged: { [weak self] button, pressed in
        self?.executor.setPressed(pressed, for: button)
      },
      onToggleCollapsed: { [weak self] in
        guard let self else { return }
        FloatingShortcutPreferences.setCollapsed(
          !isCollapsed,
          userDefaults: self.userDefaults
        )
      },
      onClose: { [weak self] in
        guard let self else { return }
        self.executor.releaseAll()
        FloatingShortcutPreferences.setEnabled(false, userDefaults: self.userDefaults)
      }
    )

    let size = panelSize(buttons: buttons, isCollapsed: isCollapsed)
    if let hostingView {
      hostingView.rootView = view
      hostingView.frame = NSRect(origin: .zero, size: size)
    } else {
      let hostingView = NSHostingView(rootView: view)
      hostingView.sizingOptions = []
      hostingView.wantsLayer = true
      hostingView.layer?.backgroundColor = NSColor.clear.cgColor
      hostingView.frame = NSRect(origin: .zero, size: size)
      hostingView.autoresizingMask = [.width, .height]
      panel.contentView = hostingView
      self.hostingView = hostingView
    }

    isApplyingFrame = true
    let origin = resolvedOrigin(for: size)
    panel.setFrame(NSRect(origin: origin, size: size), display: true)
    hasPositionedPanel = true
    isApplyingFrame = false
    panel.interactiveRects = interactiveRects(
      buttons: buttons,
      isCollapsed: isCollapsed,
      panelSize: size
    )
    panel.orderFrontRegardless()
  }

  func windowDidMove(_ notification: Notification) {
    guard !isApplyingFrame, hasPositionedPanel else { return }
    FloatingShortcutPreferences.savePosition(panel.frame.origin, userDefaults: userDefaults)
  }

  private func panelSize(
    buttons: [FloatingShortcutButtonConfiguration],
    isCollapsed: Bool
  ) -> NSSize {
    let shadowPadding: CGFloat = 12  // 6pt on every side
    let spacing: CGFloat = 6
    let horizontalPadding: CGFloat = 5 + 6  // leading + trailing

    if isCollapsed {
      let width = horizontalPadding + 26 + shadowPadding
      return NSSize(width: width, height: 24 + 10 + shadowPadding)
    }

    let keysWidth = buttons.isEmpty
      ? CGFloat(84)
      : buttons.reduce(0) { $0 + $1.compactKeyWidth }
    let itemCount = buttons.isEmpty ? 2 : buttons.count + 1  // keys/empty + chevron
    let width =
      horizontalPadding + keysWidth + 16
      + CGFloat(itemCount - 1) * spacing + shadowPadding
    return NSSize(
      width: width,
      height: FloatingShortcutDeckStyle.keyHeight + 12 + shadowPadding
    )
  }

  /// Clickable regions in window coordinates (y flipped from SwiftUI layout).
  /// Everything else on the deck acts as a drag surface.
  private func interactiveRects(
    buttons: [FloatingShortcutButtonConfiguration],
    isCollapsed: Bool,
    panelSize: NSSize
  ) -> [NSRect] {
    let shadowInset: CGFloat = 6
    var rects: [NSRect] = []

    // Hover close-badge zone at the top-trailing corner.
    rects.append(
      NSRect(x: panelSize.width - 22, y: panelSize.height - 20, width: 22, height: 20)
    )

    if isCollapsed {
      rects.append(
        NSRect(
          x: shadowInset + 5,
          y: panelSize.height - shadowInset - 5 - 24,
          width: 26,
          height: 24
        )
      )
      return rects
    }

    var x = shadowInset + 5
    let keyY = panelSize.height - shadowInset - 6 - FloatingShortcutDeckStyle.keyHeight
    if buttons.isEmpty {
      x += 84 + 6  // empty slot is a drag surface; skip to the chevron
    }
    for button in buttons {
      rects.append(
        NSRect(
          x: x,
          y: keyY,
          width: button.compactKeyWidth,
          height: FloatingShortcutDeckStyle.keyHeight
        )
      )
      x += button.compactKeyWidth + 6
    }
    // Collapse chevron.
    rects.append(NSRect(x: x, y: keyY, width: 16, height: FloatingShortcutDeckStyle.keyHeight))
    return rects
  }

  private func resolvedOrigin(for size: NSSize) -> NSPoint {
    if hasPositionedPanel {
      return clamp(panel.frame.origin, size: size)
    }
    if let saved = FloatingShortcutPreferences.loadPosition(userDefaults: userDefaults) {
      return clamp(saved, size: size)
    }

    let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
    guard let screen else { return .zero }
    let visible = screen.visibleFrame
    return NSPoint(
      x: visible.maxX - size.width - 24,
      y: visible.midY - size.height / 2
    )
  }

  private func clamp(_ origin: NSPoint, size: NSSize) -> NSPoint {
    let proposed = NSRect(origin: origin, size: size)
    let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(proposed) })
      ?? NSScreen.screens.first(where: { $0.frame.contains(origin) })
      ?? NSScreen.main
      ?? NSScreen.screens.first
    guard let screen else { return origin }
    let visible = screen.visibleFrame
    return NSPoint(
      x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
      y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
    )
  }
}
