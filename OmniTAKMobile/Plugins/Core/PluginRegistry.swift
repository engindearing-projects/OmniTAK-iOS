//
//  PluginRegistry.swift
//  OmniTAKMobile
//
//  Central registry of bundled OmniTAKPlugins. Source of truth for the
//  Plugins settings UI and the host-side hooks (map overlays, radial
//  actions, CoT handlers, settings rows).
//

import SwiftUI
import Combine

public final class PluginRegistry: ObservableObject, PluginHost {
    public static let shared = PluginRegistry()

    @Published public private(set) var plugins: [RegisteredPlugin] = []
    @Published public private(set) var mapOverlays: [MapOverlayDescriptor] = []
    @Published public private(set) var radialActions: [RadialActionDescriptor] = []
    @Published public private(set) var cotHandlers: [CoTTypeHandler] = []
    @Published public private(set) var settingsRows: [SettingsRowDescriptor] = []

    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "omnitak_plugin_enabled_"
    private var activated: Set<String> = []
    private var didLoadBundled = false

    private init() {}

    // MARK: - Lifecycle

    /// Instantiate and register every bundled plugin. Call once at app launch.
    public func loadBundledPlugins() {
        guard !didLoadBundled else { return }
        didLoadBundled = true

        let bundled: [OmniTAKPlugin] = BundledPlugins.makeAll()
        for plugin in bundled {
            register(plugin: plugin, isExample: type(of: plugin).pluginID == Self.ADSBPluginID)
        }
    }

    private static let ADSBPluginID = "com.engindearing.omnitak.plugin.adsb"

    // MARK: - Registration

    private func register(plugin: OmniTAKPlugin, isExample: Bool) {
        let meta = RegisteredPlugin(
            id: type(of: plugin).pluginID,
            displayName: type(of: plugin).displayName,
            version: type(of: plugin).pluginVersion,
            author: type(of: plugin).pluginAuthor,
            description: type(of: plugin).pluginDescription,
            isExample: isExample,
            instance: plugin
        )
        plugins.append(meta)

        if isEnabled(meta.id) {
            activate(meta)
        }
    }

    private func activate(_ meta: RegisteredPlugin) {
        guard !activated.contains(meta.id) else { return }
        meta.instance.activate(host: self)
        activated.insert(meta.id)
    }

    private func deactivate(_ meta: RegisteredPlugin) {
        guard activated.contains(meta.id) else { return }
        meta.instance.deactivate()
        activated.remove(meta.id)
        unregister(pluginID: meta.id)
    }

    // MARK: - Enable/Disable (UserDefaults-backed)

    public func isEnabled(_ pluginID: String) -> Bool {
        let key = keyPrefix + pluginID
        if userDefaults.object(forKey: key) == nil { return true }
        return userDefaults.bool(forKey: key)
    }

    public func setEnabled(_ pluginID: String, enabled: Bool) {
        let key = keyPrefix + pluginID
        userDefaults.set(enabled, forKey: key)
        guard let meta = plugins.first(where: { $0.id == pluginID }) else { return }
        if enabled {
            activate(meta)
        } else {
            deactivate(meta)
        }
        objectWillChange.send()
    }

    public func binding(for pluginID: String) -> Binding<Bool> {
        Binding(
            get: { self.isEnabled(pluginID) },
            set: { self.setEnabled(pluginID, enabled: $0) }
        )
    }

    public func plugin(_ pluginID: String) -> RegisteredPlugin? {
        plugins.first(where: { $0.id == pluginID })
    }

    // MARK: - PluginHost

    public func register(mapOverlay: MapOverlayDescriptor) {
        mapOverlays.append(mapOverlay)
    }

    public func register(radialAction: RadialActionDescriptor) {
        radialActions.append(radialAction)
    }

    public func register(cotHandler: CoTTypeHandler) {
        cotHandlers.append(cotHandler)
    }

    public func register(settingsRow: SettingsRowDescriptor) {
        settingsRows.append(settingsRow)
    }

    public func unregister(pluginID: String) {
        mapOverlays.removeAll { $0.pluginID == pluginID }
        radialActions.removeAll { $0.pluginID == pluginID }
        cotHandlers.removeAll { $0.pluginID == pluginID }
        settingsRows.removeAll { $0.pluginID == pluginID }
    }
}

// MARK: - RegisteredPlugin

public struct RegisteredPlugin: Identifiable {
    public let id: String
    public let displayName: String
    public let version: String
    public let author: String
    public let description: String
    public let isExample: Bool
    public let instance: OmniTAKPlugin
}
