//
//  KMLOverlayRendererTests.swift
//  OmniTAKMobileTests
//
//  TDD test for KMLOverlayRenderer (Issue #17: SAR GeoPDF/KML overlays).
//
//  NOTE: As of release 2.18.0 the Xcode project still does NOT have an
//  `OmniTAKMobileTests` PBXNativeTarget. This file lives in the canonical
//  test folder so it activates the moment a real test target is wired up.
//  See docs/release-notes/2.18.0-vc26051104.md and docs/specs/map-overlays.md.
//

import XCTest
import MapKit
@testable import OmniTAKMobile

final class KMLOverlayRendererTests: XCTestCase {

    /// Smallest possible "search boundary" KML — a single closed polygon
    /// around a 0.1° square near Spokane, WA. Verifies the overlay path:
    ///   KML XML  ->  KMLParser  ->  KMLOverlayRenderer  ->  MKPolygon
    ///
    /// Five coordinates because KML LinearRing requires the first point
    /// to repeat as the last point.
    func testParseAndRenderClosedPolygon() throws {
        let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <name>Test SAR Boundary</name>
            <Placemark>
              <name>Search Boundary</name>
              <Polygon>
                <outerBoundaryIs>
                  <LinearRing>
                    <coordinates>
                      -117.5,47.6,0
                      -117.4,47.6,0
                      -117.4,47.7,0
                      -117.5,47.7,0
                      -117.5,47.6,0
                    </coordinates>
                  </LinearRing>
                </outerBoundaryIs>
              </Polygon>
            </Placemark>
          </Document>
        </kml>
        """

        let parser = KMLParser(fileName: "test-boundary.kml")
        let document = try parser.parse(data: Data(kml.utf8))

        XCTAssertEqual(document.placemarks.count, 1,
                       "Expected exactly one placemark in the test KML.")

        let overlayId = UUID()
        let overlays = KMLOverlayRenderer.makeOverlays(from: document,
                                                      overlayId: overlayId)

        XCTAssertEqual(overlays.count, 1,
                       "A single-polygon KML should produce a single MKOverlay.")

        let polygon = try XCTUnwrap(overlays.first as? MKPolygon,
                                    "The overlay must be an MKPolygon.")

        // KML LinearRing repeats the first point as the last point.
        XCTAssertEqual(polygon.pointCount, 5,
                       "MKPolygon should preserve all five coordinates from the LinearRing.")

        // Spot-check the geographic corner near (47.6, -117.5).
        let mapPoint = polygon.points()[0]
        let coord = mapPoint.coordinate
        XCTAssertEqual(coord.latitude, 47.6, accuracy: 0.0001)
        XCTAssertEqual(coord.longitude, -117.5, accuracy: 0.0001)
    }

    /// Points must NOT produce overlays — passive overlay layer is shading,
    /// not markers. Point features belong to the feature-ingest path.
    func testParseIgnoresPointPlacemarks() throws {
        let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <Placemark>
              <name>Trailhead</name>
              <Point><coordinates>-117.5,47.6,0</coordinates></Point>
            </Placemark>
          </Document>
        </kml>
        """

        let document = try KMLParser(fileName: "t.kml").parse(data: Data(kml.utf8))
        let overlays = KMLOverlayRenderer.makeOverlays(from: document, overlayId: UUID())
        XCTAssertEqual(overlays.count, 0,
                       "Point placemarks should not produce passive map overlays.")
    }

    /// LineString -> MKPolyline. Common case: CalTopo route export.
    func testParseLineStringProducesPolyline() throws {
        let kml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <kml xmlns="http://www.opengis.net/kml/2.2">
          <Document>
            <Placemark>
              <name>Route</name>
              <LineString>
                <coordinates>
                  -117.5,47.6,0 -117.45,47.65,0 -117.4,47.7,0
                </coordinates>
              </LineString>
            </Placemark>
          </Document>
        </kml>
        """

        let document = try KMLParser(fileName: "r.kml").parse(data: Data(kml.utf8))
        let overlays = KMLOverlayRenderer.makeOverlays(from: document, overlayId: UUID())
        XCTAssertEqual(overlays.count, 1)
        XCTAssertTrue(overlays.first is MKPolyline,
                      "LineString should produce an MKPolyline overlay.")
    }
}
