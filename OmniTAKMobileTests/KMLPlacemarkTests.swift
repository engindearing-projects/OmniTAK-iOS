//
//  KMLPlacemarkTests.swift
//  OmniTAKMobileTests
//
//  TDD tests for issue #93 — KML Point placemarks as yellow pushpins + labels.
//
//  Verifies:
//  1. KMLParser yields the expected placemarks from a minimal KML document.
//  2. KMLGeoJSONExporter writes the `name` property into every Point feature.
//

import XCTest
import Foundation
@testable import OmniTAK

final class KMLPlacemarkTests: XCTestCase {

    // MARK: - Embedded test KML (2 named Point placemarks)

    private let twoPointKML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <kml xmlns="http://www.opengis.net/kml/2.2">
      <Document>
        <name>TestOverlay</name>
        <Placemark>
          <name>Alpha Base</name>
          <Point>
            <coordinates>121.5645,25.0339,0</coordinates>
          </Point>
        </Placemark>
        <Placemark>
          <name>Bravo Checkpoint</name>
          <Point>
            <coordinates>121.6000,25.0500,0</coordinates>
          </Point>
        </Placemark>
      </Document>
    </kml>
    """

    // MARK: - Parser yields 2 placemarks with correct names

    func testParserYieldsTwoNamedPlacemarks() throws {
        let data = try XCTUnwrap(twoPointKML.data(using: .utf8))
        let parser = KMLParser(fileName: "test.kml")
        let document = try parser.parse(data: data)

        XCTAssertEqual(document.placemarks.count, 2,
                       "Expected exactly 2 top-level placemarks")

        let names = document.placemarks.map { $0.name }
        XCTAssertTrue(names.contains("Alpha Base"),
                      "Expected 'Alpha Base' in placemarks, got \(names)")
        XCTAssertTrue(names.contains("Bravo Checkpoint"),
                      "Expected 'Bravo Checkpoint' in placemarks, got \(names)")
    }

    // MARK: - Parser yields Point geometry

    func testParserYieldsPointGeometry() throws {
        let data = try XCTUnwrap(twoPointKML.data(using: .utf8))
        let parser = KMLParser(fileName: "test.kml")
        let document = try parser.parse(data: data)

        for placemark in document.placemarks {
            if case .point = placemark.geometry {
                // correct
            } else {
                XCTFail("Placemark '\(placemark.name)' should have Point geometry")
            }
        }
    }

    // MARK: - Exporter writes `name` property into GeoJSON features

    func testExporterWritesNameProperty() throws {
        let data = try XCTUnwrap(twoPointKML.data(using: .utf8))
        let parser = KMLParser(fileName: "test.kml")
        let document = try parser.parse(data: data)

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kml_test_\(UUID().uuidString).geojson")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let result = try KMLGeoJSONExporter.export(document: document, to: tmpURL)

        // The exporter should report 2 features.
        XCTAssertEqual(result.featureCount, 2,
                       "Exporter should report 2 features")

        // Parse the output GeoJSON and verify the `name` property.
        let geojsonData = try Data(contentsOf: tmpURL)
        guard let json = try JSONSerialization.jsonObject(with: geojsonData) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            XCTFail("Could not parse output GeoJSON as FeatureCollection")
            return
        }

        XCTAssertEqual(features.count, 2,
                       "GeoJSON FeatureCollection should contain 2 features")

        for feature in features {
            guard let props = feature["properties"] as? [String: Any] else {
                XCTFail("Feature missing 'properties' object")
                continue
            }
            let name = props["name"] as? String
            XCTAssertNotNil(name,
                            "Feature 'properties' must contain a non-nil 'name' key")
            XCTAssertFalse((name ?? "").isEmpty,
                           "Feature 'name' property must not be empty")
        }

        // Both expected names must appear somewhere in the output.
        let outputString = String(data: geojsonData, encoding: .utf8) ?? ""
        XCTAssertTrue(outputString.contains("Alpha Base"),
                      "GeoJSON output must contain 'Alpha Base'")
        XCTAssertTrue(outputString.contains("Bravo Checkpoint"),
                      "GeoJSON output must contain 'Bravo Checkpoint'")
    }

    // MARK: - Exporter writes correct geometry type for points

    func testExporterWritesPointGeometryType() throws {
        let data = try XCTUnwrap(twoPointKML.data(using: .utf8))
        let parser = KMLParser(fileName: "test.kml")
        let document = try parser.parse(data: data)

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kml_geomtype_\(UUID().uuidString).geojson")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        _ = try KMLGeoJSONExporter.export(document: document, to: tmpURL)

        let geojsonData = try Data(contentsOf: tmpURL)
        guard let json = try JSONSerialization.jsonObject(with: geojsonData) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else {
            XCTFail("Could not parse output GeoJSON"); return
        }

        for feature in features {
            guard let geometry = feature["geometry"] as? [String: Any],
                  let geomType = geometry["type"] as? String else {
                XCTFail("Feature missing geometry.type"); continue
            }
            XCTAssertEqual(geomType, "Point",
                           "All features from point placemarks should be GeoJSON Points")
        }
    }
}
