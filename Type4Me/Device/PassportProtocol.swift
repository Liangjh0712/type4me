import Foundation

/// The JSON message layer on top of `PassportFrame`.
///
/// Uplink lines use the key `"event"`, downlink lines use `"type"` — an asymmetry
/// that comes straight from the firmware's `main/app_protocol.c` and is easy to
/// get wrong in both directions.
enum PassportProtocol {

    /// Uplink field caps, from `main/app_protocol.h`.
    static let uplinkLineCap = 512
    /// Downlink line cap.
    static let downlinkLineCap = 2048
    /// `transcript.text` and `agent.status.message` share a 128-byte buffer on the
    /// device, one of which the terminating NUL claims.
    static let displayTextCap = 127

    // MARK: - Device → host

    enum Event: Sendable, Equatable {
        /// Wired link handshake completed. Never sent over BLE.
        case hello(proto: Int)
        /// Record key pressed. Carries which encoding this session will use, and
        /// whether it is a quick note — the OK key records the same way but the
        /// text is kept rather than typed.
        case voiceStart(encoding: PassportAudioEncoding, isNote: Bool)
        /// Record key released; the device has drained its audio ring.
        case voiceEnd
        /// Sent right after `voiceEnd`: how many frames the device itself dropped.
        case status(drop: Int)
        /// The user discarded this recording from the device during recognition.
        ///
        /// The device has already returned to its ready screen and will ignore any
        /// transcript that arrives afterwards, but that is only its own view — the
        /// host is still running ASR and would type the result out. Without acting
        /// on this, "cancel" merely tidies the device screen while the words the
        /// user rejected still land in their document.
        case sessionAbort
        /// A key gesture the host must turn into a keystroke.
        case keyAction(KeyAction)
        /// A verdict from the on-device approval screen. Unused for voice input.
        case agentAction(taskID: String, action: String)

        enum KeyAction: String, Sendable {
            /// DOWN clicked: submit.
            case enter
            /// DOWN held: clear the whole input field.
            case clear
        }
    }

    /// Parse one uplink JSON line. Returns nil for anything unrecognized — the
    /// firmware may add events, and an unknown one is not an error.
    static func parseEvent(_ line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["event"] as? String
        else { return nil }

        switch name {
        case "device.hello":
            return .hello(proto: object["proto"] as? Int ?? 0)

        case "voice.start":
            // Trust the device's declaration rather than the transport's default:
            // the same firmware serves PCM over USB and ADPCM over BLE.
            let wireName = object["audio"] as? String ?? PassportAudioEncoding.pcm.rawValue
            guard let encoding = PassportAudioEncoding(wireName: wireName) else { return nil }
            // Absent on a normal recording, so a device running older firmware
            // simply never reports notes rather than failing to parse.
            let isNote = object["note"] as? Bool ?? false
            return .voiceStart(encoding: encoding, isNote: isNote)

        case "voice.end":
            return .voiceEnd

        case "status":
            return .status(drop: object["drop"] as? Int ?? 0)

        case "session.abort":
            return .sessionAbort

        case "key.action":
            guard let raw = object["action"] as? String,
                  let action = Event.KeyAction(rawValue: raw)
            else { return nil }
            return .keyAction(action)

        case "agent.action":
            guard let taskID = object["taskId"] as? String,
                  let action = object["action"] as? String
            else { return nil }
            return .agentAction(taskID: taskID, action: action)

        default:
            return nil
        }
    }

    // MARK: - Host → device

    /// Session state as the device understands it.
    ///
    /// The device leaves TRANSCRIBING **only** on receiving one of these, so a
    /// terminal state must be sent on every path out of a recording — see
    /// `PassportLink.finishSession`.
    enum AgentState: String, Sendable {
        case ready
        case thinking
        case running
        case error
        case done
    }

    /// Push text to the device screen. `final` false is a live preview.
    static func transcript(_ text: String, final: Bool) -> String {
        encode(["type": "transcript", "text": text, "final": final])
    }

    /// Set the device's session state. `state` must be a known value or the device
    /// rejects the whole line.
    static func agentStatus(_ state: AgentState, message: String = "") -> String {
        encode(["type": "agent.status", "state": state.rawValue, "message": message])
    }

    /// Sync the wall clock. The device has no SNTP, so without this its timestamps
    /// start from the epoch.
    static func timeSet(epoch: Int) -> String {
        encode(["type": "time.set", "epoch": epoch])
    }

    private static func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8)
        else { return "{}" }
        return line
    }

    // MARK: - Display text

    /// Split text to fit the device's display buffer without cutting a character
    /// in half. Chinese costs three bytes per glyph, so a 40-character sentence
    /// already needs two segments.
    static func splitForDisplay(_ text: String, cap: Int = displayTextCap) -> [String] {
        guard !text.isEmpty else { return [] }
        guard text.utf8.count > cap else { return [text] }

        var segments: [String] = []
        var current = ""
        var currentBytes = 0
        for character in text {
            let size = String(character).utf8.count
            if !current.isEmpty, currentBytes + size > cap {
                segments.append(current)
                current = ""
                currentBytes = 0
            }
            current.append(character)
            currentBytes += size
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }
}
