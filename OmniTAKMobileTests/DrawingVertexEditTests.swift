//
//  DrawingVertexEditTests.swift
//  OmniTAKMobileTests
//
//  Regression tests for the drawing vertex-edit geometry (issue #84 —
//  follow-up to the move/reposition work in #81). Where move rigidly
//  translates the whole shape, vertex editing moves a single point: replacing
//  vertex `i` of a line/polygon with a dragged coordinate, or resizing a circle
//  by dragging its radius handle. These tests pin that math plus the
//  nearest-vertex hit-test and the edit-session bookkeeping that Cancel relies
//  on. All geometry is engine-agnostic, so both the 2D Mapbox and 3D Cesium
//  drag paths share exactly this logic.
//

import XCTest
import CoreLocation
@testable import OmniTAK

final class DrawingVertexEditTests: XCTestCase {

    private let eps = 1e-9

    // MARK: - Replace a single vertex (line / polygon)

    func testLineReplacingVertexMovesOnlyThatVertex() {
        let line = LineDrawing(
            name: "L", color: .red,
            coordinates: [
                CLLocationCoordinate2D(latitude: 1, longitude: 1),
                CLLocationCoordinate2D(latitude: 2, longitude: 3),
                CLLocationCoordinate2D(latitude: -4, longitude: 5)
            ]
        )
        let newPoint = CLLocationCoordinate2D(latitude: 9, longitude: 9)
        let edited = line.replacingVertex(at: 1, with: newPoint)
        // Same count, identity preserved.
        XCTAssertEqual(edited.coordinates.count, 3)
        XCTAssertEqual(edited.id, line.id)
        // Only vertex 1 changed.
        XCTAssertEqual(edited.coordinates[0].latitude, 1, accuracy: eps)
        XCTAssertEqual(edited.coordinates[0].longitude, 1, accuracy: eps)
        XCTAssertEqual(edited.coordinates[1].latitude, 9, accuracy: eps)
        XCTAssertEqual(edited.coordinates[1].longitude, 9, accuracy: eps)
        XCTAssertEqual(edited.coordinates[2].latitude, -4, accuracy: eps)
        XCTAssertEqual(edited.coordinates[2].longitude, 5, accuracy: eps)
    }

    func testPolygonReplacingVertexMovesOnlyThatVertex() {
        let poly = PolygonDrawing(
            name: "P", color: .green,
            coordinates: [
                CLLocationCoordinate2D(latitude: 0, longitude: 0),
                CLLocationCoordinate2D(latitude: 0, longitude: 1),
                CLLocationCoordinate2D(latitude: 1, longitude: 1)
            ]
        )
        let newPoint = CLLocationCoordinate2D(latitude: 5, longitude: 6)
        let edited = poly.replacingVertex(at: 2, with: newPoint)
        XCTAssertEqual(edited.coordinates.count, 3)
        XCTAssertEqual(edited.id, poly.id)
        XCTAssertEqual(edited.coordinates[0].latitude, 0, accuracy: eps)
        XCTAssertEqual(edited.coordinates[1].longitude, 1, accuracy: eps)
        XCTAssertEqual(edited.coordinates[2].latitude, 5, accuracy: eps)
        XCTAssertEqual(edited.coordinates[2].longitude, 6, accuracy: eps)
    }

    func testReplacingVertexOutOfRangeIsNoOp() {
        // Defensive: an index that vanished (e.g. a concurrent edit) must not
        // crash — it returns the shape unchanged.
        let line = LineDrawing(
            name: "L", color: .red,
            coordinates: [
                CLLocationCoordinate2D(latitude: 1, longitude: 1),
                CLLocationCoordinate2D(latitude: 2, longitude: 2)
            ]
        )
        let p = CLLocationCoordinate2D(latitude: 9, longitude: 9)
        let editedHigh = line.replacingVertex(at: 5, with: p)
        let editedNeg = line.replacingVertex(at: -1, with: p)
        for edited in [editedHigh, editedNeg] {
            XCTAssertEqual(edited.coordinates.count, 2)
            XCTAssertEqual(edited.coordinates[0].latitude, 1, accuracy: eps)
            XCTAssertEqual(edited.coordinates[1].latitude, 2, accuracy: eps)
        }
    }

    // MARK: - Circle radius handle

    func testCircleRadiusHandleCoordinateIsRadiusMetersDueEast() {
        // The radius handle sits due-east of the center at exactly `radius`
        // metres, so dragging it resizes the circle. Round-tripping the handle
        // back to a radius must recover the original distance.
        let circle = CircleDrawing(
            name: "C", color: .blue,
            center: CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3),
            radius: 500
        )
        let handle = circle.radiusHandleCoordinate
        // Handle is east of center (greater longitude, same-ish latitude).
        XCTAssertGreaterThan(handle.longitude, circle.center.longitude)
        XCTAssertEqual(handle.latitude, circle.center.latitude, accuracy: 1e-6,
                       "due-east handle stays on the same parallel")
        // Distance from center to handle ≈ radius.
        XCTAssertEqual(circle.center.distance(to: handle), 500, accuracy: 1.0)
    }

    func testCircleResizingFromEdgePointUpdatesRadius() {
        let center = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let circle = CircleDrawing(name: "C", color: .blue, center: center, radius: 100)
        // Drag the handle to a point ~1000 m away; radius should follow.
        let dragged = center.offset(latDelta: 0, lonDelta: 0.01) // ~1.11 km east at equator
        let resized = circle.resized(toEdgePoint: dragged)
        XCTAssertEqual(resized.center.latitude, center.latitude, accuracy: eps,
                       "resize keeps the center fixed")
        XCTAssertEqual(resized.center.longitude, center.longitude, accuracy: eps)
        XCTAssertEqual(resized.radius, center.distance(to: dragged), accuracy: 1.0)
        XCTAssertGreaterThan(resized.radius, 1000)
        XCTAssertEqual(resized.id, circle.id)
    }

    func testCircleResizeClampsToMinimumRadius() {
        // Dragging the handle onto the center must not collapse the circle to a
        // zero/degenerate radius — it clamps to a small positive floor.
        let center = CLLocationCoordinate2D(latitude: 10, longitude: 10)
        let circle = CircleDrawing(name: "C", color: .blue, center: center, radius: 250)
        let resized = circle.resized(toEdgePoint: center)
        XCTAssertGreaterThan(resized.radius, 0, "radius must stay positive")
    }

    // MARK: - Nearest-vertex hit test (shared by both engines)

    func testNearestVertexPicksTheClosestWithinThreshold() {
        let verts = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
            CLLocationCoordinate2D(latitude: 1, longitude: 1)
        ]
        // A touch right next to vertex 1.
        let touch = CLLocationCoordinate2D(latitude: 0.0001, longitude: 1.0001)
        let idx = DrawingVertexHitTest.nearestVertexIndex(
            in: verts, to: touch, withinMeters: 10_000
        )
        XCTAssertEqual(idx, 1)
    }

    func testNearestVertexReturnsNilWhenNoneWithinThreshold() {
        let verts = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 1)
        ]
        // A touch far from every vertex with a tight threshold.
        let touch = CLLocationCoordinate2D(latitude: 50, longitude: 50)
        let idx = DrawingVertexHitTest.nearestVertexIndex(
            in: verts, to: touch, withinMeters: 100
        )
        XCTAssertNil(idx)
    }

    func testNearestVertexBreaksTiesToTheNearer() {
        let verts = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),   // far
            CLLocationCoordinate2D(latitude: 0, longitude: 0.5), // nearer
            CLLocationCoordinate2D(latitude: 0, longitude: 0.6)  // nearest
        ]
        let touch = CLLocationCoordinate2D(latitude: 0, longitude: 0.59)
        let idx = DrawingVertexHitTest.nearestVertexIndex(
            in: verts, to: touch, withinMeters: 1_000_000
        )
        XCTAssertEqual(idx, 2)
    }

    func testNearestVertexEmptyIsNil() {
        let idx = DrawingVertexHitTest.nearestVertexIndex(
            in: [], to: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            withinMeters: 1000
        )
        XCTAssertNil(idx)
    }

    // MARK: - Vertex-edit session bookkeeping

    @MainActor
    func testVertexEditSessionLifecycle() {
        let session = DrawingVertexEditSession()
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(session.originalCoordinates.isEmpty)
        XCTAssertNil(session.activeVertexIndex)

        let id = UUID()
        let original = [
            CLLocationCoordinate2D(latitude: 1, longitude: 2),
            CLLocationCoordinate2D(latitude: 3, longitude: 4),
            CLLocationCoordinate2D(latitude: 5, longitude: 6)
        ]
        session.begin(id: id, type: .polygon, label: "Poly 1", originalCoordinates: original)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.drawingId, id)
        XCTAssertEqual(session.drawingType, .polygon)
        XCTAssertEqual(session.label, "Poly 1")
        XCTAssertEqual(session.originalCoordinates.count, 3)

        // A drag grabs a specific vertex, then releases it.
        session.setActiveVertex(1)
        XCTAssertEqual(session.activeVertexIndex, 1)
        session.setActiveVertex(nil)
        XCTAssertNil(session.activeVertexIndex)

        session.end()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.drawingId)
        XCTAssertNil(session.drawingType)
        XCTAssertTrue(session.originalCoordinates.isEmpty)
        XCTAssertNil(session.activeVertexIndex)
    }

    @MainActor
    func testVertexEditSessionCircleHandleVertex() {
        // For a circle the editable "vertices" are [center, radiusHandle]; the
        // session carries that pair so the engines can render both handles and
        // Cancel can restore the exact original radius.
        let session = DrawingVertexEditSession()
        let id = UUID()
        let center = CLLocationCoordinate2D(latitude: 47.6, longitude: -122.3)
        let circle = CircleDrawing(name: "C", color: .blue, center: center, radius: 400)
        session.begin(id: id, type: .circle, label: "Circle 1",
                      originalCoordinates: [circle.center, circle.radiusHandleCoordinate])
        XCTAssertEqual(session.originalCoordinates.count, 2)
        XCTAssertEqual(session.originalCoordinates[0].latitude, center.latitude, accuracy: eps)
        // The second handle is the radius point, ~400 m east.
        XCTAssertEqual(center.distance(to: session.originalCoordinates[1]), 400, accuracy: 1.0)
        session.end()
    }
}
