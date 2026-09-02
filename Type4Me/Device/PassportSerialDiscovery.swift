import Foundation
import IOKit
import IOKit.serial

/// Finds the AI Passport's serial port.
///
/// The board exposes ESP32-C3 native USB Serial/JTAG (GPIO18/19), which macOS
/// surfaces as a `/dev/cu.usbmodem*` callout device — no driver needed. We match
/// on Espressif's USB vendor/product IDs rather than the path, because the path
/// number changes between plug-ins and between ports.
enum PassportSerialDiscovery {

    /// Espressif Systems.
    static let vendorID = 0x303A
    /// ESP32-C3/S3 USB Serial/JTAG.
    static let productID = 0x1001

    struct Port: Sendable, Equatable {
        /// Callout device path, e.g. `/dev/cu.usbmodem21401`.
        let path: String
        /// The board's MAC, which the USB descriptor carries as the serial number
        /// (e.g. `4C:11:AE:31:3D:48`). Stable across reconnects, so it is the
        /// right key for "is this the same device".
        let serialNumber: String?
    }

    /// Every attached Espressif serial port, most likely candidate first.
    static func availablePorts() -> [Port] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }

        // Restrict to callout devices (`/dev/cu.*`). The dial-in variant
        // (`/dev/tty.*`) blocks on open until carrier detect, which never comes.
        let matchingDict = matching as NSMutableDictionary
        matchingDict[kIOSerialBSDTypeKey] = kIOSerialBSDAllTypes

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var ports: [Port] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            guard let path = stringProperty(service, kIOCalloutDeviceKey) else { continue }
            // USB IDs live on an ancestor of the serial node, not the node itself.
            guard numberProperty(service, "idVendor") == vendorID,
                  numberProperty(service, "idProduct") == productID
            else { continue }

            ports.append(Port(path: path, serialNumber: stringProperty(service, "USB Serial Number")))
        }
        return ports
    }

    /// The port to use, if exactly one plausible device is attached.
    static func preferredPort() -> Port? {
        availablePorts().first
    }

    // MARK: - Registry helpers

    /// Read a string property, searching parents — USB descriptors (vendor,
    /// product, serial) are published by the USB device, several levels above the
    /// serial node that owns the path.
    private static func stringProperty(_ service: io_object_t, _ key: String) -> String? {
        let value = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func numberProperty(_ service: io_object_t, _ key: String) -> Int? {
        let value = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
        return (value as? NSNumber)?.intValue
    }
}
