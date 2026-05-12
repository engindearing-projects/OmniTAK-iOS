//
//  LassoSelectionService.swift
//  OmniTAKMobile
//
//  Issue #16 — Lasso tool for fast multi-select.
//
//  Pure-logic point-in-polygon + selection state. The user freehand-
//  draws a closed polygon on the map; everything whose coordinate
//  (marker) or centroid (drawing) lies inside is selected. The
//  resulting `SelectionContext` is consumed by downstream features:
//      * issue #15 — data package authoring sheet
//      * bulk delete / bulk affiliation change / bulk export
//
//  Mirrored byte-for-byte in OmniTAKMobileSpecs/Sources/LassoCore/
//  so the failing→green TDD tests in LassoSelectionTests can run as a
//  host-side Swift Package without needing a Simulator unit-test
//  bundle (see release notes 2.18.0 — main project has no test
//  target).
//

import Foundation
import CoreLocation
import Combine

// MARK: - Selection participants

/// Lightweight DTO for a marker that the lasso may select. The app
/// adapts both server-pushed CoT units and locally-drawn `MarkerDrawing`
/// shapes into this minimal shape so the geometry layer doesn't have to
/// know about model details.
public struct LassoMarker: Hashable {
    public let id: String
    public let coordinate: CLLocationCoordinate2D

    public init(id: String, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.coordinate = coordinate
    }

    public static func == (lhs: LassoMarker, rhs: LassoMarker) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Lightweight DTO for a drawing (line / circle / polygon / route).
/// The lasso uses the arithmetic-mean centroid for inclusion testing
/// per the issue notes: "include if centroid is inside".
public struct LassoDrawing: Hashable {
    public let id: UUID
    public let coordinates: [CLLocationCoordinate2D]

    public init(id: UUID, coordinates: [CLLocationCoordinate2D]) {
        self.id = id
        self.coordinates = coordinates
    }

    public static func == (lhs: LassoDrawing, rhs: LassoDrawing) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Selection result

/// Identity-only selection set. Downstream features depend on this —
/// not on the concrete marker / drawing types — so a future change to
/// CoT or drawing models doesn't ripple.
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

/// Observable selection state. Long-lived: outlives any single lasso
/// draw, so the selection survives map pans/zooms / panel dismissals
/// per the issue's "selection state visible and survives" requirement.
public final class LassoSelectionService: ObservableObject {

    /// Singleton — UI surfaces (highlight rings, count pill, bulk
    /// actions) all bind to the same instance.
    public static let shared = LassoSelectionService()

    /// `true` while the user is actively dragging a lasso. The map
    /// view uses this to (a) suppress map-pan gestures and (b) draw
    /// the in-progress polyline.
    @Published public var isLassoing: Bool = false

    /// In-progress polygon vertices appended as the user drags. Empty
    /// once the gesture ends.
    @Published public var inProgressPolygon: [CLLocationCoordinate2D] = []

    /// Committed selection. Empty until the first successful lasso.
    @Published public private(set) var current: SelectionContext = SelectionContext()

    public init() {}

    // MARK: - Lasso lifecycle

    public func beginLasso() {
        isLassoing = true
        inProgressPolygon.removeAll()
    }

    public func appendVertex(_ coordinate: CLLocationCoordinate2D) {
        guard isLassoing else { return }
        // Skip near-duplicates to keep the polygon vertex count sane
        // on high-frequency gesture streams.
        if let last = inProgressPolygon.last {
            let dlat = abs(last.latitude - coordinate.latitude)
            let dlon = abs(last.longitude - coordinate.longitude)
            if dlat < 1e-7 && dlon < 1e-7 { return }
        }
        inProgressPolygon.append(coordinate)
    }

    /// Finalize the lasso: compute selection over the supplied
    /// populations, commit to `current`, and reset gesture state.
    @discardableResult
    public func endLasso(
        markers: [LassoMarker],
        drawings: [LassoDrawing]
    ) -> SelectionContext {
        let polygon = inProgressPolygon
        isLassoing = false
        inProgressPolygon.removeAll()
        let result = Self.performLasso(polygon: polygon, markers: markers, drawings: drawings)
        // Per issue: a no-op lasso (too few vertices) must NOT clear
        // an existing selection. Only an explicit clear() does that.
        if !result.isEmpty {
            current = result
        }
        return result
    }

    public func cancelLasso() {
        isLassoing = false
        inProgressPolygon.removeAll()
    }

    // MARK: - Selection mutation

    public func applySelection(_ context: SelectionContext) {
        current = context
    }

    public func clear() {
        current = SelectionContext()
    }

    /// Convenience used by per-marker tap-to-deselect.
    public func deselectMarker(id: String) {
        current.markerIDs.remove(id)
    }

    public func deselectDrawing(id: UUID) {
        current.drawingIDs.remove(id)
    }

    // MARK: - Pure geometry (test-visible)

    /// Pure: given a polygon and a population, return everything
    /// inside. No side effects on `current`.
    public static func performLasso(
        polygon: [CLLocationCoordinate2D],
        markers: [LassoMarker],
        drawings: [LassoDrawing]
    ) -> SelectionContext {
        guard polygon.count >= 3 else { return SelectionContext() }

        var markerIDs: Set<String> = []
        for m in markers where pointInPolygon(m.coordinate, polygon: polygon) {
            markerIDs.insert(m.id)
        }

        var drawingIDs: Set<UUID> = []
        for d in drawings {
            guard let centroid = centroid(of: d.coordinates) else { continue }
            if pointInPolygon(centroid, polygon: polygon) {
                drawingIDs.insert(d.id)
            }
        }

        return SelectionContext(markerIDs: markerIDs, drawingIDs: drawingIDs)
    }

    /// Ray-casting point-in-polygon (Franklin's PNPOLY). Treats
    /// latitude as Y, longitude as X (planar — fine at lasso scale;
    /// even a 10 km lasso doesn't accumulate enough curvature error
    /// to matter for "is this marker inside the squiggle the user
    /// just drew").
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

            let intersect = ((yi > y) != (yj > y)) &&
                (x < (xj - xi) * (y - yi) / (yj - yi) + xi)
            if intersect { inside.toggle() }

            j = i
        }
        return inside
    }

    /// Arithmetic-mean centroid — cheap and matches the issue's
    /// "drawing centroid inside" heuristic. Not area-weighted; that's
    /// a future-polish item ("any vertex inside" was mentioned as a
    /// configurable later).
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

// MARK: - Adapters

extension LassoMarker {
    /// Adapt a CoT-channel marker (server-pushed unit) for lasso
    /// inclusion testing. Internal because `CoTMarker` is internal —
    /// the public `LassoMarker` initializer is the cross-module entry
    /// point.
    init(cot: CoTMarker) {
        self.init(id: cot.uid, coordinate: cot.coordinate)
    }

    /// Adapt a locally-drawn marker.
    init(marker: MarkerDrawing) {
        self.init(id: marker.id.uuidString, coordinate: marker.coordinate)
    }

    /// Adapt a user-dropped point marker (PointDropperService).
    init(point: PointMarker) {
        self.init(id: point.id.uuidString, coordinate: point.coordinate)
    }
}
