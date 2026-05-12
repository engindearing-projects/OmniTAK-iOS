//
//  LassoSelectionService.swift  (LassoCore — test-only stub)
//
//  Pure-logic stub used by the OmniTAKMobileSpecs Swift Package to
//  drive TDD for the lasso multi-select feature (issue #16). The
//  *real* implementation lives at:
//      OmniTAKMobile/Features/Drawing/Services/LassoSelectionService.swift
//
//  Keeping a small copy here lets us run `swift test` on the host
//  without dragging the whole app target into the SPM build.
//
//  IMPORTANT: This file MUST stay byte-for-byte API-compatible with
//  the in-app implementation for the tests to be meaningful.
//

import Foundation
import CoreLocation

// MARK: - Selection participants

/// Lightweight protocol-free DTO for a marker that the lasso may
/// select. The real app passes in either a `CoTMarker` (server-pushed)
/// or a `MarkerDrawing` (user-drawn) by adapting them to this shape.
public struct LassoMarker {
    public let id: String
    public let coordinate: CLLocationCoordinate2D

    public init(id: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.coordinate = coordinate
    }
}

/// Lightweight DTO for a drawing (line / circle / polygon / route).
/// `coordinates` is the full vertex list of the drawing — the lasso
/// uses its centroid for inclusion testing per issue #16 notes.
public struct LassoDrawing {
    public let id: UUID
    public let coordinates: [CLLocationCoordinate2D]

    public init(id: UUID, coordinates: [CLLocationCoordinate2D]) {
        self.id = id
        self.coordinates = coordinates
    }
}

// MARK: - Selection result

/// Public, identity-only selection set. Downstream features (data
/// package builder #15, bulk delete) consume this; they do NOT depend
/// on the concrete marker/drawing types.
public struct SelectionContext: Equatable {
    public var markerIDs: Set<String>
    public var drawingIDs: Set<UUID>

    public init(markerIDs: Set<String> = [], drawingIDs: Set<UUID> = []) {
        self.markerIDs = markerIDs
        self.drawingIDs = drawingIDs
    }

    public var totalCount: Int { markerIDs.count + drawingIDs.count }
    public var isEmpty: Bool { markerIDs.isEmpty && drawingIDs.isEmpty }
}

// MARK: - Service

public final class LassoSelectionService {

    public private(set) var current: SelectionContext = SelectionContext()

    public init() {}

    /// Pure, no-side-effects: given a lasso polygon and a population
    /// of map features, return everything inside. Does not mutate
    /// `current` — call `applySelection(_:)` to commit.
    public func performLasso(
        polygon: [CLLocationCoordinate2D],
        markers: [LassoMarker],
        drawings: [LassoDrawing]
    ) -> SelectionContext {
        // A polygon needs at least 3 vertices to enclose any area.
        // A degenerate "polygon" (0, 1, 2 points) selects nothing.
        guard polygon.count >= 3 else { return SelectionContext() }

        var markerIDs: Set<String> = []
        for m in markers where Self.pointInPolygon(m.coordinate, polygon: polygon) {
            markerIDs.insert(m.id)
        }

        var drawingIDs: Set<UUID> = []
        for d in drawings {
            guard let centroid = Self.centroid(of: d.coordinates) else { continue }
            if Self.pointInPolygon(centroid, polygon: polygon) {
                drawingIDs.insert(d.id)
            }
        }

        return SelectionContext(markerIDs: markerIDs, drawingIDs: drawingIDs)
    }

    public func applySelection(_ context: SelectionContext) {
        current = context
    }

    public func clear() {
        current = SelectionContext()
    }

    // MARK: - Geometry primitives (test-visible)

    /// Standard ray-casting point-in-polygon. Treats latitude as Y and
    /// longitude as X (planar — fine for lasso-scale regions: even a
    /// 10 km lasso is well under the Earth-curvature threshold where
    /// great-circle math would matter for selection accuracy).
    ///
    /// Algorithm: cast a horizontal ray east from `point` and count
    /// edge crossings. Odd = inside, even = outside.
    public static func pointInPolygon(
        _ point: CLLocationCoordinate2D,
        polygon: [CLLocationCoordinate2D]
    ) -> Bool {
        guard polygon.count >= 3 else { return false }

        let x = point.longitude
        let y = point.latitude

        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let xi = polygon[i].longitude
            let yi = polygon[i].latitude
            let xj = polygon[j].longitude
            let yj = polygon[j].latitude

            // Standard ray-casting edge crossing test. The classic
            // formulation from Franklin's PNPOLY — well-trodden, tied
            // out for decades.
            let intersect = ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            if intersect { inside.toggle() }

            j = i
        }
        return inside
    }

    /// Simple arithmetic-mean centroid. Good enough for lasso
    /// inclusion testing; not a true area-weighted centroid, but
    /// matches the issue brief's "drawing centroid inside" heuristic
    /// and is cheap.
    public static func centroid(of coordinates: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        guard !coordinates.isEmpty else { return nil }
        var sumLat: Double = 0
        var sumLon: Double = 0
        for c in coordinates {
            sumLat += c.latitude
            sumLon += c.longitude
        }
        let n = Double(coordinates.count)
        return CLLocationCoordinate2D(latitude: sumLat / n, longitude: sumLon / n)
    }
}
