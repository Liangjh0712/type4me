import CoreGraphics
import Foundation
import IOKit
import IOKit.hid

/// Remaps the built-in analog headset's Play/Pause usage to F20 while Type4Me owns it.
/// The mapping happens inside the HID event service, before macOS can reinterpret the
/// same AppleMikey event as a Siri command.
final class HeadsetMediaKeyRemapper {
    static let remappedVirtualKeyCode: CGKeyCode = 90 // F20

    private static let sourceUsage = UInt64(0x0C000000CD) // Consumer / Play or Pause
    private static let destinationUsage = UInt64(0x070000006F) // Keyboard / F20
    private static let mappingKey = "UserKeyMapping"
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"

    static let playPauseMapping: [String: NSNumber] = [
        sourceKey: NSNumber(value: sourceUsage),
        destinationKey: NSNumber(value: destinationUsage),
    ]

    private struct ServiceState {
        let service: IOHIDServiceClient
        let originalMappings: [[String: NSNumber]]
    }

    private let client: IOHIDEventSystemClient
    private var services: [UInt64: ServiceState] = [:]
    private var deviceChangeObserver: NSObjectProtocol?
    private var isRunning = false

    init() {
        client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    }

    deinit {
        stop()
    }

    func start() -> Bool {
        guard !isRunning else { return true }
        isRunning = true
        deviceChangeObserver = NotificationCenter.default.addObserver(
            forName: .audioInputDevicesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
        return refresh()
    }

    func stop() {
        guard isRunning else { return }
        if let deviceChangeObserver {
            NotificationCenter.default.removeObserver(deviceChangeObserver)
            self.deviceChangeObserver = nil
        }
        for state in services.values {
            IOHIDServiceClientSetProperty(
                state.service,
                Self.mappingKey as CFString,
                state.originalMappings as CFArray
            )
        }
        services = [:]
        isRunning = false
    }

    static func mappingsByAddingPlayPauseRemap(
        to mappings: [[String: NSNumber]]
    ) -> [[String: NSNumber]] {
        mappings.filter { !isPlayPauseRemap($0) } + [playPauseMapping]
    }

    static func mappingsByRemovingPlayPauseRemap(
        from mappings: [[String: NSNumber]]
    ) -> [[String: NSNumber]] {
        mappings.filter { !isPlayPauseRemap($0) }
    }

    @discardableResult
    func refresh() -> Bool {
        guard isRunning else { return false }
        let matchingServices = Self.headsetServices(in: client)
        let currentIDs = Set(matchingServices.compactMap(Self.registryID))
        services = services.filter { currentIDs.contains($0.key) }

        var allMappingsSucceeded = true
        for service in matchingServices {
            guard let id = Self.registryID(service) else { continue }
            let existing = Self.mappingArray(
                from: IOHIDServiceClientCopyProperty(service, Self.mappingKey as CFString)
            )
            let original = Self.mappingsByRemovingPlayPauseRemap(from: existing)
            if !existing.contains(where: Self.isPlayPauseRemap) {
                let remapped = Self.mappingsByAddingPlayPauseRemap(to: original)
                guard IOHIDServiceClientSetProperty(
                    service,
                    Self.mappingKey as CFString,
                    remapped as CFArray
                ) else {
                    allMappingsSucceeded = false
                    continue
                }
            }
            services[id] = ServiceState(service: service, originalMappings: original)
        }
        return allMappingsSucceeded
    }

    private static func headsetServices(
        in client: IOHIDEventSystemClient
    ) -> [IOHIDServiceClient] {
        let allServices = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        return allServices.filter { service in
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
    }

    private static func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private static func mappingArray(from value: CFTypeRef?) -> [[String: NSNumber]] {
        value as? [[String: NSNumber]] ?? []
    }

    private static func isPlayPauseRemap(_ mapping: [String: NSNumber]) -> Bool {
        mapping[sourceKey]?.uint64Value == sourceUsage
            && mapping[destinationKey]?.uint64Value == destinationUsage
    }
}
