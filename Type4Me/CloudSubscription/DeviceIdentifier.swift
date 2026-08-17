import Foundation
import IOKit

enum DeviceIdentifier {
    static var deviceID: String {
        if let hwUUID = hardwareUUID() {
            return hwUUID
        }
        return persistentFallbackUUID()
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, "IOPlatformUUID" as CFString,
            kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
    }

    private static func persistentFallbackUUID() -> String {
        let key = "tf_deviceFallbackUUID"
        if let uuid = UserDefaults.standard.string(forKey: key), !uuid.isEmpty {
            return uuid
        }
        let uuid = UUID().uuidString
        UserDefaults.standard.set(uuid, forKey: key)
        return uuid
    }
}
