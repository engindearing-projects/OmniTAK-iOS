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

    // MARK: - Mesh conversation helpers (GAP-122 / GAP-124)
    // These are pure-function helpers — no actor state — so callers from any
    // isolation can construct / parse the conversation IDs without hopping.

    /// Conversation id used by ChatManager to bucket incoming mesh text by channel.
    public nonisolated static func meshConversationId(channelIndex: Int) -> String {
        return "MESH-CH\(channelIndex)"
    }

    /// GAP-124 — conversation id for directed mesh text. Both my outgoing
    /// DM to node X and X's reply to me bucket into the same conversation.
    public nonisolated static func meshDmConversationId(nodeId: UInt32) -> String {
        return String(format: "MESH-DM-%08X", nodeId)
    }

    /// True if a conversation id targets the Meshtastic mesh (channel or DM).
    public nonisolated static func isMeshConversation(_ conversationId: String) -> Bool {
        return conversationId.hasPrefix("MESH-CH") || conversationId.hasPrefix("MESH-DM-")
    }

    /// Parse a `MESH-DM-{nodeIdHex}` conversation id back into a nodenum.
    public nonisolated static func meshDmNodeNum(from conversationId: String) -> UInt32? {
        guard conversationId.hasPrefix("MESH-DM-") else { return nil }
        let hex = String(conversationId.dropFirst("MESH-DM-".count))
        return UInt32(hex, radix: 16)
    }

    /// Parse a `MESH-CHn` conversation id back into a channel index.
    public nonisolated static func meshChannelIndex(from conversationId: String) -> UInt32? {
        guard conversationId.hasPrefix("MESH-CH") else { return nil }
        let n = String(conversationId.dropFirst("MESH-CH".count))
        return UInt32(n)
    }

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

    // MARK: - Initialization

    public init() {
        // TCP and BLE clients are lazily initialized when needed
        // Configure COT bridge to convert mesh nodes to map markers
        configureCOTBridge()
    }

    /// Configure the COT bridge for converting Meshtastic data to TAK format
    private func configureCOTBridge() {
        MeshtasticCOTBridge.shared.configure(meshtasticManager: self)
        print("MeshtasticManager: COT bridge configured")
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

        // GAP-122 / GAP-124 — incoming mesh text → ChatManager
        client.meshTextSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handleIncomingMeshText(event) }
            .store(in: &tcpClientCancellables)

        // GAP-109 / GAP-123 — admin responses → MeshDeviceConfigStore + channel seed
        client.adminResponseSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in self?.handleAdminResponse(response) }
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

        // GAP-122 / GAP-124 — incoming mesh text → ChatManager
        client.meshTextSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in self?.handleIncomingMeshText(event) }
            .store(in: &bleClientCancellables)

        // GAP-109 / GAP-123 — admin responses → MeshDeviceConfigStore + channel seed
        client.adminResponseSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in self?.handleAdminResponse(response) }
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

    /// Send a CoT event over the active Meshtastic transport (BLE or TCP) as
    /// a portnum-72 (ATAK_PLUGIN) packet.
    /// - Parameters:
    ///   - event: The CoT event to broadcast.
    ///   - channelIndex: Meshtastic channel index (defaults to 0 / primary).
    /// - Returns: true if dispatched to the radio, false if no transport is active.
    /// - Note: declared `internal` (not `public`) because `CoTEvent` is internal.
    ///   TODO: widen `CoTEvent` to `public` so this entry point can be used
    ///   from external Swift packages / framework consumers.
    @discardableResult
    func sendCoTOverMesh(_ event: CoTEvent, channelIndex: UInt32 = 0) -> Bool {
        guard #available(iOS 13.0, *), isConnected, let device = connectedDevice else {
            lastError = "Not connected"
            return false
        }

        let payload = ATAKPluginSerializer.serialize(event)
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

    /// Publish all mesh nodes with positions to the TAK map
    public func publishMeshNodesToMap() {
        let cotEvents = MeshtasticCoTConverter.toCoTEvents(nodes: meshNodes, ownNodeId: myNodeNum)
        for event in cotEvents {
            TAKService.shared.updateEnhancedMarker(from: event)
        }
        print("📍 Published \(cotEvents.count) mesh nodes to TAK map")
    }

    /// Publish a single node to the TAK map
    public func publishNodeToMap(_ node: MeshNode) {
        let isOwn = node.id == myNodeNum
        if let event = MeshtasticCoTConverter.toCoTEvent(node: node, isOwnNode: isOwn) {
            TAKService.shared.updateEnhancedMarker(from: event)
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
        // TAKService uses enhancedMarkers dictionary with UID as key
        // We'd need TAKService to expose a remove method, but for now just let them expire
        // meshNodes count: \(meshNodes.count) markers will expire
        print("🗺️ Mesh markers will expire from map")
    }

    // MARK: - GAP-122 / GAP-124 — Mesh text routing

    /// Send a text message over the active Meshtastic transport on the
    /// requested channel. Pass `toNodeId` to send a directed packet (DM);
    /// otherwise broadcasts to the channel. Returns true on wire-layer
    /// dispatch — does NOT wait for radio ack.
    @discardableResult
    public func sendMeshChat(text: String, channelIndex: UInt32 = 0, toNodeId: UInt32? = nil) -> Bool {
        guard #available(iOS 13.0, *), isConnected, !text.isEmpty else { return false }
        let dest = toNodeId ?? 0xFFFFFFFF
        guard let device = connectedDevice else { return false }
        switch device.connectionType {
        case .tcp:
            return tcpClient.sendMeshText(text, to: dest, channel: channelIndex)
        case .bluetooth:
            return bleClient.sendMeshText(text, to: dest, channel: channelIndex)
        }
    }

    /// Process an incoming mesh text packet — bucket into the appropriate
    /// MESH-CH<n> or MESH-DM-<id> conversation, drop self-echo, and forward
    /// to ChatManager.
    fileprivate func handleIncomingMeshText(_ event: MeshTextEvent) {
        // Echo skip: outgoing text round-trips with from == myNodeNum.
        if myNodeNum != 0 && event.from == myNodeNum { return }

        let isBroadcast = event.to == 0xFFFFFFFF
        let isDirectedToMe = !isBroadcast && myNodeNum != 0 && event.to == myNodeNum
        let conversationId: String
        if isDirectedToMe {
            conversationId = Self.meshDmConversationId(nodeId: event.from)
        } else {
            conversationId = Self.meshConversationId(channelIndex: Int(event.channel))
        }

        let node = meshNodes.first(where: { $0.id == event.from })
        let callsign = node.flatMap { n -> String? in
            if !n.longName.isEmpty { return n.longName }
            if !n.shortName.isEmpty { return n.shortName }
            return nil
        } ?? String(format: "Node %08X", event.from)

        let senderId = String(format: "MESHTASTIC-%08X", event.from)

        ensureMeshConversation(id: conversationId, isDm: isDirectedToMe, peerCallsign: callsign, peerId: senderId)

        let message = ChatMessage(
            conversationId: conversationId,
            senderId: senderId,
            senderCallsign: callsign,
            messageText: event.text,
            timestamp: Date(),
            status: .delivered,
            type: .text,
            isFromSelf: false
        )
        ChatManager.shared.receiveMessage(message)
    }

    /// Create the chat conversation if it doesn't exist yet, so the Chat
    /// tab has a target before the first incoming/outgoing message lands.
    fileprivate func ensureMeshConversation(id: String, isDm: Bool, peerCallsign: String, peerId: String) {
        let manager = ChatManager.shared
        if manager.conversations.contains(where: { $0.id == id }) { return }
        let title: String
        var participants: [ChatParticipant] = []
        if isDm {
            title = "DM: \(peerCallsign)"
            participants = [ChatParticipant(id: peerId, callsign: peerCallsign)]
        } else if id.hasPrefix("MESH-CH") {
            let n = id.dropFirst("MESH-CH".count)
            title = "Mesh: Channel \(n)"
        } else {
            title = id
        }
        let convo = Conversation(
            id: id,
            title: title,
            participants: participants,
            isGroupChat: !isDm
        )
        manager.conversations.append(convo)
    }

    // MARK: - GAP-109 / GAP-123 — Admin response routing

    fileprivate func handleAdminResponse(_ response: AdminResponse) {
        // Mirror radio state into the persisted draft.
        MeshDeviceConfigStore.shared.applyAdminResponse(response)

        // GAP-123 — auto-seed / rename a chat conversation per non-disabled channel.
        if case .channel(let index, let name, let role) = response {
            guard role != 0 else { return } // DISABLED — hide
            let id = Self.meshConversationId(channelIndex: index)
            let displayName = name.isEmpty ? "Channel \(index)" : name
            let title = "Mesh: \(displayName)"
            let manager = ChatManager.shared
            if let i = manager.conversations.firstIndex(where: { $0.id == id }) {
                if manager.conversations[i].title != title {
                    manager.conversations[i].title = title
                }
            } else {
                let convo = Conversation(id: id, title: title, isGroupChat: true)
                manager.conversations.append(convo)
            }
        }
    }

    /// GAP-109a — push the operator's draft device config to the connected
    /// Push just the owner name (long + short) without touching role,
    /// PLI, channel, or LoRa preset. Used by the callsign auto-sync that
    /// mirrors the operator's TAK callsign onto the connected mesh node
    /// — same pattern as Android `MeshtasticManager.pushOwnerName`.
    /// Returns true if the bytes hit the wire.
    public func pushOwnerName(longName: String, shortName: String) async -> Bool {
        guard #available(iOS 13.0, *), isConnected, let device = connectedDevice else { return false }
        let bytes = AdminMessageSerializer.buildSetOwner(longName: longName, shortName: shortName)
        switch device.connectionType {
        case .tcp:
            tcpClient.sendToRadio(bytes)
            return true
        case .bluetooth:
            return bleClient.sendToRadio(bytes)
        }
    }

    /// radio via portnum-6 (ADMIN_APP) AdminMessage payloads. Returns the
    /// count of messages that landed at the wire layer (0..5).
    public func pushDeviceConfig(_ config: MeshDeviceConfig) async -> Int {
        guard #available(iOS 13.0, *), isConnected, let device = connectedDevice else { return 0 }
        let messages: [Data] = [
            AdminMessageSerializer.buildSetOwner(longName: config.longName, shortName: config.shortName),
            AdminMessageSerializer.buildSetDeviceRole(config.role),
            AdminMessageSerializer.buildSetPositionBroadcastSecs(config.positionBroadcastSecs),
            AdminMessageSerializer.buildSetChannel0Name(config.channelName),
            AdminMessageSerializer.buildSetLoraPreset(config.channelPreset),
        ]
        var sent = 0
        for bytes in messages {
            let ok: Bool
            switch device.connectionType {
            case .tcp:
                tcpClient.sendToRadio(bytes); ok = true
            case .bluetooth:
                ok = bleClient.sendToRadio(bytes)
            }
            if ok { sent += 1 } else { break }
        }
        return sent
    }

    /// GAP-109/123 — request the radio's current owner / role / PLI / LoRa
    /// preset / 8 channel slots. Responses arrive asynchronously via the
    /// admin response subject and fold into MeshDeviceConfigStore.
    @discardableResult
    public func requestDeviceConfig() async -> Int {
        guard #available(iOS 13.0, *), isConnected, let device = connectedDevice else { return 0 }
        var requests: [Data] = [
            AdminMessageSerializer.buildGetOwnerRequest(),
            AdminMessageSerializer.buildGetConfigRequest(configType: AdminMessageSerializer.getConfigDevice),
            AdminMessageSerializer.buildGetConfigRequest(configType: AdminMessageSerializer.getConfigPosition),
            AdminMessageSerializer.buildGetConfigRequest(configType: AdminMessageSerializer.getConfigLora),
        ]
        // 8 channel slots — GAP-123
        for idx in 0..<8 {
            requests.append(AdminMessageSerializer.buildGetChannelRequest(channelIndex: idx))
        }
        var sent = 0
        for bytes in requests {
            let ok: Bool
            switch device.connectionType {
            case .tcp:
                tcpClient.sendToRadio(bytes); ok = true
            case .bluetooth:
                ok = bleClient.sendToRadio(bytes)
            }
            if ok { sent += 1 } else { break }
        }
        return sent
    }
}
