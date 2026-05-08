//
//  OmniTAKPlugin.swift
//  OmniTAKMobile
//
//  Plugin SDK protocol for first-party and third-party OmniTAK plugins.
//
//  iOS reality: plugins are Swift Packages compiled into the binary at build
//  time. There is no runtime loading. PluginRegistry instantiates each plugin
//  at app startup and calls activate(host:) so it can register UI hooks.
//

import SwiftUI
import MapKit

// MARK: - OmniTAKPlugin

public protocol OmniTAKPlugin {
    /// Reverse-DNS unique identifier (e.g. "com.engindearing.omnitak.plugin.adsb").
    static var pluginID: String { get }
    /// Short user-facing name shown in the Plugins list.
    static var displayName: String { get }
    /// Semver string.
    static var pluginVersion: String { get }
    /// Author / org name.
    static var pluginAuthor: String { get }
    /// One- or two-sentence description.
    static var pluginDescription: String { get }

    init()

    /// Called once at app startup if the plugin is enabled. Use the host to
    /// register overlays, radial actions, CoT handlers, and settings rows.
    func activate(host: PluginHost)

    /// Called when the user disables the plugin. Tear down background work.
    func deactivate()

    /// Optional SwiftUI settings view rendered in PluginsListView's detail.
    func settingsView() -> AnyView?
}

public extension OmniTAKPlugin {
    func settingsView() -> AnyView? { nil }
}

// MARK: - PluginHost

public protocol PluginHost: AnyObject {
    func register(mapOverlay: MapOverlayDescriptor)
    func register(radialAction: RadialActionDescriptor)
    func register(cotHandler: CoTTypeHandler)
    func register(settingsRow: SettingsRowDescriptor)

    func unregister(pluginID: String)
}

// MARK: - Descriptors

/// Describes a SwiftUI view the plugin wants overlaid on the map.
/// The host will render it above the map but below tactical UI.
public struct MapOverlayDescriptor {
    public let pluginID: String
    public let id: String
    public let view: () -> AnyView

    public init(pluginID: String, id: String, view: @escaping () -> AnyView) {
        self.pluginID = pluginID
        self.id = id
        self.view = view
    }
}

/// Describes a radial-menu action the plugin wants to add when long-pressing
/// a CoT marker of the matching type.
public struct RadialActionDescriptor {
    public let pluginID: String
    public let id: String
    public let title: String
    public let systemImage: String
    public let matchesCoTType: (String) -> Bool
    public let perform: (String) -> Void

    public init(pluginID: String,
                id: String,
                title: String,
                systemImage: String,
                matchesCoTType: @escaping (String) -> Bool,
                perform: @escaping (String) -> Void) {
        self.pluginID = pluginID
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.matchesCoTType = matchesCoTType
        self.perform = perform
    }
}

/// Describes a CoT handler that wants first dibs on a particular CoT type
/// prefix (e.g. "a-f-A" for friendly air tracks).
public struct CoTTypeHandler {
    public let pluginID: String
    public let typePrefix: String
    public let handle: (String, Data) -> Bool

    public init(pluginID: String, typePrefix: String, handle: @escaping (String, Data) -> Bool) {
        self.pluginID = pluginID
        self.typePrefix = typePrefix
        self.handle = handle
    }
}

/// Top-level Settings row contributed by a plugin (beyond its own detail view).
public struct SettingsRowDescriptor {
    public let pluginID: String
    public let id: String
    public let title: String
    public let systemImage: String
    public let destination: () -> AnyView

    public init(pluginID: String,
                id: String,
                title: String,
                systemImage: String,
                destination: @escaping () -> AnyView) {
        self.pluginID = pluginID
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.destination = destination
    }
}
