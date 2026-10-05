//
//  SimulatedRadioModel.swift
//  OmniTAKMobileTests
//
//  What a Meshtastic radio does with the admin packets its phone sends it, as a
//  model the tests share (#148). LoopbackRadio puts it behind a TCP socket, and
//  FakeRadioLink puts it behind the manager's link seam, so the same radio is
//  there with the real client and without one.
//
//  It does with a packet what the firmware does:
//   - set_config replaces the whole sub-config, and a role change rewrites the
//     position config with the role's defaults (when `roleDefaults` says what
//     they are);
//   - set_channel replaces the whole channel;
//   - get_config_request and get_channel_request are answered, in a packet from
//     the radio to itself that echoes the request's packet id in
//     Data.request_id and carries no receive metadata, but only when the packet
//     asks for a response;
//   - what it holds in memory is saved when it takes a write, unless an edit is
//     open (begin_edit_settings): then it is only in memory, and `restart()`,
//     a power cycle, puts back what was saved. A commit saves everything and
//     asks for a restart. A config write that needs a restart (the device and
//     position configs) saves and asks for one as well, and, when
//     `cutsBluetoothOnRestartingWrite` is set, cuts the link at once, as the
//     firmware does over Bluetooth (`disableBluetooth` in AdminModule). A
//     set_channel saves itself and asks for no restart;
//   - packets addressed to the radio itself wait in a queue of four, and the
//     oldest is dropped when another arrives (`processingDelay` is how long the
//     radio is busy with each packet, so that a burst can fill the queue).
//
//  Names, keys and numbers are made up.
//

import Foundation
@testable import OmniTAK

final class SimulatedRadioModel: @unchecked Sendable {

    /// An admin packet as the radio receives it.
    struct Packet {
        let to: UInt32
        let admin: Data
        let wantResponse: Bool
        let packetID: UInt32
    }

    /// What an admin message asks for.
    enum Kind: Equatable {
        case getConfig(variant: Int)
        case getChannel(index: Int)
        case setConfig(variant: Int)
        case setChannel(index: Int)
        case beginEdit
        case commitEdit
        case other
    }

    /// A packet the radio took, with when.
    struct Record {
        let packet: Packet
        let kind: Kind
        /// `DispatchTime` uptime in nanoseconds when the radio got the packet.
        let received: UInt64
    }

    /// What a packet from the radio carries when it was received over the air.
    /// The radio's own packets to its phone carry none of it.
    struct Signals {
        var rxRssi: Int32 = 0
        var rxSnr: Float = 0
        var viaMqtt = false
        var transportMechanism: UInt64 = 0
    }

    let nodeNum: UInt32

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "test.simulated.radio")

    private var _device: Data
    private var _position: Data
    private var _channels: [Int: Data]
    // What was saved: what the radio comes back with after a restart.
    private var _savedDevice: Data
    private var _savedPosition: Data
    private var _savedChannels: [Int: Data]
    private var _restartRequested = false
    private var _restarts = 0
    private var _linkCut = false
    private var _processed: [Record] = []
    private var _dropped: [Record] = []
    private var _held: [Data] = []
    private var _transactionOpen = false
    private var _commits = 0
    private var waiting: [(packet: Packet, received: UInt64, deliver: (Data) -> Void)] = []
    private var busy = false
    private var nextAnswerID: UInt32 = 0x7000_0000

    // MARK: Behavior

    private var _answersGets = true
    private var _appliesChannelWrites = true
    private var _appliesConfigWrites = true
    private var _stopsAnsweringAfterAWrite = false
    private var _holdsAnswersAfterAWrite = false
    private var _transformChannelWrite: ((Data) -> Data)?
    private var _queueDepth = 4
    private var _processingDelay: TimeInterval = 0
    private var _answerDelay: TimeInterval = 0
    private var _signals = Signals()
    private var _answerRequestIDOverride: UInt32?
    private var _answerFromOverride: UInt32?
    private var _roleDefaults: ((UInt64) -> ProtoFixture?)?
    private var _onCommit: (() -> Void)?
    private var _holdAnswers = false
    private var _cutsBluetoothOnRestartingWrite = false
    private var _onLinkCut: (() -> Void)?

    /// False: it takes get requests and never answers them.
    var answersGets: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _answersGets }
        set { lock.lock(); _answersGets = newValue; lock.unlock() }
    }
    /// False: it takes set_channel and keeps what it had.
    var appliesChannelWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _appliesChannelWrites }
        set { lock.lock(); _appliesChannelWrites = newValue; lock.unlock() }
    }
    /// False: it takes set_config and keeps what it had.
    var appliesConfigWrites: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _appliesConfigWrites }
        set { lock.lock(); _appliesConfigWrites = newValue; lock.unlock() }
    }
    /// True: after it takes a write it answers no more get requests.
    var stopsAnsweringAfterAWrite: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _stopsAnsweringAfterAWrite }
        set { lock.lock(); _stopsAnsweringAfterAWrite = newValue; lock.unlock() }
    }
    /// True: after it takes a write, its answers are kept until `releaseAnswers()`,
    /// as an answer that is slow to arrive.
    var holdsAnswersAfterAWrite: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _holdsAnswersAfterAWrite }
        set { lock.lock(); _holdsAnswersAfterAWrite = newValue; lock.unlock() }
    }
    /// What the radio holds in place of the channel it was sent: a radio that
    /// takes part of a write and keeps the rest.
    var transformChannelWrite: ((Data) -> Data)? {
        get { lock.lock(); defer { lock.unlock() }; return _transformChannelWrite }
        set { lock.lock(); _transformChannelWrite = newValue; lock.unlock() }
    }
    /// How many packets can wait. The oldest is dropped when one more arrives.
    var queueDepth: Int {
        get { lock.lock(); defer { lock.unlock() }; return _queueDepth }
        set { lock.lock(); _queueDepth = newValue; lock.unlock() }
    }
    /// How long the radio is busy with each packet, in seconds. 0: it takes each
    /// packet as it arrives and nothing waits.
    var processingDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _processingDelay }
        set { lock.lock(); _processingDelay = newValue; lock.unlock() }
    }
    /// How long after taking a get request the answer goes out, in seconds.
    var answerDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _answerDelay }
        set { lock.lock(); _answerDelay = newValue; lock.unlock() }
    }
    /// The receive metadata the answers carry. None, as a real radio's own.
    var signals: Signals {
        get { lock.lock(); defer { lock.unlock() }; return _signals }
        set { lock.lock(); _signals = newValue; lock.unlock() }
    }
    /// An id other than the request's, put in the answers.
    var answerRequestIDOverride: UInt32? {
        get { lock.lock(); defer { lock.unlock() }; return _answerRequestIDOverride }
        set { lock.lock(); _answerRequestIDOverride = newValue; lock.unlock() }
    }
    /// A node number other than the radio's own, put in the answers' `from`.
    var answerFromOverride: UInt32? {
        get { lock.lock(); defer { lock.unlock() }; return _answerFromOverride }
        set { lock.lock(); _answerFromOverride = newValue; lock.unlock() }
    }
    /// The position config a role installs. Nil: a role change touches nothing.
    var roleDefaults: ((UInt64) -> ProtoFixture?)? {
        get { lock.lock(); defer { lock.unlock() }; return _roleDefaults }
        set { lock.lock(); _roleDefaults = newValue; lock.unlock() }
    }
    /// Called when an edit is committed, which is when a radio restarts.
    var onCommit: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onCommit }
        set { lock.lock(); _onCommit = newValue; lock.unlock() }
    }
    /// True: answers are kept until `releaseAnswers()` instead of being sent.
    var holdAnswers: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _holdAnswers }
        set { lock.lock(); _holdAnswers = newValue; lock.unlock() }
    }
    /// True: when it takes a config write that needs a restart, outside an edit,
    /// or a commit, it cuts the link at once, as a radio does over Bluetooth.
    var cutsBluetoothOnRestartingWrite: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _cutsBluetoothOnRestartingWrite }
        set { lock.lock(); _cutsBluetoothOnRestartingWrite = newValue; lock.unlock() }
    }
    /// Called when the radio cuts the link.
    var onLinkCut: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onLinkCut }
        set { lock.lock(); _onLinkCut = newValue; lock.unlock() }
    }

    // MARK: What the radio holds

    var deviceConfig: Data { lock.lock(); defer { lock.unlock() }; return _device }
    var positionConfig: Data { lock.lock(); defer { lock.unlock() }; return _position }
    var channels: [Int: Data] { lock.lock(); defer { lock.unlock() }; return _channels }
    var transactionOpen: Bool { lock.lock(); defer { lock.unlock() }; return _transactionOpen }
    var commits: Int { lock.lock(); defer { lock.unlock() }; return _commits }
    /// What was saved, which is what the radio comes back with after a restart.
    var savedDeviceConfig: Data { lock.lock(); defer { lock.unlock() }; return _savedDevice }
    var savedPositionConfig: Data { lock.lock(); defer { lock.unlock() }; return _savedPosition }
    var savedChannels: [Int: Data] { lock.lock(); defer { lock.unlock() }; return _savedChannels }
    /// True once something it took asks for a restart (a commit, or a config
    /// write outside an edit) and until `restart()`.
    var restartRequested: Bool { lock.lock(); defer { lock.unlock() }; return _restartRequested }
    /// How many times it has restarted.
    var restarts: Int { lock.lock(); defer { lock.unlock() }; return _restarts }

    /// The packets it took, in order.
    var processed: [Record] { lock.lock(); defer { lock.unlock() }; return _processed }
    /// The packets the queue dropped, in order.
    var dropped: [Record] { lock.lock(); defer { lock.unlock() }; return _dropped }

    init(
        nodeNum: UInt32,
        device: ProtoFixture = RadioFixtures.deviceConfig(),
        position: ProtoFixture = RadioFixtures.positionConfig(),
        channels: [Int: ProtoFixture] = RadioFixtures.channelSlots()
    ) {
        self.nodeNum = nodeNum
        self._device = device.data
        self._position = position.data
        self._channels = channels.mapValues { $0.data }
        self._savedDevice = device.data
        self._savedPosition = position.data
        self._savedChannels = channels.mapValues { $0.data }
    }

    /// Put the radio in a state, as if it had been configured so, and saved.
    func set(device: ProtoFixture? = nil, position: ProtoFixture? = nil, channels: [Int: ProtoFixture]? = nil) {
        lock.lock()
        if let device { _device = device.data; _savedDevice = device.data }
        if let position { _position = position.data; _savedPosition = position.data }
        if let channels { _channels = channels.mapValues { $0.data }; _savedChannels = _channels }
        lock.unlock()
    }

    /// Put one channel slot in a state, saved.
    func set(channel: ProtoFixture, at index: Int) {
        lock.lock(); _channels[index] = channel.data; _savedChannels[index] = channel.data; lock.unlock()
    }

    /// A power cycle: what was only in memory is gone, and what was saved is what
    /// the radio holds. An open edit is closed, the link is back and nothing asks
    /// for a restart.
    func restart() {
        lock.lock()
        _device = _savedDevice
        _position = _savedPosition
        _channels = _savedChannels
        _transactionOpen = false
        _restartRequested = false
        _linkCut = false
        _restarts += 1
        lock.unlock()
    }

    /// Save what is in memory, as the firmware does when it takes a change and no
    /// edit is open. Called with the lock held.
    private func saveLocked(config: Bool, channels: Bool) {
        if config { _savedDevice = _device; _savedPosition = _position }
        if channels { _savedChannels = _channels }
    }

    /// What the firmware does to a channel it stores (`Channels::fixupChannel`):
    /// the name "Default" is kept as no name.
    static func fixup(_ channel: Data) -> Data {
        guard let summary = MeshtasticAdminCodec.channelSummary(in: channel),
              summary.name == "Default",
              let fixed = ProtoFields.patch(channel, [
                  .nested(MeshtasticAdminCodec.ChannelField.settings,
                          [.string(MeshtasticAdminCodec.ChannelSettingsField.name, "")]),
              ]) else { return channel }
        return fixed
    }

    // MARK: - Taking a packet

    static func uptime() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// A packet reaches the radio. `deliver` is given the FromRadio bytes of each
    /// packet the radio sends back.
    func receive(_ packet: Packet, deliver: @escaping (Data) -> Void) {
        let arrived = Self.uptime()
        lock.lock()
        let delay = _processingDelay
        if delay <= 0 {
            lock.unlock()
            process(packet, received: arrived, deliver: deliver)
            return
        }
        waiting.append((packet, arrived, deliver))
        while waiting.count > _queueDepth {
            let old = waiting.removeFirst()
            _dropped.append(Record(packet: old.packet, kind: Self.kind(of: old.packet.admin), received: old.received))
        }
        let start = !busy
        if start { busy = true }
        lock.unlock()
        if start { scheduleNext(after: delay) }
    }

    private func scheduleNext(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.processNext() }
    }

    private func processNext() {
        lock.lock()
        guard !waiting.isEmpty else {
            busy = false
            lock.unlock()
            return
        }
        let next = waiting.removeFirst()
        let delay = _processingDelay
        lock.unlock()
        process(next.packet, received: next.received, deliver: next.deliver)
        scheduleNext(after: delay)
    }

    static func kind(of admin: Data) -> Kind {
        guard let top = FixtureReader.fields(admin), let first = top.first else { return .other }
        switch first.number {
        case RadioProto.Admin.getChannelRequest:
            let raw = FixtureReader.varint(first.number, in: admin) ?? 0
            return .getChannel(index: Int(raw) - 1)
        case RadioProto.Admin.getConfigRequest:
            let raw = FixtureReader.varint(first.number, in: admin) ?? 0
            return .getConfig(variant: Int(raw) + 1)
        case RadioProto.Admin.setConfig:
            let variant = FixtureReader.fields(first.value)?.first(where: { $0.wire == 2 })?.number ?? 0
            return .setConfig(variant: variant)
        case RadioProto.Admin.setChannel:
            return .setChannel(index: Int(FixtureReader.varint(RadioProto.Channel.index, in: first.value) ?? 0))
        case RadioProto.Admin.beginEditSettings:
            return .beginEdit
        case RadioProto.Admin.commitEditSettings:
            return .commitEdit
        default:
            return .other
        }
    }

    private func process(_ packet: Packet, received: UInt64, deliver: @escaping (Data) -> Void) {
        let kind = Self.kind(of: packet.admin)
        var answer: Data?
        var commit: (() -> Void)?

        // A packet for another node is not this radio's to act on.
        guard packet.to == nodeNum else {
            lock.lock()
            _processed.append(Record(packet: packet, kind: kind, received: received))
            lock.unlock()
            return
        }

        lock.lock()
        var cutLink = false
        switch kind {
        case .setConfig(let variant):
            if _stopsAnsweringAfterAWrite { _answersGets = false }
            if _holdsAnswersAfterAWrite { _holdAnswers = true }
            if _appliesConfigWrites,
               let top = FixtureReader.fields(packet.admin)?.first,
               let member = FixtureReader.fields(top.value)?.first(where: { $0.wire == 2 && $0.number == variant }) {
                if variant == RadioProto.Config.device {
                    let oldRole = FixtureReader.varint(RadioProto.Device.role, in: _device) ?? 0
                    let newRole = FixtureReader.varint(RadioProto.Device.role, in: member.value) ?? 0
                    _device = member.value
                    if newRole != oldRole, let defaults = _roleDefaults?(newRole) {
                        _position = defaults.data
                    }
                } else if variant == RadioProto.Config.position {
                    _position = member.value
                }
                // These configs need a restart. Outside an edit the radio saves
                // them, asks for the restart, and over Bluetooth cuts the link.
                if !_transactionOpen {
                    saveLocked(config: true, channels: false)
                    _restartRequested = true
                    cutLink = _cutsBluetoothOnRestartingWrite && !_linkCut
                }
            }
        case .setChannel(let index):
            if _stopsAnsweringAfterAWrite { _answersGets = false }
            if _holdsAnswersAfterAWrite { _holdAnswers = true }
            if _appliesChannelWrites, let top = FixtureReader.fields(packet.admin)?.first {
                _channels[index] = Self.fixup(_transformChannelWrite?(top.value) ?? top.value)
                // A channel saves itself, and asks for no restart.
                if !_transactionOpen { saveLocked(config: false, channels: true) }
            }
        case .beginEdit:
            _transactionOpen = true
        case .commitEdit:
            _transactionOpen = false
            _commits += 1
            saveLocked(config: true, channels: true)
            _restartRequested = true
            cutLink = _cutsBluetoothOnRestartingWrite && !_linkCut
            commit = _onCommit
        case .getConfig(let variant):
            if packet.wantResponse, _answersGets {
                let body: Data? = variant == RadioProto.Config.device ? _device
                    : variant == RadioProto.Config.position ? _position : nil
                if let body {
                    let config = ProtoFixture().message(variant, ProtoFixture(body))
                    answer = answerFrame(ProtoFixture().message(RadioProto.Admin.getConfigResponse, config),
                                         requestID: packet.packetID)
                }
            }
        case .getChannel(let index):
            if packet.wantResponse, _answersGets, let channel = _channels[index] {
                answer = answerFrame(ProtoFixture().bytes(RadioProto.Admin.getChannelResponse, channel),
                                     requestID: packet.packetID)
            }
        case .other:
            break
        }
        _processed.append(Record(packet: packet, kind: kind, received: received))
        let delay = _answerDelay
        let hold = _holdAnswers
        if let answer, hold { _held.append(answer) }
        var cut: (() -> Void)?
        if cutLink {
            _linkCut = true
            cut = _onLinkCut
        }
        lock.unlock()

        commit?()
        cut?()
        if let answer, !hold {
            if delay > 0 {
                queue.asyncAfter(deadline: .now() + delay) { deliver(answer) }
            } else {
                deliver(answer)
            }
        }
        if hold { heldDeliver = deliver }
    }

    private var heldDeliver: ((Data) -> Void)?

    /// Send the answers that were held.
    func releaseAnswers() {
        lock.lock()
        let answers = _held
        _held.removeAll()
        let deliver = heldDeliver
        lock.unlock()
        for answer in answers { deliver?(answer) }
    }

    /// The FromRadio frame of a packet from the radio to its own node, answering
    /// the request with this packet id. Called with the lock held.
    private func answerFrame(_ admin: ProtoFixture, requestID: UInt32) -> Data {
        nextAnswerID &+= 1
        let decoded = ProtoFixture()
            .varint(RadioProto.DataMessage.portnum, RadioProto.adminPortnum)
            .bytes(RadioProto.DataMessage.payload, admin.data)
            .fixed32(RadioProto.DataMessage.requestId, _answerRequestIDOverride ?? requestID)
        var packet = ProtoFixture()
            .fixed32(RadioProto.MeshPacket.from, _answerFromOverride ?? nodeNum)
            .fixed32(RadioProto.MeshPacket.to, nodeNum)
            .message(RadioProto.MeshPacket.decoded, decoded)
            .fixed32(RadioProto.MeshPacket.id, nextAnswerID)
            .varint(RadioProto.MeshPacket.hopLimit, 5)
        if _signals.rxSnr != 0 {
            packet = packet.fixed32(RadioProto.MeshPacket.rxSnr, _signals.rxSnr.bitPattern)
        }
        if _signals.rxRssi != 0 {
            packet = packet.varint(RadioProto.MeshPacket.rxRssi, UInt64(bitPattern: Int64(_signals.rxRssi)))
        }
        if _signals.viaMqtt {
            packet = packet.bool(RadioProto.MeshPacket.viaMqtt, true)
        }
        if _signals.transportMechanism != 0 {
            packet = packet.varint(RadioProto.MeshPacket.transportMechanism, _signals.transportMechanism)
        }
        return ProtoFixture().message(RadioProto.FromRadio.packet, packet).data
    }

    // MARK: - The download

    /// The FromRadio frames of a config download: my_info, the channels, the
    /// device and position configs and config_complete_id.
    func downloadFrames(configID: UInt64 = 1) -> [Data] {
        lock.lock()
        let device = _device, position = _position, slots = _channels
        lock.unlock()
        var frames: [Data] = []
        frames.append(RadioFixtures.myInfoFrame(nodeNum: nodeNum))
        for index in slots.keys.sorted() {
            frames.append(RadioFixtures.channelFrame(ProtoFixture(slots[index]!)))
        }
        frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.device, body: ProtoFixture(device)))
        frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.position, body: ProtoFixture(position)))
        frames.append(ProtoFixture().varint(RadioProto.FromRadio.configCompleteId, configID).data)
        return frames
    }
}
