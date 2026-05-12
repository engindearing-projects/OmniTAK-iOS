//
//  DataPackageBuilder.swift
//  OmniTAKMobile  (mirrored into OmniTAKMobileSpecs for `swift test`)
//
//  Pure-logic builder that takes a `PackageSelection` plus the
//  caller's marker / drawing / track collections and produces a
//  TAK-compatible data package (.zip) containing:
//
//    MANIFEST.xml   — TAK MissionPackageManifest naming the selection
//    markers.cot    — CoT XML payload (one <event> per selected marker)
//    drawings.kml   — KML payload with the selected drawings
//    tracks.gpx     — GPX payload with the selected GPS tracks
//
//  Closes K9Blue's SAR feedback (5/10/26): "Data packages". Today
//  `DataPackageManager.exportPackage` only re-packages KML overlays
//  and app settings; this builder lets the user assemble a fresh
//  package from in-memory state and round-trip it back into ATAK /
//  iTAK / OpenTAKserver.
//
//  Foundation + CoreLocation-free on purpose so the same source
//  file ships in the iOS app and in `OmniTAKMobileSpecs` for
//  off-device unit tests until we wire up a real PBXNativeTarget.
//

import Foundation

// MARK: - Selection input

/// What the user picked in the "Build data package" sheet. Empty
/// sets mean "include nothing of that kind" — the builder is happy
/// to produce an empty package containing only a manifest.
public struct PackageSelection: Equatable, Sendable {
    public var name: String
    public var packageDescription: String?
    public var author: String?
    public var markerIDs: Set<String>
    public var drawingIDs: Set<String>
    public var trackIDs: Set<String>
    public var overlayPaths: [String]

    public init(
        name: String = "OmniTAK Data Package",
        packageDescription: String? = nil,
        author: String? = nil,
        markerIDs: Set<String> = [],
        drawingIDs: Set<String> = [],
        trackIDs: Set<String> = [],
        overlayPaths: [String] = []
    ) {
        self.name = name
        self.packageDescription = packageDescription
        self.author = author
        self.markerIDs = markerIDs
        self.drawingIDs = drawingIDs
        self.trackIDs = trackIDs
        self.overlayPaths = overlayPaths
    }

    public var isEmpty: Bool {
        markerIDs.isEmpty && drawingIDs.isEmpty && trackIDs.isEmpty && overlayPaths.isEmpty
    }

    public var totalCount: Int {
        markerIDs.count + drawingIDs.count + trackIDs.count + overlayPaths.count
    }
}

// MARK: - Builder input models
//
// We deliberately mirror, rather than depend on, the live in-app
// types (PointMarker / MarkerDrawing / LineDrawing / CircleDrawing /
// PolygonDrawing / Track). Callers adapt their live state into these
// flat structs in one place (the UI layer); the builder stays a pure
// data → bytes function with no MapKit dependency.

public struct PackageCoordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct PackageMarker: Equatable, Sendable {
    public var id: String
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double?
    public var cotType: String
    public var remarks: String?

    public init(
        id: String,
        name: String,
        latitude: Double,
        longitude: Double,
        altitude: Double? = nil,
        cotType: String = "a-f-G",
        remarks: String? = nil
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.cotType = cotType
        self.remarks = remarks
    }
}

public enum PackageDrawingKind: String, Sendable {
    case marker
    case line
    case circle
    case polygon
}

public struct PackageDrawing: Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: PackageDrawingKind
    public var color: String
    public var coordinates: [PackageCoordinate]
    /// Radius in meters — only meaningful for `.circle`.
    public var radius: Double?

    public init(
        id: String,
        name: String,
        kind: PackageDrawingKind,
        color: String = "#FF0000",
        coordinates: [PackageCoordinate] = [],
        radius: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.color = color
        self.coordinates = coordinates
        self.radius = radius
    }
}

public struct PackageTrackPoint: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var timestamp: Date

    public init(latitude: Double, longitude: Double, altitude: Double, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
    }
}

public struct PackageTrack: Equatable, Sendable {
    public var id: String
    public var name: String
    public var color: String
    public var points: [PackageTrackPoint]

    public init(id: String, name: String, color: String = "#FF0000", points: [PackageTrackPoint] = []) {
        self.id = id
        self.name = name
        self.color = color
        self.points = points
    }
}

// MARK: - Errors

public enum DataPackageBuilderError: Error, Equatable {
    case zipWriteFailed
    case nothingToPackage
}

// MARK: - Builder

public struct DataPackageBuilder {

    public init() {}

    /// Build the `.zip` data for `selection` against the caller's
    /// live collections. Throws if ZIP serialization fails.
    public func buildPackage(
        selection: PackageSelection,
        markers: [PackageMarker],
        drawings: [PackageDrawing],
        tracks: [PackageTrack],
        now: Date = Date()
    ) throws -> Data {
        let filtered = filter(
            selection: selection,
            markers: markers,
            drawings: drawings,
            tracks: tracks
        )

        var files: [(name: String, data: Data)] = []

        // 1. Manifest — TAK-style MissionPackageManifest XML
        let manifestXML = makeManifest(selection: selection, filtered: filtered, now: now)
        files.append(("MANIFEST.xml", Data(manifestXML.utf8)))

        // 2. CoT payload for markers
        if !filtered.markers.isEmpty {
            let cot = makeCoT(markers: filtered.markers, now: now)
            files.append(("markers.cot", Data(cot.utf8)))
        }

        // 3. KML payload for drawings
        if !filtered.drawings.isEmpty {
            let kml = makeDrawingsKML(drawings: filtered.drawings, selection: selection, now: now)
            files.append(("drawings.kml", Data(kml.utf8)))
        }

        // 4. GPX payload for tracks
        if !filtered.tracks.isEmpty {
            let gpx = makeTracksGPX(tracks: filtered.tracks, selection: selection, now: now)
            files.append(("tracks.gpx", Data(gpx.utf8)))
        }

        return try DataPackageZipWriter.write(files: files)
    }

    /// Write the package directly to `url` and return its on-disk size.
    @discardableResult
    public func writePackage(
        to url: URL,
        selection: PackageSelection,
        markers: [PackageMarker],
        drawings: [PackageDrawing],
        tracks: [PackageTrack],
        now: Date = Date()
    ) throws -> Int64 {
        let data = try buildPackage(
            selection: selection,
            markers: markers,
            drawings: drawings,
            tracks: tracks,
            now: now
        )
        try data.write(to: url, options: .atomic)
        return Int64(data.count)
    }

    /// Cheap back-of-envelope size estimate for the UI ("≈ 12 KB").
    /// Errs on the high side so the user is never surprised by a
    /// bigger-than-shown file on disk.
    public func estimatedSize(
        selection: PackageSelection,
        markers: [PackageMarker],
        drawings: [PackageDrawing],
        tracks: [PackageTrack]
    ) -> Int {
        let filtered = filter(
            selection: selection,
            markers: markers,
            drawings: drawings,
            tracks: tracks
        )
        // Envelope overhead (manifest + zip central directory)
        var bytes = 1024
        // ~200 B per marker (CoT event + name + remarks)
        bytes += filtered.markers.count * 220
        // ~80 B per coordinate in a drawing
        for d in filtered.drawings {
            bytes += 200 + d.coordinates.count * 80
        }
        // ~70 B per track point
        for t in filtered.tracks {
            bytes += 200 + t.points.count * 70
        }
        return bytes
    }

    // MARK: - Filter

    private struct Filtered {
        var markers: [PackageMarker]
        var drawings: [PackageDrawing]
        var tracks: [PackageTrack]
    }

    private func filter(
        selection: PackageSelection,
        markers: [PackageMarker],
        drawings: [PackageDrawing],
        tracks: [PackageTrack]
    ) -> Filtered {
        Filtered(
            markers: markers.filter { selection.markerIDs.contains($0.id) },
            drawings: drawings.filter { selection.drawingIDs.contains($0.id) },
            tracks: tracks.filter { selection.trackIDs.contains($0.id) }
        )
    }

    // MARK: - Manifest

    private func makeManifest(
        selection: PackageSelection,
        filtered: Filtered,
        now: Date
    ) -> String {
        var sb = ""
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<MissionPackageManifest version=\"2\">\n")
        sb.append("  <Configuration>\n")
        sb.append("    <Parameter name=\"uid\" value=\"\(uuidString())\"/>\n")
        sb.append("    <Parameter name=\"name\" value=\"\(escapeXML(selection.name))\"/>\n")
        if let d = selection.packageDescription {
            sb.append("    <Parameter name=\"description\" value=\"\(escapeXML(d))\"/>\n")
        }
        if let a = selection.author {
            sb.append("    <Parameter name=\"author\" value=\"\(escapeXML(a))\"/>\n")
        }
        sb.append("    <Parameter name=\"createdAt\" value=\"\(iso8601(now))\"/>\n")
        sb.append("    <Parameter name=\"onReceiveImport\" value=\"true\"/>\n")
        sb.append("    <Parameter name=\"onReceiveDelete\" value=\"false\"/>\n")
        sb.append("  </Configuration>\n")
        sb.append("  <Contents>\n")
        if !filtered.markers.isEmpty {
            sb.append("    <Content ignore=\"false\" zipEntry=\"markers.cot\">\n")
            sb.append("      <Parameter name=\"contentType\" value=\"CoT\"/>\n")
            for m in filtered.markers {
                sb.append("      <Parameter name=\"marker\" value=\"\(escapeXML(m.name))\"/>\n")
            }
            sb.append("    </Content>\n")
        }
        if !filtered.drawings.isEmpty {
            sb.append("    <Content ignore=\"false\" zipEntry=\"drawings.kml\">\n")
            sb.append("      <Parameter name=\"contentType\" value=\"KML\"/>\n")
            for d in filtered.drawings {
                sb.append("      <Parameter name=\"drawing\" value=\"\(escapeXML(d.name))\"/>\n")
            }
            sb.append("    </Content>\n")
        }
        if !filtered.tracks.isEmpty {
            sb.append("    <Content ignore=\"false\" zipEntry=\"tracks.gpx\">\n")
            sb.append("      <Parameter name=\"contentType\" value=\"GPX\"/>\n")
            for t in filtered.tracks {
                sb.append("      <Parameter name=\"track\" value=\"\(escapeXML(t.name))\"/>\n")
            }
            sb.append("    </Content>\n")
        }
        sb.append("  </Contents>\n")
        sb.append("</MissionPackageManifest>\n")
        return sb
    }

    // MARK: - CoT (markers)

    private func makeCoT(markers: [PackageMarker], now: Date) -> String {
        // TAK accepts a stream of <event> elements in a `.cot` file
        // wrapped in a single <events> root. ATAK importer is lenient
        // about either form.
        var sb = ""
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<events>\n")
        let stale = now.addingTimeInterval(60 * 60 * 24)
        for m in markers {
            let uid = "OmniTAK-\(m.id)"
            sb.append("  <event version=\"2.0\" uid=\"\(escapeXML(uid))\" type=\"\(escapeXML(m.cotType))\" ")
            sb.append("time=\"\(iso8601(now))\" start=\"\(iso8601(now))\" stale=\"\(iso8601(stale))\" how=\"h-g-i-g-o\">\n")
            sb.append("    <point lat=\"\(m.latitude)\" lon=\"\(m.longitude)\" ")
            sb.append("hae=\"\(m.altitude ?? 0)\" ce=\"9999999\" le=\"9999999\"/>\n")
            sb.append("    <detail>\n")
            sb.append("      <contact callsign=\"\(escapeXML(m.name))\"/>\n")
            if let r = m.remarks {
                sb.append("      <remarks>\(escapeXML(r))</remarks>\n")
            }
            sb.append("    </detail>\n")
            sb.append("  </event>\n")
        }
        sb.append("</events>\n")
        return sb
    }

    // MARK: - KML (drawings)

    private func makeDrawingsKML(
        drawings: [PackageDrawing],
        selection: PackageSelection,
        now: Date
    ) -> String {
        var sb = ""
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n")
        sb.append("<Document>\n")
        sb.append("<name>\(escapeXML(selection.name))</name>\n")
        sb.append("<description>Drawings exported \(iso8601(now))</description>\n")
        for d in drawings {
            sb.append("<Placemark>\n")
            sb.append("  <name>\(escapeXML(d.name))</name>\n")
            switch d.kind {
            case .marker:
                if let p = d.coordinates.first {
                    sb.append("  <Point><coordinates>\(p.longitude),\(p.latitude),0</coordinates></Point>\n")
                }
            case .line:
                sb.append("  <LineString><coordinates>")
                sb.append(d.coordinates.map { "\($0.longitude),\($0.latitude),0" }.joined(separator: " "))
                sb.append("</coordinates></LineString>\n")
            case .polygon:
                sb.append("  <Polygon><outerBoundaryIs><LinearRing><coordinates>")
                sb.append(d.coordinates.map { "\($0.longitude),\($0.latitude),0" }.joined(separator: " "))
                sb.append("</coordinates></LinearRing></outerBoundaryIs></Polygon>\n")
            case .circle:
                // KML has no circle primitive — emit a tagged Point
                // and the receiver re-renders. ATAK respects this.
                if let p = d.coordinates.first {
                    sb.append("  <Point><coordinates>\(p.longitude),\(p.latitude),0</coordinates></Point>\n")
                    if let r = d.radius {
                        sb.append("  <ExtendedData><Data name=\"radius_m\"><value>\(r)</value></Data></ExtendedData>\n")
                    }
                }
            }
            sb.append("</Placemark>\n")
        }
        sb.append("</Document>\n")
        sb.append("</kml>\n")
        return sb
    }

    // MARK: - GPX (tracks)

    private func makeTracksGPX(
        tracks: [PackageTrack],
        selection: PackageSelection,
        now: Date
    ) -> String {
        var sb = ""
        sb.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        sb.append("<gpx version=\"1.1\" creator=\"OmniTAK iOS\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n")
        sb.append("  <metadata>\n")
        sb.append("    <name>\(escapeXML(selection.name))</name>\n")
        sb.append("    <time>\(iso8601(now))</time>\n")
        sb.append("  </metadata>\n")
        for t in tracks {
            sb.append("  <trk>\n")
            sb.append("    <name>\(escapeXML(t.name))</name>\n")
            sb.append("    <trkseg>\n")
            for p in t.points {
                sb.append("      <trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\">\n")
                sb.append("        <ele>\(p.altitude)</ele>\n")
                sb.append("        <time>\(iso8601(p.timestamp))</time>\n")
                sb.append("      </trkpt>\n")
            }
            sb.append("    </trkseg>\n")
            sb.append("  </trk>\n")
        }
        sb.append("</gpx>\n")
        return sb
    }

    // MARK: - Helpers

    private func uuidString() -> String {
        UUID().uuidString.lowercased()
    }

    private func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private func escapeXML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&apos;")
            default: out.append(ch)
            }
        }
        return out
    }
}
