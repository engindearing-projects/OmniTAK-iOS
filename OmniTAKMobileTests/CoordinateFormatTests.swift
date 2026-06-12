//
//  CoordinateFormatTests.swift
//  OmniTAKMobileTests
//
//  Regression tests for CoordinateDisplayFormat.format() — the single
//  conversion path used by the self-position chip (PR #58) and the radial-
//  menu copy/get-info actions (PR #69).
//
//  Reference coordinate: Taipei 101 (25.033971, 121.564504).
//  TWD97 values derived from TWD97Converter.project() — we call the
//  converter directly rather than hardcoding to stay in sync with
//  any future precision changes.
//

import XCTest
import CoreLocation
@testable import OmniTAK

final class CoordinateFormatTests: XCTestCase {

    // Taipei 101: well-known anchor inside TWD97 bounds and MGRS coverage.
    let taipei101 = CLLocationCoordinate2D(latitude: 25.033971, longitude: 121.564504)

    // MARK: - CoordinateDisplayFormat.format() per-case

    func testDecimalDegreesFormat() {
        let result = CoordinateDisplayFormat.decimalDegrees.format(taipei101)
        // Expected: "25.033971, 121.564504"
        XCTAssertTrue(result.contains("25.03"), "DD: should contain lat prefix; got \(result)")
        XCTAssertTrue(result.contains("121.56"), "DD: should contain lon prefix; got \(result)")
        XCTAssertFalse(result.contains("°"), "DD: must not contain degree symbol; got \(result)")
    }

    func testDegreesMinutesFormat() {
        let result = CoordinateDisplayFormat.degreesMinutes.format(taipei101)
        // Expected format: "25°02.0383'N 121°33.8702'E"
        XCTAssertTrue(result.contains("N"), "DM: should contain N hemisphere; got \(result)")
        XCTAssertTrue(result.contains("E"), "DM: should contain E hemisphere; got \(result)")
        XCTAssertTrue(result.contains("°"), "DM: should contain degree symbol; got \(result)")
        XCTAssertTrue(result.contains("'"), "DM: should contain minute symbol; got \(result)")
        XCTAssertFalse(result.contains("\""), "DM: must not contain seconds symbol; got \(result)")
    }

    func testDegreesMinutesSecondsFormat() {
        let result = CoordinateDisplayFormat.degreesMinutesSeconds.format(taipei101)
        // Expected format: "25°02'02.30"N 121°33'52.21"E"
        XCTAssertTrue(result.contains("N"), "DMS: should contain N hemisphere; got \(result)")
        XCTAssertTrue(result.contains("E"), "DMS: should contain E hemisphere; got \(result)")
        XCTAssertTrue(result.contains("°"), "DMS: should contain degree symbol; got \(result)")
        XCTAssertTrue(result.contains("'"), "DMS: should contain minute symbol; got \(result)")
        XCTAssertTrue(result.contains("\""), "DMS: should contain seconds symbol; got \(result)")
    }

    func testMGRSFormat() {
        let result = CoordinateDisplayFormat.mgrs.format(taipei101)
        // Taipei 101 falls in MGRS zone 51R — starts with "51R"
        XCTAssertTrue(result.hasPrefix("51R"), "MGRS: expected zone 51R prefix; got \(result)")
        XCTAssertFalse(result.isEmpty, "MGRS: result must not be empty")
    }

    func testUTMFormat() {
        let result = CoordinateDisplayFormat.utm.format(taipei101)
        // UTM zone 51 N for Taipei
        XCTAssertTrue(result.contains("51"), "UTM: should contain zone 51; got \(result)")
        XCTAssertFalse(result.isEmpty, "UTM: result must not be empty")
    }

    func testTWD97Format() {
        let result = CoordinateDisplayFormat.twd97.format(taipei101)
        // TWD97 Taipei 101 — project to get expected values from the converter
        // so the test is authoritative against the app's own math, not a
        // hardcoded external reference.
        let (easting, northing) = TWD97Converter.project(taipei101)
        let expectedE = String(format: "%07d", Int(easting.rounded()))
        let expectedN = String(format: "%07d", Int(northing.rounded()))

        XCTAssertTrue(result.contains(expectedE),
            "TWD97: easting \(expectedE) not found in \(result)")
        XCTAssertTrue(result.contains(expectedN),
            "TWD97: northing \(expectedN) not found in \(result)")

        // Sanity: Taipei 101 is within TWD97 bounds so must not be the error string
        XCTAssertNotEqual(result, "Out of TWD97 bounds",
            "TWD97: Taipei 101 must be within TWD97 bounds")
    }

    // MARK: - UserDefaults key wiring (simulates radial-menu call path)

    /// Verifies that CoordinateDisplayFormat can be round-tripped through
    /// UserDefaults — the exact mechanism the fixed formatCoordinate() uses.
    func testUserDefaultsKeyRoundTrip() {
        let key = "coordinateDisplayFormat"
        let originalValue = UserDefaults.standard.string(forKey: key)
        defer {
            // Restore whatever was there before
            if let orig = originalValue {
                UserDefaults.standard.set(orig, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        for format in CoordinateDisplayFormat.allCases {
            UserDefaults.standard.set(format.rawValue, forKey: key)
            let stored = UserDefaults.standard.string(forKey: key)
            let parsed = stored.flatMap { CoordinateDisplayFormat(rawValue: $0) }
            XCTAssertEqual(parsed, format,
                "UserDefaults round-trip failed for format \(format.rawValue)")
        }
    }

    /// Verifies missing / unknown key falls back gracefully — no crash and
    /// a non-empty string.  This mirrors the fallback in formatCoordinate().
    func testMissingKeyFallback() {
        // Simulate a completely unknown raw value (as if the key was never written).
        let formatString = ""
        let format = CoordinateDisplayFormat(rawValue: formatString) ?? .degreesMinutesSeconds
        XCTAssertEqual(format, .degreesMinutesSeconds,
            "Empty string should fall back to DMS")

        let result = format.format(taipei101)
        XCTAssertFalse(result.isEmpty, "Fallback DMS must produce non-empty output")
        // DMS output contains degree, minute and second symbols
        XCTAssertTrue(result.contains("°") && result.contains("'") && result.contains("\""),
            "Fallback DMS must be in DMS format; got \(result)")
    }
}
