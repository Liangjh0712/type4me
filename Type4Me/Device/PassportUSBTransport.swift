import Foundation
import os

/// The wired link to an AI Passport device.
///
/// Opens the board's USB Serial/JTAG callout device, decodes the binary frame
/// stream on a dedicated queue, and writes host→device frames under a lock so
/// concurrent control and console sends cannot interleave mid-frame.
///
/// Two device behaviours shape this:
///
/// The link needs a handshake — the host sends SYS `ping` and the device answers
/// SYS_RESP `pong` followed by a `device.hello` event. Until then the device shows
/// itself as offline and refuses to record.
///
/// The read loop must never stall. The firmware abandons its USB session after ten
/// consecutive failed writes, which is about one second of the host not draining,
/// so the reader runs on its own queue and does nothing but decode and forward.
final class PassportUSBTransport: PassportTransport, @unchecked Sendable {

    /// Raw PCM: the wire is fast enough that the device skips compression here.
    let audioEncoding: PassportAudioEncoding = .pcm

    var displayName: String { port.path }

    var onFrame: ((PassportFrame.Message) -> Void)? {
        get { stateLock.withLock { _onFrame } }
        set { stateLock.withLock { _onFrame = newValue } }
    }

    var onDisconnect: (() -> Void)? {
        get { stateLock.withLock { _onDisconnect } }
        set { stateLock.withLock { _onDisconnect = newValue } }
    }

    private let port: PassportSerialDiscovery.Port
    private let logger = Logger(subsystem: "com.type4me.device", category: "PassportUSBTransport")

    private let stateLock = NSLock()
    private var _onFrame: ((PassportFrame.Message) -> Void)?
    private var _onDisconnect: (() -> Void)?
    private var fileDescriptor: Int32 = -1
    private var isClosing = false
    private var didNotifyDisconnect = false

    private let writeLock = NSLock()
    private let readQueue = DispatchQueue(label: "com.type4me.device.usb-read", qos: .userInitiated)
    private var decoder = PassportFrameDecoder()

    private var framesReceived = 0
    private var audioFramesReceived = 0

    init(port: PassportSerialDiscovery.Port) {
        self.port = port
    }

    deinit {
        closeDescriptor()
    }

    // MARK: - Lifecycle

    func open() throws {
        try stateLock.withLock {
            guard fileDescriptor < 0 else { return }

            // O_NONBLOCK so open() returns immediately; the reader then blocks on
            // read() via a cleared O_NONBLOCK below. O_NOCTTY keeps the port from
            // becoming our controlling terminal.
            let fd = Darwin.open(port.path, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else {
                throw PassportLinkError.portUnavailable(path: port.path, errno: errno)
            }

            // Exclusive: two clients on one port interleave reads and both fail.
            guard ioctl(fd, TIOCEXCL) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw PassportLinkError.portBusy(path: port.path, errno: code)
            }

            // Block in read() rather than spin. VMIN/VTIME give us a short timeout
            // so the loop can notice `isClosing` promptly.
            _ = fcntl(fd, F_SETFL, 0)

            var options = termios()
            guard tcgetattr(fd, &options) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw PassportLinkError.portUnavailable(path: port.path, errno: code)
            }
            cfmakeraw(&options)
            // Block in read() until at least one byte, or 0.1s elapses — the
            // timeout is what lets the loop notice `isClosing` promptly.
            withUnsafeMutableBytes(of: &options.c_cc) { raw in
                raw[Int(VMIN)] = 0
                raw[Int(VTIME)] = 1
            }
            // USB Serial/JTAG is not a real UART, so the baud rate is ignored. Set
            // a conventional value anyway for tools that read the port settings.
            cfsetspeed(&options, speed_t(B115200))
            guard tcsetattr(fd, TCSANOW, &options) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw PassportLinkError.portUnavailable(path: port.path, errno: code)
            }

            fileDescriptor = fd
            isClosing = false
            didNotifyDisconnect = false
            decoder = PassportFrameDecoder()
            framesReceived = 0
            audioFramesReceived = 0
        }

        logger.info("opened \(self.port.path, privacy: .public)")
        DebugFileLogger.log("passport usb open path=\(port.path) serial=\(port.serialNumber ?? "-")")

        readQueue.async { [weak self] in self?.readLoop() }
        handshake()
    }

    func close() {
        let shouldNotify: Bool = stateLock.withLock {
            guard fileDescriptor >= 0, !isClosing else { return false }
            isClosing = true
            return true
        }
        guard shouldNotify else { return }

        // Tell the device the session is ending so it can drop back to offline
        // instead of waiting for its write failures to pile up.
        send(.sys, text: "bye")

        closeDescriptor()
        DebugFileLogger.log(
            "passport usb closed frames=\(framesReceived) audioFrames=\(audioFramesReceived)")
        notifyDisconnectOnce()
    }

    private func closeDescriptor() {
        let fd: Int32 = stateLock.withLock {
            let current = fileDescriptor
            fileDescriptor = -1
            return current
        }
        if fd >= 0 {
            Darwin.close(fd)
        }
    }

    private func notifyDisconnectOnce() {
        let handler: (() -> Void)? = stateLock.withLock {
            guard !didNotifyDisconnect else { return nil }
            didNotifyDisconnect = true
            return _onDisconnect
        }
        handler?()
    }

    // MARK: - Handshake

    /// SYS `ping` → SYS_RESP `pong` + `device.hello`. Sent fire-and-forget: the
    /// session layer decides what to do when `device.hello` does or does not land.
    private func handshake() {
        send(.sys, text: "ping")
    }

    // MARK: - Writing

    func send(_ kind: PassportFrame.Kind, _ payload: Data) {
        let frame = PassportFrame.encode(kind, payload)
        let fd = stateLock.withLock { fileDescriptor }
        guard fd >= 0 else { return }

        // Serialize whole frames: two concurrent partial writes would splice into
        // one unparseable frame on the device side.
        writeLock.lock()
        defer { writeLock.unlock() }

        var offset = 0
        frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < frame.count {
                let written = Darwin.write(fd, base.advanced(by: offset), frame.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && (errno == EINTR || errno == EAGAIN) {
                    continue
                }
                break
            }
        }

        if offset < frame.count {
            // Downlink is never retried — the protocol treats a lost control frame
            // as lost. Log it so a systematically failing link is visible.
            logger.warning("short write kind=\(kind.rawValue) sent=\(offset) of \(frame.count)")
            DebugFileLogger.log("passport usb short write kind=\(kind) sent=\(offset)/\(frame.count)")
        }
    }

    // MARK: - Reading

    private func readLoop() {
        var scratch = [UInt8](repeating: 0, count: 8192)

        while true {
            let fd = stateLock.withLock { isClosing ? -1 : fileDescriptor }
            guard fd >= 0 else { break }

            let count = scratch.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.read(fd, base, raw.count)
            }

            if count > 0 {
                dispatch(Data(scratch[0..<count]))
                continue
            }

            if count == 0 {
                // VTIME expiry, not end of stream: a serial fd stays readable.
                continue
            }

            if errno == EINTR || errno == EAGAIN {
                continue
            }

            // Unplugged, or the device dropped its session.
            let wasClosing = stateLock.withLock { isClosing }
            if !wasClosing {
                logger.info("read ended errno=\(errno)")
                DebugFileLogger.log("passport usb read ended errno=\(errno) frames=\(self.framesReceived)")
            }
            break
        }

        closeDescriptor()
        notifyDisconnectOnce()
    }

    private func dispatch(_ bytes: Data) {
        let frames = decoder.decode(bytes) { [weak self] error in
            guard let self else { return }
            self.logger.warning("frame error \(String(describing: error), privacy: .public)")
            DebugFileLogger.log("passport usb frame error=\(error)")
        }
        guard !frames.isEmpty else { return }

        let handler = stateLock.withLock { _onFrame }
        for frame in frames {
            framesReceived += 1
            if frame.kind == .audio {
                audioFramesReceived += 1
                // ~every 5s of audio, matching the capture engine's heartbeat rate.
                if audioFramesReceived % 50 == 0 {
                    DebugFileLogger.log(
                        "passport usb audio frames=\(audioFramesReceived) bytes=\(frame.payload.count)")
                }
            }
            handler?(frame)
        }
    }
}

/// Why a device link could not be established.
enum PassportLinkError: Error, LocalizedError, Sendable {
    case noDeviceFound
    case portUnavailable(path: String, errno: Int32)
    case portBusy(path: String, errno: Int32)

    var errorDescription: String? {
        switch self {
        case .noDeviceFound:
            return L("未找到设备", "No device found")
        case .portUnavailable(let path, let code):
            return L(
                "无法打开设备端口 \(path)（错误 \(code)）",
                "Cannot open device port \(path) (error \(code))")
        case .portBusy(let path, _):
            return L(
                "设备端口 \(path) 已被其他程序占用",
                "Device port \(path) is in use by another program")
        }
    }
}
