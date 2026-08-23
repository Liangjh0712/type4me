import Cocoa
import Foundation
import IOKit
import IOKit.hid

/// Exclusively captures the built-in analog headset remote before macOS can
/// reinterpret its center button as a Siri command. Events stay as media-key
/// events inside Type4Me; no synthetic keyboard key or key-up state is involved.
final class HeadsetMediaKeyMonitor {
    typealias EventHandler = (_ keyType: Int, _ pressed: Bool) -> Bool

    private static let playPauseUsage = UInt32(kHIDUsage_Csmr_PlayOrPause)
    private static let volumeUpUsage = UInt32(kHIDUsage_Csmr_VolumeIncrement)
    private static let volumeDownUsage = UInt32(kHIDUsage_Csmr_VolumeDecrement)

    // Removed on startup to recover machines left with the previous F20 mapping
    // after an app crash or forced termination.
    private static let legacySourceUsage = UInt64(0x0C000000CD)
    private static let legacyDestinationUsage = UInt64(0x070000006F)
    private static let mappingKey = "UserKeyMapping"
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"

    private let manager: IOHIDManager
    private let onEvent: EventHandler
    private var isRunning = false
    private var pressedUsages: Set<UInt32> = []
    private var forwardedMediaKeysDown: Set<Int> = []
    private var volumeRepeatTimers: [Int: Timer] = [:]

    init(onEvent: @escaping EventHandler) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.onEvent = onEvent
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        guard !isRunning else { return true }

        let matching: [String: Any] = [
            kIOHIDProductKey: "Headset",
            kIOHIDTransportKey: "Audio",
            kIOHIDPrimaryUsagePageKey: kHIDPage_Consumer,
            kIOHIDPrimaryUsageKey: kHIDUsage_Csmr_ConsumerControl,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(
            manager,
            { context, result, _, value in
                guard let context else { return }
                Unmanaged<HeadsetMediaKeyMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .handleInputValue(result: result, value: value)
            },
            context
        )
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, result, _, device in
                guard let context else { return }
                Unmanaged<HeadsetMediaKeyMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .handleDeviceMatched(result: result, device: device)
            },
            context
        )
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, result, _, device in
                guard let context else { return }
                Unmanaged<HeadsetMediaKeyMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .handleDeviceRemoved(result: result, device: device)
            },
            context
        )

        Self.removeLegacyPlayPauseMappings()
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            DebugFileLogger.log(
                "headset HID open failed result=\(String(format: "0x%08x", result))")
            return false
        }

        isRunning = true
        let deviceCount = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>)?.count ?? 0
        DebugFileLogger.log("headset HID started exclusive=true devices=\(deviceCount)")
        return true
    }

    func stop() {
        guard isRunning else { return }
        releasePressedButtons()
        volumeRepeatTimers.values.forEach { $0.invalidate() }
        volumeRepeatTimers = [:]
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        isRunning = false
        DebugFileLogger.log("headset HID stopped")
    }

    static func mediaKeyType(forConsumerUsage usage: UInt32) -> Int? {
        switch usage {
        case playPauseUsage: return 16  // NX_KEYTYPE_PLAY
        case volumeUpUsage: return 0    // NX_KEYTYPE_SOUND_UP
        case volumeDownUsage: return 1  // NX_KEYTYPE_SOUND_DOWN
        default: return nil
        }
    }

    static func mappingsByRemovingLegacyPlayPauseRemap(
        from mappings: [[String: NSNumber]]
    ) -> [[String: NSNumber]] {
        mappings.filter { mapping in
            mapping[sourceKey]?.uint64Value != legacySourceUsage
                || mapping[destinationKey]?.uint64Value != legacyDestinationUsage
        }
    }

    private func handleInputValue(result: IOReturn, value: IOHIDValue) {
        guard result == kIOReturnSuccess else {
            DebugFileLogger.log(
                "headset HID value failed result=\(String(format: "0x%08x", result))")
            return
        }

        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_Consumer) else { return }
        let usage = IOHIDElementGetUsage(element)
        guard let keyType = Self.mediaKeyType(forConsumerUsage: usage) else { return }
        let pressed = IOHIDValueGetIntegerValue(value) != 0

        if pressed {
            guard pressedUsages.insert(usage).inserted else { return }
        } else {
            guard pressedUsages.remove(usage) != nil else { return }
        }

        let handled = onEvent(keyType, pressed)
        DebugFileLogger.log(
            "headset HID keyType=\(keyType) edge=\(pressed ? "down" : "up") action=\(handled ? "dispatch" : "forward")")
        if !handled {
            forwardToSystem(keyType: keyType, pressed: pressed)
        }
    }

    private func handleDeviceMatched(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else { return }
        Self.removeLegacyPlayPauseMappings()
        DebugFileLogger.log("headset HID device connected product=\(Self.productName(of: device))")
    }

    private func handleDeviceRemoved(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else { return }
        releasePressedButtons()
        DebugFileLogger.log("headset HID device removed product=\(Self.productName(of: device))")
    }

    private func releasePressedButtons() {
        let usages = pressedUsages
        pressedUsages.removeAll()
        for usage in usages {
            guard let keyType = Self.mediaKeyType(forConsumerUsage: usage) else { continue }
            if forwardedMediaKeysDown.contains(keyType) {
                forwardToSystem(keyType: keyType, pressed: false)
            } else {
                _ = onEvent(keyType, false)
            }
        }
    }

    private func forwardToSystem(keyType: Int, pressed: Bool) {
        if pressed {
            forwardedMediaKeysDown.insert(keyType)
            Self.postSystemMediaKey(keyType: keyType, pressed: true)
            if keyType == 0 || keyType == 1 {
                startVolumeRepeat(for: keyType)
            }
        } else {
            guard forwardedMediaKeysDown.remove(keyType) != nil else { return }
            stopVolumeRepeat(for: keyType)
            Self.postSystemMediaKey(keyType: keyType, pressed: false)
        }
    }

    private func startVolumeRepeat(for keyType: Int) {
        stopVolumeRepeat(for: keyType)
        let timer = Timer(timeInterval: 0.08, repeats: true) { _ in
            Self.postSystemMediaKey(keyType: keyType, pressed: true, isRepeat: true)
        }
        timer.fireDate = Date(timeIntervalSinceNow: 0.35)
        RunLoop.main.add(timer, forMode: .common)
        volumeRepeatTimers[keyType] = timer
    }

    private func stopVolumeRepeat(for keyType: Int) {
        volumeRepeatTimers.removeValue(forKey: keyType)?.invalidate()
    }

    private static func postSystemMediaKey(
        keyType: Int,
        pressed: Bool,
        isRepeat: Bool = false
    ) {
        let state = pressed ? 0x0A : 0x0B
        let repeatFlag = isRepeat ? 1 : 0
        let data1 = (keyType << 16) | (state << 8) | repeatFlag
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        )
        event?.cgEvent?.post(tap: CGEventTapLocation.cghidEventTap)
    }

    private static func removeLegacyPlayPauseMappings() {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        for service in services where isAnalogHeadsetService(service) {
            let existing = mappingArray(
                from: IOHIDServiceClientCopyProperty(service, mappingKey as CFString)
            )
            let cleaned = mappingsByRemovingLegacyPlayPauseRemap(from: existing)
            guard cleaned.count != existing.count else { continue }
            if IOHIDServiceClientSetProperty(service, mappingKey as CFString, cleaned as CFArray) {
                DebugFileLogger.log("headset HID removed legacy F20 mapping")
            }
        }
    }

    private static func isAnalogHeadsetService(_ service: IOHIDServiceClient) -> Bool {
        let product = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDProductKey as CFString
        ) as? String
        let transport = IOHIDServiceClientCopyProperty(
            service,
            kIOHIDTransportKey as CFString
        ) as? String
        return product == "Headset"
            && transport == "Audio"
            && IOHIDServiceClientConformsTo(
                service,
                UInt32(kHIDPage_Consumer),
                UInt32(kHIDUsage_Csmr_ConsumerControl)
            ) != 0
    }

    private static func mappingArray(from value: CFTypeRef?) -> [[String: NSNumber]] {
        value as? [[String: NSNumber]] ?? []
    }

    private static func productName(of device: IOHIDDevice) -> String {
        IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    }
}
