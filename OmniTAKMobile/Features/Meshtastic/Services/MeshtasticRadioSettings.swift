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
//  not what the radio holds. A write therefore never starts from what is kept
//  here: it asks the radio for the sub-config or channel first (a get request,
//  answered with the id of the request echoed), and after the write it asks
//  again. Meanwhile the entry a write touched is dropped, not updated to what
//  was sent, and is filled again only by the radio's own word:
//   - A config entry stays dropped until the radio says it again, in an answer or
//     in the next download (`isAwaitingRestart`).
//   - A channel entry is dropped until the radio's answer to the read-back
//     arrives, and then holds what the radio says (`isAwaitingReadBack`).
//  What the radio says in an answer is kept only when MeshtasticManager has
//  matched it to a request it sent; this struct never applies an answer itself.
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
        /// An admin answer to a get request (`get_config_response` or
        /// `get_channel_response`), with what is needed to decide whether it
        /// answers a request this app sent. It changes nothing by itself:
        /// MeshtasticManager matches it to a request it made, and only then are
        /// the bytes kept.
        case answer(MeshtasticAdminCodec.Answer)

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
                guard let answer = MeshtasticAdminCodec.answer(in: frame) else { return nil }
                self = .answer(answer)
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
        case .answer:
            // Not applied here. An answer is kept only when the manager has
            // matched it to a request it sent (see MeshtasticManager).
            break
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
        awaitingRestart.remove(variant)
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
            return summary.name == MeshtasticAdminCodec.storedName(name) && summary.psk == key
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
    /// The radio's own answer to a read after the write shows what was asked for.
    case applied
    /// The write was sent and the radio did not confirm it. The text says why:
    /// it did not answer, or its answer shows another value.
    case notConfirmed(String)
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

    /// Shown when the radio has not yet said who it is or what it holds, so
    /// nothing can be asked of it. Nothing is sent in that case: the radio
    /// replaces a whole sub-config with what it receives, so a write built
    /// without the radio's own values would reset everything the operator did
    /// not touch.
    public static let notLoaded = "Radio settings are not loaded yet. Reconnect and try again."

    /// Shown when a config was sent and the radio has not been heard from since.
    public static let restarting = "The radio is restarting to apply the last change. Reconnect when it is back."

    /// Shown when the connection the settings came from is not the one the write
    /// would go out on.
    public static let linkChanged = "The radio link changed. Reconnect and try again."

    /// Shown when the radio did not answer the read that comes before a write.
    public static let noAnswer = "The radio did not answer. Nothing was sent."

    /// Shown when the radio's answer to that read is not a message this app can
    /// change.
    public static let unreadable = "The radio's settings could not be read. Nothing was sent."

    /// True when the radio confirmed the change.
    public var isApplied: Bool {
        if case .applied = self { return true }
        return false
    }

    /// True when the write went to the radio, whether or not it confirmed.
    public var wasSent: Bool {
        switch self {
        case .applied, .notConfirmed: return true
        case .unchanged, .refused: return false
        }
    }

    /// The reason a write was refused, or nil when it was sent or there was
    /// nothing to change.
    public var refusal: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// What is known about a channel write. "Sent" means dispatched; the report only
/// says "applied" once the radio's own answer matches, and it changes if a late
/// answer arrives.
struct MeshtasticChannelReport: Equatable, Identifiable {
    enum State: Equatable {
        /// Dispatched. The radio has not answered the read-back yet.
        case sent
        /// The radio's answer has the name, key and role that were asked for.
        case applied
        /// The radio answered with something else. The text is the name it has.
        case radioKept(String)
        /// The radio did not answer in time. If it answers later, this changes.
        case noAnswer
        /// The link was lost before the radio answered, and nothing is waiting
        /// for the answer any more. When the radio reports the slot again, in its
        /// config download or in an answer to a read, this changes.
        case linkLost
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
            return held.isEmpty
                ? "\(label): the radio kept its own value."
                : "\(label): the radio kept its own value (\"\(held)\")."
        case .noAnswer:
            return "\(label): the radio did not confirm. The change may not have been applied. "
                + "If the radio answers later this line changes."
        case .linkLost:
            return "\(label): the link was lost before the radio confirmed. The change may or may not have been applied. "
                + "This line changes when the radio reports the slot again, after it connects or on Re-read from radio."
        }
    }
}

// MARK: - What a config write was, and what became of it

/// A value of a sub-config this app writes: what a write sets and what the radio
/// reports for it.
enum MeshtasticConfigField: Int, CaseIterable, Hashable {
    case role = 0
    case rebroadcastMode
    case positionInterval

    /// The sub-config the field is in, by its field number inside `Config`.
    var variant: Int {
        switch self {
        case .role, .rebroadcastMode: return MeshtasticAdminCodec.ConfigVariant.device
        case .positionInterval:       return MeshtasticAdminCodec.ConfigVariant.position
        }
    }

    /// The value the radio holds for it, in the bytes of its sub-config.
    func value(in body: Data) -> UInt64? {
        switch self {
        case .role:             return MeshtasticAdminCodec.deviceRole(in: body)
        case .rebroadcastMode:  return MeshtasticAdminCodec.rebroadcastMode(in: body)
        case .positionInterval: return MeshtasticAdminCodec.positionBroadcastSeconds(in: body).map { UInt64($0) }
        }
    }

    /// The value as the operator reads it.
    func text(_ value: UInt64) -> String {
        switch self {
        case .role:
            return "role " + (MeshtasticAdminCodec.DeviceRole(rawValue: value)?.displayName ?? String(value))
        case .rebroadcastMode:
            return "rebroadcast " + (MeshtasticAdminCodec.RebroadcastMode(rawValue: value)?.displayName ?? String(value))
        case .positionInterval:
            return "\(value) s"
        }
    }

    /// "role TAK, rebroadcast Local mesh only", in a fixed order.
    static func list(_ values: [MeshtasticConfigField: UInt64]) -> String {
        allCases.compactMap { field in values[field].map { field.text($0) } }.joined(separator: ", ")
    }
}

/// What is known about a config write: what was sent, and what the radio says
/// about it, in the answer to the read after the write and then, when the link
/// comes back, in the config it sends on connecting. A config write makes the
/// radio restart to save it, and the radio may put a value back when it starts,
/// so the answer before the restart is not the last word (#153).
struct MeshtasticConfigReport: Equatable, Identifiable {
    enum State: Equatable {
        /// Dispatched. The radio has not answered the read-back yet.
        case sent
        /// The radio's answer shows what was sent. It is checked again after the
        /// restart.
        case confirmed
        /// The radio's answer shows other values for these fields.
        case radioKept([MeshtasticConfigField: UInt64])
        /// The radio did not answer in time.
        case noAnswer
        /// The link changed before the radio answered, as it does over Bluetooth
        /// when the radio cuts the link to restart.
        case linkLost
        /// After the link came back, the radio reports what was sent.
        case appliedAfterRestart
        /// After the link came back, the radio reports other values for these
        /// fields.
        case differsAfterRestart([MeshtasticConfigField: UInt64])

        /// True once the radio has reported after restarting. What it reported is
        /// shown for the session it was reported in, and goes at the next connect.
        var isFinal: Bool {
            switch self {
            case .appliedAfterRestart, .differsAfterRestart: return true
            default: return false
            }
        }
    }

    /// The sub-config, by its field number inside `Config`.
    let variant: Int
    /// The radio it was sent to.
    let node: UInt32
    /// "Position interval" or "Device config".
    let what: String
    /// What was sent.
    var sent: [MeshtasticConfigField: UInt64]
    var state: State

    var id: Int { variant }

    private var sentText: String { MeshtasticConfigField.list(sent) }

    private static func capitalizingFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// What the radio is said to report, for the fields that differ.
    private func reportedText(_ values: [MeshtasticConfigField: UInt64]) -> String {
        MeshtasticConfigField.list(values)
    }

    /// The sentence the operator reads after "sent", while the write is not
    /// settled.
    var reason: String {
        switch state {
        case .sent:
            return "Waiting for the radio to confirm."
        case .confirmed:
            return "The radio reports it. It is checked again when the radio is back after restarting."
        case .radioKept(let reported):
            return "The radio reports \(reportedText(reported)), not \(sentText). "
                + "It is checked again when the radio is back after restarting."
        case .noAnswer:
            return "The radio did not confirm. It is checked when the radio next connects."
        case .linkLost:
            return "The link changed before the radio confirmed. It is checked when the radio reconnects."
        case .appliedAfterRestart, .differsAfterRestart:
            return ""
        }
    }

    var text: String {
        switch state {
        case .appliedAfterRestart:
            return "\(what): applied. The radio reports \(sentText) after reconnecting."
        case .differsAfterRestart(let reported):
            return "\(what): the radio reports \(reportedText(reported)) after reconnecting. "
                + "\(Self.capitalizingFirst(sentText)) was sent."
        default:
            return "\(what): \(sentText) sent. \(reason)"
        }
    }
}

/// A radio link a settings write can go out on. The BLE and TCP clients are the
/// two real ones; tests use a stand-in.
protocol MeshtasticAdminLink: AnyObject {
    /// The client's count of connections. A write names the connection it was
    /// built on, and the client refuses it when a newer one has begun.
    var connectionSerial: Int { get }

    /// Wrap an AdminMessage for the radio `nodeNum` and send it, on the
    /// connection `connection`, in a packet with the id `packetID`. False when it
    /// cannot go, and then nothing was sent: not connected, a newer connection
    /// has begun, or the node number the client holds for its radio is not
    /// `nodeNum`.
    @discardableResult
    func sendAdmin(payload: Data, to nodeNum: UInt32, connection: Int, wantResponse: Bool, packetID: UInt32) -> Bool
}
