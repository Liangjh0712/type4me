import Cocoa
import MediaPlayer

typealias HotkeyStyle = ProcessingMode.HotkeyStyle

struct ModeBinding {
    let bindingId: UUID
    let modeId: UUID
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags  // .maskCommand etc. Use [] for no modifiers
    let style: HotkeyStyle
    let onStart: @Sendable () -> Void
    let onStop: @Sendable () -> Void

    /// Whether this binding is for a mouse button (encoded with high-bit keyCode).
    var isMouseButton: Bool { ModeBinding.isMouseKeyCode(Int(keyCode)) }

    /// Whether this binding is for a media key (encoded with high-bit keyCode).
    var isMediaKey: Bool { ModeBinding.isMediaKeyCode(Int(keyCode)) }

    /// The mouse button number (2=middle, 3+=side buttons). Only valid when isMouseButton is true.
    var mouseButtonNumber: Int { ModeBinding.mouseButtonNumber(from: Int(keyCode)) }

    // MARK: - Mouse Button Encoding
    //
    // Convention: keyCode = 0x8000 + buttonNumber.
    // Middle button (2) → 0x8002, Side button 3 → 0x8003, etc.
    // Keyboard keyCodes are 0–127, so no collision.
    // The encoded value fits in both Int and UInt16 (CGKeyCode).

    private static let mouseKeyCodeBase = 0x8000
    private static let mediaKeyCodeBase = 0x9000
    static let modifierKeyCodes: Set<Int> = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    static let functionKeyCodes: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
    static let standardModifierMask: CGEventFlags = [
        .maskCommand,
        .maskShift,
        .maskAlternate,
        .maskControl,
        .maskSecondaryFn,
    ]

    /// Encode a mouse button number as a keyCode for a persisted binding.
    static func mouseKeyCode(for buttonNumber: Int) -> Int { mouseKeyCodeBase + buttonNumber }

    /// Decode a mouse keyCode back to a button number.
    static func mouseButtonNumber(from keyCode: Int) -> Int { keyCode - mouseKeyCodeBase }

    /// Check if a keyCode represents a mouse button.
    static func isMouseKeyCode(_ keyCode: Int) -> Bool { keyCode >= mouseKeyCodeBase && keyCode < mediaKeyCodeBase }

    // MARK: - Media Key Encoding
    //
    // Convention: keyCode = 0x9000 + NX_KEYTYPE value.
    // NX_KEYTYPE_SOUND_UP=0, NX_KEYTYPE_SOUND_DOWN=1, NX_KEYTYPE_MUTE=7,
    // NX_KEYTYPE_PLAY=16, NX_KEYTYPE_NEXT=17, NX_KEYTYPE_PREVIOUS=18,
    // NX_KEYTYPE_FAST=19, NX_KEYTYPE_REWIND=20.
    // No collision with keyboard (0–127) or mouse (0x8000+) keyCodes.

    /// Encode an NX_KEYTYPE value as a keyCode for a persisted binding.
    static func mediaKeyCode(for keyType: Int) -> Int { mediaKeyCodeBase + keyType }

    /// Decode a media keyCode back to the NX_KEYTYPE value.
    static func mediaKeyType(from keyCode: Int) -> Int { keyCode - mediaKeyCodeBase }

    /// Check if a keyCode represents a media key.
    static func isMediaKeyCode(_ keyCode: Int) -> Bool { keyCode >= mediaKeyCodeBase }

    static func isModifierKeyCode(_ keyCode: Int) -> Bool {
        modifierKeyCodes.contains(keyCode)
    }

    static func isFunctionKeyCode(_ keyCode: Int) -> Bool {
        functionKeyCodes.contains(keyCode)
    }

    static func modifierEventFlag(for keyCode: Int) -> CGEventFlags? {
        switch keyCode {
        case 54, 55: return .maskCommand
        case 56, 60: return .maskShift
        case 58, 61: return .maskAlternate
        case 59, 62: return .maskControl
        case 63: return .maskSecondaryFn
        default: return nil
        }
    }

    static func normalizedModifierFlags(_ flags: CGEventFlags, forKeyCode keyCode: Int? = nil) -> CGEventFlags {
        var normalized = flags.intersection(standardModifierMask)
        // macOS reports the Fn/function modifier on F-key events themselves.
        // Treat that as part of the F-key, not as an extra hotkey modifier.
        if let keyCode, isFunctionKeyCode(keyCode) {
            normalized.remove(.maskSecondaryFn)
        }
        return normalized
    }

    static func hotkeysAreEquivalent(
        keyCode: Int,
        modifiers: UInt64?,
        otherKeyCode: Int,
        otherModifiers: UInt64?
    ) -> Bool {
        guard keyCode == otherKeyCode else { return false }
        if isMouseKeyCode(keyCode) || isMediaKeyCode(keyCode) {
            return true
        }
        let flags = normalizedModifierFlags(CGEventFlags(rawValue: modifiers ?? 0), forKeyCode: keyCode)
        let otherFlags = normalizedModifierFlags(CGEventFlags(rawValue: otherModifiers ?? 0), forKeyCode: otherKeyCode)
        return flags == otherFlags
    }

    static func fullModifierFlags(keyCode: Int, modifiers: UInt64?) -> CGEventFlags? {
        guard let ownFlag = modifierEventFlag(for: keyCode) else { return nil }
        var flags = normalizedModifierFlags(CGEventFlags(rawValue: modifiers ?? 0))
        flags.insert(ownFlag)
        return flags
    }

    static func modifierBindingIsPrefix(
        modifierKeyCode: Int,
        modifierModifiers: UInt64?,
        otherKeyCode: Int,
        otherModifiers: UInt64?
    ) -> Bool {
        guard let flags = fullModifierFlags(keyCode: modifierKeyCode, modifiers: modifierModifiers) else {
            return false
        }

        if let otherFlags = fullModifierFlags(keyCode: otherKeyCode, modifiers: otherModifiers) {
            return flags != otherFlags && flags.isSubset(of: otherFlags)
        }

        guard let regularFlags = regularKeyModifierFlags(keyCode: otherKeyCode, modifiers: otherModifiers) else {
            return false
        }
        return flags.isSubset(of: regularFlags)
    }

    static func hasModifierPrefixConflict(
        keyCode: Int,
        modifiers: UInt64?,
        otherKeyCode: Int,
        otherModifiers: UInt64?
    ) -> Bool {
        modifierBindingIsPrefix(
            modifierKeyCode: keyCode,
            modifierModifiers: modifiers,
            otherKeyCode: otherKeyCode,
            otherModifiers: otherModifiers
        ) || modifierBindingIsPrefix(
            modifierKeyCode: otherKeyCode,
            modifierModifiers: otherModifiers,
            otherKeyCode: keyCode,
            otherModifiers: modifiers
        )
    }

    private static func regularKeyModifierFlags(keyCode: Int, modifiers: UInt64?) -> CGEventFlags? {
        guard !isMouseKeyCode(keyCode),
              !isMediaKeyCode(keyCode),
              !isModifierKeyCode(keyCode)
        else { return nil }
        let flags = normalizedModifierFlags(CGEventFlags(rawValue: modifiers ?? 0), forKeyCode: keyCode)
        return flags.isEmpty ? nil : flags
    }
}

final class HotkeyManager: NSObject {

    // MARK: - Configuration

    private var bindings: [ModeBinding] = []
    private var holdState: [UUID: Bool] = [:]
    private var wasModifierDown: [UUID: Bool] = [:]
    private var mediaKeysDown: Set<Int> = []
    private var holdSafetyTimers: [UUID: Timer] = [:]
    private var activeRecordingBindingId: UUID?
    private var activeRecordingModeId: UUID?
    private struct PendingModifierTrigger {
        let binding: ModeBinding
        let token: UUID
    }
    private var pendingModifierTriggers: [UUID: PendingModifierTrigger] = [:]

    /// Maximum hold duration before auto-stop (seconds).
    private let maxHoldDuration: TimeInterval = 120
    private let modifierPrefixTriggerDelay: TimeInterval = 0.12

    // MARK: - State

    /// When true, all hotkey events pass through unhandled (used during hotkey recording).
    var isSuppressed = false {
        didSet {
            guard oldValue != isSuppressed else { return }
            updateHeadsetMediaKeyMonitor()
        }
    }

    /// When true, ESC key aborts active recording.
    var isESCAbortEnabled = true

    /// When true, LLM post-processing is in progress (ESC can also abort this).
    var isProcessing = false

    /// Reset all active recording/hold state. Called when session ends (completed/error/finalized)
    /// to ensure hotkeys and ESC don't remain stuck.
    func resetActiveState() {
        clearActiveRecordingState()
        for key in wasModifierDown.keys { wasModifierDown[key] = false }
        for key in holdState.keys { holdState[key] = false }
        mediaKeysDown.removeAll()
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelPendingModifierTriggers()
    }

    /// Called when recording is stopped by a different mode's hotkey.
    /// The UUID is the new mode's ID that should be used for processing.
    var onCrossModeStop: ((UUID) -> Void)?

    /// Called when ESC is pressed during active recording or processing (abort).
    /// Called when ESC is pressed during active recording or processing (abort).
    /// Returns true if the abort was handled (ESC should be swallowed),
    /// false if the app is not actually in an active session (ESC should pass through).
    var onESCAbort: (() -> Bool)?

    /// Called once after a physical headset-button gesture is recognized.
    var onHeadsetButtonRecognized: ((Int) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    /// Timestamp of the last event received by the tap callback.
    fileprivate var lastEventTime: Date?

    /// Tokens for MPRemoteCommandCenter handlers (prevents Apple Music from auto-launching).
    private var mediaCommandTokens: [(command: MPRemoteCommand, token: Any)] = []
    private var isMediaSessionActive = false
    /// Exclusively captures the analog headset remote as raw HID media-key events.
    private var headsetMediaKeyMonitor: HeadsetMediaKeyMonitor?
    private var recentHeadsetMediaKeyPresses: [Int: Date] = [:]

    // MARK: - Registration

    func registerBindings(_ newBindings: [ModeBinding]) {
        let shouldReinstallEventTap = Self.requiresEventTapReinstall(
            eventTapIsInstalled: eventTap != nil,
            currentBindings: bindings,
            newBindings: newBindings
        )

        bindings = newBindings
        holdState = [:]
        wasModifierDown = [:]
        mediaKeysDown.removeAll()
        recentHeadsetMediaKeyPresses = [:]
        clearActiveRecordingState()
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelPendingModifierTriggers()

        if shouldReinstallEventTap {
            NSLog("[HotkeyManager] Media binding presence changed, reinstalling event tap")
            reinstallTap()
        } else {
            updateMediaKeySession()
            updateHeadsetMediaKeyMonitor()
        }
    }

    internal static func requiresEventTapReinstall(
        eventTapIsInstalled: Bool,
        currentBindings: [ModeBinding],
        newBindings: [ModeBinding]
    ) -> Bool {
        guard eventTapIsInstalled else { return false }
        let currentlyListensForMediaKeys = currentBindings.contains { $0.isMediaKey }
        let needsToListenForMediaKeys = newBindings.contains { $0.isMediaKey }
        return currentlyListensForMediaKeys != needsToListenForMediaKeys
    }

    // MARK: - Start / Stop

    @discardableResult
    func start() -> Bool {
        let hasMediaKeyBindings = bindings.contains { $0.isMediaKey }

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
            | (hasMediaKeyBindings ? (1 << 14) : 0)  // kCGEventSystemDefined (NX_SYSDEFINED) for media/headphone keys

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let tap: CFMachPort?
        if hasMediaKeyBindings {
            // Try cghidEventTap first for more reliable interception of media/headphone keys.
            // If unavailable (e.g. insufficient permissions), fall back to cgSessionEventTap.
            tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            ) ?? CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        } else {
            tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventMask,
                callback: hotkeyCallback,
                userInfo: userInfo
            )
        }

        guard let tap = tap else {
            return false
        }

        eventTap = tap
        lastEventTime = nil

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startHealthCheck()
        updateMediaKeySession()
        updateHeadsetMediaKeyMonitor()
        return true
    }

    func stop() {
        stopHeadsetMediaKeyMonitor()
        deactivateMediaKeySession()
        healthCheckTimer?.invalidate()
        healthCheckTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        lastEventTime = nil
        holdState = [:]
        wasModifierDown = [:]
        mediaKeysDown.removeAll()
        clearActiveRecordingState()
        holdSafetyTimers.values.forEach { $0.invalidate() }
        holdSafetyTimers = [:]
        cancelPendingModifierTriggers()
    }

    // MARK: - Health check

    /// Periodically verify the event tap is actually alive.
    /// Detects the "silent disable" race where tapCreate succeeds but the tap is dead.
    private func startHealthCheck() {
        healthCheckTimer?.invalidate()
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.eventTap else { return }

            // Check 1: Is the tap port still valid? Only recreate the tap for real invalidation,
            // not for normal idle periods with no keyboard/mouse input.
            if !CFMachPortIsValid(tap) {
                NSLog("[Type4Me] Health check: tap port invalid, reinstalling tap...")
                self.reinstallTap()
                return
            }

            // Check 2: Is the tap still enabled at the Mach port level?
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("[Type4Me] Health check: tap disabled, re-enabling...")
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    NSLog("[Type4Me] Health check: tap re-enable failed, reinstalling tap...")
                    self.reinstallTap()
                }
            }
        }
    }

    /// Tear down and recreate the event tap from scratch.
    private func reinstallTap() {
        stop()
        let ok = start()
        NSLog("[Type4Me] Tap reinstall: %@", ok ? "OK" : "FAILED")
    }

    // MARK: - Event handling

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lastEventTime = Date()

        // Re-enable tap if system disabled it, and recover any stuck hold states.
        // When macOS disables the tap (main thread blocked >1s), keyUp events are lost.
        // We must check if held keys are still physically down; if not, fire onStop.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            recoverStuckHolds()
            return Unmanaged.passUnretained(event)
        }

        // Pass all events through when suppressed (hotkey recording in progress)
        if isSuppressed {
            return Unmanaged.passUnretained(event)
        }

        // MARK: Mouse button events (otherMouseDown/Up = middle + side buttons)
        if type == .otherMouseDown || type == .otherMouseUp {
            let buttonNumber = Int(event.getIntegerValueField(.mouseEventButtonNumber))

            for binding in bindings {
                guard binding.isMouseButton, binding.mouseButtonNumber == buttonNumber else { continue }

                switch binding.style {
                case .hold:
                    if type == .otherMouseDown {
                        handleBindingEvent(binding: binding, pressed: true)
                    } else {
                        handleBindingEvent(binding: binding, pressed: false)
                    }
                case .toggle:
                    if type == .otherMouseDown {
                        handleTogglePress(binding: binding)
                    }
                }
                return nil  // Swallow matched mouse button events
            }

            return Unmanaged.passUnretained(event)
        }

        // MARK: Media key events (headphone buttons, keyboard media keys)
        if type.rawValue == 14 {  // kCGEventSystemDefined (NX_SYSDEFINED)
            guard let nsEvent = NSEvent(cgEvent: event),
                  nsEvent.type == .systemDefined,
                  nsEvent.subtype.rawValue == 8 else {
                return Unmanaged.passUnretained(event)
            }

            let keyType = Int((nsEvent.data1 >> 16) & 0xFFFF)
            let keyState = Int((nsEvent.data1 >> 8) & 0xFF)
            let isKeyDown = keyState == 0x0A
            let isKeyUp = keyState == 0x0B

            if let rawPressTime = recentHeadsetMediaKeyPresses[keyType],
               Date().timeIntervalSince(rawPressTime) < 0.2
            {
                DebugFileLogger.log(
                    "hotkey media source=system-media keyType=\(keyType) action=headset_duplicate_swallowed")
                return nil
            }

            guard handleMediaKeyEvent(
                keyType: keyType,
                isKeyDown: isKeyDown,
                isKeyUp: isKeyUp,
                source: "system-media"
            ) else {
                return Unmanaged.passUnretained(event)
            }
            return nil  // Swallow matched media key events
        }

        // MARK: Keyboard events
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown {
            cancelPendingModifierTriggers()
        }


        for binding in bindings {
            // Skip mouse button and media key bindings in the keyboard path
            guard !binding.isMouseButton && !binding.isMediaKey else { continue }
            guard binding.keyCode == keyCode else { continue }

            if isModifierKeyCode(keyCode) {
                // Modifier keys: handle via flagsChanged only, don't swallow.
                // For combos like Ctrl+Shift, binding.modifiers stores "other modifiers".
                guard type == .flagsChanged else { continue }
                let pressed = isModifierPressed(keyCode: keyCode, flags: event.flags)

                if pressed {
                    let requiredMods = normalizedModifierFlags(binding.modifiers)
                    let currentMods = otherModifierFlags(for: keyCode, flags: event.flags)
                    guard currentMods == requiredMods else { continue }
                    if shouldDeferModifierTrigger(for: binding) {
                        schedulePendingModifierTrigger(for: binding)
                    } else {
                        cancelPendingModifierTriggers()
                        handleBindingEvent(binding: binding, pressed: true)
                    }
                    return Unmanaged.passUnretained(event)
                } else if consumePendingModifierRelease(for: binding) {
                    return Unmanaged.passUnretained(event)
                } else if isModifierBindingActive(binding) {
                    // Always release active state even if other modifiers were released first.
                    handleBindingEvent(binding: binding, pressed: false)
                    return Unmanaged.passUnretained(event)
                }
                continue
            } else {
                // Regular keys: check modifier flags match
                let requiredMods = normalizedModifierFlags(binding.modifiers, forKeyCode: Int(binding.keyCode))
                let currentMods = normalizedModifierFlags(event.flags, forKeyCode: Int(keyCode))
                guard currentMods == requiredMods else { continue }

                switch binding.style {
                case .hold:
                    if type == .keyDown {
                        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                        if isRepeat != 0 { return nil }
                        handleBindingEvent(binding: binding, pressed: true)
                    } else if type == .keyUp {
                        handleBindingEvent(binding: binding, pressed: false)
                    }
                case .toggle:
                    if type == .keyDown {
                        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
                        if isRepeat != 0 { return nil }
                        handleTogglePress(binding: binding)
                    }
                }
                return nil  // Swallow matched regular key events
            }
        }

        // ESC key (keyCode 53) - abort active recording or processing
        if isESCAbortEnabled && type == .keyDown && keyCode == 53 {
            let isRecording = activeRecordingBindingId != nil
            let shouldAbort = isRecording || isProcessing
            if shouldAbort {
                NSLog("[HotkeyManager] ESC pressed, triggering abort (recording=%@, processing=%@)",
                      isRecording ? "true" : "false", isProcessing ? "true" : "false")
                if onESCAbort?() == true {
                    return nil  // Swallow ESC: abort was handled
                }
                // App is not actually in an active session — stale state.
                // Clean up and let ESC pass through to the system.
                NSLog("[HotkeyManager] ESC abort not handled, resetting stale state")
                isProcessing = false
                resetActiveState()
            }
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Binding dispatch

    private func handleBindingEvent(binding: ModeBinding, pressed: Bool) {
        switch binding.style {
        case .hold:
            if pressed {
                handleHoldPress(binding: binding)
            } else {
                handleHoldRelease(binding: binding)
            }

        case .toggle:
            let bindingId = binding.bindingId
            if pressed {
                guard wasModifierDown[bindingId] != true else { return }
                wasModifierDown[bindingId] = true
                handleTogglePress(binding: binding)
            } else {
                wasModifierDown[bindingId] = false
            }
        }
    }

    private func handleTogglePress(binding: ModeBinding) {
        if activeRecordingBindingId != nil {
            if activeRecordingModeId == binding.modeId {
                stopActiveRecording()
            } else {
                clearActiveRecordingState()
                onCrossModeStop?(binding.modeId)
            }
        } else {
            startRecording(with: binding)
        }
    }

    private func handleHoldPress(binding: ModeBinding) {
        let bindingId = binding.bindingId
        guard holdState[bindingId] != true else { return }

        if activeRecordingBindingId != nil {
            if activeRecordingModeId == binding.modeId {
                stopActiveRecording()
            } else {
                clearActiveRecordingState()
                onCrossModeStop?(binding.modeId)
            }
            return
        }

        holdState[bindingId] = true
        startSafetyTimer(for: binding)
        startRecording(with: binding)
    }

    private func handleHoldRelease(binding: ModeBinding) {
        let bindingId = binding.bindingId
        guard holdState[bindingId] == true else { return }
        holdState[bindingId] = false
        cancelSafetyTimer(for: bindingId)
        if activeRecordingBindingId == bindingId {
            stopActiveRecording()
        }
    }

    private func startRecording(with binding: ModeBinding) {
        activeRecordingBindingId = binding.bindingId
        activeRecordingModeId = binding.modeId
        binding.onStart()
    }

    private func stopActiveRecording() {
        let active = activeRecordingBinding()
        clearActiveRecordingState()
        active?.onStop()
    }

    private func clearActiveRecordingState() {
        if let activeId = activeRecordingBindingId {
            holdState[activeId] = false
            cancelSafetyTimer(for: activeId)
        }
        activeRecordingBindingId = nil
        activeRecordingModeId = nil
    }

    private func activeRecordingBinding() -> ModeBinding? {
        guard let id = activeRecordingBindingId else { return nil }
        return bindings.first { $0.bindingId == id }
    }

    internal func simulateBindingEvent(_ binding: ModeBinding, pressed: Bool) {
        handleBindingEvent(binding: binding, pressed: pressed)
    }

    /// Whether the recording being started came from the hardware device rather than
    /// the keyboard.
    ///
    /// Read by the binding's `onStart` to pick a microphone. Carried here rather than
    /// passed through `ModeBinding` because the bindings are built once at launch and
    /// shared by both trigger paths — the alternative was a parallel set of
    /// device-flavoured bindings that would drift out of step.
    private(set) var isExternalTrigger = false

    /// Drive a recording from something other than a key press — a hardware
    /// device's own button, say.
    ///
    /// Routes through the real binding for `modeId` rather than calling the session
    /// directly, so the external trigger inherits everything the hotkey path does:
    /// provider-specific mode resolution, the toggle-desync guard, the idle wait
    /// before starting, and the safety timers.
    ///
    /// The binding is forced to `.hold` regardless of what the user picked for the
    /// keyboard. A hardware push-to-talk key reports its own press and release, so
    /// interpreting the press as a toggle would make every second recording a stop —
    /// the device opens an audio stream and the host closes its source at the same
    /// moment, and that session records nothing.
    ///
    /// Returns false when no binding matches, which happens if the mode was deleted
    /// or its hotkey unassigned.
    @discardableResult
    func triggerBinding(modeId: UUID, pressed: Bool) -> Bool {
        guard let binding = bindings.first(where: { $0.modeId == modeId }) else {
            NSLog("[Type4Me] external trigger: no binding for mode %@", modeId.uuidString)
            DebugFileLogger.log("external trigger no binding mode=\(modeId)")
            return false
        }
        let pushToTalk = ModeBinding(
            bindingId: binding.bindingId,
            modeId: binding.modeId,
            keyCode: binding.keyCode,
            modifiers: binding.modifiers,
            style: .hold,
            onStart: binding.onStart,
            onStop: binding.onStop
        )
        isExternalTrigger = true
        defer { isExternalTrigger = false }
        handleBindingEvent(binding: pushToTalk, pressed: pressed)
        return true
    }

    /// Whether any mode currently has a binding registered.
    var hasBindings: Bool { !bindings.isEmpty }

    internal func simulateStopActiveRecording() {
        stopActiveRecording()
    }

    internal func isHoldActive(for bindingId: UUID) -> Bool {
        holdState[bindingId] == true
    }

    internal func isActiveRecordingBinding(_ bindingId: UUID) -> Bool {
        activeRecordingBindingId == bindingId
    }

    internal func hasPendingSafetyTimer(for bindingId: UUID) -> Bool {
        holdSafetyTimers[bindingId] != nil
    }

    // MARK: - Modifier Prefix Conflicts

    private func shouldDeferModifierTrigger(for binding: ModeBinding) -> Bool {
        guard isModifierKeyCode(binding.keyCode) else { return false }

        return bindings.contains { other in
            guard other.bindingId != binding.bindingId,
                  !other.isMouseButton,
                  !other.isMediaKey
            else { return false }
            return ModeBinding.modifierBindingIsPrefix(
                modifierKeyCode: Int(binding.keyCode),
                modifierModifiers: binding.modifiers.rawValue,
                otherKeyCode: Int(other.keyCode),
                otherModifiers: other.modifiers.rawValue
            )
        }
    }

    private func schedulePendingModifierTrigger(for binding: ModeBinding) {
        cancelPendingModifierTriggers(except: binding.bindingId)
        let token = UUID()
        pendingModifierTriggers[binding.bindingId] = PendingModifierTrigger(binding: binding, token: token)
        DispatchQueue.main.asyncAfter(deadline: .now() + modifierPrefixTriggerDelay) { [weak self] in
            self?.firePendingModifierTrigger(bindingId: binding.bindingId, token: token)
        }
    }

    private func firePendingModifierTrigger(bindingId: UUID, token: UUID) {
        guard let pending = pendingModifierTriggers[bindingId],
              pending.token == token,
              isExactModifierComboActive(for: pending.binding)
        else { return }
        pendingModifierTriggers.removeValue(forKey: bindingId)
        handleBindingEvent(binding: pending.binding, pressed: true)
    }

    private func consumePendingModifierRelease(for binding: ModeBinding) -> Bool {
        guard let pending = pendingModifierTriggers.removeValue(forKey: binding.bindingId) else { return false }
        handleBindingEvent(binding: pending.binding, pressed: true)
        handleBindingEvent(binding: pending.binding, pressed: false)
        return true
    }

    private func cancelPendingModifierTriggers(except bindingId: UUID? = nil) {
        let ids = pendingModifierTriggers.keys.filter { $0 != bindingId }
        for id in ids {
            pendingModifierTriggers.removeValue(forKey: id)
        }
    }

    private func isExactModifierComboActive(for binding: ModeBinding) -> Bool {
        guard let expected = ModeBinding.fullModifierFlags(
            keyCode: Int(binding.keyCode),
            modifiers: binding.modifiers.rawValue
        ) else { return false }
        let stateFlags = CGEventSource.flagsState(.combinedSessionState)
        var current = normalizedModifierFlags(stateFlags)
        if stateFlags.contains(.maskSecondaryFn) {
            current.insert(.maskSecondaryFn)
        }
        return current == expected
    }

    // MARK: - Safety Timer

    private func startSafetyTimer(for binding: ModeBinding) {
        let id = binding.bindingId
        cancelSafetyTimer(for: id)
        holdSafetyTimers[id] = Timer.scheduledTimer(
            timeInterval: maxHoldDuration,
            target: self,
            selector: #selector(handleHoldSafetyTimer(_:)),
            userInfo: id,
            repeats: false
        )
    }

    private func cancelSafetyTimer(for id: UUID) {
        holdSafetyTimers[id]?.invalidate()
        holdSafetyTimers[id] = nil
    }

    @objc
    private func handleHoldSafetyTimer(_ timer: Timer) {
        guard let id = timer.userInfo as? UUID else { return }
        guard holdState[id] == true else { return }
        guard activeRecordingBindingId == id else { return }
        stopActiveRecording()
    }

    // MARK: - Stuck Hold Recovery

    /// After a tap re-enable, check if any held keys were released while the tap was disabled.
    private func recoverStuckHolds() {
        let currentFlags = CGEventSource.flagsState(.combinedSessionState)

        for binding in bindings where binding.style == .hold {
            let id = binding.bindingId
            guard holdState[id] == true else { continue }

            // Mouse buttons and media keys: no API to query current state, rely on release events instead.
            // Safety timer will catch truly stuck holds.
            if binding.isMouseButton || binding.isMediaKey { continue }

            let stillDown: Bool
            if isModifierKeyCode(binding.keyCode) {
                stillDown = isModifierPressed(keyCode: binding.keyCode, flags: currentFlags)
            } else {
                stillDown = CGEventSource.keyState(.combinedSessionState, key: binding.keyCode)
            }

            if !stillDown {
                NSLog("[HotkeyManager] Recovering stuck hold for binding %@", id.uuidString)
                holdState[id] = false
                cancelSafetyTimer(for: id)
                if activeRecordingBindingId == id {
                    stopActiveRecording()
                }
            }
        }
    }

    // MARK: - Helpers

    private static func isKnownMediaKeyType(_ keyType: Int) -> Bool {
        // NX_KEYTYPE values from IOKit/hidsystem/IOHIDParameter.h
        // SOUND_UP=0, SOUND_DOWN=1, MUTE=7, PLAY=16, NEXT=17, PREVIOUS=18, FAST=19, REWIND=20
        [0, 1, 7, 16, 17, 18, 19, 20].contains(keyType)
    }

    private func isModifierKeyCode(_ keyCode: CGKeyCode) -> Bool {
        ModeBinding.isModifierKeyCode(Int(keyCode))
    }

    private func normalizedModifierFlags(_ flags: CGEventFlags, forKeyCode keyCode: Int? = nil) -> CGEventFlags {
        ModeBinding.normalizedModifierFlags(flags, forKeyCode: keyCode)
    }

    private func modifierEventFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
        ModeBinding.modifierEventFlag(for: Int(keyCode))
    }

    private func otherModifierFlags(for keyCode: CGKeyCode, flags: CGEventFlags) -> CGEventFlags {
        var mods = normalizedModifierFlags(flags)
        if let ownFlag = modifierEventFlag(for: keyCode) {
            mods.remove(ownFlag)
        }
        return mods
    }

    private func isModifierBindingActive(_ binding: ModeBinding) -> Bool {
        switch binding.style {
        case .hold:
            return holdState[binding.bindingId] ?? false
        case .toggle:
            return wasModifierDown[binding.bindingId] ?? false
        }
    }

    private func isModifierPressed(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        case 63: return flags.contains(.maskSecondaryFn)
        default: return false
        }
    }

    @discardableResult
    private func handleMediaKeyEvent(
        keyType: Int,
        isKeyDown: Bool,
        isKeyUp: Bool,
        source: String
    ) -> Bool {
        guard Self.isKnownMediaKeyType(keyType) else { return false }
        let encodedKeyCode = ModeBinding.mediaKeyCode(for: keyType)
        guard let binding = bindings.first(where: {
            $0.isMediaKey && Int($0.keyCode) == encodedKeyCode
        }) else { return false }

        let edge = isKeyDown ? "down" : isKeyUp ? "up" : "unknown"
        if isKeyDown {
            guard mediaKeysDown.insert(keyType).inserted else {
                DebugFileLogger.log(
                    "hotkey media source=\(source) keyType=\(keyType) edge=\(edge) action=duplicate_ignored")
                return true
            }
        } else if isKeyUp {
            guard mediaKeysDown.remove(keyType) != nil else {
                DebugFileLogger.log(
                    "hotkey media source=\(source) keyType=\(keyType) edge=\(edge) action=orphan_release_ignored")
                return true
            }
        } else {
            DebugFileLogger.log(
                "hotkey media source=\(source) keyType=\(keyType) edge=\(edge) action=ignored")
            return true
        }

        DebugFileLogger.log(
            "hotkey media source=\(source) keyType=\(keyType) edge=\(edge) action=dispatch style=\(binding.style.rawValue) mode=\(binding.modeId.uuidString)")
        switch binding.style {
        case .hold:
            handleBindingEvent(binding: binding, pressed: isKeyDown)
        case .toggle:
            if isKeyDown {
                handleTogglePress(binding: binding)
            }
        }
        return true
    }

    @discardableResult
    private func handleHeadsetMediaKeyPulse(keyType: Int) -> Bool {
        guard [0, 1, 16].contains(keyType) else { return false }

        let encodedKeyCode = ModeBinding.mediaKeyCode(for: keyType)
        guard let binding = bindings.first(where: {
            $0.isMediaKey && Int($0.keyCode) == encodedKeyCode
        }) else { return false }

        recentHeadsetMediaKeyPresses[keyType] = Date()
        DebugFileLogger.log(
            "hotkey media source=headset-hid keyType=\(keyType) edge=press action=dispatch style=\(binding.style.rawValue) mode=\(binding.modeId.uuidString)")
        // The HID monitor normalizes each physical gesture into one pulse.
        // Headset buttons therefore use click-to-toggle semantics for both styles.
        handleTogglePress(binding: binding)
        return true
    }

    private func updateHeadsetMediaKeyMonitor() {
        let needsMonitoring = eventTap != nil && !isSuppressed && bindings.contains { binding in
            binding.isMediaKey && [0, 1, 16].contains(
                ModeBinding.mediaKeyType(from: Int(binding.keyCode)))
        }

        guard needsMonitoring else {
            stopHeadsetMediaKeyMonitor()
            return
        }
        guard headsetMediaKeyMonitor == nil else { return }

        let monitor = HeadsetMediaKeyMonitor(
            onButtonDetected: { [weak self] keyType in
                self?.onHeadsetButtonRecognized?(keyType)
            },
            onEvent: { [weak self] keyType, _ in
                guard let self else { return false }
                return self.handleHeadsetMediaKeyPulse(keyType: keyType)
            }
        )
        guard monitor.start() else {
            NSLog("[HotkeyManager] Failed to open analog headset HID; using CGEvent fallback")
            DebugFileLogger.log("headset HID start failed; using system-media fallback")
            return
        }

        headsetMediaKeyMonitor = monitor
        NSLog("[HotkeyManager] Analog headset HID opened exclusively")
        DebugFileLogger.log("headset HID monitor started")
    }

    private func stopHeadsetMediaKeyMonitor() {
        guard let monitor = headsetMediaKeyMonitor else { return }
        monitor.stop()
        headsetMediaKeyMonitor = nil
        NSLog("[HotkeyManager] Analog headset HID released")
        DebugFileLogger.log("headset HID monitor stopped")
    }

    internal func simulateMediaKeyEvent(keyType: Int, pressed: Bool) -> Bool {
        handleMediaKeyEvent(
            keyType: keyType,
            isKeyDown: pressed,
            isKeyUp: !pressed,
            source: "simulated"
        )
    }

    internal func simulateHeadsetMediaKeyPulse(keyType: Int = 16) -> Bool {
        handleHeadsetMediaKeyPulse(keyType: keyType)
    }

    // MARK: - Media Session (prevent Apple Music auto-launch)

    /// Register as an active media session when transport media keys (play/next/prev)
    /// are bound as hotkeys, so the system doesn't launch Apple Music on key press.
    private func updateMediaKeySession() {
        for (command, token) in mediaCommandTokens {
            command.removeTarget(token)
        }
        mediaCommandTokens = []

        // Find which transport key types are bound (volume keys don't launch Apple Music)
        let boundKeyTypes = Set(bindings.filter(\.isMediaKey).map { ModeBinding.mediaKeyType(from: Int($0.keyCode)) })
        let transportKeyTypes: Set<Int> = [16, 17, 18, 19, 20]
        let boundTransportKeys = boundKeyTypes.intersection(transportKeyTypes)

        if boundTransportKeys.isEmpty {
            if isMediaSessionActive {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                MPNowPlayingInfoCenter.default().playbackState = .stopped
                isMediaSessionActive = false
                NSLog("[HotkeyManager] Deactivated media session (no transport keys bound)")
            }
            return
        }

        let commandCenter = MPRemoteCommandCenter.shared()

        if !isMediaSessionActive {
            // Must set non-empty NowPlaying info with playbackState=.playing —
            // mediaremoted on macOS 15 ignores apps with empty nowPlayingInfo.
            let nowPlayingInfo: [String: Any] = [
                MPMediaItemPropertyTitle: "Type4Me Voice Input",
                MPNowPlayingInfoPropertyPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            ]
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
            MPNowPlayingInfoCenter.default().playbackState = .playing
            isMediaSessionActive = true
            NSLog("[HotkeyManager] Activated media session (transport keys bound)")
        }

        let handler: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { event in
            NSLog("[HotkeyManager] Media remote command received: %@", String(describing: type(of: event)))
            return .success
        }

        if boundTransportKeys.contains(16) {
            commandCenter.playCommand.isEnabled = true
            commandCenter.pauseCommand.isEnabled = true
            commandCenter.togglePlayPauseCommand.isEnabled = true

            let playToken = commandCenter.playCommand.addTarget(handler: handler)
            let pauseToken = commandCenter.pauseCommand.addTarget(handler: handler)
            let toggleToken = commandCenter.togglePlayPauseCommand.addTarget(handler: handler)
            mediaCommandTokens.append(contentsOf: [
                (command: commandCenter.playCommand, token: playToken),
                (command: commandCenter.pauseCommand, token: pauseToken),
                (command: commandCenter.togglePlayPauseCommand, token: toggleToken),
            ])
        }
        if boundTransportKeys.contains(17) {
            commandCenter.nextTrackCommand.isEnabled = true
            let token = commandCenter.nextTrackCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.nextTrackCommand, token: token))
        }
        if boundTransportKeys.contains(18) {
            commandCenter.previousTrackCommand.isEnabled = true
            let token = commandCenter.previousTrackCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.previousTrackCommand, token: token))
        }
        if boundTransportKeys.contains(19) {
            commandCenter.seekForwardCommand.isEnabled = true
            let token = commandCenter.seekForwardCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.seekForwardCommand, token: token))
        }
        if boundTransportKeys.contains(20) {
            commandCenter.seekBackwardCommand.isEnabled = true
            let token = commandCenter.seekBackwardCommand.addTarget(handler: handler)
            mediaCommandTokens.append((command: commandCenter.seekBackwardCommand, token: token))
        }
    }

    private func deactivateMediaKeySession() {
        for (command, token) in mediaCommandTokens {
            command.isEnabled = false
            command.removeTarget(token)
        }
        mediaCommandTokens = []
        if isMediaSessionActive {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            isMediaSessionActive = false
            NSLog("[HotkeyManager] Deactivated media session (stop)")
        }
    }
}

// MARK: - C callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(type: type, event: event)
}
