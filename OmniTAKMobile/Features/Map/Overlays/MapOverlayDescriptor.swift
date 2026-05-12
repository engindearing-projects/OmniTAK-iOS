//
//  UserMapOverlay.swift
//  OmniTAKMobile
//
//  Model for user-imported, passive map overlays (Issue #17: SAR GeoPDF / KML
//  overlays for offline maps). Stored in Documents/map_overlays.json.
//
//  See docs/specs/map-overlays.md.
//

import Foundation
import CoreLocation

// MARK: - UserMapOverlayKind

enum UserMapOverlayKind: String, Codable, CaseIterable {
    case kml
    case kmz
    /// GeoPDF — deferred. The descriptor type exists so the manager can
    /// surface a "Coming soon" row in the UI without churning the schema
    /// when the parser lands.
    case geoPDF

    var displayName: String {
        switch self {
        case .kml: return "KML"
        case .kmz: return "KMZ"
        case .geoPDF: return "GeoPDF"
        }
    }

    /// Whether this overlay kind is wired up for import in the current build.
    var isImportable: Bool {
        switch self {
        case .kml, .kmz: return true
        case .geoPDF: return false
        }
    }

    var systemImage: String {
        switch self {
        case .kml, .kmz: return "doc.text.below.ecg"
        case .geoPDF: return "doc.richtext"
        }
    }
}

// MARK: - UserMapOverlayBounds

struct UserMapOverlayBounds: Codable, Equatable {
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                               longitude: (minLon + maxLon) / 2)
    }
}

// MARK: - UserMapOverlay

struct UserMapOverlay: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var kind: UserMapOverlayKind
    /// File name (not full path) relative to the manager's overlays directory.
    var sourceFileName: String
    var importedAt: Date
    var bounds: UserMapOverlayBounds?
    /// 0.0 ... 1.0. Default 0.65 — SAR teams want the basemap legible
    /// underneath the boundary without the overlay vanishing.
    var opacity: Double
    var isVisible: Bool

    init(id: UUID = UUID(),
         name: String,
         kind: UserMapOverlayKind,
         sourceFileName: String,
         importedAt: Date = Date(),
         bounds: UserMapOverlayBounds? = nil,
         opacity: Double = 0.65,
         isVisible: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sourceFileName = sourceFileName
        self.importedAt = importedAt
        self.bounds = bounds
        self.opacity = opacity
        self.isVisible = isVisible
    }
}
