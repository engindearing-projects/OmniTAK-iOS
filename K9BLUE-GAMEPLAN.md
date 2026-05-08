# OmniTAK iOS — definitive gameplan & K9Blue rundown

_Synthesized 2026-05-08 from a hands-on TROP TestFlight walkthrough + parallel codebase audit._

## Reality after the audit

I underclaimed our codebase by a lot. The radial menu + Settings + service layer already implement **most** of what TROP markets as discrete features. Several "missing" items are actually **already in code**, just not surfaced or default.

### Already shipped (verified by file path)

| Feature | OmniTAK iOS file |
|---|---|
| Bottom 5-tab nav (Map / Chat / Servers / Mesh / Settings) | `RootTabView.swift` |
| Full-screen map | `RootTabView.swift → ATAKMapView()` |
| Radial menu (Pin / Navigate / Measure / Draw / Layers / Save / Mode) | `RadialMenuModels.swift` (full enum) |
| Drawing primitives — line, circle, polygon | `RadialMenuPresets.swift` |
| Range / bearing / distance / area | `MeasurementCalculator.swift` |
| Route Navigation (ATAK-Style) | `NavigationSettingsView.swift` |
| MGRS grid overlay + coord format | `SettingsView.swift` |
| Breadcrumb trails with rendering + color picker | `BreadcrumbTrailOverlay.swift` |
| TAK TCP / TLS / mTLS + CSR enrollment | `CSRGenerator.swift`, `MultiServerFederation.swift` |
| Multi-server federation | `MultiServerFederation.swift` |
| Data Package (.zip) import w/ certs | `DataPackageImportView.swift` |
| CoT XML parser + marker rendering | `CoTMessageParser.swift` |
| MapLibre 5 styles (liberty / bright / positron / streets / dark) | `MapLibreService.swift` |
| ADS-B traffic (4 providers) | `ADSBTrafficService.swift`, `ADSBModels.swift` |
| Video feeds — HLS / RTSP / SRT (VLCKit) | `VideoStreamModels.swift` |
| Photo + EXIF attachments | `PhotoAttachmentService.swift` |
| Meshtastic BLE + TCP | `MeshtasticTCPClient.swift` |
| Plugin SDK scaffolding | `PluginsListView.swift`, `PluginSettingsManager.swift` |
| First-run onboarding (4 pages) | `FirstTimeOnboarding.swift` |
| MIL-STD-2525 affiliation enum (icons not loaded yet) | `PointMarkerModels.swift → MarkerAffiliation` |
| Tactical dark theme | `MapLibreService.swift dark`, `BloodhoundView.swift` |
| Status bar (server, rates, time) | `NetworkStatusBar.swift` |

### Hidden features we hadn't even claimed (now confirmed in code)

- **Viewshed / Line-of-Sight analysis** — `LineOfSightService.swift`, `ViewshedSector` (advanced terrain SA — TROP doesn't ship this)
- **KML / KMZ import** — `KMLParser.swift`, `KMLHandler.swift`, `KMLMapIntegration.swift`
- **Geofence primitives** — parsed from data packages via `MissionPackageModels.swift`
- **Team roster storage** — `TeamStorageManager.swift` for multi-unit ops
- **OpenTopoMap tile reference already in code** — `OfflineMapModels.swift` references topo tiles; just not exposed as a default `MapLibreStyle`

## True remaining gaps vs TROP

After the audit, the **actually-missing** list is:

1. **Topo basemap as a default** — code has the tile reference; needs a `MapLibreStyle.topo` case + default flip. **~30 min**
2. **Default TAK server pre-configured at first run** — empty list today. **~1h**
3. **Per-permission "why" cards** — we have 4-page onboarding; TROP has 8 with per-permission rationale. **~4h** to expand
4. **i18n** — English only; need at minimum Polski + French strings. **~1 day** for LLM-pass + native review
5. **MIL-STD-2525 affiliation icons** — enum exists, glyphs need loading from TAKAware. **~3-6h**
6. **14 ATAK team colors + Combat Role + Position pickers at signup** — **~2h**
7. **Dedicated Missions UI** — backend partly there; needs mission tab + CRUD UI. **~1-2 days**
8. **Dedicated Alerts center** — notification log + map deep-link. **~4-6h**
9. **Dedicated Groups / squads view** — server-synced roster. **~1 day**
10. **Cache size knobs** in Settings — Memory MB / Disk MB. **~2-3h**
11. **Offline routing tiles** (Valhalla / GraphHopper) — multi-day, Tier 3
12. **Radial menu floating on map** (no grey backplate) — `RadialMenuView.swift:73` `.fill(glassBgColor)` → `.fill(Color.clear)`. **~5 min**

**Tier 1 total: 6-12 hours of work to close the most-visible first-impression gaps.**

## What TROP has that we shouldn't try to copy

- **Right-side menu panel** — TROP's primary nav consumes ~30% of map area. Our full-screen map is a **strict UX win** (J's rule). Don't copy.
- **TROP server (their own backend)** — We're TAK-server-native + OpenTAKServer-native. Building a third backend is wasted effort. Stay client-pure.

## OmniTAK strengths (publicly defensible, all evidence-backed)

- Apple App Store distribution — TROP cannot follow
- Full-screen map (no permanent panel)
- Radial menu (TROP doesn't have one)
- 5-tab bottom nav (more thumb-reachable)
- ADS-B with 4 providers (OpenSky / dump1090 / adsbExchange / FlightRadar24)
- HLS + RTSP + SRT video (all 3 verified in code)
- Plugin SDK scaffolding (verified in code)
- Viewshed / Line-of-Sight analysis (TROP doesn't ship this)
- KML / KMZ import
- Meshtastic over **both** BT and TCP/WiFi (TROP only does BT in our captures)

## What we will NOT claim about TROP publicly

To keep K9Blue's comparison post defensible:

- ❌ **LoRaWAN support** — claimed in marketing copy; we have zero in-app evidence
- ❌ **Plugin / SDK extensibility** — not advertised
- ❌ **Specific video formats beyond HLS** — only HLS visually confirmed
- ❌ **Mission CRUD depth** — we saw the menu item, not the implementation
- ❌ **Specific offline routing engine** (don't name Valhalla/GraphHopper for them)
- ❌ **mTLS / encryption depth** — not addressed in screenshots

Safe public framing for these areas: *"TROP advertises X; we couldn't verify how deep it goes."*

## Definitive gameplan

### Sprint 1 (this week)
- [ ] Topo basemap default + basemap picker — `MapLibreService.swift` + `OfflineMapModels.swift` (tile ref already there)
- [ ] Default `omnitak.dev.engindearing.soy` server pre-configured at first run
- [ ] Radial menu — remove grey backplate (`RadialMenuView.swift:73`)
- [ ] MIL-STD-2525 icons — vendor TAKAware `IconData.swift` + iconset
- [ ] 14 ATAK team colors + Combat Role + Position at signup

### Sprint 2 (next 1-2 weeks)
- [ ] Per-permission "why" onboarding screens (extend `FirstTimeOnboarding.swift` from 4 → 8 pages)
- [ ] Dedicated Missions UI — server missions API CRUD
- [ ] Dedicated Alerts center
- [ ] Dedicated Groups / squads view
- [ ] Cache size knobs in Settings

### Sprint 3 (depth plays)
- [ ] i18n — Polski + French
- [ ] Offline routing tiles (Valhalla)
- [ ] Sectors / control zones as named drawing primitives
- [ ] TAKAware `EmergencyView` → Casevac/9-line form

## Rundown for K9Blue (paste-ready)

> **OmniTAK iOS — what's shipped, what's coming, where we differ from TROP**
>
> **Already shipped** (iOS App Store + TestFlight): bottom 5-tab nav (Map/Chat/Servers/Mesh/Settings), full-screen map view, long-press radial menu (Pin / Navigate / Measure / Draw / Layers / Save / Mode), ATAK-style route navigation, range / bearing / distance / area measurement, point/line/circle/polygon drawing, MGRS grid overlay + coord format, breadcrumb trails with rendering + color picker, TAK Server TCP/TLS/mTLS + CSR enrollment on 8446, multi-server federation, data package (.zip) import with cert bundles, CoT XML parser + marker rendering, KML/KMZ import, MapLibre with 5 styles, ADS-B (OpenSky/dump1090/adsbExchange/FR24), HLS/RTSP/SRT video feeds via VLCKit, photo + EXIF attachments, Meshtastic over BLE + TCP/WiFi, plugin SDK scaffolding, viewshed / line-of-sight analysis, geofence primitives, team roster storage, MIL-STD-2525 affiliation enum, tactical dark theme, status bar with server rates, 4-page first-run onboarding.
>
> **Now (this sprint):** topo basemap as default, basemap picker, default TAK server pre-configured at first run, MIL-STD-2525 affiliation icons (vendoring from Flight Tactics' TAKAware under Apache-2.0 with attribution), 14 ATAK team colors + Combat Role + Position pickers, radial menu floating on map (no backplate).
>
> **Next:** 8-page onboarding with per-permission rationale, dedicated Missions / Alerts / Groups UIs, cache size knobs in Settings, sectors / control zones as named drawing primitives.
>
> **Later:** Polski + French i18n, offline routing tiles, casevac / 9-line emergency form.
>
> **Where OmniTAK leads:** App Store distribution (one-tap install, no MDM), full-screen map (no permanent panel), radial menu, ADS-B with 4 providers, HLS + RTSP + SRT video, plugin SDK, viewshed / LOS analysis, Meshtastic over both BT and TCP/WiFi.
>
> **Where TROP leads today:** topo basemap default, 8-step per-permission onboarding, default dev server pre-configured, multi-language UI (English / Polski / French), explicit Missions / Groups / Alerts UIs, offline routing, cache size knobs.
>
> **Try it:**
> - iOS App Store: search "OmniTAK"
> - TestFlight: https://testflight.apple.com/join/SzxQGmMM
> - Android (Play closed testing): https://play.google.com/apps/testing/soy.engindearing.omnitak.mobile
> - iOS source: https://github.com/engindearing-projects/OmniTAK-iOS
> - Android source: https://github.com/engindearing-projects/OmniTAK-Android
