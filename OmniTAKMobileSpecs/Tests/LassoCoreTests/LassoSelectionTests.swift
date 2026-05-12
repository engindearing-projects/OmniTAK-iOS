//
//  LassoSelectionTests.swift
//  OmniTAKMobileSpecs / LassoCoreTests
//
//  TDD spec for issue #16 — Lasso tool for fast multi-select.
//
//  These tests cover the pure point-in-polygon + selection logic that
//  backs the new lasso drawing tool. Geometry-only — no MapKit binding,
//  no UI, no MapLibre, so they run on the host (macOS) under
//  `swift test` without an iPhone Simulator.
//
//  Run from the package root:
//      cd OmniTAKMobileSpecs && swift test
//

import XCTest
import CoreLocation
@testable import LassoCore

final class LassoSelectionTests: XCTestCase {

    // MARK: - Helpers

    /// A simple closed square polygon centered on a SAR-relevant
    /// fictional coordinate near Spokane WA (the K9Blue SAR area), so
    /// the test data smells like the real world it will run in.
    private let squareCenter = CLLocationCoordinate2D(latitude: 47.6500, longitude: -117.4250)

    /// CCW square with ~0.01° side ≈ ~1.1 km — small enough that flat
    /// 2D point-in-polygon is faithful, big enough to make
    /// "exactly on edge" coordinates float-stable.
    private var unitSquare: [CLLocationCoordinate2D] {
        [
            CLLocationCoordinate2D(latitude: squareCenter.latitude - 0.005, longitude: squareCenter.longitude - 0.005),
            CLLocationCoordinate2D(latitude: squareCenter.latitude - 0.005, longitude: squareCenter.longitude + 0.005),
            CLLocationCoordinate2D(latitude: squareCenter.latitude + 0.005, longitude: squareCenter.longitude + 0.005),
            CLLocationCoordinate2D(latitude: squareCenter.latitude + 0.005, longitude: squareCenter.longitude - 0.005)
        ]
    }

    // MARK: - Headline test from the issue brief

    func testPointInLassoSelectsMarker() {
        let service = LassoSelectionService()

        // Marker dead-center inside the square.
        let insideMarker = LassoMarker(
            id: "inside-1",
            coordinate: squareCenter
        )

        // Marker well outside the square.
        let outsideMarker = LassoMarker(
            id: "outside-1",
            coordinate: CLLocationCoordinate2D(latitude: 47.7, longitude: -117.5)
        )

        let context = service.performLasso(
            polygon: unitSquare,
            markers: [insideMarker, outsideMarker],
            drawings: []
        )

        XCTAssertTrue(context.markerIDs.contains("inside-1"),
                      "Marker inside the closed polygon must be selected.")
        XCTAssertFalse(context.markerIDs.contains("outside-1"),
                       "Marker outside the closed polygon must NOT be selected.")
        XCTAssertEqual(context.totalCount, 1)
    }

    // MARK: - Edge cases

    func testEmptyPolygonSelectsNothing() {
        let service = LassoSelectionService()

        let marker = LassoMarker(id: "anywhere", coordinate: squareCenter)

        let twoPoints: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 1, longitude: 1)
        ]

        // 0 vertices.
        let empty = service.performLasso(polygon: [], markers: [marker], drawings: [])
        XCTAssertTrue(empty.isEmpty, "An empty polygon must select nothing.")

        // <3 vertices is not a polygon.
        let degenerate = service.performLasso(polygon: twoPoints, markers: [marker], drawings: [])
        XCTAssertTrue(degenerate.isEmpty, "A 2-vertex 'polygon' must select nothing.")
    }

    func testMarkerOnPolygonEdgeIsSelectedDeterministically() {
        // Markers that sit *exactly* on a polygon edge are an
        // implementation-defined edge case. We don't really care which
        // way the boundary tie-breaks as long as the answer is stable
        // and the *interior* is unambiguous.
        let service = LassoSelectionService()

        // Sits on the bottom edge of the square (lat = bottom, lon midway).
        let onEdge = LassoMarker(
            id: "on-edge",
            coordinate: CLLocationCoordinate2D(
                latitude: squareCenter.latitude - 0.005,
                longitude: squareCenter.longitude
            )
        )

        let a = service.performLasso(polygon: unitSquare, markers: [onEdge], drawings: [])
        let b = service.performLasso(polygon: unitSquare, markers: [onEdge], drawings: [])

        XCTAssertEqual(a.markerIDs, b.markerIDs,
                       "Edge-case selection must be deterministic across calls.")
    }

    // MARK: - Drawings (per issue: include drawings if centroid is inside)

    func testDrawingCentroidInsidePolygonSelectsDrawing() {
        let service = LassoSelectionService()

        // A short polyline whose centroid is the squareCenter.
        let lineInside = LassoDrawing(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            coordinates: [
                CLLocationCoordinate2D(latitude: squareCenter.latitude - 0.001, longitude: squareCenter.longitude - 0.001),
                CLLocationCoordinate2D(latitude: squareCenter.latitude + 0.001, longitude: squareCenter.longitude + 0.001)
            ]
        )

        // A polyline whose centroid is well outside the square.
        let lineOutside = LassoDrawing(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            coordinates: [
                CLLocationCoordinate2D(latitude: 47.8, longitude: -117.6),
                CLLocationCoordinate2D(latitude: 47.81, longitude: -117.61)
            ]
        )

        let context = service.performLasso(
            polygon: unitSquare,
            markers: [],
            drawings: [lineInside, lineOutside]
        )

        XCTAssertTrue(context.drawingIDs.contains(lineInside.id),
                      "Drawing with centroid inside the polygon must be selected.")
        XCTAssertFalse(context.drawingIDs.contains(lineOutside.id),
                       "Drawing with centroid outside the polygon must not be selected.")
    }

    // MARK: - Selection state survives — `SelectionContext` is identity-stable

    func testSelectionPersistsAcrossEmptyLasso() {
        // Per issue: "Selection state visible (highlight ring) and
        // survives map pans/zooms". Pans/zooms don't re-trigger the
        // lasso, but the *selection set* must not be cleared by a
        // no-op call.
        let service = LassoSelectionService()

        let m = LassoMarker(id: "keepme", coordinate: squareCenter)

        let first = service.performLasso(polygon: unitSquare, markers: [m], drawings: [])
        XCTAssertTrue(first.markerIDs.contains("keepme"))

        // performLasso is pure — it does NOT mutate previous results.
        // Existing selection lives on the service.
        service.applySelection(first)
        XCTAssertTrue(service.current.markerIDs.contains("keepme"))

        // A user starts a new lasso but lifts their finger immediately
        // (polygon < 3 points). That should NOT clear the existing
        // selection — only an explicit clear() does that.
        let noop = service.performLasso(polygon: [], markers: [m], drawings: [])
        XCTAssertTrue(noop.isEmpty)
        XCTAssertTrue(service.current.markerIDs.contains("keepme"),
                      "Existing selection must survive a no-op lasso attempt.")

        service.clear()
        XCTAssertTrue(service.current.isEmpty,
                      "Explicit clear() empties the selection.")
    }

    // MARK: - Convex / concave polygons both work

    func testConcavePolygonExcludesCarveOut() {
        // C-shaped polygon: a 0.02° wide square with a notch carved out
        // of the right side. A marker in the notch must NOT be selected
        // even though it lies inside the bounding box.
        let service = LassoSelectionService()

        let lat = 47.65
        let lon = -117.42
        let c: [CLLocationCoordinate2D] = [
            CLLocationCoordinate2D(latitude: lat - 0.01, longitude: lon - 0.01),
            CLLocationCoordinate2D(latitude: lat - 0.01, longitude: lon + 0.01),
            CLLocationCoordinate2D(latitude: lat - 0.003, longitude: lon + 0.01),
            CLLocationCoordinate2D(latitude: lat - 0.003, longitude: lon - 0.003),
            CLLocationCoordinate2D(latitude: lat + 0.003, longitude: lon - 0.003),
            CLLocationCoordinate2D(latitude: lat + 0.003, longitude: lon + 0.01),
            CLLocationCoordinate2D(latitude: lat + 0.01, longitude: lon + 0.01),
            CLLocationCoordinate2D(latitude: lat + 0.01, longitude: lon - 0.01)
        ]

        let inSolid = LassoMarker(
            id: "solid",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon - 0.008)
        )
        let inNotch = LassoMarker(
            id: "notch",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon + 0.005)
        )

        let context = service.performLasso(
            polygon: c,
            markers: [inSolid, inNotch],
            drawings: []
        )

        XCTAssertTrue(context.markerIDs.contains("solid"),
                      "Marker in the solid part of the C must be selected.")
        XCTAssertFalse(context.markerIDs.contains("notch"),
                       "Marker in the carved-out notch must NOT be selected.")
    }
}
