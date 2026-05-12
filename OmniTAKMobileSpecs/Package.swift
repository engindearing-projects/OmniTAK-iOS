// swift-tools-version:5.9
//
// OmniTAKMobileSpecs — standalone Swift Package that hosts pure-logic
// XCTest suites for OmniTAK Mobile (iOS).
//
// The main OmniTAKMobile.xcodeproj has no PBXNativeTarget for tests
// (per release notes 2.18.0). Until that's wired up, pure-Foundation
// modules ship thin source copies here so `swift test` exercises them.
//
// Run with:
//   cd OmniTAKMobileSpecs && swift test
//
import PackageDescription

let package = Package(
    name: "OmniTAKMobileSpecs",
    platforms: [
        .macOS(.v13),
        .iOS(.v17)
    ],
    products: [
        .library(name: "LassoCore", targets: ["LassoCore"]),
        .library(name: "DataPackageBuilderCore", targets: ["DataPackageBuilderCore"]),
    ],
    targets: [
        .target(
            name: "LassoCore",
            path: "Sources/LassoCore"
        ),
        .testTarget(
            name: "LassoCoreTests",
            dependencies: ["LassoCore"],
            path: "Tests/LassoCoreTests"
        ),
        .target(
            name: "DataPackageBuilderCore",
            path: "Sources/DataPackageBuilderCore"
        ),
        .testTarget(
            name: "DataPackageBuilderCoreTests",
            dependencies: ["DataPackageBuilderCore"],
            path: "Tests/DataPackageBuilderCoreTests"
        ),
    ]
)
