//
//  GeofenceMapShape.swift
//  OmniTAKMobile
//
//  What both map engines draw for a geofence, and the small rules the "new geofence" form
//  uses. Pure, so they are tested without a map or a screen.
//

import Foundation
import CoreLocation
import UIKit

// MARK: - What the maps draw

/// One geofence as the maps draw it: an outline in the geofence's color, a light fill, and
/// its name. Only geofences that are switched on and have a shape get one.
struct GeofenceMapShape {
    enum Geometry {
        case circle(center: CLLocationCoordinate2D, radius: CLLocationDistance)
        case polygon([CLLocationCoordinate2D])
    }

    /// Starts with this on both engines so a geofence can never collide with a drawing's id
    /// (`geofence-<uuid>`), and so a tap on one is never taken for a drawing.
    static let idPrefix = "geofence-"

    /// The fill is light enough to read the map through.
    static let fillAlpha: Double = 0.12

    let id: String
    let name: String
    let color: GeofenceColor
    let geometry: Geometry
    /// Where the name is written: on the north edge of a circle, so a marker at its middle (the
    /// operator's own, when a geofence is made around him) never covers it; at the mean of a
    /// polygon's corners.
    let labelCoordinate: CLLocationCoordinate2D

    /// The shapes to draw for these geofences, in the same order. Switched-off ones, and
    /// ones without a usable shape, are left out.
    static func shapes(from geofences: [Geofence]) -> [GeofenceMapShape] {
        geofences.compactMap { geofence in
            guard geofence.isActive, geofence.hasUsableShape,
                  let middle = geofence.centerCoordinate else { return nil }
            let geometry: Geometry
            let label: CLLocationCoordinate2D
            switch geofence.type {
            case .circle:
                guard let center = geofence.center, let radius = geofence.radius else { return nil }
                geometry = .circle(center: center, radius: radius)
                label = circleRing(center: center, radius: radius, segments: 4)[0]
            case .polygon:
                guard let coordinates = geofence.polygonCoordinates else { return nil }
                geometry = .polygon(coordinates)
                label = middle
            }
            return GeofenceMapShape(id: idPrefix + geofence.id.uuidString, name: geofence.name,
                                    color: geofence.color, geometry: geometry, labelCoordinate: label)
        }
    }

    /// The outline as a closed ring: a polygon's corners with the first repeated, a circle as
    /// `segments` points around it.
    func ring(circleSegments segments: Int = 64) -> [CLLocationCoordinate2D] {
        switch geometry {
        case .polygon(let corners):
            guard let first = corners.first else { return [] }
            return corners + [first]
        case .circle(let center, let radius):
            return GeofenceMapShape.circleRing(center: center, radius: radius, segments: segments)
        }
    }

    /// `segments` points on a circle of `radius` metres around `center`, the first one due north,
    /// then the first point again to close it.
    static func circleRing(center: CLLocationCoordinate2D,
                           radius: CLLocationDistance,
                           segments: Int) -> [CLLocationCoordinate2D] {
        let earthRadius = 6_371_008.8
        let angular = radius / earthRadius
        let lat1 = center.latitude * .pi / 180
        let lon1 = center.longitude * .pi / 180
        var ring: [CLLocationCoordinate2D] = []
        for i in 0..<max(segments, 3) {
            let bearing = 2 * Double.pi * Double(i) / Double(max(segments, 3))
            let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
            let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1),
                                    cos(angular) - sin(lat1) * sin(lat2))
            ring.append(CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi))
        }
        if let first = ring.first { ring.append(first) }
        return ring
    }
}

// MARK: - The new geofence form

enum GeofenceForm {
    /// The radius a circle at the map center can have: a slider walks this list, so the steps
    /// are small where a small zone needs them and wide where a large one does.
    static let radiusChoices: [Double] = [
        50, 75, 100, 150, 200, 250, 300, 400, 500, 750,
        1_000, 1_500, 2_000, 2_500, 3_000, 4_000, 5_000
    ]

    /// What the slider starts on.
    static let defaultRadius: Double = 200

    /// The choice nearest to `meters`.
    static func nearestRadius(to meters: Double) -> Double {
        radiusChoices.min(by: { abs($0 - meters) < abs($1 - meters) }) ?? defaultRadius
    }

    /// A radius in the operator's units: "200 m", "1.5 km", "660 ft", "0.62 mi".
    static func radiusLabel(meters: Double, unitSystem: UnitSystem) -> String {
        switch unitSystem {
        case .metric:
            if meters < 1_000 { return "\(Int(meters.rounded())) m" }
            return "\(trimmed(meters / 1_000)) km"
        case .imperial:
            let feet = meters * 3.280839895
            if meters < 800 { return "\(Int((feet / 10).rounded()) * 10) ft" }
            return "\(trimmed(meters / 1_609.344, decimals: 2)) mi"
        }
    }

    private static func trimmed(_ value: Double, decimals: Int = 1) -> String {
        var text = String(format: "%.\(decimals)f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The name offered for a new geofence, "Geofence 1", "Geofence 2", and so on: the
    /// lowest number not taken yet, so Save never waits on a name.
    static func defaultName(existing: [String], template: String) -> String {
        let taken = Set(existing)
        var number = 1
        while taken.contains(String(format: template, number)) { number += 1 }
        return String(format: template, number)
    }
}

// MARK: - A geofence from a drawing

extension GeofenceDrawingSource {
    /// A geofence with this drawing's shape. The shape is copied, so moving, reshaping or
    /// deleting the drawing afterwards leaves the geofence where it is.
    func makeGeofence(name: String,
                      color: GeofenceColor,
                      alertOnEntry: Bool,
                      alertOnExit: Bool,
                      dwellTimeThreshold: TimeInterval,
                      watchSelf: Bool,
                      watchContacts: Bool) -> Geofence {
        Geofence(name: name,
                 type: type,
                 color: color,
                 alertOnEntry: alertOnEntry,
                 alertOnExit: alertOnExit,
                 dwellTimeThreshold: dwellTimeThreshold,
                 watchSelf: watchSelf,
                 watchContacts: watchContacts,
                 center: center,
                 radius: radius,
                 polygonCoordinates: coordinates)
    }
}

// MARK: - Show on map

extension Geofence {
    /// How far the shape reaches from its center: a circle's radius, a polygon's farthest corner.
    /// nil for a geofence with no shape to show.
    var extent: CLLocationDistance? {
        guard hasUsableShape, let middle = centerCoordinate else { return nil }
        switch type {
        case .circle:
            return radius
        case .polygon:
            let from = CLLocation(latitude: middle.latitude, longitude: middle.longitude)
            return polygonCoordinates?
                .map { from.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude)) }
                .max()
        }
    }
}

/// How "Show on map" frames a geofence on both engines: the whole shape, with room around it,
/// seen from straight above, whichever way the phone is held.
enum GeofenceFraming {
    /// Never closer than this many metres across the screen, so a small geofence still shows
    /// the streets around it.
    static let narrowestView: Double = 600
    /// The shape takes a third of the width of the screen.
    static let viewsPerExtent: Double = 6
    /// The flat map's world tile is 512 points wide.
    static let tileWidth: Double = 512

    /// Metres across the screen for a shape that reaches `extent` metres from its center.
    static func viewWidth(forExtent extent: CLLocationDistance) -> Double {
        max(narrowestView, extent * viewsPerExtent)
    }

    /// The longitude span the flat map is given to show `viewWidth` metres across a screen that is
    /// `screenWidth` points wide. (The map takes the span of one 512 point tile, which is wider than
    /// the screen.)
    static func longitudeSpan(viewWidth: Double, latitude: CLLocationDegrees, screenWidth: Double) -> CLLocationDegrees {
        let metersPerDegree = 111_320 * max(cos(latitude * .pi / 180), 0.01)
        return viewWidth / (max(screenWidth, 1) / tileWidth * metersPerDegree)
    }

    /// Points across the screen as it is held now.
    @MainActor
    static var screenWidth: Double {
        let widths = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }
        return Double(widths.first ?? 402)
    }
}
