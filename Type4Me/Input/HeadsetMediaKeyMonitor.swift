import Cocoa
import Foundation
import IOKit
import IOKit.hid

/// Captures the built-in analog headset remote before macOS can reinterpret it.
/// Each physical press/release cycle is normalized into exactly one logical
/// media-key press inside Type4Me.
final class HeadsetMediaKeyMonitor {
    typealias EventHandler = (_ keyType: Int, _ pressed: Bool) -> Bool
    typealias DetectionHandler = (_ keyType: Int) -> Void

    struct ButtonPressState {
        private(set) var isDown = false
        private(set) var didDispatchForCurrentPress = false

        mutating func beginPress() -> Bool {
            guard !isDown else { return false }
            isDown = true
            didDispatchForCurrentPress = false
            return true
        }

        mutating func endPress() -> Bool {
            guard isDown else { return true }
            isDown = false
            let shouldDispatch = !didDispatchForCurrentPress
            didDispatchForCurrentPress = false
            return shouldDispatch
        }

        mutating func handleLongPressTimeout() -> Bool {
            guard isDown, !didDispatchForCurrentPress else { return false }
            didDispatchForCurrentPress = true
            return true
        }

        mutating func reset() {
            isDown = false
            didDispatchForCurrentPress = false
        }
    }

    private static let playPauseUsage = UInt32(kHIDUsage_Csmr_PlayOrPause)
    private static let volumeUpUsage = UInt32(kHIDUsage_Csmr_VolumeIncrement)
    private static let volumeDownUsage = UInt32(kHIDUsage_Csmr_VolumeDecrement)
    private static let reportButtons: [(usage: UInt32, keyType: Int, mask: UInt8)] = [
        (playPauseUsage, 16, 1 << 0),
        (volumeDownUsage, 1, 1 << 1),
        (volumeUpUsage, 0, 1 << 2),
    ]

    // Removed on startup to recover machines left with the previous F20 mapping
    // after an app crash or forced termination.
    private static let legacySourceUsage = UInt64(0x0C000000CD)
    private static let legacyDestinationUsage = UInt64(0x070000006F)
    private static let mappingKey = "UserKeyMapping"
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"

    private let manager: IOHIDManager
    private let onButtonDetected: DetectionHandler
    private let onEvent: EventHandler
    private var isRunning = false
    private var buttonStates: [UInt32: ButtonPressState] = [:]
    private var buttonTimers: [UInt32: Timer] = [:]
    private let longPressDelay: TimeInterval = 0.25
    private var lastReportByte: UInt8 = 0

    init(onButtonDetected: @escaping DetectionHandler, onEvent: @escaping EventHandler) {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.onButtonDetected = onButtonDetected
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
        IOHIDManagerRegisterInputReportCallback(
            manager,
            { context, result, _, reportType, reportID, report, reportLength in
                guard let context else { return }
                Unmanaged<HeadsetMediaKeyMonitor>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .handleInputReport(
                        result: result,
                        reportType: reportType,
                        reportID: reportID,
                        report: report,
                        reportLength: reportLength
                    )
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
        buttonTimers.values.forEach { $0.invalidate() }
        buttonTimers = [:]
        buttonStates = [:]
        lastReportByte = 0
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

    private func handleInputReport(
        result: IOReturn,
        reportType: IOHIDReportType,
        reportID: UInt32,
        report: UnsafeMutablePointer<UInt8>,
        reportLength: CFIndex
    ) {
        guard result == kIOReturnSuccess, reportType == kIOHIDReportTypeInput,
              reportID == 0, reportLength > 0
        else {
            if result != kIOReturnSuccess {
                DebugFileLogger.log(
                    "headset HID report failed result=\(String(format: "0x%08x", result))")
            }
            return
        }

        let reportByte = report.pointee
        let changedBits = reportByte ^ lastReportByte
        lastReportByte = reportByte
        guard changedBits != 0 else { return }

        for button in Self.reportButtons where changedBits & button.mask != 0 {
            handleButtonValue(
                usage: button.usage,
                keyType: button.keyType,
                pressed: reportByte & button.mask != 0
            )
        }
    }

    private func handleButtonValue(usage: UInt32, keyType: Int, pressed: Bool) {
        var state = buttonStates[usage] ?? ButtonPressState()
        if pressed {
            guard state.beginPress() else { return }
            onButtonDetected(keyType)
            buttonStates[usage] = state
            buttonTimers.removeValue(forKey: usage)?.invalidate()
            let timer = Timer(timeInterval: longPressDelay, repeats: false) { [weak self] _ in
                guard let self, var state = self.buttonStates[usage],
                      state.handleLongPressTimeout()
                else { return }
                self.buttonStates[usage] = state
                self.dispatchButtonPress(sourceKeyType: keyType, reason: "long_press")
            }
            RunLoop.main.add(timer, forMode: .common)
            buttonTimers[usage] = timer
            DebugFileLogger.log(
                "headset HID sourceKeyType=\(keyType) rawEdge=down action=pending_release")
            return
        }

        buttonTimers.removeValue(forKey: usage)?.invalidate()
        if !state.isDown {
            onButtonDetected(keyType)
        }
        let shouldDispatch = state.endPress()
        buttonStates[usage] = state
        if shouldDispatch {
            dispatchButtonPress(sourceKeyType: keyType, reason: "release")
        } else {
            DebugFileLogger.log(
                "headset HID sourceKeyType=\(keyType) rawEdge=up action=long_press_release_ignored")
        }
    }

    private func dispatchButtonPress(sourceKeyType: Int, reason: String) {
        let handled = onEvent(sourceKeyType, true)
        DebugFileLogger.log(
            "headset HID sourceKeyType=\(sourceKeyType) edge=press reason=\(reason) action=\(handled ? "dispatch" : "forward")")
        if !handled {
            Self.postSystemMediaKey(keyType: sourceKeyType, pressed: true)
            Self.postSystemMediaKey(keyType: sourceKeyType, pressed: false)
        }
    }

    private func handleDeviceMatched(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else { return }
        Self.removeLegacyPlayPauseMappings()
        DebugFileLogger.log("headset HID device connected product=\(Self.productName(of: device))")
    }

    private func handleDeviceRemoved(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else { return }
        buttonTimers.values.forEach { $0.invalidate() }
        buttonTimers = [:]
        buttonStates = [:]
        lastReportByte = 0
        DebugFileLogger.log("headset HID device removed product=\(Self.productName(of: device))")
    }



    private static func postSystemMediaKey(keyType: Int, pressed: Bool) {
        let state = pressed ? 0x0A : 0x0B
        let data1 = (keyType << 16) | (state << 8)
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
