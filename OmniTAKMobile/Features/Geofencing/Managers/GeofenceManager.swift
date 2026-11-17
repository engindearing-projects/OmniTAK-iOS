//
//  GeofenceManager.swift
//  OmniTAKMobile
//
//  Storage and state manager for geofences
//

import Foundation
import CoreLocation

class GeofenceManager: ObservableObject {
    static let shared = GeofenceManager()

    @Published var geofences: [Geofence] = []

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private let storageKey = "com.omnitak.geofences.all"

    /// Set once the clean-up of geofences that never had a real position has run.
    static let placeholderCleanupKey = "com.omnitak.geofences.placeholderCleanupDone"

    /// Where every circle made by versions up to 2.44.0 was put, wherever the operator
    /// was: the form never read the map. Nothing is at this exact point on purpose.
    static let placeholderCenter = CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365)

    /// - Parameter defaults: where geofences are kept; the app's own defaults unless a
    ///   test passes an isolated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadGeofences()
        removeGeofencesThatNeverHadARealPosition()
    }

    // MARK: - Load/Save

    func loadGeofences() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        geofences = (try? decoder.decode([Geofence].self, from: data)) ?? []
    }

    func saveGeofences() {
        if let data = try? encoder.encode(geofences) {
            defaults.set(data, forKey: storageKey)
        }
    }

    // MARK: - One-time clean-up

    /// Whether this geofence is one the old form could only have made without a position:
    /// a circle exactly at the placeholder point, or a polygon with fewer than three corners
    /// (the form never gave a polygon any). They never covered anywhere real.
    static func neverHadARealPosition(_ geofence: Geofence) -> Bool {
        switch geofence.type {
        case .circle:
            guard let center = geofence.center else { return false }
            return abs(center.latitude - placeholderCenter.latitude) < 1e-9
                && abs(center.longitude - placeholderCenter.longitude) < 1e-9
        case .polygon:
            return (geofence.polygonCoordinates?.count ?? 0) < 3
        }
    }

    /// Removes those geofences, once. The flag is set on this first load even when there was
    /// nothing to remove, so a geofence made later at that exact point (the 2D map opens
    /// centered on it) is never taken for a leftover.
    private func removeGeofencesThatNeverHadARealPosition() {
        guard !defaults.bool(forKey: Self.placeholderCleanupKey) else { return }
        defaults.set(true, forKey: Self.placeholderCleanupKey)
        let kept = geofences.filter { !Self.neverHadARealPosition($0) }
        guard kept.count != geofences.count else { return }
        geofences = kept
        saveGeofences()
    }

    // MARK: - CRUD Operations

    func addGeofence(_ geofence: Geofence) {
        geofences.append(geofence)
        saveGeofences()
    }

    func updateGeofence(_ geofence: Geofence) {
        if let index = geofences.firstIndex(where: { $0.id == geofence.id }) {
            geofences[index] = geofence
            saveGeofences()
        }
    }

    func deleteGeofence(_ geofence: Geofence) {
        geofences.removeAll { $0.id == geofence.id }
        saveGeofences()
    }

    func toggleGeofence(_ geofence: Geofence) {
        if let index = geofences.firstIndex(where: { $0.id == geofence.id }) {
            geofences[index].isActive.toggle()
            saveGeofences()
        }
    }

    // MARK: - Queries

    func getActiveGeofences() -> [Geofence] {
        geofences.filter { $0.isActive }
    }

    func getGeofence(by id: UUID) -> Geofence? {
        geofences.first { $0.id == id }
    }

    // MARK: - Clear

    func clearAllData() {
        geofences.removeAll()
        defaults.removeObject(forKey: storageKey)
    }
}
