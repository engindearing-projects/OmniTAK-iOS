//
//  TAKPacketCodec.swift
//  OmniTAKMobile
//
//  Encodes/decodes Meshtastic portnum-72 (ATAK_PLUGIN) payloads using the
//  compact `TAKPacket` protobuf schema (atak.proto / meshtastic namespace).
//
//  This is the PHASE 2 interop codec for standard Meshtastic gear:
//    - ATAK Plugin for Meshtastic (Android)
//    - Meshtastic phone app in TAK role
//    - TAK_Meshtastic_Gateway
//
//  Phase 1's TAKMessage{CoTEvent} schema is kept alive in ATAKPluginParser
//  as the inbound fallback (detected by ATAKPluginParser.parseDetailed calling
//  parseTAKPacket first, then parseTAKMessage on failure).
//
//  TAKPacket wire schema (proto3, hand-rolled):
//
//  message TAKPacket {
//      bool     is_compressed  = 1;  // varint (wire 0)
//      Contact  contact        = 2;  // LEN (wire 2)
//      Group    group          = 3;  // LEN
//      Status   status         = 4;  // LEN
//      oneof payload_variant {
//          PLI     pli         = 5;  // LEN
//          GeoChat chat        = 6;  // LEN
//      }
//  }
//  message Contact { bytes callsign = 1; bytes device_callsign = 2; }
//  message Group   { MemberRole role = 1; Team team = 2; }   // both varint
//  message Status  { uint32 battery = 1; }                   // varint
//  message PLI     { sfixed32 latitude_i = 1; sfixed32 longitude_i = 2;
//                    int32 altitude = 3; uint32 speed = 4; uint32 course = 5; }
//  message GeoChat { bytes message = 1; bytes to = 2; bytes to_callsign = 3; }
//
//  Enums:
//    Team: Unspecifed_Color=0 White=1 Yellow=2 Orange=3 Magenta=4 Red=5
//          Maroon=6 Purple=7 Dark_Blue=8 Blue=9 Cyan=10 Teal=11 Green=12
//          Dark_Green=13 Brown=14
//    MemberRole: Unspecifed=0 TeamMember=1 TeamLead=2 HQ=3 Sniper=4
//                Medic=5 ForwardObserver=6 RTO=7 K9=8
//
//  sfixed32 = 4 little-endian bytes of the Int32 two's complement bit-pattern
//  (NOT zigzag). Negative longitudes like -122.3321 → round-trip correctly.
//
//  Unishox2 compression:
//  When is_compressed=true, all bytes fields in Contact, GeoChat.message, and
//  GeoChat.to are individually compressed with unishox2_compress_simple /
//  unishox2_decompress_simple using USX_PSET_DFLT. GeoChat.to_callsign is
//  only written in compressed outbound packets when present.
//
//  Wire helpers are intentionally identical in style to ATAKPluginSerializer
//  so the two files can be kept in sync easily.
//

import Foundation

// MARK: - Enums (mirrors atak.proto)

/// Meshtastic TAK team colour codes.
enum TAKTeam: UInt64 {
    case unspecifiedColor = 0
    case white       = 1
    case yellow      = 2
    case orange      = 3
    case magenta     = 4
    case red         = 5
    case maroon      = 6
    case purple      = 7
    case darkBlue    = 8
    case blue        = 9
    case cyan        = 10
    case teal        = 11
    case green       = 12
    case darkGreen   = 13
    case brown       = 14

    /// Map a TAK/ATAK team name string (any case, space or underscore) to the enum.
    /// Unrecognised strings → .unspecifiedColor.
    init(name: String) {
        let normalised = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        switch normalised {
        case "white":       self = .white
        case "yellow":      self = .yellow
        case "orange":      self = .orange
        case "magenta":     self = .magenta
        case "red":         self = .red
        case "maroon":      self = .maroon
        case "purple":      self = .purple
        case "dark_blue":   self = .darkBlue
        case "blue":        self = .blue
        case "cyan":        self = .cyan
        case "teal":        self = .teal
        case "green":       self = .green
        case "dark_green":  self = .darkGreen
        case "brown":       self = .brown
        default:            self = .unspecifiedColor
        }
    }

    /// Return the display name as used in CoT `<__group>` elements.
    var displayName: String {
        switch self {
        case .unspecifiedColor: return "Unspecifed Color"
        case .white:       return "White"
        case .yellow:      return "Yellow"
        case .orange:      return "Orange"
        case .magenta:     return "Magenta"
        case .red:         return "Red"
        case .maroon:      return "Maroon"
        case .purple:      return "Purple"
        case .darkBlue:    return "Dark Blue"
        case .blue:        return "Blue"
        case .cyan:        return "Cyan"
        case .teal:        return "Teal"
        case .green:       return "Green"
        case .darkGreen:   return "Dark Green"
        case .brown:       return "Brown"
        }
    }
}

/// Meshtastic TAK member role codes.
enum TAKMemberRole: UInt64 {
    case unspecified       = 0
    case teamMember        = 1
    case teamLead          = 2
    case hq                = 3
    case sniper            = 4
    case medic             = 5
    case forwardObserver   = 6
    case rto               = 7
    case k9                = 8

    /// Map a role display string (any case) to the enum.
    init(name: String) {
        let normalised = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        switch normalised {
        case "teammember":      self = .teamMember
        case "teamlead":        self = .teamLead
        case "hq":              self = .hq
        case "sniper":          self = .sniper
        case "medic":           self = .medic
        case "forwardobserver": self = .forwardObserver
        case "rto":             self = .rto
        case "k9":              self = .k9
        default:                self = .unspecified
        }
    }

    var displayName: String {
        switch self {
        case .unspecified:     return "Unspecifed"
        case .teamMember:      return "Team Member"
        case .teamLead:        return "Team Lead"
        case .hq:              return "HQ"
        case .sniper:          return "Sniper"
        case .medic:           return "Medic"
        case .forwardObserver: return "Forward Observer"
        case .rto:             return "RTO"
        case .k9:              return "K9"
        }
    }
}

// MARK: - Decoded model

/// Decoded representation of a portnum-72 TAKPacket payload.
struct DecodedTAKPacket {
    var isCompressed: Bool = false
    var callsign: String = ""
    var deviceCallsign: String = ""
    var team: TAKTeam = .unspecifiedColor
    var role: TAKMemberRole = .unspecified
    var battery: UInt32 = 0
    // PLI fields
    var latitudeI: Int32?
    var longitudeI: Int32?
    var altitude: Int32?
    var speed: UInt32?
    var course: UInt32?
    // GeoChat fields
    var chatMessage: String?
    var chatTo: String?
    var chatToCallsign: String?

    var hasPLI: Bool { latitudeI != nil }
    var hasChat: Bool { chatMessage != nil }
}

// MARK: - Codec

enum TAKPacketCodec {

    // MARK: - Unishox2 Swift wrappers

    /// Compress a UTF-8 string with unishox2 (USX_PSET_DFLT).
    /// Returns the compressed bytes, or the original UTF-8 bytes on failure.
    static func compress(_ text: String) -> Data {
        let utf8 = text.utf8
        let inLen = Int32(utf8.count)
        // Unishox2 worst-case output is slightly larger than input.
        let bufSize = max(Int(inLen) * 2 + 16, 32)
        var outBuf = [CChar](repeating: 0, count: bufSize)
        let result = text.withCString { inPtr in
            unishox2_compress_simple(inPtr, inLen, &outBuf)
        }
        if result <= 0 {
            // Compression failed — return raw UTF-8 (caller must handle is_compressed=false)
            return Data(utf8)
        }
        return Data(bytes: outBuf, count: Int(result))
    }

    /// Decompress unishox2-compressed bytes to a UTF-8 string.
    /// Returns nil if decompression fails.
    static func decompress(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let inLen = Int32(data.count)
        let bufSize = max(data.count * 8 + 64, 256)
        var outBuf = [CChar](repeating: 0, count: bufSize)
        let result = data.withUnsafeBytes { rawBuf -> Int32 in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: CChar.self) else { return -1 }
            return unishox2_decompress_simple(ptr, inLen, &outBuf)
        }
        guard result >= 0 else { return nil }
        outBuf[Int(result)] = 0  // null-terminate
        return String(cString: outBuf)
    }

    // MARK: - Decode

    /// Attempt to decode a portnum-72 payload as a TAKPacket.
    ///
    /// Returns a `DecodedTAKPacket` if the payload yields either a PLI or a
    /// GeoChat (and optionally a contact). Returns nil if the bytes don't look
    /// like a valid TAKPacket (e.g. Phase-1 TAKMessage payload).
    static func decode(_ data: Data) -> DecodedTAKPacket? {
        var pkt = DecodedTAKPacket()
        var idx = 0
        var seenContact = false
        var seenPLI = false
        var seenChat = false

        while idx < data.count {
            guard let tag = readTag(data, &idx) else { break }

            switch (tag.field, tag.wire) {
            case (1, 0): // is_compressed: bool (varint)
                guard let v = readVarint(data, &idx) else { return nil }
                pkt.isCompressed = v != 0
            case (2, 2): // contact: LEN
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseContact(bytes, into: &pkt, compressed: false) // defer decompression
                seenContact = true
            case (3, 2): // group: LEN
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseGroup(bytes, into: &pkt)
            case (4, 2): // status: LEN
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseStatus(bytes, into: &pkt)
            case (5, 2): // pli: LEN (oneof)
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parsePLI(bytes, into: &pkt)
                seenPLI = true
            case (6, 2): // chat: LEN (oneof)
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseGeoChat(bytes, into: &pkt, compressed: false) // defer
                seenChat = true
            case (7, 2): // detail (ignored — not present on Meshtastic payloads)
                guard readLengthDelimited(data, &idx) != nil else { return nil }
            default:
                if !skip(data, &idx, wire: tag.wire) { return nil }
            }
        }

        // Must have at least one of PLI or chat to be a meaningful TAKPacket.
        guard seenPLI || seenChat || seenContact else { return nil }

        // Now handle decompression if is_compressed=true.
        // We stored raw bytes in callsign/deviceCallsign/chatMessage/chatTo during
        // parsing with compressed=false; re-parse the raw store.
        // Easier: just re-parse the whole packet once we know is_compressed.
        if pkt.isCompressed {
            return decodeCompressed(data)
        }

        return pkt
    }

    /// Re-parse a TAKPacket with decompression enabled (called when is_compressed=true).
    private static func decodeCompressed(_ data: Data) -> DecodedTAKPacket? {
        var pkt = DecodedTAKPacket()
        pkt.isCompressed = true
        var idx = 0
        var seenPLI = false
        var seenChat = false
        var seenContact = false

        while idx < data.count {
            guard let tag = readTag(data, &idx) else { break }
            switch (tag.field, tag.wire) {
            case (1, 0):
                guard let v = readVarint(data, &idx) else { return nil }
                pkt.isCompressed = v != 0
            case (2, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseContact(bytes, into: &pkt, compressed: true)
                seenContact = true
            case (3, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseGroup(bytes, into: &pkt)
            case (4, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseStatus(bytes, into: &pkt)
            case (5, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parsePLI(bytes, into: &pkt)
                seenPLI = true
            case (6, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseGeoChat(bytes, into: &pkt, compressed: true)
                seenChat = true
            default:
                if !skip(data, &idx, wire: tag.wire) { return nil }
            }
        }

        guard seenPLI || seenChat || seenContact else { return nil }
        return pkt
    }

    // MARK: - Submessage parsers

    private static func parseContact(
        _ data: Data,
        into pkt: inout DecodedTAKPacket,
        compressed: Bool
    ) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 2): // callsign: bytes
                guard let raw = readLengthDelimited(data, &idx) else { return }
                if compressed {
                    pkt.callsign = decompress(raw) ?? String(data: raw, encoding: .utf8) ?? ""
                } else {
                    pkt.callsign = String(data: raw, encoding: .utf8) ?? ""
                }
            case (2, 2): // device_callsign: bytes
                guard let raw = readLengthDelimited(data, &idx) else { return }
                if compressed {
                    pkt.deviceCallsign = decompress(raw) ?? String(data: raw, encoding: .utf8) ?? ""
                } else {
                    pkt.deviceCallsign = String(data: raw, encoding: .utf8) ?? ""
                }
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    private static func parseGroup(_ data: Data, into pkt: inout DecodedTAKPacket) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 0): // role: MemberRole (varint)
                guard let v = readVarint(data, &idx) else { return }
                pkt.role = TAKMemberRole(rawValue: v) ?? .unspecified
            case (2, 0): // team: Team (varint)
                guard let v = readVarint(data, &idx) else { return }
                pkt.team = TAKTeam(rawValue: v) ?? .unspecifiedColor
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    private static func parseStatus(_ data: Data, into pkt: inout DecodedTAKPacket) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 0): // battery: uint32 varint
                guard let v = readVarint(data, &idx) else { return }
                pkt.battery = UInt32(truncatingIfNeeded: v)
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    private static func parsePLI(_ data: Data, into pkt: inout DecodedTAKPacket) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 5): // latitude_i: sfixed32 (wire type 5 = 32-bit)
                guard let v = readFixed32(data, &idx) else { return }
                pkt.latitudeI = Int32(bitPattern: v)
            case (2, 5): // longitude_i: sfixed32
                guard let v = readFixed32(data, &idx) else { return }
                pkt.longitudeI = Int32(bitPattern: v)
            case (3, 0): // altitude: int32 (varint — can be negative, need zigzag? No. proto3 int32 is plain varint, not sint32.)
                // Actually proto3 int32 uses zigzag encoding only for sint32.
                // Regular int32 stores negative numbers as 64-bit varint (10 bytes).
                guard let v = readVarint(data, &idx) else { return }
                pkt.altitude = Int32(bitPattern: UInt32(truncatingIfNeeded: v))
            case (4, 0): // speed: uint32
                guard let v = readVarint(data, &idx) else { return }
                pkt.speed = UInt32(truncatingIfNeeded: v)
            case (5, 0): // course: uint32
                guard let v = readVarint(data, &idx) else { return }
                pkt.course = UInt32(truncatingIfNeeded: v)
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    private static func parseGeoChat(
        _ data: Data,
        into pkt: inout DecodedTAKPacket,
        compressed: Bool
    ) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 2): // message: bytes
                guard let raw = readLengthDelimited(data, &idx) else { return }
                if compressed {
                    pkt.chatMessage = decompress(raw) ?? String(data: raw, encoding: .utf8)
                } else {
                    pkt.chatMessage = String(data: raw, encoding: .utf8)
                }
            case (2, 2): // to: bytes
                guard let raw = readLengthDelimited(data, &idx) else { return }
                // The gateway/stock-plugin sends chat.to as raw UTF-8 even when
                // is_compressed=true (asymmetric: message IS compressed, to is NOT).
                // Prefer raw UTF-8; only attempt unishox2 as a fallback when the
                // raw bytes are not valid UTF-8.
                if compressed {
                    if let rawStr = String(data: raw, encoding: .utf8) {
                        // Raw bytes are valid UTF-8 — use them directly.
                        pkt.chatTo = rawStr
                    } else {
                        // Not valid UTF-8; try unishox2 decompression as fallback.
                        pkt.chatTo = decompress(raw)
                    }
                } else {
                    pkt.chatTo = String(data: raw, encoding: .utf8)
                }
            case (3, 2): // to_callsign: bytes
                guard let raw = readLengthDelimited(data, &idx) else { return }
                if compressed {
                    pkt.chatToCallsign = decompress(raw) ?? String(data: raw, encoding: .utf8)
                } else {
                    pkt.chatToCallsign = String(data: raw, encoding: .utf8)
                }
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    // MARK: - Encode

    /// Encode a CoTEvent into a TAKPacket payload for portnum-72 TX.
    ///
    /// - a-* events → PLI packet (is_compressed=false, raw UTF-8 callsigns)
    /// - b-t-f events → GeoChat packet (is_compressed=true, unishox2-compressed fields)
    ///
    /// Returns nil if the event type is neither a-* nor b-t-f.
    static func encode(_ event: CoTEvent) -> Data? {
        if event.type.hasPrefix("a-") {
            return encodePLI(event)
        } else if event.type == "b-t-f" {
            return encodeGeoChat(event)
        }
        return nil
    }

    // MARK: - PLI encode

    private static func encodePLI(_ event: CoTEvent) -> Data {
        var out = Data()

        // field 1: is_compressed = false (default=0, omit per proto3 convention,
        // but explicit for clarity and byte-level matching with the gateway)
        // Gateway omits is_compressed when false in PLI: we do the same.
        // (Proto3 omits default values on the wire.)

        // field 2: contact
        var contact = Data()
        appendBytes(&contact, field: 1, value: Data(event.detail.callsign.utf8))
        let deviceCallsign = event.uid   // use UID as device_callsign (matches gateway)
        appendBytes(&contact, field: 2, value: Data(deviceCallsign.utf8))
        appendTag(&out, field: 2, wire: 2)
        appendVarint(&out, UInt64(contact.count))
        out.append(contact)

        // field 3: group
        let team = TAKTeam(name: event.detail.team ?? "")
        // Derive role from the CoT detail; normalize spaces (e.g. "Team Lead" → "TeamLead").
        let roleStr = (event.detail.teamRole ?? "TeamMember")
            .replacingOccurrences(of: " ", with: "")
        let role = TAKMemberRole(name: roleStr)
        if team != .unspecifiedColor || role != .unspecified {
            var group = Data()
            if role != .unspecified {
                appendVarintField(&group, field: 1, value: role.rawValue)
            }
            if team != .unspecifiedColor {
                appendVarintField(&group, field: 2, value: team.rawValue)
            }
            appendTag(&out, field: 3, wire: 2)
            appendVarint(&out, UInt64(group.count))
            out.append(group)
        }

        // field 4: status (battery)
        if let battery = event.detail.battery {
            var status = Data()
            appendVarintField(&status, field: 1, value: UInt64(max(0, battery)))
            appendTag(&out, field: 4, wire: 2)
            appendVarint(&out, UInt64(status.count))
            out.append(status)
        }

        // field 5: pli
        let latI = Int32(event.point.lat * 1e7)
        let lonI = Int32(event.point.lon * 1e7)
        let altI = Int32(event.point.hae)
        var pli = Data()
        // latitude_i: sfixed32 (wire type 5)
        appendTag(&pli, field: 1, wire: 5)
        appendFixed32(&pli, value: UInt32(bitPattern: latI))
        // longitude_i: sfixed32
        appendTag(&pli, field: 2, wire: 5)
        appendFixed32(&pli, value: UInt32(bitPattern: lonI))
        // altitude: int32 varint
        if altI != 0 {
            appendVarintField(&pli, field: 3, value: UInt64(bitPattern: Int64(altI)))
        }
        // speed: uint32
        if let speed = event.detail.speed {
            let speedI = UInt32(max(0, speed))
            if speedI != 0 {
                appendVarintField(&pli, field: 4, value: UInt64(speedI))
            }
        }
        // course: uint32
        if let course = event.detail.course {
            let courseI = UInt32(max(0, course))
            if courseI != 0 {
                appendVarintField(&pli, field: 5, value: UInt64(courseI))
            }
        }
        appendTag(&out, field: 5, wire: 2)
        appendVarint(&out, UInt64(pli.count))
        out.append(pli)

        return out
    }

    // MARK: - GeoChat encode

    private static func encodeGeoChat(_ event: CoTEvent) -> Data {
        var out = Data()

        // field 1: is_compressed = true
        appendVarintField(&out, field: 1, value: 1)

        // field 2: contact (compressed)
        let callsignData = compress(event.detail.callsign)
        let deviceCallsignData = compress(event.uid)
        var contact = Data()
        appendBytes(&contact, field: 1, value: callsignData)
        appendBytes(&contact, field: 2, value: deviceCallsignData)
        appendTag(&out, field: 2, wire: 2)
        appendVarint(&out, UInt64(contact.count))
        out.append(contact)

        // field 3: group (compressed — team/role are varint, not bytes, so no compression)
        let team = TAKTeam(name: event.detail.team ?? "")
        // Derive role from the CoT detail; normalize spaces (e.g. "Team Lead" → "TeamLead").
        let roleStr = (event.detail.teamRole ?? "TeamMember")
            .replacingOccurrences(of: " ", with: "")
        let role = TAKMemberRole(name: roleStr)
        if team != .unspecifiedColor || role != .unspecified {
            var group = Data()
            if role != .unspecified {
                appendVarintField(&group, field: 1, value: role.rawValue)
            }
            if team != .unspecifiedColor {
                appendVarintField(&group, field: 2, value: team.rawValue)
            }
            appendTag(&out, field: 3, wire: 2)
            appendVarint(&out, UInt64(group.count))
            out.append(group)
        }

        // field 4: status (battery)
        if let battery = event.detail.battery {
            var status = Data()
            appendVarintField(&status, field: 1, value: UInt64(max(0, battery)))
            appendTag(&out, field: 4, wire: 2)
            appendVarint(&out, UInt64(status.count))
            out.append(status)
        }

        // field 6: chat (compressed)
        let message = event.detail.remarks ?? ""
        let messageData = compress(message)
        // "to" is kept raw per gateway spec (chat.to raw in TX)
        let toStr = "All Chat Rooms"
        var chat = Data()
        appendBytes(&chat, field: 1, value: messageData)
        appendBytes(&chat, field: 2, value: Data(toStr.utf8))
        appendTag(&out, field: 6, wire: 2)
        appendVarint(&out, UInt64(chat.count))
        out.append(chat)

        return out
    }

    // MARK: - Wire helpers (mirrors ATAKPluginSerializer style)

    private static func appendTag(_ data: inout Data, field: Int, wire: UInt8) {
        appendVarint(&data, UInt64(field) << 3 | UInt64(wire))
    }

    static func appendVarint(_ data: inout Data, _ value: UInt64) {
        var v = value
        if v == 0 {
            data.append(0)
            return
        }
        while v > 0x7F {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private static func appendVarintField(_ data: inout Data, field: Int, value: UInt64) {
        appendTag(&data, field: field, wire: 0)
        appendVarint(&data, value)
    }

    private static func appendFixed32(_ data: inout Data, value: UInt32) {
        for i in 0..<4 {
            data.append(UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    private static func appendBytes(_ data: inout Data, field: Int, value: Data) {
        appendTag(&data, field: field, wire: 2)
        appendVarint(&data, UInt64(value.count))
        data.append(value)
    }

    // MARK: - Wire read helpers

    private struct WireTag { let field: Int; let wire: UInt8 }

    private static func readTag(_ data: Data, _ idx: inout Int) -> WireTag? {
        guard let v = readVarint(data, &idx) else { return nil }
        return WireTag(field: Int(v >> 3), wire: UInt8(v & 0x07))
    }

    static func readVarint(_ data: Data, _ idx: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while idx < data.count {
            let byte = data[idx]
            idx += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private static func readFixed32(_ data: Data, _ idx: inout Int) -> UInt32? {
        guard idx + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 {
            v |= UInt32(data[idx + i]) << (8 * i)
        }
        idx += 4
        return v
    }

    private static func readLengthDelimited(_ data: Data, _ idx: inout Int) -> Data? {
        guard let len = readVarint(data, &idx) else { return nil }
        let end = idx + Int(len)
        guard end <= data.count else { return nil }
        let slice = data.subdata(in: idx..<end)
        idx = end
        return slice
    }

    private static func skip(_ data: Data, _ idx: inout Int, wire: UInt8) -> Bool {
        switch wire {
        case 0: return readVarint(data, &idx) != nil
        case 1:
            guard idx + 8 <= data.count else { return false }
            idx += 8; return true
        case 2:
            guard let len = readVarint(data, &idx) else { return false }
            let end = idx + Int(len)
            guard end <= data.count else { return false }
            idx = end; return true
        case 5:
            guard idx + 4 <= data.count else { return false }
            idx += 4; return true
        default: return false
        }
    }
}

// MARK: - CoTEvent builder from DecodedTAKPacket

extension TAKPacketCodec {

    /// Convert a decoded TAKPacket into a CoTEvent suitable for the existing
    /// CoTEventHandler pipeline.
    ///
    /// - PLI → `a-f-G-U-C` with point populated from lat/lon (÷1e7), detail
    ///   populated with callsign, team, speed, course, battery.
    /// - GeoChat → `b-t-f` with uid `GeoChat.<from>.<to>.<uuid>`, callsign,
    ///   and remarks containing the chat text.
    ///
    /// Returns nil for packets with neither PLI nor chat.
    static func toCoTEvent(
        _ pkt: DecodedTAKPacket,
        fromUID: String? = nil,
        receiveTime: Date = Date()
    ) -> CoTEvent? {
        if pkt.hasPLI {
            return pliToCoTEvent(pkt, receiveTime: receiveTime)
        } else if pkt.hasChat {
            return chatToCoTEvent(pkt, fromUID: fromUID, receiveTime: receiveTime)
        }
        return nil
    }

    private static func pliToCoTEvent(_ pkt: DecodedTAKPacket, receiveTime: Date) -> CoTEvent {
        let lat = Double(pkt.latitudeI ?? 0) / 1e7
        let lon = Double(pkt.longitudeI ?? 0) / 1e7
        let hae = Double(pkt.altitude ?? 0)
        let speed = pkt.speed.map(Double.init)
        let course = pkt.course.map(Double.init)

        let detail = CoTDetail(
            callsign: pkt.callsign.isEmpty ? pkt.deviceCallsign : pkt.callsign,
            team: pkt.team == .unspecifiedColor ? nil : pkt.team.displayName,
            teamRole: pkt.role == .unspecified ? nil : pkt.role.displayName,
            speed: speed,
            course: course,
            remarks: nil,
            battery: pkt.battery > 0 ? Int(pkt.battery) : nil,
            device: "Meshtastic",
            platform: "Meshtastic"
        )

        let uid = pkt.deviceCallsign.isEmpty ? pkt.callsign : pkt.deviceCallsign
        return CoTEvent(
            uid: uid,
            type: "a-f-G-U-C",
            time: receiveTime,
            point: CoTPoint(lat: lat, lon: lon, hae: hae, ce: 9999, le: 9999),
            detail: detail
        )
    }

    private static func chatToCoTEvent(
        _ pkt: DecodedTAKPacket,
        fromUID: String?,
        receiveTime: Date
    ) -> CoTEvent {
        let senderUID = fromUID ?? (pkt.deviceCallsign.isEmpty ? pkt.callsign : pkt.deviceCallsign)
        let toUID = pkt.chatTo ?? "All Chat Rooms"
        let msgUID = "GeoChat.\(senderUID).\(toUID).\(UUID().uuidString)"

        let detail = CoTDetail(
            callsign: pkt.callsign.isEmpty ? senderUID : pkt.callsign,
            team: pkt.team == .unspecifiedColor ? nil : pkt.team.displayName,
            teamRole: pkt.role == .unspecified ? nil : pkt.role.displayName,
            speed: nil,
            course: nil,
            remarks: pkt.chatMessage,
            battery: nil,
            device: nil,
            platform: nil
        )

        return CoTEvent(
            uid: msgUID,
            type: "b-t-f",
            time: receiveTime,
            point: CoTPoint(lat: 0, lon: 0, hae: 0, ce: 9999, le: 9999),
            detail: detail
        )
    }
}
