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

    /// The radio's own sub-configs and channels, as the connection the operator
    /// chose last said them: in its config download, and in its answers to the
    /// get requests this app sent. A settings write starts from a fresh answer,
    /// not from this, so this is for what the screen shows and for choosing a
    /// slot (#148). Emptied when that connection drops or is replaced, and when a
    /// new download starts.
    @Published var radioSettings = MeshtasticRadioSettings()

    /// What is known about the channel writes of this connection: sent, and then
    /// applied or not once the radio's answer to a read-back is in.
    @Published var channelReports: [MeshtasticChannelReport] = []

    /// What is known about the config writes (device, position): what was sent,
    /// what the radio answered before it restarted, and what it reports once the
    /// link is back. A config write makes the radio restart, and over Bluetooth
    /// the radio cuts the link as it does, so the answer before the restart may
    /// never come and may not be the last word. These stay when the link is lost
    /// or chosen again, and go when another radio reports in (#153).
    @Published var configReports: [MeshtasticConfigReport] = []

    /// The connection the operator chose: the one transport and, for TCP, the
    /// client's number for that connection. Only its frames fill
    /// `radioSettings`, only its node number is used, and a write goes nowhere
    /// else. A radio that connects in the background (the Bluetooth client
    /// reconnects to the last paired radio on its own) is not this connection.
    struct ActiveLink: Equatable {
        let transport: MeshtasticConnectionType
        let connection: Int
    }
    private(set) var activeLink: ActiveLink?

    // MARK: Talking to the radio's admin module (#148, MeshtasticManager+Settings.swift)

    /// Where a settings write goes instead of the connected client. For tests,
    /// to see what would be sent without a radio. Nil in the app.
    var adminLinkOverride: MeshtasticAdminLink?

    /// How long to wait for the radio to answer a get request, in seconds.
    var answerTimeout: TimeInterval = 8

    /// How long after its deadline an answer to a request is still taken, in
    /// seconds, so that a slow radio's answer is not thrown away.
    var lateAnswerWindow: TimeInterval = 120

    /// The least time between two admin frames on a link, in seconds. The radio
    /// keeps the packets addressed to itself in a queue of four and drops the
    /// oldest when another arrives, so frames sent back to back lose the
    /// earliest ones.
    var frameSpacing: TimeInterval = 0.1

    /// Where the ids of the packets this app sends come from. Tests replace it.
    var requestIDSource: () -> UInt32 = { UInt32.random(in: 1...UInt32.max) }

    /// Get requests that have been sent and not answered, by packet id.
    var outstandingRequests: [UInt32: MeshtasticOutstandingRequest] = [:]
    /// The id of the newest request for each thing, so that an answer to an
    /// older one is not taken for the current state.
    var latestRequestID: [MeshtasticAdminSubject: UInt32] = [:]

    /// A channel write that has been sent and whose read-back has not settled.
    struct PendingChannelWrite {
        let token: Int
        let name: String
        let expected: MeshtasticAdminCodec.ChannelSummary
        let node: UInt32
        /// The entry for the saved list that goes with the write, once the radio
        /// has confirmed it. Nil when the key is not one this app holds.
        let saved: StoredChannel?
        /// True when the write put a new entry in the saved list before it was
        /// sent. An entry that was already there is left as it is until the radio
        /// confirms the new one, so a refused write does not lose it.
        let entryInserted: Bool
    }
    /// By slot. A slot with an entry is not free, and what the entry says is on
    /// its way counts for duplicates.
    var pendingChannelWrites: [Int: PendingChannelWrite] = [:]
    var nextWriteToken = 0

    /// A config write that has been sent. It stays until the radio, connected
    /// again, reports the sub-config in its config download (or another radio
    /// does): the answer before the restart is not the last word.
    struct PendingConfigWrite {
        var token: Int
        let node: UInt32
        let variant: Int
        /// What was sent, merged over the writes since the last download.
        var expected: [MeshtasticConfigField: UInt64]
    }
    /// By sub-config, as its field number inside `Config`.
    var pendingConfigWrites: [Int: PendingConfigWrite] = [:]

    /// One operation at a time uses the link.
    let operationGate = MeshtasticOperationGate()
    /// How many operations are running or waiting.
    @Published var settingsOperations = 0
    /// When the last admin frame went out (`DispatchTime` uptime, nanoseconds).
    var lastFrameTime: UInt64?

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

    /// Use `client` as the TCP client, wired the way `connectTCP` wires the one
    /// it creates. For tests.
    @available(iOS 13.0, *)
    func useTCPClient(_ client: MeshtasticTCPClient) {
        _tcpClient = client
        setupTCPClientObservers()
    }

    /// Use `client` as the Bluetooth client, wired the way `connectBLE` wires the
    /// one it creates. For tests, which feed a client with no radio behind it.
    @available(iOS 13.0, *)
    func useBLEClient(_ client: MeshtasticBLEClient) {
        _bleClient = client
        setupBLEClientObservers()
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

    // MARK: - Which client speaks for the manager (#148)

    /// Whether the client of this transport may change what the manager shows
    /// and holds: the connected state, the node number, the settings. With no
    /// connection chosen either may, as before. With one chosen, only that
    /// transport's client may. A radio that connects in the background must not
    /// replace what the connected radio shows, and its link dropping must not
    /// mark the connected radio disconnected.
    private func speaksForManager(_ transport: MeshtasticConnectionType) -> Bool {
        guard let link = activeLink else { return true }
        return link.transport == transport
    }

    // MARK: - TCP Client Setup

    @available(iOS 13.0, *)
    private func setupTCPClientObservers() {
        guard let client = _tcpClient as? MeshtasticTCPClient else { return }

        // Mirror the link in both directions, as the BLE client does below.
        // The first value this publisher sends is the client's initial "not
        // connected". Marking only the drop left the device not connected for
        // good on the first connection of a session, even with the link up,
        // which refused every settings write ("Not connected") and hid the
        // Meshtastic sections of the settings screen.
        client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (connected: Bool) in
                guard let self = self, self.speaksForManager(.tcp) else { return }
                if connected {
                    self.handleLinkUp(.tcp)
                } else {
                    self.handleLinkDown(.tcp)
                }
            }
            .store(in: &tcpClientCancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (state: MeshtasticTCPClient.ConnectionState) in
                guard let self = self, self.speaksForManager(.tcp) else { return }
                self.connectionState = state.rawValue
            }
            .store(in: &tcpClientCancellables)

        client.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (nodes: [UInt32: MeshNode]) in
                guard let self = self, self.speaksForManager(.tcp) else { return }
                self.meshNodes = Array(nodes.values)
            }
            .store(in: &tcpClientCancellables)

        client.$myNodeNum
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (nodeNum: UInt32) in
                guard let self = self, self.speaksForManager(.tcp) else { return }
                self.myNodeNum = nodeNum
            }
            .store(in: &tcpClientCancellables)

        client.$firmwareVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (version: String) in
                guard let self = self, self.speaksForManager(.tcp) else { return }
                self.firmwareVersion = version
            }
            .store(in: &tcpClientCancellables)

        client.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (error: String?) in
                guard let self = self, self.speaksForManager(.tcp) else { return }
                self.lastError = error
            }
            .store(in: &tcpClientCancellables)

        client.settingsEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleLinkEvent(event)
            }
            .store(in: &tcpClientCancellables)
    }

    // MARK: - The connection the settings belong to (#148)

    /// The operator chose this device on this connection. Whatever was known
    /// about the radio before is dropped, and nothing of the old connection is
    /// carried into the new one: not its settings, not its node number, not its
    /// pending channel writes.
    func beginLink(_ link: ActiveLink, device: MeshtasticDevice) {
        forgetRadioSettings()
        abandonRequests(markPendingWrites: false)
        channelReports.removeAll()
        activeLink = link
        myNodeNum = 0
        firmwareVersion = ""
        meshNodes.removeAll()
        connectedDevice = device
    }

    /// The connection of this transport came up.
    func handleLinkUp(_ transport: MeshtasticConnectionType) {
        guard activeLink?.transport == transport else { return }
        if var device = connectedDevice, device.connectionType == transport {
            device.isConnected = true
            connectedDevice = device
        }
    }

    /// The connection of this transport went down. Only the connection the
    /// operator chose can take the connected radio with it: the other
    /// transport's client dropping a link of its own changes nothing here.
    func handleLinkDown(_ transport: MeshtasticConnectionType) {
        guard activeLink?.transport == transport else { return }
        if var device = connectedDevice, device.connectionType == transport {
            device.isConnected = false
            connectedDevice = device
        }
        // What the radio reported is no longer what it holds: it may be reset
        // or swapped before the link comes back.
        forgetRadioSettings()
        // A request the radio never answered will not be answered now.
        abandonRequests(markPendingWrites: true)
    }

    /// A settings frame from a connection, or the start of a config download.
    /// The clients send these on the main queue, in the order the frames came.
    /// Only the connection the operator chose is listened to.
    func handleLinkEvent(_ linkEvent: MeshtasticLinkEvent) {
        guard let link = activeLink,
              linkEvent.transport == link.transport,
              linkEvent.connection == link.connection else { return }
        if case .answer(let answer) = linkEvent.event {
            acceptAnswer(answer)
            return
        }
        radioSettings.apply(linkEvent.event)
        // What the config download says is checked against what was sent before
        // the radio restarted, and a saved channel from a version that did not
        // record its radio is matched to the slot that holds it.
        switch linkEvent.event {
        case .downloadStarted(let node):
            dropConfigWrites(notFor: node)
            dropChannelWrites(notFor: node)
        case .config(let variant, let body):
            settleConfigWriteAfterRestart(variant: variant, body: body)
        case .channel(let index, let body):
            settleChannelWriteAfterReconnect(slot: index, body: body)
            adoptSavedChannel(slot: index)
        case .answer:
            break
        }
    }

    /// A settings event as if the connection the operator chose had delivered
    /// it. For tests.
    func handleSettingsEvent(_ event: MeshtasticRadioSettings.Event) {
        guard let link = activeLink else { return }
        handleLinkEvent(MeshtasticLinkEvent(transport: link.transport, connection: link.connection, event: event))
    }

    /// The client of the chosen connection, or the test stand-in. Never one that
    /// is made for the occasion: a write only goes down a connection that exists.
    func adminLink(for active: ActiveLink) -> MeshtasticAdminLink? {
        if let adminLinkOverride { return adminLinkOverride }
        guard #available(iOS 13.0, *) else { return nil }
        switch active.transport {
        case .bluetooth: return _bleClient as? MeshtasticBLEClient
        case .tcp:       return _tcpClient as? MeshtasticTCPClient
        }
    }

    func forgetRadioSettings() {
        // Not published when there is nothing to forget.
        if !radioSettings.isEmpty {
            radioSettings.removeAll()
        }
    }

    // MARK: - BLE Client Setup

    @available(iOS 13.0, *)
    private func setupBLEClientObservers() {
        guard let client = _bleClient as? MeshtasticBLEClient else { return }

        client.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (connected: Bool) in
                guard let self = self, self.speaksForManager(.bluetooth) else { return }
                if connected {
                    // Enable auto map updates when connected
                    self.enableAutoMapUpdates()
                    // Update device connection status
                    self.handleLinkUp(.bluetooth)
                } else {
                    self.handleLinkDown(.bluetooth)
                    self.disableAutoMapUpdates()
                }
            }
            .store(in: &bleClientCancellables)

        client.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (state: MeshtasticBLEClient.ConnectionState) in
                guard let self = self, self.speaksForManager(.bluetooth) else { return }
                self.connectionState = state.rawValue
            }
            .store(in: &bleClientCancellables)

        client.$nodes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (nodes: [UInt32: MeshNode]) in
                guard let self = self, self.speaksForManager(.bluetooth) else { return }
                self.meshNodes = Array(nodes.values)
            }
            .store(in: &bleClientCancellables)

        client.$myNodeNum
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (nodeNum: UInt32) in
                guard let self = self, self.speaksForManager(.bluetooth) else { return }
                self.myNodeNum = nodeNum
            }
            .store(in: &bleClientCancellables)

        client.$firmwareVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (version: String) in
                guard let self = self, self.speaksForManager(.bluetooth) else { return }
                self.firmwareVersion = version
            }
            .store(in: &bleClientCancellables)

        client.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] (error: String?) in
                guard let self = self, self.speaksForManager(.bluetooth) else { return }
                self.lastError = error
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

        client.settingsEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleLinkEvent(event)
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

        // One radio at a time. A TCP connection still open is the old radio.
        disconnectOtherTransport(than: .bluetooth)
        beginLink(ActiveLink(transport: .bluetooth, connection: 0), device: meshtasticDevice)
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

        // One radio at a time. A Bluetooth connection still open is the old
        // radio, and keeping it would let its frames land on this one's screen.
        disconnectOtherTransport(than: .tcp)

        // Connect via TCP client. This cancels the connection it had, if any,
        // and numbers the new one. The device is connected once the link is up
        // (`handleLinkUp`), not when it was asked for.
        tcpClient.connect(host: host, port: port)

        targetDevice.isConnected = false
        targetDevice.lastSeen = Date()
        beginLink(ActiveLink(transport: .tcp, connection: tcpClient.connectionSerial), device: targetDevice)

        // Save for future use
        saveHost(host, port: port, name: targetDevice.name)

        print("Connecting to Meshtastic TCP: \(host):\(port)")
    }

    /// Close the connection of the transport the operator did not just choose,
    /// if it has one open. The Bluetooth client reconnects to the last paired
    /// radio by itself, and that radio is not the one being connected to now.
    private func disconnectOtherTransport(than transport: MeshtasticConnectionType) {
        guard #available(iOS 13.0, *) else { return }
        switch transport {
        case .tcp:
            if let client = _bleClient as? MeshtasticBLEClient { client.disconnect() }
        case .bluetooth:
            if let client = _tcpClient as? MeshtasticTCPClient { client.disconnect() }
        }
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

        activeLink = nil
        connectedDevice = nil
        meshNodes.removeAll()
        myNodeNum = 0
        firmwareVersion = ""
        connectionState = "Disconnected"
        forgetRadioSettings()
        abandonRequests(markPendingWrites: false)
        channelReports.removeAll()

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

    /// Channels the operator created or imported inside OmniTAK, the app's own
    /// list, which the Settings screen shows, shares and applies. It is a saved
    /// set, not a view of the radio: an entry is tied to the radio it was written
    /// to, and says whether that radio confirmed it. Persisted as JSON via
    /// @AppStorage.
    @AppStorage("meshtastic_app_channels") private var appChannelsData: Data = Data()

    /// Where a saved channel stands.
    public enum SavedChannelState: String, Codable {
        /// Saved here and never sent to a radio.
        case savedOnly
        /// Sent to the radio; its answer is awaited.
        case sent
        /// The radio's own answer shows it.
        case onRadio
        /// Sent, and the radio did not confirm it.
        case notConfirmed
        /// The radio answered with something else in that slot.
        case radioKept

        public var label: String {
            switch self {
            case .savedOnly:    return "saved only, not on a radio"
            case .sent:         return "sent, waiting for the radio"
            case .onRadio:      return "on the radio"
            case .notConfirmed: return "not confirmed by the radio"
            case .radioKept:    return "refused: the radio kept its own value"
            }
        }
    }

    /// Codable mirror of `MeshChannel` (which lives in a codec file and isn't
    /// Codable) so the operator's channel set survives relaunch.
    public struct StoredChannel: Codable, Identifiable, Equatable {
        public var id: String { "\(nodeNum.map { String($0) } ?? "-"):\(index):\(name)" }
        /// The slot it was written to. -1 for one that was only saved.
        public var index: Int
        public var name: String
        /// The key as the hex of the bytes the radio holds: a private key, one
        /// byte for the open and default keys. "" is no key.
        public var pskHex: String
        public var isPrimary: Bool
        /// The radio it was written to, by node number. Nil: it was only saved.
        public var nodeNum: UInt32?
        /// Where it stands. Nil on an entry saved before this was tracked, which
        /// is shown as saved only.
        public var state: SavedChannelState?

        public init(
            index: Int, name: String, pskHex: String, isPrimary: Bool,
            nodeNum: UInt32? = nil, state: SavedChannelState? = nil
        ) {
            self.index = index
            self.name = name
            self.pskHex = pskHex
            self.isPrimary = isPrimary
            self.nodeNum = nodeNum
            self.state = state
        }

        /// The state, with an entry that has none counted as saved only.
        public var effectiveState: SavedChannelState { state ?? .savedOnly }

        /// What the key amounts to as the radio sees it.
        var keyKind: MeshtasticChannelKey.Kind {
            MeshtasticChannelKey.kind(of: MeshCoreChannelCodec.dehex(pskHex) ?? Data(), isPrimary: isPrimary)
        }
    }

    public var appChannels: [StoredChannel] {
        get { (try? JSONDecoder().decode([StoredChannel].self, from: appChannelsData)) ?? [] }
        set { appChannelsData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    /// Add or replace a channel in the operator's list. A channel written to a
    /// radio is keyed by that radio and the slot; one that was only saved, by its
    /// name. A radio's entry is never replaced by another radio's, and neither is
    /// an entry an earlier version saved from a slot (no radio, but a slot) by one
    /// that was only saved for sharing: that would lose its key.
    public func upsertAppChannel(_ ch: StoredChannel) {
        var list = appChannels
        if let i = list.firstIndex(where: { sameEntry($0, ch) }) {
            list[i] = ch
        } else {
            list.append(ch)
        }
        list.sort { ($0.nodeNum ?? 0, $0.index) < ($1.nodeNum ?? 0, $1.index) }
        appChannels = list
    }

    func sameEntry(_ a: StoredChannel, _ b: StoredChannel) -> Bool {
        if a.nodeNum != b.nodeNum { return false }
        if a.nodeNum != nil { return a.index == b.index }
        // No radio on either. One saved for sharing has no slot; one an earlier
        // version saved has the slot it was written to.
        if (a.index < 0) != (b.index < 0) { return false }
        return a.index < 0 ? a.name == b.name : a.index == b.index
    }

    /// Remove an entry from the list. The channel, if it is on a radio, stays
    /// there.
    public func removeAppChannel(_ ch: StoredChannel) {
        appChannels = appChannels.filter { !sameEntry($0, ch) }
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

    // The settings writes are in MeshtasticManager+Settings.swift.

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
