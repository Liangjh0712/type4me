import CoreGraphics
import XCTest

@testable import Type4Me

final class FloatingShortcutTests: XCTestCase {
  func testPreferencesRoundTripButtonsAndEnabledState() {
    let suiteName = "FloatingShortcutPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let buttons = [
      FloatingShortcutButtonConfiguration(title: "Send", keyCode: 36),
      FloatingShortcutButtonConfiguration(
        title: "Voice",
        keyCode: 49,
        modifiers: CGEventFlags.maskCommand.rawValue
      ),
    ]

    FloatingShortcutPreferences.saveButtons(buttons, userDefaults: defaults)
    FloatingShortcutPreferences.setEnabled(true, userDefaults: defaults)
    FloatingShortcutPreferences.setCollapsed(true, userDefaults: defaults)

    XCTAssertEqual(FloatingShortcutPreferences.loadButtons(userDefaults: defaults), buttons)
    XCTAssertTrue(FloatingShortcutPreferences.isEnabled(userDefaults: defaults))
    XCTAssertTrue(FloatingShortcutPreferences.isCollapsed(userDefaults: defaults))
  }

  func testPreferencesUseReturnAndFnWhenNoConfigurationExists() {
    let suiteName = "FloatingShortcutPreferencesDefaultsTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    XCTAssertEqual(
      FloatingShortcutPreferences.loadButtons(userDefaults: defaults),
      FloatingShortcutPreferences.defaultButtons
    )
    XCTAssertEqual(FloatingShortcutPreferences.defaultButtons.compactMap(\.keyCode), [36, 63])
  }

  func testPreferencesLimitButtonCount() {
    let suiteName = "FloatingShortcutPreferencesLimitTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let buttons = (0..<10).map { (index: Int) in
      FloatingShortcutButtonConfiguration(title: "Button \(index)", keyCode: index)
    }

    FloatingShortcutPreferences.saveButtons(buttons, userDefaults: defaults)

    XCTAssertEqual(
      FloatingShortcutPreferences.loadButtons(userDefaults: defaults).count,
      FloatingShortcutPreferences.maximumButtonCount
    )
  }

  func testFnPressStateAlternatesOneLogicalEdgePerClick() {
    var state = FloatingShortcutPressState()
    let edges = [true, false, true, false].compactMap {
      state.consume(pointerPressed: $0, latchesAcrossClicks: true)
    }

    XCTAssertEqual(edges, [true, false])
    XCTAssertFalse(state.isActive)
  }

  func testRegularPressStateMirrorsPointerEdges() {
    var state = FloatingShortcutPressState()
    let edges = [true, true, false, false].compactMap {
      state.consume(pointerPressed: $0, latchesAcrossClicks: false)
    }

    XCTAssertEqual(edges, [true, false])
    XCTAssertFalse(state.isActive)
  }

  func testExecutorMirrorsPhysicalKeyDownAndUp() {
    var events: [String] = []
    let executor = FloatingShortcutExecutor { keyCode, modifiers, pressed in
      events.append("\(keyCode):\(modifiers.rawValue):\(pressed ? "down" : "up")")
    }
    let button = FloatingShortcutButtonConfiguration(
      title: "Send",
      keyCode: 36,
      modifiers: CGEventFlags.maskCommand.rawValue
    )

    executor.setPressed(true, for: button)
    executor.setPressed(true, for: button)
    executor.setPressed(false, for: button)
    executor.setPressed(false, for: button)

    XCTAssertEqual(
      events,
      [
        "36:\(CGEventFlags.maskCommand.rawValue):down",
        "36:\(CGEventFlags.maskCommand.rawValue):up",
      ]
    )
  }

  func testExecutorAddsFnFlagForModifierOnlyButton() {
    var events: [String] = []
    let executor = FloatingShortcutExecutor { keyCode, modifiers, pressed in
      events.append("\(keyCode):\(modifiers.rawValue):\(pressed ? "down" : "up")")
    }
    let button = FloatingShortcutButtonConfiguration(title: "Fn", keyCode: 63)

    executor.setPressed(true, for: button)
    executor.setPressed(false, for: button)

    XCTAssertEqual(
      events,
      [
        "63:\(CGEventFlags.maskSecondaryFn.rawValue):down",
        "63:0:up",
      ]
    )
  }

  func testExecutorReleasesPressedKeysWhenPanelHides() {
    var events: [String] = []
    let executor = FloatingShortcutExecutor { keyCode, _, pressed in
      events.append("\(keyCode):\(pressed ? "down" : "up")")
    }
    let button = FloatingShortcutButtonConfiguration(title: "Voice", keyCode: 49)

    executor.setPressed(true, for: button)
    executor.releaseAll()

    XCTAssertEqual(events, ["49:down", "49:up"])
  }
}
