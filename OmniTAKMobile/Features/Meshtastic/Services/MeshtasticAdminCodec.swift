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
//  Wire layout (field numbers / enum values are facts):
//      AdminMessage.set_channel = 33  (Channel submessage)
//      AdminMessage.set_config  = 34  (Config submessage)
//      Channel{ index=1 (int32), settings=2 (ChannelSettings), role=3 (Role enum) }
//      ChannelSettings{ psk=2 (bytes), name=3 (string) }
//      Channel.Role: DISABLED=0, PRIMARY=1, SECONDARY=2
//      Config.device   = 1  (DeviceConfig submessage)
//      Config.position = 2  (PositionConfig submessage)
//      DeviceConfig{ role=1 (Role enum), rebroadcast_mode=6 (RebroadcastMode enum) }
//      DeviceConfig.Role: CLIENT=0, ROUTER=2, TRACKER=5, TAK=7, TAK_TRACKER=10
//      DeviceConfig.RebroadcastMode: ALL=0, LOCAL_ONLY=2, KNOWN_ONLY=3, NONE=4
//      PositionConfig{ position_broadcast_secs=1 (uint32) }
//      Config.lora     = 6  (LoRaConfig submessage)
//      LoRaConfig{ use_preset=1 (bool), modem_preset=2 (enum), region=7 (enum),
//                  hop_limit=8 (uint32), tx_enabled=9 (bool) }
//      AdminMessage.set_owner = 32 (User submessage)
//      User{ long_name=2 (string, <=39 bytes), short_name=3 (string, <=4 bytes) }
//

import Foundation

enum MeshtasticAdminCodec {

    /// Meshtastic PortNum for AdminMessage traffic.
    static let adminPortnum: UInt64 = 6

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
        case none = 4

        var displayName: String {
            switch self {
            case .all:       return "All (default)"
            case .localOnly: return "Local mesh only"
            case .knownOnly: return "Known channels only"
            case .none:      return "None (no rebroadcast)"
            }
        }
    }

    // MARK: - LoRaConfig.RegionCode (#112 — regulatory)

    /// LoRa region. `rawValue` is the firmware `Config.LoRaConfig.RegionCode`
    /// number carried in `LoRaConfig.region` (field 7).
    ///
    /// Region picks the legal band and duty cycle, and a fresh radio will not
    /// transmit until it is set — this is the first thing an operator needs when
    /// a box of radios is handed to them. Because the number *is* the band, the
    /// values are pinned to the proto rather than to declaration order: a
    /// shifted ordinal keys an operator up on a frequency they are not licensed
    /// for in that jurisdiction, and the radio will do it without complaint.
    ///
    /// Labels are operator-facing and match Android's `MeshRegion` word for word.
    enum LoRaRegion: UInt64, CaseIterable {
        case unset = 0
        case us = 1
        case eu433 = 2
        case eu868 = 3
        case cn = 4
        case jp = 5
        case anz = 6
        case kr = 7
        case tw = 8
        case ru = 9
        /// `IN` in the proto; `in` is a Swift keyword.
        case india = 10
        case nz865 = 11
        case th = 12
        case lora24 = 13
        case ua433 = 14
        case ua868 = 15
        case my433 = 16
        case my919 = 17
        case sg923 = 18
        case ph433 = 19
        case ph868 = 20
        case ph915 = 21
        case anz433 = 22
        case kz433 = 23
        case kz863 = 24
        case np865 = 25
        case br902 = 26

        var displayName: String {
            switch self {
            case .unset:   return "Unset"
            case .us:      return "United States"
            case .eu433:   return "EU 433 MHz"
            case .eu868:   return "EU 868 MHz"
            case .cn:      return "China"
            case .jp:      return "Japan"
            case .anz:     return "Australia / NZ"
            case .kr:      return "Korea"
            case .tw:      return "Taiwan"
            case .ru:      return "Russia"
            case .india:   return "India"
            case .nz865:   return "New Zealand 865 MHz"
            case .th:      return "Thailand"
            case .lora24:  return "2.4 GHz (WLAN band)"
            case .ua433:   return "Ukraine 433 MHz"
            case .ua868:   return "Ukraine 868 MHz"
            case .my433:   return "Malaysia 433 MHz"
            case .my919:   return "Malaysia 919 MHz"
            case .sg923:   return "Singapore 923 MHz"
            case .ph433:   return "Philippines 433 MHz"
            case .ph868:   return "Philippines 868 MHz"
            case .ph915:   return "Philippines 915 MHz"
            case .anz433:  return "Australia / NZ 433 MHz"
            case .kz433:   return "Kazakhstan 433 MHz"
            case .kz863:   return "Kazakhstan 863 MHz"
            case .np865:   return "Nepal 865 MHz"
            case .br902:   return "Brazil 902 MHz"
            }
        }
    }

    // MARK: - LoRaConfig.ModemPreset (#112)

    /// Modem preset — the single range-vs-throughput knob OmniTAK exposes.
    ///
    /// Values are the firmware `Config.LoRaConfig.ModemPreset` numbers. Note
    /// LONG_MODERATE = 7 sitting between SHORT_FAST and SHORT_TURBO: a table
    /// built from a UI list that omits it lands SHORT_TURBO on 7 and runs the
    /// radio at the wrong bandwidth, which looks like a flaky link rather than
    /// a bad write. Labels and blurbs match Android's `MeshChannelPreset`.
    enum ModemPreset: UInt64, CaseIterable {
        case longFast = 0
        case longSlow = 1
        case veryLongSlow = 2
        case mediumSlow = 3
        case mediumFast = 4
        case shortSlow = 5
        case shortFast = 6
        case longModerate = 7
        case shortTurbo = 8

        var displayName: String {
            switch self {
            case .longFast:     return "Long Fast"
            case .longSlow:     return "Long Slow"
            case .veryLongSlow: return "Very Long Slow"
            case .mediumSlow:   return "Medium Slow"
            case .mediumFast:   return "Medium Fast"
            case .shortSlow:    return "Short Slow"
            case .shortFast:    return "Short Fast"
            case .longModerate: return "Long Moderate"
            case .shortTurbo:   return "Short Turbo"
            }
        }

        var blurb: String {
            switch self {
            case .longFast:     return "Default. Balanced range and throughput."
            case .longSlow:     return "Maximum range, very slow."
            case .veryLongSlow: return "Extreme range, painfully slow. Last resort."
            case .mediumSlow:   return "Mid range, slow."
            case .mediumFast:   return "Mid range, faster."
            case .shortSlow:    return "Short range, slow."
            case .shortFast:    return "Short range, fastest. Crowded events."
            case .longModerate: return "Long range, moderate speed."
            case .shortTurbo:   return "Highest throughput, very short range."
            }
        }
    }

    // MARK: - set_channel

    /// Encode an `AdminMessage{ set_channel = Channel{...} }` payload.
    ///
    /// `psk` must be 0 bytes (no crypto), 1 byte (default-key shorthand), 16
    /// bytes (AES128) or 32 bytes (AES256); other lengths are passed through
    /// verbatim (the radio validates).
    static func encodeSetChannel(
        index: Int32,
        name: String,
        psk: Data,
        role: ChannelRole
    ) -> Data {
        // ChannelSettings { psk=2, name=3 }
        var settings = Data()
        if !psk.isEmpty {
            appendBytes(&settings, field: 2, value: psk)
        }
        if !name.isEmpty {
            appendBytes(&settings, field: 3, value: Data(name.utf8))
        }

        // Channel { index=1, settings=2, role=3 }
        var channel = Data()
        appendVarintField(&channel, field: 1, value: int32Varint(index)) // proto3 int32 = plain varint
        appendBytes(&channel, field: 2, value: settings)
        if role != .disabled {
            appendVarintField(&channel, field: 3, value: role.rawValue)
        }

        // AdminMessage { set_channel=33 }
        var admin = Data()
        appendBytes(&admin, field: 33, value: channel)
        return admin
    }

    // MARK: - set_config (device role + rebroadcast scope)

    /// Encode an `AdminMessage{ set_config = Config{ device = DeviceConfig{...} } }`
    /// payload carrying the device role and rebroadcast scope.
    static func encodeSetDeviceConfig(
        role: DeviceRole,
        rebroadcastMode: RebroadcastMode
    ) -> Data {
        // DeviceConfig { role=1, rebroadcast_mode=6 }
        var device = Data()
        appendVarintField(&device, field: 1, value: role.rawValue)
        appendVarintField(&device, field: 6, value: rebroadcastMode.rawValue)

        // Config { device=1 }
        var config = Data()
        appendBytes(&config, field: 1, value: device)

        // AdminMessage { set_config=34 }
        var admin = Data()
        appendBytes(&admin, field: 34, value: config)
        return admin
    }

    // MARK: - set_config (position broadcast interval)

    /// Encode an `AdminMessage{ set_config = Config{ position = PositionConfig{
    /// position_broadcast_secs } } }` payload.
    static func encodeSetPositionBroadcastInterval(seconds: UInt32) -> Data {
        // PositionConfig { position_broadcast_secs=1 }
        var position = Data()
        appendVarintField(&position, field: 1, value: UInt64(seconds))

        // Config { position=2 }
        var config = Data()
        appendBytes(&config, field: 2, value: position)

        // AdminMessage { set_config=34 }
        var admin = Data()
        appendBytes(&admin, field: 34, value: config)
        return admin
    }

    // MARK: - set_config (LoRa region + modem preset)

    /// Encode an `AdminMessage{ set_config = Config{ lora = LoRaConfig{...} } }`
    /// carrying the regulatory region and the modem preset.
    ///
    /// `set_config` REPLACES the whole submessage on the radio — the firmware
    /// assigns the decoded struct over `config.lora`, it does not merge field by
    /// field. So anything left off the wire lands as the proto3 default:
    /// `tx_enabled` would go false (the radio stops keying up entirely) and
    /// `hop_limit` would go 0 (nothing relays). Every field OmniTAK owns is
    /// therefore written on every apply, defaults included, so the radio always
    /// ends up in a state we chose rather than one we forgot about.
    ///
    /// Returns nil for `.unset` — that is the absence of a region, not a region.
    /// Writing it would clear a legal region the radio already had and mute it.
    static func encodeSetLoRaConfig(
        region: LoRaRegion,
        modemPreset: ModemPreset,
        hopLimit: UInt32 = 3
    ) -> Data? {
        guard region != .unset else { return nil }
        // hop_limit rides 3 bits in MeshPacket; 0 would strand every packet.
        let hops = UInt64(min(max(hopLimit, 1), 7))

        // LoRaConfig { use_preset=1, modem_preset=2, region=7, hop_limit=8, tx_enabled=9 }
        var lora = Data()
        appendVarintField(&lora, field: 1, value: 1) // use_preset — raw BW/SF/CR is out of scope
        appendVarintField(&lora, field: 2, value: modemPreset.rawValue)
        appendVarintField(&lora, field: 7, value: region.rawValue)
        appendVarintField(&lora, field: 8, value: hops)
        appendVarintField(&lora, field: 9, value: 1) // tx_enabled

        // Config { lora=6 }
        var config = Data()
        appendBytes(&config, field: 6, value: lora)

        // AdminMessage { set_config=34 }
        var admin = Data()
        appendBytes(&admin, field: 34, value: config)
        return admin
    }

    // MARK: - set_owner (device long / short name)

    /// Firmware `User.long_name` is nanopb `char[40]` and `short_name` is
    /// `char[5]`; one byte of each is the NUL terminator, so the budget is 39 /
    /// 4 BYTES — not characters. Thirteen Chinese characters already fill
    /// long_name.
    static let longNameMaxBytes = 39
    static let shortNameMaxBytes = 4

    /// Clean an operator-typed device name for the wire.
    ///
    /// Control and format characters (Cc/Cf) are stripped rather than passed
    /// through: they let one node's name impersonate another in the node list,
    /// and a stray newline corrupts every log line the callsign lands in. The
    /// clamp walks whole Characters because a name cut mid-scalar is invalid
    /// UTF-8 — nanopb rejects the entire AdminMessage, so the write silently
    /// does nothing and the operator is left staring at a hex node id.
    static func sanitizedName(_ raw: String, maxBytes: Int) -> String {
        let clean = String(String.UnicodeScalarView(
            raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        ))
        let trimmed = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count > maxBytes else { return trimmed }

        var out = ""
        var used = 0
        for character in trimmed {
            let size = String(character).utf8.count
            if used + size > maxBytes { break }
            out.append(character)
            used += size
        }
        return out
    }

    /// Encode an `AdminMessage{ set_owner = User{ long_name, short_name } }`.
    ///
    /// Unlike set_config, the firmware's `handleSetOwner` merges: it only takes
    /// the strings that arrive non-empty. So a blank field is omitted rather
    /// than sent empty — sending it would be a request to blank the radio's
    /// name. Returns nil when nothing survives sanitising, because an owner
    /// write with no names is airtime spent to say nothing.
    static func encodeSetOwner(longName: String, shortName: String) -> Data? {
        let long = sanitizedName(longName, maxBytes: longNameMaxBytes)
        let short = sanitizedName(shortName, maxBytes: shortNameMaxBytes)
        guard !long.isEmpty || !short.isEmpty else { return nil }

        // User { long_name=2, short_name=3 } — id / hw_model / role / public_key
        // are left off so the radio keeps what it already has.
        var user = Data()
        if !long.isEmpty { appendBytes(&user, field: 2, value: Data(long.utf8)) }
        if !short.isEmpty { appendBytes(&user, field: 3, value: Data(short.utf8)) }

        // AdminMessage { set_owner=32 }
        var admin = Data()
        appendBytes(&admin, field: 32, value: user)
        return admin
    }

    // MARK: - Admin addressing

    /// Meshtastic broadcast node number.
    static let broadcastNodeNum: UInt32 = 0xFFFFFFFF

    /// Destination for an admin write, or nil when there isn't a safe one.
    ///
    /// Admin payloads are unicast to our OWN node so the firmware handles them
    /// locally instead of putting them on the air. Broadcast is not a fallback:
    /// it transmits the config — and on the set_channel path the PSK — to every
    /// radio in range, and no peer will honour it anyway. Until the radio has
    /// reported its node number there is no destination, and the caller must
    /// fail honestly rather than shout.
    static func adminDestination(myNodeNum: UInt32) -> UInt32? {
        guard myNodeNum != 0, myNodeNum != broadcastNodeNum else { return nil }
        return myNodeNum
    }

    // MARK: - Wire helpers (independent clean-room implementation)

    private static func appendTag(_ d: inout Data, field: Int, wire: UInt8) {
        appendVarint(&d, UInt64(field) << 3 | UInt64(wire))
    }
    private static func appendVarint(_ d: inout Data, _ value: UInt64) {
        var v = value
        if v == 0 { d.append(0); return }
        while v > 0x7F { d.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        d.append(UInt8(v))
    }
    private static func appendVarintField(_ d: inout Data, field: Int, value: UInt64) {
        appendTag(&d, field: field, wire: 0); appendVarint(&d, value)
    }
    private static func appendBytes(_ d: inout Data, field: Int, value: Data) {
        appendTag(&d, field: field, wire: 2); appendVarint(&d, UInt64(value.count)); d.append(value)
    }

    /// proto3 `int32` is encoded as a plain varint, sign-extended to 64 bits for
    /// negatives. Channel indices are always >= 0 in practice, but this encodes
    /// correctly for the full int32 range.
    private static func int32Varint(_ v: Int32) -> UInt64 {
        return UInt64(bitPattern: Int64(v))
    }
}
