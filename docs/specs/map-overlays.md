# Map Overlays — GeoPDF / KML / KMZ (Issue #17)

**Status:** In progress (KML/KMZ path landing). GeoPDF deferred.
**Source:** K9Blue SAR feedback (Discord, 2026-05-10).
**Owner:** Engie

## Problem

SAR teams plan against:
- **GeoPDF** — USGS topo, USFS, county GIS deliverables with embedded georeferencing.
- **KML / KMZ overlay** — CalTopo, Google Earth route plans, hasty-search boundaries.

OmniTAK-iOS reads KML during mission/data-package import, but it converts everything to interactive markers + drawings. SAR users want a quiet, opacity-controllable raster/vector layer above the basemap and below their tactical markers.

## Goals

1. Settings → MAPS section gets a dedicated entry point: **Add Map Overlay**.
2. Supported formats today: **KML**, **KMZ**.
3. Supported formats deferred: **GeoPDF** (parser is genuinely hard — needs LGIDict / OGC GeoPDF coordinate transform walking; see [Deferred work](#deferred-work)).
4. Per-overlay UX: **opacity slider (0–100%)**, **visible toggle**, **rename**, **delete**.
5. **Offline.** Source file is stored locally; overlay re-hydrates on app launch without network.
6. **Render order:** above basemap, below all tactical markers/drawings.

## Non-goals

- Editing overlay geometry inside the app.
- Conversion overlay ↔ CoT features (existing KML import path already does that; this is the *separate* "passive layer" path).
- Per-feature styling overrides (per-overlay tint + alpha only).

## Architecture

### Domain model

> **Naming note:** the type is `UserMapOverlay` (not `MapOverlayDescriptor`) to
> avoid collision with the existing `Plugins/Core/OmniTAKPlugin.swift`
> `MapOverlayDescriptor` (which is the plugin-SwiftUI-view overlay descriptor).
> "User" disambiguates: this descriptor models a user-imported geo file, the
> plugin one models a plugin-supplied SwiftUI overlay view.

```swift
enum UserMapOverlayKind: String, Codable {
    case kml
    case kmz
    case geoPDF       // Deferred: parser not implemented
}

struct UserMapOverlay: Codable, Identifiable {
    let id: UUID
    var name: String
    var kind: UserMapOverlayKind
    var sourceFileName: String       // file relative to overlays directory
    var importedAt: Date
    var bounds: UserMapOverlayBounds?    // nil if not yet computed
    var opacity: Double              // 0.0 ... 1.0
    var isVisible: Bool
}

struct UserMapOverlayBounds: Codable {
    var minLat: Double
    var maxLat: Double
    var minLon: Double
    var maxLon: Double
}
```

### Components

| Component | Responsibility |
|-----------|----------------|
| `UserMapOverlay` | Lightweight metadata stored in `Documents/map_overlays.json`. |
| `UserMapOverlayManager` (ObservableObject) | CRUD over descriptors. Owns disk storage at `Documents/MapOverlays/`. Delegates KML/KMZ parsing to existing `KMLParser` + `KMZHandler`. Produces `MKOverlay`s on demand. |
| `KMLOverlayRenderer` | Pure-function utility — given parsed KML geometry, returns `MKOverlay`s (`MKPolygon`, `MKPolyline`). Testable in isolation. |
| `MapOverlaysListView` | SwiftUI list of descriptors with opacity slider + visible toggle + delete. Shown as a **modal sheet** from Settings (full-screen map is sacred — see [feedback_omnitak_fullscreen_map]). |
| `AddMapOverlayPicker` | `.fileImporter` over `[.kml, .kmz]`. GeoPDF row is listed but disabled with "Coming soon". |

### Data flow

```
User taps "Add Map Overlay" (Settings)
   -> sheet AddMapOverlayPicker
   -> .fileImporter (KML/KMZ only)
   -> MapOverlayManager.importFile(url:)
        - copies file to Documents/MapOverlays/<uuid>.kml(z)
        - parses via KMLParser (+ KMZHandler if .kmz)
        - computes bounds across all geometry
        - writes UserMapOverlay to disk
   -> MapOverlaysListView updates
   -> next time MapViewController consults the manager,
      KMLOverlayRenderer.makeOverlays(from: parsedDoc, descriptor:)
      produces MKPolygon/MKPolyline tagged with the descriptor id.
   -> rendererFor: returns MKPolygonRenderer / MKPolylineRenderer
      with stroke/fill alpha multiplied by descriptor.opacity
      and hidden entirely when !descriptor.isVisible.
```

### KML overlay path (this iteration)

We **reuse** the existing `KMLParser` (`Utilities/Parsers/KMLParser.swift`) and `KMZHandler` (`Utilities/Parsers/KMZHandler.swift`). Those parse KML into `KMLDocument` / `KMLPlacemark` / `KMLGeometry`.

The new `KMLOverlayRenderer` (`Utilities/Integration/KMLOverlayRenderer.swift`) provides:

```swift
enum KMLOverlayRenderer {
    /// Convert all parseable KML geometry into MKOverlays for passive map display.
    /// Points are intentionally skipped — overlay = quiet shading layer, not markers.
    static func makeOverlays(from document: KMLDocument,
                             overlayId: UUID) -> [MKOverlay]

    /// MKOverlayRenderer factory respecting per-overlay opacity + visibility.
    static func renderer(for overlay: MKOverlay,
                         descriptor: UserMapOverlay) -> MKOverlayRenderer?
}
```

This sits next to (and is intentionally distinct from) `KMLOverlayManager.swift`, which is the existing **feature-ingest** path. The two won't be merged here — different UX contracts.

### Storage

```
~/Library/Application Support/<bundle>/Documents/
├── MapOverlays/
│   ├── <uuid-a>.kml
│   ├── <uuid-b>.kmz
│   └── <uuid-c>.pdf            (future, GeoPDF)
└── map_overlays.json           (array of UserMapOverlay)
```

Atomic writes. Manager `init()` reads JSON and re-parses each descriptor file on demand.

### Z-order

Existing `MapOverlayType.kmlOverlays.zOrder = 50` (defined in `MapOverlayCoordinator.swift`). Tactical markers / drawings render above this. Basemap tiles render below.

### Opacity UX

`Slider(value: $overlay.opacity, in: 0...1)` with the canonical (0–100%) labels. Applied as `renderer.alpha = overlay.opacity`. Visibility toggle is a simple `Toggle` row; off → overlay removed from `mapView.overlays`.

## Deferred work

### GeoPDF parser
- **Why deferred:** Adobe GeoPDF and OGC GeoPDF have different metadata layouts. Adobe stores georeferencing in an LGIDict in the PDF page dictionary; OGC stores it as a Viewport entry with Measure/GeographicCoordinateSystem keys. Either way you have to walk the PDF object graph by hand (CoreGraphics surfaces the page but not these custom dicts).
- **Next-session plan:**
  1. Evaluate vendoring **Flight Tactics' Swift map renderer** (Apache-2.0, see `reference_takaware_source`) for prior art on GeoPDF reads. We already pull MIL-2525 + MGRS from that codebase.
  2. If no usable upstream, write a focused `GeoPDFParser` that reads the LGIDict via `CGPDFDocument` / `CGPDFDictionary` and produces a projection transform plus the rendered page bitmap.
  3. Wrap as `MKTileOverlay`-style tiling for large pages.
- **Estimated scope:** 1–2 focused sessions once the parsing approach is chosen.
- **Tracking:** keep on Issue #17 with checklist; do not split until the parser direction is settled.

### Cross-platform parity
- Sibling Android issue must mirror the same `UserMapOverlay` contract so a future shared SQLite/JSON sync can roundtrip.

## Test strategy

**Caveat:** The Xcode project still has no `OmniTAKMobileTests` PBXNativeTarget (per release notes 2.18.0). Test files in `OmniTAKMobileTests/` are orphan source today. New tests use the same convention — they will activate automatically the moment a test target is wired up.

For this issue, the canonical TDD test is:

```swift
// OmniTAKMobileTests/KMLOverlayRendererTests.swift
func testParseAndRenderClosedPolygon() throws {
    let kml = #"""
    <kml xmlns="http://www.opengis.net/kml/2.2"><Document>
      <Placemark><name>Search Boundary</name>
        <Polygon><outerBoundaryIs><LinearRing><coordinates>
          -117.5,47.6,0 -117.4,47.6,0 -117.4,47.7,0 -117.5,47.7,0 -117.5,47.6,0
        </coordinates></LinearRing></outerBoundaryIs></Polygon>
      </Placemark>
    </Document></kml>
    """#
    let doc = try KMLParser(fileName: "t.kml").parse(data: Data(kml.utf8))
    let overlays = KMLOverlayRenderer.makeOverlays(from: doc, overlayId: UUID())
    XCTAssertEqual(overlays.count, 1)
    let polygon = try XCTUnwrap(overlays.first as? MKPolygon)
    XCTAssertEqual(polygon.pointCount, 5)
}
```

For local TDD without a test target, the same logic can be exercised with a tiny `swift run`-style harness under `OmniTAKMobileSpecs/`. Each iteration:

1. **RED:** test fails because `KMLOverlayRenderer` doesn't exist.
2. **GREEN:** add `KMLOverlayRenderer.makeOverlays(...)` using existing `KMLParser` output.
3. **Build verify:** `xcodebuild -scheme OmniTAKMobile -configuration Debug -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.

## Open questions

- Should overlay z-order be user-controllable (drag-to-reorder)? **Not this iteration.** Single z-band is enough for SAR's stated need.
- Should we cap total overlay file size? **Soft cap at 100 MB combined** to avoid blowing out Documents storage on small devices. Defer enforcement to a later cleanup pass.
