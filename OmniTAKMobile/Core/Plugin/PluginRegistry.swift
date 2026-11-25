//
//  PluginRegistry.swift
//  OmniTAKMobile
//
//  The compile-time plugin registry. Bundled plugins are registered at app
//  start in `loadBundledPlugins()` — there is NO dynamic loading. Enablement
//  is delegated to `PluginSettingsManager` so registered plugins share the
//  exact same toggle-persistence system as the fixed-capability plugins.
//

import Foundation

final class PluginRegistry {
    static let shared = PluginRegistry()

    /// All registered plugins, in registration order.
    private(set) var plugins: [OmniTAKPlugin] = []

    /// pluginIds that are currently activated (hooks live on the host).
    private(set) var activated: Set<String> = []

    private init() {}

    // MARK: - Registration

    /// Register a plugin. Idempotent by pluginId.
    func register(_ plugin: OmniTAKPlugin) {
        guard !plugins.contains(where: { $0.pluginId == plugin.pluginId }) else { return }
        plugins.append(plugin)
    }

    /// All registered plugins.
    func all() -> [OmniTAKPlugin] { plugins }

    /// Find a registered plugin by id.
    func plugin(withId pluginId: String) -> OmniTAKPlugin? {
        plugins.first { $0.pluginId == pluginId }
    }

    func isActivated(_ pluginId: String) -> Bool {
        activated.contains(pluginId)
    }

    // MARK: - Bundled plugins (COMPILE-TIME — store compliant)

    /// Register the plugins shipped inside the app binary. This is the ONLY
    /// place plugins enter the registry; adding a plugin means adding a line
    /// here (plus the new Swift file in the Xcode target). No dynamic code.
    func loadBundledPlugins() {
        register(ADSBPlugin())
        register(DiagnosticsPlugin())
        register(VoicePlugin())
    }

    // MARK: - Activation

    /// Activate exactly the plugins the user has enabled (per
    /// PluginSettingsManager). Called once at app start after
    /// `loadBundledPlugins()`.
    func activateEnabled(host: AppPluginHost) {
        for plugin in plugins {
            if PluginSettingsManager.shared.isRegisteredPluginEnabled(plugin.pluginId) {
                activate(pluginId: plugin.pluginId, host: host)
            }
        }
    }

    /// Activate a single plugin: tag the host with its id, call activate, and
    /// record it. Idempotent.
    func activate(pluginId: String, host: AppPluginHost) {
        guard let plugin = plugin(withId: pluginId) else { return }
        guard !activated.contains(pluginId) else { return }
        host.currentlyActivating = pluginId
        plugin.activate(host: host)
        host.currentlyActivating = nil
        activated.insert(pluginId)
    }

    /// Deactivate a single plugin: call its deactivate(), strip its hooks from
    /// the host, and forget it. Idempotent.
    func deactivate(pluginId: String, host: AppPluginHost) {
        guard activated.contains(pluginId) else { return }
        plugin(withId: pluginId)?.deactivate()
        host.removeHooks(for: pluginId)
        activated.remove(pluginId)
    }
}
