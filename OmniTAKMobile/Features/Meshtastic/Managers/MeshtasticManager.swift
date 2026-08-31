//
//  MeshtasticManager.swift
//  OmniTAK Mobile
//
//  Meshtastic mesh network manager - TCP and Bluetooth connections
//

import Foundation
import Combine
import SwiftUI
import CoreBluetooth

@MainActor
public class MeshtasticManager: ObservableObject {

    // MARK: - Singleton

    /// Shared instance for app-wide Meshtastic management
    public static let shared = MeshtasticManager()

    // MARK: - Published Properties

    @Published public var connectedDevice: MeshtasticDevice?
    @Published public var meshNodes: [MeshNode] = []
    @Published public var lastError: String?
    @Published public var connectionState: String = "Disconnected"
    @Published public var myNodeNum: UInt32 = 0
    @Published public var firmwareVersion: String = ""

    // BLE-specific properties
    @Published public var isScanning: Bool = false
    @Published public var discoveredBLEDevices: [DiscoveredBLEDevice] = []
    /// Previously-paired radios available for one-tap reconnect (no scan).
    @Published public var knownBLEDevices: [DiscoveredBLEDevice] = []
    /// True when a connect failed on a stale iOS bond and the user needs to
    /// Forget + re-pair in Settings.
    @Published public var needsBluetoothRepair: Bool = false
    @Published public var bluetoothState: CBManagerState = .unknown

    // MARK: - Private Properties

    private var _tcpClient: Any? = nil
    private var _bleClient: Any? = nil

    @available(iOS 13.0, *)
    private var tcpClient: MeshtasticTCPClient {
        if _tcpClient == nil {
            _tcpClient = MeshtasticTCPClient()
            setupTCPClientObservers()
        }
        return _tcpClient as! MeshtasticTCPClient
    }

    @available(iOS 13.0, *)
    private var bleClient: MeshtasticBLEClient {
        if _bleClient == nil {
            _bleClient = MeshtasticBLEClient()
            setupBLEClientObservers()
        }
        return _bleClient as! MeshtasticBLEClient
    }

    private var tcpClientCancellables = Set<AnyCancellable>()
    private var bleClientCancellables = Set<AnyCancellable>()

    // Saved TCP connections
    @AppStorage("meshtastic_saved_hosts") private var savedHostsData: Data = Data()

    /// LoRa hop limit applied to dropped-marker (TAKPacketV2 / port 78) sends.
    /// Default 3 — enough to relay across a small mesh without flooding airtime.
    @AppStorage("meshtastic_marker_hop_limit") private var markerHopLimit: Int = 3

    /// Per-uid debounce of marker mesh sends. The first send of a uid always
    /// goes out; repeats of the same marker within `markerSendThrottle` seconds
    /// are suppressed so a re-broadcast / edit storm doesn't flood the LoRa
    /// channel. Keyed by marker uid → last send time.
    private var lastMarkerSendTimes: [String: Date] = [:]
    private let markerSendThrottle: TimeInterval = 30

    // MARK: - Initialization

    public init() {
        // TCP and BLE clients are lazily initialized when needed.
        // Node→map publishing is the single MeshtasticCoTConverter
        // pipeline (enableAutoMapUpdates → publishMeshNodesToMap).
    }

    // MARK: - TCP Client Setup

    @available(iOS 13.0, *)
    private func setupTCPClientObservers() {
        guard let client = _tcpClient as? MeshtasticTCPClient else { return }

        client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (connected: Bool) in
                if !connected {
                    self?.handleDisconnection()
                }
            }
            .store(in: &tcpClientCancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (state: MeshtasticTCPClient.ConnectionState) in
                self?.connectionState = state.rawValue
            }
            .store(in: &tcpClientCancellables)

        client.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (nodes: [UInt32: MeshNode]) in
                self?.meshNodes = Array(nodes.values)
            }
            .store(in: &tcpClientCancellables)

        client.$myNodeNum
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (nodeNum: UInt32) in
                self?.myNodeNum = nodeNum
            }
            .store(in: &tcpClientCancellables)

        client.$firmwareVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (version: String) in
                self?.firmwareVersion = version
            }
            .store(in: &tcpClientCancellables)

        client.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (error: String?) in
                self?.lastError = error
            }
            .store(in: &tcpClientCancellables)
    }

    private func handleDisconnection() {
        if var device = connectedDevice {
            device.isConnected = false
            connectedDevice = device
        }
    }

    // MARK: - BLE Client Setup

    @available(iOS 13.0, *)
    private func setupBLEClientObservers() {
        guard let client = _bleClient as? MeshtasticBLEClient else { return }

        client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (connected: Bool) in
                if connected {
                    // Enable auto map updates when connected
                    self?.enableAutoMapUpdates()
                    // Update device connection status
                    if var device = self?.connectedDevice {
                        device.isConnected = true
                        self?.connectedDevice = device
                    }
                } else {
                    self?.handleDisconnection()
                    self?.disableAutoMapUpdates()
                }
            }
            .store(in: &bleClientCancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (state: MeshtasticBLEClient.ConnectionState) in
                self?.connectionState = state.rawValue
            }
            .store(in: &bleClientCancellables)

        client.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (nodes: [UInt32: MeshNode]) in
                self?.meshNodes = Array(nodes.values)
            }
            .store(in: &bleClientCancellables)

        client.$myNodeNum
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (nodeNum: UInt32) in
                self?.myNodeNum = nodeNum
            }
            .store(in: &bleClientCancellables)

        client.$firmwareVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (version: String) in
                self?.firmwareVersion = version
            }
            .store(in: &bleClientCancellables)

        client.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (error: String?) in
                self?.lastError = error
            }
            .store(in: &bleClientCancellables)

        client.$isScanning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (scanning: Bool) in
                self?.isScanning = scanning
            }
            .store(in: &bleClientCancellables)

        client.$discoveredDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (devices: [DiscoveredBLEDevice]) in
                self?.discoveredBLEDevices = devices
            }
            .store(in: &bleClientCancellables)

        client.$knownDevices
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (devices: [DiscoveredBLEDevice]) in
                self?.knownBLEDevices = devices
            }
            .store(in: &bleClientCancellables)

        client.$needsBluetoothRepair
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (needsRepair: Bool) in
                self?.needsBluetoothRepair = needsRepair
            }
            .store(in: &bleClientCancellables)

        client.$bluetoothState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (state: CBManagerState) in
                self?.bluetoothState = state
            }
            .store(in: &bleClientCancellables)
    }

    // MARK: - Saved Hosts

    public struct SavedHost: Codable, Identifiable {
        public var id: String { "\(host):\(port)" }
        public var host: String
        public var port: UInt16
        public var name: String
        public var lastConnected: Date?
    }

    public var savedHosts: [SavedHost] {
        get {
            (try? JSONDecoder().decode([SavedHost].self, from: savedHostsData)) ?? []
        }
        set {
            savedHostsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    public func saveHost(_ host: String, port: UInt16, name: String) {
        var hosts = savedHosts
        if let idx = hosts.firstIndex(where: { $0.host == host && $0.port == port }) {
            hosts[idx].name = name
            hosts[idx].lastConnected = Date()
        } else {
            hosts.append(SavedHost(host: host, port: port, name: name, lastConnected: Date()))
        }
        savedHosts = hosts
    }

    public func removeHost(_ host: String, port: UInt16) {
        savedHosts.removeAll { $0.host == host && $0.port == port }
    }

    // MARK: - BLE Scanning

    /// Start scanning for Bluetooth Meshtastic devices
    public func startBLEScanning() {
        guard #available(iOS 13.0, *) else {
            lastError = "Bluetooth requires iOS 13.0 or later"
            return
        }

        lastError = nil
        bleClient.startScanning()
    }

    /// Stop BLE scanning
    public func stopBLEScanning() {
        guard #available(iOS 13.0, *) else { return }
        bleClient.stopScanning()
    }

    /// Refresh the list of previously-paired / system-known BLE radios
    /// (no scan required).
    public func refreshKnownBLEDevices() {
        guard #available(iOS 13.0, *) else { return }
        bleClient.refreshKnownDevices()
    }

    /// Reconnect to the most-recently-used BLE radio without scanning.
    public func reconnectLastBLEDevice() {
        guard #available(iOS 13.0, *) else { return }
        bleClient.reconnectLastDevice()
    }

    /// Forget a previously-paired BLE radio.
    public func forgetBLEDevice(id: UUID) {
        guard #available(iOS 13.0, *) else { return }
        bleClient.forgetDevice(id: id)
    }

    /// Connect to a discovered BLE device
    public func connectBLE(device: DiscoveredBLEDevice) {
        guard #available(iOS 13.0, *) else {
            lastError = "Bluetooth requires iOS 13.0 or later"
            return
        }

        lastError = nil

        // Create a MeshtasticDevice for the BLE device
        let meshtasticDevice = MeshtasticDevice(
            id: device.id.uuidString,
            name: device.name,
            connectionType: .bluetooth,
            devicePath: device.id.uuidString,
            isConnected: false,
            signalStrength: device.rssi,
            nodeId: nil,
            lastSeen: Date()
        )

        connectedDevice = meshtasticDevice
        bleClient.connect(to: device)

        print("Connecting to BLE device: \(device.name)")
    }

    // MARK: - Connection Management

    /// Connect to a Meshtastic device
    public func connect(to device: MeshtasticDevice) {
        lastError = nil

        switch device.connectionType {
        case .bluetooth:
            // For BLE, need to scan and find the device first
            lastError = "Use connectBLE() with a discovered device for Bluetooth connections"

        case .tcp:
            let port = UInt16(device.nodeId ?? "4403") ?? 4403
            connectTCP(host: device.devicePath, port: port, device: device)
        }
    }

    /// Connect via TCP to a Meshtastic device
    public func connectTCP(host: String, port: UInt16 = 4403, device: MeshtasticDevice? = nil) {
        guard #available(iOS 13.0, *) else {
            lastError = "TCP connections require iOS 13.0 or later"
            return
        }

        lastError = nil

        // Create or use provided device
        var targetDevice = device ?? MeshtasticDevice(
            id: "tcp-\(host)-\(port)",
            name: "\(host):\(port)",
            connectionType: .tcp,
            devicePath: host,
            isConnected: false,
            nodeId: "\(port)"
        )

        // Connect via TCP client
        tcpClient.connect(host: host, port: port)

        // Update device state
        targetDevice.isConnected = true
        targetDevice.lastSeen = Date()
        connectedDevice = targetDevice

        // Save for future use
        saveHost(host, port: port, name: targetDevice.name)

        print("Connecting to Meshtastic TCP: \(host):\(port)")
    }

    /// Disconnect from current device
    public func disconnect() {
        guard #available(iOS 13.0, *) else { return }

        // Only disconnect the client type we're actually using
        if let device = connectedDevice {
            switch device.connectionType {
            case .bluetooth:
                if let client = _bleClient as? MeshtasticBLEClient {
                    client.disconnect()
                }
            case .tcp:
                if let client = _tcpClient as? MeshtasticTCPClient {
                    client.disconnect()
                }
            }
        }
        // Don't disconnect "just in case" - this causes issues during connection

        connectedDevice = nil
        meshNodes.removeAll()
        myNodeNum = 0
        firmwareVersion = ""
        connectionState = "Disconnected"

        print("Disconnected from Meshtastic")
    }

    /// Send a text message through the mesh
    public func sendMessage(_ text: String, to destination: UInt32 = 0xFFFFFFFF) {
        guard #available(iOS 13.0, *), isConnected else {
            lastError = "Not connected"
            return
        }

        if let device = connectedDevice {
            switch device.connectionType {
            case .bluetooth:
                bleClient.sendTextMessage(text, to: destination)
            case .tcp:
                tcpClient.sendTextMessage(text, to: destination)
            }
        }
    }

    // MARK: - Channels & Settings (OmniTAK-iOS #101)

    /// Operator-managed Meshtastic channels created / imported inside OmniTAK.
    /// The radio does not expose its channel table to us yet, so this is the
    /// app-side working set the Settings screen lists, shares and applies.
    /// Persisted as JSON via @AppStorage.
    @AppStorage("meshtastic_app_channels") private var appChannelsData: Data = Data()

    /// Codable mirror of `MeshChannel` (which lives in a codec file and isn't
    /// Codable) so the operator's channel set survives relaunch.
    public struct StoredChannel: Codable, Identifiable, Equatable {
        public var id: String { "\(index):\(name)" }
        public var index: Int
        public var name: String
        /// PSK as lowercase hex; "" = no crypto.
        public var pskHex: String
        public var isPrimary: Bool

        public init(index: Int, name: String, pskHex: String, isPrimary: Bool) {
            self.index = index
            self.name = name
            self.pskHex = pskHex
            self.isPrimary = isPrimary
        }
    }

    public var appChannels: [StoredChannel] {
        get { (try? JSONDecoder().decode([StoredChannel].self, from: appChannelsData)) ?? [] }
        set { appChannelsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Add or replace a channel in the operator's working set (keyed by index).
    public func upsertAppChannel(_ ch: StoredChannel) {
        var list = appChannels
        if let i = list.firstIndex(where: { $0.index == ch.index }) {
            list[i] = ch
        } else {
            list.append(ch)
        }
        list.sort { $0.index < $1.index }
        appChannels = list
    }

    public func removeAppChannel(index: Int) {
        appChannels = appChannels.filter { $0.index != index }
    }

    /// Translate stored hex PSK into raw bytes (empty for "" / invalid).
    static func pskData(fromHex hex: String) -> Data {
        MeshCoreChannelCodec.dehex(hex) ?? Data()
    }

    /// Build the shareable channel-set URL for the operator's working set
    /// (or a single channel when `only` is supplied).
    public func channelShareURL(only: StoredChannel? = nil) -> String? {
        let source = only.map { [$0] } ?? appChannels
        guard !source.isEmpty else { return nil }
        let channels = source.map {
            MeshChannel(name: $0.name, psk: Self.pskData(fromHex: $0.pskHex))
        }
        return MeshChannelShare.shareURL(transport: .meshtastic, meshtastic: channels)
    }

    /// Apply (write) a channel to the connected radio via AdminMessage.set_channel.
    /// Also records it in the operator's working set. Returns true if dispatched.
    @discardableResult
    public func applyChannel(_ ch: StoredChannel) -> Bool {
        upsertAppChannel(ch)
        guard #available(iOS 13.0, *), isConnected, let device = connectedDevice else {
            lastError = "Not connected"
            return false
        }
        let payload = MeshtasticAdminCodec.encodeSetChannel(
            index: Int32(ch.index),
            name: ch.name,
            psk: Self.pskData(fromHex: ch.pskHex),
            role: ch.isPrimary ? .primary : .secondary
        )
        switch device.connectionType {
        case .bluetooth: return bleClient.sendAdmin(payload: payload)
        case .tcp:       return tcpClient.sendAdmin(payload: payload)
        }
    }

    /// Apply an imported Meshtastic channel-set (from a scanned QR / pasted
    /// link) to the radio. Channels land at indices 1…N as SECONDARY (the
    /// primary index 0 is left untouched). Returns the number applied.
    @discardableResult
    func applyImportedChannels(_ channels: [MeshChannel], startIndex: Int = 1) -> Int {
        var applied = 0
        for (offset, ch) in channels.enumerated() {
            let idx = startIndex + offset
            guard idx <= 7 else { break }
            let stored = StoredChannel(
                index: idx,
                name: ch.name,
                pskHex: MeshCoreChannelCodec.hex(ch.psk),
                isPrimary: false
            )
            if applyChannel(stored) { applied += 1 }
        }
        return applied
    }

    /// Apply device role + rebroadcast scope via AdminMessage.set_config.
    @discardableResult
    func applyDeviceConfig(
        role: MeshtasticAdminCodec.DeviceRole,
        rebroadcastMode: MeshtasticAdminCodec.RebroadcastMode
    ) -> Bool {
        guard #available(iOS 13.0, *), isConnected, let device = connectedDevice else {
            lastError = "Not connected"
            return false
        }
        let payload = MeshtasticAdminCodec.encodeSetDeviceConfig(
            role: role, rebroadcastMode: rebroadcastMode
        )
        switch device.connectionType {
        case .bluetooth: return bleClient.sendAdmin(payload: payload)
        case .tcp:       return tcpClient.sendAdmin(payload: payload)
        }
    }

    /// Apply the position broadcast interval via AdminMessage.set_config.
    @discardableResult
    public func applyPositionBroadcastInterval(seconds: UInt32) -> Bool {
        guard #available(iOS 13.0, *), isConnected, let device = connectedDevice else {
            lastError = "Not connected"
            return false
        }
        let payload = MeshtasticAdminCodec.encodeSetPositionBroadcastInterval(seconds: seconds)
        switch device.connectionType {
        case .bluetooth: return bleClient.sendAdmin(payload: payload)
        case .tcp:       return tcpClient.sendAdmin(payload: payload)
        }
    }

    /// Send a CoT event over the active Meshtastic transport (BLE or TCP) as
    /// a portnum-72 (ATAK_PLUGIN) packet.
    ///
    /// Phase 2 behaviour (TAKPacket interop):
    ///   - `a-*` events → compact TAKPacket PLI (is_compressed=false, raw callsigns).
    ///     Interoperates with stock Meshtastic ATAK Plugin, phone-app TAK role,
    ///     and TAK_Meshtastic_Gateway.
    ///   - `b-t-f` events → compact TAKPacket GeoChat (is_compressed=true,
    ///     unishox2-compressed callsign/message).
    ///   - Other event types → Phase-1 TAKMessage{CoTEvent} path (ATAKPluginSerializer).
    ///     ATAKPluginSerializer remains in the tree as the OmniTAK↔OmniTAK path.
    ///
    /// - Parameters:
    ///   - event: The CoT event to broadcast.
    ///   - channelIndex: Meshtastic channel index (defaults to 0 / primary).
    /// - Returns: true if dispatched to the radio, false if no transport is active.
    @discardableResult
    func sendCoTOverMesh(_ event: CoTEvent, channelIndex: UInt32 = 0) -> Bool {
        guard #available(iOS 13.0, *), isConnected, let device = connectedDevice else {
            lastError = "Not connected"
            return false
        }

        // Format selection (TAKPacket for PLI/GeoChat, TAKPacketV2 for dropped
        // markers, TAKMessage fallback for everything else) is the pure,
        // unit-tested MeshTAKRouting decision.
        let format = MeshTAKRouting.decide(for: event)

        // Dropped-marker (port 78) path: encode the v2 marker and ship it on
        // PortNum 78 with a config hop limit and no broadcast ACK. Throttle
        // repeats of the same uid so an edit/re-broadcast storm doesn't flood
        // the LoRa channel; the first send of any uid is always allowed.
        if format == .takPacketV2, let v2Payload = TAKPacketV2Codec.encodeMarker(event) {
            if let last = lastMarkerSendTimes[event.uid],
               Date().timeIntervalSince(last) < markerSendThrottle {
                #if DEBUG
                print("⏳ Throttled marker mesh send for uid \(event.uid) (within \(Int(markerSendThrottle))s)")
                #endif
                return false
            }
            lastMarkerSendTimes[event.uid] = Date()

            let hop = UInt32(max(1, markerHopLimit))
            switch device.connectionType {
            case .bluetooth:
                return bleClient.sendATAKPlugin(
                    payload: v2Payload, channel: channelIndex,
                    portnum: TAKPacketV2Codec.portnum, hopLimit: hop, wantAck: false
                )
            case .tcp:
                return tcpClient.sendATAKPlugin(
                    payload: v2Payload, channel: channelIndex,
                    portnum: TAKPacketV2Codec.portnum, hopLimit: hop, wantAck: false
                )
            }
        }

        // v1 / fallback path (PLI, GeoChat, TAKMessage) — port 72.
        let payload = MeshTAKRouting.encodePayload(for: event)
            ?? ATAKPluginSerializer.serialize(event)

        switch device.connectionType {
        case .bluetooth:
            return bleClient.sendATAKPlugin(payload: payload, channel: channelIndex)
        case .tcp:
            return tcpClient.sendATAKPlugin(payload: payload, channel: channelIndex)
        }
    }

    // MARK: - Status Properties

    /// Check if device is connected
    public var isConnected: Bool {
        connectedDevice?.isConnected ?? false
    }

    /// Get formatted connection status
    public var connectionStatus: String {
        if let device = connectedDevice, device.isConnected {
            return "Connected: \(device.name)"
        }
        return "Not Connected"
    }

    // MARK: - TAK Map Integration

    /// Callback for when CoT events are generated from mesh nodes (XML format)
    public var onCoTGenerated: ((String) -> Void)?

    /// Whether automatic map updates are enabled
    @Published public var autoMapUpdateEnabled: Bool = true

    private var mapUpdateCancellable: AnyCancellable?

    /// Publish all mesh nodes with positions to the TAK map.
    /// Routed through CoTEventHandler.handle so the events land in the
    /// rendered store (TAKService.cotEvents) — same path as inbound CoT.
    /// Defaults key for the "Paired radios" visibility toggle in Meshtastic
    /// settings. Off by default — see `mapVisibleNodes(_:showPairedRadios:)`.
    public static let showPairedRadiosKey = "showPairedRadios"

    /// Radio link state, for the always-visible dot on the Meshtastic tool.
    /// Field feedback asked one question the UI could not answer at a glance:
    /// "is a radio even connected?"
    public enum LinkState {
        case connected, connecting, failed, noDevice
    }

    /// Mirrors the Android status dot: green connected, amber connecting,
    /// red failed, grey no device.
    public var linkState: LinkState {
        switch connectionState {
        case "Connected":
            return .connected
        case "Connecting...", "Discovering Services...", "Scanning...":
            return .connecting
        case "Connection Failed":
            return .failed
        default:
            return .noDevice
        }
    }

    /// The nodes that belong on the map.
    ///
    /// A radio in role `TAK` is paired to a phone that is already publishing
    /// that operator's own position, so rendering the radio as well shows one
    /// person as two dots that drift apart. Those stay hidden unless the
    /// operator opts in. Standalone trackers — `TAK_TRACKER`, sensors,
    /// vehicles — are genuinely separate contacts and always ride along.
    nonisolated public static func mapVisibleNodes(_ nodes: [MeshNode], showPairedRadios: Bool? = nil) -> [MeshNode] {
        let show = showPairedRadios ?? UserDefaults.standard.bool(forKey: showPairedRadiosKey)
        guard !show else { return nodes }
        return nodes.filter { !$0.isTakPaired }
    }

    public func publishMeshNodesToMap() {
        let visible = MeshtasticManager.mapVisibleNodes(meshNodes)
        let cotEvents = MeshtasticCoTConverter.toCoTEvents(nodes: visible, ownNodeId: myNodeNum)
        for event in cotEvents {
            // #180 — these arrived over the Meshtastic mesh, not a TAK server.
            CoTEventHandler.shared.handle(event: .positionUpdate(event), source: .mesh("Meshtastic"))
        }
        print("📍 Published \(cotEvents.count) mesh nodes to TAK map")
    }

    /// Publish a single node to the TAK map
    public func publishNodeToMap(_ node: MeshNode) {
        guard !MeshtasticManager.mapVisibleNodes([node]).isEmpty else { return }
        let isOwn = node.id == myNodeNum
        if let event = MeshtasticCoTConverter.toCoTEvent(node: node, isOwnNode: isOwn) {
            CoTEventHandler.shared.handle(event: .positionUpdate(event), source: .mesh("Meshtastic"))
            print("📍 Published node \(node.shortName) to TAK map")
        }
    }

    /// Generate CoT XML for all mesh nodes with positions
    public func publishMeshNodesToCoT() {
        let cotEvents = MeshtasticCoTConverter.generateCoTForAllNodes(meshNodes)
        for cotXML in cotEvents {
            onCoTGenerated?(cotXML)
        }
        print("Published \(cotEvents.count) mesh nodes as CoT XML")
    }

    /// Generate CoT XML for a specific node
    public func generateCoT(for node: MeshNode) -> String? {
        return MeshtasticCoTConverter.generateCoT(for: node)
    }

    /// Get nodes with valid positions
    public var nodesWithPositions: [MeshNode] {
        meshNodes.filter { $0.position != nil }
    }

    /// Enable automatic publishing of mesh nodes to TAK map when nodes are updated
    public func enableAutoMapUpdates() {
        guard autoMapUpdateEnabled else { return }

        mapUpdateCancellable?.cancel()

        // Subscribe to node changes and publish to map
        mapUpdateCancellable = $meshNodes
            .receive(on: DispatchQueue.main)
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] nodes in
                guard let self = self, self.autoMapUpdateEnabled else { return }
                if !nodes.isEmpty {
                    self.publishMeshNodesToMap()
                }
            }
        print("🗺️ Auto map updates enabled for Meshtastic nodes")
    }

    /// Disable automatic map updates
    public func disableAutoMapUpdates() {
        mapUpdateCancellable?.cancel()
        mapUpdateCancellable = nil
        print("🗺️ Auto map updates disabled")
    }

    /// Remove all Meshtastic markers from TAK map
    public func clearMeshMarkersFromMap() {
        for node in meshNodes {
            CoTEventHandler.shared.removeEvent(uid: node.takUID)
        }
        print("🗺️ Removed \(meshNodes.count) mesh markers from map")
    }
}
