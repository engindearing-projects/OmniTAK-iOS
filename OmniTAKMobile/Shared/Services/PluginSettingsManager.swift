//
//  PluginSettingsManager.swift
//  OmniTAKMobile
//
//  Manages persistent plugin/feature enable states
//

import SwiftUI
import Combine

/// Plugin identifiers matching tool IDs in ATAKToolsView
enum PluginID: String, CaseIterable {
    case meshtastic = "meshtastic"
    case offlineMaps = "offline"
    case trackRecording = "tracks"
    case drawingTools = "drawing"
    case measurementTools = "measure"
    case dataPackages = "data"
    case teamManagement = "teams"
    case routePlanning = "routes"
    case emergencyBeacon = "alert"
    case chat = "chat"
    case video = "video"
    case geofence = "geofence"
    case casevac = "casevac"
    case nineline = "nineline"
    case bloodhound = "bloodhound"
    case spotrep = "spotrep"
    case view3d = "3dview"
    case turnByTurn = "turnbyturn"
    // NOTE: `.adsb` was REMOVED here — ADS-B is now a registered
    // OmniTAKPlugin (ADSBPlugin, "soy.engindearing.adsb"). It is listed once,
    // under Settings → Plugins → PLUGINS, not in this fixed FEATURES enum.
    // See PluginRegistry + the registered-plugin API below.

    var displayName: String {
        switch self {
        case .meshtastic: return "Meshtastic"
        case .offlineMaps: return "Offline Maps"
        case .trackRecording: return "Track Recording"
        case .drawingTools: return "Drawing Tools"
        case .measurementTools: return "Measurement Tools"
        case .dataPackages: return "Data Packages"
        case .teamManagement: return "Team Management"
        case .routePlanning: return "Route Planning"
        case .emergencyBeacon: return "Emergency Beacon"
        case .chat: return "Chat"
        case .video: return "Video"
        case .geofence: return "Geofence"
        case .casevac: return "CASEVAC"
        case .nineline: return "9-Line CAS"
        case .bloodhound: return "Bloodhound"
        case .spotrep: return "SPOTREP"
        case .view3d: return "3D View"
        case .turnByTurn: return "Navigation"
        }
    }

    var icon: String {
        switch self {
        case .meshtastic: return "dot.radiowaves.left.and.right"
        case .offlineMaps: return "map.fill"
        case .trackRecording: return "record.circle"
        case .drawingTools: return "pencil.tip"
        case .measurementTools: return "ruler"
        case .dataPackages: return "shippingbox.fill"
        case .teamManagement: return "person.3.fill"
        case .routePlanning: return "point.topleft.down.to.point.bottomright.curvepath.fill"
        case .emergencyBeacon: return "sos"
        case .chat: return "message.fill"
        case .video: return "video.fill"
        case .geofence: return "square.dashed"
        case .casevac: return "cross.case.fill"
        case .nineline: return "airplane"
        case .bloodhound: return "antenna.radiowaves.left.and.right"
        case .spotrep: return "doc.text.fill"
        case .view3d: return "view.3d"
        case .turnByTurn: return "location.north.line.fill"
        }
    }

    var description: String {
        switch self {
        case .meshtastic: return "Off-grid LoRa mesh networking"
        case .offlineMaps: return "Download and use maps offline"
        case .trackRecording: return "Record and playback GPS tracks"
        case .drawingTools: return "Create tactical drawings on map"
        case .measurementTools: return "Measure distances and areas"
        case .dataPackages: return "Import and export data packages"
        case .teamManagement: return "Organize and manage teams"
        case .routePlanning: return "Plan and share routes"
        case .emergencyBeacon: return "Emergency beacon and alerts"
        case .chat: return "Team chat messaging"
        case .video: return "Video streaming (Beta - requires TAK server)"
        case .geofence: return "Create geofence alerts"
        case .casevac: return "Request casualty evacuation"
        case .nineline: return "Close Air Support request"
        case .bloodhound: return "Blue Force Tracking"
        case .spotrep: return "Quick tactical spot report"
        case .view3d: return "Real 3D terrain visualization with MapLibre"
        case .turnByTurn: return "Turn-by-turn voice navigation"
        }
    }
}

/// Singleton manager for plugin enabled states with persistence
class PluginSettingsManager: ObservableObject {
    static let shared = PluginSettingsManager()

    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "plugin_enabled_"

    /// Published dictionary of plugin enabled states
    @Published private(set) var enabledPlugins: [PluginID: Bool] = [:]

    /// Tools that are not fully implemented and should be disabled by default
    /// Users can still enable them manually in the Plugins settings to try experimental features
    private static let disabledByDefault: Set<PluginID> = [
        // .view3d - Now uses MapLibre with real 3D terrain, fully functional
        .video,         // Video streaming - requires TAK server video feeds
    ]

    // MARK: - Registered OmniTAKPlugins (SDK)

    /// Registered plugins (by reverse-DNS pluginId) that should be OFF on
    /// first run. Everything else defaults ON so first-time users see plugin
    /// features. ADS-B is intentionally absent → defaults ON.
    private static let registeredDisabledByDefault: Set<String> = [
        "soy.engindearing.diagnostics",   // internal SDK probe, never on for shipping users
        "com.atakmap.android.xv.plugin",  // voice (PTT): opt-in, uses the microphone
    ]

    /// One-time migration: copy any legacy fixed-capability ADS-B enable flag
    /// (`plugin_enabled_adsb`) onto the new registered-plugin key
    /// (`plugin_enabled_soy.engindearing.adsb`) so existing testers keep their
    /// toggle when ADS-B becomes a registered plugin.
    private static let adsbMigrationDoneKey = "plugin_migrated_adsb_to_registered_v1"

    private init() {
        migrateLegacyADSBEnableFlagIfNeeded()
        loadSettings()
    }

    private func migrateLegacyADSBEnableFlagIfNeeded() {
        guard !userDefaults.bool(forKey: Self.adsbMigrationDoneKey) else { return }
        let legacyKey = keyPrefix + "adsb"   // plugin_enabled_adsb
        let newKey = keyPrefix + "soy.engindearing.adsb"
        if userDefaults.object(forKey: legacyKey) != nil,
           userDefaults.object(forKey: newKey) == nil {
            userDefaults.set(userDefaults.bool(forKey: legacyKey), forKey: newKey)
        }
        userDefaults.set(true, forKey: Self.adsbMigrationDoneKey)
    }

    /// Whether a registered OmniTAKPlugin is enabled. Keyed by pluginId under
    /// the SAME `plugin_enabled_` prefix the fixed capabilities use, so the
    /// whole toggle system is one consistent store.
    func isRegisteredPluginEnabled(_ pluginId: String) -> Bool {
        let key = keyPrefix + pluginId
        if userDefaults.object(forKey: key) == nil {
            return !Self.registeredDisabledByDefault.contains(pluginId)
        }
        return userDefaults.bool(forKey: key)
    }

    /// Persist a registered plugin's enable state.
    func setRegisteredPlugin(_ pluginId: String, enabled: Bool) {
        userDefaults.set(enabled, forKey: keyPrefix + pluginId)
        objectWillChange.send()
    }

    /// Binding for a registered plugin's Toggle. The `set` side persists the
    /// flag AND drives live activation/deactivation through the registry.
    func registeredBinding(for pluginId: String) -> Binding<Bool> {
        Binding(
            get: { self.isRegisteredPluginEnabled(pluginId) },
            set: { enabled in
                self.setRegisteredPlugin(pluginId, enabled: enabled)
                if enabled {
                    PluginRegistry.shared.activate(pluginId: pluginId, host: AppPluginHost.shared)
                } else {
                    PluginRegistry.shared.deactivate(pluginId: pluginId, host: AppPluginHost.shared)
                }
            }
        )
    }

    /// Load settings from UserDefaults
    private func loadSettings() {
        var settings: [PluginID: Bool] = [:]
        for plugin in PluginID.allCases {
            let key = keyPrefix + plugin.rawValue
            // Check if user has explicitly set a value
            if userDefaults.object(forKey: key) == nil {
                // No user setting - use default based on implementation status
                settings[plugin] = !Self.disabledByDefault.contains(plugin)
            } else {
                settings[plugin] = userDefaults.bool(forKey: key)
            }
        }
        enabledPlugins = settings
    }

    /// Check if a plugin is enabled
    func isEnabled(_ plugin: PluginID) -> Bool {
        return enabledPlugins[plugin] ?? true
    }

    /// Check if a tool ID is enabled (for ATAKToolsView compatibility)
    func isToolEnabled(_ toolID: String) -> Bool {
        // Core tools that can't be disabled
        let alwaysEnabled = ["settings", "plugins", "pointer"]
        if alwaysEnabled.contains(toolID) {
            return true
        }

        // Map tool ID to plugin
        if let plugin = PluginID(rawValue: toolID) {
            return isEnabled(plugin)
        }

        // Registered OmniTAKPlugin (reverse-DNS id, e.g. a radial action's
        // owning pluginId from RadialMenuAction.pluginToolID) — gate by the
        // registered-plugin enable flag so a disabled plugin's radial entry
        // is filtered out exactly like a fixed capability's.
        if toolID.contains(".") {
            return isRegisteredPluginEnabled(toolID)
        }

        // Unknown tools default to enabled
        return true
    }

    /// Set plugin enabled state
    func setEnabled(_ plugin: PluginID, enabled: Bool) {
        let key = keyPrefix + plugin.rawValue
        userDefaults.set(enabled, forKey: key)
        enabledPlugins[plugin] = enabled
        objectWillChange.send()
    }

    /// Toggle plugin state
    func toggle(_ plugin: PluginID) {
        let currentState = isEnabled(plugin)
        setEnabled(plugin, enabled: !currentState)
    }

    /// Get binding for a plugin (for use in Toggle views)
    func binding(for plugin: PluginID) -> Binding<Bool> {
        Binding(
            get: { self.isEnabled(plugin) },
            set: { self.setEnabled(plugin, enabled: $0) }
        )
    }

    /// Reset all plugins to enabled
    func resetAll() {
        for plugin in PluginID.allCases {
            setEnabled(plugin, enabled: true)
        }
    }
}
