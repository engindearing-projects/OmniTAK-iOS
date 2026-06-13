//
//  MeshCoreManager.swift
//  OmniTAK Mobile
//
//  App-facing manager for the MeshCore mesh framework. Owns a
//  MeshCoreBLETransport, runs the companion handshake (APP_START), polls the
//  radio for queued frames (GET_NEXT_MSG), keeps a node table, and bridges:
//    - inbound contacts' advertised positions  -> CoT PLI (UID MESHCORE-<key8>)
//    - inbound native text DMs                 -> GeoChat (ChatManager)
//    - OmniTAK self-position                   -> SET_ADVERT_LATLON + SEND_SELF_ADVERT
//    - outbound GeoChat                        -> SEND_TXT_MSG to known contacts
//
//  Mirrors MeshtasticManager's public surface and conforms to MeshManager so the
//  app can treat either framework uniformly.
//

import Foundation
import Combine
import SwiftUI
import CoreBluetooth
import CoreLocation

@available(iOS 13.0, *)
@MainActor
public final class MeshCoreManager: ObservableObject, MeshManager {

    // MARK: Singleton

    public static let shared = MeshCoreManager()

    // MARK: MeshManager / published state

    public var framework: MeshFramework { .meshcore }

    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var connectionState: String = "Disconnected"
    @Published public private(set) var myNodeNum: UInt32 = 0
    @Published public private(set) var meshNodes: [MeshNode] = []
    @Published public private(set) var lastError: String?
    /// Latest battery reading for the connected radio (-1 = unknown).
    @Published public private(set) var batteryPercent: Int = -1

    /// The connected radio's own public key hex (empty until SELF_INFO arrives).
    public private(set) var selfPubKeyHex: String = ""

    // MARK: Transport (lazily created so CBCentralManager isn't spun up at launch)

    private var _transport: Any?

    @available(iOS 13.0, *)
    var transport: MeshCoreBLETransport {
        if _transport == nil {
            let t = MeshCoreBLETransport()
            wire(t)
            _transport = t
        }
        return _transport as! MeshCoreBLETransport
    }

    /// Surface the transport for the device-picker UI (scan/connect/known list).
    @available(iOS 13.0, *)
    var bleTransport: MeshCoreBLETransport { transport }

    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?

    /// Full decoded contact keyed by derived node id — carries the pubkey the
    /// MeshNode model can't, so PLIs get the right MESHCORE-<key8> UID and DMs
    /// can be addressed by pubkey.
    private var contactsByNodeId: [UInt32: MeshCoreContact] = [:]

    private init() {}

    // MARK: Transport wiring

    @available(iOS 13.0, *)
    private func wire(_ t: MeshCoreBLETransport) {
        t.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
                if !connected { self?.handleDisconnected() }
            }
            .store(in: &cancellables)

        t.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.connectionState = state.rawValue }
            .store(in: &cancellables)

        t.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] err in if let err = err { self?.lastError = err } }
            .store(in: &cancellables)

        t.onReady = { [weak self] in self?.handleReady() }
        t.onFrame = { [weak self] frame in self?.handleFrame(frame) }
        t.onDisconnect = { [weak self] in self?.handleDisconnected() }
    }

    // MARK: Connection control (used by the picker UI)

    @available(iOS 13.0, *)
    func startBLEScanning() { lastError = nil; transport.startScanning() }

    @available(iOS 13.0, *)
    func stopBLEScanning() { transport.stopScanning() }

    @available(iOS 13.0, *)
    func refreshKnownBLEDevices() { transport.refreshKnownDevices() }

    @available(iOS 13.0, *)
    func reconnectLastBLEDevice() { transport.reconnectLastDevice() }

    @available(iOS 13.0, *)
    func forgetBLEDevice(id: UUID) { transport.forgetDevice(id: id) }

    @available(iOS 13.0, *)
    func connectBLE(device: DiscoveredBLEDevice) {
        lastError = nil
        transport.connect(to: device)
    }

    public func disconnect() {
        if #available(iOS 13.0, *) { transport.disconnect() }
        stopPolling()
        handleDisconnected()
    }

    private func handleDisconnected() {
        stopPolling()
        isConnected = false
        connectionState = "Disconnected"
        myNodeNum = 0
        batteryPercent = -1
        meshNodes.removeAll()
        contactsByNodeId.removeAll()
    }

    // MARK: Handshake + polling

    private func handleReady() {
        guard #available(iOS 13.0, *) else { return }
        let t = transport
        // APP_START → radio replies SELF_INFO; then identify + battery + first drain.
        t.send(MeshCoreFrameCodec.encodeAppStart())
        t.send(MeshCoreFrameCodec.encodeDeviceQuery())
        t.send(MeshCoreFrameCodec.encodeGetBattery())
        t.send(MeshCoreFrameCodec.encodeGetNextMessage())
        startPolling()
    }

    private func startPolling() {
        stopPolling()
        // Drain queued frames every 2.5 s — same cadence as the ATAK plugin.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.isConnected, #available(iOS 13.0, *) else { return }
                self.transport.send(MeshCoreFrameCodec.encodeGetNextMessage())
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Inbound frame routing

    private func handleFrame(_ frame: Data) {
        guard let response = MeshCoreFrameCodec.decode(frame) else { return }
        switch response {
        case .selfInfo(let info):
            selfPubKeyHex = info.pubKeyHex
            myNodeNum = MeshCoreFrameCodec.nodeId(fromPubKeyHex: info.pubKeyHex)

        case .contact(let contact):
            ingest(contact: contact)
            // Some firmware emits an advert then expects a follow-up drain.
            if #available(iOS 13.0, *) { transport.send(MeshCoreFrameCodec.encodeGetNextMessage()) }

        case .textMessage(let msg):
            routeInboundText(msg)
            if #available(iOS 13.0, *) { transport.send(MeshCoreFrameCodec.encodeGetNextMessage()) }

        case .battery(_, let percent):
            if percent >= 0 { batteryPercent = percent }

        case .deviceInfo(let info):
            #if DEBUG
            print("MeshCore: device hw=\(info.hwModel) rev=\(info.hwRevision) fw='\(info.firmwareVersion)'")
            #endif

        case .messagesWaiting:
            if #available(iOS 13.0, *) { transport.send(MeshCoreFrameCodec.encodeGetNextMessage()) }

        case .noMoreMessages, .other:
            break
        }
    }

    /// Record a contact in the node table and, if it carries a valid position,
    /// publish it to the map as a CoT PLI immediately.
    private func ingest(contact: MeshCoreContact) {
        let nodeId = MeshCoreFrameCodec.nodeId(fromPubKeyHex: contact.pubKeyHex)
        guard nodeId != 0 else { return }
        // Don't plot our own advert as a separate contact.
        // Use the 6-byte (12-hex-char) prefix — the firmware keys contacts on
        // the 6-byte prefix, so a 4-byte check would over-match short-prefix collisions.
        if !selfPubKeyHex.isEmpty,
           contact.pubKeyHex.lowercased().hasPrefix(String(selfPubKeyHex.prefix(12)).lowercased()) {
            return
        }
        contactsByNodeId[nodeId] = contact

        // Build a stable short name from the 6-byte (12-hex-char) prefix.
        let keyPrefix12 = String(contact.pubKeyHex.prefix(12)).uppercased()
        let position: MeshPosition? = contact.hasValidPosition
            ? MeshPosition(latitude: contact.latitude, longitude: contact.longitude, altitude: nil)
            : nil
        let node = MeshNode(
            id: nodeId,
            shortName: keyPrefix12,
            longName: contact.name.isEmpty ? "MeshCore \(keyPrefix12)" : contact.name,
            position: position,
            lastHeard: Date(),
            snr: nil,
            hopDistance: nil,
            batteryLevel: nil
        )
        if let idx = meshNodes.firstIndex(where: { $0.id == nodeId }) {
            meshNodes[idx] = node
        } else {
            meshNodes.append(node)
        }

        if let event = MeshCoreCoTConverter.toCoTEvent(contact: contact) {
            CoTEventHandler.shared.handle(event: .positionUpdate(event))
        }
    }

    /// Route an inbound native text DM into TAK GeoChat, keyed by the sender's
    /// pubkey prefix so it lands in the All Chat room like any GeoChat message.
    private func routeInboundText(_ msg: MeshCoreTextMessage) {
        let trimmed = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Resolve a friendly callsign from a known contact whose pubkey starts
        // with the reported sender prefix; fall back to the prefix itself.
        let senderPrefix = msg.senderPubKeyPrefixHex.lowercased()
        let known = contactsByNodeId.values.first {
            $0.pubKeyHex.lowercased().hasPrefix(senderPrefix)
        }
        let senderUID = "MESHCORE-\(String((known?.pubKeyHex ?? msg.senderPubKeyPrefixHex).prefix(12)).uppercased())"
        let callsign = known?.name ?? "MeshCore \(msg.senderPubKeyPrefixHex.prefix(12).uppercased())"

        let chat = ChatMessage(
            id: UUID().uuidString,
            conversationId: ChatRoom.allUsersId,
            senderId: senderUID,
            senderCallsign: callsign,
            recipientId: nil,
            recipientCallsign: nil,
            messageText: trimmed,
            timestamp: Date(),
            status: .delivered,
            type: .geochat,
            isFromSelf: false
        )
        CoTEventHandler.shared.handle(event: .chatMessage(chat))
    }

    // MARK: TAK map publishing

    public func publishMeshNodesToMap() {
        for contact in contactsByNodeId.values {
            if let event = MeshCoreCoTConverter.toCoTEvent(contact: contact) {
                CoTEventHandler.shared.handle(event: .positionUpdate(event))
            }
        }
    }

    /// Remove all MeshCore markers from the map.
    public func clearMeshMarkersFromMap() {
        for contact in contactsByNodeId.values {
            CoTEventHandler.shared.removeEvent(uid: MeshCoreCoTConverter.uid(forPubKeyHex: contact.pubKeyHex))
        }
    }

    // MARK: Outbound (CoT -> mesh)

    /// Bridge a CoT event onto the MeshCore mesh.
    ///   - a-*  (PLI/self position) -> SET_ADVERT_LATLON + SEND_SELF_ADVERT
    ///   - b-t-f (GeoChat)          -> SEND_TXT_MSG to every known contact
    /// Returns true if at least one frame was dispatched.
    @discardableResult
    func sendCoTOverMesh(_ event: CoTEvent, channelIndex: UInt32 = 0) -> Bool {
        guard isConnected, #available(iOS 13.0, *) else {
            lastError = "Not connected"
            return false
        }
        if event.type.hasPrefix("a-") {
            return broadcastSelfPosition(latitude: event.point.lat,
                                         longitude: event.point.lon,
                                         altitudeMeters: event.point.hae)
        }
        if event.type == "b-t-f" {
            let text = event.detail.remarks ?? ""
            return sendGeoChat(text)
        }
        return false
    }

    /// Push OmniTAK's self-position to the radio's advert (lat/lon) and rebroadcast.
    @available(iOS 13.0, *)
    @discardableResult
    func broadcastSelfPosition(latitude: Double, longitude: Double, altitudeMeters: Double = 0) -> Bool {
        guard isConnected,
              let latlon = MeshCoreFrameCodec.encodeSetAdvertLatLon(
                  latitude: latitude, longitude: longitude, altitudeMeters: altitudeMeters) else {
            return false
        }
        transport.send(latlon)
        transport.send(MeshCoreFrameCodec.encodeSendSelfAdvert())
        return true
    }

    /// Convenience: push the device's current location as a self-advert.
    @available(iOS 13.0, *)
    @discardableResult
    func broadcastCurrentLocation() -> Bool {
        guard let loc = LocationManager.shared.location else { return false }
        return broadcastSelfPosition(latitude: loc.coordinate.latitude,
                                     longitude: loc.coordinate.longitude,
                                     altitudeMeters: loc.altitude)
    }

    /// Send a GeoChat line out as native MeshCore DMs to every known contact.
    /// MeshCore's companion text path is pubkey-to-pubkey; there is no true
    /// broadcast-text command in this v1 scope, so we fan out to known contacts.
    /// Returns true if at least one DM was queued.
    @available(iOS 13.0, *)
    @discardableResult
    func sendGeoChat(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !trimmed.isEmpty else { return false }
        var sentAny = false
        for contact in contactsByNodeId.values {
            if let frame = MeshCoreFrameCodec.encodeSendTextMessage(pubKeyHex: contact.pubKeyHex, text: trimmed) {
                transport.send(frame)
                sentAny = true
            }
        }
        return sentAny
    }

    // MARK: Status helpers

    public var connectionStatus: String {
        isConnected ? "Connected" : "Not Connected"
    }

    public var nodesWithPositions: [MeshNode] {
        meshNodes.filter { $0.position != nil }
    }
}
