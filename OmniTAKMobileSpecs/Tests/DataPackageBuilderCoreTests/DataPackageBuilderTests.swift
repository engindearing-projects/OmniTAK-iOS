//
//  DataPackageBuilderTests.swift
//  OmniTAKMobileSpecs
//
//  RED → GREEN harness for `DataPackageBuilder`. Validates that a
//  caller-supplied `PackageSelection` lands in a valid `.zip` byte
//  stream containing a manifest plus the selected subset of markers
//  / drawings / tracks. Closes K9Blue's SAR feedback (5/10/26):
//  "Data packages" — today the only way to seed one is to drop the
//  demo bundle in via deeplink.
//
//  Round-trips through the same `DataPackageZipReader` the app uses
//  to import packages, so a green test == ATAK/iTAK can open the
//  output.
//

import XCTest
@testable import DataPackageBuilderCore

final class DataPackageBuilderTests: XCTestCase {

    // MARK: - Build from selection

    func testBuildPackageFromSelection() throws {
        // Arrange — three markers, two drawings, one track. The
        // selection includes only the first marker + the line drawing
        // + the track.
        let markers: [PackageMarker] = [
            PackageMarker(
                id: "marker-1",
                name: "OP-Alpha",
                latitude: 47.66,
                longitude: -117.43,
                altitude: 712,
                cotType: "a-f-G-U-C",
                remarks: "OP overlooking river"
            ),
            PackageMarker(
                id: "marker-2",
                name: "RP",
                latitude: 47.65,
                longitude: -117.42,
                altitude: nil,
                cotType: "a-n-G",
                remarks: nil
            ),
            PackageMarker(
                id: "marker-3",
                name: "LKP",
                latitude: 47.64,
                longitude: -117.41,
                altitude: nil,
                cotType: "a-f-G",
                remarks: nil
            )
        ]
        let drawings: [PackageDrawing] = [
            PackageDrawing(
                id: "drawing-1",
                name: "Search Boundary",
                kind: .polygon,
                color: "#FF0000",
                coordinates: [
                    PackageCoordinate(latitude: 47.66, longitude: -117.43),
                    PackageCoordinate(latitude: 47.67, longitude: -117.42),
                    PackageCoordinate(latitude: 47.66, longitude: -117.41),
                    PackageCoordinate(latitude: 47.66, longitude: -117.43)
                ]
            ),
            PackageDrawing(
                id: "drawing-2",
                name: "Approach Route",
                kind: .line,
                color: "#00FF00",
                coordinates: [
                    PackageCoordinate(latitude: 47.66, longitude: -117.43),
                    PackageCoordinate(latitude: 47.665, longitude: -117.425)
                ]
            )
        ]
        let tracks: [PackageTrack] = [
            PackageTrack(
                id: "track-1",
                name: "K9 Bear sweep",
                color: "#FFFF00",
                points: [
                    PackageTrackPoint(latitude: 47.66, longitude: -117.43, altitude: 700, timestamp: Date(timeIntervalSince1970: 1_778_336_000)),
                    PackageTrackPoint(latitude: 47.665, longitude: -117.425, altitude: 705, timestamp: Date(timeIntervalSince1970: 1_778_336_060))
                ]
            )
        ]

        let selection = PackageSelection(
            name: "SAR Brief",
            markerIDs: ["marker-1"],
            drawingIDs: ["drawing-2"],
            trackIDs: ["track-1"]
        )

        // Act
        let builder = DataPackageBuilder()
        let zipData = try builder.buildPackage(
            selection: selection,
            markers: markers,
            drawings: drawings,
            tracks: tracks
        )

        // Assert — valid ZIP (PK signature) and round-trips
        XCTAssertGreaterThan(zipData.count, 0, "zip should not be empty")
        XCTAssertEqual(zipData[0], 0x50, "byte 0 should be 'P'")
        XCTAssertEqual(zipData[1], 0x4B, "byte 1 should be 'K'")

        // Round-trip through the same simple ZIP reader the app uses
        // for import — this is the contract that lets ATAK/iTAK open
        // it on the receiving end.
        let entries = try DataPackageZipReader.read(zipData)
        let fileNames = entries.map { $0.fileName }.sorted()
        XCTAssertTrue(fileNames.contains("MANIFEST.xml"), "missing MANIFEST.xml — saw \(fileNames)")
        XCTAssertTrue(fileNames.contains { $0.hasSuffix(".cot") }, "missing CoT payload — saw \(fileNames)")
        XCTAssertTrue(fileNames.contains { $0.hasSuffix(".kml") }, "missing KML payload — saw \(fileNames)")
        XCTAssertTrue(fileNames.contains { $0.hasSuffix(".gpx") || $0.hasSuffix(".kml") }, "missing track payload — saw \(fileNames)")

        // Manifest should name only the selected items
        guard let manifest = entries.first(where: { $0.fileName == "MANIFEST.xml" })
                .flatMap({ String(data: $0.data, encoding: .utf8) }) else {
            return XCTFail("manifest unreadable")
        }
        XCTAssertTrue(manifest.contains("OP-Alpha"), "manifest must mention selected marker")
        XCTAssertFalse(manifest.contains("RP"), "manifest must NOT mention de-selected marker RP")
        XCTAssertFalse(manifest.contains("LKP"), "manifest must NOT mention de-selected marker LKP")
        XCTAssertTrue(manifest.contains("Approach Route"), "manifest must mention selected drawing")
        XCTAssertFalse(manifest.contains("Search Boundary"), "manifest must NOT mention de-selected drawing")
        XCTAssertTrue(manifest.contains("K9 Bear sweep"), "manifest must mention selected track")
        XCTAssertTrue(manifest.contains("SAR Brief"), "manifest must carry the user-supplied name")

        // CoT payload should carry the selected marker's coordinates
        let cotEntry = entries.first { $0.fileName.hasSuffix(".cot") }
        XCTAssertNotNil(cotEntry, "should produce a CoT payload")
        let cotText = cotEntry.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        XCTAssertTrue(cotText.contains("47.66"), "CoT must include selected marker lat")
        XCTAssertTrue(cotText.contains("-117.43"), "CoT must include selected marker lon")
        XCTAssertFalse(cotText.contains("47.65"), "CoT must not leak de-selected marker")
    }

    // MARK: - Empty selection

    func testBuildPackageWithEmptySelectionStillProducesValidZip() throws {
        let builder = DataPackageBuilder()
        let zipData = try builder.buildPackage(
            selection: PackageSelection(name: "Empty"),
            markers: [],
            drawings: [],
            tracks: []
        )
        XCTAssertGreaterThan(zipData.count, 0)
        let entries = try DataPackageZipReader.read(zipData)
        XCTAssertTrue(entries.contains { $0.fileName == "MANIFEST.xml" })
    }

    // MARK: - Size estimate

    func testEstimatedSizeMatchesActualWithinTolerance() throws {
        let markers = (0..<10).map { i in
            PackageMarker(
                id: "m-\(i)",
                name: "Marker \(i)",
                latitude: 47.6 + Double(i) * 0.001,
                longitude: -117.4 - Double(i) * 0.001,
                altitude: 700,
                cotType: "a-f-G",
                remarks: "remarks \(i)"
            )
        }
        let selection = PackageSelection(
            name: "Bulk",
            markerIDs: Set(markers.map { $0.id })
        )
        let builder = DataPackageBuilder()
        let estimate = builder.estimatedSize(
            selection: selection,
            markers: markers,
            drawings: [],
            tracks: []
        )
        let actual = try builder.buildPackage(
            selection: selection,
            markers: markers,
            drawings: [],
            tracks: []
        ).count

        // Estimate within 4x — back-of-envelope is enough for the UI
        XCTAssertGreaterThan(estimate, 0)
        let ratio = Double(actual) / Double(estimate)
        XCTAssertTrue(ratio > 0.2 && ratio < 5.0,
                      "estimate=\(estimate) vs actual=\(actual) ratio=\(ratio)")
    }
}
