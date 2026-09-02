import AppKit
import Carbon.HIToolbox

/// Keystrokes the device's non-recording keys ask for.
///
/// The device reports gestures, not keys — `enter` and `clear` — because what they
/// should do belongs to the host. Both post CGEvents to the frontmost app, so they
/// need the same Accessibility permission the hotkeys and text injection already do.
enum PassportKeystroke {

    /// Submit: the DOWN key clicked.
    static func pressReturn() {
        post(keyCode: CGKeyCode(kVK_Return))
        DebugFileLogger.log("passport keystroke return")
    }

    /// Clear the focused input field: the DOWN key held.
    ///
    /// Select-all then delete, rather than a run of backspaces — a long text would
    /// otherwise take hundreds of events and visibly crawl. Cmd-A is near-universal
    /// on macOS, though an app with a custom text view may interpret it differently.
    static func clearInputField() {
        post(keyCode: CGKeyCode(kVK_ANSI_A), flags: .maskCommand)
        // A beat for the selection to land before the delete replaces it; without
        // it a slow text view can process the delete against a stale selection.
        usleep(20_000)
        post(keyCode: CGKeyCode(kVK_Delete))
        DebugFileLogger.log("passport keystroke clear")
    }

    private static func post(keyCode: CGKeyCode, flags: CGEventFlags = []) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }

        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }
    }
}
