//
//  MeshtasticTCPClient.swift
//  OmniTAK Mobile
//
//  Pure Swift TCP client for Meshtastic device communication
//  Implements the Meshtastic streaming protocol over TCP
//

import Foundation
import Combine
import Network

// MARK: - Protocol Constants

private enum MeshtasticProtocol {
    static let startByte1: UInt8 = 0x94
    static let startByte2: UInt8 = 0xC3
    static let headerSize = 4
    static let maxPacketSize = 512
    static let defaultPort: UInt16 = 4403
}

// MARK: - TCP Client Delegate

protocol MeshtasticTCPClientDelegate: AnyObject {
    func tcpClient(_ client: MeshtasticTCPClient, didConnect host: String, port: UInt16)
    func tcpClient(_ client: MeshtasticTCPClient, didDisconnect error: Error?)
    func tcpClient(_ client: MeshtasticTCPClient, didReceiveNodeInfo node: MeshNode)
    func tcpClient(_ client: MeshtasticTCPClient, didReceivePosition nodeId: UInt32, position: MeshPosition)
    func tcpClient(_ client: MeshtasticTCPClient, didReceiveMessage from: UInt32, text: String)
    func tcpClient(_ client: MeshtasticTCPClient, didUpdateMyInfo nodeNum: UInt32, firmwareVersion: String)
    func tcpClient(_ client: MeshtasticTCPClient, didReceiveError message: String)
}

// MARK: - MeshtasticTCPClient

@available(iOS 13.0, *)
class MeshtasticTCPClient: ObservableObject {

    // MARK: - Published State

    @Published var isConnected: Bool = false
    @Published var connectionState: ConnectionState = .disconnected
    @Published var myNodeNum: UInt32 = 0
    @Published var firmwareVersion: String = ""
    @Published var nodes: [UInt32: MeshNode] = [:]
    @Published var lastError: String?

    enum ConnectionState: String {
        case disconnected = "Disconnected"
        case connecting = "Connecting..."
        case connected = "Connected"
        case failed = "Connection Failed"
    }

    // MARK: - Properties

    weak var delegate: MeshtasticTCPClientDelegate?

    /// The radio's own settings as they come in during the config download, and
    /// the start of each download, each with the connection that delivered it.
    /// MeshtasticManager keeps them so a settings write can change one field and
    /// send the rest back (#148). Events are sent in the order the frames arrive.
    let settingsEvents = PassthroughSubject<MeshtasticLinkEvent, Never>()

    private let queue = DispatchQueue(label: "com.omnitak.meshtastic.tcp", qos: .userInitiated)
    private var receiveBuffer = Data()
    private var host: String = ""
    private var port: UInt16 = MeshtasticProtocol.defaultPort

    // MARK: - Which connection

    // Every connect and every disconnect starts a new connection, numbered. The
    // old one is cancelled, and whatever it still delivers (frames, state
    // changes, a config request that was waiting) is ignored: it is not the
    // radio the operator asked for now. Settings, the node number and the
    // connected state all belong to one connection (#148).

    private let stateLock = NSLock()
    private var _connection: NWConnection?
    private var _serial = 0

    private var connection: NWConnection? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _connection
    }

    /// The number of the current connection. It changes with every `connect` and
    /// `disconnect`.
    var connectionSerial: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _serial
    }

    /// Make `new` the connection, as the next connection number. Returns the one
    /// it replaces, which the caller cancels, and the new number.
    private func replaceConnection(with new: NWConnection?) -> (old: NWConnection?, serial: Int) {
        stateLock.lock(); defer { stateLock.unlock() }
        let old = _connection
        _connection = new
        _serial += 1
        return (old, _serial)
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    /// Run `block` on the main queue, unless connection `serial` is no longer
    /// the current one by then.
    private func onMain(ifCurrent serial: Int, _ block: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.connectionSerial == serial else { return }
            block()
        }
    }

    // MARK: - Connection Management

    /// Connect to a radio. Any connection already open is cancelled first, and
    /// nothing of it is carried over: not its frames, not its node number, not
    /// what was half-read from it.
    func connect(host: String, port: UInt16 = MeshtasticProtocol.defaultPort) {
        self.host = host
        self.port = port

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 10
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.prohibitedInterfaceTypes = [.cellular]

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let new = NWConnection(to: endpoint, using: parameters)
        let (old, serial) = replaceConnection(with: new)
        old?.cancel()
        // On the queue that reads, and before the new connection can deliver
        // anything, so a half-read frame of the old connection is not the start
        // of the new one's.
        queue.async { [weak self] in self?.receiveBuffer.removeAll() }

        onMain {
            self.isConnected = false
            self.myNodeNum = 0
            self.firmwareVersion = ""
            self.nodes.removeAll()
            self.connectionState = .connecting
            self.lastError = nil
        }

        new.stateUpdateHandler = { [weak self] state in
            self?.handleConnectionState(state, serial: serial)
        }
        new.start(queue: queue)
    }

    func disconnect() {
        let (old, _) = replaceConnection(with: nil)
        old?.cancel()

        onMain {
            self.isConnected = false
            self.connectionState = .disconnected
            self.myNodeNum = 0
            self.firmwareVersion = ""
            self.nodes.removeAll()
        }

        delegate?.tcpClient(self, didDisconnect: nil)
    }

    // MARK: - State Handling

    private func handleConnectionState(_ state: NWConnection.State, serial: Int) {
        // A connection that has been replaced is not the radio any more.
        guard serial == connectionSerial else { return }

        switch state {
        case .ready:
            onMain(ifCurrent: serial) {
                self.isConnected = true
                self.connectionState = .connected
            }
            delegate?.tcpClient(self, didConnect: host, port: port)
            if let current = connection { startReceiving(on: current, serial: serial) }
            // Delay config request slightly to ensure connection is fully ready
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self = self, self.connectionSerial == serial else { return }
                self.requestConfig()
            }

        case .failed(let error):
            onMain(ifCurrent: serial) {
                self.isConnected = false
                self.connectionState = .failed
                self.lastError = error.localizedDescription
            }
            delegate?.tcpClient(self, didDisconnect: error)

        case .cancelled:
            onMain(ifCurrent: serial) {
                self.isConnected = false
                self.connectionState = .disconnected
            }

        case .waiting(let error):
            onMain(ifCurrent: serial) {
                self.lastError = "Waiting: \(error.localizedDescription)"
            }

        default:
            break
        }
    }

    // MARK: - Receiving Data

    private func startReceiving(on connection: NWConnection, serial: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self = self, self.connectionSerial == serial else { return }

            if let data = content {
                self.receiveBuffer.append(data)
                self.processBuffer(serial: serial)
            }

            if let error = error {
                self.onMain(ifCurrent: serial) {
                    self.lastError = error.localizedDescription
                }
                return
            }

            if isComplete {
                self.disconnect()
            } else {
                self.startReceiving(on: connection, serial: serial)
            }
        }
    }

    private func processBuffer(serial: Int) {
        // Process all complete packets in the buffer
        while true {
            // Need at least 4 bytes for header
            guard receiveBuffer.count >= MeshtasticProtocol.headerSize else { break }

            // Safe access using first/dropFirst pattern
            let bytes = Array(receiveBuffer.prefix(4))
            guard bytes.count == 4 else { break }

            // Check for magic bytes
            guard bytes[0] == MeshtasticProtocol.startByte1,
                  bytes[1] == MeshtasticProtocol.startByte2 else {
                // Invalid header, skip a byte
                if !receiveBuffer.isEmpty {
                    receiveBuffer.removeFirst()
                }
                continue
            }

            // Read length (big endian)
            let payloadLength = Int(UInt16(bytes[2]) << 8 | UInt16(bytes[3]))

            // Sanity check
            guard payloadLength > 0, payloadLength <= MeshtasticProtocol.maxPacketSize else {
                if !receiveBuffer.isEmpty {
                    receiveBuffer.removeFirst()
                }
                continue
            }

            // Wait for full packet
            let totalLength = MeshtasticProtocol.headerSize + payloadLength
            guard receiveBuffer.count >= totalLength else { break }

            // Extract payload safely
            let payload = receiveBuffer.prefix(totalLength).dropFirst(MeshtasticProtocol.headerSize)
            let payloadData = Data(payload)

            // Remove processed bytes
            receiveBuffer.removeFirst(totalLength)

            // Parse protobuf
            parseFromRadio(payloadData, serial: serial)
        }
    }

    // MARK: - FromRadio handling (decoding lives in MeshtasticProtoDecoder)

    private func parseFromRadio(_ data: Data, serial: Int) {
        guard let payload = MeshtasticProtoDecoder.decodeFromRadio(data) else { return }

        if let event = MeshtasticRadioSettings.Event(payload) {
            settingsEvents.send(MeshtasticLinkEvent(transport: .tcp, connection: serial, event: event))
        }

        switch payload {
        case .myInfo(let nodeNum):
            // FromRadio.my_info carries the node number only. The firmware
            // version arrives in a separate metadata frame, which is not decoded.
            let firmware = "Unknown"
            onMain(ifCurrent: serial) {
                self.myNodeNum = nodeNum
                self.firmwareVersion = firmware
            }
            delegate?.tcpClient(self, didUpdateMyInfo: nodeNum, firmwareVersion: firmware)

        case .nodeInfo(let node):
            onMain(ifCurrent: serial) {
                // A later frame without a role or a last-heard time must not
                // erase what an earlier one told us.
                self.nodes[node.id] = node.carryingForward(from: self.nodes[node.id])
            }
            delegate?.tcpClient(self, didReceiveNodeInfo: node)

        case .packet(let packet):
            handleMeshPacket(packet, serial: serial)

        case .configComplete, .rebooted, .config, .channel, .other:
            // config and channel went to settingsEvents above.
            break
        }
    }

    private func handleMeshPacket(_ packet: MeshtasticProtoDecoder.MeshPacketFrame, serial: Int) {
        // Port numbers from Meshtastic:
        // 1 = TEXT_MESSAGE_APP
        // 3 = POSITION_APP
        // 4 = NODEINFO_APP
        // 72 = ATAK_PLUGIN
        // 257 = ATAK_FORWARDER

        switch packet.portNum {
        case 1: // Text message
            if let text = String(data: packet.payload, encoding: .utf8) {
                delegate?.tcpClient(self, didReceiveMessage: packet.from, text: text)
            }

        case 3: // Position
            if let position = MeshtasticProtoDecoder.decodePosition(packet.payload) {
                // A packet that just came off the radio means the node was heard.
                // The radio's rx_time says when; it is absent when the radio has
                // no clock, and then the phone's clock is the best there is.
                let heardAt = packet.rxTime ?? Date()
                onMain(ifCurrent: serial) {
                    if var node = self.nodes[packet.from] {
                        node.position = position
                        node.noteHeard(at: heardAt)
                        self.nodes[packet.from] = node
                    }
                }
                delegate?.tcpClient(self, didReceivePosition: packet.from, position: position)
            }

        case 72, 257: // ATAK_PLUGIN / ATAK_FORWARDER
            print("🎯 ATAK Plugin message from \(String(format: "0x%08X", packet.from)) (\(packet.payload.count) bytes)")
            handleATAKPluginPayload(packet.payload, from: packet.from)

        case 78: // ATAK_PLUGIN_V2 / TAKPacketV2 — a dropped tactical marker
            print("🎯 TAKPacketV2 marker from \(String(format: "0x%08X", packet.from)) (\(packet.payload.count) bytes)")
            handleTAKPacketV2Payload(packet.payload, from: packet.from)

        default:
            break
        }
    }

    /// Decode a port-78 TAKPacketV2 payload into a marker CoTEvent and feed it
    /// to the CoT pipeline as a position/marker update (NOT chat). Dedup is by
    /// uid (preserved verbatim by the codec) — CoTEventHandler updates the
    /// existing event in place when the uid already exists.
    fileprivate func handleTAKPacketV2Payload(_ payload: Data, from nodeId: UInt32) {
        guard let event = TAKPacketV2Codec.decode(payload) else {
            print("⚠️ Failed to decode TAKPacketV2 payload (\(payload.count) bytes) from \(String(format: "0x%08X", nodeId))")
            return
        }
        print("✅ TAKPacketV2 → marker CoTEvent uid=\(event.uid) type=\(event.type) callsign=\(event.detail.callsign)")
        DispatchQueue.main.async {
            CoTEventHandler.shared.handle(event: .positionUpdate(event))
        }
    }

    /// Parse a portnum-72 payload and forward into the existing CoT pipeline.
    fileprivate func handleATAKPluginPayload(_ payload: Data, from nodeId: UInt32) {
        guard let cot = ATAKPluginParser.parse(payload) else {
            print("⚠️ Failed to parse ATAK plugin payload (\(payload.count) bytes) from \(String(format: "0x%08X", nodeId))")
            return
        }
        print("✅ ATAK plugin → CoTEvent uid=\(cot.uid) type=\(cot.type) callsign=\(cot.detail.callsign)")
        let eventType: CoTEventType = ATAKPluginParser.classify(cot)
        DispatchQueue.main.async {
            CoTEventHandler.shared.handle(event: eventType)
        }
    }

    /// Send an ATAK payload over the active TCP connection. Defaults to
    /// portnum 72 (ATAK_PLUGIN, TAKPacket v1); pass portnum 78 for a
    /// TAKPacketV2 marker. Returns true if the bytes were dispatched.
    @discardableResult
    func sendATAKPlugin(
        payload: Data,
        to destination: UInt32 = 0xFFFFFFFF,
        channel: UInt32 = 0,
        portnum: UInt64 = 72,
        hopLimit: UInt32 = 3,
        wantAck: Bool = false
    ) -> Bool {
        guard connection != nil, isConnected else {
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
        sendToRadio(toRadio)
        return true
    }

    /// Send an `AdminMessage` payload (channel / config apply) on the ADMIN_APP
    /// portnum (6) to the local radio. Unicast to the radio's own node with
    /// want_ack so the radio applies + persists the change. Returns true if
    /// dispatched.
    ///
    /// The write names the connection it was built on and the radio it was
    /// built for. It is refused, and nothing is sent, when the connection is
    /// not that one any more (a newer one has begun), or the node number this
    /// client holds is not that radio's. There is no fallback to the broadcast
    /// address: that would put the admin message, and for set_channel the
    /// channel key, on the air.
    @discardableResult
    func sendAdmin(payload: Data, to nodeNum: UInt32, connection expected: Int, wantResponse: Bool = false) -> Bool {
        guard connection != nil, isConnected, connectionSerial == expected else {
            DispatchQueue.main.async { self.lastError = MeshtasticWriteResult.notConnected }
            return false
        }
        guard myNodeNum == nodeNum,
              let toRadio = MeshtasticAdminCodec.toRadioFrame(
                  adminPayload: payload, myNodeNum: nodeNum, wantResponse: wantResponse) else {
            DispatchQueue.main.async { self.lastError = MeshtasticWriteResult.linkChanged }
            return false
        }
        sendToRadio(toRadio)
        return true
    }

    // MARK: - Sending Data

    func requestConfig() {
        // Send ToRadio with want_config_id to request device configuration
        // Field 3: want_config_id (uint32)
        sendToRadio(buildWantConfig())
    }

    func sendTextMessage(_ text: String, to destination: UInt32 = 0xFFFFFFFF) {
        // Build a text message packet
        let packet = buildTextMessage(text, to: destination)
        sendToRadio(packet)
    }

    private func buildWantConfig() -> Data {
        // ToRadio message with want_config_id = random
        var data = Data()

        // Field 3: want_config_id (uint32)
        let configId = UInt32.random(in: 1...UInt32.max)
        data.append(0x18) // Tag: field 3, wire type 0 (varint)
        appendVarint(&data, UInt64(configId))

        return data
    }

    private func buildTextMessage(_ text: String, to destination: UInt32) -> Data {
        var data = Data()

        // ToRadio.packet (field 1, wire type 2)
        // MeshPacket structure

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

    private func sendToRadio(_ payload: Data) {
        guard let connection = connection else { return }

        // Build frame with header
        var frame = Data()
        frame.append(MeshtasticProtocol.startByte1)
        frame.append(MeshtasticProtocol.startByte2)
        frame.append(UInt8((payload.count >> 8) & 0xFF))
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(payload)

        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.lastError = "Send error: \(error.localizedDescription)"
                }
            }
        })
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

// MARK: - Settings writes

@available(iOS 13.0, *)
extension MeshtasticTCPClient: MeshtasticAdminLink {}
