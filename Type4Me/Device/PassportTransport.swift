import Foundation

/// One physical link to an AI Passport device.
///
/// The device speaks the same events and audio over two very different pipes —
/// a wired byte stream and BLE GATT — so the session layer above works in terms
/// of decoded frames and never learns which one is attached. Mirrors the five
/// method contract the reference client uses (`companion/serial_transport.py`).
protocol PassportTransport: AnyObject, Sendable {

    /// Human-readable identifier for logs and the settings UI, e.g. a port path.
    var displayName: String { get }

    /// Whether the audio arriving on this link is raw PCM or ADPCM. The device
    /// announces the truth per session in `voice.start`; this is the transport's
    /// expectation, used to pick a decoder before the first frame lands.
    var audioEncoding: PassportAudioEncoding { get }

    /// Called for every decoded inbound frame, on the transport's own queue.
    var onFrame: ((PassportFrame.Message) -> Void)? { get set }

    /// Called once when the link drops, for any reason including `close()`.
    var onDisconnect: (() -> Void)? { get set }

    /// Attach to the device and start delivering frames. Throws if unavailable.
    func open() throws

    /// Detach. Idempotent.
    func close()

    /// Send one host→device frame. Failures are logged, not thrown: the protocol
    /// never retries a downlink, and a dropped one must not abort the session.
    func send(_ kind: PassportFrame.Kind, _ payload: Data)
}

extension PassportTransport {
    func send(_ kind: PassportFrame.Kind, text: String) {
        send(kind, Data(text.utf8))
    }
}

/// How audio is encoded on the wire.
enum PassportAudioEncoding: String, Sendable {
    /// Raw 16 kHz mono Int16, one recognition chunk per frame. Used over USB,
    /// where bandwidth is free.
    case pcm
    /// IMA ADPCM 4:1, 804-byte blocks. Used over BLE, where 256 kbps of raw PCM
    /// would sit right at the edge of what the radio sustains.
    case imaADPCM = "ima_adpcm"

    /// Parse the `audio` field of a `voice.start` event.
    init?(wireName: String) {
        switch wireName {
        case "pcm": self = .pcm
        case "ima_adpcm": self = .imaADPCM
        default: return nil
        }
    }
}
