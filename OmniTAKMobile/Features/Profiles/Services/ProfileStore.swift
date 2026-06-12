//
//  ProfileStore.swift
//  OmniTAKMobile
//
//  Manages N config profiles.  Backed by UserDefaults ("omnitak_profiles" JSON).
//  Provides snapshot / apply against the live UserDefaults + ServerManager stores.
//  Does NOT re-namespace existing keys — it snapshots them and writes them back.
//

import Foundation
import Combine

// MARK: - Profile Store

class ProfileStore: ObservableObject {
    static let shared = ProfileStore()

    @Published var profiles: [ConfigProfile] = []
    @Published var activeProfileID: UUID?

    private let profilesKey   = "omnitak_profiles"
    private let activeIDKey   = "omnitak_active_profile_id"

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([ConfigProfile].self, from: data) {
            profiles = decoded
        }
        if let idStr = UserDefaults.standard.string(forKey: activeIDKey),
           let uuid = UUID(uuidString: idStr) {
            activeProfileID = uuid
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        if let id = activeProfileID {
            UserDefaults.standard.set(id.uuidString, forKey: activeIDKey)
        } else {
            UserDefaults.standard.removeObject(forKey: activeIDKey)
        }
    }

    // MARK: - Snapshot current live config

    /// Reads current UserDefaults + ServerManager state → ConfigProfile (no secrets).
    func snapshotCurrent(name: String) -> ConfigProfile {
        let ud = UserDefaults.standard

        let servers = ServerManager.shared.servers.map { ProfileServer(from: $0) }

        return ConfigProfile(
            name: name,
            teamName: nil,   // caller can fill these in
            teamRole: nil,
            teamColor: nil,
            servers: servers,
            mapEngine: ud.string(forKey: "mapEngine"),
            coordinateFormat: ud.string(forKey: "coordinateDisplayFormat"),
            unitSystem: ud.string(forKey: "unitSystem"),
            mgrsGridEnabled: ud.object(forKey: "mgrsGridEnabled") != nil
                ? ud.bool(forKey: "mgrsGridEnabled") : nil,
            mgrsGridDensity: ud.string(forKey: "mgrsGridDensity"),
            showMGRSLabels: ud.object(forKey: "showMGRSLabels") != nil
                ? ud.bool(forKey: "showMGRSLabels") : nil,
            breadcrumbTrailsEnabled: ud.object(forKey: "breadcrumbTrailsEnabled") != nil
                ? ud.bool(forKey: "breadcrumbTrailsEnabled") : nil,
            selfMarkerStyle: ud.string(forKey: "selfMarkerStyle"),
            remoteIdScanEnabled: ud.object(forKey: "remoteIdScanEnabled") != nil
                ? ud.bool(forKey: "remoteIdScanEnabled") : nil,
            gybDetectorEnabled: ud.object(forKey: "gybDetectorEnabled") != nil
                ? ud.bool(forKey: "gybDetectorEnabled") : nil,
            selectedMeshFramework: ud.string(forKey: "selectedMeshFramework")
        )
    }

    // MARK: - Apply a profile to live stores

    /// Writes a ConfigProfile's non-secret settings back to UserDefaults + ServerManager.
    /// Callsign is intentionally NOT set — each user configures their own.
    func apply(_ profile: ConfigProfile) {
        let ud = UserDefaults.standard

        // Map / display settings
        if let v = profile.mapEngine            { ud.set(v, forKey: "mapEngine") }
        if let v = profile.coordinateFormat     { ud.set(v, forKey: "coordinateDisplayFormat") }
        if let v = profile.unitSystem           { ud.set(v, forKey: "unitSystem") }
        if let v = profile.mgrsGridEnabled      { ud.set(v, forKey: "mgrsGridEnabled") }
        if let v = profile.mgrsGridDensity      { ud.set(v, forKey: "mgrsGridDensity") }
        if let v = profile.showMGRSLabels       { ud.set(v, forKey: "showMGRSLabels") }
        if let v = profile.breadcrumbTrailsEnabled { ud.set(v, forKey: "breadcrumbTrailsEnabled") }
        if let v = profile.selfMarkerStyle      { ud.set(v, forKey: "selfMarkerStyle") }
        if let v = profile.remoteIdScanEnabled  { ud.set(v, forKey: "remoteIdScanEnabled") }
        if let v = profile.gybDetectorEnabled   { ud.set(v, forKey: "gybDetectorEnabled") }
        if let v = profile.selectedMeshFramework { ud.set(v, forKey: "selectedMeshFramework") }

        // Server import: add new servers (idempotent — ServerManager deduplicates by endpoint)
        for profileServer in profile.servers {
            let takServer = profileServer.toTAKServer()
            ServerManager.shared.addServer(takServer)
        }

        // Post notification so observing views (SettingsView, etc.) can react
        NotificationCenter.default.post(name: .profileApplied, object: profile)
    }

    // MARK: - CRUD

    func addProfile(_ profile: ConfigProfile) {
        if !profiles.contains(where: { $0.id == profile.id }) {
            profiles.append(profile)
        }
        save()
    }

    func saveSnapshot(name: String) -> ConfigProfile {
        let profile = snapshotCurrent(name: name)
        addProfile(profile)
        return profile
    }

    func updateProfile(_ profile: ConfigProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            save()
        }
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
        }
        save()
    }

    func renameProfile(id: UUID, name: String) {
        if let idx = profiles.firstIndex(where: { $0.id == id }) {
            profiles[idx].name = name
            save()
        }
    }

    func setActive(id: UUID) {
        activeProfileID = id
        save()
    }

    var activeProfile: ConfigProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    // MARK: - QR helpers

    func qrURLString(for profile: ConfigProfile) throws -> String {
        try ProfileQRCodec.encode(profile)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let profileApplied = Notification.Name("omnitak.profileApplied")
}
