//
//  TAKIconSuiteTests.swift
//  OmniTAKMobileTests
//
//  Regression tests for the TAK icon suite (issue #75): the Spot Map icon
//  resolution + CoT round-trip. These pin the contract that a placed spot
//  marker emits the canonical iconset path + color and that a received
//  spot-map CoT resolves back to a renderable icon — i.e. that "standard TAK
//  icon sets render for matching CoT types and are selectable when placing
//  markers."
//

import XCTest
import CoreLocation
@testable import OmniTAK

final class TAKIconSuiteTests: XCTestCase {

    // MARK: - Canonical constants match ATAK

    func testSpotMapCoTTypeIsCanonical() {
        // ATAK's SpotMapReceiver.SPOT_MAP_POINT_COT_TYPE.
        XCTAssertEqual(TAKSpotIcon.cotType, "b-m-p-s-m")
    }

    func testIconsetPathFormatMatchesATAK() {
        // COT_MAPPING_SPOTMAP/{color}, lowercase color token.
        XCTAssertEqual(TAKSpotIcon.red.iconsetPath, "COT_MAPPING_SPOTMAP/red")
        XCTAssertEqual(TAKSpotIcon.cyan.iconsetPath, "COT_MAPPING_SPOTMAP/cyan")
    }

    // MARK: - iconsetpath → icon resolution

    func testResolveFromIconsetPath() {
        XCTAssertEqual(TAKSpotIcon.from(iconsetPath: "COT_MAPPING_SPOTMAP/orange"), .orange)
        // Case-insensitive trailing token.
        XCTAssertEqual(TAKSpotIcon.from(iconsetPath: "COT_MAPPING_SPOTMAP/GREEN"), .green)
        // The app's own affiliation-keyed path ("…/unknown_point") isn't a
        // known swatch token, so it falls back to white rather than nil.
        XCTAssertEqual(TAKSpotIcon.from(iconsetPath: "COT_MAPPING_SPOTMAP/unknown_point"), .white)
        // A non-spot iconset path resolves to nil (caller uses MIL-STD fallback).
        XCTAssertNil(TAKSpotIcon.from(iconsetPath: "COT_MAPPING_2525C/a-f-G"))
    }

    // MARK: - Registry resolution returns an image for spot types, nil otherwise

    func testRegistryResolvesSpotByType() {
        let img = TAKIconRegistry.shared.resolveImage(cotType: "b-m-p-s-m")
        XCTAssertNotNil(img, "Spot-map CoT type should resolve to a rendered dot")
    }

    func testRegistryResolvesSpotByIconsetPath() {
        let img = TAKIconRegistry.shared.resolveImage(
            cotType: "a-u-G", iconsetPath: "COT_MAPPING_SPOTMAP/red")
        XCTAssertNotNil(img, "A spot-map usericon path should resolve even for a generic type")
    }

    func testRegistryReturnsNilForPlainAffiliation() {
        // A normal MIL-STD affiliation type must NOT be hijacked by the spot
        // registry — it has to fall through to the 2525 frame.
        XCTAssertNil(TAKIconRegistry.shared.resolveImage(cotType: "a-f-G-U-C-I"))
    }

    // MARK: - ARGB color decode round-trips

    func testARGBRoundTrip() {
        // Red opaque = 0xFFFF0000 (signed -65536).
        let red = TAKSpotIcon.red
        let argbHex = red.argbHex
        XCTAssertEqual(argbHex, "FFFF0000")
        let signed = Int(Int32(bitPattern: UInt32(argbHex, radix: 16)!))
        let decoded = TAKIconRegistry.uiColor(fromARGB: signed)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        decoded.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, 1.0, accuracy: 0.02)
        XCTAssertEqual(g, 0.0, accuracy: 0.02)
        XCTAssertEqual(b, 0.0, accuracy: 0.02)
    }

    // MARK: - CoT round-trip: placed spot marker → CoT XML

    func testGeneratedCoTCarriesSpotIconsetAndType() {
        let marker = PointMarker(
            name: "SPOT-RED-1",
            affiliation: .unknown,
            coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -117.4),
            takIcon: .red
        )
        // The marker's CoT type is the canonical spot-map type.
        XCTAssertEqual(marker.cotType, "b-m-p-s-m")

        let xml = MarkerCoTGenerator.generateCoT(for: marker)
        XCTAssertTrue(xml.contains("type=\"b-m-p-s-m\""),
                      "CoT event should use the spot-map type; got: \(xml)")
        XCTAssertTrue(xml.contains("iconsetpath=\"COT_MAPPING_SPOTMAP/red\""),
                      "CoT should carry the canonical spot iconset path; got: \(xml)")
        // Color element present and red (the <color argb> is a signed int).
        let redSigned = Int(Int32(bitPattern: 0xFFFF0000))
        XCTAssertTrue(xml.contains("argb=\"\(redSigned)\""),
                      "CoT should carry the red ARGB color; got: \(xml)")
    }

    func testNonTakMarkerKeepsAffiliationIconsetPath() {
        // A plain affiliation marker still emits the legacy affiliation-keyed
        // spot path — we didn't regress the existing behavior.
        let marker = PointMarker(
            name: "HOSTILE-1",
            affiliation: .hostile,
            coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -117.4)
        )
        let xml = MarkerCoTGenerator.generateCoT(for: marker)
        XCTAssertTrue(xml.contains("iconsetpath=\"COT_MAPPING_SPOTMAP/hostile_point\""),
                      "Plain affiliation marker should keep its legacy path; got: \(xml)")
    }

    // MARK: - Selection catalogue is the full ATAK palette

    func testSelectableSpotCatalogueMatchesATAKPalette() {
        let names = Set(TAKIconRegistry.shared.selectableSpotIcons.map { $0.rawValue })
        // The canonical ATAK SpotMapPalletFragment colors.
        let expected: Set<String> = ["white", "yellow", "orange", "brown", "red",
                                     "magenta", "blue", "cyan", "green", "grey", "black"]
        XCTAssertEqual(names, expected)
    }
}
