// swift-tools-version:5.9
//
// Package manifest for the reference OmniTAK plugin.
//
// In the OmniTAK-iOS app this package's Sources/ files are referenced
// directly by OmniTAKMobile.xcodeproj — the package is compiled into
// the app target alongside the plugin host. The Package.swift here is
// the canonical layout third-party plugin authors should mirror.
//
// See docs/PLUGIN_AUTHORING.md for the full walkthrough.

import PackageDescription

let package = Package(
    name: "ADSBPlugin",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "ADSBPlugin", targets: ["ADSBPlugin"])
    ],
    targets: [
        .target(
            name: "ADSBPlugin",
            path: "Sources/ADSBPlugin"
        )
    ]
)
