//
//  LoopbackRadio.swift
//  OmniTAKMobileTests
//
//  A radio inside the test process, for the tests of how the app handles a link
//  (#148). It listens on a loopback port, speaks the Meshtastic TCP framing
//  (0x94 0xC3 and a two-byte big-endian length), answers a config request with a
//  download, and does with an admin write what the firmware does: a set_config
//  replaces the whole sub-config and a set_channel replaces the whole channel.
//  It answers get_channel_request when the packet asks for a response.
//
//  The tests then run the app's real MeshtasticTCPClient, decoder and manager
//  against it, so the link the app picks, the node number it addresses and the
//  bytes it sends are the real ones. What the real firmware does with those bytes
//  is checked against meshtasticd in MeshtasticSimulatedRadioTests.
//
//  Names, keys and numbers are made up.
//

import Foundation
import Network

final class LoopbackRadio {

    let nodeNum: UInt32

    // What the radio holds, as the bytes it would send in a download.
    private(set) var deviceConfig: Data
    private(set) var positionConfig: Data
    private(set) var channels: [Int: Data]

    /// False: it accepts the connection and never answers a config request.
    var answersConfigRequests = true
    /// False: it ignores set_channel and keeps what it had.
    var appliesChannelWrites = true

    /// An admin message the radio received.
    struct AdminWrite {
        /// The node the packet was addressed to.
        let to: UInt32
        let payload: Data
        let wantResponse: Bool
    }

    private let lock = NSLock()
    private var _admin: [AdminWrite] = []
    private var _configRequests = 0
    private var _accepted = 0
    private var _clientConnected = false
    private var _channelWrites: [Data] = []

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
        self.deviceConfig = device.data
        self.positionConfig = position.data
        self.channels = channels.mapValues { $0.data }
    }

    // MARK: - What the test can see

    /// Admin messages received, in order.
    var admin: [AdminWrite] { lock.lock(); defer { lock.unlock() }; return _admin }
    /// How many config requests arrived.
    var configRequests: Int { lock.lock(); defer { lock.unlock() }; return _configRequests }
    /// How many connections it has accepted.
    var accepted: Int { lock.lock(); defer { lock.unlock() }; return _accepted }
    /// Whether a client is connected right now.
    var isClientConnected: Bool { lock.lock(); defer { lock.unlock() }; return _clientConnected }
    /// The Channel messages of the set_channel writes it received, in order.
    var channelWrites: [Data] { lock.lock(); defer { lock.unlock() }; return _channelWrites }

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
        for frame in downloadFrames(configID: configID) { sendRaw(frame) }
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
            // packet
            if field.number == 1 && field.wire == 2 {
                handlePacket(field.value)
            }
        }
    }

    private func handlePacket(_ packet: Data) {
        guard let fields = FixtureReader.fields(packet),
              let to = fields.first(where: { $0.number == 2 && $0.wire == 5 }),
              let decoded = fields.first(where: { $0.number == 4 && $0.wire == 2 }),
              FixtureReader.varint(1, in: decoded.value) == RadioProto.adminPortnum,
              let adminPayload = FixtureReader.bytes(2, in: decoded.value) else { return }

        let target = to.value.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        let wantsResponse = (FixtureReader.varint(3, in: decoded.value) ?? 0) != 0
        let record = AdminWrite(to: target, payload: adminPayload, wantResponse: wantsResponse)

        // Admin messages for another node are not this radio's to apply.
        guard target == nodeNum, let admin = FixtureReader.fields(adminPayload) else {
            lock.lock(); _admin.append(record); lock.unlock()
            return
        }

        var answers: [Data] = []
        for field in admin {
            switch (field.number, field.wire) {
            case (RadioProto.Admin.setConfig, 2):
                // A set_config replaces the whole sub-config.
                if let variant = FixtureReader.fields(field.value)?.first(where: { $0.wire == 2 }) {
                    lock.lock()
                    if variant.number == RadioProto.Config.device { deviceConfig = variant.value }
                    if variant.number == RadioProto.Config.position { positionConfig = variant.value }
                    lock.unlock()
                }
            case (RadioProto.Admin.setChannel, 2):
                lock.lock(); _channelWrites.append(field.value); lock.unlock()
                if appliesChannelWrites {
                    let index = Int(FixtureReader.varint(RadioProto.Channel.index, in: field.value) ?? 0)
                    lock.lock(); channels[index] = field.value; lock.unlock()
                }
            case (1, 0):
                // get_channel_request, the index plus one
                guard wantsResponse, let raw = FixtureReader.varint(1, in: adminPayload), raw >= 1 else { continue }
                lock.lock(); let channel = channels[Int(raw) - 1]; lock.unlock()
                if let channel = channel { answers.append(channel) }
            default:
                break
            }
        }

        // Recorded once its effect is in place, and before any answer goes out,
        // so a test that has seen the message can rely on the radio holding what
        // it asked for.
        lock.lock(); _admin.append(record); lock.unlock()
        for channel in answers { sendChannelResponse(channel) }
    }

    private func sendChannelResponse(_ channel: Data) {
        let adminMessage = ProtoFixture().bytes(2, channel).data
        let decoded = ProtoFixture().varint(1, RadioProto.adminPortnum).bytes(2, adminMessage)
        let packet = ProtoFixture().fixed32(1, nodeNum).fixed32(2, 0).message(4, decoded)
        send(ProtoFixture().message(RadioProto.FromRadio.packet, packet))
    }

    // MARK: - The download

    private func downloadFrames(configID: UInt64) -> [Data] {
        lock.lock()
        let device = deviceConfig, position = positionConfig, slots = channels
        lock.unlock()

        var frames: [Data] = []
        frames.append(LoopbackRadio.frame(RadioFixtures.myInfoFrame(nodeNum: nodeNum)))
        for index in slots.keys.sorted() {
            frames.append(LoopbackRadio.frame(RadioFixtures.channelFrame(ProtoFixture(slots[index]!))))
        }
        frames.append(LoopbackRadio.frame(RadioFixtures.configFrame(variant: RadioProto.Config.device, body: ProtoFixture(device))))
        frames.append(LoopbackRadio.frame(RadioFixtures.configFrame(variant: RadioProto.Config.position, body: ProtoFixture(position))))
        frames.append(LoopbackRadio.frame(ProtoFixture().varint(RadioProto.FromRadio.configCompleteId, configID).data))
        return frames
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
