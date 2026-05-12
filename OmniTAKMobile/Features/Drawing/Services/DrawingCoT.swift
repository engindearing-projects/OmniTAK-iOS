//
//  DrawingCoT.swift
//  OmniTAKMobile
//
//  Cross-platform parity with Android DrawingCoT.kt — closes K9Blue's
//  "Bullseye could not be shared within a mission" feedback by giving
//  the iOS app the same `u-d-*` event envelopes the Android side
//  emits, so a line / polygon / circle / bullseye drawn on one
//  platform reaches every connected TAK server's clients on the
//  other.
//
//  CoT type conventions match the Android side exactly so both
//  platforms' parsers round-trip each other's output:
//    - LINE / POLYGON → u-d-f (freeform), vertex chain as <link>
//    - CIRCLE → u-d-c-c with <ellipse> + radius=Nm in <remarks>
//    - BULLSEYE → N concentric u-d-c-c events sharing a group UID
//

import Foundation
import CoreLocation

enum DrawingCoT {

    // 6 h default — a search team should still see their own shapes
    // after a refuel break, but the map shouldn't fossilise a day-old
    // plan. Mirrors Android DEFAULT_STALE_SECONDS.
    static let defaultStaleSeconds: TimeInterval = 6 * 60 * 60

    /// SAR-standard concentric ring set when an operator drops a
    /// bullseye without customising radii. Matches Android exactly so
    /// the same bullseye reproduces visually on both platforms.
    static let defaultBullseyeRadiiM: [Double] = [100, 500, 1_000]

    /// Parsed shape recovered from an incoming `u-d-*` event. Kept as
    /// a flat struct (rather than a polymorphic protocol) so the
    /// receive site can route to whichever concrete `DrawingObject`
    /// the iOS store wants without re-introspecting XML.
    struct Parsed {
        enum Kind { case line, polygon, circle }
        let kind: Kind
        let uid: String
        let callsign: String
        let colorHex: String
        let widthPx: Float
        let points: [CLLocationCoordinate2D]   // line/polygon vertices, or [center] for circle
        let radiusM: Double?                   // circle only
        let bullseyeGroup: String?             // set when receiver should re-group rings
        let bullseyeRing: Int?
    }

    // MARK: - Build (line / polygon)

    static func buildLine(
        uid: String,
        callsign: String,
        points: [CLLocationCoordinate2D],
        closed: Bool,
        colorHex: String = "#4ADE80",
        widthPx: Float = 3,
        now: Date = Date(),
        staleSeconds: TimeInterval = defaultStaleSeconds
    ) -> String {
        precondition(points.count >= 2, "Line/polygon needs at least 2 points")
        let isoNow = isoUTC(now)
        let isoStale = isoUTC(now.addingTimeInterval(staleSeconds))
        let argb = hexToARGB(colorHex)
        let safeUid = escapeXML(uid)
        let safeCs = escapeXML(callsign.isEmpty ? (closed ? "Polygon" : "Line") : callsign)
        let anchor = points[0]

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<event version=\"2.0\""
        xml += " uid=\"\(safeUid)\""
        xml += " type=\"u-d-f\""
        xml += " time=\"\(isoNow)\" start=\"\(isoNow)\" stale=\"\(isoStale)\""
        xml += " how=\"h-e\">"
        xml += "<point lat=\"\(anchor.latitude)\" lon=\"\(anchor.longitude)\" hae=\"0.0\" ce=\"9999999.0\" le=\"9999999.0\"/>"
        xml += "<detail>"
        for (i, p) in points.enumerated() {
            xml += "<link uid=\"\(safeUid)-v\(i)\" type=\"b-m-p\""
            xml += " point=\"\(p.latitude),\(p.longitude),0.0\""
            xml += " relation=\"p-p\"/>"
        }
        if closed {
            xml += "<link uid=\"\(safeUid)-v\(points.count)\" type=\"b-m-p\""
            xml += " point=\"\(anchor.latitude),\(anchor.longitude),0.0\""
            xml += " relation=\"p-p\"/>"
            xml += "<__shapeExtras editable=\"true\" closed_polygon=\"1\"/>"
        } else {
            xml += "<__shapeExtras editable=\"true\"/>"
        }
        xml += "<strokeColor value=\"\(argb)\"/>"
        xml += "<strokeWeight value=\"\(widthPx)\"/>"
        // Fill at ~20% opacity for closed shapes; transparent for open lines.
        let fill = closed ? (argb & Int(0x33FFFFFF)) : 0
        xml += "<fillColor value=\"\(fill)\"/>"
        xml += "<labels_on value=\"false\"/>"
        xml += "<contact callsign=\"\(safeCs)\"/>"
        xml += "<remarks>OmniTAK drawing — \(closed ? "polygon" : "line"), \(points.count) vertices</remarks>"
        xml += "</detail>"
        xml += "</event>"
        return xml
    }

    // MARK: - Build (circle)

    static func buildCircle(
        uid: String,
        callsign: String,
        center: CLLocationCoordinate2D,
        radiusM: Double,
        colorHex: String = "#4ADE80",
        widthPx: Float = 3,
        now: Date = Date(),
        staleSeconds: TimeInterval = defaultStaleSeconds,
        bullseyeGroup: String? = nil,
        bullseyeRing: Int? = nil,
        bullseyeRingCount: Int? = nil
    ) -> String {
        let isoNow = isoUTC(now)
        let isoStale = isoUTC(now.addingTimeInterval(staleSeconds))
        let argb = hexToARGB(colorHex)
        let safeUid = escapeXML(uid)
        let safeCs = escapeXML(callsign.isEmpty ? "Circle" : callsign)
        let rStr = formatDouble(radiusM)

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<event version=\"2.0\""
        xml += " uid=\"\(safeUid)\""
        xml += " type=\"u-d-c-c\""
        xml += " time=\"\(isoNow)\" start=\"\(isoNow)\" stale=\"\(isoStale)\""
        xml += " how=\"h-e\">"
        xml += "<point lat=\"\(center.latitude)\" lon=\"\(center.longitude)\" hae=\"0.0\" ce=\"9999999.0\" le=\"9999999.0\"/>"
        xml += "<detail>"
        xml += "<shape><ellipse minor=\"\(rStr)\" major=\"\(rStr)\" angle=\"0\"/></shape>"
        xml += "<strokeColor value=\"\(argb)\"/>"
        xml += "<strokeWeight value=\"\(widthPx)\"/>"
        xml += "<fillColor value=\"0\"/>"
        xml += "<labels_on value=\"false\"/>"
        xml += "<contact callsign=\"\(safeCs)\"/>"
        if let group = bullseyeGroup, let ring = bullseyeRing {
            xml += "<__bullseye group=\"\(escapeXML(group))\" ring=\"\(ring)\""
            if let total = bullseyeRingCount { xml += " rings=\"\(total)\"" }
            xml += " radius=\"\(rStr)\"/>"
        }
        xml += "<remarks>OmniTAK drawing — circle, radius=\(rStr)m</remarks>"
        xml += "</detail>"
        xml += "</event>"
        return xml
    }

    // MARK: - Build (bullseye)

    /// Returns one CoT event per concentric ring. Receivers that don't
    /// understand `<__bullseye>` see them as plain circles — every TAK
    /// client renders circles, so the worst-case fallback still
    /// communicates the operator's intent.
    static func buildBullseye(
        baseUid: String,
        callsign: String,
        center: CLLocationCoordinate2D,
        radiiM: [Double]? = nil,
        colorHex: String = "#4ADE80",
        widthPx: Float = 3,
        now: Date = Date(),
        staleSeconds: TimeInterval = defaultStaleSeconds
    ) -> [String] {
        let rings = (radiiM ?? defaultBullseyeRadiiM)
            .filter { $0 > 0 }
            .sorted()
        guard !rings.isEmpty else { return [] }
        let baseCs = callsign.isEmpty ? "Bullseye" : callsign
        return rings.enumerated().map { (idx, r) in
            buildCircle(
                uid: "\(baseUid)-ring\(idx + 1)",
                callsign: "\(baseCs) R\(idx + 1)",
                center: center,
                radiusM: r,
                colorHex: colorHex,
                widthPx: widthPx,
                now: now,
                staleSeconds: staleSeconds,
                bullseyeGroup: baseUid,
                bullseyeRing: idx + 1,
                bullseyeRingCount: rings.count
            )
        }
    }

    // MARK: - Parse

    /// Recover a drawing from incoming CoT XML. Returns nil for
    /// anything that doesn't look like a `u-d-*` drawing — the caller
    /// then falls through to the standard CoT contact / chat parsers.
    static func parse(_ xml: String) -> Parsed? {
        guard let typeRange = xml.range(of: "type=\"u-d-"),
              let typeStart = xml.index(typeRange.upperBound, offsetBy: -3, limitedBy: xml.endIndex)
                .flatMap({ _ in xml.range(of: "type=\"", range: typeRange.lowerBound..<xml.endIndex) }) else {
            return nil
        }
        let afterType = xml.index(typeStart.upperBound, offsetBy: 0)
        guard let typeEnd = xml.range(of: "\"", range: afterType..<xml.endIndex) else { return nil }
        let cotType = String(xml[afterType..<typeEnd.lowerBound])
        guard cotType.hasPrefix("u-d-") else { return nil }

        guard let uid = attr(xml, "<event", "uid") else { return nil }
        let callsign = attr(xml, "<contact", "callsign") ?? ""
        let colorRaw = match(xml, pattern: "<strokeColor value=\"(-?[0-9]+)\"")
        let argb = colorRaw.flatMap { Int($0) }
        let colorHex = argb.map { argbToHex($0) } ?? "#4ADE80"
        let widthPx = match(xml, pattern: "<strokeWeight value=\"([0-9.]+)\"")
            .flatMap { Float($0) } ?? 3

        switch cotType {
        case "u-d-f":
            // Vertex chain inside <link point="lat,lon,..."/>.
            let linkPattern = "<link\\b[^/>]*\\bpoint=\"(-?[0-9.]+),(-?[0-9.]+)(?:,-?[0-9.]+)?\""
            var pts: [CLLocationCoordinate2D] = []
            if let regex = try? NSRegularExpression(pattern: linkPattern) {
                let ns = xml as NSString
                let range = NSRange(location: 0, length: ns.length)
                regex.enumerateMatches(in: xml, range: range) { m, _, _ in
                    guard let m = m, m.numberOfRanges >= 3 else { return }
                    let lat = Double(ns.substring(with: m.range(at: 1)))
                    let lon = Double(ns.substring(with: m.range(at: 2)))
                    if let lat = lat, let lon = lon {
                        pts.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
                    }
                }
            }
            guard pts.count >= 2 else { return nil }
            let closed = xml.contains("closed_polygon=\"1\"") || xml.contains("closed_polygon=\"true\"")
            // Drop the closing duplicate vertex on closed polygons so
            // the in-memory shape matches the sender's original.
            let cleaned: [CLLocationCoordinate2D]
            if closed && pts.count >= 4,
               let first = pts.first, let last = pts.last,
               abs(first.latitude - last.latitude) < 1e-9 &&
               abs(first.longitude - last.longitude) < 1e-9 {
                cleaned = Array(pts.dropLast())
            } else {
                cleaned = pts
            }
            return Parsed(
                kind: closed ? .polygon : .line,
                uid: uid,
                callsign: callsign,
                colorHex: colorHex,
                widthPx: widthPx,
                points: cleaned,
                radiusM: nil,
                bullseyeGroup: nil,
                bullseyeRing: nil
            )
        case "u-d-c-c":
            guard let latStr = match(xml, pattern: "<point lat=\"(-?[0-9.]+)\""),
                  let lonStr = match(xml, pattern: " lon=\"(-?[0-9.]+)\""),
                  let lat = Double(latStr), let lon = Double(lonStr) else { return nil }
            // Prefer the canonical ellipse minor axis; fall back to the
            // radius= remark for older / open-source clients.
            let radius = match(xml, pattern: "minor=\"([0-9.]+)\"").flatMap { Double($0) }
                ?? match(xml, pattern: "radius=([0-9.]+)m").flatMap { Double($0) }
            guard let r = radius else { return nil }
            let group = match(xml, pattern: "<__bullseye[^/>]*\\bgroup=\"([^\"]+)\"")
            let ring = match(xml, pattern: "<__bullseye[^/>]*\\bring=\"([0-9]+)\"")
                .flatMap { Int($0) }
            return Parsed(
                kind: .circle,
                uid: uid,
                callsign: callsign,
                colorHex: colorHex,
                widthPx: widthPx,
                points: [CLLocationCoordinate2D(latitude: lat, longitude: lon)],
                radiusM: r,
                bullseyeGroup: group,
                bullseyeRing: ring
            )
        default:
            return nil
        }
    }

    /// Convenience: detect whether a CoT XML blob is a drawing event
    /// without paying for the full parse. Used by the receive
    /// pipeline to short-circuit before invoking the marker parser.
    static func isDrawingCoT(_ xml: String) -> Bool {
        return xml.contains("type=\"u-d-f\"") || xml.contains("type=\"u-d-c-c\"")
    }

    // MARK: - Helpers

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func isoUTC(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func formatDouble(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return "\(Int64(v)).0"
        }
        return String(format: "%g", v)
    }

    /// "#RRGGBB" or "#AARRGGBB" → ARGB signed Int. Mirrors Android
    /// [DrawingCoT.hexToArgbInt] so the wire format stays byte-identical.
    static func hexToARGB(_ hex: String) -> Int {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        let padded: String
        switch s.count {
        case 6: padded = "FF" + s
        case 8: padded = s
        default: padded = "FF4ADE80"
        }
        guard let v = UInt32(padded, radix: 16) else { return -1 }
        return Int(Int32(bitPattern: v))
    }

    static func argbToHex(_ argb: Int) -> String {
        let u = UInt32(truncatingIfNeeded: argb)
        return String(format: "#%08X", u)
    }

    private static func escapeXML(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&", with: "&amp;")
        r = r.replacingOccurrences(of: "<", with: "&lt;")
        r = r.replacingOccurrences(of: ">", with: "&gt;")
        r = r.replacingOccurrences(of: "\"", with: "&quot;")
        r = r.replacingOccurrences(of: "'", with: "&apos;")
        return r
    }

    /// Extract an attribute value from the named opening tag. Returns
    /// nil if the tag or attribute is absent.
    private static func attr(_ xml: String, _ tag: String, _ name: String) -> String? {
        guard let tagRange = xml.range(of: tag) else { return nil }
        // Find the next > after the tag opens.
        guard let tagClose = xml.range(of: ">", range: tagRange.upperBound..<xml.endIndex) else { return nil }
        let region = xml[tagRange.upperBound..<tagClose.lowerBound]
        return match(String(region), pattern: "\\b\(name)=\"([^\"]*)\"")
    }

    /// First captured group from [pattern] applied to [xml], or nil.
    private static func match(_ xml: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = xml as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = regex.firstMatch(in: xml, range: range), m.numberOfRanges >= 2 else {
            return nil
        }
        return ns.substring(with: m.range(at: 1))
    }
}

// MARK: - Notification bridge for receive side

extension Notification.Name {
    /// Posted by `TAKService.handleReceivedMessage` whenever an incoming
    /// CoT event parses as a drawing. The `DrawingStore` owner (today:
    /// `MapViewController`) subscribes and ingests the payload via
    /// the appropriate `addLine` / `addCircle` / `addPolygon` call.
    /// `userInfo["payload"]` is a `DrawingCoT.Parsed`.
    static let drawingCoTReceived = Notification.Name("OmniTAK.drawingCoTReceived")
}
