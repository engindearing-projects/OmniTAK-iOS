//
//  CesiumCameraSeedTests.swift
//  OmniTAKMobileTests
//
//  Regression tests for the 2D→3D camera handoff (issue #62).
//
//  Root cause: when the operator switches from Mapbox 2D to the Cesium globe
//  the bridge-ready handler ignored the persisted 2D camera (mapRegion) and
//  either flew to the ADSB search center or to the last Cesium pose. If the
//  operator had never opened the globe before — or was looking at a region
//  far from their GPS position — the globe opened somewhere else.
//
//  Fix: CesiumMainMap accepts an optional `cameraSeed` (MKCoordinateRegion).
//  When the seed is present and no meaningful Cesium pose has been saved
//  (cesium.lastLat/.lastLon are still at the KJFK defaults), the bridge-ready
//  handler converts the region to a Cesium height and calls setCamera (instant
//  top-down setView, no animation) before any flyTo. The 3D→2D direction already
//  worked: Cesium camera-changed events mirror into mapRegion (MVC line ~1820).
//
//  These tests exercise the two pure functions that underpin the fix:
//    - CesiumCameraMath.heightForRegion(_:)  — latitudeDelta → metres AGL
//    - CesiumCameraMath.seedJS(for:bearing:) — region + bearing → JS call string
//  Both can run without a simulator (no UIKit, no WKWebView).
//

import XCTest
import MapKit
import CoreLocation
@testable import OmniTAK

final class CesiumCameraSeedTests: XCTestCase {

    // Tolerance used for floating-point comparisons.
    private let eps = 1e-3

    // MARK: - heightForRegion

    // The conversion must be the exact inverse of the JS _zoomFromHeight formula
    // used in cesium_scene.html (line 122):
    //
    //   zoom = log2(40_075_017 * cos(lat) / max(h * 256 / 1000, 1))
    //
    // And of the mirror in handleCesiumMapEvent (MapViewController.swift ~1817):
    //
    //   metersVisible = 1.15 * height
    //   latDelta = metersVisible / 111_320
    //
    // The inverse is:  height = latDelta * 111_320 / 1.15
    // This test pins that contract so height ↔ latDelta stay consistent
    // across future edits to either side.

    func testHeightForRegionAtEquator() {
        // latDelta = 0.1° ≈ 11_132 m visible; expected height ≈ 9680 m
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
        let h = CesiumCameraMath.heightForRegion(region)
        let expected = 0.1 * 111_320.0 / 1.15
        XCTAssertEqual(h, expected, accuracy: 1.0)   // within 1 m
    }

    func testHeightForRegionAtMidLatitude() {
        // San Francisco latitude — cos scaling should not affect height
        // because we derive height from latitudeDelta, which is already
        // in degrees of latitude (not projected metres).
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
        let h = CesiumCameraMath.heightForRegion(region)
        let expected = 0.5 * 111_320.0 / 1.15
        XCTAssertEqual(h, expected, accuracy: 1.0)
    }

    func testHeightClampsAboveMinimum() {
        // A very tight zoom (latDelta = 0) should clamp, not produce 0 or negative.
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1),
            span: MKCoordinateSpan(latitudeDelta: 0, longitudeDelta: 0)
        )
        let h = CesiumCameraMath.heightForRegion(region)
        XCTAssertGreaterThanOrEqual(h, 50.0, "height must not be less than the 50 m floor")
    }

    func testHeightClampsAtWorldView() {
        // A world-scale zoom should not exceed the Cesium bootstrap ceiling.
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 180, longitudeDelta: 360)
        )
        let h = CesiumCameraMath.heightForRegion(region)
        XCTAssertLessThanOrEqual(h, 20_000_000.0, "world-view height must not exceed 20 000 km")
    }

    // Round-trip: convert latDelta → height → latDelta should be identity
    // (within floating-point noise) when using the same formulas both ways.
    func testRoundTripLatDeltaHeightLatDelta() {
        let originalDelta = 0.25
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321),
            span: MKCoordinateSpan(latitudeDelta: originalDelta, longitudeDelta: originalDelta)
        )
        let h = CesiumCameraMath.heightForRegion(region)
        // Inverse: metersVisible = 1.15 * h; latDelta = metersVisible / 111_320
        let roundTripped = (1.15 * h) / 111_320.0
        XCTAssertEqual(roundTripped, originalDelta, accuracy: eps,
                       "height ↔ latDelta round-trip must be stable")
    }

    // MARK: - seedJS

    // seedJS must produce a well-formed OmniBridge.setCamera(…) call whose
    // lat, lon, height, heading, and pitch values round-trip from the region.

    func testSeedJSContainsCenter() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.3382, longitude: -121.8863),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
        let js = CesiumCameraMath.seedJS(for: region, bearing: 0)
        XCTAssertTrue(js.hasPrefix("window.OmniBridge.setCamera("),
                      "call must target setCamera on OmniBridge")
        XCTAssertTrue(js.contains("37.3382"), "lat must appear in the JS")
        XCTAssertTrue(js.contains("-121.8863"), "lon must appear in the JS")
    }

    func testSeedJSPitchIsTopDown() {
        // Top-down pitch is −90 (straight down), matching the 2D map perspective.
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
        let js = CesiumCameraMath.seedJS(for: region, bearing: 0)
        XCTAssertTrue(js.contains("pitch:-90"),
                      "seeded pitch must be −90 (top-down) to match 2D map perspective")
    }

    func testSeedJSPassesBearing() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060),
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        )
        let bearing = 45.0
        let js = CesiumCameraMath.seedJS(for: region, bearing: bearing)
        XCTAssertTrue(js.contains("heading:45.0") || js.contains("heading:45"),
                      "bearing must be forwarded as the Cesium heading")
    }

    func testSeedJSHeightIsPositive() {
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1),
            span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)
        )
        let js = CesiumCameraMath.seedJS(for: region, bearing: 0)
        // Extract the height value — it appears as height:<number>
        // We just verify it exists and contains a plausible positive number.
        XCTAssertTrue(js.contains("height:"),
                      "JS must include a height parameter")
        // The height for latDelta=0.2 is ~19,360 m — definitely > 100
        let heightRange = js.range(of: #"height:(\d+)"#, options: .regularExpression)
        XCTAssertNotNil(heightRange, "height must be a positive integer (no minus sign)")
    }
}
