//
//  CesiumMainMap.swift
//  OmniTAKMobile
//
//  The 3D Cesium engine: WKWebView representable + JS bridge
//  coordinator. The scene HTML is a bundled resource (cesium_scene.html).
//  Extracted from MapViewController.swift — mechanical move, no behavior change.
//

import SwiftUI
import MapKit
import CoreLocation
import WebKit
import UIKit

// MARK: - Cesium 3D main-map engine (Phase 1 + Phase 2 bridge)

/// Full-screen WKWebView hosting the Cesium 3D scene as the main map.
/// Phase 2: a JS↔native bridge pushes CoT contacts, aircraft, and the
/// operator's self-position into Cesium as `window.OmniBridge` entities
/// at real altitude. The HTML is kept in lockstep with the Android
/// `assets/cesium_scene.html` so both platforms render the same scene
/// from the same bridge contract.
/// Phase 4a — bidirectional event from the Cesium scene back to native.
/// The HTML posts `{event, lat, lon, hae, screenX, screenY, uid?}` via
/// `window.webkit.messageHandlers.omniMapEvent`; we decode it into this
/// struct so the SwiftUI shell can drive the radial menu and contact
/// edit flows the same way the 2D Mapbox path does.
struct CesiumMapEvent {
    enum Kind { case tap, longpress, cameraChanged, lasso, move }
    let kind: Kind
    /// For `.move`, this is the drag's CURRENT globe point; `moveFromCoordinate`
    /// is the previous one, so the delta is (coordinate − moveFromCoordinate).
    let coordinate: CLLocationCoordinate2D
    let screenPoint: CGPoint
    /// Cesium Entity id that was picked under the cursor, or nil for an
    /// empty-map gesture. Matches the uid we ship to `setEntities` —
    /// `__self__`, raw CoT uids, `ads-<id>`, `line-…`, etc.
    let entityUid: String?
    /// Camera state, only populated for `.cameraChanged` events.
    let camera: CameraState?
    /// Globe point under the screen center (aim crosshair) on
    /// `.cameraChanged` — the correct point-drop / region center when tilted.
    let centerCoordinate: CLLocationCoordinate2D?
    /// Freehand lasso polygon (lat/lon vertices) for a `.lasso` event.
    let polygon: [CLLocationCoordinate2D]?
    /// Drag origin for a `.move` event (issue #60) — the globe point under the
    /// finger on the PREVIOUS frame. `coordinate` holds the current frame, so
    /// the rigid-translate delta is (coordinate − moveFromCoordinate).
    let moveFromCoordinate: CLLocationCoordinate2D?

    struct CameraState {
        let height: Double      // metres above ellipsoid
        let heading: Double     // degrees CW from north
        let pitch: Double       // degrees (negative = looking down)
        let zoom: Double        // Mapbox-style zoom, derived from height
    }
}

/// Cesium Ion access token, injected at build time from the gitignored
/// Config.xcconfig via the Info.plist `CesiumIonToken` key — the exact same
/// pattern as the Mapbox `MBXAccessToken`. NEVER hardcode the token in source:
/// this repo is public. An empty token just means Ion-hosted assets (world
/// terrain) don't load; the globe itself still renders.
enum CesiumIonConfig {
    static let token: String =
        (Bundle.main.object(forInfoDictionaryKey: "CesiumIonToken") as? String) ?? ""
}

extension Notification.Name {
    /// Posted by the toolbar zoom buttons so the Cesium coordinator can zoom
    /// the globe's camera (mapRegion can't drive it). userInfo["factor"]: Double.
    static let cesiumZoom = Notification.Name("cesiumZoom")
    /// Posted by `handleCenterMapOnContact` so the Cesium coordinator can fly
    /// the globe's camera to a contact's position (mapRegion only drives the
    /// 2D engine). userInfo["lat"]: Double, userInfo["lon"]: Double.
    static let cesiumCenterOn = Notification.Name("cesiumCenterOn")
    /// Posted by the Cesium coordinator's load watchdog when the globe fails to
    /// initialize within the timeout (e.g. the cesium.com CDN is unreachable).
    /// `ATAKMapView` falls the map back to the 2D engine so the user isn't
    /// stuck on an infinite "Loading 3D world…" spinner.
    static let cesiumLoadTimedOut = Notification.Name("cesiumLoadTimedOut")
    /// Issue #72/#73 — snap the Cesium globe heading back to north (0°).
    /// Posted by the compass overlay tap or the north-lock toggle.
    static let cesiumResetNorth = Notification.Name("cesiumResetNorth")
    /// Issue #72 — engage/release the Cesium north-up lock. userInfo["on"]: Bool.
    /// When on, the globe stays north-up (heading pinned to 0°) while pan/zoom/
    /// tilt stay live; the JS side instantly re-snaps any heading drift.
    static let cesiumSetNorthLock = Notification.Name("cesiumSetNorthLock")
}

struct CesiumMainMap: UIViewRepresentable {
    let contacts: [CoTMarker]
    let aircraft: [Aircraft]
    let lineDrawings: [LineDrawing]
    let circleDrawings: [CircleDrawing]
    let polygonDrawings: [PolygonDrawing]
    // Drawing-tool point markers (DrawingStore.markers — MarkerDrawing).
    // The 2D Mapbox path renders these via refreshDrawingMarkers(); without
    // this parameter the 3D engine never saw a drawing marker, so a dropped
    // drawing-tool pin was invisible on the globe (issue #61). Distinct from
    // `pointMarkers` (PointDropperService) — these come from the Draw tools.
    let markerDrawings: [MarkerDrawing]
    let rangeRings: [RangeRing]
    // Dropped point markers (PointDropperService). The 2D Mapbox path
    // renders these via refreshPointMarkers(); without this the 3D
    // engine never saw a dropped pin and nothing appeared — the App
    // Store "drop does nothing" regression.
    let pointMarkers: [PointMarker]
    let selfLocation: CLLocation?
    /// When true (GPS follow mode), keep the Cesium camera centered on the
    /// operator as `selfLocation` updates, preserving current zoom/tilt/heading.
    var isFollowing: Bool = false
    /// When true (lasso mode), lock the globe camera and capture a freehand
    /// drag for multi-select; the polygon is posted back as a `.lasso` event.
    var lassoActive: Bool = false
    /// Issue #60 (move/reposition follow-up) — when true (drawing reposition
    /// mode), lock the globe camera and capture a single-finger drag; each
    /// step is posted back as a `.move` event carrying the previous→current
    /// globe coordinates so the native side rigidly translates the shape.
    var drawingMoveActive: Bool = false
    /// Base imagery layer for the globe ("satellite" | "hybrid" | "standard").
    var baseLayer: String = "satellite"
    /// Issue #72 — north-up lock. When true the globe is pinned north-up
    /// (heading 0°) while pan/zoom/tilt stay live. Applied on change and
    /// re-applied on bridge-ready so it survives engine toggles / restarts.
    var isNorthLocked: Bool = false
    let selfCallsign: String
    /// Self-position marker style from Settings ("milstd" | "bullseye").
    /// "milstd" renders the SFGPUCI---- milsymbol frame; "bullseye" falls
    /// back to the friendly canvas disc + center dot (the bullseye analog
    /// in the HTML's `_billboard` path).
    var selfMarkerStyle: String = "milstd"
    // Phase 3b — measurement sessions to mirror as dashed polylines with
    // per-segment distance labels. Sourced from `MeasurementManager`.
    let measurements: [Measurement]
    // Live in-progress measurement vertices (MeasurementManager's
    // temporaryPoints while a measurement is active). Mirrored as a yellow
    // polyline with per-segment labels so the globe shows the measurement
    // as it's built — parity with the Mapbox path's systemYellow temp line.
    // Empty when no measurement is active.
    var liveMeasurementPoints: [CLLocationCoordinate2D] = []
    // Live in-progress DRAWING vertices (DrawingToolsManager.temporaryPoints
    // while a line/polygon/circle is being placed). Mirrored as a solid line
    // + vertex dots in the active drawing color so the globe shows the shape
    // as the operator taps — parity with the Mapbox temp overlay (issue #63).
    // Empty when no drawing is in progress. `liveDrawingMode` tells the bridge
    // whether to close the ring (polygon) and how to render a circle preview.
    var liveDrawingPoints: [CLLocationCoordinate2D] = []
    /// "line" | "polygon" | "circle" | nil — the in-progress drawing kind so
    /// the temp overlay matches the committed shape (closed ring for polygon,
    /// radius preview for circle). Nil when no drawing is active.
    var liveDrawingMode: String? = nil
    /// Active drawing color as "#RRGGBB" so the temp shape reads the same as
    /// the committed drawing. Defaults to the systemBlue the 2D temp line uses.
    var liveDrawingColor: String = "#007AFF"
    // Active navigation route (RoutePlanningService.activeRoute) — bridged
    // as a polyline + waypoint billboards so starting navigation on the 3D
    // globe shows the route instead of silently rendering nothing.
    var activeRoute: Route? = nil
    // Phase 3b — operator's breadcrumb trail (single trail; sourced from
    // `BreadcrumbTrailService.shared`). Empty array means "no trail".
    let breadcrumbTrailCoords: [CLLocationCoordinate2D]
    let breadcrumbTrailColor: String
    /// Phase 4a — fired when the HTML posts a tap or long-press through
    /// the `omniMapEvent` handler. Optional so older call sites still
    /// compile while the parent wires the radial menu / edit sheet.
    var onMapEvent: ((CesiumMapEvent) -> Void)?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.userContentController.add(context.coordinator, name: "omniBridgeReady")
        // Phase 4a — second handler for tap/longpress events coming back
        // from the Cesium scene. Body is a JSON string (the HTML uses
        // `postMessage(JSON.stringify(payload))`), decoded in the
        // coordinator.
        config.userContentController.add(context.coordinator, name: "omniMapEvent")

        let webView = WKWebView(frame: .zero, configuration: config)
        // Recover from WebGL/render-process termination. Cesium is GPU-heavy;
        // iOS can kill the WebContent process under memory pressure, leaving a
        // black globe that never returns on its own (the user had to manually
        // toggle 2D↔3D). The delegate's `…ProcessDidTerminate` reloads it.
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        context.coordinator.webView = webView

        // Bridge the toolbar zoom buttons to the Cesium camera. mapRegion
        // can't drive the globe, so the parent posts `.cesiumZoom` and the
        // coordinator forwards it to the JS bridge.
        context.coordinator.zoomObserver = NotificationCenter.default.addObserver(
            forName: .cesiumZoom, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator] note in
            guard let coordinator, coordinator.isReady, let wv = coordinator.webView else { return }
            let factor = (note.userInfo?["factor"] as? Double) ?? 1.0
            wv.evaluateJavaScript("window.OmniBridge.zoomBy({factor:\(factor)});", completionHandler: nil)
        }

        // Bridge "Show on Map" from the Contacts list to the Cesium camera.
        // The 2D path sets `mapRegion`; on 3D we need to fly the globe camera
        // explicitly. `OmniBridge.flyTo` defaults the range to 5000m at -30°
        // pitch, which keeps the target framed without losing situational
        // context.
        context.coordinator.centerOnObserver = NotificationCenter.default.addObserver(
            forName: .cesiumCenterOn, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator] note in
            guard let coordinator, coordinator.isReady, let wv = coordinator.webView else { return }
            guard let lat = note.userInfo?["lat"] as? Double,
                  let lon = note.userInfo?["lon"] as? Double else { return }
            wv.evaluateJavaScript(
                "window.OmniBridge.flyTo({lat:\(lat),lon:\(lon),range:5000});",
                completionHandler: nil
            )
        }

        // Issue #72/#73 — snap the globe heading to north (0°). Preserves the
        // current center, altitude, and pitch so only the rotation changes.
        context.coordinator.resetNorthObserver = NotificationCenter.default.addObserver(
            forName: .cesiumResetNorth, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            guard let coordinator, coordinator.isReady, let wv = coordinator.webView else { return }
            wv.evaluateJavaScript("window.OmniBridge.setHeading({heading:0});", completionHandler: nil)
        }

        // Issue #72 — engage/release the globe's north-up lock. The JS
        // `setNorthLock` disables free-look, snaps to north, and re-snaps any
        // heading drift on its own — so the globe physically stays north-up
        // without the native side polling. Remember the latest value so a
        // bridge re-init (engine toggle / WebGL process restart) can re-apply it.
        context.coordinator.northLockObserver = NotificationCenter.default.addObserver(
            forName: .cesiumSetNorthLock, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator] note in
            guard let coordinator else { return }
            let on = (note.userInfo?["on"] as? Bool) ?? false
            coordinator.northLocked = on
            guard coordinator.isReady, let wv = coordinator.webView else { return }
            wv.evaluateJavaScript("window.OmniBridge.setNorthLock({on:\(on)});", completionHandler: nil)
        }

        webView.loadHTMLString(CesiumMainMap.html, baseURL: URL(string: "https://cesium.com/"))
        context.coordinator.startLoadWatchdog()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let entities = buildEntityJSON()
        let drawings = buildDrawingJSON()
        let measurementsJSON = buildMeasurementJSON()
        let tempDrawingJSON = buildTempDrawingJSON()
        let trailsJSON = buildTrailJSON()
        context.coordinator.lastSnapshot = entities
        context.coordinator.lastDrawingsSnapshot = drawings
        context.coordinator.lastMeasurementsSnapshot = measurementsJSON
        context.coordinator.lastTempDrawingSnapshot = tempDrawingJSON
        context.coordinator.lastTrailsSnapshot = trailsJSON
        if context.coordinator.isReady {
            // Dedup ALL the bulk bridge calls — `updateUIView` fires on every
            // SwiftUI re-render, including ones triggered by unrelated
            // @Published churn (per-packet message counters, camera ticks).
            // Crossing the WKWebView process boundary with an identical
            // entity/trail payload every frame was a dominant map-lag source.
            // `setEntities` + `setTrails` were previously unguarded while
            // `setDrawings`/`setMeasurements` were — bring them in line (same
            // anti-pattern fixed on the 2D path in commit c9855f0). The JSON is
            // still built (it backs `lastSnapshot`, replayed on webview-ready);
            // only the cross-boundary push is skipped when nothing changed.
            if context.coordinator.shouldPublishBridge(call: "setEntities", signature: entities.hashValue) {
                webView.evaluateJavaScript("window.OmniBridge.setEntities(\(entities));", completionHandler: nil)
            }
            if context.coordinator.shouldPublishBridge(call: "setDrawings", signature: drawings.hashValue) {
                webView.evaluateJavaScript("window.OmniBridge.setDrawings(\(drawings));", completionHandler: nil)
            }
            if context.coordinator.shouldPublishBridge(call: "setMeasurements", signature: measurementsJSON.hashValue) {
                webView.evaluateJavaScript("window.OmniBridge.setMeasurements(\(measurementsJSON));", completionHandler: nil)
            }
            // Issue #63 — in-progress drawing preview (solid line + vertices in
            // the drawing color). Deduped like the others; the `draw-live` uid
            // makes each vertex replace the prior preview, and an empty payload
            // on complete/cancel clears it.
            if context.coordinator.shouldPublishBridge(call: "setTempDrawing", signature: tempDrawingJSON.hashValue) {
                webView.evaluateJavaScript("window.OmniBridge.setTempDrawing(\(tempDrawingJSON));", completionHandler: nil)
            }
            if context.coordinator.shouldPublishBridge(call: "setTrails", signature: trailsJSON.hashValue) {
                webView.evaluateJavaScript("window.OmniBridge.setTrails(\(trailsJSON));", completionHandler: nil)
            }

            // GPS follow mode — recenter the camera on the operator. `follow`
            // keeps the live camera's zoom/tilt/heading and only moves the
            // ground center, so the user can still rotate/tilt while tracked.
            // Dedup on coordinate so unrelated re-renders don't re-issue it.
            if isFollowing, let loc = selfLocation {
                context.coordinator.wasFollowing = true
                let key = "\(loc.coordinate.latitude),\(loc.coordinate.longitude)"
                if key != context.coordinator.lastFollowKey {
                    context.coordinator.lastFollowKey = key
                    webView.evaluateJavaScript(
                        "window.OmniBridge.follow({lat:\(loc.coordinate.latitude),lon:\(loc.coordinate.longitude)});",
                        completionHandler: nil
                    )
                }
            } else {
                // Follow just turned off — release the lookAt frame so the
                // operator can pan/zoom freely again.
                if context.coordinator.wasFollowing {
                    context.coordinator.wasFollowing = false
                    webView.evaluateJavaScript("window.OmniBridge.unfollow();", completionHandler: nil)
                }
                context.coordinator.lastFollowKey = nil
            }

            // Lasso mode toggle — push to the bridge on transitions only.
            if lassoActive != context.coordinator.lassoWasActive {
                context.coordinator.lassoWasActive = lassoActive
                webView.evaluateJavaScript("window.OmniBridge.setLassoMode({on:\(lassoActive)});", completionHandler: nil)
            }

            // Issue #60 (move/reposition follow-up) — reposition mode toggle.
            // Same transition-only pattern as lasso; the bridge locks the
            // camera and captures the single-finger drag, posting `move` events.
            if drawingMoveActive != context.coordinator.moveWasActive {
                context.coordinator.moveWasActive = drawingMoveActive
                webView.evaluateJavaScript("window.OmniBridge.setMoveMode({on:\(drawingMoveActive)});", completionHandler: nil)
            }

            // Base layer (imagery) — swap the globe's imagery on change so the
            // layers panel's Satellite/Hybrid/Standard work on 3D too.
            if baseLayer != context.coordinator.lastBaseLayer {
                context.coordinator.lastBaseLayer = baseLayer
                webView.evaluateJavaScript("window.OmniBridge.setBaseLayer({type:'\(baseLayer)'});", completionHandler: nil)
            }

            // Issue #72 — north-up lock. Apply on transition so a persisted
            // lock engages when the globe appears and an engine toggle keeps it.
            if isNorthLocked != context.coordinator.northLocked {
                context.coordinator.northLocked = isNorthLocked
                webView.evaluateJavaScript("window.OmniBridge.setNorthLock({on:\(isNorthLocked)});", completionHandler: nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: CesiumMainMap
        weak var webView: WKWebView?
        var isReady = false
        var lastSnapshot: String = "[]"
        var lastDrawingsSnapshot: String = "[]"
        var lastMeasurementsSnapshot: String = "[]"
        /// Last in-progress drawing preview pushed to the globe (issue #63).
        var lastTempDrawingSnapshot: String = "[]"
        var lastTrailsSnapshot: String = "[]"
        /// Last coordinate we recentered on in follow mode (dedupe key).
        var lastFollowKey: String?
        /// Whether follow was active last render (to release lookAt on exit).
        var wasFollowing = false
        /// Whether lasso mode was active last render (to toggle on transition).
        var lassoWasActive = false
        /// Issue #60 — whether drawing reposition mode was active last render.
        var moveWasActive = false
        /// Last base imagery layer pushed to the globe (swap on change).
        var lastBaseLayer = "satellite"
        /// Observer token for toolbar zoom commands forwarded to the bridge.
        var zoomObserver: NSObjectProtocol?
        /// Observer token for "Show on Map" (contact-centering) commands.
        var centerOnObserver: NSObjectProtocol?
        /// Observer token for issue #72/#73 north-snap commands.
        var resetNorthObserver: NSObjectProtocol?
        /// Observer token for issue #72 north-lock engage/release commands.
        var northLockObserver: NSObjectProtocol?
        /// Latest north-lock state, re-applied when the bridge (re)initializes
        /// so the lock survives an engine toggle or a WebGL process restart.
        var northLocked = false
        /// Watchdog: the globe pulls Cesium.js + terrain from the cesium.com
        /// CDN on every load. If the device can't reach it (bad network, dead
        /// CDN) the page sits on "Loading 3D world…" forever. If the bridge
        /// hasn't signalled ready within the timeout, fall back to 2D rather
        /// than hang. Cancelled the instant `omniBridgeReady` fires.
        var loadWatchdog: Timer?

        func startLoadWatchdog() {
            loadWatchdog?.invalidate()
            loadWatchdog = Timer.scheduledTimer(withTimeInterval: 12.0, repeats: false) { [weak self] _ in
                guard let self, !self.isReady else { return }
                NotificationCenter.default.post(name: .cesiumLoadTimedOut, object: nil)
            }
        }

        /// The WebGL render process was killed (memory pressure) — the globe is
        /// now black and won't recover on its own. Reload it; `omniBridgeReady`
        /// will re-fire and `updateUIView` re-pushes the entity snapshot, so the
        /// scene restores. The watchdog covers the case where the reload itself
        /// can't complete (→ falls back to 2D).
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isReady = false
            // Force the next updateUIView to re-push every bridge payload (the
            // fresh page has no entities/drawings/trails yet).
            bridgePayloadHashes.removeAll()
            webView.loadHTMLString(CesiumMainMap.html, baseURL: URL(string: "https://cesium.com/"))
            startLoadWatchdog()
        }

        /// Per-bridge-call payload hash cache. `updateUIView` runs on every
        /// SwiftUI re-render (including camera ticks), so we hash the JSON
        /// payload going to each `OmniBridge` call and short-circuit when
        /// the content is identical — mirrors the 2D path's
        /// `shouldPublish(layer:signature:)` dedup.
        private var bridgePayloadHashes: [String: Int] = [:]
        func shouldPublishBridge(call: String, signature: Int) -> Bool {
            if bridgePayloadHashes[call] == signature { return false }
            bridgePayloadHashes[call] = signature
            return true
        }

        deinit {
            if let zoomObserver { NotificationCenter.default.removeObserver(zoomObserver) }
            if let centerOnObserver { NotificationCenter.default.removeObserver(centerOnObserver) }
            if let resetNorthObserver { NotificationCenter.default.removeObserver(resetNorthObserver) }
            if let northLockObserver { NotificationCenter.default.removeObserver(northLockObserver) }
            loadWatchdog?.invalidate()
        }

        init(_ parent: CesiumMainMap) {
            self.parent = parent
            super.init()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "omniBridgeReady":
                isReady = true
                loadWatchdog?.invalidate(); loadWatchdog = nil
                // Issue #72 — re-apply the north-lock if it was engaged before
                // this bridge (re)initialized (engine toggle / WebGL restart),
                // so the globe comes back north-up and stays locked.
                if northLocked {
                    webView?.evaluateJavaScript("window.OmniBridge.setNorthLock({on:true});", completionHandler: nil)
                }
                // Issue #60 — if reposition mode was active before this bridge
                // (re)initialized (e.g. a WebGL process restart mid-move),
                // re-engage it so the globe camera comes back locked and the
                // drag capture is restored, mirroring the north-lock re-apply.
                if moveWasActive {
                    webView?.evaluateJavaScript("window.OmniBridge.setMoveMode({on:true});", completionHandler: nil)
                }
                // Drain the latest snapshots the moment the HTML signals it
                // has the OmniBridge alive — anything queued during page
                // load lands in one shot.
                webView?.evaluateJavaScript(
                    "window.OmniBridge.setEntities(\(lastSnapshot));",
                    completionHandler: nil
                )
                webView?.evaluateJavaScript(
                    "window.OmniBridge.setDrawings(\(lastDrawingsSnapshot));",
                    completionHandler: nil
                )
                webView?.evaluateJavaScript(
                    "window.OmniBridge.setMeasurements(\(lastMeasurementsSnapshot));",
                    completionHandler: nil
                )
                webView?.evaluateJavaScript(
                    "window.OmniBridge.setTempDrawing(\(lastTempDrawingSnapshot));",
                    completionHandler: nil
                )
                webView?.evaluateJavaScript(
                    "window.OmniBridge.setTrails(\(lastTrailsSnapshot));",
                    completionHandler: nil
                )
                // Align Cesium camera with the ADSB search center on
                // bridge-ready so the aircraft pill count and the entities
                // on-screen always match — first-launch users never see
                // "I have 41 aircraft tracked but the map is empty"
                // because the camera was over DC and the planes are over
                // KJFK. ADSB's `getSearchCenter()` returns the user's GPS
                // (real device) or the KJFK fallback (no fix yet); pre-
                // existing persisted camera state in cesium.lastLat etc.
                // is intentionally ignored for this initial alignment.
                if let center = ADSBTrafficService.shared.searchCenterForBridge() {
                    let h = max(20000.0, UserDefaults.standard.double(forKey: "cesium.lastHeight"))
                    let hd = UserDefaults.standard.double(forKey: "cesium.lastHeading")
                    let pt = UserDefaults.standard.object(forKey: "cesium.lastPitch") as? Double ?? -60
                    webView?.evaluateJavaScript(
                        "window.OmniBridge.flyTo({lat:\(center.latitude),lon:\(center.longitude),range:\(h),heading:\(hd),pitch:\(pt)});",
                        completionHandler: nil
                    )
                } else {
                    // No ADSB center available — restore last camera pose
                    // (engine toggle 3D → 2D → back) so we don't snap to
                    // the bootstrap default.
                    let d = UserDefaults.standard
                    if d.object(forKey: "cesium.lastLat") != nil {
                        let lat = d.double(forKey: "cesium.lastLat")
                        let lon = d.double(forKey: "cesium.lastLon")
                        let h   = d.double(forKey: "cesium.lastHeight")
                        let hd  = d.double(forKey: "cesium.lastHeading")
                        let pt  = d.double(forKey: "cesium.lastPitch")
                        webView?.evaluateJavaScript(
                            "window.OmniBridge.flyTo({lat:\(lat),lon:\(lon),range:\(h),heading:\(hd),pitch:\(pt)});",
                            completionHandler: nil
                        )
                    }
                }
            case "omniMapEvent":
                // Body arrives as a JSON string from the HTML. Tolerate
                // a dictionary body too in case a future WK build relaxes
                // the contract.
                let data: Data?
                if let s = message.body as? String {
                    data = s.data(using: .utf8)
                } else if let dict = message.body as? [String: Any] {
                    data = try? JSONSerialization.data(withJSONObject: dict)
                } else {
                    data = nil
                }
                guard let bytes = data,
                      let payload = try? JSONDecoder().decode(MapEventPayload.self, from: bytes)
                else { return }
                let kind: CesiumMapEvent.Kind
                switch payload.event {
                case "tap": kind = .tap
                case "longpress": kind = .longpress
                case "camerachanged": kind = .cameraChanged
                case "lasso": kind = .lasso
                case "move": kind = .move
                default: return
                }
                let cameraState: CesiumMapEvent.CameraState?
                if kind == .cameraChanged,
                   let h = payload.height, let hd = payload.heading,
                   let pt = payload.pitch, let zm = payload.zoom {
                    cameraState = .init(height: h, heading: hd, pitch: pt, zoom: zm)
                } else {
                    cameraState = nil
                }
                let centerCoord: CLLocationCoordinate2D?
                if let cLat = payload.centerLat, let cLon = payload.centerLon {
                    centerCoord = CLLocationCoordinate2D(latitude: cLat, longitude: cLon)
                } else {
                    centerCoord = nil
                }
                let polygon: [CLLocationCoordinate2D]? = payload.polygon?.compactMap {
                    $0.count == 2 ? CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) : nil
                }
                let moveFrom: CLLocationCoordinate2D?
                if let fLat = payload.fromLat, let fLon = payload.fromLon {
                    moveFrom = CLLocationCoordinate2D(latitude: fLat, longitude: fLon)
                } else {
                    moveFrom = nil
                }
                let event = CesiumMapEvent(
                    kind: kind,
                    coordinate: CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lon),
                    screenPoint: CGPoint(x: payload.screenX ?? 0, y: payload.screenY ?? 0),
                    entityUid: payload.uid,
                    camera: cameraState,
                    centerCoordinate: centerCoord,
                    polygon: polygon,
                    moveFromCoordinate: moveFrom
                )
                parent.onMapEvent?(event)
            default:
                break
            }
        }

        /// Wire-format mirror of the HTML payload (`{event, lat, lon, hae,
        /// screenX, screenY, uid?}`). `hae` is accepted but unused on the
        /// Swift side — the radial menu / contact lookup only needs the
        /// 2D coordinate.
        private struct MapEventPayload: Decodable {
            let event: String
            let lat: Double
            let lon: Double
            let hae: Double?
            let screenX: Double?     // absent for camerachanged
            let screenY: Double?
            let uid: String?
            // Camera fields — only present for "camerachanged"
            let height: Double?
            let heading: Double?
            let pitch: Double?
            let zoom: Double?
            // Globe point under the screen center (aim crosshair) on
            // camerachanged — the correct point-drop / region center.
            let centerLat: Double?
            let centerLon: Double?
            // Freehand lasso polygon as [[lat,lon],...] for a 'lasso' event.
            let polygon: [[Double]]?
            // Drag origin (previous frame globe point) for a 'move' event
            // (issue #60). `lat`/`lon` carry the current frame.
            let fromLat: Double?
            let fromLon: Double?
        }
    }

    // MARK: - Drawing bridge (Phase 3a)

    private struct BridgeDrawing: Encodable {
        let uid: String
        let kind: String      // "line" | "polygon" | "circle"
        let coords: [[Double]]
        let color: String
        let width: Double
    }

    private func buildDrawingJSON() -> String {
        var all: [BridgeDrawing] = []

        for line in lineDrawings where !line.coordinates.isEmpty {
            all.append(BridgeDrawing(
                uid: "line-\(line.id.uuidString)",
                kind: "line",
                coords: line.coordinates.map { [$0.longitude, $0.latitude] },
                color: CesiumMainMap.hex(forDrawingColor: line.color),
                width: 3
            ))
        }

        for polygon in polygonDrawings where !polygon.coordinates.isEmpty {
            all.append(BridgeDrawing(
                uid: "poly-\(polygon.id.uuidString)",
                kind: "polygon",
                coords: polygon.coordinates.map { [$0.longitude, $0.latitude] },
                color: CesiumMainMap.hex(forDrawingColor: polygon.color),
                width: 3
            ))
        }

        for circle in circleDrawings {
            // The shared bridge schema is [center, edge]; convert iOS's
            // (center, radiusMetres) shape by shifting one degree's worth
            // of longitude east by the radius distance.
            let center = circle.center
            let edge = CesiumMainMap.edgePoint(from: center, eastMetres: circle.radius)
            all.append(BridgeDrawing(
                uid: "circ-\(circle.id.uuidString)",
                kind: "circle",
                coords: [
                    [center.longitude, center.latitude],
                    [edge.longitude, edge.latitude],
                ],
                color: CesiumMainMap.hex(forDrawingColor: circle.color),
                width: 3
            ))
        }

        // Active navigation route — bridged as a wide line in the route's
        // own color. Prefer the calculated segment paths (road-following
        // when available); fall back to straight waypoint legs.
        if let route = activeRoute {
            var coords = route.segments.flatMap { $0.path }
            if coords.count < 2 {
                coords = route.waypoints
                    .sorted { $0.order < $1.order }
                    .map { $0.coordinate }
            }
            if coords.count >= 2 {
                all.append(BridgeDrawing(
                    uid: "route-\(route.id.uuidString)",
                    kind: "line",
                    coords: coords.map { [$0.longitude, $0.latitude] },
                    color: route.color,
                    width: max(3, route.lineWidth)
                ))
            }
        }

        // Range rings reuse the circle bridge path — same (center, edge)
        // shape, different uid namespace so an operator's range rings
        // can't collide with their drawing circles or the in-progress
        // measurement.
        for ring in rangeRings where ring.isVisible {
            let center = ring.center
            let edge = CesiumMainMap.edgePoint(from: center, eastMetres: ring.radiusMeters)
            all.append(BridgeDrawing(
                uid: "rring-\(ring.id.uuidString)",
                kind: "circle",
                coords: [
                    [center.longitude, center.latitude],
                    [edge.longitude, edge.latitude],
                ],
                color: CesiumMainMap.hex(forUIColor: ring.color),
                width: 2
            ))
        }

        guard let data = try? JSONEncoder().encode(all),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    /// Move `metres` east from a coordinate. Used to translate iOS's
    /// (center, radius) circle convention to the bridge's [center, edge]
    /// pair convention. Accurate enough at any latitude we'd plot a
    /// tactical circle.
    private static func edgePoint(from center: CLLocationCoordinate2D, eastMetres metres: Double) -> CLLocationCoordinate2D {
        let metersPerDegLon = 111_320.0 * max(cos(center.latitude * .pi / 180), 0.01)
        return CLLocationCoordinate2D(
            latitude: center.latitude,
            longitude: center.longitude + (metres / metersPerDegLon)
        )
    }

    /// Hex string for the bridge — matches the system tints the 2D Mapbox
    /// path uses so a shape rendered in either engine reads the same.
    private static func hex(forDrawingColor c: DrawingColor) -> String {
        switch c {
        case .red:    return "#FF3B30"
        case .blue:   return "#007AFF"
        case .green:  return "#34C759"
        case .yellow: return "#FFCC00"
        case .orange: return "#FF9500"
        case .purple: return "#AF52DE"
        case .cyan:   return "#5AC8FA"
        case .white:  return "#FFFFFF"
        }
    }

    // (hex(forUIColor:) is defined later in this file alongside the
    // measurement encoder — reuse it for range rings.)

    private struct BridgeEntity: Encodable {
        let uid: String
        let lat: Double
        let lon: Double
        let hae: Double?
        let callsign: String?
        let affiliation: String
        let kind: String
        // Phase 3b — aircraft heading in degrees clockwise from north. Nil
        // for contacts and self (the HTML bridge treats absent heading as
        // "no rotation"). Only aircraft carry a meaningful track angle.
        let heading: Double?
        // MIL-STD-2525 SIDC code (e.g. "SFGPUCI----"). When present, the
        // HTML side renders via milsymbol.js; when nil/unparseable it
        // falls back to the affiliation-shape canvas billboard.
        let sidc: String?
        // Issue #75 — TAK Spot Map dot color as "#RRGGBB". When present, the
        // HTML renders a colored dot (the standard spot-map point) instead of
        // the sidc / affiliation art, so the globe matches the 2D engine.
        let spot: String?
        // Issue #75 — pre-rendered icon as a PNG data URI (used for the TAK
        // "Google" place pack, which has no SIDC equivalent). When present the
        // HTML billboards this image directly so the globe matches the 2D pin.
        let icon: String?
        // TAK-style altitude leader line (vertical drop-line from ground to
        // the icon + "{alt} m HAE" label). Reserved for detected drones so
        // the 3D globe doesn't get cluttered with a stick under every
        // airborne ADS-B aircraft. Aircraft still float at their altitude;
        // they just don't draw the leader/label.
        let leader: Bool
    }

    /// Issue #75 — "#RRGGBB" for a TAK Spot Map marker, or nil when the entity
    /// isn't a spot-map point. Mirrors the iOS registry / generator so the
    /// globe dot, the 2D dot, and the emitted CoT color all agree.
    private static func spotHex(cotType: String, iconsetPath: String?, argb: Int?) -> String? {
        let isSpot = (iconsetPath.map { TAKSpotIcon.from(iconsetPath: $0) != nil } ?? false)
            || cotType == TAKSpotIcon.cotType
        guard isSpot else { return nil }
        let color: UIColor
        if let argb { color = TAKIconRegistry.uiColor(fromARGB: argb) }
        else if let path = iconsetPath, let spot = TAKSpotIcon.from(iconsetPath: path) { color = spot.uiColor }
        else { color = TAKSpotIcon.white.uiColor }
        return CesiumMainMap.hex(forUIColor: color)
    }

    /// Issue #75 — PNG data URI for a TAK "Google" place marker, or nil when
    /// the entity isn't a Google-pack point. The Google pack has no SIDC, so the
    /// globe billboards the same rendered pin the 2D engine uses.
    private static func googleIconURI(iconsetPath: String?) -> String? {
        guard let path = iconsetPath, let g = TAKGoogleIcon.from(iconsetPath: path) else { return nil }
        return dataURI(for: TAKIconRegistry.shared.image(for: g, size: 44))
    }

    /// Encode a UIImage as a `data:image/png;base64,…` URI for the HTML bridge.
    private static func dataURI(for image: UIImage) -> String? {
        guard let png = image.pngData() else { return nil }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    private func buildEntityJSON() -> String {
        var all: [BridgeEntity] = []

        if let loc = selfLocation {
            // Issue #66 — supply GPS course as heading when the arrow style is
            // active (non-negative course = valid heading from CoreLocation).
            // The HTML billboard rotates the entity icon by `heading` degrees
            // clockwise from north, same as aircraft entities.
            let selfHeading: Double? = (selfMarkerStyle == "arrow" && loc.course >= 0)
                ? loc.course
                : nil

            all.append(BridgeEntity(
                uid: "__self__",
                lat: loc.coordinate.latitude,
                lon: loc.coordinate.longitude,
                hae: loc.altitude > 0 ? loc.altitude : nil,
                callsign: selfCallsign,
                affiliation: "f",
                kind: "self",
                heading: selfHeading,
                // Self renders as a friendly ground combat unit so milsymbol
                // draws the standard friendly frame the operator expects.
                // The "bullseye" Settings style suppresses the SIDC so the
                // HTML falls back to the green disc + center-dot canvas
                // billboard — the globe's bullseye analog.
                // The "arrow" style also suppresses the SIDC in favour of
                // the heading-rotated arrow billboard from the HTML side.
                sidc: (selfMarkerStyle == "bullseye" || selfMarkerStyle == "arrow") ? nil : "SFGPUCI----",
                spot: nil,
                icon: nil,
                leader: false
            ))
        }

        for c in contacts {
            all.append(BridgeEntity(
                uid: c.uid,
                lat: c.coordinate.latitude,
                lon: c.coordinate.longitude,
                hae: c.hae, // air tracks (drones/ADS-B) float at HAE; ground units stay nil → clamped
                callsign: c.callsign,
                affiliation: CesiumMainMap.affiliation(fromCoTType: c.type),
                kind: "contact",
                heading: nil,
                // SIDC from the existing CoT→2525 mapping service — same
                // mapping the 2D Mapbox / MapKit paths use, so a contact
                // reads identically across all engines.
                sidc: MilStdIconService.shared.getSIDC(for: c.type),
                // Issue #75 — spot-map dot color when the contact is a spot-map
                // point (carries a COT_MAPPING_SPOTMAP usericon or b-m-p-s-m
                // type); the HTML renders the dot over the sidc in that case.
                spot: CesiumMainMap.spotHex(cotType: c.type, iconsetPath: c.iconsetPath, argb: c.argbColor),
                // Issue #75 — Google-pack place pin (no SIDC) rendered for 3D.
                icon: CesiumMainMap.googleIconURI(iconsetPath: c.iconsetPath),
                // Detected drones (RID-{uasId}) get the TAK altitude leader
                // line; other airborne CoT contacts float without the stick.
                leader: c.uid.hasPrefix("RID-")
            ))
        }

        for a in aircraft {
            // Normalise heading into [0, 360). ADSBService can hand back
            // negative or >360 values for stale tracks; the HTML side
            // expects a clean compass bearing.
            let h = a.heading.truncatingRemainder(dividingBy: 360)
            let normalisedHeading = h < 0 ? h + 360 : h
            all.append(BridgeEntity(
                uid: "ads-\(a.id)",
                lat: a.coordinate.latitude,
                lon: a.coordinate.longitude,
                hae: a.onGround ? nil : a.altitude,
                callsign: a.callsign,
                affiliation: "n",
                kind: "aircraft",
                heading: normalisedHeading,
                // Aircraft keep the heading-rotated arrow billboard — the
                // HTML _billboard() function ignores sidc when kind ==
                // "aircraft" so the directional arrow wins.
                sidc: nil,
                spot: nil,
                icon: nil,
                // ADS-B aircraft float at altitude but skip the leader line to
                // keep a busy airspace readable.
                leader: false
            ))
        }

        // Dropped point markers. The 2D Mapbox path renders these via
        // refreshPointMarkers(); the Cesium bridge never received them, so
        // dropping a pin produced "no pin, no icon, no info" on the 3D
        // engine. Reuse the contact SIDC mapping so a pin reads identically
        // across engines; nil sidc falls back to the affiliation-shape
        // billboard in the HTML.
        for pm in pointMarkers {
            all.append(BridgeEntity(
                uid: pm.uid,
                lat: pm.coordinate.latitude,
                lon: pm.coordinate.longitude,
                hae: pm.altitude,
                callsign: pm.name,
                affiliation: CesiumMainMap.affiliation(fromCoTType: pm.cotType),
                kind: "marker",
                heading: nil,
                sidc: MilStdIconService.shared.getSIDC(for: pm.cotType),
                // Issue #75 — a placed TAK spot-map pin renders its colored dot
                // on the globe too, matching the picker swatch and 2D engine.
                spot: pm.takIcon.map { CesiumMainMap.hex(forUIColor: $0.uiColor) },
                // Issue #75 — a placed Google place pin renders on the globe via
                // its data URI (Markers ride the sidc path above).
                icon: pm.googleIcon.map { CesiumMainMap.dataURI(for: TAKIconRegistry.shared.image(for: $0, size: 44)) } ?? nil,
                leader: false
            ))
        }

        // Drawing-tool markers (DrawingStore.markers — MarkerDrawing). The 2D
        // Mapbox path renders these via refreshDrawingMarkers() as a colored
        // disc; the Cesium bridge never received them, so a drawing-tool pin was
        // invisible on the 3D engine (issue #61). They carry no CoT type / SIDC
        // — render the affiliation-shape billboard in the drawing's color via a
        // friendly affiliation fallback, and tag them with a `dmark-` uid so the
        // tap handler can open the drawing edit/delete menu (issue #60).
        for dm in markerDrawings {
            all.append(BridgeEntity(
                uid: "dmark-\(dm.id.uuidString)",
                lat: dm.coordinate.latitude,
                lon: dm.coordinate.longitude,
                hae: nil,
                callsign: dm.label,
                affiliation: "f",
                kind: "marker",
                heading: nil,
                // No SIDC — fall through to the dot billboard, recolored to the
                // drawing's tactical color so it matches the 2D disc.
                sidc: nil,
                spot: CesiumMainMap.hex(forDrawingColor: dm.color),
                icon: nil,
                leader: false
            ))
        }

        // Active-route waypoints — labelled billboards so the operator can
        // see where the route goes on the globe (the 2D path renders these
        // via RouteOverlayCoordinator's MKAnnotations). Friendly affiliation
        // keeps the billboard in the route's tactical color family; nil sidc
        // falls back to the affiliation-shape canvas billboard.
        if let route = activeRoute {
            for wp in route.waypoints {
                all.append(BridgeEntity(
                    uid: "route-wp-\(wp.id.uuidString)",
                    lat: wp.latitude,
                    lon: wp.longitude,
                    hae: nil,
                    callsign: wp.name,
                    affiliation: "f",
                    kind: "marker",
                    heading: nil,
                    sidc: nil,
                    spot: nil,
                    icon: nil,
                    leader: false
                ))
            }
        }

        guard let data = try? JSONEncoder().encode(all),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    // MARK: - Measurement bridge (Phase 3b)

    private struct BridgeMeasurement: Encodable {
        let uid: String
        let vertices: [[Double]]
        let color: String
        let segments: [Segment]

        struct Segment: Encodable {
            let label: String?
        }
    }

    private func buildMeasurementJSON() -> String {
        var all: [BridgeMeasurement] = []

        for m in measurements where !m.points.isEmpty {
            // Bridge schema is [lon, lat] per vertex. iOS holds
            // CLLocationCoordinate2D (lat, lon) — flip on the way out.
            let verts: [[Double]] = m.points.map { [$0.longitude, $0.latitude] }

            // Per-segment label: index 0 has no preceding segment so its
            // label is empty; index N's label is the great-circle distance
            // between vertex N-1 and N.
            var segments: [BridgeMeasurement.Segment] = []
            segments.reserveCapacity(m.points.count)
            for (i, pt) in m.points.enumerated() {
                if i == 0 {
                    segments.append(.init(label: ""))
                } else {
                    let prev = m.points[i - 1]
                    let metres = CesiumMainMap.haversineMetres(prev, pt)
                    segments.append(.init(label: CesiumMainMap.formatDistanceLabel(metres)))
                }
            }

            all.append(BridgeMeasurement(
                uid: "meas-\(m.id.uuidString)",
                vertices: verts,
                color: CesiumMainMap.hex(forUIColor: m.color),
                segments: segments
            ))
        }

        // Live in-progress measurement — same schema under a fixed uid so
        // each new vertex replaces the previous polyline. systemYellow to
        // match the Mapbox temp line; disappears on complete/cancel (the
        // committed session then arrives via `measurements`).
        if liveMeasurementPoints.count >= 2 {
            let verts: [[Double]] = liveMeasurementPoints.map { [$0.longitude, $0.latitude] }
            var segments: [BridgeMeasurement.Segment] = []
            segments.reserveCapacity(liveMeasurementPoints.count)
            for (i, pt) in liveMeasurementPoints.enumerated() {
                if i == 0 {
                    segments.append(.init(label: ""))
                } else {
                    let metres = CesiumMainMap.haversineMetres(liveMeasurementPoints[i - 1], pt)
                    segments.append(.init(label: CesiumMainMap.formatDistanceLabel(metres)))
                }
            }
            all.append(BridgeMeasurement(
                uid: "meas-live",
                vertices: verts,
                color: "#FFCC00",
                segments: segments
            ))
        }

        guard let data = try? JSONEncoder().encode(all),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    // MARK: - Live drawing bridge (issue #63)

    /// In-progress drawing geometry for the globe — a solid polyline + vertex
    /// dots in the active drawing color, so multi-tap line/polygon placement
    /// shows feedback BEFORE the operator hits Complete (parity with the 2D
    /// Mapbox temp overlay). Single fixed uid (`draw-live`) so each new vertex
    /// replaces the prior preview; cleared (empty payload) on complete/cancel.
    private struct BridgeTempDrawing: Encodable {
        let uid: String
        let kind: String          // "line" | "polygon" | "circle"
        let coords: [[Double]]    // [lon, lat] per vertex
        let color: String
        let width: Double
    }

    private func buildTempDrawingJSON() -> String {
        // Need an active mode and at least one placed vertex. A circle with a
        // center but no radius point still shows its center dot; a line/polygon
        // needs its growing vertex chain.
        guard let mode = liveDrawingMode, !liveDrawingPoints.isEmpty else { return "[]" }
        let temp = BridgeTempDrawing(
            uid: "draw-live",
            kind: mode,
            coords: liveDrawingPoints.map { [$0.longitude, $0.latitude] },
            color: liveDrawingColor,
            width: 2
        )
        guard let data = try? JSONEncoder().encode([temp]),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    // MARK: - Trail bridge (Phase 3b)

    private struct BridgeTrail: Encodable {
        let uid: String
        let coords: [[Double]]
        let color: String
        let width: Double
    }

    private func buildTrailJSON() -> String {
        // Only the operator's own breadcrumb trail today — the service
        // models a single trail. Skip if there's nothing recorded (the JS
        // side will diff this against any prior trails and remove them).
        guard breadcrumbTrailCoords.count >= 2 else { return "[]" }

        let coords: [[Double]] = breadcrumbTrailCoords.map { [$0.longitude, $0.latitude] }
        let trail = BridgeTrail(
            uid: "trail-self",
            coords: coords,
            color: breadcrumbTrailColor,
            width: 3
        )

        guard let data = try? JSONEncoder().encode([trail]),
              let str = String(data: data, encoding: .utf8) else { return "[]" }
        return str
    }

    /// Great-circle distance in metres between two coordinates. Mirrors
    /// the JS `_havDist` so a segment computed in Swift matches a segment
    /// the HTML side would compute itself.
    private static func haversineMetres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let R = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let s = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * R * asin(min(1, sqrt(s)))
    }

    /// "1.2 km" if >= 1 km, otherwise "850 m" (integer metres). Matches
    /// the contract documented in the Phase 3b spec.
    private static func formatDistanceLabel(_ metres: Double) -> String {
        if metres >= 1000 {
            return String(format: "%.1f km", metres / 1000.0)
        }
        return "\(Int(metres.rounded())) m"
    }

    /// Hex string for a measurement's UIColor. Uses the same `#RRGGBB`
    /// shape as `hex(forDrawingColor:)` so the JS side can lean on a
    /// single CSS color parser.
    private static func hex(forUIColor c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        let R = Int((max(0, min(1, r)) * 255).rounded())
        let G = Int((max(0, min(1, g)) * 255).rounded())
        let B = Int((max(0, min(1, b)) * 255).rounded())
        return String(format: "#%02X%02X%02X", R, G, B)
    }

    /// CoT type codes look like `a-f-G-U-C-I` — second token is the
    /// affiliation character. Map to the single-letter codes the HTML
    /// bridge consumes (f/h/n/u).
    private static func affiliation(fromCoTType type: String) -> String {
        let parts = type.split(separator: "-")
        guard parts.count >= 2, let first = parts[1].first else { return "u" }
        switch first {
        case "f", "F": return "f"
        case "h", "H": return "h"
        case "n", "N": return "n"
        default:       return "u"
        }
    }

    /// Build-time injected — see `CesiumIonConfig`. Kept as a computed alias so
    /// the HTML interpolation below reads the same as before the migration.
    private static var cesiumIonToken: String { CesiumIonConfig.token }

    /// HTML for the Cesium scene, loaded from the bundled `cesium_scene.html`
    /// resource — kept in lockstep with the Android copy at
    /// `OmniTAK-Android/app/src/main/assets/cesium_scene.html` (same file,
    /// same `__CESIUM_ION_TOKEN__` injection point). When you change one,
    /// change both. The Ion token is injected at load time from
    /// `CesiumIonConfig` (Config.xcconfig → Info.plist), never hardcoded.
    static var html: String {
        guard let url = Bundle.main.url(forResource: "cesium_scene", withExtension: "html"),
              let template = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("cesium_scene.html missing from app bundle")
            return ""
        }
        return template.replacingOccurrences(of: "__CESIUM_ION_TOKEN__", with: cesiumIonToken)
    }
}
