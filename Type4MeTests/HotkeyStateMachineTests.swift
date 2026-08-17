import XCTest
@testable import Type4Me

private final class HotkeyBindingCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    func recordStart() {
        lock.lock()
        starts += 1
        lock.unlock()
    }

    func recordStop() {
        lock.lock()
        stops += 1
        lock.unlock()
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }
}

final class HotkeyStateMachineTests: XCTestCase {
    func testSiblingToggleBindingStopsSameModeRecording() {
        let manager = HotkeyManager()
        let counters = HotkeyBindingCounters()
        let modeId = UUID()
        let keyboard = makeBinding(modeId: modeId, keyCode: 49, style: .toggle, counters: counters)
        let mouse = makeBinding(
            modeId: modeId,
            keyCode: ModeBinding.mouseKeyCode(for: 2),
            style: .toggle,
            counters: counters
        )
        manager.registerBindings([keyboard, mouse])

        manager.simulateBindingEvent(keyboard, pressed: true)
        manager.simulateBindingEvent(mouse, pressed: true)

        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 1)
        XCTAssertFalse(manager.isActiveRecordingBinding(keyboard.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(mouse.bindingId))
    }

    func testSiblingToggleClearsInterruptedHoldState() {
        let manager = HotkeyManager()
        let counters = HotkeyBindingCounters()
        let modeId = UUID()
        let hold = makeBinding(modeId: modeId, keyCode: 49, style: .hold, counters: counters)
        let mouse = makeBinding(
            modeId: modeId,
            keyCode: ModeBinding.mouseKeyCode(for: 2),
            style: .toggle,
            counters: counters
        )
        manager.registerBindings([hold, mouse])

        manager.simulateBindingEvent(hold, pressed: true)
        XCTAssertTrue(manager.isHoldActive(for: hold.bindingId))
        XCTAssertTrue(manager.hasPendingSafetyTimer(for: hold.bindingId))

        manager.simulateBindingEvent(mouse, pressed: true)

        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 1)
        XCTAssertFalse(manager.isHoldActive(for: hold.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: hold.bindingId))
    }

    func testDifferentModeBindingUsesCrossModeStop() {
        let manager = HotkeyManager()
        let counters = HotkeyBindingCounters()
        let first = makeBinding(modeId: UUID(), keyCode: 49, style: .toggle, counters: counters)
        let secondModeId = UUID()
        let second = makeBinding(modeId: secondModeId, keyCode: 50, style: .toggle, counters: counters)
        var stoppedForModes: [UUID] = []
        manager.onCrossModeStop = { stoppedForModes.append($0) }
        manager.registerBindings([first, second])

        manager.simulateBindingEvent(first, pressed: true)
        manager.simulateBindingEvent(second, pressed: true)

        XCTAssertEqual(counters.startCount, 1)
        XCTAssertEqual(counters.stopCount, 0)
        XCTAssertEqual(stoppedForModes, [secondModeId])
        XCTAssertFalse(manager.isActiveRecordingBinding(first.bindingId))
    }

    func testResetClearsActiveHoldAndTimer() {
        let manager = HotkeyManager()
        let counters = HotkeyBindingCounters()
        let hold = makeBinding(modeId: UUID(), keyCode: 49, style: .hold, counters: counters)
        manager.registerBindings([hold])
        manager.simulateBindingEvent(hold, pressed: true)

        manager.resetActiveState()

        XCTAssertFalse(manager.isHoldActive(for: hold.bindingId))
        XCTAssertFalse(manager.isActiveRecordingBinding(hold.bindingId))
        XCTAssertFalse(manager.hasPendingSafetyTimer(for: hold.bindingId))
    }

    private func makeBinding(
        modeId: UUID,
        keyCode: Int,
        style: ProcessingMode.HotkeyStyle,
        counters: HotkeyBindingCounters
    ) -> ModeBinding {
        ModeBinding(
            bindingId: UUID(),
            modeId: modeId,
            keyCode: CGKeyCode(keyCode),
            modifiers: [],
            style: style,
            onStart: { counters.recordStart() },
            onStop: { counters.recordStop() }
        )
    }
}
