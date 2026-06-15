import Foundation
import MapKit
import CoreLocation
import SwiftUI

// MARK: - Drawing Protocol

protocol DrawingObject: Identifiable, Codable {
    var id: UUID { get }
    var name: String { get set }
    var color: DrawingColor { get set }
    var createdAt: Date { get }
    var coordinates: [CLLocationCoordinate2D] { get }

    func createOverlay() -> MKOverlay
}

// MARK: - Drawing Mode

enum DrawingMode: String, CaseIterable {
    case marker = "Marker"
    case line = "Line"
    case circle = "Circle"
    case polygon = "Polygon"
    // Issue #16 — lasso lives in the drawing-tools cluster alongside
    // marker / line / circle / polygon. It doesn't *create* a shape;
    // it selects existing features inside the dragged region.
    case lasso = "Lasso"

    var icon: String {
        switch self {
        case .marker: return "mappin.circle.fill"
        case .line: return "line.diagonal"
        case .circle: return "circle"
        case .polygon: return "pentagon"
        case .lasso: return "lasso"
        }
    }

    var displayName: String {
        switch self {
        case .marker: return "Marker"
        case .line: return "Line/Polyline"
        case .circle: return "Circle"
        case .polygon: return "Polygon"
        case .lasso: return "Lasso (multi-select)"
        }
    }
}

// MARK: - Drawing Color

enum DrawingColor: String, CaseIterable, Codable {
    case red = "Red"
    case blue = "Blue"
    case green = "Green"
    case yellow = "Yellow"
    case orange = "Orange"
    case purple = "Purple"
    case cyan = "Cyan"
    case white = "White"

    var uiColor: UIColor {
        switch self {
        case .red: return .systemRed
        case .blue: return .systemBlue
        case .green: return .systemGreen
        case .yellow: return .systemYellow
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .cyan: return .systemCyan
        case .white: return .white
        }
    }

    var swiftUIColor: Color {
        switch self {
        case .red: return .red
        case .blue: return .blue
        case .green: return .green
        case .yellow: return .yellow
        case .orange: return .orange
        case .purple: return .purple
        case .cyan: return .cyan
        case .white: return .white
        }
    }
}

// MARK: - Marker Drawing

struct MarkerDrawing: DrawingObject {
    let id: UUID
    var name: String
    var label: String  // User-editable label for marker
    var color: DrawingColor
    let createdAt: Date
    // `var` so a placed marker can be repositioned (issue #60 move/reposition
    // follow-up). The reposition flow rigidly translates the coordinate and
    // persists it through DrawingStore.updateMarker(_:).
    var coordinate: CLLocationCoordinate2D

    var coordinates: [CLLocationCoordinate2D] {
        [coordinate]
    }

    init(id: UUID = UUID(), name: String, label: String? = nil, color: DrawingColor, coordinate: CLLocationCoordinate2D) {
        self.id = id
        self.name = name
        self.label = label ?? name  // Default label to name if not provided
        self.color = color
        self.createdAt = Date()
        self.coordinate = coordinate
    }

    func createOverlay() -> MKOverlay {
        // Markers don't use overlays, they use annotations
        // Return a small circle for compatibility
        return MKCircle(center: coordinate, radius: 1)
    }

    // Codable conformance
    enum CodingKeys: String, CodingKey {
        case id, name, label, color, createdAt, latitude, longitude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        // Backwards compatibility - if label doesn't exist, use name
        label = (try? container.decode(String.self, forKey: .label)) ?? name
        color = try container.decode(DrawingColor.self, forKey: .color)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        let lat = try container.decode(Double.self, forKey: .latitude)
        let lon = try container.decode(Double.self, forKey: .longitude)
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(label, forKey: .label)
        try container.encode(color, forKey: .color)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(coordinate.latitude, forKey: .latitude)
        try container.encode(coordinate.longitude, forKey: .longitude)
    }
}

// MARK: - Line Drawing (Polyline)

struct LineDrawing: DrawingObject {
    let id: UUID
    var name: String
    var label: String  // User-editable label
    var color: DrawingColor
    let createdAt: Date
    var coordinates: [CLLocationCoordinate2D]

    init(id: UUID = UUID(), name: String, label: String? = nil, color: DrawingColor, coordinates: [CLLocationCoordinate2D]) {
        self.id = id
        self.name = name
        self.label = label ?? name
        self.color = color
        self.createdAt = Date()
        self.coordinates = coordinates
    }

    func createOverlay() -> MKOverlay {
        return MKPolyline(coordinates: coordinates, count: coordinates.count)
    }

    // Codable conformance
    enum CodingKeys: String, CodingKey {
        case id, name, label, color, createdAt, points
    }

    struct CoordinatePair: Codable {
        let latitude: Double
        let longitude: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        label = (try? container.decode(String.self, forKey: .label)) ?? name
        color = try container.decode(DrawingColor.self, forKey: .color)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        let points = try container.decode([CoordinatePair].self, forKey: .points)
        coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(label, forKey: .label)
        try container.encode(color, forKey: .color)
        try container.encode(createdAt, forKey: .createdAt)
        let points = coordinates.map { CoordinatePair(latitude: $0.latitude, longitude: $0.longitude) }
        try container.encode(points, forKey: .points)
    }
}

// MARK: - Circle Drawing

struct CircleDrawing: DrawingObject {
    let id: UUID
    var name: String
    var label: String  // User-editable label
    var color: DrawingColor
    let createdAt: Date
    // `var` so a placed circle can be repositioned (issue #60 move/reposition
    // follow-up) — move translates the center; radius is unchanged.
    var center: CLLocationCoordinate2D
    var radius: CLLocationDistance

    var coordinates: [CLLocationCoordinate2D] {
        [center]
    }

    init(id: UUID = UUID(), name: String, label: String? = nil, color: DrawingColor, center: CLLocationCoordinate2D, radius: CLLocationDistance) {
        self.id = id
        self.name = name
        self.label = label ?? name
        self.color = color
        self.createdAt = Date()
        self.center = center
        self.radius = radius
    }

    func createOverlay() -> MKOverlay {
        return MKCircle(center: center, radius: radius)
    }

    // Codable conformance
    enum CodingKeys: String, CodingKey {
        case id, name, label, color, createdAt, latitude, longitude, radius
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        label = (try? container.decode(String.self, forKey: .label)) ?? name
        color = try container.decode(DrawingColor.self, forKey: .color)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        let lat = try container.decode(Double.self, forKey: .latitude)
        let lon = try container.decode(Double.self, forKey: .longitude)
        center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        radius = try container.decode(CLLocationDistance.self, forKey: .radius)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(label, forKey: .label)
        try container.encode(color, forKey: .color)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(center.latitude, forKey: .latitude)
        try container.encode(center.longitude, forKey: .longitude)
        try container.encode(radius, forKey: .radius)
    }
}

// MARK: - Polygon Drawing

struct PolygonDrawing: DrawingObject {
    let id: UUID
    var name: String
    var label: String  // User-editable label
    var color: DrawingColor
    let createdAt: Date
    var coordinates: [CLLocationCoordinate2D]

    init(id: UUID = UUID(), name: String, label: String? = nil, color: DrawingColor, coordinates: [CLLocationCoordinate2D]) {
        self.id = id
        self.name = name
        self.label = label ?? name
        self.color = color
        self.createdAt = Date()
        self.coordinates = coordinates
    }

    func createOverlay() -> MKOverlay {
        return MKPolygon(coordinates: coordinates, count: coordinates.count)
    }

    // Codable conformance
    enum CodingKeys: String, CodingKey {
        case id, name, label, color, createdAt, points
    }

    struct CoordinatePair: Codable {
        let latitude: Double
        let longitude: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        label = (try? container.decode(String.self, forKey: .label)) ?? name
        color = try container.decode(DrawingColor.self, forKey: .color)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        let points = try container.decode([CoordinatePair].self, forKey: .points)
        coordinates = points.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(label, forKey: .label)
        try container.encode(color, forKey: .color)
        try container.encode(createdAt, forKey: .createdAt)
        let points = coordinates.map { CoordinatePair(latitude: $0.latitude, longitude: $0.longitude) }
        try container.encode(points, forKey: .points)
    }
}

// MARK: - CLLocationCoordinate2D Extensions

// Helper function to calculate distance between two coordinates
extension CLLocationCoordinate2D {
    func distance(to coordinate: CLLocationCoordinate2D) -> CLLocationDistance {
        let from = CLLocation(latitude: self.latitude, longitude: self.longitude)
        let to = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return from.distance(from: to)
    }

    /// Offset this coordinate by a degree delta. Used by the drawing
    /// reposition flow to rigidly translate a whole shape by the same
    /// (latΔ, lonΔ) the operator dragged. Longitude wraps across the
    /// antimeridian; latitude is clamped to the poles.
    func offset(latDelta: CLLocationDegrees, lonDelta: CLLocationDegrees) -> CLLocationCoordinate2D {
        var lon = longitude + lonDelta
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        let lat = max(-90, min(90, latitude + latDelta))
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Rigid Translate (issue #60 — move/reposition follow-up)

// Each drawing type can be rigidly translated by a degree delta — every
// vertex (or the circle center / marker point) shifts by the same offset,
// so the shape's geometry is preserved exactly and only its position moves.
// Mirrors Android's DrawingMoveOverlay rigid-translate behavior.

extension MarkerDrawing {
    func translated(latDelta: CLLocationDegrees, lonDelta: CLLocationDegrees) -> MarkerDrawing {
        var copy = self
        copy.coordinate = coordinate.offset(latDelta: latDelta, lonDelta: lonDelta)
        return copy
    }
}

extension LineDrawing {
    func translated(latDelta: CLLocationDegrees, lonDelta: CLLocationDegrees) -> LineDrawing {
        var copy = self
        copy.coordinates = coordinates.map { $0.offset(latDelta: latDelta, lonDelta: lonDelta) }
        return copy
    }
}

extension PolygonDrawing {
    func translated(latDelta: CLLocationDegrees, lonDelta: CLLocationDegrees) -> PolygonDrawing {
        var copy = self
        copy.coordinates = coordinates.map { $0.offset(latDelta: latDelta, lonDelta: lonDelta) }
        return copy
    }
}

extension CircleDrawing {
    func translated(latDelta: CLLocationDegrees, lonDelta: CLLocationDegrees) -> CircleDrawing {
        var copy = self
        copy.center = center.offset(latDelta: latDelta, lonDelta: lonDelta)
        return copy
    }
}

// Restore-from-snapshot helpers — used by the move Cancel path to put a
// shape's geometry back exactly as it was when Move began (see
// DrawingMoveSession.originalCoordinates), independent of any clamping or
// antimeridian wrap the drag applied.

extension MarkerDrawing {
    func with(coordinate: CLLocationCoordinate2D) -> MarkerDrawing {
        var copy = self; copy.coordinate = coordinate; return copy
    }
}

extension LineDrawing {
    func with(coordinates: [CLLocationCoordinate2D]) -> LineDrawing {
        var copy = self; copy.coordinates = coordinates; return copy
    }
}

extension PolygonDrawing {
    func with(coordinates: [CLLocationCoordinate2D]) -> PolygonDrawing {
        var copy = self; copy.coordinates = coordinates; return copy
    }
}

extension CircleDrawing {
    func with(center: CLLocationCoordinate2D) -> CircleDrawing {
        var copy = self; copy.center = center; return copy
    }
}

// MARK: - Drawing Move Session (issue #60 — move/reposition follow-up)

/// Drives "reposition mode" for a single placed drawing, shared by both the
/// 2D Mapbox and 3D Cesium engines so the move UX is identical on each. The
/// operator enters it from the drawing radial menu's **Move** action; while
/// active the map camera is locked and a single-finger drag rigidly
/// translates the whole shape. A committed move persists the new geometry to
/// the DrawingStore; cancel restores the original.
final class DrawingMoveSession: ObservableObject {
    /// True while the operator is repositioning a shape — engines lock the
    /// camera and capture the drag, and the move HUD shows.
    @Published private(set) var isActive: Bool = false
    /// The shape being moved.
    @Published private(set) var drawingId: UUID?
    @Published private(set) var drawingType: RadialMenuContext.DrawingType?
    /// Human-readable name for the move HUD ("Move <label>").
    @Published private(set) var label: String = ""

    /// The shape's exact geometry at the moment Move was entered. Cancel
    /// restores this verbatim rather than reversing accumulated drag deltas —
    /// so a move that clamped at a pole or crossed the antimeridian still
    /// returns the shape precisely to where it started. For a circle this is
    /// `[center]`; for a marker `[point]`; for a line/polygon every vertex.
    private(set) var originalCoordinates: [CLLocationCoordinate2D] = []

    /// Begin repositioning the given drawing, snapshotting its starting
    /// geometry so Cancel can restore it exactly.
    func begin(id: UUID, type: RadialMenuContext.DrawingType, label: String,
               originalCoordinates: [CLLocationCoordinate2D]) {
        drawingId = id
        drawingType = type
        self.label = label
        self.originalCoordinates = originalCoordinates
        isActive = true
    }

    /// End the session (commit or after the caller has reverted). Clears state.
    func end() {
        isActive = false
        drawingId = nil
        drawingType = nil
        label = ""
        originalCoordinates = []
    }
}
