//
//  ATAKPluginSerializer.swift
//  OmniTAKMobile
//
//  Serializes a CoTEvent into a Meshtastic portnum-72 (ATAK_PLUGIN) payload.
//
//  Inverse of `ATAKPluginParser`. Produces a TAK-protobuf TAKMessage with a
//  CoTEvent submessage populated from the OmniTAK CoTEvent model. Like the
//  parser, this hand-rolls the wire format to avoid pulling in
//  swift-protobuf and to stay consistent with the existing manual encoders
//  in `MeshtasticTCPClient` / `MeshtasticBLEClient`.
//

import Foundation

enum ATAKPluginSerializer {

    /// Serialize a CoTEvent into the bytes of a TAKMessage protobuf, suitable
    /// for use as the payload of a Meshtastic Data message at portnum 72.
    static func serialize(
        _ event: CoTEvent,
        how: String = "m-g",
        sendTime: Date = Date(),
        startTime: Date? = nil,
        staleTime: Date? = nil
    ) -> Data {
        let cotEvent = encodeCoTEvent(
            event,
            how: how,
            sendTime: sendTime,
            startTime: startTime ?? sendTime,
            staleTime: staleTime ?? sendTime.addingTimeInterval(60)
        )

        // Wrap in TAKMessage (field 2 = cotEvent, wire type 2).
        var out = Data()
        appendTag(&out, field: 2, wire: 2)
        appendVarint(&out, UInt64(cotEvent.count))
        out.append(cotEvent)
        return out
    }

    // MARK: - CoTEvent submessage

    private static func encodeCoTEvent(
        _ event: CoTEvent,
        how: String,
        sendTime: Date,
        startTime: Date,
        staleTime: Date
    ) -> Data {
        var out = Data()

        // 1: type (string)
        appendString(&out, field: 1, value: event.type)

        // 5: uid (string)
        appendString(&out, field: 5, value: event.uid)

        // 6: sendTime (uint64 ms)
        appendVarintField(&out, field: 6, value: millis(sendTime))

        // 7: startTime
        appendVarintField(&out, field: 7, value: millis(startTime))

        // 8: staleTime
        appendVarintField(&out, field: 8, value: millis(staleTime))

        // 9: how
        appendString(&out, field: 9, value: how)

        // 10..14: doubles via fixed64 bit pattern
        appendDouble(&out, field: 10, value: event.point.lat)
        appendDouble(&out, field: 11, value: event.point.lon)
        appendDouble(&out, field: 12, value: event.point.hae)
        appendDouble(&out, field: 13, value: event.point.ce)
        appendDouble(&out, field: 14, value: event.point.le)

        // 15: detail
        let detailBytes = encodeDetail(event.detail)
        if !detailBytes.isEmpty {
            appendTag(&out, field: 15, wire: 2)
            appendVarint(&out, UInt64(detailBytes.count))
            out.append(detailBytes)
        }

        return out
    }

    // MARK: - Detail submessage

    private static func encodeDetail(_ detail: CoTDetail) -> Data {
        var out = Data()

        // 6: contact (callsign + endpoint)
        if !detail.callsign.isEmpty {
            var contact = Data()
            appendString(&contact, field: 1, value: detail.callsign)
            appendTag(&out, field: 6, wire: 2)
            appendVarint(&out, UInt64(contact.count))
            out.append(contact)
        }

        // 2: group (name)
        if let team = detail.team, !team.isEmpty {
            var group = Data()
            appendString(&group, field: 1, value: team)
            appendTag(&out, field: 2, wire: 2)
            appendVarint(&out, UInt64(group.count))
            out.append(group)
        }

        // 4: status (battery)
        if let battery = detail.battery {
            var status = Data()
            appendVarintField(&status, field: 1, value: UInt64(max(0, battery)))
            appendTag(&out, field: 4, wire: 2)
            appendVarint(&out, UInt64(status.count))
            out.append(status)
        }

        // 5: takv (device, platform)
        if detail.device != nil || detail.platform != nil {
            var takv = Data()
            if let device = detail.device { appendString(&takv, field: 1, value: device) }
            if let platform = detail.platform { appendString(&takv, field: 2, value: platform) }
            appendTag(&out, field: 5, wire: 2)
            appendVarint(&out, UInt64(takv.count))
            out.append(takv)
        }

        // 7: track (speed, course)
        if detail.speed != nil || detail.course != nil {
            var track = Data()
            if let speed = detail.speed {
                appendTag(&track, field: 1, wire: 1)
                appendFixed64(&track, value: speed.bitPattern)
            }
            if let course = detail.course {
                appendTag(&track, field: 2, wire: 1)
                appendFixed64(&track, value: course.bitPattern)
            }
            appendTag(&out, field: 7, wire: 2)
            appendVarint(&out, UInt64(track.count))
            out.append(track)
        }

        // 1: xmlDetail (free-form) — stash remarks here so parsers that ignore
        // structured submessages still see them.
        if let remarks = detail.remarks, !remarks.isEmpty {
            let xml = "<remarks>\(escape(remarks))</remarks>"
            appendString(&out, field: 1, value: xml)
        }

        return out
    }

    // MARK: - Wire helpers

    private static func appendTag(_ data: inout Data, field: Int, wire: UInt8) {
        appendVarint(&data, UInt64(field) << 3 | UInt64(wire))
    }

    private static func appendVarint(_ data: inout Data, _ value: UInt64) {
        var v = value
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

    private static func appendFixed64(_ data: inout Data, value: UInt64) {
        for i in 0..<8 {
            data.append(UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    private static func appendFixed32(_ data: inout Data, value: UInt32) {
        for i in 0..<4 {
            data.append(UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    private static func appendDouble(_ data: inout Data, field: Int, value: Double) {
        appendTag(&data, field: field, wire: 1)
        appendFixed64(&data, value: value.bitPattern)
    }

    private static func appendString(_ data: inout Data, field: Int, value: String) {
        let bytes = Data(value.utf8)
        appendTag(&data, field: field, wire: 2)
        appendVarint(&data, UInt64(bytes.count))
        data.append(bytes)
    }

    // MARK: - MeshPacket / ToRadio (for TX path)

    /// Build a Meshtastic ToRadio bytes blob with a MeshPacket carrying an
    /// ATAK payload. Caller is responsible for any TCP framing.
    ///
    /// - Parameters:
    ///   - portnum: Meshtastic PortNum for the Data submessage. Defaults to 72
    ///     (ATAK_PLUGIN, TAKPacket v1). Pass 78 for TAKPacketV2 markers.
    ///   - hopLimit: LoRa hop_limit (MeshPacket field 9). Defaults to 3.
    ///   - wantAck: whether to request a delivery ACK. Defaults to false —
    ///     broadcast marker/chat traffic doesn't ACK (an ACK on a broadcast
    ///     just adds airtime). Unicast callers can opt in.
    ///   - wantResponse: Data.want_response (field 3). An admin request such as
    ///     get_channel_request is only answered when this is set. Defaults to
    ///     false, which adds no bytes.
    static func buildToRadio(
        atakPayload: Data,
        to destination: UInt32 = 0xFFFFFFFF,
        channel: UInt32 = 0,
        portnum: UInt64 = 72,
        hopLimit: UInt32 = 3,
        wantAck: Bool = false,
        wantResponse: Bool = false,
        packetID: UInt32 = UInt32.random(in: 1...UInt32.max)
    ) -> Data {
        // Data submessage.
        var decoded = Data()
        // 1: portnum (ATAK_PLUGIN = 72, ATAK_PLUGIN_V2 / TAKPacketV2 = 78)
        appendVarintField(&decoded, field: 1, value: portnum)
        // 2: payload
        appendTag(&decoded, field: 2, wire: 2)
        appendVarint(&decoded, UInt64(atakPayload.count))
        decoded.append(atakPayload)
        // 3: want_response (bool varint)
        if wantResponse {
            appendVarintField(&decoded, field: 3, value: 1)
        }

        // MeshPacket.
        var meshPacket = Data()
        // 2: to (fixed32)
        appendTag(&meshPacket, field: 2, wire: 5)
        appendFixed32(&meshPacket, value: destination)
        // 3: channel (uint32 varint)
        if channel != 0 {
            appendVarintField(&meshPacket, field: 3, value: UInt64(channel))
        }
        // 4: decoded (sub-message)
        appendTag(&meshPacket, field: 4, wire: 2)
        appendVarint(&meshPacket, UInt64(decoded.count))
        meshPacket.append(decoded)
        // 6: id (fixed32)
        appendTag(&meshPacket, field: 6, wire: 5)
        appendFixed32(&meshPacket, value: packetID)
        // 9: hop_limit (uint32 varint) — emitted before field 10 so the
        // marker survives multi-hop relays across the mesh.
        if hopLimit != 0 {
            appendVarintField(&meshPacket, field: 9, value: UInt64(hopLimit))
        }
        // 10: want_ack (bool varint)
        if wantAck {
            appendVarintField(&meshPacket, field: 10, value: 1)
        }

        // ToRadio with field 1 = packet.
        var toRadio = Data()
        appendTag(&toRadio, field: 1, wire: 2)
        appendVarint(&toRadio, UInt64(meshPacket.count))
        toRadio.append(meshPacket)
        return toRadio
    }

    // MARK: - Helpers

    private static func millis(_ date: Date) -> UInt64 {
        let ms = date.timeIntervalSince1970 * 1000.0
        if ms < 0 { return 0 }
        return UInt64(ms)
    }

    private static func escape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
