//
//  CoTXMLBuilder.swift
//  OmniTAKMobile
//
//  Single owner of the outbound CoT <event> envelope. Every CoT
//  generator supplies only its <detail> payload; the envelope
//  (<?xml…?> declaration, <event> attributes uid/type/time/start/
//  stale/how, and the <point> element) is built here so the wire
//  format stays consistent across features. Also hosts the single
//  XML-escaping helper and the canonical ISO8601 formatter pair —
//  previously ~13 private escapeXML copies and 47 ad-hoc
//  ISO8601DateFormatter() instantiations were scattered per feature,
//  with timestamp precision differing between them.
//

import CoreLocation
import Foundation

// MARK: - XML escaping

extension String {
    /// Escape the five XML entities for safe embedding in attribute
    /// values and text nodes. `&` must be replaced first.
    var xmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// Returns true when this CoT UID belongs to a locally-dropped point
    /// marker.  All PointMarker instances set `uid = "marker-<UUID>"` in
    /// their initialiser — that prefix is the canonical discriminant used
    /// to distinguish user-dropped map markers from real EUDs (units that
    /// can receive chat messages) and from drone detections (prefix "RID-").
    ///
    /// Used by CoTEventHandler to skip the participant-store feed, and by
    /// ChatManager to scrub stale entries from the persisted participants
    /// list on launch.
    var isDroppedPointMarkerUID: Bool {
        hasPrefix("marker-")
    }
}

// MARK: - CoT XML Builder

enum CoTXMLBuilder {

    /// Canonical CoT timestamp formatter (internet date-time with
    /// fractional seconds — the form TAK servers themselves emit).
    /// ISO8601DateFormatter is thread-safe, so one shared instance
    /// replaces per-call instantiation.
    static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Whole-second variant for call sites/parsers that need the
    /// non-fractional form.
    static let timestampFormatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Format a date with the canonical CoT timestamp formatter.
    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    /// Build a complete CoT event document.
    ///
    /// - Parameters:
    ///   - uid: Event UID (escaped here).
    ///   - type: CoT type string, e.g. "a-f-G-U-C" (escaped here).
    ///   - how: CoT `how` attribute (default human-GPS "h-g-i-g-o").
    ///   - time: Event time (defaults to now).
    ///   - start: Validity start (defaults to `time`).
    ///   - staleAfter: Seconds after `time` at which the event goes stale.
    ///   - lat/lon/hae/ce/le: `<point>` attributes. ce/le default to the
    ///     TAK "unknown accuracy" sentinel.
    ///   - detail: Inner XML of `<detail>` — the caller composes and
    ///     escapes its own payload content (attribute values and text
    ///     nodes via `String.xmlEscaped`).
    static func buildEvent(
        uid: String,
        type: String,
        how: String = "h-g-i-g-o",
        time: Date = Date(),
        start: Date? = nil,
        staleAfter: TimeInterval,
        lat: Double,
        lon: Double,
        hae: Double = 0.0,
        ce: Double = 9999999.0,
        le: Double = 9999999.0,
        detail: String
    ) -> String {
        let timeStr = timestamp(time)
        let startStr = timestamp(start ?? time)
        let staleStr = timestamp(time.addingTimeInterval(staleAfter))
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <event version="2.0" uid="\(uid.xmlEscaped)" type="\(type.xmlEscaped)" time="\(timeStr)" start="\(startStr)" stale="\(staleStr)" how="\(how.xmlEscaped)">
            <point lat="\(lat)" lon="\(lon)" hae="\(hae)" ce="\(ce)" le="\(le)"/>
            <detail>
        \(detail)
            </detail>
        </event>
        """
    }

    /// Convenience overload taking a CLLocationCoordinate2D.
    static func buildEvent(
        uid: String,
        type: String,
        how: String = "h-g-i-g-o",
        time: Date = Date(),
        start: Date? = nil,
        staleAfter: TimeInterval,
        coordinate: CLLocationCoordinate2D,
        hae: Double = 0.0,
        ce: Double = 9999999.0,
        le: Double = 9999999.0,
        detail: String
    ) -> String {
        buildEvent(
            uid: uid,
            type: type,
            how: how,
            time: time,
            start: start,
            staleAfter: staleAfter,
            lat: coordinate.latitude,
            lon: coordinate.longitude,
            hae: hae,
            ce: ce,
            le: le,
            detail: detail
        )
    }
}
