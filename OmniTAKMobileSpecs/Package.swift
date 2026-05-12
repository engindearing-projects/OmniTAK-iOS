// swift-tools-version:5.9
//
// OmniTAKMobileSpecs
//
// Standalone XCTest harness for OmniTAK iOS modules that don't yet have a
// PBXNativeTarget wired up in OmniTAKMobile.xcodeproj. Used as a fallback so
// we can keep TDD discipline (RED -> GREEN) for unit-level Swift code while
// the Xcode test target is still missing (see OmniTAKMobileTests/README.md).
//
// To run:
//     cd OmniTAKMobileSpecs
//     swift test
//
// To add a new spec for an in-app module, copy the file into Sources/<Spec>/
// (only pure-Swift types — no UIKit/SwiftUI/MapKit dependencies in here) and
// write your XCTest cases against it under Tests/.
//
import PackageDescription

let package = Package(
    name: "OmniTAKMobileSpecs",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "FEMACatalogSpec", targets: ["FEMACatalogSpec"]),
    ],
    targets: [
        .target(
            name: "FEMACatalogSpec",
            path: "Sources/FEMACatalogSpec"
        ),
        .testTarget(
            name: "FEMACatalogSpecTests",
            dependencies: ["FEMACatalogSpec"],
            path: "Tests/FEMACatalogSpecTests"
        ),
    ]
)
