//
//  TAKPacketV2Codec.swift
//  OmniTAK Mobile
//
//  Clean-room encoder/decoder for Meshtastic TAKPacketV2 (PortNum 78,
//  ATAK_PLUGIN_V2) carrying a tactical MARKER — the wire format the legacy
//  TAKPacket v1 (port 72, PLI + GeoChat only) cannot represent.
//
//  IMPORTANT — licensing: this is an independent, clean-room implementation.
//  The Meshtastic TAK SDKs and the `atak.proto` source file are GPL-3.0 (no
//  linking exception); OmniTAK is Apache-2.0. Protobuf field NUMBERS and the
//  wire layout are an interface, not copyrightable expression, so we hand-roll
//  the bytes here exactly as `TAKPacketCodec` already hand-rolls v1 — copying
//  no GPL code or .proto text. We emit ONLY the 0xFF (uncompressed) envelope,
//  which stock ATAK / iTAK / Meshtastic >= 2.8.0 accept, so we interoperate
//  without the GPL-licensed zstd dictionary.
//
//  Envelope on the wire (Data.payload for portnum 78):
//      [1 byte flags = 0xFF][TAKPacketV2 protobuf body]
//
//  TAKPacketV2 fields used (numbers are facts from the published wire spec):
//      callsign       = 3   (string)
//      latitude_i     = 6   (sfixed32, degrees * 1e7)
//      longitude_i    = 7   (sfixed32, degrees * 1e7)
//      altitude       = 8   (sint32, metres HAE, zigzag)
//      uid            = 14  (string)   <- preserved verbatim
//      stale_seconds  = 16  (uint32)
//      cot_type_str   = 23  (string)   <- raw CoT type, e.g. "a-u-G"
//      remarks        = 24  (string)
//      marker         = 35  (Marker submessage, payload_variant oneof)
//  Marker submessage:
//      kind           = 1   (enum)
//      color_argb     = 3   (fixed32, signed ARGB as bit pattern)
//      readiness      = 4   (bool)
//      iconset        = 8   (string)
//

import Foundation

enum TAKPacketV2Codec {

    /// Meshtastic PortNum for TAKPacketV2.
    static let portnum: UInt64 = 78

    /// Envelope flag byte signalling an uncompressed protobuf body.
    static let flagUncompressed: UInt8 = 0xFF

    /// Conservative wire budget; a Meshtastic Data payload caps at 233 bytes.
    static let maxWireBytes = 225

    // MARK: - Marker kind (clean-room enum mirroring the wire values)

    enum MarkerKind: UInt64 {
        case unspecified = 0
        case spot = 1
        case waypoint = 2
        case checkpoint = 3
        case selfPosition = 4
        case symbol2525 = 5
        case spotMap = 6
        case customIcon = 7
        case goToPoint = 8
        case initialPoint = 9
        case contactPoint = 10
        case observationPost = 11
        case imageMarker = 12
    }

    // MARK: - Encode

    /// Encode a dropped-marker CoTEvent into a port-78 payload.
    ///
    /// Returns nil if the resulting packet would exceed the LoRa wire budget
    /// (the caller should fall back to a v1 GeoChat-degraded text line).
    static func encodeMarker(_ event: CoTEvent, staleSeconds: UInt32 = 3600) -> Data? {
        var body = Data()

        // field 3: callsign
        if !event.detail.callsign.isEmpty {
            appendBytes(&body, field: 3, value: Data(event.detail.callsign.utf8))
        }

        // field 6 / 7: latitude_i / longitude_i (sfixed32, 1e-7 deg)
        let latI = Int32((event.point.lat * 1e7).rounded())
        let lonI = Int32((event.point.lon * 1e7).rounded())
        appendTag(&body, field: 6, wire: 5)
        appendFixed32(&body, UInt32(bitPattern: latI))
        appendTag(&body, field: 7, wire: 5)
        appendFixed32(&body, UInt32(bitPattern: lonI))

        // field 8: altitude (sint32 HAE), only if meaningful
        let alt = Int32(event.point.hae.rounded())
        if alt != 0 {
            appendVarintField(&body, field: 8, value: zigzag32(alt))
        }

        // field 14: uid — preserved VERBATIM (the marker's identity across
        // mesh hops and the eventual server-reconnect dedup)
        appendBytes(&body, field: 14, value: Data(event.uid.utf8))

        // field 16: stale_seconds
        if staleSeconds > 0 {
            appendVarintField(&body, field: 16, value: UInt64(staleSeconds))
        }

        // field 23: cot_type_str — the raw CoT type restores the marker faithfully
        appendBytes(&body, field: 23, value: Data(event.type.utf8))

        // field 24: remarks (optional; first to be dropped under the size guard)
        if let remarks = event.detail.remarks, !remarks.isEmpty {
            appendBytes(&body, field: 24, value: Data(remarks.utf8))
        }

        // field 35: marker submessage
        appendBytes(&body, field: 35, value: encodeMarkerSubmessage(event))

        // Size guard: strip remarks and retry once if over budget.
        if body.count + 1 > maxWireBytes, event.detail.remarks?.isEmpty == false {
            var stripped = event
            stripped = CoTEvent(
                uid: event.uid, type: event.type, time: event.time,
                point: event.point,
                detail: detailWithoutRemarks(event.detail)
            )
            return encodeMarker(stripped, staleSeconds: staleSeconds)
        }
        guard body.count + 1 <= maxWireBytes else { return nil }

        // Prepend the uncompressed-envelope flag byte.
        var out = Data([flagUncompressed])
        out.append(body)
        return out
    }

    private static func encodeMarkerSubmessage(_ event: CoTEvent) -> Data {
        var marker = Data()

        // field 1: kind — inferred from CoT type + iconset
        let kind = inferKind(type: event.type, iconset: event.detail.iconsetPath)
        if kind != .unspecified {
            appendVarintField(&marker, field: 1, value: kind.rawValue)
        }

        // field 3: color_argb (fixed32, signed ARGB bit pattern)
        if let argb = event.detail.argbColor {
            appendTag(&marker, field: 3, wire: 5)
            appendFixed32(&marker, UInt32(bitPattern: Int32(truncatingIfNeeded: argb)))
        }

        // field 4: readiness (default true)
        appendVarintField(&marker, field: 4, value: 1)

        // field 8: iconset path (drives the 2525 / FEMA / custom icon on receive)
        if let iconset = event.detail.iconsetPath, !iconset.isEmpty {
            appendBytes(&marker, field: 8, value: Data(iconset.utf8))
        }

        return marker
    }

    private static func inferKind(type: String, iconset: String?) -> MarkerKind {
        if let icon = iconset?.uppercased() {
            if icon.contains("2525") { return .symbol2525 }
            if icon.contains("SPOTMAP") { return .spotMap }
            if icon.contains(".PNG") { return .customIcon }
        }
        // CoT waypoint / spot families
        if type.hasPrefix("b-m-p-w") { return .waypoint }
        if type.hasPrefix("b-m-p-c") { return .checkpoint }
        if type.hasPrefix("b-m-p-s") { return .spot }
        return .spot
    }

    // MARK: - Decode

    /// Decode a port-78 payload back into a marker CoTEvent.
    ///
    /// Preserves the original uid verbatim and restores the real CoT type,
    /// position, color and iconset, so the result re-enters the map-marker
    /// pipeline (NOT the chat path) and dedups by uid.
    ///
    /// Returns nil if the flag byte is not 0xFF (a dict-compressed body we
    /// cannot decode without the GPL dictionary — caller should log + drop).
    static func decode(_ data: Data, receiveTime: Date = Date()) -> CoTEvent? {
        guard let flags = data.first else { return nil }
        guard flags == flagUncompressed else { return nil } // 0x00/0x01 = dict-compressed; unsupported by design
        var idx = 1 // 0-based offset past the flag byte; read helpers index via data.startIndex + idx

        var callsign = ""
        var latI: Int32 = 0
        var lonI: Int32 = 0
        var alt: Int32 = 0
        var uid = ""
        var cotType = ""
        var remarks: String?
        var markerBytes: Data?

        while idx < data.count {
            guard let tag = readTag(data, &idx) else { break }
            switch (tag.field, tag.wire) {
            case (3, 2):  callsign = readString(data, &idx) ?? callsign
            case (6, 5):  if let v = readFixed32(data, &idx) { latI = Int32(bitPattern: v) }
            case (7, 5):  if let v = readFixed32(data, &idx) { lonI = Int32(bitPattern: v) }
            case (8, 0):  if let v = readVarint(data, &idx) { alt = unzigzag32(v) }
            case (14, 2): uid = readString(data, &idx) ?? uid
            case (23, 2): cotType = readString(data, &idx) ?? cotType
            case (24, 2): remarks = readString(data, &idx)
            case (35, 2): markerBytes = readLengthDelimited(data, &idx)
            default:      if !skip(data, &idx, wire: tag.wire) { return nil }
            }
        }

        guard !uid.isEmpty else { return nil }

        var argb: Int?
        var iconset: String?
        if let mb = markerBytes {
            (argb, iconset) = decodeMarkerSubmessage(mb)
        }

        var detail = CoTDetail(
            callsign: callsign.isEmpty ? uid : callsign,
            team: nil, teamRole: nil, speed: nil, course: nil,
            remarks: remarks, battery: nil, device: "Meshtastic", platform: "Meshtastic"
        )
        detail.iconsetPath = iconset
        detail.argbColor = argb

        return CoTEvent(
            uid: uid,
            type: cotType.isEmpty ? "a-u-G" : cotType,
            time: receiveTime,
            point: CoTPoint(
                lat: Double(latI) / 1e7,
                lon: Double(lonI) / 1e7,
                hae: Double(alt),
                ce: 9999, le: 9999
            ),
            detail: detail
        )
    }

    private static func decodeMarkerSubmessage(_ data: Data) -> (argb: Int?, iconset: String?) {
        var idx = 0
        var argb: Int?
        var iconset: String?
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { break }
            switch (tag.field, tag.wire) {
            case (3, 5):  if let v = readFixed32(data, &idx) { argb = Int(Int32(bitPattern: v)) }
            case (8, 2):  iconset = readString(data, &idx)
            default:      if !skip(data, &idx, wire: tag.wire) { return (argb, iconset) }
            }
        }
        return (argb, iconset)
    }

    private static func detailWithoutRemarks(_ d: CoTDetail) -> CoTDetail {
        var copy = CoTDetail(
            callsign: d.callsign, team: d.team, teamRole: d.teamRole,
            speed: d.speed, course: d.course, remarks: nil,
            battery: d.battery, device: d.device, platform: d.platform
        )
        copy.iconsetPath = d.iconsetPath
        copy.argbColor = d.argbColor
        return copy
    }

    // MARK: - zigzag

    private static func zigzag32(_ v: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: (v << 1) ^ (v >> 31)))
    }
    private static func unzigzag32(_ v: UInt64) -> Int32 {
        let u = UInt32(truncatingIfNeeded: v)
        return Int32(bitPattern: (u >> 1) ^ (~(u & 1) &+ 1))
    }

    // MARK: - Wire helpers (independent clean-room implementation)

    private static func appendTag(_ data: inout Data, field: Int, wire: UInt8) {
        appendVarint(&data, UInt64(field) << 3 | UInt64(wire))
    }
    private static func appendVarint(_ data: inout Data, _ value: UInt64) {
        var v = value
        if v == 0 { data.append(0); return }
        while v > 0x7F { data.append(UInt8((v & 0x7F) | 0x80)); v >>= 7 }
        data.append(UInt8(v))
    }
    private static func appendVarintField(_ data: inout Data, field: Int, value: UInt64) {
        appendTag(&data, field: field, wire: 0); appendVarint(&data, value)
    }
    private static func appendFixed32(_ data: inout Data, _ value: UInt32) {
        for i in 0..<4 { data.append(UInt8((value >> (8 * i)) & 0xFF)) }
    }
    private static func appendBytes(_ data: inout Data, field: Int, value: Data) {
        appendTag(&data, field: field, wire: 2); appendVarint(&data, UInt64(value.count)); data.append(value)
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
    private static func readFixed32(_ data: Data, _ idx: inout Int) -> UInt32? {
        guard idx + 4 <= data.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(data[data.startIndex + idx + i]) << (8 * i) }
        idx += 4; return v
    }
    private static func readString(_ data: Data, _ idx: inout Int) -> String? {
        guard let d = readLengthDelimited(data, &idx) else { return nil }
        return String(data: d, encoding: .utf8)
    }
    private static func readLengthDelimited(_ data: Data, _ idx: inout Int) -> Data? {
        // Compared as UInt64 first: a varint above Int.max would trap in the
        // conversion, and these bytes come off the air.
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
