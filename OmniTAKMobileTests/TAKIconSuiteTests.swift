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

    // MARK: - All three standard packs are bundled (Phase 1 criteria)

    func testAllStandardPacksAreBundled() {
        // Phase 1 requires the standard sets — Markers / Spots / Google — to be
        // present. Each pack renders at runtime, so all report as bundled.
        for pack in TAKIconPack.allCases {
            XCTAssertTrue(pack.isBundled, "\(pack.displayName) must be bundled for Phase 1")
        }
        let names = Set(TAKIconPack.allCases.map { $0.displayName })
        XCTAssertEqual(names, ["Spot Map", "Markers", "Google"])
    }

    func testIconPackUIDsMatchATAK() {
        // The path prefixes must match ATAK's so an iconsetpath round-trips.
        XCTAssertEqual(TAKIconPack.spotMap.rawValue, "COT_MAPPING_SPOTMAP")
        XCTAssertEqual(TAKIconPack.markers.rawValue, "COT_MAPPING_2525C")
        XCTAssertEqual(TAKIconPack.google.rawValue, "f7f71666-8b28-4b57-9fbb-e38e61d33b79")
    }

    // MARK: - Markers (2525C) pack: resolution + selection + round-trip

    func testMarkersPackIsSelectable() {
        let icons = TAKIconRegistry.shared.selectableMarkersIcons
        XCTAssertFalse(icons.isEmpty, "Markers pack must be selectable when placing")
        // Every selectable Markers icon renders to a real image.
        for icon in icons {
            XCTAssertNotNil(TAKIconRegistry.shared.image(for: icon, size: 32))
        }
    }

    func testMarkersIconsetPathResolvesToImage() {
        // The exact gap from round 1: a received Markers iconsetpath must
        // resolve to a non-nil icon (not fall through to the generic frame).
        let img = TAKIconRegistry.shared.resolveImage(
            cotType: "a-f-G-U-C", iconsetPath: "COT_MAPPING_2525C/a-f-G-U-C-I")
        XCTAssertNotNil(img, "A Markers (2525C) usericon path must resolve to an icon")
    }

    func testMarkersIconsetPathTokenParse() {
        XCTAssertEqual(
            TAKMarkersIcon.cotType(fromIconsetPath: "COT_MAPPING_2525C/a-h-G-U-C"),
            "a-h-G-U-C")
        XCTAssertNil(TAKMarkersIcon.cotType(fromIconsetPath: "COT_MAPPING_SPOTMAP/red"))
    }

    func testMarkersCoTRoundTrip() {
        let marker = PointMarker(
            name: "H-INF-1",
            affiliation: .hostile,
            coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -117.4),
            markersIcon: .hostileInfantry
        )
        // Carries the icon's 2525 CoT type.
        XCTAssertEqual(marker.cotType, "a-h-G-U-C-I")
        let xml = MarkerCoTGenerator.generateCoT(for: marker)
        XCTAssertTrue(xml.contains("type=\"a-h-G-U-C-I\""),
                      "CoT should use the Markers icon's 2525 type; got: \(xml)")
        XCTAssertTrue(xml.contains("iconsetpath=\"COT_MAPPING_2525C/a-h-G-U-C-I\""),
                      "CoT should carry the Markers iconset path; got: \(xml)")
    }

    // MARK: - Google pack: resolution + selection + round-trip

    func testGooglePackIsSelectable() {
        let icons = TAKIconRegistry.shared.selectableGoogleIcons
        XCTAssertFalse(icons.isEmpty, "Google pack must be selectable when placing")
        for icon in icons {
            XCTAssertNotNil(TAKIconRegistry.shared.image(for: icon, size: 32))
        }
    }

    func testGoogleIconsetPathResolvesToImage() {
        // A received Google-pack iconsetpath must resolve to a non-nil pin.
        let path = "f7f71666-8b28-4b57-9fbb-e38e61d33b79/coffee.png"
        let img = TAKIconRegistry.shared.resolveImage(cotType: "a-u-G", iconsetPath: path)
        XCTAssertNotNil(img, "A Google usericon path must resolve to a place pin")
    }

    func testGoogleIconsetPathTokenParse() {
        let g = TAKGoogleIcon.from(
            iconsetPath: "f7f71666-8b28-4b57-9fbb-e38e61d33b79/hospitals.png")
        XCTAssertEqual(g, .hospitals)
        // Trailing .png optional / case-insensitive.
        XCTAssertEqual(
            TAKGoogleIcon.from(iconsetPath: "f7f71666-8b28-4b57-9fbb-e38e61d33b79/POLICE"),
            .police)
        // Non-Google path → nil.
        XCTAssertNil(TAKGoogleIcon.from(iconsetPath: "COT_MAPPING_SPOTMAP/red"))
    }

    func testGoogleIconsetPathFormatMatchesATAK() {
        XCTAssertEqual(TAKGoogleIcon.coffee.iconsetPath,
                       "f7f71666-8b28-4b57-9fbb-e38e61d33b79/coffee.png")
    }

    func testGoogleCoTRoundTrip() {
        let marker = PointMarker(
            name: "COFFEE-1",
            affiliation: .unknown,
            coordinate: CLLocationCoordinate2D(latitude: 47.6, longitude: -117.4),
            googleIcon: .coffee
        )
        let xml = MarkerCoTGenerator.generateCoT(for: marker)
        XCTAssertTrue(
            xml.contains("iconsetpath=\"f7f71666-8b28-4b57-9fbb-e38e61d33b79/coffee.png\""),
            "CoT should carry the Google iconset path; got: \(xml)")
    }

    // MARK: - Received pack markers resolve via the same path the map uses

    func testReceivedPackMarkersAllResolve() {
        // Mirror the map's symbolImage(for:) resolution: a spot, a Markers, and
        // a Google iconsetpath must each return a non-nil image so the map never
        // falls back to the generic affiliation glyph for a known pack.
        let cases: [(String, String)] = [
            ("b-m-p-s-m", "COT_MAPPING_SPOTMAP/blue"),
            ("a-f-G-U-C", "COT_MAPPING_2525C/a-f-G-U-C"),
            ("a-u-G", "f7f71666-8b28-4b57-9fbb-e38e61d33b79/gas_stations.png"),
        ]
        for (type, path) in cases {
            XCTAssertNotNil(
                TAKIconRegistry.shared.resolveImage(cotType: type, iconsetPath: path),
                "Pack marker \(path) should resolve to an icon")
        }
    }
}
