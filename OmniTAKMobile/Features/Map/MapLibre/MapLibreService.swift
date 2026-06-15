//
//  MapLibreService.swift
//  OmniTAKMobile
//
//  Service layer for the Mapbox Maps SDK v3 (native).
//  Class/struct/enum names are preserved (MapLibre*) so existing call sites
//  keep compiling; a rename PR can follow once the engine swap is verified.
//

import Foundation
import MapboxMaps
import CoreLocation
import SwiftUI
import UIKit

// MARK: - Map Service

class MapLibreService: ObservableObject {
    static let shared = MapLibreService()

    @Published var isMapLoaded = false
    @Published var is3DEnabled = false
    @Published var terrainExaggeration: Double = 1.5
    @Published var currentStyle: MapLibreStyle = .standard
    @Published var showBuildings = true

    weak var mapView: MapView?

    var currentStyleURL: URL? { currentStyle.url }

    // MARK: - Terrain & Atmosphere

    func configureTerrain(for _: Any? = nil) {
        guard let mapView else { return }
        guard is3DEnabled else { removeTerrain(from: nil); return }

        do {
            if !mapView.mapboxMap.sourceExists(withId: "mapbox-dem") {
                var source = RasterDemSource(id: "mapbox-dem")
                source.url = "mapbox://mapbox.mapbox-terrain-dem-v1"
                source.tileSize = 514
                source.maxzoom = 14.0
                try mapView.mapboxMap.addSource(source)
            }

            var terrain = Terrain(sourceId: "mapbox-dem")
            terrain.exaggeration = .constant(terrainExaggeration)
            try mapView.mapboxMap.setTerrain(terrain)

            var atmosphere = Atmosphere()
            atmosphere.color = .constant(StyleColor(red: 0, green: 128, blue: 255, alpha: 1.0)!)
            atmosphere.highColor = .constant(StyleColor(red: 25, green: 77, blue: 179, alpha: 1.0)!)
            atmosphere.horizonBlend = .constant(0.1)
            atmosphere.spaceColor = .constant(StyleColor(red: 0, green: 0, blue: 13, alpha: 1.0)!)
            atmosphere.starIntensity = .constant(0.15)
            try mapView.mapboxMap.setAtmosphere(atmosphere)
        } catch {
            print("MapLibreService: failed to configure terrain — \(error)")
        }
    }

    func removeTerrain(from _: Any? = nil) {
        guard let mapView else { return }
        mapView.mapboxMap.removeTerrain()
        try? mapView.mapboxMap.removeAtmosphere()
    }

    // MARK: - Camera

    func set3DMode(enabled: Bool) {
        is3DEnabled = enabled
        guard let mapView else { return }
        let camera = CameraOptions(pitch: enabled ? 60 : 0)
        mapView.camera.ease(to: camera, duration: 0.5)
        if enabled {
            configureTerrain()
        } else {
            removeTerrain()
        }
    }

    func setTerrainExaggeration(_ value: Double) {
        terrainExaggeration = value
        if is3DEnabled { configureTerrain() }
    }

    func setCameraPitch(_ pitch: Double) {
        guard let mapView else { return }
        let clamped = CGFloat(min(85, max(0, pitch)))
        mapView.camera.ease(to: CameraOptions(pitch: clamped), duration: 0.25)
    }

    func setCameraBearing(_ bearing: Double) {
        guard let mapView else { return }
        mapView.camera.ease(to: CameraOptions(bearing: bearing), duration: 0.25)
    }

    func flyTo(coordinate: CLLocationCoordinate2D,
               zoom: Double? = nil,
               pitch: Double? = nil,
               bearing: Double? = nil,
               duration: TimeInterval = 2.0) {
        guard let mapView else { return }
        let current = mapView.mapboxMap.cameraState
        let opts = CameraOptions(
            center: coordinate,
            zoom: zoom ?? current.zoom,
            bearing: bearing ?? current.bearing,
            pitch: pitch.map { CGFloat($0) } ?? current.pitch
        )
        mapView.camera.fly(to: opts, duration: duration)
    }

    func resetCamera() {
        guard let mapView else { return }
        let current = mapView.mapboxMap.cameraState
        let opts = CameraOptions(center: current.center, zoom: current.zoom, bearing: 0, pitch: 0)
        mapView.camera.fly(to: opts, duration: 0.5)
    }

    // MARK: - Style

    func setStyle(_ style: MapLibreStyle) {
        currentStyle = style
        guard let mapView else { return }
        mapView.mapboxMap.loadStyle(style.styleURI) { [weak self] _ in
            if self?.is3DEnabled == true {
                self?.configureTerrain()
            }
        }
    }

    // MARK: - Annotations

    private var pointManager: PointAnnotationManager?
    private var lineManager: PolylineAnnotationManager?

    private func ensurePointManager() -> PointAnnotationManager? {
        if let m = pointManager { return m }
        guard let mapView else { return nil }
        let m = mapView.annotations.makePointAnnotationManager()
        pointManager = m
        return m
    }

    private func ensureLineManager() -> PolylineAnnotationManager? {
        if let m = lineManager { return m }
        guard let mapView else { return nil }
        let m = mapView.annotations.makePolylineAnnotationManager()
        lineManager = m
        return m
    }

    @discardableResult
    func addMarker(at coordinate: CLLocationCoordinate2D,
                   title: String?,
                   icon: UIImage? = nil) -> PointAnnotation? {
        guard let manager = ensurePointManager() else { return nil }
        var annotation = PointAnnotation(coordinate: coordinate)
        if let icon {
            annotation.image = .init(image: icon, name: title ?? UUID().uuidString)
        }
        annotation.textField = title
        manager.annotations.append(annotation)
        return annotation
    }

    func removeMarker(_ annotation: PointAnnotation) {
        pointManager?.annotations.removeAll { $0.id == annotation.id }
    }

    func removeAllMarkers() {
        pointManager?.annotations = []
    }

    @discardableResult
    func addRoute(coordinates: [CLLocationCoordinate2D],
                  color: UIColor = .systemBlue,
                  lineWidth: CGFloat = 4) -> PolylineAnnotation? {
        guard let manager = ensureLineManager() else { return nil }
        var annotation = PolylineAnnotation(lineCoordinates: coordinates)
        annotation.lineColor = StyleColor(color)
        annotation.lineWidth = Double(lineWidth)
        manager.annotations.append(annotation)
        return annotation
    }
}

// MARK: - Map Styles

enum MapLibreStyle: String, CaseIterable, Identifiable {
    case standard  = "Standard"   // Mapbox Standard — 3D buildings + atmosphere + lighting
    case streets   = "Streets"
    case outdoors  = "Outdoors"
    case satellite = "Satellite"
    case dark      = "Dark"
    case light     = "Light"
    /// Custom XYZ/WMTS tile URL supplied by the operator in Settings.
    /// The tile URL template is stored in UserDefaults under
    /// "customTileURL" and loaded by the 2D engine on style activation.
    case custom    = "Custom"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .standard:  return "globe.americas.fill"
        case .streets:   return "map.fill"
        case .outdoors:  return "mountain.2.fill"
        case .satellite: return "globe"
        case .dark:      return "moon.fill"
        case .light:     return "sun.max.fill"
        case .custom:    return "link.circle.fill"
        }
    }

    /// StyleURI for Mapbox-hosted styles. `.custom` returns `.streets` as
    /// the initial load target — the TacticalMapView coordinator then overlays
    /// the custom RasterSource on top once the base style finishes loading.
    var styleURI: StyleURI {
        switch self {
        case .standard:  return .standard
        case .streets:   return .streets
        case .outdoors:  return .outdoors
        case .satellite: return .satelliteStreets
        case .dark:      return .dark
        case .light:     return .light
        case .custom:    return .streets   // base; custom layer added post-load
        }
    }

    var url: URL? { URL(string: styleURI.rawValue) }

    // Backwards-compat aliases for legacy OpenFreeMap style names.
    static let liberty:  MapLibreStyle = .standard
    static let bright:   MapLibreStyle = .outdoors
    static let positron: MapLibreStyle = .light
}

// MARK: - Custom Tile URL Validator

/// Pure utility — no MapView dependency — so it can be unit-tested in isolation.
///
/// Accepts XYZ tile URL templates with `{z}`, `{x}`, `{y}` placeholders
/// (canonical) and ATAK-style `{$z}`, `{$x}`, `{$y}` variants.
/// Only `http://` and `https://` schemes are accepted.
struct CustomTileURLValidator {

    /// Normalise ATAK-style `{$z}/{$x}/{$y}` placeholders to the canonical
    /// `{z}/{x}/{y}` form expected by the Mapbox raster-source tiles array.
    static func normalize(_ urlTemplate: String) -> String {
        urlTemplate
            .replacingOccurrences(of: "{$z}", with: "{z}")
            .replacingOccurrences(of: "{$x}", with: "{x}")
            .replacingOccurrences(of: "{$y}", with: "{y}")
    }

    /// Returns `nil` if the template is valid, or a human-readable error string.
    static func validate(_ urlTemplate: String) -> String? {
        guard !urlTemplate.isEmpty else { return "URL must not be empty." }
        let normalized = normalize(urlTemplate)
        guard normalized.hasPrefix("http://") || normalized.hasPrefix("https://") else {
            return "URL must use http:// or https://."
        }
        guard normalized.contains("{z}") else { return "URL must contain {z} placeholder." }
        guard normalized.contains("{x}") else { return "URL must contain {x} placeholder." }
        guard normalized.contains("{y}") else { return "URL must contain {y} placeholder." }
        return nil
    }

    /// Substitute real tile coordinates into a validated (and already-normalised)
    /// template. Returns the concrete tile URL string.
    static func rasterTileURL(_ template: String, zoom: Int, x: Int, y: Int) -> String {
        template
            .replacingOccurrences(of: "{z}", with: "\(zoom)")
            .replacingOccurrences(of: "{x}", with: "\(x)")
            .replacingOccurrences(of: "{y}", with: "\(y)")
    }
}

// MARK: - Flyover

extension MapLibreService {
    func startFlyover(along coordinates: [CLLocationCoordinate2D],
                      altitude: Double = 500,
                      duration: TimeInterval = 30) {
        guard let mapView, coordinates.count >= 2 else { return }
        let segmentDuration = duration / Double(coordinates.count - 1)
        flyoverStep(mapView: mapView,
                    coordinates: coordinates,
                    currentIndex: 0,
                    altitude: altitude,
                    segmentDuration: segmentDuration)
    }

    private func flyoverStep(mapView: MapView,
                             coordinates: [CLLocationCoordinate2D],
                             currentIndex: Int,
                             altitude: Double,
                             segmentDuration: TimeInterval) {
        guard currentIndex < coordinates.count else { return }
        let coordinate = coordinates[currentIndex]
        var bearing = mapView.mapboxMap.cameraState.bearing
        if currentIndex < coordinates.count - 1 {
            bearing = bearingBetween(from: coordinate, to: coordinates[currentIndex + 1])
        }
        let zoom = zoomFor(altitude: altitude, latitude: coordinate.latitude)
        let camera = CameraOptions(center: coordinate, zoom: zoom, bearing: bearing, pitch: 70)
        mapView.camera.fly(to: camera, duration: segmentDuration) { [weak self] _ in
            self?.flyoverStep(mapView: mapView,
                              coordinates: coordinates,
                              currentIndex: currentIndex + 1,
                              altitude: altitude,
                              segmentDuration: segmentDuration)
        }
    }

    private func bearingBetween(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        // Canonical formula in MeasurementCalculator
        return MeasurementCalculator.bearing(from: from, to: to)
    }

    private func zoomFor(altitude: Double, latitude: Double) -> Double {
        let earthCircumference = 40_075_017.0
        let latRad = latitude * .pi / 180
        let metersPerPixelAtZoom0 = earthCircumference * cos(latRad) / 256
        let targetMetersPerPixel = max(altitude / 50, 1.0)
        let z = log2(metersPerPixelAtZoom0 / targetMetersPerPixel)
        return min(max(z, 0), 22)
    }
}
