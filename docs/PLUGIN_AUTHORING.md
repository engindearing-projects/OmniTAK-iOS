# OmniTAK iOS — Plugin Authoring Guide

This guide is for engineers building plugins on top of OmniTAK iOS. It is the
companion to the reference implementation at
[`plugins/example-adsb-plugin/`](../plugins/example-adsb-plugin).

## The hard iOS truth

iOS does not allow runtime loading of arbitrary code. Every Swift Package,
every framework, every line of executable Swift in your plugin must be
present at App Store / TestFlight build time and signed into the binary.

So in OmniTAK terms, a "plugin" on iOS means:

1. A Swift Package (`Package.swift` + `Sources/`) authored and shipped by you.
2. Added as a local package dependency to OmniTAK-iOS.
3. Registered in `OmniTAKMobile/Plugins/Core/BundledPlugins.swift`.
4. Compiled into the same binary as the host app.

The runtime "plug-in-ness" is the lifecycle: `PluginRegistry.shared` enumerates
your plugin in the Plugins UI, the user can enable/disable it, and your
`activate(host:)` / `deactivate()` methods get called accordingly.

## Anatomy of a plugin

A minimum viable plugin is two files:

```
plugins/my-plugin/
├── Package.swift
└── Sources/MyPlugin/
    └── MyPlugin.swift
```

`Package.swift`:

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MyPlugin",
    platforms: [.iOS(.v15)],
    products: [.library(name: "MyPlugin", targets: ["MyPlugin"])],
    targets: [
        .target(name: "MyPlugin", path: "Sources/MyPlugin")
    ]
)
```

`Sources/MyPlugin/MyPlugin.swift`:

```swift
import SwiftUI

public struct MyPlugin: OmniTAKPlugin {
    public static let pluginID = "com.acme.omnitak.plugin.example"
    public static let displayName = "My Plugin"
    public static let pluginVersion = "1.0.0"
    public static let pluginAuthor = "Acme"
    public static let pluginDescription = "Demonstrates the OmniTAK plugin protocol."

    public init() {}

    public func activate(host: PluginHost) {
        // Register what your plugin contributes to the app.
    }

    public func deactivate() {
        // Stop background work, deregister observers, etc.
    }

    public func settingsView() -> AnyView? {
        AnyView(Text("Settings for My Plugin"))
    }
}
```

## The OmniTAKPlugin protocol

```swift
public protocol OmniTAKPlugin {
    static var pluginID: String { get }            // reverse-DNS, unique
    static var displayName: String { get }
    static var pluginVersion: String { get }       // semver
    static var pluginAuthor: String { get }
    static var pluginDescription: String { get }

    init()

    func activate(host: PluginHost)
    func deactivate()
    func settingsView() -> AnyView?                // optional, default = nil
}
```

`activate(host:)` is invoked at app startup if the user has the plugin
enabled, and again whenever the user toggles it on. `deactivate()` is
invoked when the user toggles it off; the registry also tears down all
hooks the plugin registered (overlays, radial actions, CoT handlers,
settings rows) so you do not need to remember each individual
unregister call.

`settingsView()` returns the SwiftUI view rendered when the user taps your
plugin in the Plugins list. Return `nil` (the default) if your plugin has
no settings.

## The PluginHost API

Inside `activate(host:)` you ask the host to wire your contributions in.

| API | What it does |
|---|---|
| `host.register(mapOverlay:)` | Place a SwiftUI view above the map. |
| `host.register(radialAction:)` | Add an item to the radial menu shown when long-pressing a CoT marker. Use `matchesCoTType` to scope the action to specific marker types (e.g. `a-f-A` for friendly air). |
| `host.register(cotHandler:)` | First-dibs handler for a CoT type prefix. Return `true` from `handle(_:_:)` to consume the message. |
| `host.register(settingsRow:)` | Add a top-level row to the Settings screen. |

All descriptors carry the registering plugin's `pluginID` so the host can
clean up after `deactivate()`.

## Step-by-step: shipping your plugin

1. Clone OmniTAK-iOS:
   ```sh
   git clone https://github.com/Engindearing/OmniTAK-iOS.git
   cd OmniTAK-iOS
   ```
2. Drop your package into `plugins/your-plugin/`.
3. Open `OmniTAKMobile.xcodeproj` in Xcode and either:
   - Add the package's `Sources/` files to the `OmniTAKMobile` target via
     File > Add Files to "OmniTAKMobile"… (recommended for now), **or**
   - File > Add Package Dependencies… > Add Local… and select your
     `plugins/your-plugin/` folder.
4. Open `OmniTAKMobile/Plugins/Core/BundledPlugins.swift` and add your
   plugin to `makeAll()`:
   ```swift
   static func makeAll() -> [OmniTAKPlugin] {
       return [
           ADSBPlugin(),
           MyPlugin()
       ]
   }
   ```
5. Build & run. Open Settings → Plugins. Your plugin will be listed below
   ADS-B with a working enable/disable toggle.

## Reference: example-adsb-plugin

Study [`plugins/example-adsb-plugin/`](../plugins/example-adsb-plugin) as the
canonical example. It demonstrates:

- A `Package.swift` matching the recommended layout.
- A `OmniTAKPlugin` conformance that registers a settings row, maintains
  a long-running service tied to `activate()` / `deactivate()`, and
  exposes a non-trivial SwiftUI settings view.
- UserDefaults-backed persistence via the plugin's own keys (so user
  state survives toggle off/on cycles).

## Caveats and house rules

- **No private entitlements.** Your plugin can only do what the host app's
  entitlements already allow. Background modes, push, HealthKit, Bluetooth
  Central — all already declared on the OmniTAK app target. Anything new
  you need has to land in the host's `Info.plist` first.
- **No surprise networking.** Be a good citizen: declare your endpoints
  in your README, respect rate limits, and never beacon out without
  explicit user opt-in. ATS rules apply (HTTPS or documented exception).
- **No PII without consent.** OmniTAK ships in safety- and life-critical
  contexts. Treat user location, callsigns, and CoT contents as sensitive.
- **Match host iOS minimum.** OmniTAK targets iOS 15+. Don't use 17-only
  APIs without `@available` guards.
- **No threading shortcuts.** SwiftUI updates on `MainActor`. Long-running
  work goes off-main.

## Submitting your plugin

OmniTAK is Apache-2.0. Plugins shipped in-tree under `plugins/` follow the
same license; sign Engindearing's CLA at PR time.

PR template:

- One commit per plugin, atomic with its `Package.swift` + `Sources/`.
- README.md at `plugins/your-plugin/README.md` describing what it does,
  what API keys it needs, and any provider attribution.
- Smoke test build with the iPhone 17 Pro simulator scheme.
- No bundled binary blobs.

Naming convention:

- Folder: `plugins/<short-noun>-plugin/` (e.g. `weather-plugin`,
  `meshtastic-plugin`).
- Swift module: PascalCase (`WeatherPlugin`).
- `pluginID`: `com.<your-org>.omnitak.plugin.<short-noun>`.
