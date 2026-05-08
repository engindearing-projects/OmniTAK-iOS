//
//  ADSBPlugin.swift
//  example-adsb-plugin
//
//  Reference OmniTAK plugin. Demonstrates the OmniTAKPlugin protocol by
//  wrapping the existing ADSBTrafficService and ADSBTrafficView in the
//  plugin lifecycle. Behavior is identical to pre-plugin builds: same
//  providers, same UserDefaults keys, same map markers.
//

import SwiftUI

public struct ADSBPlugin: OmniTAKPlugin {
    public static let pluginID = "com.engindearing.omnitak.plugin.adsb"
    public static let displayName = "ADS-B Traffic"
    public static let pluginVersion = "1.0.0"
    public static let pluginAuthor = "Engindearing"
    public static let pluginDescription = "Real-time aircraft traffic from OpenSky, dump1090, adsbExchange, and FlightRadar24."

    public init() {}

    public func activate(host: PluginHost) {
        // Map presence is wired through MapViewController's existing
        // ADSBTrafficService.shared observation. We register an empty
        // overlay descriptor so the host can enumerate map contributors
        // and so future map renderers can swap to the SwiftUI overlay.
        host.register(mapOverlay: MapOverlayDescriptor(
            pluginID: Self.pluginID,
            id: "adsb.aircraft",
            view: { AnyView(EmptyView()) }
        ))

        host.register(settingsRow: SettingsRowDescriptor(
            pluginID: Self.pluginID,
            id: "adsb.settings",
            title: "ADS-B Traffic",
            systemImage: "airplane.circle.fill",
            destination: { AnyView(ADSBTrafficView()) }
        ))

        // Honor any persisted user preference on enable.
        let service = ADSBTrafficService.shared
        if service.settings.isEnabled {
            service.startTracking()
        }
    }

    public func deactivate() {
        let service = ADSBTrafficService.shared
        service.stopTracking()
    }

    public func settingsView() -> AnyView? {
        AnyView(ADSBTrafficView())
    }
}
