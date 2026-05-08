//
//  BundledPlugins.swift
//  OmniTAKMobile
//
//  The list of plugins that ship inside the binary. Plugin authors
//  add their plugin's `Plugin()` to `makeAll()` after dropping their
//  Swift Package into the project.
//
//  See docs/PLUGIN_AUTHORING.md for the full walkthrough.
//

enum BundledPlugins {
    static func makeAll() -> [OmniTAKPlugin] {
        return [
            // Reference plugin — the canonical example.
            ADSBPlugin()
        ]
    }
}
