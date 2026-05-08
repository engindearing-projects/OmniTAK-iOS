# TROP vs OmniTAK iOS — feature delta

_Last updated 2026-05-08 from a hands-on TestFlight + iPhone Mirror walkthrough of both apps in one session._

## Headline

**We're a lot closer to parity than the TROP marketing copy suggests.** Routes, range/bearing, drawing tools, layer manager, breadcrumb trails, and MGRS are already in OmniTAK iOS — they're surfaced on the **radial menu** (long-press the map) plus the **Settings tab**, not as separate top-level features. TROP exposes them as discrete menu items, which makes them more discoverable but no more capable.

**Our standout edge is layout discipline:** OmniTAK uses the full screen for the map. TROP shrinks the map for a permanent right-side feature panel. Per J's design rule, that's a competitive moat we keep.

## TROP at a glance

- **Full name:** Taktyczny Rejestr Obserwacji i Pozycji
- **Vendor:** Defencebay.com (Polish)
- **Distribution:** TestFlight only — not on App Store
- **Languages:** English / Polski / French
- **Default server:** `devopsbay.dev.trop.defencebay.com` ships pre-configured
- **Version observed:** 0.79

## Side-by-side feature matrix

| Feature | TROP | OmniTAK iOS | Notes |
|---|---|---|---|
| **Layout** | Right panel + reduced map | Full-screen map | **OmniTAK wins** |
| Primary nav | Right-side menu list | Bottom 5-tab bar | OmniTAK more discoverable |
| Distribution | TestFlight only | App Store + TestFlight | **OmniTAK wins** |
| Onboarding | 8-step w/ per-permission "why" cards | Minimal | TROP wins on first-run polish |
| Default basemap | Topo (terrain shading) | Apple Standard | TROP wins on visual punch |
| Default server | Pre-configured TROP dev server | Empty server list | TROP wins on first-run friction |
| Multi-language | EN / PL / FR | EN only | TROP wins |
| Map | Full topo with PPLI, contacts | MapKit w/ PPLI, contacts | functional parity, basemap delta |
| Radial menu | (none — uses panel list) | **Pin / Navigate / Measure / Draw / Layers / Save / Mode** | **OmniTAK wins** |
| Routes | Routes feature in panel | "Navigate" in radial + "Route Navigation: ATAK-Style" in Settings | parity |
| Range / bearing | Distance/area/bearing tool | "Measure" in radial | parity |
| Drawing | Markers & Shapes feature | "Draw" in radial | likely parity (need to verify shape primitives) |
| Layers manager | Map Overlays panel | "Layers" in radial | parity |
| MGRS coords | (claimed in marketing) | MGRS grid overlay + coord format toggle | parity |
| Breadcrumb / track | "My Path" feature | "Breadcrumb Trails" toggle in Settings | parity |
| Chat | Messages | Team Chat tab w/ contact list | parity (we even show a TROP user in our chat list — interop confirmed) |
| Servers | Connection profile mgr | Servers tab w/ multi-server, Import .zip data pack | parity |
| Meshtastic | BT mesh | BT + TCP/WiFi | **OmniTAK wins** (TCP option) |
| Data Packages | Yes | Yes (.zip import + cert bundles) | parity |
| Photo + EXIF | Photo & Video Capture | Yes | parity |
| Video feeds | (claimed) | HLS / RTSP / SRT via VLCKit | likely **OmniTAK wins** |
| ADS-B | not advertised | 4 providers (OpenSky/dump1090/adsbExchange/FR24) | **OmniTAK wins** |
| Plugin SDK | not advertised | Swift package scaffolding | **OmniTAK wins** |
| Missions | "Missions" feature | (no dedicated UI) | TROP wins on surface |
| Groups / squads | "Groups" feature | (no dedicated UI) | TROP wins on surface |
| Alerts center | "Alerts" feature | (no dedicated UI) | TROP wins on surface |
| Offline routing | Offline → Routing tab | (tile cache only) | TROP wins |
| Offline cache config | Memory + Disk size config | (likely automatic) | TROP wins on knob exposure |

## True remaining gaps (the short list)

After ground-truthing the radial menu and Settings, the **actually missing** features are:

1. **Topo basemap as default** — biggest first-impression delta
2. **Default dev server pre-configured at first run** — kills onboarding friction
3. **Polished onboarding (8-step "why this permission" flow)** — first-impression
4. **i18n** — at minimum Polski + French strings
5. **14 ATAK team colors + Combat Role + Position pickers** at signup
6. **Dedicated Missions UI** beyond .zip import (CRUD against TAK Server missions API)
7. **Dedicated Groups / squads UI** for team org
8. **Dedicated Alerts center** (notification log + map deep-link)
9. **Offline routing tiles** (Valhalla or GraphHopper) — multi-day lift
10. **Cache size knobs** in Settings (Memory MB / Disk MB)
11. **MIL-STD-2525 affiliation icons** (vendor TAKAware)

## OmniTAK strengths to lean into

- **Full-screen map** — preserve at all costs (J's rule)
- **Radial menu** — already implements 7 of the highest-value actions; TROP has no equivalent
- **5-tab bottom nav** — better one-handed reachability than TROP's right-side menu
- **App Store distribution** — TROP literally cannot ship there
- **ADS-B** — 4 providers — TROP doesn't ship aviation
- **HLS / RTSP / SRT video** — full-stack video; TROP didn't surface this
- **Plugin SDK scaffolding** — extensibility story TROP doesn't have

## Recommended ship order — corrected

### Tier 1 — first-impression wins (this week)
1. **Topo basemap default + basemap picker** (OSM/OpenTopo/Sat/Dark) — 2h. The single most-noticeable visual delta.
2. **Default dev server pre-configured at first run** — 1h. Ship with OpenTAKServer demo creds at `tak.engindearing.soy`.
3. **Radial menu floating on map** (no grey backplate) — `RadialMenuView.swift:73` `.fill(glassBgColor)` → `.fill(Color.clear)`. 5 minutes. Per J.
4. **MIL-STD-2525 affiliation icons** — vendor TAKAware `IconData.swift` + iconset, 3-6h.
5. **14 ATAK team colors + Combat Role + Position at signup** — 2h SwiftUI form.

### Tier 2 — surface-area parity (next sprint)
6. **Per-permission onboarding screens** — 4-6h. Swiftiful 8-step flow w/ rationale for BT, Location, Notifications, Network.
7. **Dedicated Missions tab/view** — TAK Server missions API CRUD + local mission list. 1-2 days.
8. **Dedicated Alerts center** — notification log + map deep-link. 4-6h.
9. **Dedicated Groups / squads view** — server-synced team roster. 1 day.
10. **Cache size knobs in Settings** — Memory/Disk MB controls. 2-3h.

### Tier 3 — deeper plays
11. **i18n** — Polski + French (LLM-pass + native review).
12. **Offline routing tiles** — Valhalla integration. Multi-day.
13. **Sectors / control zones** as named drawing primitives.
14. **TAKAware EmergencyView → Casevac/9-line** form.

## Borrow-or-build sourcing

- **TAKAware (Apache-2.0)** — MIL-STD-2525, MGRS already (we have ours), KML/KMZ, bearing math, EmergencyView, CoT, data packages, CSR. Vendor file-by-file with attribution.
- **MapLibre** — already in stack; basemap swap is config-only.
- **Valhalla / GraphHopper** — offline routing (Tier 3).

## Strategic positioning for K9Blue's comparison

Honest framing for the public comparison post:

> "TROP and OmniTAK iOS overlap on most core TAK features (map, chat, servers, mesh, drawing, routes, range/bearing, breadcrumbs, layers, data packages). OmniTAK leads on the App Store path, full-screen map layout, ADS-B, RTSP/SRT video, and plugin SDK. TROP leads on first-run onboarding polish, default topo basemap, multi-language UI, dedicated UIs for Missions/Groups/Alerts, and offline routing."

That's defensible, honest, and lets him write the comparison without us having to overclaim.

## What we still couldn't verify

- TROP's actual drawing primitives (couldn't open Markers & Shapes — Catalyst pickers eat synthetic clicks)
- TROP's Combat Role list (dropdown didn't open in walkthrough)
- TROP's mission CRUD vs local-only mission storage
- TROP's video feed format support (HLS confirmed, RTSP/SRT not)
- TROP's plugin or extensibility story (none advertised)
- OmniTAK's drawing primitives depth via Draw radial action (next walkthrough)
