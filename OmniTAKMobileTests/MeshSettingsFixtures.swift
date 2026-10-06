//
//  MeshSettingsFixtures.swift
//  OmniTAKMobileTests
//
//  Shared fixtures for the Meshtastic settings-write tests (#148): a protobuf
//  builder, the field numbers of the messages involved, and made-up radio
//  settings to write against.
//
//  The field numbers below are written out from config.proto, channel.proto,
//  admin.proto and mesh.proto on purpose. They are not read from the app's own
//  constants, so a wrong constant in the app fails a test instead of agreeing
//  with itself. Every name, key and number here is made up.
//

import Foundation

// MARK: - Field numbers

enum RadioProto {
    enum FromRadio {
        static let id = 1
        static let packet = 2
        static let myInfo = 3
        static let nodeInfo = 4
        static let config = 5
        static let configCompleteId = 7
        static let channel = 10
    }

    enum ToRadio {
        static let packet = 1
    }

    enum MeshPacket {
        static let from = 1
        static let to = 2
        static let decoded = 4
        static let id = 6
        static let rxTime = 7
        static let rxSnr = 8
        static let hopLimit = 9
        static let wantAck = 10
        static let rxRssi = 12
        static let viaMqtt = 14
        static let hopStart = 15
        static let transportMechanism = 21
    }

    enum DataMessage {
        static let portnum = 1
        static let payload = 2
        static let wantResponse = 3
        static let requestId = 6
    }

    enum Admin {
        static let getChannelRequest = 1
        static let getChannelResponse = 2
        static let getConfigRequest = 5
        static let getConfigResponse = 6
        static let setChannel = 33
        static let setConfig = 34
        static let beginEditSettings = 64
        static let commitEditSettings = 65
    }

    /// The oneof inside `Config`.
    enum Config {
        static let device = 1
        static let position = 2
        static let power = 3
        static let network = 4
        static let display = 5
        static let lora = 6
        static let bluetooth = 7
        static let security = 8
    }

    enum Device {
        static let role = 1
        static let buttonGpio = 4
        static let buzzerGpio = 5
        static let rebroadcastMode = 6
        static let nodeInfoBroadcastSecs = 7
        static let doubleTapAsButtonPress = 8
        static let tzdef = 11
        static let ledHeartbeatDisabled = 12
        static let buzzerMode = 13
    }

    enum Position {
        static let broadcastSecs = 1
        static let smartEnabled = 2
        static let fixedPosition = 3
        static let gpsUpdateInterval = 5
        static let flags = 7
        static let smartMinimumDistance = 10
        static let smartMinimumIntervalSecs = 11
        static let gpsMode = 13
    }

    enum Channel {
        static let index = 1
        static let settings = 2
        static let role = 3
    }

    enum ChannelSettings {
        static let psk = 2
        static let name = 3
        static let id = 4
        static let uplinkEnabled = 5
        static let downlinkEnabled = 6
        static let moduleSettings = 7
        static let useAead = 8
    }

    enum ModuleSettings {
        static let positionPrecision = 1
        static let isMuted = 2
    }

    /// Role enum values (channel.proto, config.proto).
    enum ChannelRole { static let disabled: UInt64 = 0, primary: UInt64 = 1, secondary: UInt64 = 2 }
    enum DeviceRole { static let client: UInt64 = 0, router: UInt64 = 2, sensor: UInt64 = 6, tak: UInt64 = 7 }
    enum Rebroadcast { static let all: UInt64 = 0, localOnly: UInt64 = 2, knownOnly: UInt64 = 3, coreOnly: UInt64 = 5 }

    /// Portnum of ADMIN_APP (portnums.proto).
    static let adminPortnum: UInt64 = 6

    /// A field number no proto has yet. Above 15, so it takes a two-byte tag.
    static let futureField = 300
}

// MARK: - Builder

/// Builds a protobuf message from field numbers and wire types. Tags are
/// varints, so a field number above 15 takes two bytes, as it does from a radio.
struct ProtoFixture: Equatable {
    private(set) var data = Data()

    init(_ data: Data = Data()) {
        self.data = data
    }

    static func varintBytes(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var v = value
        while v > 0x7F {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    func raw(_ bytes: [UInt8]) -> ProtoFixture {
        var copy = self
        copy.data.append(contentsOf: bytes)
        return copy
    }

    private func field(_ number: Int, wire: UInt64, _ body: [UInt8]) -> ProtoFixture {
        raw(ProtoFixture.varintBytes(UInt64(number) << 3 | wire) + body)
    }

    func varint(_ number: Int, _ value: UInt64) -> ProtoFixture {
        field(number, wire: 0, ProtoFixture.varintBytes(value))
    }

    func bool(_ number: Int, _ value: Bool) -> ProtoFixture {
        varint(number, value ? 1 : 0)
    }

    func fixed32(_ number: Int, _ value: UInt32) -> ProtoFixture {
        field(number, wire: 5, (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }

    func fixed64(_ number: Int, _ value: UInt64) -> ProtoFixture {
        field(number, wire: 1, (0..<8).map { UInt8((value >> (8 * UInt64($0))) & 0xFF) })
    }

    func bytes(_ number: Int, _ value: Data) -> ProtoFixture {
        field(number, wire: 2, ProtoFixture.varintBytes(UInt64(value.count)) + [UInt8](value))
    }

    func string(_ number: Int, _ value: String) -> ProtoFixture {
        bytes(number, Data(value.utf8))
    }

    func message(_ number: Int, _ value: ProtoFixture) -> ProtoFixture {
        bytes(number, value.data)
    }
}

// MARK: - An independent reader

/// Reads the top-level fields of a message without using the code under test.
/// Returns nil for anything malformed. Used to check what the app wrote.
enum FixtureReader {
    struct Field: Equatable {
        let number: Int
        let wire: Int
        /// The tag and the value as written.
        let raw: Data
        /// The value: the bytes after the length for a length-delimited field.
        let value: Data
    }

    static func fields(_ message: Data) -> [Field]? {
        let bytes = [UInt8](message)
        var out: [Field] = []
        var i = 0

        func varint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count && shift < 64 {
                let b = bytes[i]
                i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while i < bytes.count {
            let start = i
            guard let tag = varint() else { return nil }
            let number = Int(tag >> 3)
            let wire = Int(tag & 7)
            guard number > 0 else { return nil }
            let valueStart: Int
            switch wire {
            case 0:
                valueStart = i
                guard varint() != nil else { return nil }
            case 1:
                guard bytes.count - i >= 8 else { return nil }
                valueStart = i
                i += 8
            case 2:
                guard let length = varint(), length <= UInt64(bytes.count - i) else { return nil }
                valueStart = i
                i += Int(length)
            case 5:
                guard bytes.count - i >= 4 else { return nil }
                valueStart = i
                i += 4
            default:
                return nil
            }
            out.append(Field(number: number, wire: wire,
                             raw: Data(bytes[start..<i]), value: Data(bytes[valueStart..<i])))
        }
        return out
    }

    /// The value of a varint field, from `message`. Nil when absent or malformed.
    static func varint(_ number: Int, in message: Data) -> UInt64? {
        guard let field = fields(message)?.last(where: { $0.number == number && $0.wire == 0 }) else { return nil }
        var result: UInt64 = 0
        for (shift, byte) in field.value.enumerated() {
            result |= UInt64(byte & 0x7F) << UInt64(7 * shift)
        }
        return result
    }

    /// The bytes of a length-delimited field, from `message`.
    static func bytes(_ number: Int, in message: Data) -> Data? {
        fields(message)?.last(where: { $0.number == number && $0.wire == 2 })?.value
    }

    /// Every field of `message` except those with a number in `except`, as
    /// their raw bytes in order.
    static func rawFields(of message: Data, except: Set<Int> = []) -> [Data]? {
        fields(message)?.filter { !except.contains($0.number) }.map(\.raw)
    }

    /// The `Config` message inside an `AdminMessage{ set_config }`: the field
    /// number of the sub-config it carries and the bytes of that sub-config.
    /// Nil unless the admin message holds exactly that and nothing else.
    static func setConfig(in admin: Data) -> (variant: Int, body: Data)? {
        guard let top = fields(admin), top.count == 1,
              top[0].number == RadioProto.Admin.setConfig, top[0].wire == 2,
              let config = fields(top[0].value), config.count == 1,
              config[0].wire == 2 else { return nil }
        return (config[0].number, config[0].value)
    }

    /// The `Channel` inside an `AdminMessage{ set_channel }`. Nil unless the
    /// admin message holds exactly that and nothing else.
    static func setChannel(in admin: Data) -> Data? {
        guard let top = fields(admin), top.count == 1,
              top[0].number == RadioProto.Admin.setChannel, top[0].wire == 2 else { return nil }
        return top[0].value
    }

    /// The `AdminMessage` and the id of the packet in a ToRadio frame. Nil unless
    /// the frame is an admin packet.
    static func adminPacket(in toRadio: Data) -> (admin: Data, packetID: UInt32, to: UInt32, wantResponse: Bool, wantAck: Bool)? {
        guard let top = fields(toRadio),
              let packet = top.first(where: { $0.number == RadioProto.ToRadio.packet && $0.wire == 2 }),
              let mp = fields(packet.value),
              let decoded = mp.first(where: { $0.number == RadioProto.MeshPacket.decoded && $0.wire == 2 }),
              varint(RadioProto.DataMessage.portnum, in: decoded.value) == RadioProto.adminPortnum,
              let admin = bytes(RadioProto.DataMessage.payload, in: decoded.value) else { return nil }
        func fixed32(_ number: Int) -> UInt32 {
            guard let field = mp.last(where: { $0.number == number && $0.wire == 5 }) else { return 0 }
            return field.value.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        return (admin, fixed32(RadioProto.MeshPacket.id), fixed32(RadioProto.MeshPacket.to),
                (varint(RadioProto.DataMessage.wantResponse, in: decoded.value) ?? 0) != 0,
                (varint(RadioProto.MeshPacket.wantAck, in: packet.value) ?? 0) != 0)
    }
}

// MARK: - Made-up radio settings

enum RadioFixtures {

    /// A 32-byte channel key that belongs to no real channel.
    static let key = Data((0..<32).map { UInt8(0x40 &+ UInt8($0) &* 5) })

    /// Another key of the same length.
    static let otherKey = Data((0..<32).map { UInt8(0xA0 &- UInt8($0) &* 3) })

    static let timeZone = "XST7XDT,M3.2.0,M11.1.0"

    /// A device config as a radio with a few non-default settings sends it:
    /// role CLIENT and rebroadcast ALL are defaults and absent. Carries a field
    /// the app knows nothing about (a varint at 99 and a string at `futureField`).
    static func deviceConfig() -> ProtoFixture {
        ProtoFixture()
            .varint(RadioProto.Device.buttonGpio, 12)
            .varint(RadioProto.Device.buzzerGpio, 13)
            .varint(RadioProto.Device.nodeInfoBroadcastSecs, 10_800)
            .bool(RadioProto.Device.doubleTapAsButtonPress, true)
            .string(RadioProto.Device.tzdef, timeZone)
            .bool(RadioProto.Device.ledHeartbeatDisabled, true)
            .varint(RadioProto.Device.buzzerMode, 2)
            .varint(99, 5)
            .string(RadioProto.futureField, "future")
    }

    /// A position config with the GPS on, smart broadcast on and a few more
    /// non-default settings, and a field the app does not know.
    static func positionConfig(broadcastSecs: UInt64 = 3600) -> ProtoFixture {
        ProtoFixture()
            .varint(RadioProto.Position.broadcastSecs, broadcastSecs)
            .bool(RadioProto.Position.smartEnabled, true)
            .varint(RadioProto.Position.gpsUpdateInterval, 120)
            .varint(RadioProto.Position.flags, 811)
            .varint(RadioProto.Position.smartMinimumDistance, 150)
            .varint(RadioProto.Position.smartMinimumIntervalSecs, 300)
            .varint(RadioProto.Position.gpsMode, 1)
            .fixed32(77, 0xCAFE_F00D)
    }

    /// A channel slot in use, with settings the app does not write: an id,
    /// uplink, location precision, mute, AEAD, and a field it does not know.
    static func channel(
        index: Int,
        name: String = "alpha",
        psk: Data = key,
        role: UInt64 = RadioProto.ChannelRole.secondary
    ) -> ProtoFixture {
        let moduleSettings = ProtoFixture()
            .varint(RadioProto.ModuleSettings.positionPrecision, 13)
            .bool(RadioProto.ModuleSettings.isMuted, true)
        let settings = ProtoFixture()
            .bytes(RadioProto.ChannelSettings.psk, psk)
            .string(RadioProto.ChannelSettings.name, name)
            .fixed32(RadioProto.ChannelSettings.id, 0x0102_0304)
            .bool(RadioProto.ChannelSettings.uplinkEnabled, true)
            .message(RadioProto.ChannelSettings.moduleSettings, moduleSettings)
            .bool(RadioProto.ChannelSettings.useAead, true)
            .varint(40, 9)
        // Slot 0 is index 0, a default, so a radio leaves the field out.
        let head = index == 0 ? ProtoFixture() : ProtoFixture().varint(RadioProto.Channel.index, UInt64(index))
        return head
            .message(RadioProto.Channel.settings, settings)
            .varint(RadioProto.Channel.role, role)
    }

    // MARK: Factory settings

    /// A device config from a radio nobody has configured. The role (CLIENT) and
    /// the rebroadcast mode (ALL) are defaults, so the radio leaves both fields
    /// out. This is the message that a screen which treats a missing field as
    /// "unknown" fills with its own default.
    static func factoryDeviceConfig() -> ProtoFixture {
        ProtoFixture().varint(RadioProto.Device.nodeInfoBroadcastSecs, 10_800)
    }

    /// A position config at the radio's own settings: just the interval.
    static func factoryPositionConfig(broadcastSecs: UInt64 = 900) -> ProtoFixture {
        ProtoFixture().varint(RadioProto.Position.broadcastSecs, broadcastSecs)
    }

    /// The primary channel of a radio nobody has configured: no name, the
    /// one-byte default key, role PRIMARY. Slot 0 is index 0, so no index.
    static func factoryPrimaryChannel() -> ProtoFixture {
        ProtoFixture()
            .message(RadioProto.Channel.settings, ProtoFixture().bytes(RadioProto.ChannelSettings.psk, Data([0x01])))
            .varint(RadioProto.Channel.role, RadioProto.ChannelRole.primary)
    }

    /// Eight channel slots of a factory radio: the unnamed primary, then seven
    /// disabled slots.
    static func factoryChannelSlots() -> [Int: ProtoFixture] {
        var slots: [Int: ProtoFixture] = [:]
        for index in 1...7 { slots[index] = disabledChannel(index: index) }
        slots[0] = factoryPrimaryChannel()
        return slots
    }

    /// A slot the radio has disabled: the index and nothing else. Slot 0 is a
    /// default and sends an empty message.
    static func disabledChannel(index: Int) -> ProtoFixture {
        index == 0 ? ProtoFixture() : ProtoFixture().varint(RadioProto.Channel.index, UInt64(index))
    }

    /// The FromRadio frame for a sub-config.
    static func configFrame(variant: Int, body: ProtoFixture, id: UInt64 = 7) -> Data {
        ProtoFixture()
            .varint(RadioProto.FromRadio.id, id)
            .message(RadioProto.FromRadio.config, ProtoFixture().message(variant, body))
            .data
    }

    /// The FromRadio frame for a channel slot.
    static func channelFrame(_ channel: ProtoFixture, id: UInt64 = 8) -> Data {
        ProtoFixture()
            .varint(RadioProto.FromRadio.id, id)
            .message(RadioProto.FromRadio.channel, channel)
            .data
    }

    static func myInfoFrame(nodeNum: UInt32) -> Data {
        ProtoFixture()
            .message(RadioProto.FromRadio.myInfo, ProtoFixture().varint(1, UInt64(nodeNum)))
            .data
    }

    /// Eight channel slots with the primary named "simtest", the slots in `used`
    /// in use, and the rest disabled.
    static func channelSlots(used: Set<Int>) -> [Int: ProtoFixture] {
        var out: [Int: ProtoFixture] = [:]
        for index in 0...7 {
            out[index] = used.contains(index)
                ? channel(index: index, name: "used\(index)", psk: otherKey)
                : disabledChannel(index: index)
        }
        out[0] = channel(index: 0, name: "simtest", role: RadioProto.ChannelRole.primary)
        return out
    }

    /// Eight channel slots as a radio sends them: slot 0 primary, slot 1 in
    /// use, the rest disabled.
    static func channelSlots() -> [Int: ProtoFixture] {
        var slots: [Int: ProtoFixture] = [:]
        for index in 0...7 { slots[index] = disabledChannel(index: index) }
        slots[0] = channel(index: 0, name: "simtest", role: RadioProto.ChannelRole.primary)
        slots[1] = channel(index: 1, name: "bravo", psk: otherKey)
        return slots
    }
}
