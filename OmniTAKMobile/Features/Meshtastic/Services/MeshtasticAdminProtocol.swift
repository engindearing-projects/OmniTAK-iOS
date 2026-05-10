//
//  MeshtasticAdminProtocol.swift
//  OmniTAK Mobile
//
//  GAP-109/109a — hand-rolled Meshtastic admin-port (portnum 6) protobuf
//  serializer + parser. Mirrors the Android `AdminMessageSerializer` /
//  `AdminMessageParser` pair byte-for-byte. Field numbers come from
//  canonical Meshtastic firmware admin.proto / config.proto / channel.proto.
//

import Foundation

// MARK: - Operator-facing enums

/// Operator role on the mesh. Mirrors the Meshtastic firmware
/// `Config_DeviceConfig_Role` enum so the admin-write path can map 1:1.
public enum MeshRole: String, CaseIterable, Codable {
    case client = "CLIENT"
    case clientMute = "CLIENT_MUTE"
    case router = "ROUTER"
    case routerClient = "ROUTER_CLIENT"
    case repeater = "REPEATER"
    case tracker = "TRACKER"
    case sensor = "SENSOR"
    case tak = "TAK"
    case clientHidden = "CLIENT_HIDDEN"
    case lostAndFound = "LOST_AND_FOUND"
    case takTracker = "TAK_TRACKER"

    public var label: String {
        switch self {
        case .client: return "Client"
        case .clientMute: return "Client Mute"
        case .router: return "Router"
        case .routerClient: return "Router Client"
        case .repeater: return "Repeater"
        case .tracker: return "Tracker"
        case .sensor: return "Sensor"
        case .tak: return "TAK"
        case .clientHidden: return "Client Hidden"
        case .lostAndFound: return "Lost & Found"
        case .takTracker: return "TAK Tracker"
        }
    }

    public var blurb: String {
        switch self {
        case .client: return "Standard handheld. Routes for the mesh."
        case .clientMute: return "Receives only — never rebroadcasts."
        case .router: return "Dedicated repeater. No UI presence."
        case .routerClient: return "Routes and acts as a client."
        case .repeater: return "Pure repeater, no telemetry."
        case .tracker: return "Broadcasts position frequently."
        case .sensor: return "Periodic telemetry only."
        case .tak: return "TAK-tuned defaults — what you usually want with OmniTAK."
        case .clientHidden: return "Client that doesn't appear in nodelist."
        case .lostAndFound: return "Beacons location for recovery."
        case .takTracker: return "TAK-tuned tracker. Position-heavy, no chat."
        }
    }
}

/// Channel preset — matches Meshtastic firmware named LoRa modem profile presets.
public enum MeshChannelPreset: String, CaseIterable, Codable {
    case longFast = "LONG_FAST"
    case longSlow = "LONG_SLOW"
    case veryLongSlow = "VERY_LONG_SLOW"
    case mediumSlow = "MEDIUM_SLOW"
    case mediumFast = "MEDIUM_FAST"
    case shortSlow = "SHORT_SLOW"
    case shortFast = "SHORT_FAST"
    case shortTurbo = "SHORT_TURBO"

    public var label: String {
        switch self {
        case .longFast: return "Long Fast"
        case .longSlow: return "Long Slow"
        case .veryLongSlow: return "Very Long Slow"
        case .mediumSlow: return "Medium Slow"
        case .mediumFast: return "Medium Fast"
        case .shortSlow: return "Short Slow"
        case .shortFast: return "Short Fast"
        case .shortTurbo: return "Short Turbo"
        }
    }

    public var blurb: String {
        switch self {
        case .longFast: return "Default. Balanced range and throughput."
        case .longSlow: return "Maximum range, very slow."
        case .veryLongSlow: return "Extreme range, painfully slow. Last resort."
        case .mediumSlow: return "Mid range, slow."
        case .mediumFast: return "Mid range, faster."
        case .shortSlow: return "Short range, slow."
        case .shortFast: return "Short range, fastest."
        case .shortTurbo: return "Highest throughput, very short range."
        }
    }
}

// MARK: - Decoded admin responses

public enum AdminResponse: Equatable {
    case owner(longName: String, shortName: String)
    case deviceConfig(role: MeshRole?)
    case positionConfig(broadcastSecs: Int)
    case loraConfig(preset: MeshChannelPreset?)
    /// Channel role enum: 0 = DISABLED, 1 = PRIMARY, 2 = SECONDARY.
    case channel(index: Int, name: String, role: Int)
}

// MARK: - Admin message serializer

enum AdminMessageSerializer {

    /// Meshtastic portnum for AdminMessage payloads on the local radio.
    private static let PORTNUM_ADMIN_APP: UInt64 = 6

    // region Public builders --------------------------------------------

    /// `AdminMessage { set_owner = User { long_name, short_name } }` (field 32).
    static func buildSetOwner(longName: String, shortName: String) -> Data {
        let owner = encodeOwner(longName: longName, shortName: shortName)
        var admin = Data()
        appendTag(&admin, field: 32, wire: 2)
        appendVarint(&admin, UInt64(owner.count))
        admin.append(owner)
        return wrapToRadio(admin)
    }

    /// `AdminMessage { set_config { device { role } } }` (field 34 → 1 → 1).
    static func buildSetDeviceRole(_ role: MeshRole) -> Data {
        var deviceConfig = Data()
        appendVarintField(&deviceConfig, field: 1, value: UInt64(roleProtoOrdinal(role)))

        var config = Data()
        appendTag(&config, field: 1, wire: 2)
        appendVarint(&config, UInt64(deviceConfig.count))
        config.append(deviceConfig)

        var admin = Data()
        appendTag(&admin, field: 34, wire: 2)
        appendVarint(&admin, UInt64(config.count))
        admin.append(config)
        return wrapToRadio(admin)
    }

    /// `AdminMessage { set_config { position { position_broadcast_secs = N } } }`.
    static func buildSetPositionBroadcastSecs(_ secs: Int) -> Data {
        let safe = UInt64(max(0, min(secs, 24 * 60 * 60)))
        var positionConfig = Data()
        appendVarintField(&positionConfig, field: 4, value: safe)

        var config = Data()
        appendTag(&config, field: 2, wire: 2)
        appendVarint(&config, UInt64(positionConfig.count))
        config.append(positionConfig)

        var admin = Data()
        appendTag(&admin, field: 34, wire: 2)
        appendVarint(&admin, UInt64(config.count))
        admin.append(config)
        return wrapToRadio(admin)
    }

    /// `AdminMessage { set_channel { Channel { index=0, settings.name, role=PRIMARY } } }`.
    static func buildSetChannel0Name(_ name: String) -> Data {
        var settings = Data()
        appendString(&settings, field: 3, value: name)

        var channel = Data()
        appendVarintField(&channel, field: 1, value: 0)
        appendTag(&channel, field: 2, wire: 2)
        appendVarint(&channel, UInt64(settings.count))
        channel.append(settings)
        appendVarintField(&channel, field: 3, value: 1) // Channel.Role.PRIMARY

        var admin = Data()
        appendTag(&admin, field: 33, wire: 2)
        appendVarint(&admin, UInt64(channel.count))
        admin.append(channel)
        return wrapToRadio(admin)
    }

    /// `AdminMessage { set_config { lora { use_preset = true, modem_preset } } }`.
    static func buildSetLoraPreset(_ preset: MeshChannelPreset) -> Data {
        var loraConfig = Data()
        appendVarintField(&loraConfig, field: 1, value: 1)
        appendVarintField(&loraConfig, field: 2, value: UInt64(presetProtoOrdinal(preset)))

        var config = Data()
        appendTag(&config, field: 6, wire: 2)
        appendVarint(&config, UInt64(loraConfig.count))
        config.append(loraConfig)

        var admin = Data()
        appendTag(&admin, field: 34, wire: 2)
        appendVarint(&admin, UInt64(config.count))
        admin.append(config)
        return wrapToRadio(admin)
    }

    // region Read requests ----------------------------------------------

    /// `AdminMessage.get_owner_request` (field 3, bool=true).
    static func buildGetOwnerRequest() -> Data {
        var admin = Data()
        appendVarintField(&admin, field: 3, value: 1)
        return wrapToRadio(admin)
    }

    /// `AdminMessage.get_config_request` (field 5, ConfigType enum).
    static func buildGetConfigRequest(configType: Int) -> Data {
        var admin = Data()
        appendVarintField(&admin, field: 5, value: UInt64(configType))
        return wrapToRadio(admin)
    }

    /// `AdminMessage.get_channel_request` (field 1, 1-based channel index).
    static func buildGetChannelRequest(channelIndex: Int) -> Data {
        var admin = Data()
        let zeroBased = max(0, channelIndex)
        appendVarintField(&admin, field: 1, value: UInt64(zeroBased + 1))
        return wrapToRadio(admin)
    }

    // ConfigType enum values (admin.proto)
    static let getConfigDevice = 0
    static let getConfigPosition = 1
    static let getConfigLora = 5

    // region Private encoders -------------------------------------------

    private static func encodeOwner(longName: String, shortName: String) -> Data {
        var out = Data()
        let safeLong = String(longName.prefix(39))
        let safeShort = String(shortName.prefix(4))
        appendString(&out, field: 2, value: safeLong)
        appendString(&out, field: 3, value: safeShort)
        return out
    }

    private static func roleProtoOrdinal(_ role: MeshRole) -> Int {
        switch role {
        case .client: return 0
        case .clientMute: return 1
        case .router: return 2
        case .routerClient: return 3
        case .repeater: return 4
        case .tracker: return 5
        case .sensor: return 6
        case .tak: return 7
        case .clientHidden: return 8
        case .lostAndFound: return 9
        case .takTracker: return 10
        }
    }

    private static func presetProtoOrdinal(_ preset: MeshChannelPreset) -> Int {
        switch preset {
        case .longFast: return 0
        case .longSlow: return 1
        case .veryLongSlow: return 2
        case .mediumSlow: return 3
        case .mediumFast: return 4
        case .shortSlow: return 5
        case .shortFast: return 6
        case .shortTurbo: return 8 // skip 7 = LONG_MODERATE per recent firmware
        }
    }

    /// Wrap an AdminMessage byte blob into a fully-framed `ToRadio`. Mirrors
    /// the Android impl: portnum=ADMIN_APP, to=0xFFFFFFFF, want_response=true.
    private static func wrapToRadio(_ adminBytes: Data) -> Data {
        var packetId = UInt32.random(in: 1...UInt32.max)
        if packetId == 0 { packetId = 1 }

        var decoded = Data()
        appendVarintField(&decoded, field: 1, value: PORTNUM_ADMIN_APP)
        appendTag(&decoded, field: 2, wire: 2)
        appendVarint(&decoded, UInt64(adminBytes.count))
        decoded.append(adminBytes)
        appendVarintField(&decoded, field: 5, value: 1) // want_response

        var meshPacket = Data()
        // 2: to (fixed32)
        appendTag(&meshPacket, field: 2, wire: 5)
        appendFixed32(&meshPacket, 0xFFFFFFFF)
        // 4: decoded
        appendTag(&meshPacket, field: 4, wire: 2)
        appendVarint(&meshPacket, UInt64(decoded.count))
        meshPacket.append(decoded)
        // 6: id (fixed32)
        appendTag(&meshPacket, field: 6, wire: 5)
        appendFixed32(&meshPacket, packetId)
        // 10: want_ack
        appendVarintField(&meshPacket, field: 10, value: 1)

        var toRadio = Data()
        appendTag(&toRadio, field: 1, wire: 2)
        appendVarint(&toRadio, UInt64(meshPacket.count))
        toRadio.append(meshPacket)
        return toRadio
    }

    // region Wire helpers ------------------------------------------------

    private static func appendTag(_ out: inout Data, field: Int, wire: Int) {
        appendVarint(&out, UInt64((field << 3) | (wire & 0x7)))
    }

    private static func appendVarint(_ out: inout Data, _ value: UInt64) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        out.append(UInt8(v & 0x7F))
    }

    private static func appendVarintField(_ out: inout Data, field: Int, value: UInt64) {
        appendTag(&out, field: field, wire: 0)
        appendVarint(&out, value)
    }

    private static func appendFixed32(_ out: inout Data, _ value: UInt32) {
        for i in 0..<4 {
            out.append(UInt8((value >> (i * 8)) & 0xFF))
        }
    }

    private static func appendString(_ out: inout Data, field: Int, value: String) {
        guard !value.isEmpty, let bytes = value.data(using: .utf8) else { return }
        appendTag(&out, field: field, wire: 2)
        appendVarint(&out, UInt64(bytes.count))
        out.append(bytes)
    }
}

// MARK: - Admin message parser

enum AdminMessageParser {

    /// Decode an AdminMessage payload. Returns nil for set_* echoes /
    /// future fields we don't handle.
    static func parse(_ bytes: Data) -> AdminResponse? {
        var idx = 0
        while idx < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, from: idx) else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            idx = afterTag
            switch field {
            case 4: // get_owner_response
                guard wire == 2, let (sub, _) = readLengthDelimited(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                let (sn, ln) = parseUser(sub)
                return .owner(longName: ln, shortName: sn)
            case 2: // get_channel_response
                guard wire == 2, let (sub, _) = readLengthDelimited(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                return parseChannel(sub)
            case 6: // get_config_response
                guard wire == 2, let (sub, _) = readLengthDelimited(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                return parseConfig(sub)
            default:
                idx = skipField(bytes, from: idx, wire: wire)
            }
        }
        return nil
    }

    /// Public — Channel submessage at FromRadio.field=10. Same byte
    /// layout as inside `get_channel_response`. Used by the want_config_id
    /// channel-slot dump.
    static func parseChannelPublic(_ bytes: Data) -> AdminResponse {
        return parseChannel(bytes)
    }

    private static func parseConfig(_ bytes: Data) -> AdminResponse? {
        var idx = 0
        while idx < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, from: idx) else { return nil }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            idx = afterTag
            switch field {
            case 1: // device
                guard wire == 2, let (sub, _) = readLengthDelimited(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                return parseDeviceConfig(sub)
            case 2: // position
                guard wire == 2, let (sub, _) = readLengthDelimited(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                return parsePositionConfig(sub)
            case 6: // lora
                guard wire == 2, let (sub, _) = readLengthDelimited(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                return parseLoraConfig(sub)
            default:
                idx = skipField(bytes, from: idx, wire: wire)
            }
        }
        return nil
    }

    private static func parseDeviceConfig(_ bytes: Data) -> AdminResponse {
        var idx = 0
        var role: MeshRole? = nil
        while idx < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, from: idx) else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            idx = afterTag
            if field == 1 && wire == 0, let (v, after) = readVarint(bytes, from: idx) {
                role = roleFromOrdinal(Int(v))
                idx = after
            } else {
                idx = skipField(bytes, from: idx, wire: wire)
            }
        }
        return .deviceConfig(role: role)
    }

    private static func parsePositionConfig(_ bytes: Data) -> AdminResponse {
        var idx = 0
        var secs = 0
        while idx < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, from: idx) else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            idx = afterTag
            if field == 4 && wire == 0, let (v, after) = readVarint(bytes, from: idx) {
                secs = Int(v)
                idx = after
            } else {
                idx = skipField(bytes, from: idx, wire: wire)
            }
        }
        return .positionConfig(broadcastSecs: secs)
    }

    private static func parseLoraConfig(_ bytes: Data) -> AdminResponse {
        var idx = 0
        var preset: MeshChannelPreset? = nil
        while idx < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, from: idx) else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            idx = afterTag
            if field == 2 && wire == 0, let (v, after) = readVarint(bytes, from: idx) {
                preset = presetFromOrdinal(Int(v))
                idx = after
            } else {
                idx = skipField(bytes, from: idx, wire: wire)
            }
        }
        return .loraConfig(preset: preset)
    }

    /// Channel { 1 index varint, 2 settings sub, 3 role varint enum }.
    private static func parseChannel(_ bytes: Data) -> AdminResponse {
        var idx = 0
        var index = 0
        var name = ""
        var role = 0
        while idx < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, from: idx) else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            idx = afterTag
            switch field {
            case 1:
                guard wire == 0, let (v, after) = readVarint(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                index = Int(v); idx = after
            case 2:
                guard wire == 2, let (sub, end) = readLengthDelimited(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                name = parseChannelSettingsName(sub)
                idx = end
            case 3:
                guard wire == 0, let (v, after) = readVarint(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                role = Int(v); idx = after
            default:
                idx = skipField(bytes, from: idx, wire: wire)
            }
        }
        return .channel(index: index, name: name, role: role)
    }

    private static func parseChannelSettingsName(_ bytes: Data) -> String {
        var idx = 0
        var name = ""
        while idx < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, from: idx) else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            idx = afterTag
            if field == 3 && wire == 2, let (s, after) = readString(bytes, from: idx) {
                name = s; idx = after
            } else {
                idx = skipField(bytes, from: idx, wire: wire)
            }
        }
        return name
    }

    /// User submessage: 2 long_name, 3 short_name. Returns (short, long).
    private static func parseUser(_ bytes: Data) -> (String, String) {
        var idx = 0
        var shortName = ""
        var longName = ""
        while idx < bytes.count {
            guard let (tag, afterTag) = readVarint(bytes, from: idx) else { break }
            let field = Int(tag >> 3)
            let wire = Int(tag & 0x7)
            idx = afterTag
            switch field {
            case 2:
                guard wire == 2, let (s, after) = readString(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                longName = s; idx = after
            case 3:
                guard wire == 2, let (s, after) = readString(bytes, from: idx) else {
                    idx = skipField(bytes, from: idx, wire: wire); continue
                }
                shortName = s; idx = after
            default:
                idx = skipField(bytes, from: idx, wire: wire)
            }
        }
        return (shortName, longName)
    }

    private static func roleFromOrdinal(_ ordinal: Int) -> MeshRole? {
        switch ordinal {
        case 0: return .client
        case 1: return .clientMute
        case 2: return .router
        case 3: return .routerClient
        case 4: return .repeater
        case 5: return .tracker
        case 6: return .sensor
        case 7: return .tak
        case 8: return .clientHidden
        case 9: return .lostAndFound
        case 10: return .takTracker
        default: return nil
        }
    }

    private static func presetFromOrdinal(_ ordinal: Int) -> MeshChannelPreset? {
        switch ordinal {
        case 0: return .longFast
        case 1: return .longSlow
        case 2: return .veryLongSlow
        case 3: return .mediumSlow
        case 4: return .mediumFast
        case 5: return .shortSlow
        case 6: return .shortFast
        case 8: return .shortTurbo
        default: return nil
        }
    }

    // region Wire helpers ------------------------------------------------

    private static func readVarint(_ data: Data, from index: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift = 0
        var idx = index
        while idx < data.count {
            let byte = data[idx]
            idx += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return (result, idx)
            }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private static func readString(_ data: Data, from index: Int) -> (String, Int)? {
        guard let (length, lengthEnd) = readVarint(data, from: index) else { return nil }
        let stringEnd = lengthEnd + Int(length)
        guard stringEnd <= data.count else { return nil }
        let stringData = data.subdata(in: lengthEnd..<stringEnd)
        guard let str = String(data: stringData, encoding: .utf8) else { return nil }
        return (str, stringEnd)
    }

    private static func readLengthDelimited(_ data: Data, from index: Int) -> (Data, Int)? {
        guard let (length, lengthEnd) = readVarint(data, from: index) else { return nil }
        let dataEnd = lengthEnd + Int(length)
        guard dataEnd <= data.count else { return nil }
        return (data.subdata(in: lengthEnd..<dataEnd), dataEnd)
    }

    private static func skipField(_ data: Data, from index: Int, wire: Int) -> Int {
        switch wire {
        case 0:
            // Varint
            var idx = index
            while idx < data.count && (data[idx] & 0x80) != 0 { idx += 1 }
            return min(idx + 1, data.count)
        case 1: // 64-bit
            return min(index + 8, data.count)
        case 2: // length-delimited
            guard let (length, lengthEnd) = readVarint(data, from: index) else { return data.count }
            return min(lengthEnd + Int(length), data.count)
        case 5: // 32-bit
            return min(index + 4, data.count)
        default:
            return data.count
        }
    }
}
