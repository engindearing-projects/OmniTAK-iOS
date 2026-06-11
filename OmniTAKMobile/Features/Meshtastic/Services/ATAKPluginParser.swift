//
//  ATAKPluginParser.swift
//  OmniTAKMobile
//
//  Parses Meshtastic portnum-72 (ATAK_PLUGIN) payloads into CoTEvent objects.
//
//  The portnum-72 payload is normally a TAK protobuf `TAKMessage` containing
//  a `CoTEvent` submessage (the schema documented in atak-civ / mesh-protobufs).
//  Older clients sometimes wrap raw CoT XML directly in the payload — we
//  attempt the protobuf path first and fall back to XML when the bytes look
//  like a CoT XML document.
//
//  The encoder lives in `ATAKPluginSerializer.swift`. Parser and serializer
//  hand-roll the protobuf wire format the same way `MeshtasticTCPClient.swift`
//  does, intentionally avoiding a `swift-protobuf` dependency.
//
//  TAK protobuf schema (subset used here):
//
//  message TAKMessage {
//      TakControl takControl = 1;
//      CoTEvent   cotEvent   = 2;
//  }
//  message CoTEvent {
//      string type      = 1;
//      string access    = 2;
//      string qos       = 3;
//      string opex      = 4;
//      string uid       = 5;
//      uint64 sendTime  = 6;
//      uint64 startTime = 7;
//      uint64 staleTime = 8;
//      string how       = 9;
//      double lat       = 10;
//      double lon       = 11;
//      double hae       = 12;
//      double ce        = 13;
//      double le        = 14;
//      Detail detail    = 15;
//  }
//  message Detail {
//      string xmlDetail               = 1;
//      Group group                    = 2;
//      PrecisionLocation precision    = 3;
//      Status status                  = 4;
//      Takv takv                      = 5;
//      Contact contact                = 6;
//      Track track                    = 7;
//  }
//

import Foundation

/// Result of a successful ATAK-plugin payload parse.
///
/// We surface the populated `CoTEvent` plus the reconstructed `<detail>` XML
/// fragment so downstream code that expects raw CoT XML can still see the
/// extra TAK-protobuf submessages (group/contact/status/takv/track/etc.) even
/// though the current `CoTEvent` model can't carry them all natively.
///
/// TODO: widen `CoTDetail` to carry these fields directly (group role,
///       precisionLocation src, takv version) so the XML round-trip becomes
///       lossless without piggy-backing on remarks.
struct ATAKPluginParsedMessage {
    let event: CoTEvent
    let detailXML: String
    let cotXML: String
}

enum ATAKPluginParser {

    // MARK: - Public Entry

    /// Parse a portnum-72 payload. Returns the populated CoTEvent, or nil if the
    /// bytes are neither a recognizable TAKMessage protobuf nor a CoT XML doc.
    static func parse(_ payload: Data) -> CoTEvent? {
        return parseDetailed(payload)?.event
    }

    /// Like `parse` but returns the auxiliary XML fragments for callers that
    /// want to forward raw CoT XML (e.g. into the existing CoTMessageParser
    /// pipeline) instead of the structured event.
    static func parseDetailed(_ payload: Data) -> ATAKPluginParsedMessage? {
        guard !payload.isEmpty else { return nil }

        // XML fast-path — older ATAK plugin clients shove raw CoT XML directly
        // into the portnum-72 payload, no protobuf wrapper.
        if looksLikeXML(payload), let xmlString = String(data: payload, encoding: .utf8) {
            if let event = CoTMessageParser.parsePositionUpdate(xml: xmlString) {
                let detailXML = extractDetailXML(from: xmlString) ?? ""
                return ATAKPluginParsedMessage(event: event, detailXML: detailXML, cotXML: xmlString)
            }
            return nil
        }

        // Phase 2: try compact TAKPacket (atak.proto) FIRST.
        // Accepts if decode yields PLI, chat, or at minimum a contact.
        // Stock Meshtastic ATAK Plugin, phone-app TAK role, and the gateway
        // all use this format.
        if let pkt = TAKPacketCodec.decode(payload),
           let event = TAKPacketCodec.toCoTEvent(pkt) {
            let detailXML = buildDetailXMLFromTAKPacket(pkt)
            let cotXML = renderCoTXML(
                event: event,
                how: pkt.hasPLI ? "m-g" : "h-g-i-g-o",
                sendTime: event.time,
                startTime: event.time,
                staleTime: event.time.addingTimeInterval(pkt.hasPLI ? 300 : 60),
                detailXML: detailXML
            )
            return ATAKPluginParsedMessage(event: event, detailXML: detailXML, cotXML: cotXML)
        }

        // Phase 1 fallback: protobuf TAKMessage{CoTEvent} path.
        if let parsed = parseTAKMessage(payload) {
            return parsed
        }

        return nil
    }

    /// Build a `<detail>` XML fragment from a decoded TAKPacket, equivalent to
    /// what the TAK_Meshtastic_Gateway generates so downstream ATAK/WinTAK sees
    /// familiar fields.
    private static func buildDetailXMLFromTAKPacket(_ pkt: DecodedTAKPacket) -> String {
        var inner = ""
        let callsign = pkt.callsign.isEmpty ? pkt.deviceCallsign : pkt.callsign

        if pkt.hasPLI {
            inner += "<contact callsign=\"\(escape(callsign))\" endpoint=\"0.0.0.0:4242:tcp\"/>"
            inner += "<uid Droid=\"\(escape(callsign))\"/>"
            inner += "<precisionlocation altsrc=\"GPS\" geopointsrc=\"GPS\"/>"
            if pkt.battery > 0 {
                inner += "<status battery=\"\(pkt.battery)\"/>"
            }
            inner += "<takv device=\"Meshtastic\" platform=\"Meshtastic\" os=\"Meshtastic\" version=\"\"/>"
            let speedStr = pkt.speed.map { String($0) } ?? "0"
            let courseStr = pkt.course.map { String($0) } ?? "0"
            inner += "<track course=\"\(courseStr)\" speed=\"\(speedStr)\"/>"
            if pkt.team != .unspecifiedColor {
                inner += "<__group name=\"\(escape(pkt.team.displayName))\" role=\"\(escape(pkt.role.displayName))\"/>"
            }
        } else if pkt.hasChat {
            let to = pkt.chatTo ?? "All Chat Rooms"
            let senderUID = pkt.deviceCallsign.isEmpty ? pkt.callsign : pkt.deviceCallsign
            inner += "<__chat chatroom=\"\(escape(to))\" groupOwner=\"false\" id=\"\(escape(to))\""
            inner += " messageId=\"\" parent=\"RootContactGroup\" senderCallsign=\"\(escape(callsign))\">"
            inner += "<chatgrp id=\"\(escape(to))\" uid0=\"\(escape(senderUID))\" uid1=\"\(escape(to))\"/>"
            inner += "</__chat>"
            inner += "<link relation=\"p-p\" type=\"a-f-G-U-C\" uid=\"\(escape(senderUID))\"/>"
            if let msg = pkt.chatMessage {
                inner += "<remarks source=\"BAO.F.ATAK.\(escape(senderUID))\" to=\"\(escape(to))\">"
                inner += escape(msg)
                inner += "</remarks>"
            }
        }

        return "<detail>\(inner)</detail>"
    }

    /// Classify a parsed CoTEvent into the correct CoTEventType variant for
    /// `CoTEventHandler.handle(event:)`. Mirrors the routing in
    /// `CoTMessageParser.parse(xml:)`.
    static func classify(_ event: CoTEvent) -> CoTEventType {
        let t = event.type
        if t.hasPrefix("a-") {
            return .positionUpdate(event)
        }
        if t == "b-m-p-w" || t.hasPrefix("b-m-p-s-p-i") {
            return .waypoint(event)
        }
        // b-t-f is a GeoChat message.  We have all we need (uid, callsign,
        // remarks) from the parsed CoTEvent, so promote it to .chatMessage
        // so it lands in ChatManager.receiveMessage via CoTEventHandler.
        if t == "b-t-f" {
            let msg = ChatMessage(
                id: event.uid,
                conversationId: ChatRoom.allUsersId,
                senderId: event.uid,
                senderCallsign: event.detail.callsign,
                recipientId: nil,
                recipientCallsign: nil,
                messageText: event.detail.remarks ?? "",
                timestamp: event.time,
                status: .delivered,
                type: .geochat,
                isFromSelf: false
            )
            return .chatMessage(msg)
        }
        // b-a-* would need EmergencyAlert richer structure — best-effort via
        // the XML fallback path; treat remaining b-* as position updates so
        // they still flow into the marker pipeline.
        if t.hasPrefix("b-") {
            return .positionUpdate(event)
        }
        return .unknown(t)
    }

    // MARK: - TAKMessage protobuf

    private static func parseTAKMessage(_ data: Data) -> ATAKPluginParsedMessage? {
        var idx = 0
        var cotEventBytes: Data? = nil

        while idx < data.count {
            guard let tag = readTag(data, &idx) else { break }

            switch (tag.field, tag.wire) {
            case (1, 2): // takControl — ignore
                guard let len = readVarint(data, &idx) else { return nil }
                idx = min(idx + Int(len), data.count)
            case (2, 2): // cotEvent
                guard let len = readVarint(data, &idx) else { return nil }
                let end = min(idx + Int(len), data.count)
                cotEventBytes = data.subdata(in: idx..<end)
                idx = end
            default:
                if !skip(data, &idx, wire: tag.wire) { return nil }
            }
        }

        // The whole payload may itself be a bare CoTEvent (no TAKMessage wrapper),
        // some senders skip the outer envelope. Try that as a fallback.
        let cotBytes = cotEventBytes ?? data
        return parseCoTEvent(cotBytes)
    }

    private static func parseCoTEvent(_ data: Data) -> ATAKPluginParsedMessage? {
        var idx = 0

        var typeStr: String?
        var uid: String?
        var how: String?
        var sendTime: UInt64 = 0
        var startTime: UInt64 = 0
        var staleTime: UInt64 = 0
        var lat: Double = 0
        var lon: Double = 0
        var hae: Double = 0
        var ce: Double = 9999
        var le: Double = 9999
        var detailBytes: Data?

        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return nil }

            switch (tag.field, tag.wire) {
            case (1, 2): typeStr = readString(data, &idx)
            case (2, 2): _ = readString(data, &idx) // access
            case (3, 2): _ = readString(data, &idx) // qos
            case (4, 2): _ = readString(data, &idx) // opex
            case (5, 2): uid = readString(data, &idx)
            case (6, 0):
                guard let v = readVarint(data, &idx) else { return nil }
                sendTime = v
            case (7, 0):
                guard let v = readVarint(data, &idx) else { return nil }
                startTime = v
            case (8, 0):
                guard let v = readVarint(data, &idx) else { return nil }
                staleTime = v
            case (9, 2): how = readString(data, &idx)
            case (10, 1):
                guard let v = readFixed64(data, &idx) else { return nil }
                lat = Double(bitPattern: v)
            case (11, 1):
                guard let v = readFixed64(data, &idx) else { return nil }
                lon = Double(bitPattern: v)
            case (12, 1):
                guard let v = readFixed64(data, &idx) else { return nil }
                hae = Double(bitPattern: v)
            case (13, 1):
                guard let v = readFixed64(data, &idx) else { return nil }
                ce = Double(bitPattern: v)
            case (14, 1):
                guard let v = readFixed64(data, &idx) else { return nil }
                le = Double(bitPattern: v)
            case (15, 2):
                guard let len = readVarint(data, &idx) else { return nil }
                let end = min(idx + Int(len), data.count)
                detailBytes = data.subdata(in: idx..<end)
                idx = end
            default:
                if !skip(data, &idx, wire: tag.wire) { return nil }
            }
        }

        guard let resolvedUid = uid, let resolvedType = typeStr else {
            return nil
        }

        let parsedDetail = detailBytes.flatMap(parseDetail) ?? ParsedDetail()

        let cotDetail = CoTDetail(
            callsign: parsedDetail.callsign ?? resolvedUid,
            team: parsedDetail.groupName,
            teamRole: nil,
            speed: parsedDetail.speed,
            course: parsedDetail.course,
            remarks: parsedDetail.remarks,
            battery: parsedDetail.battery.map(Int.init),
            device: parsedDetail.device,
            platform: parsedDetail.platform
        )

        let event = CoTEvent(
            uid: resolvedUid,
            type: resolvedType,
            time: dateFromMillis(sendTime),
            point: CoTPoint(lat: lat, lon: lon, hae: hae, ce: ce, le: le),
            detail: cotDetail
        )

        let detailXML = renderDetailXML(parsedDetail)
        let cotXML = renderCoTXML(
            event: event,
            how: how ?? "m-g",
            sendTime: dateFromMillis(sendTime),
            startTime: dateFromMillis(startTime == 0 ? sendTime : startTime),
            staleTime: dateFromMillis(staleTime == 0 ? sendTime + 60_000 : staleTime),
            detailXML: detailXML
        )

        return ATAKPluginParsedMessage(event: event, detailXML: detailXML, cotXML: cotXML)
    }

    // MARK: - Detail submessage

    fileprivate struct ParsedDetail {
        var xmlDetail: String?
        var groupName: String?
        var groupRole: String?
        var precisionGeo: String?
        var precisionAlt: String?
        var battery: UInt32?
        var device: String?
        var platform: String?
        var os: String?
        var version: String?
        var callsign: String?
        var endpoint: String?
        var speed: Double?
        var course: Double?
        var remarks: String?
    }

    private static func parseDetail(_ data: Data) -> ParsedDetail? {
        var idx = 0
        var detail = ParsedDetail()

        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return nil }

            switch (tag.field, tag.wire) {
            case (1, 2): detail.xmlDetail = readString(data, &idx)
            case (2, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseGroup(bytes, into: &detail)
            case (3, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parsePrecisionLocation(bytes, into: &detail)
            case (4, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseStatus(bytes, into: &detail)
            case (5, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseTakv(bytes, into: &detail)
            case (6, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseContact(bytes, into: &detail)
            case (7, 2):
                guard let bytes = readLengthDelimited(data, &idx) else { return nil }
                parseTrack(bytes, into: &detail)
            default:
                if !skip(data, &idx, wire: tag.wire) { return nil }
            }
        }

        // Pull remarks out of xmlDetail if present so CoTDetail.remarks works.
        if let xml = detail.xmlDetail {
            detail.remarks = extractInnerText(of: "remarks", in: xml) ?? detail.remarks
        }

        return detail
    }

    private static func parseGroup(_ data: Data, into detail: inout ParsedDetail) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 2): detail.groupName = readString(data, &idx)
            case (2, 2): detail.groupRole = readString(data, &idx)
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    private static func parsePrecisionLocation(_ data: Data, into detail: inout ParsedDetail) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 2): detail.precisionGeo = readString(data, &idx)
            case (2, 2): detail.precisionAlt = readString(data, &idx)
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    private static func parseStatus(_ data: Data, into detail: inout ParsedDetail) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 0):
                guard let v = readVarint(data, &idx) else { return }
                detail.battery = UInt32(truncatingIfNeeded: v)
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    private static func parseTakv(_ data: Data, into detail: inout ParsedDetail) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 2): detail.device = readString(data, &idx)
            case (2, 2): detail.platform = readString(data, &idx)
            case (3, 2): detail.os = readString(data, &idx)
            case (4, 2): detail.version = readString(data, &idx)
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    private static func parseContact(_ data: Data, into detail: inout ParsedDetail) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 2): detail.callsign = readString(data, &idx)
            case (2, 2): detail.endpoint = readString(data, &idx)
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    private static func parseTrack(_ data: Data, into detail: inout ParsedDetail) {
        var idx = 0
        while idx < data.count {
            guard let tag = readTag(data, &idx) else { return }
            switch (tag.field, tag.wire) {
            case (1, 1):
                guard let v = readFixed64(data, &idx) else { return }
                detail.speed = Double(bitPattern: v)
            case (2, 1):
                guard let v = readFixed64(data, &idx) else { return }
                detail.course = Double(bitPattern: v)
            default: if !skip(data, &idx, wire: tag.wire) { return }
            }
        }
    }

    // MARK: - Detail XML rendering

    fileprivate static func renderDetailXML(_ detail: ParsedDetail) -> String {
        // Prefer the verbatim xmlDetail if the sender included one (it may
        // already wrap <detail>...</detail> tags).
        if let xml = detail.xmlDetail, !xml.isEmpty {
            // Strip surrounding <detail>...</detail> if present so we can wrap
            // ourselves consistently.
            let trimmed = xml.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("<detail") {
                return trimmed
            } else {
                return "<detail>\(trimmed)</detail>"
            }
        }

        var inner = ""
        if let cs = detail.callsign {
            if let endpoint = detail.endpoint {
                inner += "<contact callsign=\"\(escape(cs))\" endpoint=\"\(escape(endpoint))\"/>"
            } else {
                inner += "<contact callsign=\"\(escape(cs))\"/>"
            }
        }
        if let group = detail.groupName {
            let role = detail.groupRole.map { " role=\"\(escape($0))\"" } ?? ""
            inner += "<__group name=\"\(escape(group))\"\(role)/>"
        }
        if let geo = detail.precisionGeo {
            let alt = detail.precisionAlt.map { " altsrc=\"\(escape($0))\"" } ?? ""
            inner += "<precisionlocation geopointsrc=\"\(escape(geo))\"\(alt)/>"
        } else if let alt = detail.precisionAlt {
            inner += "<precisionlocation altsrc=\"\(escape(alt))\"/>"
        }
        if let battery = detail.battery {
            inner += "<status battery=\"\(battery)\"/>"
        }
        if detail.device != nil || detail.platform != nil || detail.os != nil || detail.version != nil {
            var attrs = ""
            if let v = detail.device { attrs += " device=\"\(escape(v))\"" }
            if let v = detail.platform { attrs += " platform=\"\(escape(v))\"" }
            if let v = detail.os { attrs += " os=\"\(escape(v))\"" }
            if let v = detail.version { attrs += " version=\"\(escape(v))\"" }
            inner += "<takv\(attrs)/>"
        }
        if detail.speed != nil || detail.course != nil {
            var attrs = ""
            if let v = detail.speed { attrs += " speed=\"\(v)\"" }
            if let v = detail.course { attrs += " course=\"\(v)\"" }
            inner += "<track\(attrs)/>"
        }
        if let remarks = detail.remarks {
            inner += "<remarks>\(escape(remarks))</remarks>"
        }
        return "<detail>\(inner)</detail>"
    }

    private static func renderCoTXML(
        event: CoTEvent,
        how: String,
        sendTime: Date,
        startTime: Date,
        staleTime: Date,
        detailXML: String
    ) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <event version="2.0" uid="\(escape(event.uid))" type="\(escape(event.type))" time="\(fmt.string(from: sendTime))" start="\(fmt.string(from: startTime))" stale="\(fmt.string(from: staleTime))" how="\(escape(how))">
        <point lat="\(event.point.lat)" lon="\(event.point.lon)" hae="\(event.point.hae)" ce="\(event.point.ce)" le="\(event.point.le)"/>
        \(detailXML)
        </event>
        """
    }

    // MARK: - Wire helpers

    private struct WireTag { let field: Int; let wire: UInt8 }

    private static func readTag(_ data: Data, _ idx: inout Int) -> WireTag? {
        guard let v = readVarint(data, &idx) else { return nil }
        return WireTag(field: Int(v >> 3), wire: UInt8(v & 0x07))
    }

    private static func readVarint(_ data: Data, _ idx: inout Int) -> UInt64? {
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

    private static func readFixed64(_ data: Data, _ idx: inout Int) -> UInt64? {
        guard idx + 8 <= data.count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(data[idx + i]) << (8 * i)
        }
        idx += 8
        return v
    }

    private static func readString(_ data: Data, _ idx: inout Int) -> String? {
        guard let bytes = readLengthDelimited(data, &idx) else { return nil }
        return String(data: bytes, encoding: .utf8)
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
        case 0:
            return readVarint(data, &idx) != nil
        case 1:
            guard idx + 8 <= data.count else { return false }
            idx += 8
            return true
        case 2:
            guard let len = readVarint(data, &idx) else { return false }
            let end = idx + Int(len)
            guard end <= data.count else { return false }
            idx = end
            return true
        case 5:
            guard idx + 4 <= data.count else { return false }
            idx += 4
            return true
        default:
            return false
        }
    }

    // MARK: - Misc helpers

    private static func looksLikeXML(_ data: Data) -> Bool {
        // Skip leading whitespace then sniff for "<?xml" or "<event".
        var i = 0
        while i < data.count {
            let b = data[i]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                i += 1
                continue
            }
            break
        }
        guard i < data.count else { return false }
        let remaining = data.count - i
        if remaining >= 5 {
            let xmlMarker: [UInt8] = [0x3C, 0x3F, 0x78, 0x6D, 0x6C] // <?xml
            if Array(data[i..<i+5]) == xmlMarker { return true }
        }
        if remaining >= 6 {
            let eventMarker: [UInt8] = [0x3C, 0x65, 0x76, 0x65, 0x6E, 0x74] // <event
            if Array(data[i..<i+6]) == eventMarker { return true }
        }
        return false
    }

    private static func dateFromMillis(_ ms: UInt64) -> Date {
        if ms == 0 { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    }

    private static func escape(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func extractDetailXML(from xml: String) -> String? {
        guard let openRange = xml.range(of: "<detail"),
              let closeRange = xml.range(of: "</detail>", range: openRange.upperBound..<xml.endIndex) else {
            return nil
        }
        return String(xml[openRange.lowerBound..<closeRange.upperBound])
    }

    private static func extractInnerText(of tag: String, in xml: String) -> String? {
        let openPattern = "<\(tag)>"
        let closePattern = "</\(tag)>"
        guard let openRange = xml.range(of: openPattern),
              let closeRange = xml.range(of: closePattern, range: openRange.upperBound..<xml.endIndex) else {
            return nil
        }
        let inner = xml[openRange.upperBound..<closeRange.lowerBound]
        return String(inner)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}

// MARK: - Test hook

#if DEBUG
extension ATAKPluginParser {
    /// Internal entry point exposed for unit tests so they can build or
    /// inspect the intermediate `ParsedDetail` structure without re-deriving
    /// it from XML.
    static func _testRenderDetailXML(
        callsign: String? = nil,
        groupName: String? = nil,
        groupRole: String? = nil,
        battery: UInt32? = nil,
        device: String? = nil,
        platform: String? = nil
    ) -> String {
        var d = ParsedDetail()
        d.callsign = callsign
        d.groupName = groupName
        d.groupRole = groupRole
        d.battery = battery
        d.device = device
        d.platform = platform
        return renderDetailXML(d)
    }
}
#endif
