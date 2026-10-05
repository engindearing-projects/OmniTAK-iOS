//
//  MeshtasticRadioSettings.swift
//  OmniTAK Mobile
//
//  What a Meshtastic radio says about its own settings, kept as the raw bytes it
//  sent, so that a write can change one field and send the rest back (#148, see
//  MeshtasticAdminCodec for why).
//
//  The radio sends its settings during the config download that follows
//  `want_config_id`: a `config` frame for each sub-config and a `channel` frame
//  for each of its eight channel slots, disabled slots included. The first frame
//  of every download is `my_info`, which names the radio. The settings belong to
//  that radio on that connection:
//   - Nothing is kept until a `my_info` has said whose settings they are, and
//     `nodeNum` is that radio. A write is addressed to it.
//   - A download starting empties everything and starts over.
//   - MeshtasticManager only feeds in what the connection the operator chose
//     delivers, empties it when that connection drops or is replaced, and sends
//     a write only down the connection these settings came from.
//
//  What a write leaves behind. The radio may not do what was asked, and a role
//  change makes the firmware install that role's defaults, so what was sent is
//  not what the radio holds. After a write the entries it touched are dropped,
//  not updated:
//   - A config entry stays dropped. The radio restarts to apply a config, and
//     the next download refills it (`isAwaitingRestart`).
//   - A channel entry is dropped until the radio's answer to a read-back request
//     arrives (`channelReadBack`), and then holds what the radio says.
//
//  Only the sub-configs the app can write are kept. The rest of the config
//  download is dropped on arrival: nothing here edits it, the security config
//  holds the radio's private key and the network config holds the WiFi password.
//  The bytes live in memory only.
//

import Foundation

/// A settings event and the connection it came from.
struct MeshtasticLinkEvent: Equatable {
    let transport: MeshtasticConnectionType
    /// The client's count of connections when the frame was read. 0 for a
    /// transport that does not count them.
    let connection: Int
    let event: MeshtasticRadioSettings.Event
}

/// The sub-configs and channels of the radio on one connection.
struct MeshtasticRadioSettings: Equatable {

    // MARK: - Events

    /// Something on the link that changes what is known.
    enum Event: Equatable {
        /// A config download is starting: the radio's `my_info`, with its node
        /// number. Whatever was known is out of date and belongs to nobody now.
        case downloadStarted(nodeNum: UInt32)
        /// A sub-config: the field number it has inside `Config` and the bytes of
        /// the sub-config message.
        case config(variant: Int, body: Data)
        /// A channel slot: its index and the bytes of the whole Channel message.
        case channel(index: Int, body: Data)
        /// The radio's answer to a `get_channel_request`: the node it came from
        /// and the bytes of the whole Channel message.
        case channelReadBack(from: UInt32, body: Data)

        /// The event a decoded FromRadio frame stands for, or nil for a frame that
        /// does not change what is known about the radio's settings.
        init?(_ payload: MeshtasticProtoDecoder.FromRadioPayload) {
            switch payload {
            case .myInfo(let nodeNum):
                // A my_info with no node number names nobody.
                guard nodeNum != 0 else { return nil }
                self = .downloadStarted(nodeNum: nodeNum)
            case .config(let variant, let body):
                self = .config(variant: variant, body: body)
            case .channel(let index, let body):
                self = .channel(index: index, body: body)
            case .packet(let frame):
                guard frame.portNum == Int(MeshtasticAdminCodec.adminPortnum),
                      let channel = MeshtasticAdminCodec.channelResponse(in: frame.payload) else { return nil }
                self = .channelReadBack(from: frame.from, body: channel)
            default:
                return nil
            }
        }
    }

    // MARK: - What is kept

    /// The sub-configs a setter can change. Their field numbers inside `Config`.
    static let storedConfigVariants: Set<Int> = [
        MeshtasticAdminCodec.ConfigVariant.device,
        MeshtasticAdminCodec.ConfigVariant.position,
    ]

    /// The channel slots a radio has. Indices outside it are not kept.
    static let channelSlots = 0...7

    /// The radio these settings are from: the node number its `my_info`
    /// reported. Nil until a download has started, and nothing is kept before.
    private(set) var nodeNum: UInt32?

    /// Sub-config bytes by the field number of the sub-config inside `Config`.
    private(set) var configs: [Int: Data] = [:]
    /// Channel bytes by channel index.
    private(set) var channels: [Int: Data] = [:]

    /// Sub-configs a write was sent for. The radio restarts to apply one, and
    /// the next download refills it.
    private(set) var awaitingRestart: Set<Int> = []
    /// Channel slots a write was sent for and the radio has not answered yet.
    private(set) var awaitingReadBack: Set<Int> = []

    init() {}

    var isEmpty: Bool {
        nodeNum == nil && configs.isEmpty && channels.isEmpty && awaitingRestart.isEmpty && awaitingReadBack.isEmpty
    }

    // MARK: - Changing it

    mutating func apply(_ event: Event) {
        switch event {
        case .downloadStarted(let node):
            removeAll()
            nodeNum = node
        case .config(let variant, let body):
            guard nodeNum != nil else { return }
            storeConfig(variant: variant, body: body)
        case .channel(let index, let body):
            guard nodeNum != nil else { return }
            storeChannel(index: index, body: body)
        case .channelReadBack(let node, let body):
            // Only an answer from the radio these settings are from counts.
            guard node == nodeNum, let summary = MeshtasticAdminCodec.channelSummary(in: body) else { return }
            storeChannel(index: summary.index, body: body)
        }
    }

    mutating func removeAll() {
        nodeNum = nil
        configs.removeAll()
        channels.removeAll()
        awaitingRestart.removeAll()
        awaitingReadBack.removeAll()
    }

    /// Keep a sub-config, if it is one the app can write.
    mutating func storeConfig(variant: Int, body: Data) {
        guard Self.storedConfigVariants.contains(variant) else { return }
        configs[variant] = body
    }

    /// Keep a channel, if the index is a slot the radio has.
    mutating func storeChannel(index: Int, body: Data) {
        guard Self.channelSlots.contains(index) else { return }
        channels[index] = body
        awaitingReadBack.remove(index)
    }

    /// A write was sent for this sub-config. Forget what the radio said: it
    /// restarts to apply it, and what it holds afterwards is only known from the
    /// next download.
    mutating func invalidateConfig(variant: Int) {
        configs[variant] = nil
        awaitingRestart.insert(variant)
    }

    /// A write was sent for this channel slot. Forget what the radio said until
    /// it answers a read-back request.
    mutating func invalidateChannel(index: Int) {
        channels[index] = nil
        awaitingReadBack.insert(index)
    }

    // MARK: - Reading it

    /// The bytes of a sub-config. An empty `Data` is a real entry: a radio that
    /// has every field at its default sends an empty message.
    func config(variant: Int) -> Data? { configs[variant] }

    func channel(index: Int) -> Data? { channels[index] }

    func isAwaitingRestart(variant: Int) -> Bool { awaitingRestart.contains(variant) }

    /// True when a write has been sent and the config it changed has not come
    /// back in a new download yet.
    var isAwaitingAnyRestart: Bool { !awaitingRestart.isEmpty }

    func isAwaitingReadBack(index: Int) -> Bool { awaitingReadBack.contains(index) }

    /// True once the device config is known.
    var hasDeviceConfig: Bool { configs[MeshtasticAdminCodec.ConfigVariant.device] != nil }

    /// True once the position config is known.
    var hasPositionConfig: Bool { configs[MeshtasticAdminCodec.ConfigVariant.position] != nil }

    // MARK: Channels

    /// What the radio reports for a slot, or nil when the slot is not known (not
    /// reported, written to and not read back yet, or not well formed).
    func channelSummary(index: Int) -> MeshtasticAdminCodec.ChannelSummary? {
        channels[index].flatMap { MeshtasticAdminCodec.channelSummary(in: $0) }
    }

    /// The secondary slots (1 to 7) the radio reports as disabled, in order. A
    /// slot nothing is known about is not free: it may be in use, or a write to
    /// it may be on its way.
    var freeChannelSlots: [Int] {
        (1...7).filter { index in
            guard let summary = channelSummary(index: index) else { return false }
            return summary.isDisabled && summary.index == index
        }
    }

    /// The slot (any, primary included) that is in use and has this name and
    /// key, so that adding the same channel again is not a second copy.
    func slotHolding(name: String, key: Data) -> Int? {
        Self.channelSlots.first { index in
            guard let summary = channelSummary(index: index), !summary.isDisabled else { return false }
            return summary.name == name && summary.psk == key
        }
    }

    // MARK: Values for the settings screen

    // What the settings screen starts at. A field the radio leaves out of its
    // message is at its proto3 default, not unknown: a radio at factory settings
    // sends a DeviceConfig with no role and no rebroadcast mode, and that means
    // CLIENT and ALL. The values are nil only while the config itself has not
    // arrived.

    /// `DeviceConfig.role` as the radio reported it, as the proto number. 0
    /// (CLIENT) when the device config is known and has no role. Nil until the
    /// device config is known. A role this app has no name for is still reported.
    var deviceRole: UInt64? {
        configs[MeshtasticAdminCodec.ConfigVariant.device].flatMap { MeshtasticAdminCodec.deviceRole(in: $0) }
    }

    /// `DeviceConfig.rebroadcast_mode` as the proto number. 0 (ALL) when the
    /// device config is known and has none. Nil until the device config is known.
    var rebroadcastMode: UInt64? {
        configs[MeshtasticAdminCodec.ConfigVariant.device].flatMap { MeshtasticAdminCodec.rebroadcastMode(in: $0) }
    }

    /// `PositionConfig.position_broadcast_secs`. 0 when the position config is
    /// known and has none, which is how the radio says "use my default". Nil
    /// until the position config is known.
    var positionBroadcastSeconds: UInt32? {
        configs[MeshtasticAdminCodec.ConfigVariant.position].flatMap { MeshtasticAdminCodec.positionBroadcastSeconds(in: $0) }
    }

    /// The role as a role the app has a name for. Nil until the device config is
    /// known, and when the radio's role is a number the app has no name for
    /// (see `unlistedDeviceRole`).
    var namedDeviceRole: MeshtasticAdminCodec.DeviceRole? {
        deviceRole.flatMap { MeshtasticAdminCodec.DeviceRole(rawValue: $0) }
    }

    /// The radio's role when it is a number the app has no name for. The screen
    /// shows it as it is and writes nothing for it unless the operator picks a
    /// named role. Nil otherwise.
    var unlistedDeviceRole: UInt64? {
        guard let raw = deviceRole, MeshtasticAdminCodec.DeviceRole(rawValue: raw) == nil else { return nil }
        return raw
    }

    /// The rebroadcast mode as a mode the app has a name for. Nil until known,
    /// and when it is a number the app has no name for.
    var namedRebroadcastMode: MeshtasticAdminCodec.RebroadcastMode? {
        rebroadcastMode.flatMap { MeshtasticAdminCodec.RebroadcastMode(rawValue: $0) }
    }

    /// The radio's rebroadcast mode when it is a number the app has no name for.
    var unlistedRebroadcastMode: UInt64? {
        guard let raw = rebroadcastMode, MeshtasticAdminCodec.RebroadcastMode(rawValue: raw) == nil else { return nil }
        return raw
    }
}

// MARK: - Writing

/// What became of a request to change a radio setting.
public enum MeshtasticWriteResult: Equatable {
    /// The write went to the radio. That is all this says: the radio applies it
    /// after that, or does not. A config change makes it restart a few seconds
    /// later, and a channel change is read back (`MeshtasticChannelReport`).
    case sent
    /// Nothing was sent, because the radio already has every value that was
    /// asked for. A config write makes the radio restart, so a write that
    /// changes nothing is not sent.
    case unchanged
    /// Nothing was sent. The text says why, for the operator.
    case refused(String)

    /// Shown when there is no radio link.
    public static let notConnected = "Not connected"

    /// Shown when nothing was sent because nothing differs from the radio.
    public static let nothingToChange = "Nothing to change. The radio already has these settings."

    /// Shown when the radio's current settings are not known, so a write could
    /// not be built from them. Nothing is sent in that case: the radio replaces
    /// a whole sub-config with what it receives, so a write built without the
    /// radio's own values would reset everything the operator did not touch.
    public static let notLoaded = "Radio settings are not loaded yet. Reconnect and try again."

    /// Shown when a config was sent and the radio has not been heard from since.
    public static let restarting = "The radio is restarting to apply the last change. Reconnect when it is back."

    /// Shown when the connection the settings came from is not the one the write
    /// would go out on.
    public static let linkChanged = "The radio link changed. Reconnect and try again."

    public var isSent: Bool {
        if case .sent = self { return true }
        return false
    }

    /// The reason a write was refused, or nil when it was sent or there was
    /// nothing to change.
    public var refusal: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// What is known about a channel write. "Sent" means dispatched; the report only
/// says "applied" once the radio's own answer matches.
struct MeshtasticChannelReport: Equatable, Identifiable {
    enum State: Equatable {
        /// Dispatched. The radio has not answered the read-back yet.
        case sent
        /// The radio's answer has the name, key and role that were asked for.
        case applied
        /// The radio answered with something else. The text is the name it has.
        case radioKept(String)
        /// The radio did not answer.
        case noAnswer
    }

    let slot: Int
    /// The name that was asked for.
    let name: String
    var state: State

    var id: Int { slot }

    var text: String {
        let label = "Slot \(slot) \"\(name)\""
        switch state {
        case .sent:
            return "\(label): sent, waiting for the radio to confirm."
        case .applied:
            return "\(label): applied. The radio reports it."
        case .radioKept(let held):
            return "\(label): the radio kept its own value (\"\(held)\")."
        case .noAnswer:
            return "\(label): the radio did not confirm. The change may not have been applied."
        }
    }
}

/// A radio link a settings write can go out on. The BLE and TCP clients are the
/// two real ones; tests use a recording stand-in.
protocol MeshtasticAdminLink: AnyObject {
    /// The client's count of connections. A write names the connection it was
    /// built on, and the client refuses it when a newer one has begun.
    var connectionSerial: Int { get }

    /// Wrap an AdminMessage for the radio `nodeNum` and send it, on the
    /// connection `connection`. False when it cannot go, and then nothing was
    /// sent: not connected, a newer connection has begun, or the node number
    /// the client holds for its radio is not `nodeNum`.
    @discardableResult
    func sendAdmin(payload: Data, to nodeNum: UInt32, connection: Int, wantResponse: Bool) -> Bool
}
