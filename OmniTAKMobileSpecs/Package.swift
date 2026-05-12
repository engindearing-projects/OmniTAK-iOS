// swift-tools-version:5.9
//
// OmniTAKMobileSpecs — standalone XCTest harness for pure logic
// modules that ship in the iOS app but can be unit-tested off-device
// without a PBXNativeTarget. The main Xcode project does not yet have
// an `OmniTAKMobileTests` test target (release notes 2.18.0); until we
// wire one up, pure-Foundation modules should ship a thin source
// symlink/copy here so `swift test` from this directory exercises them.
//
// Trigger from CI / locally:
//
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
        .library(name: "DataPackageBuilderCore", targets: ["DataPackageBuilderCore"]),
    ],
    targets: [
        .target(
            name: "DataPackageBuilderCore",
            path: "Sources/DataPackageBuilderCore"
        ),
        .testTarget(
            name: "DataPackageBuilderCoreTests",
            dependencies: ["DataPackageBuilderCore"],
            path: "Tests/DataPackageBuilderCoreTests"
        )
    ]
)
