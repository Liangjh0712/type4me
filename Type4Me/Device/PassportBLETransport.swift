import CoreBluetooth
import Foundation
import os

/// The wireless link to an AI Passport device.
///
/// Same protocol as the wired link, three differences that matter:
///
/// Audio is IMA ADPCM in fragmented blocks rather than raw PCM frames, because
/// 256 kbps of PCM sits right at the edge of what this radio sustains. Reassembly
/// and decoding happen in `PassportADPCMReassembler`.
///
/// Event lines are not framed by a characteristic write, so a JSON line can span
/// notifications and several can arrive in one. They are accumulated and split on
/// newlines.
///
/// The device treats "subscribed to EVENT" as the definition of being online, and
/// refuses to record until then — so subscribing is not optional bookkeeping.
final class PassportBLETransport: NSObject, PassportTransport, @unchecked Sendable {

    /// The device advertises this name. Its service UUID is in the scan response
    /// rather than the advertisement — flags plus a full name plus a 128-bit UUID
    /// exceed the 31-byte advertising payload — so scanning *by service* finds
    /// nothing and we filter on the name instead.
    static let advertisedName = "AI Passport"

    /// Declared as 16-bit UUIDs nested in a 128-bit service, which is how they
    /// surface on macOS. Building the full 128-bit form byte-order-reversed is an
    /// easy way to match nothing at all.
    static let serviceUUID = CBUUID(string: "A2B0")
    static let controlUUID = CBUUID(string: "A2B1")
    static let eventUUID = CBUUID(string: "A2B2")
    static let audioUUID = CBUUID(string: "A2B3")

    /// ADPCM over the air.
    let audioEncoding: PassportAudioEncoding = .imaADPCM

    var displayName: String { peripheralName ?? Self.advertisedName }

    var onFrame: ((PassportFrame.Message) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    var onReady: (() -> Void)? {
        get { lock.withLock { _onReady } }
        set { lock.withLock { _onReady = newValue } }
    }

    var onDisconnect: (() -> Void)? {
        get { lock.withLock { _onDisconnect } }
        set { lock.withLock { _onDisconnect = newValue } }
    }

    private let logger = Logger(subsystem: "com.type4me.device", category: "PassportBLETransport")
    private let lock = NSLock()
    private var _onFrame: ((PassportFrame.Message) -> Void)?
    private var _onReady: (() -> Void)?
    private var _onDisconnect: (() -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var peripheralName: String?
    private var controlCharacteristic: CBCharacteristic?
    private var isSubscribedToEvents = false
    private var didNotifyDisconnect = false
    private var isClosing = false

    private let queue = DispatchQueue(label: "com.type4me.device.ble", qos: .userInitiated)
    private var reassembler = PassportADPCMReassembler()
    /// Partial event line carried across notifications.
    private var eventBuffer = Data()
    /// Guards against unbounded growth if newlines stop arriving.
    private static let eventBufferCap = 4096

    private var audioFramesDelivered = 0

    override init() {
        super.init()
    }

    // MARK: - Lifecycle

    func open() throws {
        lock.withLock {
            isClosing = false
            didNotifyDisconnect = false
            reassembler.reset()
            eventBuffer = Data()
            audioFramesDelivered = 0
        }
        // Creating the manager triggers the authorization prompt on first use and
        // reports readiness through the delegate; scanning starts from there.
        central = CBCentralManager(delegate: self, queue: queue)
        DebugFileLogger.log("passport ble open")
    }

    func close() {
        let shouldTeardown: Bool = lock.withLock {
            guard !isClosing else { return false }
            isClosing = true
            return true
        }
        guard shouldTeardown else { return }

        if let central, let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central?.stopScan()
        central = nil
        DebugFileLogger.log("passport ble closed audioFrames=\(audioFramesDelivered)")
        notifyDisconnectOnce()
    }

    private func notifyDisconnectOnce() {
        let handler: (() -> Void)? = lock.withLock {
            guard !didNotifyDisconnect else { return nil }
            didNotifyDisconnect = true
            return _onDisconnect
        }
        handler?()
    }

    // MARK: - Writing

    func send(_ kind: PassportFrame.Kind, _ payload: Data) {
        // BLE carries the protocol on characteristics, so control lines go out raw —
        // the binary framing exists only because USB is a bare byte stream.
        guard kind == .control else {
            logger.debug("ignoring \(kind.rawValue) on BLE (wired-only channel)")
            return
        }
        guard let peripheral, let controlCharacteristic else { return }

        // Without a response: waiting for the ATT acknowledgement costs a round trip
        // each time, and a dropped control line is never retried anyway.
        peripheral.writeValue(payload, for: controlCharacteristic, type: .withoutResponse)
    }

    // MARK: - Inbound

    /// Drop any half-assembled block: the device resets its ADPCM encoder per
    /// session, so a fragment left over from the previous recording would decode
    /// against the wrong predictor.
    ///
    /// Hops to the delegate queue, which is the only place `reassembler` is touched.
    func beginSession() {
        queue.async { [weak self] in
            self?.reassembler.reset()
        }
    }

    private func handleAudio(_ payload: Data) {
        let frames = reassembler.accept(payload)
        guard !frames.isEmpty else { return }

        let handler = lock.withLock { _onFrame }
        for pcm in frames {
            audioFramesDelivered += 1
            if audioFramesDelivered % 50 == 0 {
                DebugFileLogger.log(
                    "passport ble audio frames=\(audioFramesDelivered) missed=\(reassembler.missedBlocks)")
            }
            // Republished as an audio frame so the link layer above cannot tell the
            // transports apart.
            handler?(PassportFrame.Message(kind: .audio, payload: pcm))
        }
    }

    private func handleEvent(_ payload: Data) {
        eventBuffer.append(payload)
        if eventBuffer.count > Self.eventBufferCap {
            logger.warning("event buffer overflow, resyncing")
            DebugFileLogger.log("passport ble event buffer overflow bytes=\(eventBuffer.count)")
            eventBuffer = Data()
            return
        }

        let handler = lock.withLock { _onFrame }
        while let newline = eventBuffer.firstIndex(of: 0x0A) {
            let line = eventBuffer[eventBuffer.startIndex...newline]
            eventBuffer = Data(eventBuffer[(newline + 1)...])
            handler?(PassportFrame.Message(kind: .event, payload: Data(line)))
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension PassportBLETransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        switch manager.state {
        case .poweredOn:
            // Scanning by service UUID finds nothing: the UUID lives in the scan
            // response, not the advertisement.
            manager.scanForPeripherals(withServices: nil)
            DebugFileLogger.log("passport ble scanning")
        case .unauthorized:
            logger.warning("Bluetooth permission denied")
            DebugFileLogger.log("passport ble unauthorized")
            notifyDisconnectOnce()
        case .poweredOff:
            DebugFileLogger.log("passport ble powered off")
            notifyDisconnectOnce()
        default:
            break
        }
    }

    func centralManager(
        _ manager: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard name == Self.advertisedName else {
            // Log a near-miss once: a renamed or reflashed device is otherwise
            // indistinguishable from one that is simply absent.
            if let name, name.lowercased().contains("passport") || name.lowercased().contains("folo") {
                DebugFileLogger.log("passport ble saw similar name=\(name) rssi=\(rssi.intValue)")
            }
            return
        }

        manager.stopScan()
        self.peripheral = peripheral
        self.peripheralName = name
        peripheral.delegate = self
        manager.connect(peripheral)
        DebugFileLogger.log("passport ble found rssi=\(rssi.intValue)")
    }

    func centralManager(_ manager: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.serviceUUID])
        DebugFileLogger.log("passport ble connected")
    }

    func centralManager(
        _ manager: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        logger.warning("connect failed: \(error?.localizedDescription ?? "unknown", privacy: .public)")
        DebugFileLogger.log("passport ble connect failed error=\(error?.localizedDescription ?? "-")")
        notifyDisconnectOnce()
    }

    func centralManager(
        _ manager: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        isSubscribedToEvents = false
        controlCharacteristic = nil
        DebugFileLogger.log("passport ble disconnected error=\(error?.localizedDescription ?? "clean")")
        notifyDisconnectOnce()
    }
}

// MARK: - CBPeripheralDelegate

extension PassportBLETransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            logger.warning("audio service not found")
            DebugFileLogger.log("passport ble service missing")
            close()
            return
        }
        peripheral.discoverCharacteristics(
            [Self.controlUUID, Self.eventUUID, Self.audioUUID], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case Self.controlUUID:
                controlCharacteristic = characteristic
            case Self.eventUUID, Self.audioUUID:
                // Subscribing is what makes the device consider itself online; until
                // the EVENT CCCD is written it shows OFFLINE and blocks recording.
                // The characteristics require encryption, so this write is also what
                // prompts macOS to pair (Just Works, no PIN).
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        DebugFileLogger.log(
            "passport ble characteristics mtu=\(peripheral.maximumWriteValueLength(for: .withoutResponse))")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            logger.warning("subscribe failed \(characteristic.uuid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            DebugFileLogger.log("passport ble subscribe failed uuid=\(characteristic.uuid) error=\(error.localizedDescription)")
            return
        }
        if characteristic.uuid == Self.eventUUID, characteristic.isNotifying {
            isSubscribedToEvents = true
            DebugFileLogger.log("passport ble event subscribed")
            // The device counts itself online from this moment, and it sends nothing
            // unprompted — so this, not a first frame, is when the link is usable.
            lock.withLock { _onReady }?()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        switch characteristic.uuid {
        case Self.audioUUID:
            handleAudio(value)
        case Self.eventUUID:
            handleEvent(value)
        default:
            break
        }
    }
}
