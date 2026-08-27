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
  private static let dragHandleWidth: CGFloat = 36

  init() {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 180, height: 58),
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
      event.locationInWindow.x <= Self.dragHandleWidth
    {
      performDrag(with: event)
      return
    }
    super.sendEvent(event)
  }
}

private enum FloatingShortcutDeckStyle {
  static let shellTop = Color(red: 0.075, green: 0.145, blue: 0.180)
  static let shellBottom = Color(red: 0.020, green: 0.045, blue: 0.058)
  static let keyTop = Color(red: 0.100, green: 0.184, blue: 0.224)
  static let keyBottom = Color(red: 0.040, green: 0.083, blue: 0.104)
  static let edge = Color(red: 0.780, green: 0.840, blue: 0.830).opacity(0.18)
  static let legend = Color(red: 0.949, green: 0.925, blue: 0.875)
  static let brass = Color(red: 1.000, green: 0.714, blue: 0.282)
  static let signal = Color(red: 0.373, green: 0.827, blue: 0.753)
}

private struct FloatingShortcutPanelView: View {
  let buttons: [FloatingShortcutButtonConfiguration]
  let isCollapsed: Bool
  let onPressedChanged: (FloatingShortcutButtonConfiguration, Bool) -> Void
  let onToggleCollapsed: () -> Void
  let onClose: () -> Void

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
    HStack(spacing: 7) {
      dragHandle(height: 48)

      Rectangle()
        .fill(FloatingShortcutDeckStyle.edge)
        .frame(width: 1, height: 36)

      ForEach(buttons) { button in
        FloatingShortcutKeyButton(button: button) { pressed in
          onPressedChanged(button, pressed)
        }
      }

      if buttons.isEmpty {
        VStack(spacing: 3) {
          Image(systemName: "keyboard.badge.ellipsis")
            .font(.system(size: 14, weight: .medium))
          Text(L("待配置", "UNMAPPED"))
            .font(.custom("SF Mono", size: 8).weight(.semibold))
            .tracking(1.1)
        }
        .foregroundStyle(FloatingShortcutDeckStyle.legend.opacity(0.52))
        .frame(width: 84, height: 48)
      }

      VStack(spacing: 3) {
        utilityButton(
          symbol: "chevron.compact.left",
          help: L("折叠快捷键", "Collapse shortcuts"),
          action: onToggleCollapsed
        )
        utilityButton(
          symbol: "xmark",
          help: L("关闭悬浮快捷键", "Close floating shortcuts"),
          action: onClose
        )
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 6)
    .background(deckBackground(cornerRadius: 15))
    .overlay(deckBorder(cornerRadius: 15))
    .shadow(color: .black.opacity(0.42), radius: 14, y: 7)
    .padding(4)
  }

  private var collapsedDeck: some View {
    HStack(spacing: 5) {
      dragHandle(height: 38)

      Button(action: onToggleCollapsed) {
        VStack(spacing: 1) {
          Image(systemName: "keyboard.fill")
            .font(.system(size: 12, weight: .semibold))
          Text("KEYS")
            .font(.custom("SF Mono", size: 6.5).weight(.bold))
            .tracking(0.8)
        }
        .foregroundStyle(FloatingShortcutDeckStyle.legend.opacity(0.78))
        .frame(width: 34, height: 36)
        .background(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(FloatingShortcutDeckStyle.keyBottom)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(FloatingShortcutDeckStyle.edge, lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .help(L("展开快捷键", "Expand shortcuts"))

      utilityButton(
        symbol: "xmark",
        help: L("关闭悬浮快捷键", "Close floating shortcuts"),
        action: onClose
      )
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
    .background(deckBackground(cornerRadius: 13))
    .overlay(deckBorder(cornerRadius: 13))
    .shadow(color: .black.opacity(0.38), radius: 11, y: 5)
    .padding(3)
  }

  private func dragHandle(height: CGFloat) -> some View {
    VStack(spacing: 3) {
      Circle()
        .fill(FloatingShortcutDeckStyle.signal)
        .frame(width: 4, height: 4)
        .shadow(color: FloatingShortcutDeckStyle.signal.opacity(0.8), radius: 3)
      ForEach(0..<5, id: \.self) { _ in
        Capsule()
          .fill(FloatingShortcutDeckStyle.legend.opacity(0.22))
          .frame(width: 10, height: 1)
      }
    }
    .frame(width: 22, height: height)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Color.black.opacity(0.16))
    )
    .contentShape(Rectangle())
    .help(L("拖动面板", "Drag panel"))
  }

  private func utilityButton(
    symbol: String,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(FloatingShortcutDeckStyle.legend.opacity(0.58))
        .frame(width: 22, height: 22)
        .background(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.black.opacity(0.16))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .stroke(FloatingShortcutDeckStyle.edge.opacity(0.7), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
    .help(help)
  }

  private func deckBackground(cornerRadius: CGFloat) -> some View {
    ZStack {
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(
          LinearGradient(
            colors: [
              FloatingShortcutDeckStyle.shellTop.opacity(0.98),
              FloatingShortcutDeckStyle.shellBottom.opacity(0.98),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
      RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .fill(
          LinearGradient(
            colors: [.white.opacity(0.07), .clear, .black.opacity(0.12)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
    }
  }

  private func deckBorder(cornerRadius: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .stroke(
        LinearGradient(
          colors: [FloatingShortcutDeckStyle.edge, Color.black.opacity(0.45)],
          startPoint: .top,
          endPoint: .bottom
        ),
        lineWidth: 1
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

  private var shortcut: String {
    guard let keyCode = button.keyCode else { return "—" }
    switch keyCode {
    case 36: return "↵"
    case 49: return "SPACE"
    case 53: return "ESC"
    case 63: return "fn"
    default:
      return HotkeyRecorderView.keyDisplayName(keyCode: keyCode, modifiers: button.modifiers)
    }
  }

  private var latchesAcrossClicks: Bool {
    button.keyCode == 63 && (button.modifiers ?? 0) == 0
  }

  private var accent: Color {
    latchesAcrossClicks && pressState.isActive
      ? FloatingShortcutDeckStyle.brass
      : FloatingShortcutDeckStyle.signal
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Text(title.uppercased())
          .font(.custom("SF Mono", size: 7.5).weight(.semibold))
          .tracking(1.1)
          .foregroundStyle(FloatingShortcutDeckStyle.legend.opacity(0.48))
          .lineLimit(1)
        Spacer(minLength: 2)
        Circle()
          .fill(accent.opacity(pressState.isActive ? 1 : 0.34))
          .frame(width: 4, height: 4)
          .shadow(color: accent.opacity(pressState.isActive ? 0.9 : 0), radius: 3)
      }

      Text(shortcut)
        .font(.custom("SF Mono", size: shortcut.count > 5 ? 10 : 15).weight(.bold))
        .tracking(shortcut.count > 5 ? 0.2 : 0.8)
        .foregroundStyle(FloatingShortcutDeckStyle.legend)
        .lineLimit(1)
        .minimumScaleFactor(0.68)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 9)
    .frame(width: 84, height: 48)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(
          LinearGradient(
            colors: pressState.isActive
              ? [accent.opacity(0.30), FloatingShortcutDeckStyle.keyBottom]
              : [
                FloatingShortcutDeckStyle.keyTop.opacity(isHovered ? 1 : 0.72),
                FloatingShortcutDeckStyle.keyBottom,
              ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
    )
    .overlay(alignment: .top) {
      Capsule()
        .fill(accent.opacity(pressState.isActive ? 0.95 : (isHovered ? 0.42 : 0.16)))
        .frame(height: 1.5)
        .padding(.horizontal, 8)
        .padding(.top, 1)
    }
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(
          pressState.isActive ? accent.opacity(0.62) : FloatingShortcutDeckStyle.edge,
          lineWidth: 1
        )
    )
    .shadow(
      color: pressState.isActive ? accent.opacity(0.16) : .black.opacity(isHovered ? 0.36 : 0.26),
      radius: pressState.isActive ? 5 : 3,
      y: pressState.isActive ? 0 : 2
    )
    .offset(y: pressState.isActive ? 1 : (isHovered ? -1 : 0))
    .scaleEffect(pressState.isActive ? 0.975 : 1)
    .animation(.spring(response: 0.2, dampingFraction: 0.78), value: pressState.isActive)
    .animation(.easeOut(duration: 0.14), value: isHovered)
    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay {
      FloatingShortcutPressInteraction(
        onHoverChanged: { isHovered = $0 },
        onPressedChanged: { pointerPressed in
          guard let logicalPressed = pressState.consume(
            pointerPressed: pointerPressed,
            latchesAcrossClicks: latchesAcrossClicks
          ) else { return }
          onPressedChanged(logicalPressed)
        }
      )
    }
    .accessibilityLabel(title)
    .accessibilityValue(shortcut)
  }
}

private struct FloatingShortcutPressInteraction: NSViewRepresentable {
  let onHoverChanged: (Bool) -> Void
  let onPressedChanged: (Bool) -> Void

  func makeNSView(context: Context) -> FloatingShortcutPressNSView {
    let view = FloatingShortcutPressNSView()
    view.title = ""
    view.isBordered = false
    view.focusRingType = .none
    view.setButtonType(.momentaryPushIn)
    view.onHoverChanged = onHoverChanged
    view.onPressedChanged = onPressedChanged
    return view
  }

  func updateNSView(_ nsView: FloatingShortcutPressNSView, context: Context) {
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

    let size = panelSize(buttonCount: buttons.count, isCollapsed: isCollapsed)
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
    panel.orderFrontRegardless()
  }

  func windowDidMove(_ notification: Notification) {
    guard !isApplyingFrame, hasPositionedPanel else { return }
    FloatingShortcutPreferences.savePosition(panel.frame.origin, userDefaults: userDefaults)
  }

  private func panelSize(buttonCount: Int, isCollapsed: Bool) -> NSSize {
    guard !isCollapsed else { return NSSize(width: 106, height: 54) }
    let visibleKeyCount = max(1, buttonCount)
    let keyWidthWithSpacing: CGFloat = 91
    let fixedWidth: CGFloat = 81
    return NSSize(
      width: fixedWidth + CGFloat(visibleKeyCount) * keyWidthWithSpacing,
      height: 68
    )
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
