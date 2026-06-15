//
//  LassoLineSelectTests.swift
//  OmniTAKMobileTests
//
//  Regression coverage for lasso-selecting line/polygon drawings. The
//  original selection test only included a drawing when its arithmetic
//  centroid fell inside the lasso, which silently missed lines: a line
//  drawn across the map was never selected unless the lasso happened to
//  enclose its midpoint. These tests pin the "contained, overlapped, or
//  crossed" behavior.
//

import XCTest
import CoreLocation
@testable import OmniTAK

final class LassoLineSelectTests: XCTestCase {

    private func c(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// THE BUG: a long horizontal line, lassoed by a small box over its
    /// left portion. Both endpoints (lon ±10) are outside the box and the
    /// centroid (0,0) is outside too — the old centroid-only test missed
    /// it. The line still crosses the box, so it must be selected now.
    func testLineCrossingLassoSelectedEvenWhenCentroidOutside() {
        let line = LassoDrawing(id: UUID(), coordinates: [c(0, -10), c(0, 10)])
        let box = [c(-1, -8), c(1, -8), c(1, -6), c(-1, -6)] // lat[-1,1] lon[-8,-6]
        let result = LassoSelectionService.performLasso(polygon: box, markers: [], drawings: [line])
        XCTAssertTrue(
            result.drawingIDs.contains(line.id),
            "A line crossing the lasso must be selected even when its centroid is outside")
    }

    /// Regression guard: the original centroid-inside heuristic still works.
    func testLineSelectedWhenCentroidInside() {
        let line = LassoDrawing(id: UUID(), coordinates: [c(0, -2), c(0, 2)])
        let box = [c(-1, -3), c(1, -3), c(1, 3), c(-1, 3)]
        let result = LassoSelectionService.performLasso(polygon: box, markers: [], drawings: [line])
        XCTAssertTrue(result.drawingIDs.contains(line.id))
    }

    /// A single endpoint inside the lasso is enough to select.
    func testLineSelectedWhenEndpointInside() {
        let line = LassoDrawing(id: UUID(), coordinates: [c(0, -10), c(0, 10)])
        let box = [c(-1, 8), c(1, 8), c(1, 12), c(-1, 12)] // contains the +10 end
        let result = LassoSelectionService.performLasso(polygon: box, markers: [], drawings: [line])
        XCTAssertTrue(result.drawingIDs.contains(line.id))
    }

    /// No false positives: a line well clear of the lasso is not selected.
    func testLineFarFromLassoNotSelected() {
        let line = LassoDrawing(id: UUID(), coordinates: [c(0, -10), c(0, -8)])
        let box = [c(20, 20), c(21, 20), c(21, 21), c(20, 21)]
        let result = LassoSelectionService.performLasso(polygon: box, markers: [], drawings: [line])
        XCTAssertFalse(result.drawingIDs.contains(line.id))
    }

    /// Direct check of the segment-intersection primitive.
    func testSegmentsIntersect() {
        // A vertical and a horizontal segment that cross at the origin.
        XCTAssertTrue(LassoSelectionService.segmentsIntersect(
            c(-1, 0), c(1, 0), c(0, -1), c(0, 1)))
        // Two far-apart segments do not cross.
        XCTAssertFalse(LassoSelectionService.segmentsIntersect(
            c(0, -1), c(0, 1), c(5, 5), c(6, 6)))
    }
}
