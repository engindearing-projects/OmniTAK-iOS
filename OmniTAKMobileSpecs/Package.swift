// swift-tools-version:5.7
//
// OmniTAKMobileSpecs — standalone Swift Package that hosts pure-logic
// XCTest suites for OmniTAK Mobile (iOS).
//
// The main OmniTAKMobile.xcodeproj has no PBXNativeTarget for tests
// (per release notes 2.18.0), so we run TDD-style tests for pure logic
// (e.g. lasso point-in-polygon) here. Run with:
//
//   cd OmniTAKMobileSpecs && swift test
//
import PackageDescription

let package = Package(
    name: "OmniTAKMobileSpecs",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(name: "LassoCore", targets: ["LassoCore"])
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
        )
    ]
)
