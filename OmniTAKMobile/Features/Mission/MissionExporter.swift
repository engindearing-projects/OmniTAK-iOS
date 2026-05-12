//
//  MissionExporter.swift
//  OmniTAKMobile
//
//  Bundle every PointMarker + drawing + recorded track on the map into
//  a single KML file. Mirrors Android `MissionKmlExporter.kt` so a SAR
//  pair running mixed iOS + Android can hand off mid-search and the IC
//  drops the file into CalTopo, ATAK, or another K9 handler's client
//  without translation.
//
//  Closes K9Blue's TROP feedback (5/9/26): "Exporting Missions is not
//  possible from the app. Which really stinks because sometimes we will
//  be asked to provide search data on the spot when we do not have a
//  CalTopo file or equivalent."
//
//  Pure: takes the in-memory state, returns a string. Caller writes to
//  disk and share-sheets it.
//

import Foundation
import CoreLocation

struct MissionExporter {

    /// Default file/mission name when the caller has not supplied one.
    /// UTC HHmm matches the Android exporter so a cross-platform team
    /// produces the same default name in the same minute.
    static func defaultMissionName(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return "OmniTAK Mission \(f.string(from: now))"
    }

    /// Build the mission KML. All inputs are optional so a partial
    /// snapshot still produces a valid file (an iOS user with only
    /// tracks should still be able to export).
    static func export(
        pointMarkers: [PointMarker] = [],
        markerDrawings: [MarkerDrawing] = [],
        lines: [LineDrawing] = [],
        circles: [CircleDrawing] = [],
        polygons: [PolygonDrawing] = [],
        tracks: [Track] = [],
        missionName: String? = nil,
        now: Date = Date()
    ) -> String {
        let name = missionName ?? defaultMissionName(now: now)
        var sb = String()
        sb.reserveCapacity(4096)
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n")
        sb.append("<Document>\n")
        sb.append("<name>\(escape(name))</name>\n")
        sb.append("<description>Exported from OmniTAK at \(isoHuman(now))</description>\n")

        // Affiliation marker styles. KML colors are aabbggrr.
        for (id, color) in AFFILIATION_STYLES {
            sb.append("<Style id=\"\(id)\">")
            sb.append("<IconStyle><color>\(color)</color>")
            sb.append("<Icon><href>http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png</href></Icon></IconStyle>")
            sb.append("<LineStyle><color>\(color)</color><width>3</width></LineStyle>")
            sb.append("<PolyStyle><color>40\(color.dropFirst(2))</color></PolyStyle>")
            sb.append("</Style>\n")
        }
        sb.append("<Style id=\"sar_drawing\">")
        sb.append("<LineStyle><color>ff80de4a</color><width>3</width></LineStyle>")
        sb.append("<PolyStyle><color>4080de4a</color></PolyStyle>")
        sb.append("</Style>\n")
        sb.append("<Style id=\"sar_track\">")
        sb.append("<LineStyle><color>ffff00ff</color><width>4</width></LineStyle>")
        sb.append("</Style>\n")

        // Markers folder: point markers (PointDropperService) + marker
        // drawings (DrawingStore) — both render as KML Placemarks with
        // a Point geometry, so flatten into a single folder.
        sb.append("<Folder><name>Markers</name>\n")
        for m in pointMarkers {
            sb.append("<Placemark>\n")
            sb.append("<name>\(escape(m.name.isEmpty ? m.uid : m.name))</name>\n")
            sb.append("<styleUrl>#\(styleId(for: m.affiliation))</styleUrl>\n")
            if let remarks = m.remarks, !remarks.isEmpty {
                sb.append("<description>\(escape(remarks))</description>\n")
            }
            sb.append("<Point><coordinates>")
            sb.append("\(m.coordinate.longitude),\(m.coordinate.latitude),\(m.altitude ?? 0.0)")
            sb.append("</coordinates></Point>\n")
            sb.append("</Placemark>\n")
        }
        for d in markerDrawings {
            sb.append("<Placemark>\n")
            sb.append("<name>\(escape(d.label.isEmpty ? d.name : d.label))</name>\n")
            sb.append("<styleUrl>#sar_drawing</styleUrl>\n")
            sb.append("<Point><coordinates>")
            sb.append("\(d.coordinate.longitude),\(d.coordinate.latitude),0")
            sb.append("</coordinates></Point>\n")
            sb.append("</Placemark>\n")
        }
        sb.append("</Folder>\n")

        // Drawings folder: lines + polygons + circles.
        sb.append("<Folder><name>Drawings</name>\n")
        for line in lines { appendLine(&sb, line) }
        for poly in polygons { appendPolygon(&sb, poly) }
        for circle in circles { appendCircle(&sb, circle) }
        sb.append("</Folder>\n")

        // Tracks folder: each recorded Track becomes one LineString.
        sb.append("<Folder><name>Tracks</name>\n")
        for t in tracks { appendTrack(&sb, t) }
        sb.append("</Folder>\n")

        sb.append("</Document>\n</kml>\n")
        return sb
    }

    // MARK: - Drawing renderers

    private static func appendLine(_ sb: inout String, _ d: LineDrawing) {
        sb.append("<Placemark><name>\(escape(d.label.isEmpty ? d.name : d.label))</name>")
        sb.append("<styleUrl>#sar_drawing</styleUrl>")
        sb.append("<LineString><tessellate>1</tessellate><coordinates>")
        for c in d.coordinates {
            sb.append("\(c.longitude),\(c.latitude),0 ")
        }
        sb.append("</coordinates></LineString></Placemark>\n")
    }

    private static func appendPolygon(_ sb: inout String, _ d: PolygonDrawing) {
        guard let first = d.coordinates.first else { return }
        sb.append("<Placemark><name>\(escape(d.label.isEmpty ? d.name : d.label))</name>")
        sb.append("<styleUrl>#sar_drawing</styleUrl>")
        sb.append("<Polygon><outerBoundaryIs><LinearRing><coordinates>")
        for c in d.coordinates {
            sb.append("\(c.longitude),\(c.latitude),0 ")
        }
        // Close the ring.
        sb.append("\(first.longitude),\(first.latitude),0")
        sb.append("</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>\n")
    }

    private static func appendCircle(_ sb: inout String, _ d: CircleDrawing) {
        let name = d.label.isEmpty ? d.name : d.label
        sb.append("<Placemark><name>\(escape(name)) (\(formatRadius(d.radius)))</name>")
        sb.append("<styleUrl>#sar_drawing</styleUrl>")
        sb.append("<Polygon><outerBoundaryIs><LinearRing><coordinates>")
        // Approximate the circle with 64 points so it imports cleanly
        // into CalTopo / Google Earth — no native circle primitive in
        // KML 2.2.
        let steps = 64
        let centerLat = d.center.latitude
        let centerLon = d.center.longitude
        for i in 0...steps {
            let ang = (Double(i) / Double(steps)) * 2.0 * .pi
            let dLat = (d.radius / EARTH_R_M) * cos(ang)
            let dLon = (d.radius / EARTH_R_M) * sin(ang) / cos(centerLat * .pi / 180.0)
            let plat = centerLat + dLat * 180.0 / .pi
            let plon = centerLon + dLon * 180.0 / .pi
            sb.append("\(plon),\(plat),0 ")
        }
        sb.append("</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>\n")
    }

    private static func appendTrack(_ sb: inout String, _ t: Track) {
        sb.append("<Placemark><name>\(escape(t.name))</name>")
        sb.append("<styleUrl>#sar_track</styleUrl>")
        sb.append("<LineString><altitudeMode>absolute</altitudeMode><coordinates>")
        for p in t.points {
            sb.append("\(p.longitude),\(p.latitude),\(p.altitude) ")
        }
        sb.append("</coordinates></LineString></Placemark>\n")
    }

    // MARK: - Helpers

    private static let AFFILIATION_STYLES: [(String, String)] = [
        ("friendly", "ff00ff00"),  // green
        ("hostile",  "ff0000ff"),  // red
        ("neutral",  "ffffffff"),  // white
        ("unknown",  "ff00ffff"),  // yellow
    ]

    private static func styleId(for a: MarkerAffiliation) -> String {
        switch a {
        case .friendly: return "friendly"
        case .hostile:  return "hostile"
        case .neutral:  return "neutral"
        case .unknown:  return "unknown"
        }
    }

    private static let EARTH_R_M = 6_371_000.0

    private static func formatRadius(_ m: CLLocationDistance) -> String {
        if m >= 1000.0 {
            return String(format: "%.1f km", m / 1000.0)
        }
        return String(format: "%.0f m", m)
    }

    private static func isoHuman(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
