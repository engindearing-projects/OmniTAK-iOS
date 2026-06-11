//
//  PluginSDKTests.swift
//  OmniTAKMobileTests
//
//  Exercises the entire OmniTAKPlugin host surface — all four hooks
//  (registerMapOverlay / registerRadialAction / registerCoTHandler /
//  registerSettingsRow) — proving each fires, that dispatchCoT short-circuits
//  on a consuming handler, that deactivate removes a plugin's hooks, and that
//  the registry honors PluginSettingsManager enablement.
//

import XCTest
import SwiftUI
import CoreLocation
@testable import OmniTAK

// MARK: - Fake plugin exercising all four hooks

private final class AllHooksPlugin: OmniTAKPlugin {
    let pluginId = "test.plugin.allhooks"
    let displayName = "All Hooks"
    let pluginVersion = "9.9.9"
    let pluginAuthor = "Tests"
    let pluginDescription = "Exercises every host hook"

    let consumesCoT: Bool
    private(set) var cotSeen = 0
    private(set) var radialFired = false
    private(set) var deactivated = false

    init(consumesCoT: Bool = false) {
        self.consumesCoT = consumesCoT
    }

    func activate(host: PluginHost) {
        host.registerMapOverlay { AnyView(EmptyView()) }
        host.registerRadialAction(
            RadialMenuItem(icon: "star", label: "Test", action: .custom("plugin_test")),
            onSelect: { _ in self.radialFired = true }
        )
        host.registerCoTHandler { _ in
            self.cotSeen += 1
            return self.consumesCoT
        }
        host.registerSettingsRow(label: "Test", icon: "star")
    }

    func deactivate() { deactivated = true }

    func settingsContent() -> AnyView? { AnyView(Text("settings")) }
}

private final class NoSettingsPlugin: OmniTAKPlugin {
    let pluginId = "test.plugin.nosettings"
    let displayName = "No Settings"
    let pluginVersion = "1.0.0"
    let pluginAuthor = "Tests"
    let pluginDescription = "Has no settings UI"
    func activate(host: PluginHost) {}
    func deactivate() {}
}

final class PluginSDKTests: XCTestCase {

    private func makeCoTEvent(uid: String = "TEST-1") -> CoTEvent {
        CoTEvent(
            uid: uid,
            type: "a-f-G-U-C",
            time: Date(),
            point: CoTPoint(lat: 40.64, lon: -73.78, hae: 0, ce: 0, le: 0),
            detail: CoTDetail(callsign: "TEST", team: nil, teamRole: nil,
                              speed: nil, course: nil, remarks: nil,
                              battery: nil, device: nil, platform: nil)
        )
    }

    // MARK: - All four hooks register through the host

    func testAllFourHooksRegister() {
        let host = AppPluginHost.shared
        host.removeHooks(for: "test.plugin.allhooks")

        let plugin = AllHooksPlugin()
        host.currentlyActivating = plugin.pluginId
        plugin.activate(host: host)
        host.currentlyActivating = nil

        XCTAssertTrue(host.mapOverlays.contains { $0.pluginId == plugin.pluginId },
                      "registerMapOverlay should append an overlay")
        XCTAssertTrue(host.settingsRows.contains { $0.pluginId == plugin.pluginId },
                      "registerSettingsRow should append a settings row")
        XCTAssertTrue(host.radialActions.contains { $0.pluginId == plugin.pluginId },
                      "registerRadialAction should append a radial action")
        XCTAssertTrue(host.cotHandlers.contains { $0.pluginId == plugin.pluginId },
                      "registerCoTHandler should append a CoT handler")

        host.removeHooks(for: plugin.pluginId)
    }

    // MARK: - CoT dispatch fires the handler

    func testCoTHandlerFires() {
        let host = AppPluginHost.shared
        host.removeHooks(for: "test.plugin.allhooks")

        let plugin = AllHooksPlugin(consumesCoT: false)
        host.currentlyActivating = plugin.pluginId
        plugin.activate(host: host)
        host.currentlyActivating = nil

        let consumed = host.dispatchCoT(makeCoTEvent())
        XCTAssertEqual(plugin.cotSeen, 1, "the registered CoT handler should be called")
        XCTAssertFalse(consumed, "a non-consuming handler should not mark the event consumed")

        host.removeHooks(for: plugin.pluginId)
    }

    // MARK: - CoT dispatch short-circuits on a consuming handler

    func testCoTDispatchShortCircuits() {
        let host = AppPluginHost.shared
        host.removeHooks(for: "test.plugin.allhooks")

        let consumer = AllHooksPlugin(consumesCoT: true)
        host.currentlyActivating = consumer.pluginId
        consumer.activate(host: host)
        host.currentlyActivating = nil

        XCTAssertTrue(host.dispatchCoT(makeCoTEvent()),
                      "a consuming handler should mark the event consumed")

        host.removeHooks(for: consumer.pluginId)
    }

    // MARK: - Radial onSelect fires by identifier

    func testRadialActionFires() {
        let host = AppPluginHost.shared
        host.removeHooks(for: "test.plugin.allhooks")

        let plugin = AllHooksPlugin()
        host.currentlyActivating = plugin.pluginId
        plugin.activate(host: host)
        host.currentlyActivating = nil

        // .custom("plugin_test") → identifier "custom_plugin_test"
        let fired = host.fireRadialAction(
            identifier: "custom_plugin_test",
            at: CLLocationCoordinate2D(latitude: 1, longitude: 2)
        )
        XCTAssertTrue(fired, "fireRadialAction should locate the registered action")
        XCTAssertTrue(plugin.radialFired, "the registered onSelect closure should run")

        host.removeHooks(for: plugin.pluginId)
    }

    // MARK: - Deactivate removes a plugin's hooks

    func testDeactivateRemovesHooks() {
        let host = AppPluginHost.shared
        host.removeHooks(for: "test.plugin.allhooks")

        let plugin = AllHooksPlugin()
        host.currentlyActivating = plugin.pluginId
        plugin.activate(host: host)
        host.currentlyActivating = nil

        XCTAssertFalse(host.mapOverlays.filter { $0.pluginId == plugin.pluginId }.isEmpty)
        host.removeHooks(for: plugin.pluginId)

        XCTAssertTrue(host.mapOverlays.filter { $0.pluginId == plugin.pluginId }.isEmpty)
        XCTAssertTrue(host.settingsRows.filter { $0.pluginId == plugin.pluginId }.isEmpty)
        XCTAssertTrue(host.radialActions.filter { $0.pluginId == plugin.pluginId }.isEmpty)
        XCTAssertTrue(host.cotHandlers.filter { $0.pluginId == plugin.pluginId }.isEmpty)
    }

    // MARK: - Registry honors PluginSettingsManager enablement

    func testActivateEnabledRespectsSettings() {
        let host = AppPluginHost.shared
        let registry = PluginRegistry.shared

        let enabledPlugin = AllHooksPlugin()
        let disabledPlugin = NoSettingsPlugin()
        registry.register(enabledPlugin)
        registry.register(disabledPlugin)

        PluginSettingsManager.shared.setRegisteredPlugin(enabledPlugin.pluginId, enabled: true)
        PluginSettingsManager.shared.setRegisteredPlugin(disabledPlugin.pluginId, enabled: false)

        registry.activateEnabled(host: host)

        XCTAssertTrue(registry.isActivated(enabledPlugin.pluginId),
                      "an enabled plugin should be activated")
        XCTAssertFalse(registry.isActivated(disabledPlugin.pluginId),
                       "a disabled plugin should NOT be activated")

        // Cleanup
        registry.deactivate(pluginId: enabledPlugin.pluginId, host: host)
        host.removeHooks(for: enabledPlugin.pluginId)
    }

    // MARK: - Plugins without settingsContent return nil by default

    func testDefaultSettingsContentIsNil() {
        XCTAssertNil(NoSettingsPlugin().settingsContent(),
                     "the protocol-extension default should return nil")
    }

    // MARK: - Bundled plugins register ADS-B + Diagnostics

    func testBundledPluginsRegistered() {
        let registry = PluginRegistry.shared
        registry.loadBundledPlugins()
        XCTAssertNotNil(registry.plugin(withId: "soy.engindearing.adsb"),
                        "ADS-B reference plugin should be registered")
        XCTAssertNotNil(registry.plugin(withId: "soy.engindearing.diagnostics"),
                        "Diagnostics test plugin should be registered")
    }

    // MARK: - Diagnostics is disabled by default; ADS-B enabled by default

    func testRegisteredDefaults() {
        let mgr = PluginSettingsManager.shared
        // Clear any persisted value to test the first-run default.
        UserDefaults.standard.removeObject(forKey: "plugin_enabled_soy.engindearing.diagnostics")
        XCTAssertFalse(mgr.isRegisteredPluginEnabled("soy.engindearing.diagnostics"),
                       "DiagnosticsPlugin should default OFF")
        UserDefaults.standard.removeObject(forKey: "plugin_enabled_soy.engindearing.adsb")
        XCTAssertTrue(mgr.isRegisteredPluginEnabled("soy.engindearing.adsb"),
                      "ADS-B should default ON so first-time users see it")
    }

    // MARK: - ADS-B re-enable is symmetric (overlay returns to prior state)

    /// Restore the shared ADS-B service to a known enabled state after each
    /// case so the symmetric-toggle tests don't leak into each other or into
    /// any later test that reads the singleton.
    private func setADSBOverlay(enabled: Bool) {
        var s = ADSBTrafficService.shared.settings
        s.isEnabled = enabled
        ADSBTrafficService.shared.settings = s
    }

    /// Disabling then re-enabling the plugin must restore the overlay to the
    /// state it was in BEFORE deactivation. When it was ON, it comes back ON.
    func testADSBReenableRestoresOverlayWhenPreviouslyOn() {
        let originalEnabled = ADSBTrafficService.shared.settings.isEnabled
        defer { setADSBOverlay(enabled: originalEnabled) }

        let plugin = ADSBPlugin()
        setADSBOverlay(enabled: true)

        plugin.deactivate()
        XCTAssertFalse(ADSBTrafficService.shared.settings.isEnabled,
                       "deactivate should turn the overlay off")

        plugin.activate(host: AppPluginHost.shared)
        XCTAssertTrue(ADSBTrafficService.shared.settings.isEnabled,
                      "re-enabling the plugin should restore the overlay to ON")

        AppPluginHost.shared.removeHooks(for: plugin.pluginId)
    }

    /// When the user had hidden aircraft (overlay OFF) but left the plugin
    /// enabled, disabling then re-enabling the plugin must NOT force the
    /// overlay back on — it stays OFF, exactly as the user left it.
    func testADSBReenableRestoresOverlayWhenPreviouslyOff() {
        let originalEnabled = ADSBTrafficService.shared.settings.isEnabled
        defer { setADSBOverlay(enabled: originalEnabled) }

        let plugin = ADSBPlugin()
        setADSBOverlay(enabled: false)

        plugin.deactivate()
        XCTAssertFalse(ADSBTrafficService.shared.settings.isEnabled,
                       "deactivate is a no-op for visibility when already off")

        plugin.activate(host: AppPluginHost.shared)
        XCTAssertFalse(ADSBTrafficService.shared.settings.isEnabled,
                       "re-enabling must not clobber a user who hid aircraft")

        AppPluginHost.shared.removeHooks(for: plugin.pluginId)
    }

    /// First-ever activation (no prior deactivate, nothing stashed) defaults
    /// the overlay ON, matching the plugin's default-enabled posture so a
    /// first-time user sees aircraft.
    func testADSBFirstActivationDefaultsOverlayOn() {
        let originalEnabled = ADSBTrafficService.shared.settings.isEnabled
        defer { setADSBOverlay(enabled: originalEnabled) }

        // Start from OFF and activate a fresh plugin that has never stashed a
        // value — the nil-stash branch should restore to the default-ON state.
        setADSBOverlay(enabled: false)
        let plugin = ADSBPlugin()

        plugin.activate(host: AppPluginHost.shared)
        XCTAssertTrue(ADSBTrafficService.shared.settings.isEnabled,
                      "first activation with no stash should default the overlay ON")

        AppPluginHost.shared.removeHooks(for: plugin.pluginId)
    }
}
