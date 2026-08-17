//
//  CustomTileURLTests.swift
//  OmniTAKMobileTests
//
//  Unit tests for the custom WMTS/XYZ tile URL feature (issue #57).
//
//  Covers:
//    • CustomTileURLValidator.validate(_:) — returns nil on valid URLs,
//      error string on invalid ones.
//    • CustomTileURLValidator.normalize(_:) — converts ATAK-style {$z}/{$x}/{$y}
//      placeholders to the canonical {z}/{x}/{y} form.
//    • CustomTileURLValidator.rasterTileURL(_:zoom:x:y:) — substitutes
//      {z}/{x}/{y} into an accepted template and returns the concrete URL.
//    • MapLibreStyle.custom rawValue and display metadata.
//
//  All tests are pure logic — no MapView required, no network access.
//

import XCTest
@testable import OmniTAK

final class CustomTileURLTests: XCTestCase {

    // MARK: - Validation: valid URLs pass

    func testValidXYZURLPassesValidation() {
        let url = "https://mt1.google.com/vt/lyrs=m,traffic&x={x}&y={y}&z={z}"
        XCTAssertNil(CustomTileURLValidator.validate(url),
            "Valid XYZ URL should pass validation; got error")
    }

    func testValidWMTSURLPassesValidation() {
        let url = "https://tiles.example.com/{z}/{x}/{y}.png"
        XCTAssertNil(CustomTileURLValidator.validate(url),
            "Valid WMTS URL should pass validation; got error")
    }

    func testHTTPSchemePassesValidation() {
        let url = "http://tiles.local/{z}/{x}/{y}"
        XCTAssertNil(CustomTileURLValidator.validate(url),
            "http:// scheme should be accepted (LAN/offline servers)")
    }

    // MARK: - Validation: invalid URLs fail

    func testEmptyStringFailsValidation() {
        XCTAssertNotNil(CustomTileURLValidator.validate(""),
            "Empty string should fail validation")
    }

    func testMissingZPlaceholderFailsValidation() {
        let url = "https://tiles.example.com/{x}/{y}.png"
        XCTAssertNotNil(CustomTileURLValidator.validate(url),
            "URL missing {z} should fail validation")
    }

    func testMissingXPlaceholderFailsValidation() {
        let url = "https://tiles.example.com/{z}/{y}.png"
        XCTAssertNotNil(CustomTileURLValidator.validate(url),
            "URL missing {x} should fail validation")
    }

    func testMissingYPlaceholderFailsValidation() {
        let url = "https://tiles.example.com/{z}/{x}.png"
        XCTAssertNotNil(CustomTileURLValidator.validate(url),
            "URL missing {y} should fail validation")
    }

    func testNonHTTPSchemeFailsValidation() {
        let url = "ftp://tiles.example.com/{z}/{x}/{y}.png"
        XCTAssertNotNil(CustomTileURLValidator.validate(url),
            "Non-http/https scheme should fail validation")
    }

    func testPlainStringFailsValidation() {
        let url = "not a url"
        XCTAssertNotNil(CustomTileURLValidator.validate(url),
            "Non-URL string should fail validation")
    }

    // MARK: - ATAK placeholder normalization

    func testATAKStylePlaceholdersNormalized() {
        let ataStyle = "https://tiles.example.com/{$z}/{$x}/{$y}.png"
        let normalized = CustomTileURLValidator.normalize(ataStyle)
        XCTAssertEqual(normalized, "https://tiles.example.com/{z}/{x}/{y}.png",
            "ATAK {$z}/{$x}/{$y} placeholders must be normalized to {z}/{x}/{y}")
    }

    func testStandardPlaceholdersUnchanged() {
        let standard = "https://tiles.example.com/{z}/{x}/{y}.png"
        let normalized = CustomTileURLValidator.normalize(standard)
        XCTAssertEqual(normalized, standard,
            "Already-standard placeholders must not be mutated")
    }

    func testMixedPlaceholdersNormalized() {
        let mixed = "https://tiles.example.com/{$z}/{x}/{$y}.png"
        let normalized = CustomTileURLValidator.normalize(mixed)
        XCTAssertEqual(normalized, "https://tiles.example.com/{z}/{x}/{y}.png",
            "Mixed ATAK/standard placeholders must all normalize to standard form")
    }

    // MARK: - Tile URL interpolation

    func testRasterTileURLSubstitution() {
        let template = "https://mt1.google.com/vt/lyrs=m&x={x}&y={y}&z={z}"
        let result = CustomTileURLValidator.rasterTileURL(template, zoom: 12, x: 3456, y: 1789)
        XCTAssertEqual(result, "https://mt1.google.com/vt/lyrs=m&x=3456&y=1789&z=12",
            "Tile URL substitution must replace {x}/{y}/{z} with integer coordinates")
    }

    func testRasterTileURLZeroCoordinates() {
        let template = "https://tiles.example.com/{z}/{x}/{y}.png"
        let result = CustomTileURLValidator.rasterTileURL(template, zoom: 0, x: 0, y: 0)
        XCTAssertEqual(result, "https://tiles.example.com/0/0/0.png",
            "Zero-value tile coordinates must substitute correctly")
    }

    // MARK: - MapLibreStyle.custom

    func testCustomStyleRawValue() {
        XCTAssertEqual(MapLibreStyle.custom.rawValue, "Custom",
            "MapLibreStyle.custom rawValue must be 'Custom'")
    }

    func testCustomStyleIsInAllCases() {
        XCTAssertTrue(MapLibreStyle.allCases.contains(.custom),
            "MapLibreStyle.allCases must include .custom")
    }

    func testCustomStyleHasIcon() {
        let icon = MapLibreStyle.custom.icon
        XCTAssertFalse(icon.isEmpty, "MapLibreStyle.custom must have a non-empty SF Symbol icon")
    }
}
