//
//  MeshtasticChannelCodec.swift
//  OmniTAK Mobile
//
//  Clean-room encoder/decoder for the Meshtastic "channel set" share URL —
//  the `https://meshtastic.org/e/#<base64url>` link / QR that the stock
//  Meshtastic app uses to share a channel (name + PSK) with other devices.
//
//  Closed-test feedback (PatoG1899): operators want to create + share a
//  channel from inside OmniTAK instead of preconfiguring every radio in the
//  stock app. This is the testable core of that feature.
//
//  Licensing: independent clean-room implementation. Protobuf field numbers
//  and the URL layout are an interface (not copyrightable); no GPL proto or
//  SDK code is copied. Same approach as the existing v1 TAKPacket codec.
//
//  Wire format:
//    URL  = "https://meshtastic.org/e/#" + base64url(ChannelSet protobuf), no '='
//    ChannelSet { repeated ChannelSettings settings = 1; LoRaConfig lora_config = 2 }
//    ChannelSettings { bytes psk = 2; string name = 3; fixed32 id = 4;
//                      bool uplink_enabled = 5; bool downlink_enabled = 6 }
//

import Foundation

/// One Meshtastic channel as carried in a share URL.
struct MeshChannel: Equatable {
    var name: String
    /// Pre-shared key. 0 bytes = no crypto; 1 byte = default-key shorthand
    /// (n selects the well-known key + n); 16/32 bytes = AES128/256.
    var psk: Data
    var uplinkEnabled: Bool = false
    var downlinkEnabled: Bool = false
}

enum MeshtasticChannelCodec {

    static let urlPrefix = "https://meshtastic.org/e/#"

    // MARK: - Encode

    /// Build the shareable channel-set URL for one or more channels.
    /// `loraConfig` is optional opaque LoRaConfig protobuf bytes (passed through
    /// verbatim when present so the preset/region travel with the share).
    static func encodeURL(_ channels: [MeshChannel], loraConfig: Data? = nil) -> String {
        var set = Data()
        for ch in channels {
            appendBytes(&set, field: 1, value: encodeSettings(ch))
        }
        if let lora = loraConfig, !lora.isEmpty {
            appendBytes(&set, field: 2, value: lora)
        }
        return urlPrefix + base64url(set)
    }

    private static func encodeSettings(_ ch: MeshChannel) -> Data {
        var s = Data()
        if !ch.psk.isEmpty {
            appendBytes(&s, field: 2, value: ch.psk)
        }
        if !ch.name.isEmpty {
            appendBytes(&s, field: 3, value: Data(ch.name.utf8))
        }
        if ch.uplinkEnabled { appendVarintField(&s, field: 5, value: 1) }
        if ch.downlinkEnabled { appendVarintField(&s, field: 6, value: 1) }
        return s
    }

    // MARK: - Decode

    /// Parse a channel-set URL (or the bare base64url fragment) into channels.
    /// Returns nil if the input isn't a recognizable channel-set link.
    static func decodeURL(_ input: String) -> [MeshChannel]? {
        let frag: String
        if let hashIdx = input.firstIndex(of: "#") {
            frag = String(input[input.index(after: hashIdx)...])
        } else if !input.contains("/") {
            frag = input // bare fragment
        } else {
            return nil
        }
        guard !frag.isEmpty, let data = base64urlDecode(frag) else { return nil }

        var channels: [MeshChannel] = []
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return channels.isEmpty ? nil : channels }
            switch (tag.field, tag.wire) {
            case (1, 2):
                if let body = readLengthDelimited(data, &idx), let ch = decodeSettings(body) {
                    channels.append(ch)
                }
            default:
                if !skip(data, &idx, wire: tag.wire) { return channels.isEmpty ? nil : channels }
            }
        }
        return channels.isEmpty ? nil : channels
    }

    private static func decodeSettings(_ data: Data) -> MeshChannel? {
        var idx = 0
        var psk = Data()
        var name = ""
        var up = false
        var down = false
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { break }
            switch (tag.field, tag.wire) {
            case (2, 2): psk = readLengthDelimited(data, &idx) ?? psk
            case (3, 2): name = (readLengthDelimited(data, &idx).flatMap { String(data: $0, encoding: .utf8) }) ?? name
            case (5, 0): up = (readVarint(data, &idx) ?? 0) != 0
            case (6, 0): down = (readVarint(data, &idx) ?? 0) != 0
            default: if !skip(data, &idx, wire: tag.wire) { return nil }
            }
        }
        return MeshChannel(name: name, psk: psk, uplinkEnabled: up, downlinkEnabled: down)
    }

    // MARK: - base64url

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64urlDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        return Data(base64Encoded: b64)
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

    private struct WireTag { let field: Int; let wire: UInt8 }
    private static func readTag(_ data: Data, _ idx: inout Int) -> WireTag? {
        guard let v = readVarint(data, &idx) else { return nil }
        return WireTag(field: Int(v >> 3), wire: UInt8(v & 0x07))
    }
    private static func readVarint(_ data: Data, _ idx: inout Int) -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while idx < data.count {
            let byte = data[data.startIndex + idx]; idx += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7; if shift >= 64 { return nil }
        }
        return nil
    }
    private static func readLengthDelimited(_ data: Data, _ idx: inout Int) -> Data? {
        // Compared as UInt64 first: a varint above Int.max would trap in the
        // conversion, and a pasted link is untrusted input.
        guard let len = readVarint(data, &idx), len <= UInt64(data.count - idx) else { return nil }
        let end = idx + Int(len)
        let slice = data.subdata(in: (data.startIndex + idx)..<(data.startIndex + end))
        idx = end; return slice
    }
    private static func skip(_ data: Data, _ idx: inout Int, wire: UInt8) -> Bool {
        switch wire {
        case 0: return readVarint(data, &idx) != nil
        case 1: guard idx + 8 <= data.count else { return false }; idx += 8; return true
        case 2: guard let len = readVarint(data, &idx), len <= UInt64(data.count - idx) else { return false }
                idx += Int(len); return true
        case 5: guard idx + 4 <= data.count else { return false }; idx += 4; return true
        default: return false
        }
    }
}
