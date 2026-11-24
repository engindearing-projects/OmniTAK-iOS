//
//  MumbleWire.swift
//  OmniTAKMobile
//
//  Minimal hand-rolled wire helpers for the Mumble control protocol: a tiny
//  protobuf encoder/decoder (only varint, length-delimited and fixed64 — all
//  the field kinds the handful of messages we use need) plus Mumble's own
//  varint used inside voice packets. Hand-rolled to avoid adding a protobuf
//  package dependency for ~10 small messages.
//

import Foundation

// MARK: - Protobuf encoding

struct MumbleProtoWriter {
    private(set) var data = Data()

    private mutating func rawVarint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7F) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
    private mutating func key(_ field: Int, _ wire: Int) { rawVarint(UInt64(field << 3 | wire)) }

    mutating func uint(_ field: Int, _ v: UInt64) { key(field, 0); rawVarint(v) }
    mutating func uint32(_ field: Int, _ v: UInt32) { uint(field, UInt64(v)) }
    mutating func bool(_ field: Int, _ v: Bool) { uint(field, v ? 1 : 0) }
    mutating func bytes(_ field: Int, _ v: Data) { key(field, 2); rawVarint(UInt64(v.count)); data.append(v) }
    mutating func string(_ field: Int, _ v: String) { bytes(field, Data(v.utf8)) }
}

// MARK: - Protobuf decoding

/// Decoded protobuf fields: field number -> values in order of appearance.
struct MumbleProtoFields {
    enum Value { case varint(UInt64), bytes(Data), fixed64(UInt64), fixed32(UInt32) }
    private(set) var values: [Int: [Value]] = [:]

    init?(_ data: Data) {
        var i = data.startIndex
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < data.endIndex {
                let b = data[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < data.endIndex {
            guard let k = varint() else { return nil }
            let field = Int(k >> 3)
            switch k & 7 {
            case 0:
                guard let v = varint() else { return nil }
                values[field, default: []].append(.varint(v))
            case 1:
                guard data.endIndex - i >= 8 else { return nil }
                var v: UInt64 = 0
                for n in 0..<8 { v |= UInt64(data[i + n]) << (8 * UInt64(n)) }
                i += 8; values[field, default: []].append(.fixed64(v))
            case 2:
                guard let len = varint(), data.endIndex - i >= Int(len) else { return nil }
                values[field, default: []].append(.bytes(data.subdata(in: i..<i + Int(len))))
                i += Int(len)
            case 5:
                guard data.endIndex - i >= 4 else { return nil }
                var v: UInt32 = 0
                for n in 0..<4 { v |= UInt32(data[i + n]) << (8 * UInt32(n)) }
                i += 4; values[field, default: []].append(.fixed32(v))
            default:
                return nil
            }
        }
    }

    func uint(_ field: Int) -> UInt64? {
        if case .varint(let v)? = values[field]?.last { return v }
        return nil
    }
    func uint32(_ field: Int) -> UInt32? { uint(field).map { UInt32(truncatingIfNeeded: $0) } }
    func bool(_ field: Int) -> Bool? { uint(field).map { $0 != 0 } }
    func bytes(_ field: Int) -> Data? {
        if case .bytes(let d)? = values[field]?.last { return d }
        return nil
    }
    func string(_ field: Int) -> String? { bytes(field).flatMap { String(data: $0, encoding: .utf8) } }
    func has(_ field: Int) -> Bool { values[field] != nil }
}

// MARK: - Mumble varint (used inside legacy voice packets)

enum MumbleVarint {
    static func encode(_ value: UInt64) -> Data {
        let v = value
        if v < 0x80 { return Data([UInt8(v)]) }
        if v < 0x4000 { return Data([UInt8(0x80 | (v >> 8)), UInt8(v & 0xFF)]) }
        if v < 0x20_0000 { return Data([UInt8(0xC0 | (v >> 16)), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
        if v < 0x1000_0000 {
            return Data([UInt8(0xE0 | (v >> 24)), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }
        if v <= 0xFFFF_FFFF {
            return Data([0xF0, UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }
        var d = Data([0xF4])
        for s in stride(from: 56, through: 0, by: -8) { d.append(UInt8((v >> UInt64(s)) & 0xFF)) }
        return d
    }

    /// Decode at `index`, advancing it. Returns nil on truncation.
    static func decode(_ d: Data, _ index: inout Int) -> UInt64? {
        func byte() -> UInt64? {
            guard index < d.endIndex else { return nil }
            defer { index += 1 }
            return UInt64(d[index])
        }
        guard let b0 = byte() else { return nil }
        if b0 & 0x80 == 0 { return b0 }
        if b0 & 0xC0 == 0x80 { guard let b1 = byte() else { return nil }; return (b0 & 0x3F) << 8 | b1 }
        if b0 & 0xE0 == 0xC0 {
            guard let b1 = byte(), let b2 = byte() else { return nil }
            return (b0 & 0x1F) << 16 | b1 << 8 | b2
        }
        if b0 & 0xF0 == 0xE0 {
            guard let b1 = byte(), let b2 = byte(), let b3 = byte() else { return nil }
            return (b0 & 0x0F) << 24 | b1 << 16 | b2 << 8 | b3
        }
        switch b0 & 0xFC {
        case 0xF0:
            var v: UInt64 = 0
            for _ in 0..<4 { guard let b = byte() else { return nil }; v = v << 8 | b }
            return v
        case 0xF4:
            var v: UInt64 = 0
            for _ in 0..<8 { guard let b = byte() else { return nil }; v = v << 8 | b }
            return v
        case 0xF8:
            guard let inner = decode(d, &index) else { return nil }
            return ~inner
        case 0xFC:
            return ~(b0 & 0x03)
        default:
            return nil
        }
    }
}

// MARK: - Legacy voice packet (UDPTunnel payload)

/// Mumble's legacy voice packet, as carried in UDPTunnel (type 1):
///   header byte (codec << 5 | target), [session varint — server→client only],
///   sequence varint, length varint (bit 0x2000 = terminator), Opus bytes.
enum MumbleVoicePacket {
    static let opusCodec: UInt8 = 4

    /// Client → server packet (no session field).
    static func encode(sequence: UInt64, opus: Data, terminator: Bool, target: UInt8 = 0) -> Data {
        var p = Data([opusCodec << 5 | (target & 0x1F)])
        p.append(MumbleVarint.encode(sequence))
        var len = UInt64(opus.count & 0x1FFF)
        if terminator { len |= 0x2000 }
        p.append(MumbleVarint.encode(len))
        p.append(opus)
        return p
    }

    struct Inbound: Equatable {
        let session: UInt32
        let sequence: UInt64
        let opus: Data
        let terminator: Bool
    }

    /// Server → client packet. Nil for non-Opus or malformed packets.
    /// Trailing positional audio data, if any, is ignored.
    static func decode(_ p: Data) -> Inbound? {
        guard let header = p.first, header >> 5 == opusCodec else { return nil }
        var i = p.startIndex + 1
        guard let session = MumbleVarint.decode(p, &i),
              let seq = MumbleVarint.decode(p, &i),
              let lenField = MumbleVarint.decode(p, &i) else { return nil }
        let len = Int(lenField & 0x1FFF)
        guard p.endIndex - i >= len else { return nil }
        return Inbound(session: UInt32(truncatingIfNeeded: session), sequence: seq,
                       opus: p.subdata(in: i ..< i + len), terminator: lenField & 0x2000 != 0)
    }
}
