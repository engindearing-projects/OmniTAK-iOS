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
    /// chose reported them in its last config download. A settings write changes
    /// one field of these and sends the rest back, so nothing is written until
    /// they are known (#148). Emptied when that connection drops or is replaced,
    /// and when a new download starts.
    @Published private(set) var radioSettings = MeshtasticRadioSettings()

    /// What is known about the channel writes of this connection: sent, and then
    /// applied or not once the radio's answer to a read-back request is in.
    @Published private(set) var channelReports: [MeshtasticChannelReport] = []

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

    /// Where a settings write goes instead of the connected client. For tests,
    /// to see what would be sent without a radio. Nil in the app.
    var adminLinkOverride: MeshtasticAdminLink?

    /// How long to wait for the radio to answer a channel read-back, in seconds.
    var readBackTimeout: TimeInterval = 8

    private struct PendingReadBack {
        let token: Int
        let name: String
        let expected: MeshtasticAdminCodec.ChannelSummary
    }
    private var pendingReadBacks: [Int: PendingReadBack] = [:]
    private var nextReadBackToken = 0

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
        pendingReadBacks.removeAll()
        channelReports.removeAll()
        activeLink = link
        myNodeNum = 0
        firmwareVersion = ""
        meshNodes.removeAll()
        connectedDevice = device
    }

    /// The connection of this transport came up.
    private func handleLinkUp(_ transport: MeshtasticConnectionType) {
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
        // A channel write the radio never answered will not be answered now.
        for slot in pendingReadBacks.keys.sorted() {
            if let pending = pendingReadBacks.removeValue(forKey: slot) {
                setChannelReport(slot: slot, name: pending.name, state: .noAnswer)
            }
        }
    }

    /// A settings frame from a connection, or the start of a config download.
    /// The clients send these on the main queue, in the order the frames came.
    /// Only the connection the operator chose is listened to.
    func handleLinkEvent(_ linkEvent: MeshtasticLinkEvent) {
        guard let link = activeLink,
              linkEvent.transport == link.transport,
              linkEvent.connection == link.connection else { return }
        radioSettings.apply(linkEvent.event)
        // Only an answer from the radio these settings are from settles a write.
        if case .channelReadBack(let node, let body) = linkEvent.event, node == radioSettings.nodeNum {
            settleReadBack(body: body)
        }
    }

    /// A settings event as if the connection the operator chose had delivered
    /// it. For tests.
    func handleSettingsEvent(_ event: MeshtasticRadioSettings.Event) {
        guard let link = activeLink else { return }
        handleLinkEvent(MeshtasticLinkEvent(transport: link.transport, connection: link.connection, event: event))
    }

    private func forgetRadioSettings() {
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
        pendingReadBacks.removeAll()
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

    // MARK: - Writing radio settings (OmniTAK-iOS #148)
    //
    // The radio replaces a whole sub-config (or channel) with the set_config
    // (or set_channel) it receives. Every write below therefore starts from the
    // bytes the radio reported for that sub-config or channel, changes the
    // fields the operator edited, and sends the whole thing.
    //
    // Whose bytes. The settings belong to one connection: the one the operator
    // chose, which delivered a `my_info` naming the radio. A write is built from
    // them, addressed to that radio, and sent down that connection, and the
    // client refuses it if either has changed. When the settings, the radio's
    // node number or the connection are not known, nothing is sent and the
    // result says why. There is no write built from scratch, except a new
    // channel in a slot the radio itself reports as disabled.
    //
    // What "sent" means. It means dispatched. The entries a write touched are
    // dropped from the settings, not updated to what was sent: the radio may
    // not do it, and a role change makes the firmware install that role's
    // defaults. A config comes back in the download after the radio's restart.
    // A channel is read back (`get_channel_request`), and only the radio's own
    // answer decides whether it is reported applied.

    /// Where a write built from the current settings goes.
    private struct Route {
        let link: MeshtasticAdminLink
        let connection: Int
        let node: UInt32
    }

    private enum Routing {
        case go(Route)
        case stop(String)
    }

    /// The route a write takes, or why there is none.
    private func route() -> Routing {
        guard let active = activeLink, isConnected else {
            return .stop(MeshtasticWriteResult.notConnected)
        }
        // The radio the settings are from, on the connection they came from.
        guard let node = radioSettings.nodeNum else {
            return .stop(MeshtasticWriteResult.notLoaded)
        }
        guard let link = adminLink(for: active) else {
            return .stop(MeshtasticWriteResult.notConnected)
        }
        guard link.connectionSerial == active.connection else {
            return .stop(MeshtasticWriteResult.linkChanged)
        }
        return .go(Route(link: link, connection: active.connection, node: node))
    }

    /// The client of the chosen connection, or the test stand-in. Never one that
    /// is made for the occasion: a write only goes down a connection that exists.
    private func adminLink(for active: ActiveLink) -> MeshtasticAdminLink? {
        if let adminLinkOverride { return adminLinkOverride }
        guard #available(iOS 13.0, *) else { return nil }
        switch active.transport {
        case .bluetooth: return _bleClient as? MeshtasticBLEClient
        case .tcp:       return _tcpClient as? MeshtasticTCPClient
        }
    }

    private func refuseWrite(_ reason: String) -> MeshtasticWriteResult {
        lastError = reason
        return .refused(reason)
    }

    // MARK: Device role, rebroadcast scope and position interval

    /// Apply device role + rebroadcast scope via AdminMessage.set_config.
    /// A nil argument leaves that field as the radio has it, and so does a value
    /// the radio already has: only a field that differs is written. The rest of
    /// the device config (time zone, LED, button, buzzer) stays as the radio has
    /// it. When nothing differs, nothing is sent (`.unchanged`). After a write
    /// the device config is dropped until the radio restarts and the next
    /// download brings it back.
    @discardableResult
    func applyDeviceConfig(
        role: MeshtasticAdminCodec.DeviceRole?,
        rebroadcastMode: MeshtasticAdminCodec.RebroadcastMode?
    ) -> MeshtasticWriteResult {
        writeConfig(variant: MeshtasticAdminCodec.ConfigVariant.device) {
            MeshtasticAdminCodec.encodeSetDeviceConfig(current: $0, role: role, rebroadcastMode: rebroadcastMode)
        }
    }

    /// Apply the position broadcast interval via AdminMessage.set_config. The
    /// rest of the position config (GPS mode, position flags, smart broadcast)
    /// stays as the radio has it. When the radio already has this interval,
    /// nothing is sent (`.unchanged`). After a write the position config is
    /// dropped until the radio restarts and the next download brings it back.
    @discardableResult
    public func applyPositionBroadcastInterval(seconds: UInt32) -> MeshtasticWriteResult {
        writeConfig(variant: MeshtasticAdminCodec.ConfigVariant.position) {
            MeshtasticAdminCodec.encodeSetPositionBroadcastInterval(current: $0, seconds: seconds)
        }
    }

    private func writeConfig(
        variant: Int,
        build: (Data) -> MeshtasticAdminCodec.Write?
    ) -> MeshtasticWriteResult {
        let route: Route
        switch self.route() {
        case .stop(let reason): return refuseWrite(reason)
        case .go(let found): route = found
        }
        guard let current = radioSettings.config(variant: variant) else {
            return refuseWrite(radioSettings.isAwaitingRestart(variant: variant)
                ? MeshtasticWriteResult.restarting
                : MeshtasticWriteResult.notLoaded)
        }
        guard let write = build(current) else {
            return refuseWrite(MeshtasticWriteResult.notLoaded)
        }
        guard !write.changesNothing else {
            return .unchanged
        }
        guard route.link.sendAdmin(payload: write.payload, to: route.node,
                                   connection: route.connection, wantResponse: false) else {
            return refuseWrite(MeshtasticWriteResult.linkChanged)
        }
        // Sent is all that is known. The radio restarts to apply a config, and
        // what it holds afterwards comes with the next download.
        radioSettings.invalidateConfig(variant: variant)
        return .sent
    }

    // MARK: Channels

    /// What came of a request to put a channel on the radio.
    struct ChannelOutcome: Equatable {
        let result: MeshtasticWriteResult
        /// The slot written to, or nil when nothing was sent.
        let slot: Int?
    }

    /// What came of importing a set of channels.
    struct ImportOutcome: Equatable {
        /// The slots written to, in order.
        var sent: [Int] = []
        /// Channels the radio already has under that name and key.
        var alreadyThere = 0
        /// Channels left out because the radio has no free slot for them.
        var noRoom = 0
        /// Channels left out because they cannot be written, and why.
        var skipped: [String] = []
        /// Why nothing could be sent at all, when that is the case.
        var refusal: String?
    }

    /// Create a channel from what the operator typed.
    ///
    /// - The name is at most 11 bytes: the radio drops the whole message for a
    ///   longer one.
    /// - The key is hex or base64 of 1, 16 or 32 bytes. Blank is not "no key":
    ///   with `noEncryption` it is an open channel, chosen on purpose; when
    ///   replacing the primary it keeps the radio's key; for a new channel it is
    ///   refused. Something that is not a key is refused, never turned into none.
    /// - A new channel goes into the first slot the radio reports as disabled
    ///   and inherits nothing from the slot's old occupant. The primary is only
    ///   written when `replacePrimary` is set, which is the operator's explicit
    ///   choice, and then only its name and, if one was typed, its key change.
    func createChannel(
        name rawName: String,
        keyText: String,
        noEncryption: Bool,
        replacePrimary: Bool
    ) -> ChannelOutcome {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let problem = Self.channelNameProblem(name) { return refuseChannel(problem) }

        let key: MeshtasticAdminCodec.KeyChange
        switch MeshtasticChannelKey.parse(keyText) {
        case .invalid(let reason):
            return refuseChannel(reason)
        case .key(let bytes):
            if noEncryption { return refuseChannel("Enter a key or choose No encryption, not both.") }
            key = .set(bytes)
        case .blank:
            if noEncryption {
                key = .clear
            } else if replacePrimary {
                key = .keep
            } else {
                return refuseChannel("Enter a key (hex or base64), or choose No encryption for an open channel.")
            }
        }

        let route: Route
        switch self.route() {
        case .stop(let reason): return refuseChannel(reason)
        case .go(let found): route = found
        }

        let slot: Int
        let write: MeshtasticAdminCodec.Write
        let expected: MeshtasticAdminCodec.ChannelSummary

        if replacePrimary {
            slot = 0
            guard let summary = radioSettings.channelSummary(index: 0), !summary.isDisabled,
                  let current = radioSettings.channel(index: 0) else {
                return refuseChannel(radioSettings.isAwaitingReadBack(index: 0)
                    ? "Slot 0 was just written. Wait for the radio to confirm it."
                    : MeshtasticWriteResult.notLoaded)
            }
            guard let built = MeshtasticAdminCodec.encodeSetChannel(
                current: current, name: name, key: key, role: .primary) else {
                return refuseChannel(MeshtasticWriteResult.notLoaded)
            }
            write = built
            let psk: Data
            switch key {
            case .keep: psk = summary.psk
            case .set(let bytes): psk = bytes
            case .clear: psk = Data()
            }
            expected = MeshtasticAdminCodec.ChannelSummary(index: 0, name: name, psk: psk, role: MeshtasticAdminCodec.ChannelRole.primary.rawValue)
        } else {
            guard let free = radioSettings.freeChannelSlots.first,
                  let current = radioSettings.channel(index: free) else {
                return refuseChannel("No free channel slot. All seven secondary slots on this radio are in use.")
            }
            slot = free
            let psk: Data
            if case .set(let bytes) = key { psk = bytes } else { psk = Data() }
            guard let built = MeshtasticAdminCodec.encodeNewChannel(index: free, current: current, name: name, psk: psk) else {
                return refuseChannel(MeshtasticWriteResult.notLoaded)
            }
            write = built
            expected = MeshtasticAdminCodec.ChannelSummary(index: free, name: name, psk: psk, role: MeshtasticAdminCodec.ChannelRole.secondary.rawValue)
        }

        guard !write.changesNothing else {
            return ChannelOutcome(result: .unchanged, slot: slot)
        }
        guard route.link.sendAdmin(payload: write.payload, to: route.node,
                                   connection: route.connection, wantResponse: false) else {
            return refuseChannel(MeshtasticWriteResult.linkChanged)
        }
        afterChannelSend(route: route, slot: slot, name: name, expected: expected)

        // The working set lists what the app can share, so only a channel whose
        // key is known goes in it.
        switch key {
        case .set(let bytes):
            upsertAppChannel(StoredChannel(index: slot, name: name, pskHex: MeshCoreChannelCodec.hex(bytes), isPrimary: slot == 0))
        case .clear:
            upsertAppChannel(StoredChannel(index: slot, name: name, pskHex: "", isPrimary: slot == 0))
        case .keep:
            break
        }
        return ChannelOutcome(result: .sent, slot: slot)
    }

    /// Apply an imported Meshtastic channel-set (from a scanned QR / pasted
    /// link) to the radio.
    ///
    /// Each channel goes into a slot the radio reports as disabled, in order,
    /// and inherits nothing from the slot's old occupant. The primary is never
    /// touched, and no slot in use is overwritten. A channel the radio already
    /// has under that name and key is not added again. When there are more
    /// channels than free slots the rest are left out and counted.
    func importChannels(_ channels: [MeshChannel]) -> ImportOutcome {
        var outcome = ImportOutcome()
        let route: Route
        switch self.route() {
        case .stop(let reason):
            lastError = reason
            outcome.refusal = reason
            return outcome
        case .go(let found):
            route = found
        }

        var free = radioSettings.freeChannelSlots
        var sentThisTime: [(name: String, key: Data)] = []

        for channel in channels {
            let name = channel.name
            if let problem = Self.channelNameProblem(name) {
                outcome.skipped.append(problem)
                continue
            }
            guard channel.psk.isEmpty || MeshtasticChannelKey.validLengths.contains(channel.psk.count) else {
                outcome.skipped.append("\"\(name)\" has a key of \(channel.psk.count) bytes. A key is 1, 16 or 32 bytes.")
                continue
            }
            if radioSettings.slotHolding(name: name, key: channel.psk) != nil
                || sentThisTime.contains(where: { $0.name == name && $0.key == channel.psk }) {
                outcome.alreadyThere += 1
                continue
            }
            guard let slot = free.first else {
                outcome.noRoom += 1
                continue
            }
            guard let current = radioSettings.channel(index: slot),
                  let write = MeshtasticAdminCodec.encodeNewChannel(index: slot, current: current, name: name, psk: channel.psk) else {
                outcome.skipped.append("\"\(name)\": slot \(slot) is not in a state this app can write to.")
                free.removeFirst()
                continue
            }
            guard route.link.sendAdmin(payload: write.payload, to: route.node,
                                       connection: route.connection, wantResponse: false) else {
                outcome.refusal = MeshtasticWriteResult.linkChanged
                lastError = MeshtasticWriteResult.linkChanged
                break
            }
            free.removeFirst()
            let expected = MeshtasticAdminCodec.ChannelSummary(
                index: slot, name: name, psk: channel.psk, role: MeshtasticAdminCodec.ChannelRole.secondary.rawValue)
            afterChannelSend(route: route, slot: slot, name: name, expected: expected)
            upsertAppChannel(StoredChannel(index: slot, name: name, pskHex: MeshCoreChannelCodec.hex(channel.psk), isPrimary: false))
            outcome.sent.append(slot)
            sentThisTime.append((name, channel.psk))
        }
        return outcome
    }

    /// The reason a channel name cannot be written, or nil. The radio drops the
    /// whole message for a name over 11 bytes, so it is refused here, and the
    /// operator is told why.
    static func channelNameProblem(_ name: String) -> String? {
        let bytes = name.utf8.count
        guard bytes > MeshtasticAdminCodec.maxChannelNameBytes else { return nil }
        return "Channel names are at most \(MeshtasticAdminCodec.maxChannelNameBytes) bytes. "
            + "\"\(name)\" is \(bytes). The radio would drop the whole message."
    }

    private func refuseChannel(_ reason: String) -> ChannelOutcome {
        ChannelOutcome(result: refuseWrite(reason), slot: nil)
    }

    // MARK: Reading a channel back

    /// A channel write was sent. Forget what the radio said about the slot, ask
    /// it what it holds now, and wait for the answer.
    private func afterChannelSend(
        route: Route,
        slot: Int,
        name: String,
        expected: MeshtasticAdminCodec.ChannelSummary
    ) {
        radioSettings.invalidateChannel(index: slot)
        nextReadBackToken += 1
        let token = nextReadBackToken
        pendingReadBacks[slot] = PendingReadBack(token: token, name: name, expected: expected)
        setChannelReport(slot: slot, name: name, state: .sent)

        let request = MeshtasticAdminCodec.encodeGetChannelRequest(index: slot)
        guard route.link.sendAdmin(payload: request, to: route.node,
                                   connection: route.connection, wantResponse: true) else {
            pendingReadBacks[slot] = nil
            setChannelReport(slot: slot, name: name, state: .noAnswer)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + readBackTimeout) { [weak self] in
            self?.readBackTimedOut(slot: slot, token: token)
        }
    }

    /// The radio answered a read-back request. It is reported applied only when
    /// what it holds is what was asked for; otherwise the radio kept its own.
    private func settleReadBack(body: Data) {
        guard let answer = MeshtasticAdminCodec.channelSummary(in: body),
              let pending = pendingReadBacks.removeValue(forKey: answer.index) else { return }
        let matches = answer.name == pending.expected.name
            && answer.psk == pending.expected.psk
            && answer.role == pending.expected.role
        setChannelReport(slot: answer.index, name: pending.name, state: matches ? .applied : .radioKept(answer.name))
    }

    private func readBackTimedOut(slot: Int, token: Int) {
        guard let pending = pendingReadBacks[slot], pending.token == token else { return }
        pendingReadBacks[slot] = nil
        setChannelReport(slot: slot, name: pending.name, state: .noAnswer)
    }

    private func setChannelReport(slot: Int, name: String, state: MeshtasticChannelReport.State) {
        var reports = channelReports.filter { $0.slot != slot }
        reports.append(MeshtasticChannelReport(slot: slot, name: name, state: state))
        reports.sort { $0.slot < $1.slot }
        channelReports = reports
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
