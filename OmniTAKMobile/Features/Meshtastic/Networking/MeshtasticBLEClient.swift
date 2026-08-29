//
//  MeshtasticBLEClient.swift
//  OmniTAK Mobile
//
//  CoreBluetooth client for Meshtastic device communication
//  Implements the Meshtastic BLE protocol for iOS
//

import Foundation
import CoreBluetooth
import Combine

// MARK: - Meshtastic BLE UUIDs

enum MeshtasticBLEUUID {
    // Canonical Meshtastic BLE GATT UUIDs (must match the firmware exactly,
    // same values the working Android client uses). Earlier builds had wrong
    // fromRadio/fromNum UUIDs, so the characteristics never matched on
    // discovery — the radio could never be read and the node list stayed empty.
    static let service = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    static let toRadio = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    static let fromRadio = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")
    static let fromNum = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547de15e6")
}

// MARK: - BLE Protocol Constants

private enum BLEProtocol {
    static let maxPacketSize = 512
    static let mtuSize = 512
}

// MARK: - Discovered BLE Device

public struct DiscoveredBLEDevice: Identifiable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let peripheral: CBPeripheral
    public var lastSeen: Date = Date()

    public var signalStrength: String {
        switch rssi {
        case -50...0: return "Excellent"
        case -70..<(-50): return "Good"
        case -90..<(-70): return "Fair"
        default: return "Weak"
        }
    }

    public init(id: UUID, name: String, rssi: Int, peripheral: CBPeripheral, lastSeen: Date = Date()) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.peripheral = peripheral
        self.lastSeen = lastSeen
    }
}

// MARK: - BLE Client Delegate

protocol MeshtasticBLEClientDelegate: AnyObject {
    func bleClient(_ client: MeshtasticBLEClient, didDiscover device: DiscoveredBLEDevice)
    func bleClient(_ client: MeshtasticBLEClient, didConnect peripheral: CBPeripheral)
    func bleClient(_ client: MeshtasticBLEClient, didDisconnect peripheral: CBPeripheral, error: Error?)
    func bleClient(_ client: MeshtasticBLEClient, didReceiveNodeInfo node: MeshNode)
    func bleClient(_ client: MeshtasticBLEClient, didReceivePosition nodeId: UInt32, position: MeshPosition)
    func bleClient(_ client: MeshtasticBLEClient, didReceiveMessage from: UInt32, text: String)
    func bleClient(_ client: MeshtasticBLEClient, didUpdateMyInfo nodeNum: UInt32, firmwareVersion: String)
    func bleClient(_ client: MeshtasticBLEClient, didReceiveError message: String)
    func bleClient(_ client: MeshtasticBLEClient, bluetoothStateChanged state: CBManagerState)
}

// MARK: - MeshtasticBLEClient

@available(iOS 13.0, *)
class MeshtasticBLEClient: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var isScanning: Bool = false
    @Published var isConnected: Bool = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var discoveredDevices: [DiscoveredBLEDevice] = []
    /// Previously-paired / system-known Meshtastic radios, retrieved without
    /// a scan so a known device is one tap (or an automatic reconnect) away.
    @Published var knownDevices: [DiscoveredBLEDevice] = []
    /// True when the last failure was a stale iOS bond ("peer removed pairing
    /// information"). Only the user can clear it via Settings, so the UI shows
    /// recovery steps instead of a cryptic error.
    @Published var needsBluetoothRepair: Bool = false
    @Published var connectedPeripheral: CBPeripheral?
    @Published var myNodeNum: UInt32 = 0
    @Published var firmwareVersion: String = ""
    @Published var nodes: [UInt32: MeshNode] = [:]
    @Published var lastError: String?

    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case scanning = "Scanning..."
        case connecting = "Connecting..."
        case discovering = "Discovering Services..."
        case connected = "Connected"
        case failed = "Connection Failed"
    }

    // MARK: - Properties

    weak var delegate: MeshtasticBLEClientDelegate?

    private var centralManager: CBCentralManager!
    private var toRadioCharacteristic: CBCharacteristic?
    private var fromRadioCharacteristic: CBCharacteristic?
    private var fromNumCharacteristic: CBCharacteristic?
    private var receiveBuffer = Data()
    private var pendingPeripheral: CBPeripheral?

    // Timer for periodic FromRadio reads
    private var readTimer: Timer?

    // #175 — connection watchdog. CoreBluetooth's connect() has no built-in
    // timeout: if the radio is off/out of range (common when auto-reconnecting
    // to a previously-paired device that's now gone), neither didConnect nor
    // didFailToConnect ever fires and the UI hangs forever on "Connecting…" /
    // "Discovering Services…". This timer caps the whole connect → discover
    // window; on expiry we cancel the in-flight connection and surface a
    // retryable failure instead of an indefinite spinner.
    private var connectTimeoutTimer: Timer?
    private let connectTimeoutInterval: TimeInterval = 20

    // Flag to prevent operations during shutdown
    private var isShuttingDown = false

    // Persisted set of radios we've connected to before, so we can
    // reconnect/auto-reconnect without re-scanning or re-pairing.
    private let knownDevicesKey = "meshtastic_known_ble_devices"
    // Set when the operator taps Disconnect — suppresses auto-reconnect so we
    // don't immediately reconnect to a device they just chose to leave.
    private var userDidDisconnect = false

    // Track if we're in the middle of draining the message queue
    private var isDrainingQueue = false
    private var messagesReadInBatch = 0

    // MARK: - Initialization

    override init() {
        super.init()
        // Use main queue for CBCentralManager to ensure UI updates happen on main thread
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    deinit {
        isShuttingDown = true
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil
        readTimer?.invalidate()
        readTimer = nil
        // Don't call disconnect() in deinit - it can cause crashes
        // The centralManager will be deallocated and clean up automatically
    }

    // MARK: - Scanning

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            DispatchQueue.main.async {
                self.lastError = "Bluetooth is not available"
            }
            return
        }

        DispatchQueue.main.async {
            self.discoveredDevices.removeAll()
            self.isScanning = true
            self.connectionState = .scanning
        }

        centralManager.scanForPeripherals(
            withServices: [MeshtasticBLEUUID.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        print("Started scanning for Meshtastic devices...")
    }

    func stopScanning() {
        centralManager.stopScan()
        DispatchQueue.main.async {
            self.isScanning = false
            if !self.isConnected {
                self.connectionState = .disconnected
            }
        }
        print("Stopped scanning")
    }

    // MARK: - Connection Management

    func connect(to device: DiscoveredBLEDevice) {
        stopScanning()

        // Operator chose to connect — re-enable auto-reconnect for this device
        // and clear any stale-pairing warning from a prior attempt.
        userDidDisconnect = false
        DispatchQueue.main.async { self.needsBluetoothRepair = false }
        pendingPeripheral = device.peripheral

        DispatchQueue.main.async {
            self.connectionState = .connecting
            self.lastError = nil
        }

        centralManager.connect(device.peripheral, options: nil)
        startConnectTimeout()
        print("Connecting to \(device.name)...")
    }

    func connect(peripheral: CBPeripheral) {
        stopScanning()

        pendingPeripheral = peripheral

        DispatchQueue.main.async {
            self.connectionState = .connecting
            self.lastError = nil
        }

        centralManager.connect(peripheral, options: nil)
        startConnectTimeout()
    }

    // MARK: - Connection Watchdog (#175)

    /// Arm the connect/discover watchdog. Replaces any prior timer so a retry
    /// always gets the full window. Runs on the main run loop (CB callbacks are
    /// already on .main), so it fires on the same queue that owns our state.
    private func startConnectTimeout() {
        cancelConnectTimeout()
        let timer = Timer(timeInterval: connectTimeoutInterval, repeats: false) { [weak self] _ in
            self?.handleConnectTimeout()
        }
        RunLoop.main.add(timer, forMode: .common)
        connectTimeoutTimer = timer
    }

    /// Clear the watchdog once the connection resolves (connected or failed) or
    /// the operator cancels. Safe to call when no timer is armed.
    private func cancelConnectTimeout() {
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = nil
    }

    /// Fired when connect/discover overran the budget. Tear down the in-flight
    /// attempt and surface a retryable failure so the UI escapes "Connecting…".
    private func handleConnectTimeout() {
        connectTimeoutTimer = nil
        // Already resolved (e.g. didConnect + discovery completed) — nothing to do.
        guard connectionState == .connecting || connectionState == .discovering else { return }

        print("⌛️ Meshtastic BLE connect timed out after \(Int(connectTimeoutInterval))s — cancelling")

        // Cancel whichever peripheral is in flight so CoreBluetooth stops
        // trying and frees the slot for a clean retry.
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        } else if let peripheral = pendingPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        pendingPeripheral = nil

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isConnected = false
            self.connectedPeripheral = nil
            self.connectionState = .failed
            self.lastError = "Connection timed out. Make sure the radio is powered on and nearby, then try again."
        }
    }

    func disconnect() {
        guard !isShuttingDown else { return }

        // Operator-initiated leave — don't auto-reconnect to this device.
        userDidDisconnect = true

        cancelConnectTimeout()
        readTimer?.invalidate()
        readTimer = nil

        // Cancel any pending or active connections
        if let peripheral = connectedPeripheral, centralManager != nil {
            centralManager.cancelPeripheralConnection(peripheral)
        } else if let peripheral = pendingPeripheral, centralManager != nil {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        // Reset state on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isShuttingDown else { return }
            self.isConnected = false
            self.connectionState = .disconnected
            self.connectedPeripheral = nil
            self.toRadioCharacteristic = nil
            self.fromRadioCharacteristic = nil
            self.fromNumCharacteristic = nil
            self.nodes.removeAll()
            self.myNodeNum = 0
            self.firmwareVersion = ""
        }

        pendingPeripheral = nil
        print("Disconnected from Meshtastic device")
    }

    // MARK: - Known / Paired Devices

    /// One persisted radio we've connected to before.
    private struct KnownDevice: Codable {
        let uuid: String
        let name: String
    }

    private func loadKnownDeviceRecords() -> [KnownDevice] {
        guard let data = UserDefaults.standard.data(forKey: knownDevicesKey),
              let list = try? JSONDecoder().decode([KnownDevice].self, from: data) else { return [] }
        return list
    }

    /// Remember a radio we just connected to (most-recent first, capped).
    private func rememberDevice(_ peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString
        var list = loadKnownDeviceRecords().filter { $0.uuid != uuid }
        list.insert(KnownDevice(uuid: uuid, name: peripheral.name ?? "Meshtastic"), at: 0)
        if list.count > 8 { list = Array(list.prefix(8)) }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: knownDevicesKey)
        }
    }

    /// Forget a previously-paired radio so it no longer appears under
    /// "Paired Devices" and won't be auto-reconnected.
    func forgetDevice(id: UUID) {
        let list = loadKnownDeviceRecords().filter { $0.uuid != id.uuidString }
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: knownDevicesKey)
        }
        DispatchQueue.main.async {
            self.knownDevices.removeAll { $0.id == id }
        }
    }

    /// Populate `knownDevices` from radios iOS already knows about — ones we've
    /// connected to before (`retrievePeripherals`) plus any currently connected
    /// at the system level (`retrieveConnectedPeripherals`). No scan required,
    /// so a previously-paired radio shows up instantly for one-tap reconnect.
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
                let name = p.name ?? stored ?? "Meshtastic"
                result.append(DiscoveredBLEDevice(id: p.identifier, name: name, rssi: 0, peripheral: p))
            }
        }
        for p in centralManager.retrieveConnectedPeripherals(withServices: [MeshtasticBLEUUID.service])
        where !seen.contains(p.identifier) {
            seen.insert(p.identifier)
            result.append(DiscoveredBLEDevice(id: p.identifier, name: p.name ?? "Meshtastic", rssi: 0, peripheral: p))
        }

        DispatchQueue.main.async { self.knownDevices = result }
    }

    /// Reconnect to the most-recently-used radio without scanning. Returns true
    /// if a reconnect was attempted. Skips when already connected or when the
    /// operator explicitly disconnected this session.
    @discardableResult
    func reconnectLastDevice() -> Bool {
        guard centralManager?.state == .poweredOn, !isConnected, !userDidDisconnect else { return false }
        let records = loadKnownDeviceRecords()
        guard let last = records.first, let uuid = UUID(uuidString: last.uuid),
              let peripheral = centralManager.retrievePeripherals(withIdentifiers: [uuid]).first else { return false }
        print("🔄 Auto-reconnecting to known Meshtastic device \(peripheral.name ?? last.name)")
        connect(peripheral: peripheral)
        return true
    }

    // MARK: - Sending Data

    func requestConfig() {
        guard let peripheral = connectedPeripheral,
              let characteristic = toRadioCharacteristic else {
            print("❌ Cannot request config - not connected or missing characteristic")
            return
        }

        guard peripheral.state == .connected else {
            print("❌ Cannot request config - peripheral not in connected state")
            return
        }

        let configRequest = buildWantConfig()
        print("📤 Sending config request (\(configRequest.count) bytes)")
        sendToRadio(configRequest, peripheral: peripheral, characteristic: characteristic)
    }

    func sendTextMessage(_ text: String, to destination: UInt32 = 0xFFFFFFFF) {
        guard let peripheral = connectedPeripheral,
              let characteristic = toRadioCharacteristic else {
            DispatchQueue.main.async {
                self.lastError = "Not connected"
            }
            return
        }

        let packet = buildTextMessage(text, to: destination)
        sendToRadio(packet, peripheral: peripheral, characteristic: characteristic)
    }

    /// Send an ATAK payload over the active BLE connection. Defaults to
    /// portnum 72 (ATAK_PLUGIN, TAKPacket v1); pass portnum 78 for a
    /// TAKPacketV2 marker. Returns true if the bytes were dispatched to the radio.
    @discardableResult
    func sendATAKPlugin(
        payload: Data,
        to destination: UInt32 = 0xFFFFFFFF,
        channel: UInt32 = 0,
        portnum: UInt64 = 72,
        hopLimit: UInt32 = 3,
        wantAck: Bool = false
    ) -> Bool {
        guard let peripheral = connectedPeripheral,
              let characteristic = toRadioCharacteristic,
              peripheral.state == .connected else {
            DispatchQueue.main.async { self.lastError = "Not connected" }
            return false
        }

        let toRadio = ATAKPluginSerializer.buildToRadio(
            atakPayload: payload,
            to: destination,
            channel: channel,
            portnum: portnum,
            hopLimit: hopLimit,
            wantAck: wantAck
        )
        sendToRadio(toRadio, peripheral: peripheral, characteristic: characteristic)
        return true
    }

    /// Send an `AdminMessage` payload (channel / config apply) on the ADMIN_APP
    /// portnum (6) to the local radio. Admin writes are unicast to our own node
    /// with want_ack so the radio applies + persists them. Returns true if the
    /// bytes were dispatched.
    @discardableResult
    func sendAdmin(payload: Data) -> Bool {
        guard let peripheral = connectedPeripheral,
              let characteristic = toRadioCharacteristic,
              peripheral.state == .connected else {
            DispatchQueue.main.async { self.lastError = "Not connected" }
            return false
        }
        let destination = myNodeNum != 0 ? myNodeNum : 0xFFFFFFFF
        let toRadio = ATAKPluginSerializer.buildToRadio(
            atakPayload: payload,
            to: destination,
            channel: 0,
            portnum: MeshtasticAdminCodec.adminPortnum,
            hopLimit: 3,
            wantAck: true
        )
        sendToRadio(toRadio, peripheral: peripheral, characteristic: characteristic)
        return true
    }

    /// Parse a portnum-72 payload and forward to the CoT pipeline.
    fileprivate func handleATAKPluginPayload(_ payload: Data, from nodeId: UInt32) {
        guard let cot = ATAKPluginParser.parse(payload) else {
            print("   ⚠️ Failed to parse ATAK plugin payload (\(payload.count) bytes) from \(String(format: "0x%08X", nodeId))")
            return
        }
        print("   ✅ ATAK plugin → CoTEvent uid=\(cot.uid) type=\(cot.type) callsign=\(cot.detail.callsign)")
        let eventType: CoTEventType = ATAKPluginParser.classify(cot)
        DispatchQueue.main.async {
            CoTEventHandler.shared.handle(event: eventType)
        }
    }

    private func sendToRadio(_ data: Data, peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        // For BLE, we send the raw protobuf data without the TCP framing header
        guard peripheral.state == .connected else {
            print("❌ Cannot send - peripheral not connected")
            return
        }

        // Check if characteristic supports write
        guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else {
            print("❌ Characteristic doesn't support writing")
            return
        }

        let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: characteristic, type: writeType)
        print("📤 Wrote \(data.count) bytes to \(characteristic.uuid)")
    }

    // MARK: - Building Protobuf Messages

    private func buildWantConfig() -> Data {
        var data = Data()

        // ToRadio message with want_config_id = random
        // Field 3: want_config_id (uint32)
        let configId = UInt32.random(in: 1...UInt32.max)
        data.append(0x18) // Tag: field 3, wire type 0 (varint)
        appendVarint(&data, UInt64(configId))

        return data
    }

    private func buildTextMessage(_ text: String, to destination: UInt32) -> Data {
        var data = Data()

        var meshPacket = Data()

        // to (field 2, fixed32)
        meshPacket.append(0x15) // Tag: field 2, wire type 5
        meshPacket.append(contentsOf: withUnsafeBytes(of: destination.littleEndian) { Array($0) })

        // decoded (field 4, sub-message)
        var decoded = Data()

        // portnum = 1 (TEXT_MESSAGE_APP)
        decoded.append(0x08) // Tag: field 1, wire type 0
        appendVarint(&decoded, 1)

        // payload = text
        if let textData = text.data(using: .utf8) {
            decoded.append(0x12) // Tag: field 2, wire type 2
            appendVarint(&decoded, UInt64(textData.count))
            decoded.append(textData)
        }

        meshPacket.append(0x22) // Tag: field 4, wire type 2
        appendVarint(&meshPacket, UInt64(decoded.count))
        meshPacket.append(decoded)

        // want_ack = true (field 10)
        meshPacket.append(0x50) // Tag: field 10, wire type 0
        meshPacket.append(0x01)

        // Wrap in ToRadio
        data.append(0x0A) // Tag: field 1, wire type 2
        appendVarint(&data, UInt64(meshPacket.count))
        data.append(meshPacket)

        return data
    }

    // MARK: - Parsing FromRadio

    private func parseFromRadio(_ data: Data) {
        guard !data.isEmpty else { return }

        var index = 0
        while index < data.count {
            guard index < data.count else { break }

            let tag = data[index]
            let fieldNumber = (tag >> 3)
            let wireType = (tag & 0x07)
            index += 1

            switch fieldNumber {
            case 3: // my_info (canonical FromRadio.my_info = 3)
                print("📦 Parsing my_info (field 3)")
                if let (info, newIndex) = parseMyNodeInfo(data, from: index, wireType: wireType) {
                    index = newIndex
                    print("✅ my_info: nodeNum=\(info.nodeNum), firmware=\(info.firmwareVersion)")
                    DispatchQueue.main.async {
                        self.myNodeNum = info.nodeNum
                        self.firmwareVersion = info.firmwareVersion
                    }
                    delegate?.bleClient(self, didUpdateMyInfo: info.nodeNum, firmwareVersion: info.firmwareVersion)
                } else {
                    print("⚠️ Failed to parse my_info")
                    index = skipField(data, from: index, wireType: wireType)
                }

            case 4: // node_info (canonical FromRadio.node_info = 4)
                print("📦 Parsing node_info (field 4)")
                if let (node, newIndex) = parseNodeInfo(data, from: index, wireType: wireType) {
                    index = newIndex
                    let hasPos = node.position != nil
                    print("✅ node_info: id=\(String(format: "0x%08X", node.id)), name='\(node.shortName)', hasPosition=\(hasPos)")
                    if let pos = node.position {
                        print("   📍 Position: lat=\(pos.latitude), lon=\(pos.longitude), alt=\(pos.altitude ?? 0)")
                    }
                    DispatchQueue.main.async {
                        // Role only rides some NodeInfo frames. A later frame
                        // without one must not erase a role we already learned.
                        var merged = node
                        if merged.role == nil { merged.role = self.nodes[node.id]?.role }
                        self.nodes[node.id] = merged
                        print("📊 Total nodes in store: \(self.nodes.count)")
                    }
                    delegate?.bleClient(self, didReceiveNodeInfo: node)
                } else {
                    print("⚠️ Failed to parse node_info")
                    index = skipField(data, from: index, wireType: wireType)
                }

            case 2: // packet (MeshPacket)
                print("📦 Parsing MeshPacket (field 2)")
                if let (packet, newIndex) = parseMeshPacket(data, from: index, wireType: wireType) {
                    index = newIndex
                    print("✅ MeshPacket: from=\(String(format: "0x%08X", packet.from)), portNum=\(packet.portNum)")
                    handleMeshPacket(packet)
                } else {
                    print("⚠️ Failed to parse MeshPacket")
                    index = skipField(data, from: index, wireType: wireType)
                }

            case 7: // config_complete_id
                print("📦 config_complete_id received (field 7) - all node data sent")
                index = skipField(data, from: index, wireType: wireType)

            case 8: // rebooted
                print("📦 rebooted notification (field 8)")
                index = skipField(data, from: index, wireType: wireType)

            default:
                print("📦 Unknown field \(fieldNumber), wire type \(wireType)")
                index = skipField(data, from: index, wireType: wireType)
            }
        }
    }

    private func parseMyNodeInfo(_ data: Data, from index: Int, wireType: UInt8) -> ((nodeNum: UInt32, firmwareVersion: String), Int)? {
        guard wireType == 2 else { return nil }

        guard let (length, lengthEnd) = readVarint(data, from: index) else { return nil }
        let messageEnd = min(lengthEnd + Int(length), data.count)

        var nodeNum: UInt32 = 0
        let firmware = "Unknown"
        var idx = lengthEnd

        while idx < messageEnd {
            guard idx < data.count else { break }
            let tag = data[idx]
            let field = (tag >> 3)
            let wire = (tag & 0x07)
            idx += 1

            switch field {
            case 1: // my_node_num
                if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    nodeNum = UInt32(val)
                    idx = min(newIdx, messageEnd)
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            default:
                idx = skipField(data, from: idx, wireType: wire)
            }
        }

        return ((nodeNum, firmware), messageEnd)
    }

    private func parseNodeInfo(_ data: Data, from index: Int, wireType: UInt8) -> (MeshNode, Int)? {
        guard wireType == 2 else { return nil }

        guard let (length, lengthEnd) = readVarint(data, from: index) else { return nil }
        let messageEnd = min(lengthEnd + Int(length), data.count)

        var nodeNum: UInt32 = 0
        var shortName = ""
        var longName = ""
        var snr: Double? = nil
        var lastHeard: Date? = nil
        var position: MeshPosition? = nil
        var hopDistance: Int? = nil
        var battery: Int? = nil
        var role: Int? = nil

        var idx = lengthEnd

        // NodeInfo field layout mirrors the canonical Meshtastic mesh.proto and
        // the working Android parser. user lives at field 2 (legacy) or 4
        // (modern); position is field 5; snr at 5(float)/7; last_heard 9;
        // device_metrics (battery) 10; hops_away 11.
        while idx < messageEnd {
            guard idx < data.count else { break }
            let tag = data[idx]
            let field = (tag >> 3)
            let wire = (tag & 0x07)
            idx += 1

            switch field {
            case 1: // num — varint (uint32) or fixed32 depending on firmware rev
                if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    nodeNum = UInt32(truncatingIfNeeded: val)
                    idx = min(newIdx, messageEnd)
                } else if wire == 5 && idx + 4 <= data.count {
                    nodeNum = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    idx += 4
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 2, 4: // user (sub-message) — field 2 (legacy) or 4 (modern)
                if wire == 2, let (len, lenEnd) = readVarint(data, from: idx) {
                    let userEnd = min(lenEnd + Int(len), data.count)
                    let (sn, ln, r) = parseUserSubmessage(data, from: lenEnd, end: userEnd)
                    if !sn.isEmpty { shortName = sn }
                    if !ln.isEmpty { longName = ln }
                    if let r = r { role = r }
                    idx = userEnd
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 5: // position (length-delimited) OR snr (float) — disambiguate by wire type
                if wire == 2, let (len, lenEnd) = readVarint(data, from: idx) {
                    let posEnd = min(lenEnd + Int(len), data.count)
                    if let pos = parsePositionSubmessage(data, from: lenEnd, end: posEnd) {
                        position = pos
                    }
                    idx = posEnd
                } else if wire == 5 && idx + 4 <= data.count {
                    let floatBits = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    snr = Double(Float(bitPattern: floatBits))
                    idx += 4
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 7: // snr (float, alternate field)
                if wire == 5 && idx + 4 <= data.count {
                    let floatBits = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    snr = Double(Float(bitPattern: floatBits))
                    idx += 4
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 9: // last_heard — fixed32 (epoch secs) or varint
                if wire == 5 && idx + 4 <= data.count {
                    let raw = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    lastHeard = Date(timeIntervalSince1970: Double(raw))
                    idx += 4
                } else if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    lastHeard = Date(timeIntervalSince1970: Double(val))
                    idx = newIdx
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 10: // device_metrics (sub-message) — pull battery_level (field 1)
                if wire == 2, let (len, lenEnd) = readVarint(data, from: idx) {
                    let metricsEnd = min(lenEnd + Int(len), data.count)
                    battery = parseDeviceMetricsBattery(data, from: lenEnd, end: metricsEnd)
                    idx = metricsEnd
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 11: // hops_away (varint)
                if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    hopDistance = Int(val)
                    idx = newIdx
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            default:
                idx = skipField(data, from: idx, wireType: wire)
            }
        }

        let node = MeshNode(
            id: nodeNum,
            shortName: shortName.isEmpty ? String(format: "%04X", nodeNum & 0xFFFF) : shortName,
            longName: longName.isEmpty ? "Node \(String(format: "%08X", nodeNum))" : longName,
            position: position,
            lastHeard: lastHeard ?? Date(),
            snr: snr,
            hopDistance: hopDistance,
            batteryLevel: battery,
            role: role
        )

        return (node, messageEnd)
    }

    /// Parse a Meshtastic `User` submessage and return (shortName, longName, role).
    /// long_name = field 2, short_name = field 3, role = field 7.
    private func parseUserSubmessage(_ data: Data, from start: Int, end: Int) -> (short: String, long: String, role: Int?) {
        var shortName = ""
        var longName = ""
        var role: Int? = nil
        var uIdx = start
        while uIdx < end {
            guard uIdx < data.count else { break }
            let uTag = data[uIdx]
            let uField = (uTag >> 3)
            let uWire = (uTag & 0x07)
            uIdx += 1

            if uField == 2 && uWire == 2 { // long_name
                if let (str, newIdx) = readString(data, from: uIdx) {
                    longName = str
                    uIdx = min(newIdx, end)
                } else {
                    uIdx = skipField(data, from: uIdx, wireType: uWire)
                }
            } else if uField == 3 && uWire == 2 { // short_name
                if let (str, newIdx) = readString(data, from: uIdx) {
                    shortName = str
                    uIdx = min(newIdx, end)
                } else {
                    uIdx = skipField(data, from: uIdx, wireType: uWire)
                }
            } else if uField == 7 && uWire == 0 { // role (Config.DeviceConfig.Role)
                if let (v, newIdx) = readVarint(data, from: uIdx) {
                    role = Int(v)
                    uIdx = min(newIdx, end)
                } else {
                    uIdx = skipField(data, from: uIdx, wireType: uWire)
                }
            } else {
                uIdx = skipField(data, from: uIdx, wireType: uWire)
            }
        }
        return (shortName, longName, role)
    }

    /// Parse a Meshtastic `DeviceMetrics` submessage and return battery_level
    /// (field 1, varint, percentage 0-100).
    private func parseDeviceMetricsBattery(_ data: Data, from start: Int, end: Int) -> Int? {
        var idx = start
        while idx < end {
            guard idx < data.count else { break }
            let tag = data[idx]
            let field = (tag >> 3)
            let wire = (tag & 0x07)
            idx += 1
            if field == 1 && wire == 0, let (val, _) = readVarint(data, from: idx) {
                return Int(val)
            }
            idx = skipField(data, from: idx, wireType: wire)
        }
        return nil
    }

    private func parsePositionSubmessage(_ data: Data, from start: Int, end: Int) -> MeshPosition? {
        var lat: Double = 0
        var lon: Double = 0
        var alt: Int? = nil

        print("   🔍 Parsing position submessage, bytes \(start)-\(end)")

        var idx = start
        while idx < end {
            guard idx < data.count else { break }
            let tag = data[idx]
            let field = (tag >> 3)
            let wire = (tag & 0x07)
            idx += 1

            switch field {
            case 1: // latitude_i (sfixed32)
                if wire == 5 && idx + 4 <= data.count {
                    let bits = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    lat = Double(Int32(bitPattern: bits)) / 1e7
                    print("   🔍 latitude_i (sfixed32): raw=\(bits), lat=\(lat)")
                    idx += 4
                } else if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    // Handle as sint32/varint (zigzag encoded)
                    let zigzag = UInt32(val)
                    let decoded = Int32(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))
                    lat = Double(decoded) / 1e7
                    print("   🔍 latitude_i (varint/zigzag): raw=\(val), decoded=\(decoded), lat=\(lat)")
                    idx = newIdx
                } else {
                    print("   ⚠️ latitude_i: unexpected wire type \(wire)")
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 2: // longitude_i (sfixed32)
                if wire == 5 && idx + 4 <= data.count {
                    let bits = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    lon = Double(Int32(bitPattern: bits)) / 1e7
                    print("   🔍 longitude_i (sfixed32): raw=\(bits), lon=\(lon)")
                    idx += 4
                } else if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    // Handle as sint32/varint (zigzag encoded)
                    let zigzag = UInt32(val)
                    let decoded = Int32(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))
                    lon = Double(decoded) / 1e7
                    print("   🔍 longitude_i (varint/zigzag): raw=\(val), decoded=\(decoded), lon=\(lon)")
                    idx = newIdx
                } else {
                    print("   ⚠️ longitude_i: unexpected wire type \(wire)")
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 3: // altitude
                if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    alt = Int(Int32(bitPattern: UInt32(val)))
                    print("   🔍 altitude: \(alt ?? 0)")
                    idx = newIdx
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            default:
                idx = skipField(data, from: idx, wireType: wire)
            }
        }

        if lat == 0 && lon == 0 {
            print("   ⚠️ Position is 0,0 - skipping (no valid position)")
            return nil
        }

        print("   ✅ Parsed position: lat=\(lat), lon=\(lon), alt=\(alt ?? 0)")
        return MeshPosition(latitude: lat, longitude: lon, altitude: alt)
    }

    private func parseMeshPacket(_ data: Data, from index: Int, wireType: UInt8) -> ((from: UInt32, to: UInt32, portNum: Int, payload: Data), Int)? {
        guard wireType == 2 else { return nil }

        guard let (length, lengthEnd) = readVarint(data, from: index) else { return nil }
        let messageEnd = min(lengthEnd + Int(length), data.count)
        guard messageEnd <= data.count else { return nil }

        var fromNode: UInt32 = 0
        var toNode: UInt32 = 0
        var portNum = 0
        var payload = Data()

        var idx = lengthEnd

        while idx < messageEnd {
            guard idx < data.count else { break }
            let tag = data[idx]
            let field = (tag >> 3)
            let wire = (tag & 0x07)
            idx += 1

            switch field {
            case 1: // from
                if wire == 5 && idx + 4 <= data.count {
                    fromNode = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    idx += 4
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 2: // to
                if wire == 5 && idx + 4 <= data.count {
                    toNode = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    idx += 4
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 4: // decoded (Data message)
                if wire == 2, let (len, lenEnd) = readVarint(data, from: idx) {
                    let dataEnd = min(lenEnd + Int(len), data.count)
                    var dIdx = lenEnd
                    while dIdx < dataEnd {
                        guard dIdx < data.count else { break }
                        let dTag = data[dIdx]
                        let dField = (dTag >> 3)
                        let dWire = (dTag & 0x07)
                        dIdx += 1

                        if dField == 1 && dWire == 0 { // portnum
                            if let (val, newIdx) = readVarint(data, from: dIdx) {
                                portNum = Int(val)
                                dIdx = min(newIdx, dataEnd)
                            } else {
                                dIdx = skipField(data, from: dIdx, wireType: dWire)
                            }
                        } else if dField == 2 && dWire == 2 { // payload
                            if let (len2, len2End) = readVarint(data, from: dIdx) {
                                let payloadEnd = min(len2End + Int(len2), data.count)
                                payload = data.subdata(in: len2End..<payloadEnd)
                                dIdx = payloadEnd
                            } else {
                                dIdx = skipField(data, from: dIdx, wireType: dWire)
                            }
                        } else {
                            dIdx = skipField(data, from: dIdx, wireType: dWire)
                        }
                    }
                    idx = dataEnd
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            default:
                idx = skipField(data, from: idx, wireType: wire)
            }
        }

        return ((fromNode, toNode, portNum, payload), messageEnd)
    }

    private func handleMeshPacket(_ packet: (from: UInt32, to: UInt32, portNum: Int, payload: Data)) {
        // Port numbers from Meshtastic:
        // 1 = TEXT_MESSAGE_APP
        // 3 = POSITION_APP
        // 4 = NODEINFO_APP
        // 67 = TELEMETRY_APP
        // 72 = ATAK_PLUGIN
        // 257 = ATAK_FORWARDER

        switch packet.portNum {
        case 1: // Text message
            if let text = String(data: packet.payload, encoding: .utf8) {
                print("   💬 Text message from \(String(format: "0x%08X", packet.from)): \(text)")
                delegate?.bleClient(self, didReceiveMessage: packet.from, text: text)
            }

        case 3: // Position
            print("   📍 Position update from \(String(format: "0x%08X", packet.from))")
            if let position = parsePositionPayload(packet.payload) {
                DispatchQueue.main.async {
                    if var node = self.nodes[packet.from] {
                        node.position = position
                        self.nodes[packet.from] = node
                        print("   ✅ Updated position for existing node \(node.shortName)")
                    } else {
                        // Create a basic node entry if we don't have one yet
                        let newNode = MeshNode(
                            id: packet.from,
                            shortName: String(format: "%04X", packet.from & 0xFFFF),
                            longName: "Node \(String(format: "%08X", packet.from))",
                            position: position,
                            lastHeard: Date(),
                            snr: nil,
                            hopDistance: nil,
                            batteryLevel: nil
                        )
                        self.nodes[packet.from] = newNode
                        print("   ✅ Created new node entry with position for \(String(format: "0x%08X", packet.from))")
                    }
                    print("📊 Total nodes in store: \(self.nodes.count)")
                }
                delegate?.bleClient(self, didReceivePosition: packet.from, position: position)
            }

        case 4: // NodeInfo
            print("   ℹ️ NodeInfo packet from \(String(format: "0x%08X", packet.from)) - handled via FromRadio field 6")

        case 67: // Telemetry
            print("   📊 Telemetry from \(String(format: "0x%08X", packet.from))")

        case 72, 257: // ATAK_PLUGIN / ATAK_FORWARDER
            print("   🎯 ATAK Plugin message from \(String(format: "0x%08X", packet.from)) (\(packet.payload.count) bytes)")
            handleATAKPluginPayload(packet.payload, from: packet.from)

        case 78: // ATAK_PLUGIN_V2 / TAKPacketV2 — a dropped tactical marker
            print("   🎯 TAKPacketV2 marker from \(String(format: "0x%08X", packet.from)) (\(packet.payload.count) bytes)")
            handleTAKPacketV2Payload(packet.payload, from: packet.from)

        default:
            print("   ❓ Unknown portNum \(packet.portNum) from \(String(format: "0x%08X", packet.from))")
        }
    }

    /// Decode a port-78 TAKPacketV2 payload into a marker CoTEvent and feed it
    /// to the CoT pipeline as a position/marker update (NOT chat). Dedup is by
    /// uid (preserved verbatim by the codec) — CoTEventHandler updates the
    /// existing event in place when the uid already exists.
    fileprivate func handleTAKPacketV2Payload(_ payload: Data, from nodeId: UInt32) {
        guard let event = TAKPacketV2Codec.decode(payload) else {
            print("   ⚠️ Failed to decode TAKPacketV2 payload (\(payload.count) bytes) from \(String(format: "0x%08X", nodeId))")
            return
        }
        print("   ✅ TAKPacketV2 → marker CoTEvent uid=\(event.uid) type=\(event.type) callsign=\(event.detail.callsign)")
        DispatchQueue.main.async {
            CoTEventHandler.shared.handle(event: .positionUpdate(event))
        }
    }

    private func parsePositionPayload(_ data: Data) -> MeshPosition? {
        guard !data.isEmpty else { return nil }

        print("   🔍 Parsing position payload, \(data.count) bytes")

        var lat: Double = 0
        var lon: Double = 0
        var alt: Int? = nil

        var idx = 0
        while idx < data.count {
            guard idx < data.count else { break }
            let tag = data[idx]
            let field = (tag >> 3)
            let wire = (tag & 0x07)
            idx += 1

            switch field {
            case 1: // latitude_i (sfixed32 or sint32)
                if wire == 5 && idx + 4 <= data.count {
                    let bits = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    lat = Double(Int32(bitPattern: bits)) / 1e7
                    print("   🔍 latitude_i (sfixed32): \(lat)")
                    idx += 4
                } else if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    // Handle as sint32/varint (zigzag encoded)
                    let zigzag = UInt32(val)
                    let decoded = Int32(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))
                    lat = Double(decoded) / 1e7
                    print("   🔍 latitude_i (varint/zigzag): \(lat)")
                    idx = newIdx
                } else {
                    print("   ⚠️ latitude_i: unexpected wire type \(wire)")
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 2: // longitude_i (sfixed32 or sint32)
                if wire == 5 && idx + 4 <= data.count {
                    let bits = UInt32(data[idx]) | (UInt32(data[idx+1]) << 8) | (UInt32(data[idx+2]) << 16) | (UInt32(data[idx+3]) << 24)
                    lon = Double(Int32(bitPattern: bits)) / 1e7
                    print("   🔍 longitude_i (sfixed32): \(lon)")
                    idx += 4
                } else if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    // Handle as sint32/varint (zigzag encoded)
                    let zigzag = UInt32(val)
                    let decoded = Int32(bitPattern: (zigzag >> 1) ^ (0 &- (zigzag & 1)))
                    lon = Double(decoded) / 1e7
                    print("   🔍 longitude_i (varint/zigzag): \(lon)")
                    idx = newIdx
                } else {
                    print("   ⚠️ longitude_i: unexpected wire type \(wire)")
                    idx = skipField(data, from: idx, wireType: wire)
                }
            case 3: // altitude
                if wire == 0, let (val, newIdx) = readVarint(data, from: idx) {
                    alt = Int(Int32(bitPattern: UInt32(val)))
                    print("   🔍 altitude: \(alt ?? 0)")
                    idx = newIdx
                } else {
                    idx = skipField(data, from: idx, wireType: wire)
                }
            default:
                idx = skipField(data, from: idx, wireType: wire)
            }
        }

        if lat == 0 && lon == 0 {
            print("   ⚠️ Position is 0,0 - no valid position")
            return nil
        }

        print("   ✅ Position update: lat=\(lat), lon=\(lon), alt=\(alt ?? 0)")
        return MeshPosition(latitude: lat, longitude: lon, altitude: alt)
    }

    // MARK: - Protobuf Helpers

    private func readVarint(_ data: Data, from index: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift = 0
        var idx = index

        while idx < data.count {
            let byte = data[idx]
            idx += 1
            result |= UInt64(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                return (result, idx)
            }

            shift += 7
            if shift >= 64 { return nil }
        }

        return nil
    }

    private func readString(_ data: Data, from index: Int) -> (String, Int)? {
        guard let (length, lengthEnd) = readVarint(data, from: index) else { return nil }
        let stringEnd = lengthEnd + Int(length)
        guard stringEnd <= data.count else { return nil }

        let stringData = data.subdata(in: lengthEnd..<stringEnd)
        guard let str = String(data: stringData, encoding: .utf8) else { return nil }

        return (str, stringEnd)
    }

    private func appendVarint(_ data: inout Data, _ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private func skipField(_ data: Data, from index: Int, wireType: UInt8) -> Int {
        guard index < data.count else { return data.count }

        switch wireType {
        case 0: // Varint
            if let (_, newIdx) = readVarint(data, from: index) {
                return min(newIdx, data.count)
            }
            return min(index + 1, data.count)

        case 1: // 64-bit
            return min(index + 8, data.count)

        case 2: // Length-delimited
            if let (length, lengthEnd) = readVarint(data, from: index) {
                return min(lengthEnd + Int(length), data.count)
            }
            return min(index + 1, data.count)

        case 5: // 32-bit
            return min(index + 4, data.count)

        default:
            return min(index + 1, data.count)
        }
    }
}

// MARK: - CBCentralManagerDelegate

@available(iOS 13.0, *)
extension MeshtasticBLEClient: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        DispatchQueue.main.async {
            self.bluetoothState = central.state
        }

        delegate?.bleClient(self, bluetoothStateChanged: central.state)

        switch central.state {
        case .poweredOn:
            print("Bluetooth is ready")
            // Surface previously-paired radios immediately and reconnect to the
            // last one (unless the operator explicitly disconnected), so a known
            // device comes back without a scan or re-pair.
            refreshKnownDevices()
            reconnectLastDevice()
        case .poweredOff:
            DispatchQueue.main.async {
                self.lastError = "Bluetooth is turned off"
                self.isConnected = false
                self.connectionState = .disconnected
            }
        case .unauthorized:
            DispatchQueue.main.async {
                self.lastError = "Bluetooth permission not granted"
            }
        case .unsupported:
            DispatchQueue.main.async {
                self.lastError = "Bluetooth is not supported on this device"
            }
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        let deviceName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "Unknown Meshtastic"

        let device = DiscoveredBLEDevice(
            id: peripheral.identifier,
            name: deviceName,
            rssi: RSSI.intValue,
            peripheral: peripheral
        )

        DispatchQueue.main.async {
            if let existingIndex = self.discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                self.discoveredDevices[existingIndex] = device
            } else {
                self.discoveredDevices.append(device)
            }
        }

        delegate?.bleClient(self, didDiscover: device)
        print("Discovered: \(deviceName) (RSSI: \(RSSI))")
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to \(peripheral.name ?? "device")")

        DispatchQueue.main.async {
            self.connectionState = .discovering
            self.connectedPeripheral = peripheral
        }

        peripheral.delegate = self
        peripheral.discoverServices([MeshtasticBLEUUID.service])
    }

    /// True when an error is the stale-bond case ("peer removed pairing
    /// information", CBError code 14) — iOS holds pairing info the radio no
    /// longer honours. Apps can't clear bonds, so the user must Forget +
    /// re-pair in Settings.
    private func isPairingError(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        if error.domain == CBErrorDomain,
           error.code == CBError.Code.peerRemovedPairingInformation.rawValue { return true }
        return error.localizedDescription.lowercased().contains("pairing")
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimeout()
        let pairing = isPairingError(error)
        if pairing {
            // Stale bond — don't auto-reconnect into a guaranteed-failing loop.
            userDidDisconnect = true
        }
        DispatchQueue.main.async {
            self.connectionState = .failed
            self.needsBluetoothRepair = pairing
            self.lastError = pairing
                ? "Bluetooth pairing is out of sync. In iOS Settings → Bluetooth, tap your Meshtastic device, choose “Forget This Device,” then reconnect here. You should only need to do this once."
                : (error?.localizedDescription ?? "Failed to connect")
        }

        delegate?.bleClient(self, didDisconnect: peripheral, error: error)
        print("Failed to connect: \(error?.localizedDescription ?? "unknown error")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        cancelConnectTimeout()
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectionState = .disconnected
            self.connectedPeripheral = nil
        }

        readTimer?.invalidate()
        readTimer = nil

        delegate?.bleClient(self, didDisconnect: peripheral, error: error)
        print("Disconnected from \(peripheral.name ?? "device")")
    }
}

// MARK: - CBPeripheralDelegate

@available(iOS 13.0, *)
extension MeshtasticBLEClient: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            print("❌ Service discovery failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.lastError = "Service discovery failed: \(error.localizedDescription)"
            }
            return
        }

        guard let services = peripheral.services else {
            print("❌ No services found")
            return
        }

        print("📡 Found \(services.count) services")
        for service in services {
            print("  - Service: \(service.uuid)")
            if service.uuid == MeshtasticBLEUUID.service {
                print("✅ Found Meshtastic service, discovering ALL characteristics...")
                // Discover ALL characteristics (nil = all) to ensure we get everything
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            print("❌ Characteristic discovery failed: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.lastError = "Characteristic discovery failed: \(error.localizedDescription)"
            }
            return
        }

        guard let characteristics = service.characteristics else {
            print("❌ No characteristics found")
            return
        }

        print("📡 Found \(characteristics.count) characteristics:")
        for characteristic in characteristics {
            print("  - Characteristic: \(characteristic.uuid) (properties: \(characteristic.properties.rawValue))")

            switch characteristic.uuid {
            case MeshtasticBLEUUID.toRadio:
                toRadioCharacteristic = characteristic
                print("    ✅ This is toRadio (write)")

            case MeshtasticBLEUUID.fromRadio:
                fromRadioCharacteristic = characteristic
                print("    ✅ This is fromRadio (read)")

            case MeshtasticBLEUUID.fromNum:
                fromNumCharacteristic = characteristic
                print("    ✅ This is fromNum (notify)")
                // Subscribe to notifications for fromNum
                peripheral.setNotifyValue(true, for: characteristic)

            default:
                break
            }
        }

        // Check what we found
        print("📊 Characteristic status:")
        print("  - toRadio: \(toRadioCharacteristic != nil ? "✅" : "❌")")
        print("  - fromRadio: \(fromRadioCharacteristic != nil ? "✅" : "❌")")
        print("  - fromNum: \(fromNumCharacteristic != nil ? "✅" : "❌")")

        // We need at least toRadio to send and fromRadio OR fromNum to receive
        let canSend = toRadioCharacteristic != nil
        let canReceive = fromRadioCharacteristic != nil || fromNumCharacteristic != nil

        if canSend && canReceive {
            print("✅ Ready to communicate with Meshtastic device")

            // Connection fully established — stand the watchdog down.
            cancelConnectTimeout()

            // Remember this radio so it shows under "Paired Devices" and can
            // be auto-reconnected next time without a scan.
            rememberDevice(peripheral)
            userDidDisconnect = false

            DispatchQueue.main.async {
                self.isConnected = true
                self.connectionState = .connected
                self.needsBluetoothRepair = false
            }

            delegate?.bleClient(self, didConnect: peripheral)

            // Subscribe to fromRadio notifications if available
            if let fromRadio = fromRadioCharacteristic {
                if fromRadio.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: fromRadio)
                    print("📡 Subscribed to fromRadio notifications")
                }
            }

            // Delay config request to let connection stabilize
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, self.isConnected else { return }
                print("📤 Requesting device config...")
                self.requestConfig()
            }

            // Start periodic reads if we have fromRadio
            if fromRadioCharacteristic != nil {
                startPeriodicReads()
            }
        } else {
            print("❌ Missing required characteristics - cannot communicate")
            cancelConnectTimeout()
            DispatchQueue.main.async {
                self.lastError = "Device missing required BLE characteristics"
                self.connectionState = .failed
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("❌ Error reading characteristic \(characteristic.uuid): \(error.localizedDescription)")
            isDrainingQueue = false
            return
        }

        if characteristic.uuid == MeshtasticBLEUUID.fromRadio {
            guard let data = characteristic.value, !data.isEmpty else {
                // Empty data means queue is drained
                if isDrainingQueue {
                    print("📥 Queue drained after \(messagesReadInBatch) messages")
                    isDrainingQueue = false
                    messagesReadInBatch = 0
                }
                return
            }

            messagesReadInBatch += 1
            print("📥 Received \(data.count) bytes from fromRadio (message #\(messagesReadInBatch))")
            parseFromRadio(data)

            // Keep reading - there may be more messages queued
            // Meshtastic queues multiple messages and we need to drain them all
            if peripheral.state == .connected, let fromRadio = fromRadioCharacteristic {
                isDrainingQueue = true
                peripheral.readValue(for: fromRadio)
            }

        } else if characteristic.uuid == MeshtasticBLEUUID.fromNum {
            print("📥 fromNum notification received - starting queue drain")
            // fromNum notified us there's data to read - start draining queue
            if let fromRadio = fromRadioCharacteristic, peripheral.state == .connected {
                messagesReadInBatch = 0
                isDrainingQueue = true
                peripheral.readValue(for: fromRadio)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            DispatchQueue.main.async {
                self.lastError = "Write failed: \(error.localizedDescription)"
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Notification state update failed: \(error.localizedDescription)")
            return
        }

        print("Notification state updated for \(characteristic.uuid): \(characteristic.isNotifying)")
    }

    // MARK: - Periodic Reading

    private func startPeriodicReads() {
        guard !isShuttingDown else { return }

        readTimer?.invalidate()
        readTimer = nil

        guard fromRadioCharacteristic != nil else {
            print("⚠️ Cannot start periodic reads - fromRadio characteristic not available")
            return
        }

        print("📡 Starting periodic reads from fromRadio...")

        // Read fromRadio periodically to get queued messages
        // Use a slower interval (1 second) to reduce load
        readTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self, !self.isShuttingDown else {
                timer.invalidate()
                return
            }

            // Safety checks
            guard self.isConnected,
                  let peripheral = self.connectedPeripheral,
                  peripheral.state == .connected,
                  let fromRadio = self.fromRadioCharacteristic else {
                print("⚠️ Stopping periodic reads - connection lost")
                timer.invalidate()
                self.readTimer = nil
                return
            }

            peripheral.readValue(for: fromRadio)
        }
    }

    private func stopPeriodicReads() {
        readTimer?.invalidate()
        readTimer = nil
        print("📡 Stopped periodic reads")
    }
}
