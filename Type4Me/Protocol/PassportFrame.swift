import Foundation

/// Binary framing for the wired link to an AI Passport device.
///
/// USB Serial/JTAG is a bare byte stream — no GATT characteristics to separate
/// messages — so both ends wrap everything in one frame layout:
///
/// ```
/// [0xA5][0x5A][type:1][len:2 LE][payload][checksum:1]      total = 6 + len
/// ```
///
/// The checksum makes the whole frame sum to zero mod 256. Kept byte-for-byte
/// identical to the firmware's `main/usb_link_framing.c` and the reference
/// client's `companion/serial_frame.py`, which share one set of test vectors.
enum PassportFrame {

    static let magic0: UInt8 = 0xA5
    static let magic1: UInt8 = 0x5A
    /// magic(2) + type(1) + len(2) + checksum(1)
    static let overhead = 6

    /// Frame types. Direction is part of the contract: a host only ever receives
    /// `event`/`audio`/`sysResponse` and only ever sends `control`/`sys`.
    enum Kind: UInt8, Sendable, CaseIterable {
        /// Device → host: one JSON event line (includes its trailing newline).
        case event = 0x01
        /// Device → host: 3200 bytes of raw 16 kHz mono Int16 PCM.
        case audio = 0x02
        /// Host → device: protocol JSON (no trailing newline).
        case control = 0x03
        /// Host → device: console command text.
        case sys = 0x04
        /// Device → host: console command output.
        case sysResponse = 0x05

        /// Per-type payload ceiling, mirroring the firmware's `type_max_payload`.
        var maxPayload: Int {
            switch self {
            case .event: return 512
            case .audio: return 3200
            case .control: return 2048
            case .sys: return 128
            case .sysResponse: return 2048
            }
        }

        /// Whether a host may receive this type. Checked before any payload byte
        /// is buffered, so a stray downlink type cannot drive an oversized read.
        var isInbound: Bool {
            switch self {
            case .event, .audio, .sysResponse: return true
            case .control, .sys: return false
            }
        }
    }

    /// A decoded frame.
    struct Message: Sendable, Equatable {
        let kind: Kind
        let payload: Data
    }

    /// Why a byte was rejected. Surfaced for diagnostics; decoding always
    /// recovers and keeps going.
    enum DecodeError: Error, Sendable, Equatable {
        /// Type byte outside 0x01...0x05, or one this side must not receive.
        case badType(UInt8)
        /// Declared length exceeds the type's ceiling.
        case oversize(kind: Kind, length: Int)
        /// Frame contents did not sum to zero.
        case checksumMismatch
    }

    /// Build a frame for transmission.
    static func encode(_ kind: Kind, _ payload: Data) -> Data {
        var frame = Data(capacity: overhead + payload.count)
        frame.append(magic0)
        frame.append(magic1)
        frame.append(kind.rawValue)
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(UInt8((payload.count >> 8) & 0xFF))
        frame.append(payload)
        let sum = frame.reduce(0) { ($0 + Int($1)) & 0xFF }
        frame.append(UInt8((256 - sum) & 0xFF))
        return frame
    }

    /// Convenience for the two host→device text channels.
    static func encode(_ kind: Kind, text: String) -> Data {
        encode(kind, Data(text.utf8))
    }
}

/// Incremental decoder for the wired frame stream.
///
/// A serial read returns an arbitrary slice of the stream: frames split across
/// reads, several frames arrive at once, and boot-time log noise shows up between
/// them. So this is a byte-at-a-time state machine rather than a buffer scan —
/// and on any illegal byte it re-scans from that same byte instead of discarding
/// it, which is what keeps a sequence like `A5 A5 5A` from swallowing the frame
/// that actually starts at the second `A5`.
///
/// A value type with no I/O, so it can be unit-tested against the shared vectors.
struct PassportFrameDecoder {

    private enum State {
        case magic0
        case magic1
        case type
        case lengthLow
        case lengthHigh
        case payload
        case checksum
    }

    /// What the decoder produced for one fed byte.
    enum Outcome: Sendable, Equatable {
        /// Byte consumed, frame still incomplete.
        case pending
        case frame(PassportFrame.Message)
        case failure(PassportFrame.DecodeError)
    }

    private var state: State = .magic0
    private var sum: Int = 0
    private var kind: PassportFrame.Kind = .event
    private var declaredLength = 0
    private var payload = Data()

    init() {}

    /// Feed a read's worth of bytes and collect every complete frame.
    ///
    /// Errors are reported through `onError` rather than thrown: a corrupt frame
    /// costs its own bytes and nothing more, and the caller must keep reading.
    mutating func decode(_ bytes: Data, onError: ((PassportFrame.DecodeError) -> Void)? = nil) -> [PassportFrame.Message] {
        var frames: [PassportFrame.Message] = []
        for byte in bytes {
            switch feed(byte) {
            case .pending:
                continue
            case .frame(let message):
                frames.append(message)
            case .failure(let error):
                onError?(error)
            }
        }
        return frames
    }

    /// Advance the state machine by one byte.
    mutating func feed(_ byte: UInt8) -> Outcome {
        switch state {
        case .magic0:
            if byte == PassportFrame.magic0 {
                state = .magic1
                sum = Int(PassportFrame.magic0)
            }
            return .pending

        case .magic1:
            if byte == PassportFrame.magic1 {
                state = .type
                sum += Int(PassportFrame.magic1)
            } else {
                // `A5 A5 5A`: the second 0xA5 becomes the new frame start.
                rescan(from: byte)
            }
            return .pending

        case .type:
            // Direction is filtered before length, so an outbound-only type can
            // never reach the payload state and size the buffer.
            guard let decoded = PassportFrame.Kind(rawValue: byte), decoded.isInbound else {
                rescan(from: byte)
                return .failure(.badType(byte))
            }
            kind = decoded
            sum += Int(byte)
            state = .lengthLow
            return .pending

        case .lengthLow:
            declaredLength = Int(byte)
            sum += Int(byte)
            state = .lengthHigh
            return .pending

        case .lengthHigh:
            declaredLength |= Int(byte) << 8
            sum += Int(byte)
            guard declaredLength <= kind.maxPayload else {
                let length = declaredLength
                rescan(from: byte)
                return .failure(.oversize(kind: kind, length: length))
            }
            payload = Data(capacity: declaredLength)
            state = declaredLength == 0 ? .checksum : .payload
            return .pending

        case .payload:
            payload.append(byte)
            sum += Int(byte)
            if payload.count == declaredLength {
                state = .checksum
            }
            return .pending

        case .checksum:
            guard (sum + Int(byte)) & 0xFF == 0 else {
                rescan(from: byte)
                return .failure(.checksumMismatch)
            }
            let message = PassportFrame.Message(kind: kind, payload: payload)
            rescan(from: 0)
            return .frame(message)
        }
    }

    /// Restart scanning, re-considering `byte` as a possible frame start.
    private mutating func rescan(from byte: UInt8) {
        payload = Data()
        declaredLength = 0
        if byte == PassportFrame.magic0 {
            state = .magic1
            sum = Int(PassportFrame.magic0)
        } else {
            state = .magic0
            sum = 0
        }
    }
}
