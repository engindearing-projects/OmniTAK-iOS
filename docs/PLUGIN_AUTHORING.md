# OmniTAK Plugin SDK: Authoring Guide (iOS)

This describes the **shipped** OmniTAK plugin SDK on iOS: the `OmniTAKPlugin`
protocol, the four host hooks, the ADS-B reference plugin, and how to add your
own plugin.

The SDK is deliberately the same shape on Android (same hook names, same
reverse-DNS `pluginId`) so a plugin ports across platforms in about a day.

---

## What a plugin is (and the two hard rules)

A plugin is a **compile-time Swift class** that conforms to `OmniTAKPlugin`
and is registered at app start. Two non-negotiable constraints follow from
shipping on the App Store:

1. **No dynamic code.** There is no DEX/dylib loading, no remote code, no
   download-and-run. A plugin is Swift source linked into the app binary and
   added to the registry in `PluginRegistry.loadBundledPlugins()`. This keeps
   OmniTAK App-Store compliant.

2. **No sandbox.** A plugin runs **in the host process with the host app's
   full permissions** (network, location, files, etc.). Treat a plugin's code
   as part of the app. Reviewers must read it the same way they'd read any
   app code.

---

## The protocol

```swift
protocol OmniTAKPlugin: AnyObject {
    var pluginId: String { get }          // reverse-DNS, e.g. "soy.engindearing.adsb"
    var displayName: String { get }
    var pluginVersion: String { get }     // semver, e.g. "1.0.0"
    var pluginAuthor: String { get }
    var pluginDescription: String { get }

    func activate(host: PluginHost)        // register your hooks here
    func deactivate()                      // stop your work; hooks auto-removed
    func settingsContent() -> AnyView?     // optional settings UI (default nil)
}
```

`pluginId` is the **stable key** for everything: enable-state persistence, hook
ownership, and cross-platform settings portability. Pick it once and never
change it.

`settingsContent()` returns a **type-erased** `AnyView?` (not `some View`) so
the registry can hold a heterogeneous list of plugins. Default is `nil`.

---

## The four host hooks

`activate(host:)` receives a `PluginHost`. Register through it:

| Hook | What it does |
|------|--------------|
| `registerMapOverlay { AnyView(...) }` | A SwiftUI overlay mounted in the engine-agnostic map chrome. It renders on **both** map engines (Cesium 3D + Mapbox 2D), above the map and below the radial menu. Non-interactive by default. |
| `registerRadialAction(item, onSelect:)` | Adds an entry to the empty-map long-press **radial menu**. `onSelect(coordinate)` fires with the pressed map coordinate. The entry is gated by the plugin's enable flag. |
| `registerCoTHandler { event in ... }` | Called for **every inbound CoT position event after the core store ingests it**. Return `true` to mark the event consumed (short-circuits remaining handlers). Runs on the **main thread**: keep it cheap. |
| `registerSettingsRow(label:icon:)` | Adds a row to Settings → Plugins that navigates into your `settingsContent()`. `icon` is an SF Symbol name. |

Hooks are tagged with your `pluginId` automatically, so `deactivate()` cleanly
removes them, you don't have to unregister manually.

---

## The ADS-B reference plugin

`ADSBPlugin` (`soy.engindearing.adsb`) is the canonical example. It wraps the
existing ADS-B traffic feature **with zero behavior change**:

- It uses **`registerMapOverlay`** (a thin status surface, `ADSBStatusOverlay`,
  which renders `EmptyView`) and **`registerSettingsRow`** ("ADS-B").
- `settingsContent()` returns the existing `ADSBTrafficView()` verbatim.
- `deactivate()` flips `ADSBTrafficService.shared.settings.isEnabled = false`,
  reusing the service's existing `didSet → stopTracking()`.

> **Why the aircraft rendering path is untouched.** ADS-B does not draw through
> a SwiftUI overlay, aircraft flow as a `[Aircraft]` data array straight into
> both map engines. That proven pipeline stays byte-identical; the plugin only
> adds discovery, enable/disable, and a settings entry point.

`ADSBPlugin` registers two of the four hooks. The internal **`DiagnosticsPlugin`**
(`soy.engindearing.diagnostics`, **off by default**) exercises the other two:
`registerRadialAction` (a "Diag" entry) and `registerCoTHandler` (an event
counter): so the whole host surface is wired and tested. `PluginSDKTests`
covers all four hooks regardless of enable state.

---

## How to add a plugin

1. **Create a file** in a plugin group, e.g.
   `OmniTAKMobile/Features/MyFeature/Plugin/MyPlugin.swift`.
2. **Conform** a `final class` to `OmniTAKPlugin`. Give it a unique reverse-DNS
   `pluginId`. Register your hooks in `activate(host:)`.
3. **Register it** in `PluginRegistry.loadBundledPlugins()`:
   ```swift
   func loadBundledPlugins() {
       register(ADSBPlugin())
       register(DiagnosticsPlugin())
       register(MyPlugin())   // <- add this line
   }
   ```
4. **Add the file to the Xcode target.** The pbxproj uses explicit file
   references, so a new `.swift` file must be added to the `OmniTAKMobile`
   target's Sources build phase or it won't compile in. Use the helper:
   ```bash
   # edit scripts/add_plugin_sdk_files.rb to list your file, then:
   ruby scripts/add_plugin_sdk_files.rb
   ```
   (or add it via Xcode's "Add Files to OmniTAKMobile...").
5. **Default enable state.** Bundled plugins default **ON** on first run so
   first-time users see plugin features. To ship OFF by default, add your
   `pluginId` to `PluginSettingsManager.registeredDisabledByDefault`.
6. **Open a PR**, or **fork and sign your own build** (see `CONTRIBUTING.md`).
   Because plugins are compiled in, distributing a plugin means distributing a
   build, either upstream via PR or your own signed fork.

---

## Where the SDK lives

| File | Role |
|------|------|
| `OmniTAKMobile/Core/Plugin/OmniTAKPlugin.swift` | the plugin protocol |
| `OmniTAKMobile/Core/Plugin/PluginHost.swift` | the four-hook host protocol |
| `OmniTAKMobile/Core/Plugin/AppPluginHost.swift` | concrete host; holds registered hooks |
| `OmniTAKMobile/Core/Plugin/PluginRegistry.swift` | compile-time registry + activation |
| `OmniTAKMobile/Core/Plugin/DiagnosticsPlugin.swift` | internal test plugin (radial + CoT) |
| `OmniTAKMobile/Features/ADSB/Plugin/ADSBPlugin.swift` | ADS-B reference plugin |
| `OmniTAKMobileTests/PluginSDKTests.swift` | host-surface coverage |

The four seams the host wires into:

- **Map overlay**: `MapViewController.registeredPluginOverlays` (inside the
  engine-agnostic `mapChrome`, so both engines get it).
- **Radial**: `RadialMenuMapCoordinator.configureMapMenu` appends registered
  items; `RadialMenuActionExecutor.executeCustomAction` fires `onSelect`.
- **CoT**: `CoTEventHandler.handlePositionUpdate` calls `dispatchCoT` after
  the core store ingest.
- **Settings**: `PluginsListView` lists `PluginRegistry.shared.all()`.
