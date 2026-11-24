//
//  AppPluginHost.swift
//  OmniTAKMobile
//
//  Concrete `PluginHost`. Holds the registered hooks from all active plugins
//  and exposes them to the four real seams:
//    - map overlays  → MapViewController.mapChrome (both engines)
//    - radial actions → RadialMenuMapCoordinator / RadialMenuActionExecutor
//    - CoT handlers   → CoTEventHandler.handlePositionUpdate (post-ingest)
//    - settings rows  → PluginsListView
//
//  Every registration is tagged with the pluginId the registry is currently
//  activating (set via `currentlyActivating`), so `removeHooks(for:)` can
//  cleanly tear down a single plugin on deactivate.
//

import SwiftUI
import CoreLocation
import Combine

final class AppPluginHost: ObservableObject, PluginHost {
    static let shared = AppPluginHost()

    // MARK: - Registered hooks (observed by the UI seams)

    struct OverlayEntry: Identifiable {
        let id: String          // "<pluginId>#<index>"
        let pluginId: String
        let view: () -> AnyView
    }

    struct SettingsRowEntry: Identifiable {
        let id: String          // "<pluginId>#<index>"
        let pluginId: String
        let label: String
        let icon: String
    }

    struct RadialEntry {
        let pluginId: String
        let item: RadialMenuItem
        let onSelect: (CLLocationCoordinate2D) -> Void
    }

    struct CoTHandlerEntry {
        let pluginId: String
        let handler: (CoTEvent) -> Bool
    }

    /// Map overlays rendered in the engine-agnostic chrome on BOTH engines.
    @Published private(set) var mapOverlays: [OverlayEntry] = []
    /// Rows shown in Settings → Plugins (navigate into settingsContent()).
    @Published private(set) var settingsRows: [SettingsRowEntry] = []
    /// Radial menu items appended to the empty-map long-press menu.
    private(set) var radialActions: [RadialEntry] = []
    /// Handlers fired after the core store ingests an inbound CoT event.
    private(set) var cotHandlers: [CoTHandlerEntry] = []

    /// The pluginId the registry is currently activating. Every register*
    /// call tags its hook with this so deactivate can remove it cleanly.
    var currentlyActivating: String?

    private init() {}

    // MARK: - PluginHost

    func registerMapOverlay(_ overlay: @escaping () -> AnyView) {
        let owner = currentlyActivating ?? "unknown"
        let entry = OverlayEntry(id: "\(owner)#\(mapOverlays.count)",
                                 pluginId: owner,
                                 view: overlay)
        mapOverlays.append(entry)
    }

    func registerRadialAction(_ action: RadialMenuItem,
                              onSelect: @escaping (CLLocationCoordinate2D) -> Void) {
        let owner = currentlyActivating ?? "unknown"
        radialActions.append(RadialEntry(pluginId: owner, item: action, onSelect: onSelect))
    }

    func registerCoTHandler(_ handler: @escaping (CoTEvent) -> Bool) {
        let owner = currentlyActivating ?? "unknown"
        cotHandlers.append(CoTHandlerEntry(pluginId: owner, handler: handler))
    }

    func registerSettingsRow(label: String, icon: String) {
        let owner = currentlyActivating ?? "unknown"
        let entry = SettingsRowEntry(id: "\(owner)#\(settingsRows.count)",
                                     pluginId: owner,
                                     label: label,
                                     icon: icon)
        settingsRows.append(entry)
    }

    // MARK: - Teardown

    /// Remove every hook a plugin registered. Called from the registry on
    /// `deactivate(pluginId:)`.
    func removeHooks(for pluginId: String) {
        mapOverlays.removeAll { $0.pluginId == pluginId }
        settingsRows.removeAll { $0.pluginId == pluginId }
        radialActions.removeAll { $0.pluginId == pluginId }
        cotHandlers.removeAll { $0.pluginId == pluginId }
    }

    // MARK: - CoT dispatch

    /// Fire every registered CoT handler in order. Short-circuits and returns
    /// `true` as soon as a handler consumes the event. Called from
    /// CoTEventHandler AFTER the core store ingests the event.
    @discardableResult
    func dispatchCoT(_ event: CoTEvent) -> Bool {
        for entry in cotHandlers {
            if entry.handler(event) {
                return true
            }
        }
        return false
    }

    /// Look up a registered radial action by its `.custom(identifier)` value
    /// and invoke its onSelect with the pressed coordinate. Returns true when
    /// a matching registered action was found and fired.
    @discardableResult
    func fireRadialAction(identifier: String, at coordinate: CLLocationCoordinate2D) -> Bool {
        for entry in radialActions where entry.item.action.identifier == identifier {
            entry.onSelect(coordinate)
            return true
        }
        return false
    }
}
