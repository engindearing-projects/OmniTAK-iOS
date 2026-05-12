// KMLOverlayRendererSpec.swift
//
// Standalone TDD spec for Issue #17 — KML overlay rendering.
// Runs without a PBXNativeTarget via `./run-spec.sh`.
//
// swift-include: OmniTAKMobile/Utilities/Parsers/KMLParser.swift
// swift-include: OmniTAKMobile/Features/Map/Overlays/MapOverlayDescriptor.swift
// swift-include: OmniTAKMobile/Utilities/Integration/KMLOverlayRenderer.swift

import Foundation
import MapKit
import CoreLocation

func expect(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
    if !cond {
        FileHandle.standardError.write(Data("FAIL [\(file):\(line)] \(msg)\n".utf8))
        exit(1)
    }
}

// MARK: - testParseAndRenderClosedPolygon

let kmlPolygon = """
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

do {
    let doc = try KMLParser(fileName: "test-boundary.kml").parse(data: Data(kmlPolygon.utf8))
    expect(doc.placemarks.count == 1, "expected one placemark, got \(doc.placemarks.count)")

    let overlays = KMLOverlayRenderer.makeOverlays(from: doc, overlayId: UUID())
    expect(overlays.count == 1, "expected one overlay, got \(overlays.count)")

    guard let polygon = overlays.first as? MKPolygon else {
        FileHandle.standardError.write(Data("FAIL overlay was not MKPolygon\n".utf8))
        exit(1)
    }
    expect(polygon.pointCount == 5, "expected 5 points, got \(polygon.pointCount)")

    let first = polygon.points()[0].coordinate
    expect(abs(first.latitude - 47.6) < 0.0001, "lat=\(first.latitude)")
    expect(abs(first.longitude - (-117.5)) < 0.0001, "lon=\(first.longitude)")
} catch {
    FileHandle.standardError.write(Data("FAIL polygon parse threw: \(error)\n".utf8))
    exit(1)
}

// MARK: - testParseIgnoresPointPlacemarks

let kmlPoint = """
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
  <Placemark><name>Trailhead</name>
    <Point><coordinates>-117.5,47.6,0</coordinates></Point>
  </Placemark>
</Document></kml>
"""

do {
    let doc = try KMLParser(fileName: "t.kml").parse(data: Data(kmlPoint.utf8))
    let overlays = KMLOverlayRenderer.makeOverlays(from: doc, overlayId: UUID())
    expect(overlays.count == 0, "points should produce no overlays, got \(overlays.count)")
} catch {
    FileHandle.standardError.write(Data("FAIL point parse threw: \(error)\n".utf8))
    exit(1)
}

// MARK: - testParseLineStringProducesPolyline

let kmlLine = """
<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
  <Placemark><name>Route</name>
    <LineString><coordinates>-117.5,47.6,0 -117.45,47.65,0 -117.4,47.7,0</coordinates></LineString>
  </Placemark>
</Document></kml>
"""

do {
    let doc = try KMLParser(fileName: "r.kml").parse(data: Data(kmlLine.utf8))
    let overlays = KMLOverlayRenderer.makeOverlays(from: doc, overlayId: UUID())
    expect(overlays.count == 1, "expected one overlay for linestring, got \(overlays.count)")
    expect(overlays.first is MKPolyline, "linestring should produce MKPolyline")
} catch {
    FileHandle.standardError.write(Data("FAIL linestring parse threw: \(error)\n".utf8))
    exit(1)
}

print("PASS KMLOverlayRendererSpec — 3 assertions")
