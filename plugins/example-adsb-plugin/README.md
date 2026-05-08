# example-adsb-plugin

The reference OmniTAK iOS plugin. Real, shipping code — `ADSBPlugin` is
loaded by `PluginRegistry` at app startup and feeds aircraft markers to
the tactical map.

## What it does

Streams ADS-B aircraft positions from one of six configurable providers:

- **OpenSky Network** — free academic tier, no key required.
- **dump1090 / ADSB.lol** — community feed, no key required.
- **adsbExchange** — RapidAPI key required.
- **FlightRadar24** — Bearer token required.
- **FlightAware** — `x-apikey` required.
- **Custom** — user-defined URL with `{lat}` `{lon}` `{radius}` placeholders.

The plugin renders aircraft as `MKAnnotation`s with rotated SVG icons and
exposes a SwiftUI settings view for choosing provider, location, refresh
interval, and altitude filters.

## Why it ships in-tree

`example-adsb-plugin` is the canonical reference for plugin authors. It
demonstrates:

- The layout convention third-party plugins should mirror.
- A non-trivial `OmniTAKPlugin` implementation that owns a long-running
  service.
- UserDefaults-backed persistence inside the plugin.
- A real SwiftUI settings view returned via `settingsView()`.

For the protocol, host API, and step-by-step authoring instructions, see
[`docs/PLUGIN_AUTHORING.md`](../../docs/PLUGIN_AUTHORING.md).

## License

Apache-2.0, same as the host app.
