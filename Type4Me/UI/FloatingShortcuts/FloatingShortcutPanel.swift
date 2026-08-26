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
    FloatingShortcutButtonConfiguration(title: "Return", keyCode: 36)
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
      eventPoster(shortcut.keyCode, shortcut.modifiers, true)
      return
    }

    guard let shortcut = pressedShortcuts.removeValue(forKey: button.id) else { return }
    eventPoster(shortcut.keyCode, shortcut.modifiers, false)
  }

  func releaseAll() {
    let shortcuts = pressedShortcuts.values
    pressedShortcuts.removeAll()
    for shortcut in shortcuts {
      eventPoster(shortcut.keyCode, shortcut.modifiers, false)
    }
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
  private static let dragHandleWidth: CGFloat = 30

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

private struct FloatingShortcutPanelView: View {
  let buttons: [FloatingShortcutButtonConfiguration]
  let isCollapsed: Bool
  let onPressedChanged: (FloatingShortcutButtonConfiguration, Bool) -> Void
  let onToggleCollapsed: () -> Void
  let onClose: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: "circle.grid.2x2.fill")
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Color.white.opacity(0.42))
        .frame(width: 22, height: 42)
        .contentShape(Rectangle())
        .help(L("拖动面板", "Drag panel"))

      if !isCollapsed {
        ForEach(buttons) { button in
          FloatingShortcutKeyButton(button: button) { pressed in
            onPressedChanged(button, pressed)
          }
        }

        if buttons.isEmpty {
          Text(L("请在设置中添加按键", "Add a key in Settings"))
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.58))
            .padding(.horizontal, 8)
        }
      }

      Button(action: onToggleCollapsed) {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.left")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.62))
          .frame(width: 24, height: 24)
          .background(Circle().fill(Color.white.opacity(0.08)))
      }
      .buttonStyle(.plain)
      .help(isCollapsed ? L("展开快捷键", "Expand shortcuts") : L("折叠快捷键", "Collapse shortcuts"))

      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(Color.white.opacity(0.5))
          .frame(width: 24, height: 24)
          .background(Circle().fill(Color.white.opacity(0.06)))
      }
      .buttonStyle(.plain)
      .help(L("关闭悬浮快捷键", "Close floating shortcuts"))
    }
    .padding(7)
    .background(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .fill(Color(red: 0.035, green: 0.075, blue: 0.11).opacity(0.94))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(Color.white.opacity(0.14), lineWidth: 1)
    )
    .padding(4)
  }
}

private struct FloatingShortcutKeyButton: View {
  let button: FloatingShortcutButtonConfiguration
  let onPressedChanged: (Bool) -> Void

  @State private var isPressed = false

  private var title: String {
    let trimmed = button.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return button.keyCode.map {
        HotkeyRecorderView.keyDisplayName(keyCode: $0, modifiers: button.modifiers)
      } ?? L("未设置", "Unset")
    }
    return trimmed
  }

  private var shortcut: String {
    guard let keyCode = button.keyCode else { return "—" }
    return HotkeyRecorderView.keyDisplayName(keyCode: keyCode, modifiers: button.modifiers)
  }

  var body: some View {
    VStack(spacing: 2) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
      Text(shortcut)
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.52))
        .lineLimit(1)
    }
    .frame(width: 76, height: 40)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(Color.white.opacity(isPressed ? 0.18 : 0.08))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(Color.white.opacity(isPressed ? 0.34 : 0.12), lineWidth: 1)
    )
    .scaleEffect(isPressed ? 0.96 : 1)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !isPressed else { return }
          isPressed = true
          onPressedChanged(true)
        }
        .onEnded { _ in
          guard isPressed else { return }
          isPressed = false
          onPressedChanged(false)
        }
    )
    .onDisappear {
      guard isPressed else { return }
      isPressed = false
      onPressedChanged(false)
    }
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
    guard !isCollapsed else { return NSSize(width: 104, height: 62) }
    let keyWidth: CGFloat = 82
    let fixedWidth: CGFloat = 104
    return NSSize(width: fixedWidth + CGFloat(buttonCount) * keyWidth, height: 62)
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
