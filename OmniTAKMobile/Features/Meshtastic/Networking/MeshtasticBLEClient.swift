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
    // Meshtastic BLE GATT UUIDs. They must match the firmware exactly
    // (src/BluetoothCommon.h: MESH_SERVICE_UUID, TORADIO_UUID, FROMRADIO_UUID,
    // FROMNUM_UUID). Earlier builds had wrong fromRadio/fromNum UUIDs, so the
    // characteristics never matched on discovery — the radio could never be
    // read and the node list stayed empty.
    static let service = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    static let toRadio = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    static let fromRadio = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")
    // This ended in …de15e6 (copied from the Android client, which had the
    // same typo), which matches nothing on the radio: fromNum was never
    // found, its notifications were never enabled, and frames only came in
    // on the once-a-second read timer.
    static let fromNum = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")
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

    /// The radio's own settings as they come in during the config download, and
    /// the start of each download. MeshtasticManager keeps them so a settings
    /// write can change one field and send the rest back (#148). Events are
    /// sent in the order the frames arrive.
    let settingsEvents = PassthroughSubject<MeshtasticRadioSettings.Event, Never>()

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
    ///
    /// Without the radio's node number nothing is sent. There is no fallback to
    /// the broadcast address: that would put the admin message, and for
    /// set_channel the channel key, on the air.
    @discardableResult
    func sendAdmin(payload: Data) -> Bool {
        guard let peripheral = connectedPeripheral,
              let characteristic = toRadioCharacteristic,
              peripheral.state == .connected else {
            DispatchQueue.main.async { self.lastError = MeshtasticWriteResult.notConnected }
            return false
        }
        guard let toRadio = MeshtasticAdminCodec.toRadioFrame(adminPayload: payload, myNodeNum: myNodeNum) else {
            DispatchQueue.main.async { self.lastError = MeshtasticWriteResult.notLoaded }
            return false
        }
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

    // MARK: - FromRadio handling (decoding lives in MeshtasticProtoDecoder)

    private func parseFromRadio(_ data: Data) {
        guard let payload = MeshtasticProtoDecoder.decodeFromRadio(data) else { return }

        if let event = MeshtasticRadioSettings.Event(payload) {
            settingsEvents.send(event)
        }

        switch payload {
        case .myInfo(let nodeNum):
            // FromRadio.my_info carries the node number only. The firmware
            // version arrives in a separate metadata frame, which is not decoded.
            let firmware = "Unknown"
            print("📦 my_info: nodeNum=\(nodeNum)")
            DispatchQueue.main.async {
                self.myNodeNum = nodeNum
                self.firmwareVersion = firmware
            }
            delegate?.bleClient(self, didUpdateMyInfo: nodeNum, firmwareVersion: firmware)

        case .nodeInfo(let node):
            let hasPos = node.position != nil
            print("✅ node_info: id=\(String(format: "0x%08X", node.id)), name='\(node.shortName)', hasPosition=\(hasPos)")
            if let pos = node.position {
                print("   📍 Position: lat=\(pos.latitude), lon=\(pos.longitude), alt=\(pos.altitude ?? 0)")
            }
            DispatchQueue.main.async {
                // A later frame without a role or a last-heard time must not
                // erase what an earlier one told us.
                self.nodes[node.id] = node.carryingForward(from: self.nodes[node.id])
                print("📊 Total nodes in store: \(self.nodes.count)")
            }
            delegate?.bleClient(self, didReceiveNodeInfo: node)

        case .packet(let packet):
            print("✅ MeshPacket: from=\(String(format: "0x%08X", packet.from)), portNum=\(packet.portNum)")
            handleMeshPacket(packet)

        case .configComplete:
            print("📦 config_complete_id received (field 7) - all node data sent")

        case .rebooted:
            print("📦 rebooted notification (field 8)")

        case .config(let variant, _):
            // Not logged beyond the number: the security variant holds a key.
            print("📦 config variant \(variant)")

        case .channel(let index, _):
            // Not logged beyond the index: a channel holds its key.
            print("📦 channel slot \(index)")

        case .other(let field):
            print("📦 Unused FromRadio field \(field)")
        }
    }

    private func handleMeshPacket(_ packet: MeshtasticProtoDecoder.MeshPacketFrame) {
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
            if let position = MeshtasticProtoDecoder.decodePosition(packet.payload) {
                // A packet that just came off the radio means the node was heard.
                // The radio's rx_time says when; it is absent when the radio has
                // no clock, and then the phone's clock is the best there is.
                let heardAt = packet.rxTime ?? Date()
                DispatchQueue.main.async {
                    if var node = self.nodes[packet.from] {
                        node.position = position
                        node.noteHeard(at: heardAt)
                        self.nodes[packet.from] = node
                        print("   ✅ Updated position for existing node \(node.shortName)")
                    } else {
                        // Create a basic node entry if we don't have one yet
                        let newNode = MeshNode(
                            id: packet.from,
                            shortName: String(format: "%04X", packet.from & 0xFFFF),
                            longName: "Node \(String(format: "%08X", packet.from))",
                            position: position,
                            lastHeard: heardAt,
                            snr: packet.rxSnr.map(Double.init),
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
            print("   ℹ️ NodeInfo packet from \(String(format: "0x%08X", packet.from)) - handled via FromRadio field 4")

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

    // MARK: - Protobuf Helpers

    private func appendVarint(_ data: inout Data, _ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
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

// MARK: - Settings writes

@available(iOS 13.0, *)
extension MeshtasticBLEClient: MeshtasticAdminLink {}
