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
//  of every download is `my_info`, so seeing it means a new download has begun
//  and what was known is out of date.
//
//  Lifecycle:
//   - A download starting empties it.
//   - The link dropping empties it (MeshtasticManager does that).
//   - After the app sends a write it keeps what it wrote (`storeConfig` /
//     `storeChannel`), so a second edit starts from the first and not from what
//     the radio said before.
//
//  Only the sub-configs the app can write are kept. The rest of the config
//  download is dropped on arrival: nothing here edits it, the security config
//  holds the radio's private key and the network config holds the WiFi password.
//  The bytes live in memory only.
//

import Foundation

/// The sub-configs and channels of the radio the phone is connected to.
struct MeshtasticRadioSettings: Equatable {

    // MARK: - Events

    /// Something on the link that changes what is known.
    enum Event: Equatable {
        /// A config download is starting. Whatever was known is out of date.
        case downloadStarted
        /// A sub-config: the field number it has inside `Config` and the bytes of
        /// the sub-config message.
        case config(variant: Int, body: Data)
        /// A channel slot: its index and the bytes of the whole Channel message.
        case channel(index: Int, body: Data)

        /// The event a decoded FromRadio frame stands for, or nil for a frame that
        /// does not change what is known about the radio's settings.
        init?(_ payload: MeshtasticProtoDecoder.FromRadioPayload) {
            switch payload {
            case .myInfo:
                self = .downloadStarted
            case .config(let variant, let body):
                self = .config(variant: variant, body: body)
            case .channel(let index, let body):
                self = .channel(index: index, body: body)
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

    /// Sub-config bytes by the field number of the sub-config inside `Config`.
    private(set) var configs: [Int: Data] = [:]
    /// Channel bytes by channel index.
    private(set) var channels: [Int: Data] = [:]

    init() {}

    var isEmpty: Bool { configs.isEmpty && channels.isEmpty }

    // MARK: - Changing it

    mutating func apply(_ event: Event) {
        switch event {
        case .downloadStarted:
            removeAll()
        case .config(let variant, let body):
            storeConfig(variant: variant, body: body)
        case .channel(let index, let body):
            storeChannel(index: index, body: body)
        }
    }

    mutating func removeAll() {
        configs.removeAll()
        channels.removeAll()
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
    }

    // MARK: - Reading it

    /// The bytes of a sub-config. An empty `Data` is a real entry: a radio that
    /// has every field at its default sends an empty message.
    func config(variant: Int) -> Data? { configs[variant] }

    func channel(index: Int) -> Data? { channels[index] }

    /// True once the device config is known.
    var hasDeviceConfig: Bool { configs[MeshtasticAdminCodec.ConfigVariant.device] != nil }

    /// True once the position config is known.
    var hasPositionConfig: Bool { configs[MeshtasticAdminCodec.ConfigVariant.position] != nil }

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
    /// The write went to the radio. The radio applies it after that, and for a
    /// config change usually restarts a few seconds later.
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

/// A radio link a settings write can go out on. The BLE and TCP clients are the
/// two real ones; tests use a recording stand-in.
protocol MeshtasticAdminLink: AnyObject {
    /// Wrap an AdminMessage for the radio and send it. False when it cannot go,
    /// and then nothing was sent.
    @discardableResult
    func sendAdmin(payload: Data) -> Bool
}
