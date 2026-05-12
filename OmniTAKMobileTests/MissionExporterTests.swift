//
//  MissionExporterTests.swift
//  OmniTAKMobileTests
//
//  Locks down the mission KML envelope shape so a SAR pair handing off
//  mid-search drops the file into CalTopo / ATAK and finds the same
//  Markers / Drawings / Tracks folders the Android counterpart writes.
//

import XCTest
import CoreLocation
@testable import OmniTAKMobile

final class MissionExporterTests: XCTestCase {

    private let fixedDate = Date(timeIntervalSince1970: 1_778_336_220) // 2026-05-11 14:37 UTC

    // MARK: - Envelope

    func test_empty_export_still_produces_valid_kml() {
        let kml = MissionExporter.export(now: fixedDate)
        XCTAssertTrue(kml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(kml.contains("<kml xmlns=\"http://www.opengis.net/kml/2.2\">"))
        XCTAssertTrue(kml.contains("<Document>"))
        XCTAssertTrue(kml.contains("</Document>"))
        XCTAssertTrue(kml.contains("<Folder><name>Markers</name>"))
        XCTAssertTrue(kml.contains("<Folder><name>Drawings</name>"))
        XCTAssertTrue(kml.contains("<Folder><name>Tracks</name>"))
        XCTAssertTrue(kml.hasSuffix("</kml>\n"))
    }

    func test_default_mission_name_is_utc_timestamped() {
        XCTAssertEqual(
            MissionExporter.defaultMissionName(now: fixedDate),
            "OmniTAK Mission 2026-05-11 1437"
        )
    }

    func test_custom_name_is_xml_escaped() {
        let kml = MissionExporter.export(
            missionName: "Bear & Owl <Search>",
            now: fixedDate
        )
        XCTAssertTrue(kml.contains("<name>Bear &amp; Owl &lt;Search&gt;</name>"))
    }

    // MARK: - Markers

    func test_point_marker_renders_with_coordinates_and_affiliation_style() {
        let marker = PointMarker(
            name: "Bravo-2",
            affiliation: .friendly,
            coordinate: CLLocationCoordinate2D(latitude: 47.66, longitude: -117.43),
            altitude: 712.0,
            remarks: "OP overlooking river"
        )
        let kml = MissionExporter.export(pointMarkers: [marker], now: fixedDate)
        XCTAssertTrue(kml.contains("<name>Bravo-2</name>"))
        XCTAssertTrue(kml.contains("<styleUrl>#friendly</styleUrl>"))
        XCTAssertTrue(kml.contains("-117.43,47.66,712.0"))
        XCTAssertTrue(kml.contains("<description>OP overlooking river</description>"))
    }

    // MARK: - Drawings

    func test_line_drawing_emits_linestring_in_lon_lat_order() {
        let line = LineDrawing(
            name: "Route A",
            color: DrawingColor.cyan,
            coordinates: [
                CLLocationCoordinate2D(latitude: 47.66, longitude: -117.43),
                CLLocationCoordinate2D(latitude: 47.67, longitude: -117.42),
            ]
        )
        let kml = MissionExporter.export(lines: [line], now: fixedDate)
        XCTAssertTrue(kml.contains("<LineString><tessellate>1</tessellate><coordinates>"))
        XCTAssertTrue(kml.contains("-117.43,47.66,0 -117.42,47.67,0"))
    }

    func test_polygon_closes_the_ring() {
        let poly = PolygonDrawing(
            name: "AO",
            color: DrawingColor.cyan,
            coordinates: [
                CLLocationCoordinate2D(latitude: 47.66, longitude: -117.43),
                CLLocationCoordinate2D(latitude: 47.67, longitude: -117.42),
                CLLocationCoordinate2D(latitude: 47.68, longitude: -117.44),
            ]
        )
        let kml = MissionExporter.export(polygons: [poly], now: fixedDate)
        // First and last coordinate of the LinearRing should match.
        XCTAssertTrue(kml.contains("-117.43,47.66,0 -117.42,47.67,0 -117.44,47.68,0 -117.43,47.66,0"))
    }

    func test_circle_includes_radius_in_name_and_closes_polygon() {
        let circle = CircleDrawing(
            name: "Search Radius",
            color: DrawingColor.cyan,
            center: CLLocationCoordinate2D(latitude: 47.66, longitude: -117.43),
            radius: 500.0
        )
        let kml = MissionExporter.export(circles: [circle], now: fixedDate)
        XCTAssertTrue(kml.contains("Search Radius (500 m)"))
        XCTAssertTrue(kml.contains("<Polygon><outerBoundaryIs><LinearRing>"))
    }

    // MARK: - Tracks

    func test_track_renders_as_linestring_with_absolute_altitude() {
        var track = Track(name: "Patrol")
        track.addPoint(TrackPoint(
            latitude: 47.66, longitude: -117.43, altitude: 700.0, timestamp: fixedDate
        ))
        track.addPoint(TrackPoint(
            latitude: 47.67, longitude: -117.42, altitude: 720.0,
            timestamp: fixedDate.addingTimeInterval(30)
        ))
        let kml = MissionExporter.export(tracks: [track], now: fixedDate)
        XCTAssertTrue(kml.contains("<styleUrl>#sar_track</styleUrl>"))
        XCTAssertTrue(kml.contains("<altitudeMode>absolute</altitudeMode>"))
        XCTAssertTrue(kml.contains("-117.43,47.66,700.0"))
        XCTAssertTrue(kml.contains("-117.42,47.67,720.0"))
    }
}
