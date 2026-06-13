//
//  MeshCoreFrameCodec.swift
//  OmniTAK Mobile
//
//  Encodes/decodes the MeshCore *companion* BLE protocol — the same wire format
//  the upstream MeshCore companion apps and the TAK-MeshCore ATAK plugin speak.
//  Each BLE write to the Nordic-UART RX characteristic is one command frame
//  (first byte = command code); each TX notification is one response frame
//  (first byte = response code). There is no extra length prefix at this layer
//  — the GATT characteristic value IS the frame.
//
//  Reference: MeshCore-1.4.8 ATAK plugin, BtConnectionManager.java
//  (command/response codes, byte layouts, little-endian multibyte fields).
//

import Foundation

// MARK: - Decoded Records

/// A MeshCore contact / advert decoded from the radio: another node's identity
/// and (optionally) its advertised position. Maps onto a CoT PLI.
struct MeshCoreContact: Equatable {
    /// Full public-key hex (lowercase, 64 chars for a 32-byte key).
    let pubKeyHex: String
    /// Advert type byte (0x01 = chat node, 0x02 = repeater, …).
    let advertType: Int
    let name: String
    /// Advert timestamp (epoch seconds), 0 if unknown.
    let advertTimestampSec: UInt32
    let latitude: Double
    let longitude: Double
    let hasPosition: Bool

    var isRepeater: Bool { advertType == MeshCoreFrameCodec.advTypeRepeater }

    /// True when the advertised position is a usable, non-null-island fix.
    var hasValidPosition: Bool {
        guard hasPosition, latitude.isFinite, longitude.isFinite else { return false }
        if latitude < -90 || latitude > 90 || longitude < -180 || longitude > 180 { return false }
        return !(abs(latitude) < 0.000001 && abs(longitude) < 0.000001)
    }
}

/// An inbound text message from another node (native pubkey-to-pubkey DM).
struct MeshCoreTextMessage: Equatable {
    /// Sender public-key prefix hex (first 6 bytes -> 12 hex chars), as the
    /// firmware reports it on a contact-message frame.
    let senderPubKeyPrefixHex: String
    let text: String
}

/// The radio's own identity + position from a SELF_INFO (APP_START reply) frame.
struct MeshCoreSelfInfo: Equatable {
    let pubKeyHex: String
    let name: String
    let latitude: Double
    let longitude: Double
    let hasPosition: Bool
}

/// Device info decoded from a RESP_DEVICE_INFO (0x0D) frame.
/// Layout per MeshCore-1.4.8: [0x0D][hwModel u8 @1][hwRevision u8 @2][fwVersion ascii @3…].
struct MeshCoreDeviceInfo: Equatable {
    /// Hardware model identifier byte.
    let hwModel: UInt8
    /// Hardware revision byte.
    let hwRevision: UInt8
    /// Firmware version string (null-terminated ASCII, may be empty).
    let firmwareVersion: String
}

/// One decoded response frame from the radio.
enum MeshCoreResponse: Equatable {
    case selfInfo(MeshCoreSelfInfo)
    case contact(MeshCoreContact)        // advert / contact (position-bearing)
    case textMessage(MeshCoreTextMessage)
    case battery(millivolts: Int, percent: Int)
    case deviceInfo(MeshCoreDeviceInfo)  // 0x0D — hardware / firmware identity
    case noMoreMessages
    case messagesWaiting
    case other(code: UInt8)              // recognized-but-unhandled / unknown
}

// MARK: - Codec

enum MeshCoreFrameCodec {

    // --- Companion command codes (RX, app -> radio) ---
    static let cmdAppStart: UInt8        = 0x01
    static let cmdSendTxtMsg: UInt8      = 0x02
    static let cmdSendChannelMsg: UInt8  = 0x03
    static let cmdSendSelfAdvert: UInt8  = 0x07
    static let cmdSetAdvertName: UInt8   = 0x08
    static let cmdGetNextMsg: UInt8      = 0x0A
    static let cmdSetAdvertLatLon: UInt8 = 0x0E
    static let cmdGetBattery: UInt8      = 0x14
    static let cmdDeviceQuery: UInt8     = 0x16
    static let cmdGetContactByKey: UInt8 = 0x1E
    static let cmdSendChannelData: UInt8 = 0x3E

    static let txtTypePlain: UInt8       = 0x00
    static let deviceQueryArg: UInt8     = 0x03

    /// App identifier sent in APP_START (matches the upstream companion app id).
    static let companionAppId = "meshcore-flutter"

    // --- Companion response codes (TX, radio -> app) ---
    static let respSelfInfo: UInt8       = 0x05
    static let respContactMsg: UInt8     = 0x07
    static let respContactMsgV3: UInt8   = 0x10
    static let respNoMoreMsgs: UInt8     = 0x0A
    static let respBattery: UInt8        = 0x0C
    static let respDeviceInfo: UInt8     = 0x0D   // RESP_DEVICE_INFO — 82 bytes on live radio
    static let respCodeContact: UInt8    = 0x03   // full contact record
    static let pushCodeAdvert: UInt8     = 0x80
    static let pushCodeNewAdvert: UInt8  = 0x8A
    static let pushMessagesWaiting: UInt8 = 0x83

    static let advTypeRepeater = 0x02

    // Battery model (matches firmware meshBatteryMvToPercent).
    static let batteryMinMv = 3300
    static let batteryMaxMv = 4200

    // MARK: - Encoders

    /// APP_START — first command after the link is up; the radio replies with
    /// SELF_INFO. Layout: [0x01][7 reserved 0x00][appId ascii].
    static func encodeAppStart(appId: String = companionAppId) -> Data {
        var out = Data([cmdAppStart])
        out.append(contentsOf: [UInt8](repeating: 0, count: 7))
        out.append(Data(appId.utf8))
        return out
    }

    /// DEVICE_QUERY — [0x16][0x03].
    static func encodeDeviceQuery() -> Data {
        Data([cmdDeviceQuery, deviceQueryArg])
    }

    /// GET_NEXT_MSG — drain one queued frame from the radio.
    static func encodeGetNextMessage() -> Data { Data([cmdGetNextMsg]) }

    /// GET_BATTERY — request a battery reading.
    static func encodeGetBattery() -> Data { Data([cmdGetBattery]) }

    /// SEND_SELF_ADVERT — broadcast this node's advert (identity + position if
    /// the radio is configured to share it).
    static func encodeSendSelfAdvert() -> Data { Data([cmdSendSelfAdvert]) }

    /// SET_ADVERT_LATLON — set the position the radio will share in its advert.
    /// Layout: [0x0E][latE6 i32 LE][lonE6 i32 LE][altMeters i32 LE] (13 bytes).
    /// Returns nil for an out-of-range coordinate.
    static func encodeSetAdvertLatLon(latitude: Double,
                                      longitude: Double,
                                      altitudeMeters: Double = 0) -> Data? {
        guard latitude.isFinite, longitude.isFinite,
              latitude >= -90, latitude <= 90,
              longitude >= -180, longitude <= 180 else { return nil }
        let latE6 = Int32((latitude * 1_000_000).rounded())
        let lonE6 = Int32((longitude * 1_000_000).rounded())
        let alt = altitudeMeters.isFinite ? Int32(altitudeMeters.rounded()) : 0
        var out = Data([cmdSetAdvertLatLon])
        out.appendInt32LE(latE6)
        out.appendInt32LE(lonE6)
        out.appendInt32LE(alt)
        return out
    }

    /// SET_ADVERT_NAME — set this node's advertised name (≤31 bytes UTF-8).
    static func encodeSetAdvertName(_ name: String) -> Data? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var bytes = Array(trimmed.utf8)
        if bytes.count > 31 { bytes = Array(bytes.prefix(31)) }
        return Data([cmdSetAdvertName]) + Data(bytes)
    }

    /// SEND_TXT_MSG — a native pubkey-to-pubkey direct message. Layout:
    /// [0x02][txtType=0x00][attempt=0x00][timestamp u32 LE][pubkeyPrefix 6][msg].
    /// `pubKeyHex` must be >= 12 hex chars (first 6 bytes are the prefix).
    /// Returns nil on bad pubkey / empty text.
    static func encodeSendTextMessage(pubKeyHex: String,
                                      text: String,
                                      timestamp: Date = Date()) -> Data? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let prefix = pubKeyPrefixBytes(pubKeyHex, count: 6) else {
            return nil
        }
        var out = Data([cmdSendTxtMsg, txtTypePlain, 0x00])
        out.appendUInt32LE(UInt32(truncatingIfNeeded: Int(timestamp.timeIntervalSince1970)))
        out.append(prefix)
        out.append(Data(trimmed.utf8))
        return out
    }

    /// GET_CONTACT_BY_KEY — request the full contact record for a 32-byte
    /// pubkey (taken from an advert frame's bytes 1..32). Returns nil if the
    /// advert frame is too short.
    static func encodeGetContactByKey(advertFrame: Data) -> Data? {
        guard advertFrame.count >= 33 else { return nil }
        var out = Data([cmdGetContactByKey])
        out.append(advertFrame.subdata(in: 1..<33))
        return out
    }

    // MARK: - Decoder

    /// Decode one response frame (the raw GATT TX characteristic value).
    static func decode(_ frame: Data) -> MeshCoreResponse? {
        guard let code = frame.first else { return nil }
        switch code {
        case respSelfInfo:
            if let info = decodeSelfInfo(frame) { return .selfInfo(info) }
            return .other(code: code)
        case pushMessagesWaiting:
            return .messagesWaiting
        case respNoMoreMsgs:
            return .noMoreMessages
        case respBattery:
            if let (mv, pct) = decodeBattery(frame) { return .battery(millivolts: mv, percent: pct) }
            return .other(code: code)
        case respDeviceInfo:
            if let info = decodeDeviceInfo(frame) { return .deviceInfo(info) }
            return .other(code: code)
        case respContactMsg, respContactMsgV3:
            if let msg = decodeTextMessage(frame, v3: code == respContactMsgV3) {
                return .textMessage(msg)
            }
            return .other(code: code)
        case pushCodeAdvert, pushCodeNewAdvert, respCodeContact:
            if let contact = decodeContact(frame) { return .contact(contact) }
            return .other(code: code)
        default:
            return .other(code: code)
        }
    }

    /// Parse an advert / contact frame into a `MeshCoreContact`.
    /// Layout (companion firmware): [code][pubkey 32 @1][advType @33]
    /// [name 32 @100][tsSec u32 @132][latE6 i32 @136][lonE6 i32 @140].
    static func decodeContact(_ frame: Data) -> MeshCoreContact? {
        guard frame.count >= 144 else { return nil }
        let pubKeyHex = frame.hexString(from: 1, count: 32)
        guard !pubKeyHex.isEmpty else { return nil }
        let advType = Int(frame[frame.startIndex + 33])
        var name = frame.cString(from: 100, maxLen: 32)
        if name.isEmpty { name = "MeshCore Node" }
        let tsSec = frame.uint32LE(at: 132) ?? 0
        let latE6 = frame.int32LE(at: 136) ?? 0
        let lonE6 = frame.int32LE(at: 140) ?? 0
        let hasPosition = !(latE6 == 0 && lonE6 == 0)
        return MeshCoreContact(
            pubKeyHex: pubKeyHex,
            advertType: advType,
            name: name,
            advertTimestampSec: tsSec,
            latitude: Double(latE6) / 1_000_000.0,
            longitude: Double(lonE6) / 1_000_000.0,
            hasPosition: hasPosition
        )
    }

    /// Parse a SELF_INFO frame (APP_START reply).
    /// Layout: [0x05][advType @1][txPower @2][maxTx @3][pubkey 32 @4]
    /// [latE6 i32 @36][lonE6 i32 @40] … [name @58+].
    static func decodeSelfInfo(_ frame: Data) -> MeshCoreSelfInfo? {
        guard frame.count >= 44 else { return nil }
        let pubKeyHex = frame.hexString(from: 4, count: 32)
        let latE6 = frame.int32LE(at: 36) ?? 0
        let lonE6 = frame.int32LE(at: 40) ?? 0
        var name = ""
        if frame.count > 58 {
            name = frame.cString(from: 58, maxLen: frame.count - 58)
        }
        let lat = Double(latE6) / 1_000_000.0
        let lon = Double(lonE6) / 1_000_000.0
        let hasPosition = !(latE6 == 0 && lonE6 == 0)
        return MeshCoreSelfInfo(
            pubKeyHex: pubKeyHex,
            name: name,
            latitude: lat,
            longitude: lon,
            hasPosition: hasPosition
        )
    }

    /// Parse a contact-message (native DM) frame.
    /// v1: [0x07][senderPrefix 6 @1][...][txtType @8][text @13 (+4 if txtType==2)].
    /// v3: [0x10][...][senderPrefix 6 @4][txtType @11][text @16 (+4 if txtType==2)].
    static func decodeTextMessage(_ frame: Data, v3: Bool) -> MeshCoreTextMessage? {
        let prefixOff = v3 ? 4 : 1
        let txtTypeIdx = v3 ? 11 : 8
        var textOff = v3 ? 16 : 13
        guard frame.count >= prefixOff + 6, frame.count > txtTypeIdx else { return nil }
        let senderPrefixHex = frame.hexString(from: prefixOff, count: 6)
        let txtType = frame[frame.startIndex + txtTypeIdx]
        if txtType == 2 { textOff += 4 } // signed/timestamped variant carries 4 extra bytes
        guard frame.count > textOff else { return nil }
        let textData = frame.subdata(in: (frame.startIndex + textOff)..<frame.endIndex)
        let text = String(data: textData, encoding: .utf8) ?? ""
        return MeshCoreTextMessage(senderPubKeyPrefixHex: senderPrefixHex, text: text)
    }

    /// Parse a battery frame: [0x0C][mv low][mv high]. Returns (mv, percent).
    static func decodeBattery(_ frame: Data) -> (Int, Int)? {
        guard frame.count >= 3 else { return nil }
        let lo = Int(frame[frame.startIndex + 1])
        let hi = Int(frame[frame.startIndex + 2])
        let mv = lo | (hi << 8)
        return (mv, batteryPercent(fromMillivolts: mv))
    }

    /// Parse a RESP_DEVICE_INFO (0x0D) frame.
    /// Layout: [0x0D][hwModel u8 @1][hwRevision u8 @2][fwVersion ascii @3…].
    /// The live radio sends an 82-byte frame; anything ≥ 3 bytes is accepted
    /// (the version string can be empty on minimal builds).
    static func decodeDeviceInfo(_ frame: Data) -> MeshCoreDeviceInfo? {
        guard frame.count >= 3 else { return nil }
        let hwModel    = frame[frame.startIndex + 1]
        let hwRevision = frame[frame.startIndex + 2]
        let fwVersion  = frame.count > 3
            ? frame.cString(from: 3, maxLen: frame.count - 3)
            : ""
        return MeshCoreDeviceInfo(hwModel: hwModel, hwRevision: hwRevision, firmwareVersion: fwVersion)
    }

    static func batteryPercent(fromMillivolts mv: Int) -> Int {
        if mv <= 0 { return -1 }
        if mv <= batteryMinMv { return 0 }
        if mv >= batteryMaxMv { return 100 }
        return Int((100.0 * Double(mv - batteryMinMv) / Double(batteryMaxMv - batteryMinMv)).rounded())
    }

    // MARK: - Helpers

    /// First `count` bytes of a hex pubkey as raw bytes; nil if too short/invalid.
    static func pubKeyPrefixBytes(_ pubKeyHex: String, count: Int) -> Data? {
        let hex = pubKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count >= count * 2 else { return nil }
        var out = Data(capacity: count)
        var idx = hex.startIndex
        for _ in 0..<count {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        return out
    }

    /// Derive a stable 32-bit node id from the first 6 bytes of a pubkey hex.
    /// We fold the 6 bytes into a UInt32 by XOR-ing bytes 4 and 5 into the high
    /// and mid positions so the full 48-bit prefix contributes to the id; this
    /// matches the Android companion's key-contact behaviour (6-byte prefix).
    /// 0 if the pubkey is invalid or too short.
    static func nodeId(fromPubKeyHex pubKeyHex: String) -> UInt32 {
        guard let bytes = pubKeyPrefixBytes(pubKeyHex, count: 6) else { return 0 }
        // Incorporate all 6 bytes: use first 4 as base, mix bytes 4+5 in.
        let base = bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let mix  = UInt32(bytes[4]) ^ (UInt32(bytes[5]) << 16)
        return base ^ mix
    }

    /// Stable 12-hex-char public-key prefix (6 bytes) used for MESHCORE UIDs
    /// and self-node deduplication. Returns nil if pubKeyHex is too short.
    static func pubKeyPrefix12(fromPubKeyHex pubKeyHex: String) -> String? {
        let hex = pubKeyHex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count >= 12 else { return nil }
        return String(hex.prefix(12)).lowercased()
    }
}

// MARK: - Data byte helpers (little-endian, offset-safe)

extension Data {
    fileprivate mutating func appendInt32LE(_ value: Int32) {
        appendUInt32LE(UInt32(bitPattern: value))
    }

    fileprivate mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    /// Read a little-endian UInt32 at logical offset `off` (0-based from the
    /// start of this Data slice). Nil if out of range.
    func uint32LE(at off: Int) -> UInt32? {
        guard off >= 0, count >= off + 4 else { return nil }
        let b = startIndex + off
        return UInt32(self[b])
            | (UInt32(self[b + 1]) << 8)
            | (UInt32(self[b + 2]) << 16)
            | (UInt32(self[b + 3]) << 24)
    }

    /// Read a little-endian Int32 at logical offset `off`.
    func int32LE(at off: Int) -> Int32? {
        guard let u = uint32LE(at: off) else { return nil }
        return Int32(bitPattern: u)
    }

    /// Lowercase hex of `count` bytes starting at logical offset `off`.
    /// Empty string if out of range.
    func hexString(from off: Int, count n: Int) -> String {
        guard off >= 0, n > 0, count >= off + n else { return "" }
        let b = startIndex + off
        var s = ""
        s.reserveCapacity(n * 2)
        for i in 0..<n {
            s += String(format: "%02x", self[b + i])
        }
        return s
    }

    /// Decode a null-terminated / null-padded UTF-8 C string of up to `maxLen`
    /// bytes starting at logical offset `off`. Trimmed of surrounding whitespace.
    func cString(from off: Int, maxLen: Int) -> String {
        guard off >= 0, maxLen > 0, count > off else { return "" }
        let b = startIndex + off
        let end = Swift.min(endIndex, b + maxLen)
        var n = b
        while n < end && self[n] != 0 { n += 1 }
        let raw = subdata(in: b..<n)
        return (String(data: raw, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
