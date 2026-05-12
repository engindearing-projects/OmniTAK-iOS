// swift-tools-version: 5.9
//
//  OmniTAKMobileSpecs — standalone XCTest harness
//
//  The xcodeproj has no PBXNativeTarget for OmniTAKMobileTests (see
//  `docs/release-notes/2.18.0-vc26051104.md` follow-up note). Rather
//  than block on test-target plumbing, individual feature areas can
//  be unit-tested from this Swift Package by symlinking or pointing
//  `path:` at the real `OmniTAKMobile/Features/.../*.swift` source.
//
//  Run from repo root:
//      swift test --package-path OmniTAKMobileSpecs
//
//  Targets here MUST stay UIKit/SwiftUI-free so they build on the host
//  Mac toolchain. Anything depending on iOS-only APIs should ship in
//  the main app target instead.
//

import PackageDescription

let package = Package(
    name: "OmniTAKMobileSpecs",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "MissionAPIClientKit",
            targets: ["MissionAPIClientKit"]
        ),
    ],
    targets: [
        // Library wrapper that points directly at the real source file
        // shipping in the iOS app. No copy, no drift.
        .target(
            name: "MissionAPIClientKit",
            path: "Sources/MissionAPIClientKit"
        ),
        .testTarget(
            name: "MissionAPIClientKitTests",
            dependencies: ["MissionAPIClientKit"],
            path: "Tests/MissionAPIClientKitTests"
        ),
    ]
)
