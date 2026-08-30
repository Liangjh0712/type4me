import AppKit
import SwiftUI

// MARK: - Configuration

/// What a deck cell does. Plain keys post CGEvents; the mode cell opens the
/// processing-mode list. Older prefs JSON has no `action` field and decodes
/// as `.key`.
enum FloatingShortcutAction: String, Codable, Equatable, Sendable {
  case key
  case modeSwitch
}

struct FloatingShortcutButtonConfiguration: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var title: String
  var keyCode: Int?
  var modifiers: UInt64?
  var action: FloatingShortcutAction

  init(
    id: UUID = UUID(), title: String, keyCode: Int?, modifiers: UInt64? = nil,
    action: FloatingShortcutAction = .key
  ) {
    self.id = id
    self.title = title
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.action = action
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    keyCode = try container.decodeIfPresent(Int.self, forKey: .keyCode)
    modifiers = try container.decodeIfPresent(UInt64.self, forKey: .modifiers)
    action = try container.decodeIfPresent(FloatingShortcutAction.self, forKey: .action) ?? .key
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

  /// Keys offered by the deck's + cell. Anything more exotic is recorded in
  /// Settings, which syncs back into the deck through the same prefs.
  static let presetKeys: [(title: String, keyCode: Int, modifiers: UInt64?)] = [
    ("↵ 回车", 36, nil),
    ("fn", 63, nil),
    ("空格", 49, nil),
    ("Esc", 53, nil),
    ("Tab", 48, nil),
    ("⌫ 删除", 51, nil),
    ("⌘C 复制", 8, CGEventFlags.maskCommand.rawValue),
    ("⌘V 粘贴", 9, CGEventFlags.maskCommand.rawValue),
  ]

  static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
    userDefaults.bool(forKey: isEnabledKey)
  }

  static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
    userDefaults.set(enabled, forKey: isEnabledKey)
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

// MARK: - Executor

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

// MARK: - Panel

private final class FloatingShortcutPanel: NSPanel {
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
    hasShadow = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    hidesOnDeactivate = false
    animationBehavior = .utilityWindow
    appearance = NSAppearance(named: .darkAqua)
  }

  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseDown {
      // Every clickable element on the deck is a real NSButton, so the
      // hit-test decides click-vs-drag. Hand-computed interactive rects were
      // dropped — they drifted away from SwiftUI's layout on the capsule and
      // the same fragility applied here.
      if let hit = contentView?.hitTest(event.locationInWindow), hit is NSButton {
        super.sendEvent(event)
        return
      }
      performDrag(with: event)
      return
    }
    super.sendEvent(event)
  }
}

// MARK: - Style

private enum FloatingShortcutDeckStyle {
  static let accent = Color(red: 0.38, green: 0.85, blue: 0.76)
  static let latch = Color(red: 1.00, green: 0.74, blue: 0.34)
  static let keyHeight: CGFloat = 20
  static let deckCornerRadius: CGFloat = 9
  static let keyCornerRadius: CGFloat = 5
  static let settingsCellWidth: CGFloat = 24

  /// Fixed mode-cell width shared by the view and the panel-size math —
  /// derived from a per-character estimate (never measured at render time),
  /// so SwiftUI and the controller always agree exactly.
  static func modeCellWidth(_ name: String) -> CGFloat {
    let units = name.prefix(5).reduce(CGFloat(0)) { $0 + ($1.isASCII ? 5.5 : 10) }
    return min(72, max(36, 16 + units))
  }
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
    let perChar: CGFloat = count > 3 ? 7 : 8
    return min(88, max(30, 18 + CGFloat(count) * perChar))
  }

  /// Width of this cell as laid out on the deck (key or mode cell).
  func cellWidth(modeName: String) -> CGFloat {
    action == .modeSwitch
      ? FloatingShortcutDeckStyle.modeCellWidth(modeName)
      : compactKeyWidth
  }
}

// MARK: - Deck View

private struct FloatingShortcutPanelView: View {
  var state: AppState
  let buttons: [FloatingShortcutButtonConfiguration]
  let onPressedChanged: (FloatingShortcutButtonConfiguration, Bool) -> Void
  /// Menu actions receive the clicked NSView so the controller can pop an
  /// NSMenu anchored at the cell.
  let onSettings: (NSView) -> Void
  let onShowModes: (NSView) -> Void

  var body: some View {
    deckChrome {
      HStack(spacing: 6) {
        ForEach(buttons) { button in
          if button.action == .modeSwitch {
            modeCell
          } else {
            FloatingShortcutKeyButton(
              button: button,
              onPressedChanged: { onPressedChanged(button, $0) }
            )
          }
        }

        settingsCell
      }
      .padding(.leading, 4)
      .padding(.trailing, 5)
      .padding(.vertical, 3)
    }
  }

  /// Mode cell: shows the current mode name, click pops the mode list.
  private var modeCell: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(FloatingShortcutDeckStyle.accent)
        .frame(width: 5, height: 5)
        .shadow(color: FloatingShortcutDeckStyle.accent.opacity(0.8), radius: 3)
      Text(state.currentMode.name)
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.88))
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 10)
    .frame(
      width: FloatingShortcutDeckStyle.modeCellWidth(state.currentMode.name),
      height: FloatingShortcutDeckStyle.keyHeight
    )
    .background(
      RoundedRectangle(
        cornerRadius: FloatingShortcutDeckStyle.keyCornerRadius, style: .continuous
      )
      .fill(FloatingShortcutDeckStyle.accent.opacity(0.10))
    )
    .overlay(
      RoundedRectangle(
        cornerRadius: FloatingShortcutDeckStyle.keyCornerRadius, style: .continuous
      )
      .strokeBorder(FloatingShortcutDeckStyle.accent.opacity(0.28), lineWidth: 0.5)
    )
    .overlay {
      DeckClickButton(
        help: L("切换处理模式", "Switch processing mode"),
        onHoverChanged: nil
      ) { view in
        onShowModes(view)
      }
    }
    .accessibilityLabel(L("模式切换", "Mode switch"))
  }

  /// Trailing gear cell: the ONLY on-deck management entry. Add/remove live
  /// inside its menu — inline × badges on every cell misfired too easily.
  private var settingsCell: some View {
    Image(systemName: "gearshape.fill")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.white.opacity(0.55))
      .frame(
        width: FloatingShortcutDeckStyle.settingsCellWidth,
        height: FloatingShortcutDeckStyle.keyHeight
      )
      .background(
        RoundedRectangle(
          cornerRadius: FloatingShortcutDeckStyle.keyCornerRadius, style: .continuous
        )
        .fill(.white.opacity(0.06))
      )
      .overlay(
        RoundedRectangle(
          cornerRadius: FloatingShortcutDeckStyle.keyCornerRadius, style: .continuous
        )
        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
      )
      .overlay {
        DeckClickButton(
          help: L("管理格子（添加 / 移除）", "Manage cells (add / remove)"),
          onHoverChanged: nil
        ) { view in
          onSettings(view)
        }
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
        .fill(.ultraThinMaterial)
        .overlay(
          // Same frosted-glass + dark-tint recipe as the transcript capsule:
          // lighter than the old near-black plate, and the two floating
          // surfaces now share one material language.
          RoundedRectangle(
            cornerRadius: FloatingShortcutDeckStyle.deckCornerRadius,
            style: .continuous
          )
          .fill(
            LinearGradient(
              colors: [.black.opacity(0.38), .black.opacity(0.50)],
              startPoint: .top,
              endPoint: .bottom
            )
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
  }
}

// MARK: - Key Cell

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
    // Keys sit on a frosted-glass plate now (lighter than the old near-black
    // one), so the idle fill gets a bit more body to stay defined.
    return .white.opacity(isHovered ? 0.12 : 0.08)
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
          size: button.compactKeyLabel.count > 3 ? 9 : 11,
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

// MARK: - Click Interaction (utility buttons / mode cell / add cell / badges)

/// Transparent real NSButton (title explicitly emptied — NSButton's default
/// title is the literal string "Button", which once rendered over the row
/// text). Participates in the panel hit-test so clicks never become drags,
/// and reports itself to the handler so menus can anchor at the cell.
private struct DeckClickButton: NSViewRepresentable {
  let help: String
  let onHoverChanged: ((Bool) -> Void)?
  let onClick: (NSView) -> Void

  func makeNSView(context: Context) -> DeckClickNSButton {
    let button = DeckClickNSButton()
    configure(button)
    return button
  }

  func updateNSView(_ nsView: DeckClickNSButton, context: Context) {
    configure(nsView)
  }

  private func configure(_ button: DeckClickNSButton) {
    button.title = ""
    button.isBordered = false
    button.setButtonType(.momentaryPushIn)
    button.focusRingType = .none
    button.toolTip = help
    button.onClick = onClick
    button.onHoverChanged = onHoverChanged
  }
}

private final class DeckClickTarget: NSObject {
  var handler: ((NSView) -> Void)?
  @objc func clicked(_ sender: Any?) {
    if let view = sender as? NSView { handler?(view) }
  }
}

private final class DeckClickNSButton: NSButton {
  var onClick: ((NSView) -> Void)? {
    get { clickTarget.handler }
    set { clickTarget.handler = newValue }
  }
  var onHoverChanged: ((Bool) -> Void)?
  private let clickTarget = DeckClickTarget()

  init() {
    super.init(frame: .zero)
    target = clickTarget
    action = #selector(DeckClickTarget.clicked(_:))
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

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

  override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
  override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

// MARK: - Press-and-hold Interaction (key cells)

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

// MARK: - Menus

private final class DeckMenuTarget: NSObject {
  var handler: (() -> Void)?
  @objc func run(_ sender: Any?) { handler?() }
}

// MARK: - Controller

@MainActor
final class FloatingShortcutPanelController: NSObject, NSWindowDelegate {
  private let state: AppState
  private let panel = FloatingShortcutPanel()
  private let userDefaults: UserDefaults
  private let executor: FloatingShortcutExecutor
  private var hostingView: NSHostingView<FloatingShortcutPanelView>?
  private var preferencesObserver: NSObjectProtocol?
  private var isApplyingFrame = false
  private var hasPositionedPanel = false

  init(
    state: AppState,
    userDefaults: UserDefaults = .standard,
    executor: FloatingShortcutExecutor = FloatingShortcutExecutor()
  ) {
    self.state = state
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
    startModeObservation()
    syncFromPreferences()
  }

  /// The mode cell's width tracks the current mode's name, so a mode switch
  /// (from the deck, a hotkey, or anywhere else) re-lays-out the deck.
  private func startModeObservation() {
    withObservationTracking {
      _ = state.currentMode.id
    } onChange: { [weak self] in
      DispatchQueue.main.async { [weak self] in
        MainActor.assumeIsolated {
          self?.startModeObservation()
          self?.syncFromPreferences()
        }
      }
    }
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
      .filter { $0.keyCode != nil || $0.action == .modeSwitch }
    let view = FloatingShortcutPanelView(
      state: state,
      buttons: buttons,
      onPressedChanged: { [weak self] button, pressed in
        self?.executor.setPressed(pressed, for: button)
      },
      onSettings: { [weak self] anchor in
        MainActor.assumeIsolated { self?.showSettingsMenu(anchor: anchor) }
      },
      onShowModes: { [weak self] anchor in
        MainActor.assumeIsolated { self?.showModeMenu(anchor: anchor) }
      }
    )

    let size = panelSize(buttons: buttons)
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
    let target = NSRect(origin: origin, size: size)
    // Cell add/remove resizes the deck; glide instead of jumping. Left edge
    // stays anchored so the strip shrinks in place.
    if panel.isVisible, !target.size.equalTo(panel.frame.size) {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.2
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(target, display: true)
      }
    } else {
      panel.setFrame(target, display: true)
    }
    hasPositionedPanel = true
    isApplyingFrame = false
    panel.orderFrontRegardless()
  }

  func windowDidMove(_ notification: Notification) {
    guard !isApplyingFrame, hasPositionedPanel else { return }
    FloatingShortcutPreferences.savePosition(panel.frame.origin, userDefaults: userDefaults)
  }

  // MARK: - Add / Remove

  private func removeButton(_ button: FloatingShortcutButtonConfiguration) {
    var buttons = FloatingShortcutPreferences.loadButtons(userDefaults: userDefaults)
    buttons.removeAll { $0.id == button.id }
    FloatingShortcutPreferences.saveButtons(buttons, userDefaults: userDefaults)
  }

  private func addButton(_ button: FloatingShortcutButtonConfiguration) {
    var buttons = FloatingShortcutPreferences.loadButtons(userDefaults: userDefaults)
    guard buttons.count < FloatingShortcutPreferences.maximumButtonCount else { return }
    buttons.append(button)
    FloatingShortcutPreferences.saveButtons(buttons, userDefaults: userDefaults)
  }

  /// The gear cell's menu: the deliberate home for ALL deck management —
  /// add presets, add the mode cell, remove existing cells, or jump to the
  /// full Settings editor (custom key recording lives there). Keeping this
  /// off the deck surface is deliberate: inline × badges misfired too often.
  private func showSettingsMenu(anchor: NSView) {
    let current = FloatingShortcutPreferences.loadButtons(userDefaults: userDefaults)
    let menu = NSMenu()
    var targets: [DeckMenuTarget] = []

    func addItem(
      _ title: String,
      enabled: Bool = true,
      handler: @escaping () -> Void
    ) {
      let item = NSMenuItem(
        title: title, action: #selector(DeckMenuTarget.run(_:)), keyEquivalent: "")
      let target = DeckMenuTarget()
      target.handler = { [weak self] in
        MainActor.assumeIsolated {
          guard self != nil else { return }
          handler()
        }
      }
      item.target = target
      item.isEnabled = enabled
      targets.append(target)
      menu.addItem(item)
    }

    let atCapacity = current.count >= FloatingShortcutPreferences.maximumButtonCount

    for preset in FloatingShortcutPreferences.presetKeys {
      let alreadyAdded = current.contains {
        $0.keyCode == preset.keyCode && ($0.modifiers ?? 0) == (preset.modifiers ?? 0)
      }
      addItem(preset.title, enabled: !alreadyAdded && !atCapacity) { [weak self] in
        self?.addButton(
          FloatingShortcutButtonConfiguration(
            title: preset.title, keyCode: preset.keyCode, modifiers: preset.modifiers
          )
        )
      }
    }
    addItem(
      L("模式切换", "Mode switch"),
      enabled: !atCapacity && !current.contains { $0.action == .modeSwitch }
    ) { [weak self] in
      self?.addButton(
        FloatingShortcutButtonConfiguration(
          title: L("模式", "Mode"), keyCode: nil, action: .modeSwitch
        )
      )
    }

    if !current.isEmpty {
      menu.addItem(.separator())
      for button in current {
        let label =
          button.action == .modeSwitch
          ? L("模式切换", "Mode switch")
          : button.title
        addItem(L("移除 \(label)", "Remove \(label)")) { [weak self] in
          self?.removeButton(button)
        }
      }
    }

    menu.addItem(.separator())
    addItem(L("打开设置…", "Open Settings…")) {
      AppDelegate.openSettingsAction?()
    }

    // Targets must outlive the menu's run loop.
    objc_setAssociatedObject(menu, &deckMenuTargetKey, targets, .OBJC_ASSOCIATION_RETAIN)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
  }

  private func showModeMenu(anchor: NSView) {
    let menu = NSMenu()
    var targets: [DeckMenuTarget] = []

    for mode in state.selectablePanelModes {
      let item = NSMenuItem(
        title: mode.name, action: #selector(DeckMenuTarget.run(_:)), keyEquivalent: "")
      let target = DeckMenuTarget()
      target.handler = { [weak self] in
        MainActor.assumeIsolated {
          guard let self else { return }
          if self.state.barPhase == .preparing || self.state.barPhase == .recording {
            self.state.selectPanelMode(mode)
          } else if self.state.currentMode.id != mode.id {
            self.state.currentMode = mode
          }
        }
      }
      item.target = target
      targets.append(target)
      item.state = mode.id == state.currentMode.id ? .on : .off
      menu.addItem(item)
    }

    objc_setAssociatedObject(menu, &deckMenuTargetKey, targets, .OBJC_ASSOCIATION_RETAIN)
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
  }

  // MARK: - Geometry

  private func panelSize(
    buttons: [FloatingShortcutButtonConfiguration]
  ) -> NSSize {
    // The panel hugs the deck exactly — no shadow padding, no transparent
    // drag margin (that dead ring around the deck was pure overhead).
    let spacing: CGFloat = 6
    let horizontalPadding: CGFloat = 4 + 5  // leading + trailing

    let modeName = state.currentMode.name
    let cellsWidth = buttons.reduce(0) { $0 + $1.cellWidth(modeName: modeName) }
    let itemCount = buttons.count + 1  // cells + settings gear
    let width =
      horizontalPadding + cellsWidth
      + FloatingShortcutDeckStyle.settingsCellWidth
      + CGFloat(itemCount - 1) * spacing
    return NSSize(
      width: width,
      height: FloatingShortcutDeckStyle.keyHeight + 6
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

private var deckMenuTargetKey: UInt8 = 0
