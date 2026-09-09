# OmniTAK iOS 2.41.0

Server setup gets more flexible, the 2D map takes any tile server, and two
fixes land for reports filed by users on GitHub. Everything here has been on
`main` since mid August; this is the build that gets it to the App Store.

## Servers
- **Per-server Marti API port.** Mission Sync and Data Sync used to assume the
  server's REST API lives on 8443, with no way to change it. Edit Server now has
  a "Marti API Port" field next to the streaming and enrollment ports. Servers
  you already saved keep working unchanged. Shared config profiles carry the
  port too. Thanks to zeidlos for the report. (#114)
- **Quick Connect over plain TCP.** The Streaming Protocol row in Advanced
  options was a mock-up; only SSL ever worked. It is now a real TCP | SSL
  selector. TCP mode skips enrollment, defaults to port 8087, shows a clear-text
  warning, and connects directly. QUIC is no longer offered until there is a
  transport behind it. Thanks to eelcocramer for the report. (#103)

## Map
- **Custom XYZ/WMTS tile basemap.** Settings > Custom Tile Basemap accepts any
  `{z}/{x}/{y}` URL template (ATAK-style `{$z}` variants included) and installs
  it as a raster layer on the 2D engine. Appears in the Layers panel once a URL
  is saved. Android parity. (#57)
- **Radial menu floats on the map.** No backing disc, no label pills, no heavy
  dim: ring-outlined icon buttons directly over the map, matching Android.

## Mesh
- **Paired-radio split.** A phone plus its paired Meshtastic radio no longer
  shows up as two drifting dots. Radios running the TAK role are hidden from the
  map by default; standalone trackers (vehicles, mission objects) stay visible.
  "Show paired radios" toggle in Meshtastic settings. (#110)
- **Mesh link-state dot.** The Mesh tab icon carries a status dot: green
  connected, amber connecting, red failed, grey no device. Same ladder as
  Android. (#110)

## Fixes
- **Done buttons on Settings and Servers return to the map.** They were silent
  no-ops when those screens ran as tabs.

---
*Build cut from `main` at 5aec01d. Marketing version 2.41.0, build 26090801,
stamped by `scripts/release-ios.sh` at archive time.*
