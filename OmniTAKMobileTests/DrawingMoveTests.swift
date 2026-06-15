//
//  DrawingMoveTests.swift
//  OmniTAKMobileTests
//
//  Regression tests for the drawing move/reposition geometry (issue #60
//  follow-up). The reposition flow rigidly translates a placed shape by a
//  (latΔ, lonΔ) degree delta — every vertex (or the circle center / marker
//  point) shifts by the same offset, so the shape's geometry is preserved and
//  only its position changes. These tests pin that math + the move-session
//  bookkeeping that Cancel relies on.
//

import XCTest
import CoreLocation
@testable import OmniTAK

final class DrawingMoveTests: XCTestCase {

    private let eps = 1e-9

    // MARK: - Coordinate offset

    func testCoordinateOffsetAddsDelta() {
        let c = CLLocationCoordinate2D(latitude: 40.0, longitude: -73.0)
        let moved = c.offset(latDelta: 0.5, lonDelta: -0.25)
        XCTAssertEqual(moved.latitude, 40.5, accuracy: eps)
        XCTAssertEqual(moved.longitude, -73.25, accuracy: eps)
    }

    func testCoordinateOffsetClampsLatitudeToPole() {
        let c = CLLocationCoordinate2D(latitude: 89.9, longitude: 10.0)
        let moved = c.offset(latDelta: 5.0, lonDelta: 0)
        XCTAssertEqual(moved.latitude, 90.0, accuracy: eps, "latitude must clamp at the pole")
    }

    func testCoordinateOffsetWrapsLongitudeAcrossAntimeridian() {
        let c = CLLocationCoordinate2D(latitude: 0, longitude: 179.0)
        let moved = c.offset(latDelta: 0, lonDelta: 3.0)   // 182 → wraps to -178
        XCTAssertEqual(moved.longitude, -178.0, accuracy: 1e-6)
    }

    // MARK: - Rigid translate per shape

    func testLineTranslateShiftsEveryVertexEqually() {
        let line = LineDrawing(
            name: "L", color: .red,
            coordinates: [
                CLLocationCoordinate2D(latitude: 1, longitude: 1),
                CLLocationCoordinate2D(latitude: 2, longitude: 3),
                CLLocationCoordinate2D(latitude: -4, longitude: 5)
            ]
        )
        let moved = line.translated(latDelta: 0.1, lonDelta: -0.2)
        XCTAssertEqual(moved.coordinates.count, line.coordinates.count)
        for (orig, new) in zip(line.coordinates, moved.coordinates) {
            XCTAssertEqual(new.latitude - orig.latitude, 0.1, accuracy: 1e-9)
            XCTAssertEqual(new.longitude - orig.longitude, -0.2, accuracy: 1e-9)
        }
        // Identity preserved — same shape, new position.
        XCTAssertEqual(moved.id, line.id)
    }

    func testPolygonTranslatePreservesShape() {
        let poly = PolygonDrawing(
            name: "P", color: .green,
            coordinates: [
                CLLocationCoordinate2D(latitude: 0, longitude: 0),
                CLLocationCoordinate2D(latitude: 0, longitude: 1),
                CLLocationCoordinate2D(latitude: 1, longitude: 1)
            ]
        )
        let moved = poly.translated(latDelta: 10, lonDelta: 20)
        // Pairwise edge vectors are unchanged → rigid translation, not a warp.
        for i in 0..<poly.coordinates.count {
            let j = (i + 1) % poly.coordinates.count
            let origEdgeLat = poly.coordinates[j].latitude - poly.coordinates[i].latitude
            let newEdgeLat = moved.coordinates[j].latitude - moved.coordinates[i].latitude
            XCTAssertEqual(origEdgeLat, newEdgeLat, accuracy: 1e-9)
        }
        XCTAssertEqual(moved.id, poly.id)
    }

    func testCircleTranslateMovesCenterKeepsRadius() {
        let circle = CircleDrawing(
            name: "C", color: .blue,
            center: CLLocationCoordinate2D(latitude: 5, longitude: 5),
            radius: 250
        )
        let moved = circle.translated(latDelta: -1, lonDelta: 2)
        XCTAssertEqual(moved.center.latitude, 4, accuracy: 1e-9)
        XCTAssertEqual(moved.center.longitude, 7, accuracy: 1e-9)
        XCTAssertEqual(moved.radius, 250, accuracy: 1e-9, "radius must be unchanged by a move")
        XCTAssertEqual(moved.id, circle.id)
    }

    func testMarkerTranslateMovesPoint() {
        let marker = MarkerDrawing(
            name: "M", color: .yellow,
            coordinate: CLLocationCoordinate2D(latitude: 12, longitude: -8)
        )
        let moved = marker.translated(latDelta: 0.3, lonDelta: 0.4)
        XCTAssertEqual(moved.coordinate.latitude, 12.3, accuracy: 1e-9)
        XCTAssertEqual(moved.coordinate.longitude, -7.6, accuracy: 1e-9)
        XCTAssertEqual(moved.id, marker.id)
    }

    func testTranslateThenReverseRestoresOriginal() {
        // The Cancel path applies the negated net delta; it must land back
        // exactly on the starting geometry.
        let line = LineDrawing(
            name: "L", color: .orange,
            coordinates: [
                CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33),
                CLLocationCoordinate2D(latitude: 47.62, longitude: -122.31)
            ]
        )
        let moved = line.translated(latDelta: 0.05, lonDelta: -0.07)
        let restored = moved.translated(latDelta: -0.05, lonDelta: 0.07)
        for (orig, back) in zip(line.coordinates, restored.coordinates) {
            XCTAssertEqual(back.latitude, orig.latitude, accuracy: 1e-9)
            XCTAssertEqual(back.longitude, orig.longitude, accuracy: 1e-9)
        }
    }

    func testWithCoordinatesRestoresSnapshotExactly() {
        // The Cancel path writes the snapshot back verbatim via `with(...)`.
        let original = [
            CLLocationCoordinate2D(latitude: 47.61, longitude: -122.33),
            CLLocationCoordinate2D(latitude: 47.62, longitude: -122.31)
        ]
        let line = LineDrawing(name: "L", color: .red, coordinates: original)
        // Simulate a drag that moved it, then restore from the snapshot.
        let moved = line.translated(latDelta: 0.5, lonDelta: 0.5)
        let restored = moved.with(coordinates: original)
        for (orig, back) in zip(original, restored.coordinates) {
            XCTAssertEqual(back.latitude, orig.latitude, accuracy: eps)
            XCTAssertEqual(back.longitude, orig.longitude, accuracy: eps)
        }
        XCTAssertEqual(restored.id, line.id)
    }

    func testCircleWithCenterKeepsRadius() {
        let circle = CircleDrawing(
            name: "C", color: .blue,
            center: CLLocationCoordinate2D(latitude: 5, longitude: 5),
            radius: 250
        )
        let restored = circle.with(center: CLLocationCoordinate2D(latitude: 1, longitude: 2))
        XCTAssertEqual(restored.center.latitude, 1, accuracy: eps)
        XCTAssertEqual(restored.radius, 250, accuracy: eps)
    }

    func testSnapshotCancelRestoresExactlyEvenAfterPoleClamp() {
        // A move that clamps at the pole loses information for a delta-reverse,
        // but the snapshot-based Cancel restores the exact original anyway.
        let line = LineDrawing(
            name: "L", color: .red,
            coordinates: [
                CLLocationCoordinate2D(latitude: 89.9, longitude: 10),
                CLLocationCoordinate2D(latitude: 88.0, longitude: 11)
            ]
        )
        let original = line.coordinates
        let moved = line.translated(latDelta: 5, lonDelta: 0) // first vertex clamps at 90
        XCTAssertEqual(moved.coordinates[0].latitude, 90, accuracy: eps)
        let restored = moved.with(coordinates: original)
        for (orig, back) in zip(original, restored.coordinates) {
            XCTAssertEqual(back.latitude, orig.latitude, accuracy: eps)
            XCTAssertEqual(back.longitude, orig.longitude, accuracy: eps)
        }
    }

    // MARK: - Move session bookkeeping

    @MainActor
    func testMoveSessionLifecycle() {
        let session = DrawingMoveSession()
        XCTAssertFalse(session.isActive)
        XCTAssertTrue(session.originalCoordinates.isEmpty)

        let id = UUID()
        let original = [
            CLLocationCoordinate2D(latitude: 1, longitude: 2),
            CLLocationCoordinate2D(latitude: 3, longitude: 4)
        ]
        session.begin(id: id, type: .line, label: "Line 1", originalCoordinates: original)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.drawingId, id)
        XCTAssertEqual(session.drawingType, .line)
        XCTAssertEqual(session.label, "Line 1")
        XCTAssertEqual(session.originalCoordinates.count, 2)
        XCTAssertEqual(session.originalCoordinates[0].latitude, 1, accuracy: eps)

        session.end()
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.drawingId)
        XCTAssertNil(session.drawingType)
        XCTAssertTrue(session.originalCoordinates.isEmpty)
    }
}
