//
//  MeshtasticProtoDecoder.swift
//  OmniTAK Mobile
//
//  Decoders for the radio-to-phone messages the Meshtastic BLE and TCP clients
//  read: FromRadio, MyNodeInfo, NodeInfo, User, Position, DeviceMetrics,
//  MeshPacket and Data.
//
//  Field numbers and wire types are the ones in the published mesh.proto and
//  telemetry.proto, written out by hand (no generated code, no proto text).
//  Each client used to carry its own private copy of these decoders. The two
//  copies agreed with each other and not with mesh.proto, so the same NodeInfo
//  mistake was in both (#146). They live here so there is one copy to test.
//
//  Reading rules:
//   - Tags are varints. A field number above 15 takes a two-byte tag, and the
//     old single-byte reader lost its place on those (Position and FromRadio
//     both have them).
//   - A known field that arrives with the wrong wire type is skipped, not
//     reinterpreted as something else.
//   - A length that runs past the end of the buffer ends that message. What was
//     decoded before it is kept.
//   - A value that is missing stays nil. Nothing is defaulted to "now" or 0.
//
//  Layouts used here (field number, name, wire type):
//
//    FromRadio   1 id varint, 2 packet len, 3 my_info len, 4 node_info len,
//                7 config_complete_id varint, 8 rebooted varint. Everything
//                else (5 config, 10 channel, 13 metadata, 16 and up) is skipped.
//    MyNodeInfo  1 my_node_num varint
//    NodeInfo    1 num varint, 2 user len, 3 position len, 4 snr float32,
//                5 last_heard fixed32, 6 device_metrics len, 9 hops_away varint.
//                7 channel, 8 via_mqtt, 10 is_favorite, 11 is_ignored and
//                anything newer are skipped.
//    User        2 long_name len, 3 short_name len, 7 role varint
//    Position    1 latitude_i sfixed32, 2 longitude_i sfixed32, 3 altitude
//                int32 varint
//    DeviceMetrics  1 battery_level varint
//    MeshPacket  1 from fixed32, 2 to fixed32, 3 channel varint, 4 decoded len,
//                7 rx_time fixed32, 8 rx_snr float32, 9 hop_limit varint,
//                12 rx_rssi int32 varint. 5 encrypted, 6 id, 10 want_ack,
//                11 priority, 14 via_mqtt, 15 hop_start, 16 public_key and
//                anything newer are skipped.
//    Data        1 portnum varint, 2 payload len
//

import Foundation

enum MeshtasticProtoDecoder {

    // MARK: - Results

    /// The parts of a MeshPacket the app reads.
    struct MeshPacketFrame: Equatable {
        var from: UInt32 = 0
        var to: UInt32 = 0
        var channel: UInt32 = 0
        /// PortNum of the decoded Data. 0 when the packet is encrypted or has none.
        var portNum: Int = 0
        var payload = Data()
        /// When the radio received the packet. Nil when the field is absent or 0,
        /// which is what a radio with no clock sends.
        var rxTime: Date?
        var rxSnr: Float?
        var hopLimit: Int?
        var rxRssi: Int?
    }

    /// What a FromRadio frame carried. FromRadio holds one payload variant, so
    /// when a frame has more than one the last wins, as in any protobuf oneof.
    enum FromRadioPayload: Equatable {
        case myInfo(nodeNum: UInt32)
        case nodeInfo(MeshNode)
        case packet(MeshPacketFrame)
        case configComplete(id: UInt32)
        case rebooted
        /// A variant the app does not use (config, channel, metadata, ...), or a
        /// node_info that could not be decoded.
        case other(field: Int)
    }

    // MARK: - FromRadio

    /// Decode one FromRadio frame. Nil when it holds no payload variant.
    static func decodeFromRadio(_ data: Data) -> FromRadioPayload? {
        var reader = Reader(data)
        var result: FromRadioPayload?
        while let tag = reader.readTag() {
            switch (tag.field, tag.wire) {
            case (1, _): // id: sequence number, not a payload
                guard reader.skip(wire: tag.wire) else { return result }
            case (2, 2):
                guard let body = reader.readBytes() else { return result }
                result = .packet(decodeMeshPacket(body))
            case (3, 2):
                guard let body = reader.readBytes() else { return result }
                result = .myInfo(nodeNum: decodeMyNodeInfo(body))
            case (4, 2):
                guard let body = reader.readBytes() else { return result }
                result = decodeNodeInfo(body).map { .nodeInfo($0) } ?? .other(field: 4)
            case (7, 0):
                guard let value = reader.readVarint() else { return result }
                result = .configComplete(id: UInt32(truncatingIfNeeded: value))
            case (8, 0):
                guard reader.readVarint() != nil else { return result }
                result = .rebooted
            default:
                guard reader.skip(wire: tag.wire) else { return result }
                result = .other(field: tag.field)
            }
        }
        return result
    }

    // MARK: - MyNodeInfo

    /// `my_node_num`, or 0 when the message does not carry it.
    static func decodeMyNodeInfo(_ data: Data) -> UInt32 {
        var reader = Reader(data)
        var nodeNum: UInt32 = 0
        while let tag = reader.readTag() {
            switch (tag.field, tag.wire) {
            case (1, 0):
                guard let value = reader.readVarint() else { return nodeNum }
                nodeNum = UInt32(truncatingIfNeeded: value)
            default:
                guard reader.skip(wire: tag.wire) else { return nodeNum }
            }
        }
        return nodeNum
    }

    // MARK: - NodeInfo

    /// A node from the radio's node database. Nil when the message has no `num`.
    ///
    /// `last_heard` is left nil when it is missing or 0 (the firmware sends 0
    /// for a node it has no time for). It is never defaulted to "now".
    static func decodeNodeInfo(_ data: Data) -> MeshNode? {
        var reader = Reader(data)
        var nodeNum: UInt32 = 0
        var shortName = ""
        var longName = ""
        var role: Int?
        var position: MeshPosition?
        var snr: Double?
        var lastHeard: Date?
        var battery: Int?
        var hopsAway: Int?

        fields: while let tag = reader.readTag() {
            switch (tag.field, tag.wire) {
            case (1, 0): // num
                guard let value = reader.readVarint() else { break fields }
                nodeNum = UInt32(truncatingIfNeeded: value)
            case (2, 2): // user
                guard let body = reader.readBytes() else { break fields }
                let user = decodeUser(body)
                if !user.short.isEmpty { shortName = user.short }
                if !user.long.isEmpty { longName = user.long }
                if let userRole = user.role { role = userRole }
            case (3, 2): // position
                guard let body = reader.readBytes() else { break fields }
                position = decodePosition(body) ?? position
            case (4, 5): // snr, dB of the last packet heard from this node
                guard let bits = reader.readFixed32() else { break fields }
                snr = Double(Float(bitPattern: bits))
            case (5, 5): // last_heard, epoch seconds
                guard let seconds = reader.readFixed32() else { break fields }
                if seconds > 0 { lastHeard = Date(timeIntervalSince1970: TimeInterval(seconds)) }
            case (6, 2): // device_metrics
                guard let body = reader.readBytes() else { break fields }
                battery = decodeDeviceMetricsBattery(body) ?? battery
            case (9, 0): // hops_away, 0 is a direct neighbour
                guard let value = reader.readVarint() else { break fields }
                hopsAway = Int(UInt32(truncatingIfNeeded: value))
            default:
                guard reader.skip(wire: tag.wire) else { break fields }
            }
        }

        guard nodeNum != 0 else { return nil }
        return MeshNode(
            id: nodeNum,
            shortName: shortName.isEmpty ? String(format: "%04X", nodeNum & 0xFFFF) : shortName,
            longName: longName.isEmpty ? "Node \(String(format: "%08X", nodeNum))" : longName,
            position: position,
            lastHeard: lastHeard,
            snr: snr,
            hopDistance: hopsAway,
            batteryLevel: battery,
            role: role
        )
    }

    // MARK: - User

    /// long_name, short_name and role of a `User`. Empty strings and a nil role
    /// when the message does not carry them.
    static func decodeUser(_ data: Data) -> (short: String, long: String, role: Int?) {
        var reader = Reader(data)
        var shortName = ""
        var longName = ""
        var role: Int?
        fields: while let tag = reader.readTag() {
            switch (tag.field, tag.wire) {
            case (2, 2):
                guard let body = reader.readBytes() else { break fields }
                if let text = String(data: body, encoding: .utf8) { longName = text }
            case (3, 2):
                guard let body = reader.readBytes() else { break fields }
                if let text = String(data: body, encoding: .utf8) { shortName = text }
            case (7, 0): // role, Config.DeviceConfig.Role
                guard let value = reader.readVarint() else { break fields }
                role = Int(UInt32(truncatingIfNeeded: value))
            default:
                guard reader.skip(wire: tag.wire) else { break fields }
            }
        }
        return (shortName, longName, role)
    }

    // MARK: - DeviceMetrics

    /// `battery_level` of a `DeviceMetrics`, or nil when it is not there.
    /// 0 to 100 is a percentage; above 100 means external power.
    static func decodeDeviceMetricsBattery(_ data: Data) -> Int? {
        var reader = Reader(data)
        while let tag = reader.readTag() {
            switch (tag.field, tag.wire) {
            case (1, 0):
                guard let value = reader.readVarint() else { return nil }
                return Int(UInt32(truncatingIfNeeded: value))
            default:
                guard reader.skip(wire: tag.wire) else { return nil }
            }
        }
        return nil
    }

    // MARK: - Position

    /// A position, or nil when the message does not carry both coordinates or
    /// they are exactly 0, 0 (a node with no fix).
    ///
    /// Coordinates are sfixed32 in degrees times 1e7. Altitude is an int32, so a
    /// negative value arrives as a 10-byte sign-extended varint.
    static func decodePosition(_ data: Data) -> MeshPosition? {
        var reader = Reader(data)
        var latitudeI: Int32?
        var longitudeI: Int32?
        var altitude: Int?
        fields: while let tag = reader.readTag() {
            switch (tag.field, tag.wire) {
            case (1, 5):
                guard let bits = reader.readFixed32() else { break fields }
                latitudeI = Int32(bitPattern: bits)
            case (2, 5):
                guard let bits = reader.readFixed32() else { break fields }
                longitudeI = Int32(bitPattern: bits)
            case (3, 0):
                guard let value = reader.readVarint() else { break fields }
                altitude = Int(Int32(truncatingIfNeeded: value))
            default:
                guard reader.skip(wire: tag.wire) else { break fields }
            }
        }

        guard let latitudeI, let longitudeI else { return nil }
        if latitudeI == 0 && longitudeI == 0 { return nil }
        return MeshPosition(
            latitude: Double(latitudeI) / 1e7,
            longitude: Double(longitudeI) / 1e7,
            altitude: altitude
        )
    }

    // MARK: - MeshPacket

    static func decodeMeshPacket(_ data: Data) -> MeshPacketFrame {
        var reader = Reader(data)
        var packet = MeshPacketFrame()
        fields: while let tag = reader.readTag() {
            switch (tag.field, tag.wire) {
            case (1, 5):
                guard let value = reader.readFixed32() else { break fields }
                packet.from = value
            case (2, 5):
                guard let value = reader.readFixed32() else { break fields }
                packet.to = value
            case (3, 0):
                guard let value = reader.readVarint() else { break fields }
                packet.channel = UInt32(truncatingIfNeeded: value)
            case (4, 2): // decoded
                guard let body = reader.readBytes() else { break fields }
                let decoded = decodeData(body)
                packet.portNum = decoded.portNum
                packet.payload = decoded.payload
            case (7, 5): // rx_time
                guard let seconds = reader.readFixed32() else { break fields }
                packet.rxTime = seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
            case (8, 5): // rx_snr
                guard let bits = reader.readFixed32() else { break fields }
                packet.rxSnr = Float(bitPattern: bits)
            case (9, 0): // hop_limit
                guard let value = reader.readVarint() else { break fields }
                packet.hopLimit = Int(UInt32(truncatingIfNeeded: value))
            case (12, 0): // rx_rssi, int32
                guard let value = reader.readVarint() else { break fields }
                packet.rxRssi = Int(Int32(truncatingIfNeeded: value))
            default:
                guard reader.skip(wire: tag.wire) else { break fields }
            }
        }
        return packet
    }

    // MARK: - Data

    /// portnum and payload of a MeshPacket's `decoded` Data.
    static func decodeData(_ data: Data) -> (portNum: Int, payload: Data) {
        var reader = Reader(data)
        var portNum = 0
        var payload = Data()
        fields: while let tag = reader.readTag() {
            switch (tag.field, tag.wire) {
            case (1, 0):
                guard let value = reader.readVarint() else { break fields }
                portNum = Int(UInt32(truncatingIfNeeded: value))
            case (2, 2):
                guard let body = reader.readBytes() else { break fields }
                payload = body
            default:
                guard reader.skip(wire: tag.wire) else { break fields }
            }
        }
        return (portNum, payload)
    }

    // MARK: - Wire reader

    /// Protobuf wire reader over one message. Every read is bounds-checked and a
    /// failed read leaves the cursor where it was, so a malformed message stops
    /// the loop that is reading it rather than trapping.
    private struct Reader {
        private let data: Data
        private var idx = 0

        init(_ data: Data) {
            // Index from 0 even when handed a slice of a larger buffer.
            self.data = data.startIndex == 0 ? data : Data(data)
        }

        /// The next field number and wire type, or nil at the end of the message
        /// or on a tag that is not valid (a zero field number, a varint that
        /// runs past ten bytes).
        mutating func readTag() -> (field: Int, wire: Int)? {
            guard let value = readVarint() else { return nil }
            let field = Int(value >> 3)
            guard field > 0 else { return nil }
            return (field, Int(value & 0x07))
        }

        mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            var cursor = idx
            while cursor < data.count {
                let byte = data[cursor]
                cursor += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 {
                    idx = cursor
                    return result
                }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }

        mutating func readFixed32() -> UInt32? {
            guard data.count - idx >= 4 else { return nil }
            let value = UInt32(data[idx])
                | UInt32(data[idx + 1]) << 8
                | UInt32(data[idx + 2]) << 16
                | UInt32(data[idx + 3]) << 24
            idx += 4
            return value
        }

        /// A length-delimited field's bytes. Nil when the declared length is
        /// more than what is left.
        mutating func readBytes() -> Data? {
            guard let length = readLength() else { return nil }
            let slice = data.subdata(in: idx..<(idx + length))
            idx += length
            return slice
        }

        /// Step over a field of the given wire type. False when it is malformed
        /// or the wire type is not one this reader knows (groups, 6, 7).
        mutating func skip(wire: Int) -> Bool {
            switch wire {
            case 0:
                return readVarint() != nil
            case 1:
                guard data.count - idx >= 8 else { return false }
                idx += 8
                return true
            case 2:
                guard let length = readLength() else { return false }
                idx += length
                return true
            case 5:
                return readFixed32() != nil
            default:
                return false
            }
        }

        /// Read a length varint and check the value that follows it fits in
        /// what is left. The comparison is done as UInt64, so a huge length
        /// cannot trap in a conversion to Int. On success the cursor is at the
        /// start of the value; on failure it is back where it was.
        private mutating func readLength() -> Int? {
            let start = idx
            guard let length = readVarint(), length <= UInt64(data.count - idx) else {
                idx = start
                return nil
            }
            return Int(length)
        }
    }
}
