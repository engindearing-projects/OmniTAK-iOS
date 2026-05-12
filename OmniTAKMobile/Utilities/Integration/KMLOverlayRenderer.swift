//
//  KMLOverlayRenderer.swift
//  OmniTAKMobile
//
//  Pure converter from parsed KML geometry into MKOverlays for use as a
//  PASSIVE map overlay layer (Issue #17: SAR GeoPDF/KML overlays).
//
//  This is intentionally distinct from KMLOverlayManager / KMLMapIntegration
//  in the same folder. Those are the feature-ingest path: KML placemarks
//  become tactical markers + interactive drawings. This file is the
//  shading-layer path: KML polygons + lines become quiet `MKOverlay`s with
//  per-document opacity and visibility, no per-feature interaction.
//
//  Points are intentionally skipped — overlay = passive shading, not pins.
//
//  See docs/specs/map-overlays.md.
//

import Foundation
import MapKit
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Tagged overlay subclasses
//
// We subclass MKPolygon / MKPolyline so the map view's rendererFor: can
// look up the owning UserMapOverlay (by overlayId) at draw time and
// apply per-overlay opacity / visibility / tint.

final class MapOverlayPolygon: MKPolygon {
    var overlayId: UUID?
}

final class MapOverlayPolyline: MKPolyline {
    var overlayId: UUID?
}

// MARK: - KMLOverlayRenderer

enum KMLOverlayRenderer {

    /// Walk every placemark in the document and convert each polygon /
    /// linestring into an MKOverlay tagged with the supplied overlayId.
    ///
    /// Points and any geometry we don't render are silently skipped.
    static func makeOverlays(from document: KMLDocument,
                             overlayId: UUID) -> [MKOverlay] {
        var overlays: [MKOverlay] = []

        for placemark in document.placemarks {
            appendOverlays(for: placemark.geometry,
                           overlayId: overlayId,
                           into: &overlays)
        }
        for folder in document.folders {
            for placemark in folder.placemarks {
                appendOverlays(for: placemark.geometry,
                               overlayId: overlayId,
                               into: &overlays)
            }
        }

        return overlays
    }

    /// Compute the geographic bounds of a parsed KML document. Returns nil
    /// when the document has no renderable geometry.
    static func bounds(of document: KMLDocument) -> UserMapOverlayBounds? {
        var minLat = Double.greatestFiniteMagnitude
        var maxLat = -Double.greatestFiniteMagnitude
        var minLon = Double.greatestFiniteMagnitude
        var maxLon = -Double.greatestFiniteMagnitude
        var any = false

        func extend(_ coord: CLLocationCoordinate2D) {
            any = true
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }

        func walk(_ geometry: KMLGeometry) {
            switch geometry {
            case .point(let p):
                extend(p.coordinate)
            case .lineString(let l):
                l.mapCoordinates.forEach(extend)
            case .polygon(let p):
                p.outerCoordinates.forEach(extend)
                for inner in p.innerBoundaries {
                    inner.map { $0.coordinate }.forEach(extend)
                }
            case .multiGeometry(let nested):
                nested.forEach(walk)
            }
        }

        document.placemarks.forEach { walk($0.geometry) }
        document.folders.forEach { folder in
            folder.placemarks.forEach { walk($0.geometry) }
        }

        guard any else { return nil }
        return UserMapOverlayBounds(minLat: minLat,
                                maxLat: maxLat,
                                minLon: minLon,
                                maxLon: maxLon)
    }

    #if canImport(UIKit)
    /// Build an MKOverlayRenderer for a tagged overlay produced by
    /// `makeOverlays(from:overlayId:)`. Honours per-descriptor opacity +
    /// visibility. Returns nil for unrelated overlays (caller should fall
    /// back to existing renderer chains).
    static func renderer(for overlay: MKOverlay,
                         descriptor: UserMapOverlay) -> MKOverlayRenderer? {
        let opacity = CGFloat(max(0.0, min(1.0, descriptor.opacity)))
        let visible = descriptor.isVisible

        if let polygon = overlay as? MapOverlayPolygon {
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.fillColor = UIColor.systemTeal.withAlphaComponent(0.25 * opacity)
            renderer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.9 * opacity)
            renderer.lineWidth = 2.0
            renderer.alpha = visible ? opacity : 0.0
            return renderer
        }

        if let polyline = overlay as? MapOverlayPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.9 * opacity)
            renderer.lineWidth = 3.0
            renderer.lineCap = .round
            renderer.alpha = visible ? opacity : 0.0
            return renderer
        }

        return nil
    }
    #endif

    // MARK: - Private

    private static func appendOverlays(for geometry: KMLGeometry,
                                       overlayId: UUID,
                                       into overlays: inout [MKOverlay]) {
        switch geometry {
        case .point:
            // Passive overlay layer intentionally skips points.
            return

        case .lineString(let line):
            var coords = line.mapCoordinates
            guard coords.count >= 2 else { return }
            let poly = MapOverlayPolyline(coordinates: &coords, count: coords.count)
            poly.overlayId = overlayId
            overlays.append(poly)

        case .polygon(let polygon):
            var outer = polygon.outerCoordinates
            guard outer.count >= 3 else { return }

            let mkPolygon: MapOverlayPolygon
            if polygon.innerBoundaries.isEmpty {
                mkPolygon = MapOverlayPolygon(coordinates: &outer, count: outer.count)
            } else {
                let interior = polygon.innerBoundaries.map { ring -> MKPolygon in
                    var inner = ring.map { $0.coordinate }
                    return MKPolygon(coordinates: &inner, count: inner.count)
                }
                mkPolygon = MapOverlayPolygon(coordinates: &outer,
                                              count: outer.count,
                                              interiorPolygons: interior)
            }
            mkPolygon.overlayId = overlayId
            overlays.append(mkPolygon)

        case .multiGeometry(let nested):
            for child in nested {
                appendOverlays(for: child, overlayId: overlayId, into: &overlays)
            }
        }
    }
}
