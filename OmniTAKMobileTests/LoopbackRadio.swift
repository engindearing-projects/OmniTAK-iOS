//
//  LoopbackRadio.swift
//  OmniTAKMobileTests
//
//  A radio inside the test process, for the tests of how the app handles a link
//  (#148). It listens on a loopback port, speaks the Meshtastic TCP framing
//  (0x94 0xC3 and a two-byte big-endian length), answers a config request with a
//  download, and hands the admin packets it receives to a SimulatedRadioModel,
//  which does with them what the firmware does: replaces a whole sub-config or
//  channel, answers get requests with the request's packet id echoed, takes
//  packets addressed to itself through a queue of four that drops the oldest.
//
//  The tests then run the app's real MeshtasticTCPClient, decoder and manager
//  against it, so the link the app picks, the node number it addresses, the ids
//  it sends and the pace it sends at are the real ones. What the real firmware
//  does with those bytes is checked against meshtasticd in
//  MeshtasticSimulatedRadioTests.
//
//  Names, keys and numbers are made up.
//

import Foundation
import Network

final class LoopbackRadio {

    let nodeNum: UInt32

    /// What the radio is, and does with a packet.
    let model: SimulatedRadioModel

    /// False: it accepts the connection and never answers a config request.
    var answersConfigRequests = true

    /// An admin message the radio received.
    struct AdminWrite {
        /// The node the packet was addressed to.
        let to: UInt32
        let payload: Data
        let wantResponse: Bool
        let packetID: UInt32
        let kind: SimulatedRadioModel.Kind
    }

    private let lock = NSLock()
    private var _configRequests = 0
    private var _accepted = 0
    private var _clientConnected = false

    private let queue = DispatchQueue(label: "test.loopback.radio")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()

    init(
        nodeNum: UInt32,
        device: ProtoFixture = RadioFixtures.deviceConfig(),
        position: ProtoFixture = RadioFixtures.positionConfig(),
        channels: [Int: ProtoFixture] = RadioFixtures.channelSlots()
    ) {
        self.nodeNum = nodeNum
        self.model = SimulatedRadioModel(nodeNum: nodeNum, device: device, position: position, channels: channels)
    }

    // MARK: - What the test can see

    var deviceConfig: Data { model.deviceConfig }
    var positionConfig: Data { model.positionConfig }
    var channels: [Int: Data] { model.channels }
    /// False: it ignores set_channel and keeps what it had.
    var appliesChannelWrites: Bool {
        get { model.appliesChannelWrites }
        set { model.appliesChannelWrites = newValue }
    }

    /// Admin messages the radio took, in order. A message is listed once its
    /// effect is in place, and before any answer goes out.
    var admin: [AdminWrite] {
        model.processed.map {
            AdminWrite(to: $0.packet.to, payload: $0.packet.admin, wantResponse: $0.packet.wantResponse,
                       packetID: $0.packet.packetID, kind: $0.kind)
        }
    }
    /// How many config requests arrived.
    var configRequests: Int { lock.lock(); defer { lock.unlock() }; return _configRequests }
    /// How many connections it has accepted.
    var accepted: Int { lock.lock(); defer { lock.unlock() }; return _accepted }
    /// Whether a client is connected right now.
    var isClientConnected: Bool { lock.lock(); defer { lock.unlock() }; return _clientConnected }
    /// The Channel messages of the set_channel writes it took, in order.
    var channelWrites: [Data] {
        model.processed.compactMap { record in
            guard case .setChannel = record.kind else { return nil }
            return FixtureReader.setChannel(in: record.packet.admin)
        }
    }

    // MARK: - Running

    /// Start listening on a free loopback port and return it.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.first() { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    if resumed.first() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        queue.sync {
            connection?.cancel()
            connection = nil
        }
    }

    /// Close the client's connection from the radio's side, as a restart does.
    func dropClient() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    /// Send bytes to the client as they are.
    func sendRaw(_ bytes: Data) {
        queue.async { [weak self] in
            self?.connection?.send(content: bytes, completion: .contentProcessed { _ in })
        }
    }

    /// Send a FromRadio message to the client, framed.
    func send(_ fromRadio: ProtoFixture) {
        sendRaw(LoopbackRadio.frame(fromRadio.data))
    }

    /// The config download a radio sends for a config request.
    func sendDownload(configID: UInt64 = 1) {
        for frame in model.downloadFrames(configID: configID) { sendRaw(LoopbackRadio.frame(frame)) }
    }

    // MARK: - Connection handling

    private func accept(_ new: NWConnection) {
        // One client at a time, as the firmware has it: a new one replaces the old.
        connection?.cancel()
        connection = new
        buffer.removeAll()
        lock.lock(); _accepted += 1; _clientConnected = true; lock.unlock()

        new.stateUpdateHandler = { [weak self, weak new] state in
            switch state {
            case .cancelled, .failed:
                guard let self = self, self.connection === new || self.connection == nil else { return }
                self.lock.lock(); self._clientConnected = false; self.lock.unlock()
            default:
                break
            }
        }
        new.start(queue: queue)
        receive(on: new)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak connection] data, _, isComplete, error in
            guard let self = self, let connection = connection, self.connection === connection else { return }
            if let data = data { self.buffer.append(data); self.processFrames() }
            if error != nil || isComplete {
                self.lock.lock(); self._clientConnected = false; self.lock.unlock()
                return
            }
            self.receive(on: connection)
        }
    }

    private func processFrames() {
        while buffer.count >= 4 {
            let bytes = [UInt8](buffer.prefix(4))
            guard bytes[0] == 0x94, bytes[1] == 0xC3 else { buffer.removeFirst(); continue }
            let length = Int(bytes[2]) << 8 | Int(bytes[3])
            guard buffer.count >= 4 + length else { return }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer.removeFirst(4 + length)
            handleToRadio(payload)
        }
    }

    // MARK: - What the radio does with what it receives

    private func handleToRadio(_ payload: Data) {
        guard let fields = FixtureReader.fields(payload) else { return }
        for field in fields {
            // want_config_id
            if field.number == 3 && field.wire == 0 {
                lock.lock(); _configRequests += 1; lock.unlock()
                if answersConfigRequests {
                    sendDownload(configID: FixtureReader.varint(3, in: payload) ?? 1)
                }
            }
        }
        // An admin packet goes to the model, which answers through the socket.
        if let packet = FixtureReader.adminPacket(in: payload) {
            model.receive(SimulatedRadioModel.Packet(
                to: packet.to, admin: packet.admin, wantResponse: packet.wantResponse, packetID: packet.packetID)
            ) { [weak self] answer in
                self?.sendRaw(LoopbackRadio.frame(answer))
            }
        }
    }

    static func frame(_ payload: Data) -> Data {
        var out = Data([0x94, 0xC3, UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)])
        out.append(payload)
        return out
    }
}

/// True the first time it is asked, and never again.
private final class ResumeOnce {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if used { return false }
        used = true
        return true
    }
}
