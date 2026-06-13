//
//  MeshCoreBLETransport.swift
//  OmniTAK Mobile
//
//  CoreBluetooth link to a MeshCore *companion* radio over the Nordic UART
//  service. Scans for the NUS service, connects (iOS handles passkey pairing —
//  the 6-digit code is shown on the node's OLED, or 123456 on screenless
//  builds), discovers the RX (write) / TX (notify) characteristics, subscribes
//  to TX notifications, and writes command frames to RX.
//
//  Framing is delegated to MeshCoreFrameCodec; this class is the byte pipe plus
//  a small write queue (the radio expects one outstanding write at a time, like
//  the ATAK plugin's drainWriteQueue). Decoded-frame routing and the companion
//  state machine live in MeshCoreManager.
//
//  Pattern intentionally mirrors MeshtasticBLEClient so the two transports read
//  the same and share the app's BLE conventions.
//

import Foundation
import CoreBluetooth
import Combine

// MARK: - MeshCore BLE UUIDs

enum MeshCoreBLEUUID {
    /// Nordic UART service advertised by MeshCore companion firmware.
    static let service  = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    /// RX characteristic — the app WRITES command frames here.
    static let rx       = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    /// TX characteristic — the app receives response frames via NOTIFY here.
    static let tx       = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    /// Firmware BLE name prefix (BLE_NAME_PREFIX). Used only as a soft hint —
    /// the service UUID is the authoritative filter.
    static let namePrefix = "MeshCore-"
    /// Default BLE PIN on screenless builds (firmware BLE_PIN_CODE).
    static let defaultPairingPin = 123456
}

// MARK: - MeshCoreBLETransport

@available(iOS 13.0, *)
final class MeshCoreBLETransport: NSObject, ObservableObject, MeshTransport {

    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case scanning     = "Scanning..."
        case connecting   = "Connecting..."
        case discovering  = "Discovering Services..."
        case connected    = "Connected"
        case failed       = "Connection Failed"
    }

    // MARK: Published state

    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var discoveredDevices: [DiscoveredBLEDevice] = []
    @Published var knownDevices: [DiscoveredBLEDevice] = []
    @Published var needsBluetoothRepair: Bool = false
    @Published var connectedPeripheral: CBPeripheral?
    @Published var lastError: String?

    /// MeshTransport requirements (companion path: node table + own node id are
    /// owned by MeshCoreManager, so the transport leaves these empty/zero).
    @Published var nodes: [UInt32: MeshNode] = [:]
    var myNodeNum: UInt32 = 0

    // MARK: Callbacks (wired by MeshCoreManager)

    /// Fired (on main) with each decoded response frame from the radio.
    var onFrame: ((Data) -> Void)?
    /// Fired (on main) right after the TX notify subscription is live — the
    /// manager kicks off the APP_START handshake here.
    var onReady: (() -> Void)?
    /// Fired (on main) when the link drops.
    var onDisconnect: (() -> Void)?

    // MARK: Private

    private var centralManager: CBCentralManager!
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?
    private var pendingPeripheral: CBPeripheral?
    private var isShuttingDown = false
    private var userDidDisconnect = false

    private let knownDevicesKey = "meshcore_known_ble_devices"

    /// One-write-at-a-time queue (the radio drops overlapping writes).
    private var writeQueue: [Data] = []
    private var writeInFlight = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    deinit {
        isShuttingDown = true
    }

    // MARK: Scanning

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            DispatchQueue.main.async { self.lastError = "Bluetooth is not available" }
            return
        }
        DispatchQueue.main.async {
            self.discoveredDevices.removeAll()
            self.isScanning = true
            self.connectionState = .scanning
        }
        // Filter strictly on the Nordic UART service — the authoritative
        // MeshCore-companion signal. A Meshtastic Heltec won't match.
        centralManager.scanForPeripherals(
            withServices: [MeshCoreBLEUUID.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        print("MeshCore: started scanning (Nordic UART service)")
    }

    func stopScanning() {
        centralManager.stopScan()
        DispatchQueue.main.async {
            self.isScanning = false
            if !self.isConnected { self.connectionState = .disconnected }
        }
    }

    // MARK: Connection

    func connect(to device: DiscoveredBLEDevice) {
        stopScanning()
        userDidDisconnect = false
        pendingPeripheral = device.peripheral
        DispatchQueue.main.async {
            self.needsBluetoothRepair = false
            self.connectionState = .connecting
            self.lastError = nil
        }
        centralManager.connect(device.peripheral, options: nil)
        print("MeshCore: connecting to \(device.name)…")
    }

    func connect(peripheral: CBPeripheral) {
        stopScanning()
        pendingPeripheral = peripheral
        DispatchQueue.main.async {
            self.connectionState = .connecting
            self.lastError = nil
        }
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard !isShuttingDown else { return }
        userDidDisconnect = true
        clearWriteQueue()
        if let p = connectedPeripheral {
            centralManager.cancelPeripheralConnection(p)
        } else if let p = pendingPeripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isShuttingDown else { return }
            self.isConnected = false
            self.connectionState = .disconnected
            self.connectedPeripheral = nil
            self.rxCharacteristic = nil
            self.txCharacteristic = nil
        }
        pendingPeripheral = nil
        print("MeshCore: disconnected")
    }

    // MARK: Writing

    /// Queue a command frame for the RX characteristic. Frames are sent one at a
    /// time; the next is written after `didWriteValueFor` (mirrors the plugin's
    /// drainWriteQueue and avoids dropped writes on the radio).
    func send(_ frame: Data) {
        guard !frame.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.writeQueue.append(frame)
            self.drainWriteQueue()
        }
    }

    private func drainWriteQueue() {
        guard !writeInFlight else { return }
        guard let peripheral = connectedPeripheral,
              let rx = rxCharacteristic,
              peripheral.state == .connected,
              !writeQueue.isEmpty else { return }
        let frame = writeQueue.removeFirst()
        writeInFlight = true
        // RX is "write without response" on MeshCore; fall back to withResponse
        // only if the characteristic doesn't advertise WWR.
        let writeType: CBCharacteristicWriteType =
            rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(frame, for: rx, type: writeType)
        if writeType == .withoutResponse {
            // WWR: pace via peripheralIsReady(toSendWriteWithoutResponse:) so the
            // radio's UART buffer isn't overrun under burst writes.  Release the
            // in-flight latch now only when the peripheral reports it's ready;
            // if canSendWriteWithoutResponse is already true we drain immediately
            // (avoids deadlock on the very first frame).
            writeInFlight = false
            if !writeQueue.isEmpty {
                if peripheral.canSendWriteWithoutResponse {
                    drainWriteQueue()
                }
                // else: peripheralIsReady(toSendWriteWithoutResponse:) will call drainWriteQueue()
            }
        }
    }

    private func clearWriteQueue() {
        writeQueue.removeAll()
        writeInFlight = false
    }

    // MARK: Known / paired devices

    private struct KnownDevice: Codable { let uuid: String; let name: String }

    private func loadKnownDeviceRecords() -> [KnownDevice] {
        guard let data = UserDefaults.standard.data(forKey: knownDevicesKey),
              let list = try? JSONDecoder().decode([KnownDevice].self, from: data) else { return [] }
        return list
    }

    private func rememberDevice(_ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        var list = loadKnownDeviceRecords().filter { $0.uuid != uuid }
        list.insert(KnownDevice(uuid: uuid, name: peripheral.name ?? "MeshCore"), at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: knownDevicesKey)
        }
    }

    func forgetDevice(id: UUID) {
        let list = loadKnownDeviceRecords().filter { $0.uuid != id.uuidString }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: knownDevicesKey)
        }
        DispatchQueue.main.async { self.knownDevices.removeAll { $0.id == id } }
    }

    func refreshKnownDevices() {
        guard centralManager?.state == .poweredOn else { return }
        var result: [DiscoveredBLEDevice] = []
        var seen = Set<UUID>()
        let records = loadKnownDeviceRecords()
        let uuids = records.compactMap { UUID(uuidString: $0.uuid) }
        if !uuids.isEmpty {
            for p in centralManager.retrievePeripherals(withIdentifiers: uuids) where !seen.contains(p.identifier) {
                seen.insert(p.identifier)
                let stored = records.first { $0.uuid == p.identifier.uuidString }?.name
                result.append(DiscoveredBLEDevice(id: p.identifier, name: p.name ?? stored ?? "MeshCore", rssi: 0, peripheral: p))
            }
        }
        for p in centralManager.retrieveConnectedPeripherals(withServices: [MeshCoreBLEUUID.service])
        where !seen.contains(p.identifier) {
            seen.insert(p.identifier)
            result.append(DiscoveredBLEDevice(id: p.identifier, name: p.name ?? "MeshCore", rssi: 0, peripheral: p))
        }
        DispatchQueue.main.async { self.knownDevices = result }
    }

    @discardableResult
    func reconnectLastDevice() -> Bool {
        guard centralManager?.state == .poweredOn, !isConnected, !userDidDisconnect else { return false }
        let records = loadKnownDeviceRecords()
        guard let last = records.first, let uuid = UUID(uuidString: last.uuid),
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else { return false }
        print("MeshCore: auto-reconnecting to \(peripheral.name ?? last.name)")
        connect(peripheral: peripheral)
        return true
    }
}

// MARK: - CBCentralManagerDelegate

@available(iOS 13.0, *)
extension MeshCoreBLETransport: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async { self.bluetoothState = central.state }
        switch central.state {
        case .poweredOn:
            refreshKnownDevices()
            reconnectLastDevice()
        case .poweredOff:
            DispatchQueue.main.async {
                self.lastError = "Bluetooth is turned off"
                self.isConnected = false
                self.connectionState = .disconnected
            }
        case .unauthorized:
            DispatchQueue.main.async { self.lastError = "Bluetooth permission not granted" }
        case .unsupported:
            DispatchQueue.main.async { self.lastError = "Bluetooth is not supported on this device" }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
            ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? "MeshCore Node"
        let device = DiscoveredBLEDevice(id: peripheral.identifier, name: name,
                                         rssi: RSSI.intValue, peripheral: peripheral)
        DispatchQueue.main.async {
            if let i = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[i] = device
            } else {
                self.discoveredDevices.append(device)
            }
        }
        print("MeshCore: discovered \(name) (RSSI \(RSSI))")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            self.connectionState = .discovering
            self.connectedPeripheral = peripheral
        }
        peripheral.delegate = self
        peripheral.discoverServices([MeshCoreBLEUUID.service])
    }

    private func isPairingError(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        if error.domain == CBErrorDomain,
           error.code == CBError.Code.peerRemovedPairingInformation.rawValue { return true }
        return error.localizedDescription.lowercased().contains("pairing")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let pairing = isPairingError(error)
        if pairing { userDidDisconnect = true }
        DispatchQueue.main.async {
            self.connectionState = .failed
            self.needsBluetoothRepair = pairing
            self.lastError = pairing
                ? "Bluetooth pairing is out of sync. In iOS Settings → Bluetooth, tap your MeshCore device, choose “Forget This Device,” then reconnect here."
                : (error?.localizedDescription ?? "Failed to connect")
        }
        print("MeshCore: failed to connect: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        clearWriteQueue()
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionState = .disconnected
            self.connectedPeripheral = nil
            self.rxCharacteristic = nil
            self.txCharacteristic = nil
            self.onDisconnect?()
        }
        print("MeshCore: disconnected from \(peripheral.name ?? "device")")
    }
}

// MARK: - CBPeripheralDelegate

@available(iOS 13.0, *)
extension MeshCoreBLETransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            DispatchQueue.main.async { self.lastError = "Service discovery failed: \(error.localizedDescription)" }
            return
        }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == MeshCoreBLEUUID.service {
            peripheral.discoverCharacteristics([MeshCoreBLEUUID.rx, MeshCoreBLEUUID.tx], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            DispatchQueue.main.async { self.lastError = "Characteristic discovery failed: \(error.localizedDescription)" }
            return
        }
        guard let characteristics = service.characteristics else { return }
        for ch in characteristics {
            switch ch.uuid {
            case MeshCoreBLEUUID.rx: rxCharacteristic = ch
            case MeshCoreBLEUUID.tx: txCharacteristic = ch
            default: break
            }
        }
        guard let tx = txCharacteristic, rxCharacteristic != nil else {
            DispatchQueue.main.async {
                self.lastError = "MeshCore RX/TX characteristics missing"
                self.connectionState = .failed
            }
            return
        }
        // Subscribe to TX notifications; the link is "ready" once notifications
        // are enabled (see didUpdateNotificationStateFor).
        peripheral.setNotifyValue(true, for: tx)
        rememberDevice(peripheral)
        userDidDisconnect = false
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == MeshCoreBLEUUID.tx else { return }
        if let error = error {
            DispatchQueue.main.async {
                self.lastError = "Enable notifications failed: \(error.localizedDescription)"
                self.connectionState = .failed
            }
            return
        }
        guard characteristic.isNotifying else { return }
        DispatchQueue.main.async {
            self.isConnected = true
            self.connectionState = .connected
            self.needsBluetoothRepair = false
            self.onReady?()
        }
        print("MeshCore: TX notifications live — link ready")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == MeshCoreBLEUUID.tx,
              let data = characteristic.value, !data.isEmpty else { return }
        let frame = data
        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            DispatchQueue.main.async { self.lastError = "Write failed: \(error.localizedDescription)" }
        }
        // Write-with-response completed — release the latch and send the next.
        writeInFlight = false
        drainWriteQueue()
    }

    /// Called by CoreBluetooth when a WWR peripheral's TX buffer has space again.
    /// Resume draining the write queue now that the radio is ready.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        drainWriteQueue()
    }
}
