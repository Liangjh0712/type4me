import Foundation

/// User preferences for the hardware voice device link.
enum PassportLinkPreferences {

    /// Whether to look for the device over Bluetooth.
    ///
    /// On by default: wireless is the point of a handheld card. Turning it off keeps
    /// the link wired-only, which is useful while debugging (the wired channel has a
    /// console) and avoids a pairing prompt for anyone who does not own the hardware.
    static let bluetoothEnabledKey = "tf_passportBluetoothEnabled"

    static var isBluetoothEnabled: Bool {
        get {
            // Absent means "never set", which should behave as enabled rather than
            // as the `false` a missing Bool decodes to.
            guard UserDefaults.standard.object(forKey: bluetoothEnabledKey) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: bluetoothEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: bluetoothEnabledKey)
        }
    }
}
