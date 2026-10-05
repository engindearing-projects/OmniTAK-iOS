//
//  MeshtasticAdminCodec.swift
//  OmniTAK Mobile
//
//  Clean-room encoder for the Meshtastic `AdminMessage` — the protobuf carried
//  on the ADMIN_APP portnum (6) that writes channel + config settings to a
//  radio. This is the "apply an imported/created channel to the radio" half of
//  the channel-share feature (OmniTAK-iOS #101): the share codec produces the
//  URL/QR, this codec produces the bytes that program the local radio.
//
//  Closed-test feedback (PatoG1899): operators want to (a) create + share a
//  channel from inside OmniTAK and (b) constrain rebroadcast to the current /
//  known channel only. (b) is DeviceConfig.rebroadcast_mode = KNOWN_ONLY /
//  LOCAL_ONLY, set via AdminMessage.set_config.
//
//  Licensing: independent clean-room implementation. Protobuf field NUMBERS and
//  enum VALUES are an interface (facts from the published wire spec), not
//  copyrightable expression — we hand-roll the bytes here exactly as
//  TAKPacketV2Codec / ATAKPluginSerializer already do, copying NO GPL proto text
//  or Meshtastic-SDK code.
//
//  Writes change one field and send the rest back (#148)
//  -----------------------------------------------------
//  The radio does not merge a `set_config` or `set_channel` into what it has. It
//  replaces the whole sub-config (or channel) with the message. A message that
//  carries only the field the operator changed therefore puts every other field
//  of that sub-config back to its default: the position interval turned the GPS
//  off, the device role cleared the time zone, a channel rename reset the
//  location precision. So nothing in this file builds a set_config or
//  set_channel from scratch. Each encoder takes the bytes the radio reported for
//  that sub-config or channel, changes the fields the operator edited and leaves
//  every other field as it was (ProtoFields). The bytes are the radio's answer to
//  a get request made just before the write (MeshtasticManager asks every time:
//  what was downloaded at connect is only as fresh as the connection), and the
//  caller reads the radio again afterwards to see what it holds.
//
//  A key is only changed when asked (#148): `KeyChange.keep` leaves the radio's
//  key as it is, `.set` replaces it, and making the channel open is its own case,
//  `.clear`, which writes the one byte 0: with no key at all a secondary channel
//  uses the primary's key (MeshtasticChannelKey).
//  A new channel goes into a slot the radio reports as disabled and is built
//  from that slot's index alone (`encodeNewChannel`), so it inherits nothing from
//  whatever used the slot before. That is the one message here that does not
//  start from the old bytes, and it only exists for a slot the radio says is
//  empty.
//
//  Wire layout (field numbers / enum values are facts):
//      AdminMessage.get_channel_request  = 1  (uint32: channel index + 1)
//      AdminMessage.get_channel_response = 2  (Channel submessage)
//      AdminMessage.get_config_request   = 5  (ConfigType enum: DEVICE=0, POSITION=1)
//      AdminMessage.get_config_response  = 6  (Config submessage)
//      AdminMessage.set_channel = 33  (Channel submessage)
//      AdminMessage.set_config  = 34  (Config submessage)
//      AdminMessage.begin_edit_settings  = 64 (bool)
//      AdminMessage.commit_edit_settings = 65 (bool)
//      Data.request_id = 6 (fixed32): the id of the MeshPacket a reply answers
//      Channel{ index=1 (int32), settings=2 (ChannelSettings), role=3 (Role enum) }
//      ChannelSettings{ psk=2 (bytes), name=3 (string); others are left as they are }
//      Channel.Role: DISABLED=0, PRIMARY=1, SECONDARY=2
//      Config.device   = 1  (DeviceConfig submessage)
//      Config.position = 2  (PositionConfig submessage)
//      DeviceConfig{ role=1 (Role enum), rebroadcast_mode=6 (RebroadcastMode enum) }
//      DeviceConfig.Role: CLIENT=0, ROUTER=2, TRACKER=5, TAK=7, TAK_TRACKER=10
//      DeviceConfig.RebroadcastMode: ALL=0, LOCAL_ONLY=2, KNOWN_ONLY=3, NONE=4
//      PositionConfig{ position_broadcast_secs=1 (uint32) }
//

import Foundation

enum MeshtasticAdminCodec {

    /// Meshtastic PortNum for AdminMessage traffic.
    static let adminPortnum: UInt64 = 6

    /// The address a packet takes to reach every node.
    static let broadcastNodeNum: UInt32 = 0xFFFF_FFFF

    // MARK: - Field numbers

    enum AdminField {
        static let getChannelRequest = 1
        static let getChannelResponse = 2
        static let getConfigRequest = 5
        static let getConfigResponse = 6
        static let setChannel = 33
        static let setConfig = 34
        static let beginEditSettings = 64
        static let commitEditSettings = 65
    }

    /// The enum `get_config_request` carries: which sub-config to send. For the
    /// two this app reads it is the sub-config's field number inside `Config`
    /// minus one (measured against firmware 2.7.26: device 0 is answered with
    /// `Config.device`, position 1 with `Config.position`).
    enum ConfigType: UInt64 {
        case device = 0
        case position = 1

        /// The field number of the sub-config inside `Config`.
        var variant: Int { Int(rawValue) + 1 }

        init?(variant: Int) {
            switch variant {
            case ConfigVariant.device:   self = .device
            case ConfigVariant.position: self = .position
            default: return nil
            }
        }
    }

    /// The longest a channel name may be. The firmware's string field holds 11
    /// bytes and a terminator, and a longer name makes it drop the whole message.
    static let maxChannelNameBytes = 11

    /// The oneof inside `Config`: which sub-config a Config message carries.
    enum ConfigVariant {
        static let device = 1
        static let position = 2
        static let power = 3
        static let network = 4
        static let display = 5
        static let lora = 6
        static let bluetooth = 7
        static let security = 8
    }

    enum DeviceConfigField {
        static let role = 1
        static let rebroadcastMode = 6
    }

    enum PositionConfigField {
        static let broadcastSecs = 1
    }

    enum ChannelField {
        static let index = 1
        static let settings = 2
        static let role = 3
    }

    enum ChannelSettingsField {
        static let psk = 2
        static let name = 3
    }

    // MARK: - Channel.Role (clean-room enum mirroring the wire values)

    enum ChannelRole: UInt64 {
        case disabled = 0
        case primary = 1
        case secondary = 2
    }

    // MARK: - DeviceConfig.Role (subset OmniTAK exposes)

    enum DeviceRole: UInt64, CaseIterable {
        case client = 0
        case router = 2
        case tracker = 5
        case tak = 7
        case takTracker = 10

        var displayName: String {
            switch self {
            case .client:     return "Client"
            case .router:     return "Router"
            case .tracker:    return "Tracker"
            case .tak:        return "TAK"
            case .takTracker: return "TAK Tracker"
            }
        }
    }

    // MARK: - DeviceConfig.RebroadcastMode (the PatoG1899 "scope" ask)

    enum RebroadcastMode: UInt64, CaseIterable {
        case all = 0
        case localOnly = 2
        case knownOnly = 3
        /// The proto's NONE. Not named `none`: the setters take an optional
        /// mode, where nil means "leave it", and `.none` would be read as nil.
        case noRebroadcast = 4

        var displayName: String {
            switch self {
            case .all:           return "All (default)"
            case .localOnly:     return "Local mesh only"
            case .knownOnly:     return "Known channels only"
            case .noRebroadcast: return "None (no rebroadcast)"
            }
        }
    }

    // MARK: - A write

    /// A settings write built from what the radio reported.
    struct Write: Equatable {
        /// The `AdminMessage` to send on the ADMIN_APP portnum.
        let payload: Data
        /// The sub-config (or channel) as the radio will hold it once it applies
        /// `payload`, if it applies it as sent. A role change makes the firmware
        /// change more than that, so the next edit starts from a fresh read of the
        /// radio, not from this.
        let stored: Data
        /// True when `stored` is what the radio already held: every value asked
        /// for was one it already had. There is nothing to send then, and the
        /// radio would restart for nothing if it were sent.
        let changesNothing: Bool

        // Only the encoders below make one, so a Write always came from the
        // radio's own bytes.
        fileprivate init(payload: Data, stored: Data, current: Data) {
            self.payload = payload
            self.stored = stored
            self.changesNothing = stored == current
        }
    }

    // MARK: - set_channel

    /// What to do with a channel's key.
    enum KeyChange: Equatable, CustomStringConvertible {
        /// Leave the key as the radio has it.
        case keep
        /// Replace it. The bytes are a key of a valid length, never empty.
        case set(Data)
        /// Turn encryption off: the key becomes the one byte 0, which is how the
        /// radio is told "open". No key at all would not do it: on a secondary
        /// channel the radio takes a missing key to mean the primary's. Only
        /// ever asked for explicitly.
        case clear

        // Key bytes are never printed.
        var description: String {
            switch self {
            case .keep: return "keep"
            case .set(let key): return "set(\(key.count) bytes)"
            case .clear: return "clear"
            }
        }
    }

    /// `AdminMessage{ set_channel = Channel{...} }` for a channel slot that is in
    /// use: the channel as the radio reported it with its name, role and, when
    /// asked, its key changed.
    ///
    /// Every other field of the channel and of its settings stays as it was:
    /// the id, uplink and downlink flags, the location precision and mute
    /// setting in `module_settings`, and anything this app does not know about.
    /// An empty `name` removes the name field, which is what the operator asked
    /// for when they gave none: a channel with no name stays without one, and
    /// nothing is put in its place. The key is only touched for `.set` and
    /// `.clear`. When the channel already has this name, key and role, the
    /// result `changesNothing`.
    ///
    /// - Parameter current: the Channel message the radio sent for this slot.
    /// - Returns: nil when `current` is not a well-formed message, or `.set` has
    ///   no bytes.
    static func encodeSetChannel(
        current: Data,
        name: String,
        key: KeyChange,
        role: ChannelRole
    ) -> Write? {
        var settingsEdits: [ProtoFields.Edit] = [.string(ChannelSettingsField.name, name)]
        switch key {
        case .keep:
            break
        case .set(let bytes):
            guard !bytes.isEmpty else { return nil }
            settingsEdits.append(.bytes(ChannelSettingsField.psk, bytes))
        case .clear:
            settingsEdits.append(.bytes(ChannelSettingsField.psk, MeshtasticChannelKey.open))
        }
        guard let stored = ProtoFields.patch(current, [
            .nested(ChannelField.settings, settingsEdits),
            .varint(ChannelField.role, role.rawValue),
        ]) else { return nil }

        let admin = ProtoFields.messageField(AdminField.setChannel, stored).raw
        return Write(payload: admin, stored: stored, current: current)
    }

    /// `AdminMessage{ set_channel = Channel{...} }` for a new SECONDARY channel in
    /// a slot the radio reports as disabled.
    ///
    /// Built from the slot's index alone: the old occupant's uplink and downlink
    /// flags, location precision, mute setting and id are not carried over,
    /// because they belong to a channel that is gone.
    ///
    /// - Parameters:
    ///   - index: 1 to 7. Slot 0 is the primary and is never a new channel.
    ///   - current: the Channel message the radio sent for the slot. It must say
    ///     the slot is disabled and be the slot `index`.
    ///   - psk: the key: 16 or 32 bytes, or the one byte 0 for an open channel
    ///     (`MeshtasticChannelKey.isUsable`). Never empty: on a secondary channel
    ///     the radio would take no key to mean the primary's.
    /// - Returns: nil when the slot is not one the radio reported as disabled, or
    ///   the key is not one the radio would take.
    static func encodeNewChannel(index: Int, current: Data, name: String, psk: Data) -> Write? {
        guard (1...7).contains(index),
              MeshtasticChannelKey.isUsable(psk),
              let slot = channelSummary(in: current),
              slot.index == index,
              slot.role == ChannelRole.disabled.rawValue else { return nil }

        let base = ProtoFields.serialize([ProtoFields.varintField(ChannelField.index, UInt64(index))])
        guard let stored = ProtoFields.patch(base, [
            .nested(ChannelField.settings, [
                .bytes(ChannelSettingsField.psk, psk),
                .string(ChannelSettingsField.name, name),
            ]),
            .varint(ChannelField.role, ChannelRole.secondary.rawValue),
        ]) else { return nil }

        let admin = ProtoFields.messageField(AdminField.setChannel, stored).raw
        return Write(payload: admin, stored: stored, current: current)
    }

    // MARK: - Reading a channel

    /// The parts of a channel the app reads back to check a write. The key is
    /// kept for comparing and is never printed.
    struct ChannelSummary: Equatable, CustomStringConvertible {
        let index: Int
        let name: String
        let psk: Data
        let role: UInt64

        var isDisabled: Bool { role == ChannelRole.disabled.rawValue }

        var description: String {
            "slot \(index) \"\(name)\" role \(role) key \(psk.count) bytes"
        }
    }

    /// The index, name, key and role of a Channel message. Nil when it is not
    /// well formed, including when its settings are not.
    static func channelSummary(in channel: Data) -> ChannelSummary? {
        guard let fields = ProtoFields.parse(channel) else { return nil }
        var index = 0
        if let raw = ProtoFields.varint(ChannelField.index, in: fields) {
            guard raw <= UInt64(Int32.max) else { return nil }
            index = Int(raw)
        }
        let role = ProtoFields.varint(ChannelField.role, in: fields) ?? 0

        var name = ""
        var psk = Data()
        if let settings = fields.last(where: { $0.number == ChannelField.settings }) {
            guard settings.wireType == 2, let inner = ProtoFields.parse(settings.value) else { return nil }
            if let field = inner.last(where: { $0.number == ChannelSettingsField.name && $0.wireType == 2 }) {
                name = String(decoding: field.value, as: UTF8.self)
            }
            if let field = inner.last(where: { $0.number == ChannelSettingsField.psk && $0.wireType == 2 }) {
                psk = field.value
            }
        }
        return ChannelSummary(index: index, name: name, psk: psk, role: role)
    }

    // MARK: - get_channel (reading a channel back)

    /// `AdminMessage{ get_channel_request = index + 1 }`. The radio answers with
    /// `get_channel_response` only when the packet that carries this asks for a
    /// response (`toRadioFrame(wantResponse: true)`).
    static func encodeGetChannelRequest(index: Int) -> Data {
        ProtoFields.varintField(AdminField.getChannelRequest, UInt64(index + 1)).raw
    }

    /// The Channel message in an `AdminMessage{ get_channel_response }`, or nil
    /// when the message is anything else or is not well formed.
    static func channelResponse(in adminPayload: Data) -> Data? {
        guard let fields = ProtoFields.parse(adminPayload),
              let response = fields.last(where: { $0.number == AdminField.getChannelResponse }),
              response.wireType == 2 else { return nil }
        return response.value
    }

    // MARK: - get_config (reading a sub-config)

    /// `AdminMessage{ get_config_request = type }`. The value is written even
    /// when it is 0: the request is a member of a oneof, and being present is
    /// what asks. The radio answers only a packet that asks for a response.
    static func encodeGetConfigRequest(_ type: ConfigType) -> Data {
        ProtoFields.varintField(AdminField.getConfigRequest, type.rawValue).raw
    }

    /// The sub-config in an `AdminMessage{ get_config_response }`: the field
    /// number it has inside `Config` and the bytes of the sub-config message.
    /// Nil when the message is anything else, is not well formed, or carries no
    /// sub-config.
    static func configResponse(in adminPayload: Data) -> (variant: Int, body: Data)? {
        guard let fields = ProtoFields.parse(adminPayload),
              let response = fields.last(where: { $0.number == AdminField.getConfigResponse }),
              response.wireType == 2,
              let config = ProtoFields.parse(response.value),
              let member = config.last(where: { $0.wireType == 2 }) else { return nil }
        return (member.number, member.value)
    }

    // MARK: - Edit transaction

    /// `AdminMessage{ begin_edit_settings = true }`. Until the matching commit
    /// the radio applies what it receives and holds off saving it.
    static func encodeBeginEditSettings() -> Data {
        ProtoFields.boolField(AdminField.beginEditSettings, true).raw
    }

    /// `AdminMessage{ commit_edit_settings = true }`: save what was edited. The
    /// radio restarts to apply it.
    static func encodeCommitEditSettings() -> Data {
        ProtoFields.boolField(AdminField.commitEditSettings, true).raw
    }

    // MARK: - An answer to a get request

    /// A `get_config_response` or `get_channel_response` as it arrived in a
    /// MeshPacket, with what is needed to decide whether it answers a request
    /// this app sent (MeshtasticManager decides).
    struct Answer: Equatable {
        enum Content: Equatable {
            case config(variant: Int, body: Data)
            case channel(index: Int, body: Data)
        }

        /// MeshPacket.from.
        let from: UInt32
        /// Data.request_id, nil when the packet has none.
        let requestId: UInt32?
        /// True when the packet carries any receive metadata: a signal
        /// strength, a signal-to-noise ratio, an MQTT flag or a transport
        /// mechanism. A packet the radio makes for its own phone carries none.
        let hasReceiveSignals: Bool
        let content: Content
    }

    /// The answer a MeshPacket carries, or nil when it is not an admin
    /// get_config_response or get_channel_response.
    static func answer(in frame: MeshtasticProtoDecoder.MeshPacketFrame) -> Answer? {
        guard frame.portNum == Int(adminPortnum) else { return nil }
        let signals = (frame.rxRssi ?? 0) != 0
            || (frame.rxSnr ?? 0) != 0
            || frame.viaMQTT
            || frame.transportMechanism != 0
        if let channel = channelResponse(in: frame.payload) {
            guard let summary = channelSummary(in: channel) else { return nil }
            return Answer(from: frame.from, requestId: frame.requestId, hasReceiveSignals: signals,
                          content: .channel(index: summary.index, body: channel))
        }
        if let config = configResponse(in: frame.payload) {
            return Answer(from: frame.from, requestId: frame.requestId, hasReceiveSignals: signals,
                          content: .config(variant: config.variant, body: config.body))
        }
        return nil
    }

    // MARK: - set_config (device role + rebroadcast scope)

    /// `AdminMessage{ set_config = Config{ device = DeviceConfig{...} } }`: the
    /// device config as the radio reported it with the role and rebroadcast
    /// scope changed. A nil argument leaves that field as the radio has it.
    ///
    /// A field is only written when its value differs from the radio's. A radio
    /// at its defaults sends no role and no rebroadcast mode, which means CLIENT
    /// and ALL, so asking for CLIENT of a radio that has none changes nothing,
    /// and asking for TAK is the only thing that adds a role. When no value
    /// differs the result `changesNothing`.
    ///
    /// The time zone, LED, button and buzzer settings stay as they were.
    ///
    /// - Parameter current: the DeviceConfig message the radio sent.
    /// - Returns: nil when `current` is not a well-formed message.
    static func encodeSetDeviceConfig(
        current: Data,
        role: DeviceRole?,
        rebroadcastMode: RebroadcastMode?
    ) -> Write? {
        guard let currentRole = deviceRole(in: current),
              let currentMode = self.rebroadcastMode(in: current) else { return nil }
        var edits: [ProtoFields.Edit] = []
        if let role, role.rawValue != currentRole {
            edits.append(.varint(DeviceConfigField.role, role.rawValue))
        }
        if let rebroadcastMode, rebroadcastMode.rawValue != currentMode {
            edits.append(.varint(DeviceConfigField.rebroadcastMode, rebroadcastMode.rawValue))
        }
        return encodeSetConfig(variant: ConfigVariant.device, current: current, edits: edits)
    }

    // MARK: - set_config (position broadcast interval)

    /// `AdminMessage{ set_config = Config{ position = PositionConfig{...} } }`:
    /// the position config as the radio reported it with
    /// `position_broadcast_secs` changed. When the radio already has that
    /// interval the result `changesNothing`.
    ///
    /// The GPS mode, position flags, smart-broadcast settings and the GPS update
    /// interval stay as they were.
    ///
    /// - Parameter current: the PositionConfig message the radio sent.
    /// - Returns: nil when `current` is not a well-formed message.
    static func encodeSetPositionBroadcastInterval(current: Data, seconds: UInt32) -> Write? {
        guard let currentSeconds = positionBroadcastSeconds(in: current) else { return nil }
        let edits: [ProtoFields.Edit] = seconds == currentSeconds
            ? []
            : [.varint(PositionConfigField.broadcastSecs, UInt64(seconds))]
        return encodeSetConfig(variant: ConfigVariant.position, current: current, edits: edits)
    }

    private static func encodeSetConfig(variant: Int, current: Data, edits: [ProtoFields.Edit]) -> Write? {
        guard let stored = ProtoFields.patch(current, edits) else { return nil }
        let config = ProtoFields.messageField(variant, stored).raw
        let admin = ProtoFields.messageField(AdminField.setConfig, config).raw
        return Write(payload: admin, stored: stored, current: current)
    }

    // MARK: - Reading what the radio reported

    /// `DeviceConfig.role` of a DeviceConfig message. 0 (CLIENT) when the
    /// message does not carry the field, because the radio leaves a default out.
    /// Nil when the message is malformed.
    static func deviceRole(in deviceConfig: Data) -> UInt64? {
        varint(DeviceConfigField.role, in: deviceConfig)
    }

    /// `DeviceConfig.rebroadcast_mode`. 0 (ALL) when absent, nil when malformed.
    static func rebroadcastMode(in deviceConfig: Data) -> UInt64? {
        varint(DeviceConfigField.rebroadcastMode, in: deviceConfig)
    }

    /// `PositionConfig.position_broadcast_secs`. 0 when absent, nil when malformed.
    static func positionBroadcastSeconds(in positionConfig: Data) -> UInt32? {
        varint(PositionConfigField.broadcastSecs, in: positionConfig).map { UInt32(truncatingIfNeeded: $0) }
    }

    private static func varint(_ number: Int, in message: Data) -> UInt64? {
        guard let fields = ProtoFields.parse(message) else { return nil }
        return ProtoFields.varint(number, in: fields) ?? 0
    }

    // MARK: - Framing

    /// The `ToRadio` frame that carries an AdminMessage to the radio this phone
    /// is connected to: a unicast to the radio's own node number, with
    /// want_ack so it applies and saves the change.
    ///
    /// `wantResponse` is for a request (get_channel_request): the radio only
    /// answers a request that asks for an answer.
    ///
    /// Nil when the node number is not known (0) or is the broadcast address.
    /// An admin message must never be addressed to everyone: it would go out
    /// over the air, and for `set_channel` it carries the channel key.
    ///
    /// `packetID` is the MeshPacket id. A request carries one the app made up and
    /// keeps, so that the answer, which echoes it, can be matched to it. It is
    /// never 0.
    static func toRadioFrame(
        adminPayload: Data,
        myNodeNum: UInt32,
        wantResponse: Bool = false,
        packetID: UInt32 = UInt32.random(in: 1...UInt32.max)
    ) -> Data? {
        guard myNodeNum != 0, myNodeNum != broadcastNodeNum, packetID != 0 else { return nil }
        return ATAKPluginSerializer.buildToRadio(
            atakPayload: adminPayload,
            to: myNodeNum,
            channel: 0,
            portnum: adminPortnum,
            hopLimit: 3,
            wantAck: true,
            wantResponse: wantResponse,
            packetID: packetID
        )
    }
}
