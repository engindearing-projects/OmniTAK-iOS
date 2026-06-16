//
//  TacticalMapView.swift
//  OmniTAKMobile
//
//  The 2D Mapbox engine: UIViewRepresentable + coordinator + the
//  radial-menu Mapbox bridge.
//  Extracted from MapViewController.swift — mechanical move, no behavior change.
//

import SwiftUI
import MapKit
import CoreLocation
import MapboxMaps
import UIKit

// MARK: - Mapbox north-reset notification (Issue #72/#73)

extension Notification.Name {
    /// Posted by ATAKMapView to snap the Mapbox camera heading to 0° (north).
    static let mapboxResetNorth = Notification.Name("mapboxResetNorth")
    /// Issue #65 — posted when the operator taps their own self-position puck
    /// (either the Mapbox 2D puck or the Cesium 3D `__self__` entity). The
    /// MapViewController observes this and presents `SelfPositionEditSheet`.
    static let selfMarkerTapped = Notification.Name("selfMarkerTapped")
}

// MARK: - Tactical Map View (Mapbox Maps SDK v3 — native)
//
// This is the main map surface for OmniTAK iOS. It used to wrap MKMapView;
// the engine swap moved it to Mapbox Maps SDK v11 (`MapboxMaps`) so the
// same UIViewRepresentable serves a Mapbox `MapView` underneath while the
// SwiftUI parent (`ATAKMapView`) and every call-site keep their existing
// bindings (`MKCoordinateRegion`, `MKMapType`, `MapUserTrackingMode`).
// The 3D Standard style + terrain + atmosphere are loaded by default so
// the operator opens straight into the immersive view that the legacy
// MapKit version never could deliver.

struct TacticalMapView: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var mapType: MKMapType
    @Binding var trackingMode: MapUserTrackingMode
    let markers: [CoTMarker]
    let pointMarkers: [PointMarker]
    let aircraft: [Aircraft]
    let showsUserLocation: Bool
    @ObservedObject var drawingStore: DrawingStore
    @ObservedObject var drawingManager: DrawingToolsManager
    @ObservedObject var radialMenuCoordinator: RadialMenuMapCoordinator
    @ObservedObject var overlayCoordinator: MapOverlayCoordinator
    @ObservedObject var routeOverlayCoordinator: RouteOverlayCoordinator
    @ObservedObject var mapStateManager: MapStateManager
    @ObservedObject var measurementManager: MeasurementManager
    @ObservedObject var lassoService: LassoSelectionService = LassoSelectionService.shared
    // Issue #60 (move/reposition follow-up) — reposition session shared with
    // the parent + Cesium engine. When active, a single-finger drag rigidly
    // translates the shape via `onDrawingMoveDragged` (the parent persists it).
    @ObservedObject var drawingMoveSession: DrawingMoveSession
    var onDrawingMoveDragged: ((CLLocationDegrees, CLLocationDegrees) -> Void)? = nil
    // Issue #84 — vertex-edit session shared with the parent + Cesium engine.
    // When active, a single-finger drag grabs the nearest handle on touch-down
    // (`onVertexDragBegan` with the touched coordinate) and moves it each frame
    // (`onVertexDragMoved`); the parent owns the hit-test + persist.
    @ObservedObject var drawingVertexEditSession: DrawingVertexEditSession
    var onVertexDragBegan: ((CLLocationCoordinate2D) -> Void)? = nil
    var onVertexDragMoved: ((CLLocationCoordinate2D) -> Void)? = nil
    var onVertexDragEnded: (() -> Void)? = nil
    @ObservedObject var kmlVectorStore: KMLVectorOverlayStore = KMLVectorOverlayStore.shared
    @ObservedObject var rasterStore: RasterOverlayStore = RasterOverlayStore.shared
    @ObservedObject var mbtilesStore: MBTilesOverlayStore = MBTilesOverlayStore.shared
    let onMapTap: (CLLocationCoordinate2D) -> Void
    /// Issue #72 — when true, rotation gestures are disabled and bearing
    /// is snapped back to 0° on any camera-change that drifts off north.
    var isNorthLocked: Bool = false
    /// Issue #73 — called with the current map bearing (° CW from north)
    /// whenever the Mapbox camera rotates, so the parent can update the
    /// compass overlay needle.
    var onBearingChanged: ((Double) -> Void)? = nil

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> MapView {
        // 3D default: Standard style + 60° pitch on launch. Camera is
        // hydrated from the SwiftUI region binding so a fresh launch
        // sits over Washington DC (the default), and restored sessions
        // pick up wherever the operator left off.
        let initialCenter = region.center
        let initialZoom = TacticalMapView.zoom(forSpan: region.span, mapHeight: 400)
        let cameraOpts = CameraOptions(
            center: initialCenter,
            zoom: initialZoom,
            bearing: 0,
            pitch: 60
        )
        let mapView = MapView(
            frame: .zero,
            mapInitOptions: MapInitOptions(
                cameraOptions: cameraOpts,
                styleURI: TacticalMapView.styleURI(for: mapType)
            )
        )

        // Native user-location puck, styled per the Settings "Self-position
        // marker" picker (selfMarkerStyle). Previously the picker persisted
        // a value nothing read and the puck was always the default dot.
        mapView.location.options.puckType = TacticalMapView.selfPuckType()
        TacticalMapView.applyPuckBearing(to: mapView)
        context.coordinator.lastSelfMarkerStyle =
            UserDefaults.standard.string(forKey: "selfMarkerStyle") ?? "milstd"
        if !showsUserLocation { mapView.location.options.puckType = nil }

        // Sane defaults for tactical use — let the operator pan, zoom,
        // pitch, and rotate freely. Mapbox enables all of these by
        // default; we re-state them so future toggles are explicit.
        mapView.gestures.options.pitchEnabled = true
        mapView.gestures.options.rotateEnabled = true
        mapView.gestures.options.panEnabled = true
        mapView.gestures.options.pinchEnabled = true
        mapView.gestures.options.doubleTapToZoomInEnabled = true
        mapView.gestures.options.doubleTouchToZoomOutEnabled = true

        // Hide Mapbox's built-in top-leading scale-bar ornament. OmniTAK draws
        // its own toggleable scale bar (ScaleBarView, bottom-left), so the
        // native one produced a double scale bar on the 2D map.
        mapView.ornaments.options.scaleBar.visibility = .hidden

        // Issue #64 — the built-in rotate-compass ornament keeps the SDK
        // default (.topTrailing, 8pt margins, adaptive visibility), so when the
        // operator rotates the map it pops UNDER the full-width opaque status
        // strip and is unreachable. Push it down below the status bar so the
        // tap-to-reset-north affordance is visible. OmniTAK's own
        // CompassOverlayView (also top-trailing) only mounts when the compass
        // overlay toggle or north-lock is on; this keeps the native rotate
        // affordance usable the rest of the time without the two stacking.
        // The y margin clears the status strip (~44pt) plus a small gap; x
        // keeps it off the right edge a touch more than the 8pt default so it
        // doesn't sit directly beneath OmniTAK's compass when both are shown.
        mapView.ornaments.options.compass.position = .topTrailing
        mapView.ornaments.options.compass.margins = CGPoint(x: 12, y: 96)

        // Tap → contact hit-test / map-tap fan-out
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMapTap(_:))
        )
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        mapView.addGestureRecognizer(tap)

        // Long-press → radial menu (with marker context awareness)
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = 0.5
        longPress.cancelsTouchesInView = false
        mapView.addGestureRecognizer(longPress)

        // Lasso multi-select — separate recognizer gated on
        // DrawingToolsManager.currentMode == .lasso (issue #16). When
        // inactive it no-ops; when active it suppresses pan so the
        // user can drag a free-form selection.
        let lasso = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleLassoGesture(_:))
        )
        lasso.minimumPressDuration = 0.25
        lasso.allowableMovement = .greatestFiniteMagnitude
        lasso.cancelsTouchesInView = true
        lasso.delegate = context.coordinator
        mapView.addGestureRecognizer(lasso)
        context.coordinator.lassoGesture = lasso

        // Issue #60 (move/reposition follow-up) — drag-to-reposition gesture,
        // gated on DrawingMoveSession.isActive. When inactive it no-ops; when
        // active it captures the single-finger pan and rigidly translates the
        // selected shape. `updateUIView` also disables map pan while moving so
        // the camera stays put under the dragged shape.
        let movePan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleMovePanGesture(_:))
        )
        movePan.maximumNumberOfTouches = 1
        movePan.cancelsTouchesInView = true
        movePan.delegate = context.coordinator
        mapView.addGestureRecognizer(movePan)
        context.coordinator.movePanGesture = movePan

        // Issue #84 — vertex-edit drag gesture, gated on
        // DrawingVertexEditSession.isActive. On touch-down it forwards the
        // touched map coordinate so the parent hit-tests the grabbed handle;
        // each frame forwards the dragged coordinate so the parent moves that
        // vertex (or the circle radius handle). Like move, `updateUIView`
        // disables map pan while active so the drag moves the vertex, not the
        // camera.
        let vertexPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleVertexEditPanGesture(_:))
        )
        vertexPan.maximumNumberOfTouches = 1
        vertexPan.cancelsTouchesInView = true
        vertexPan.delegate = context.coordinator
        mapView.addGestureRecognizer(vertexPan)
        context.coordinator.vertexEditPanGesture = vertexPan

        // Lifecycle hooks — load terrain + atmosphere on style load
        // so the operator gets immediate 3D depth without a settings
        // detour, and mirror camera changes back into the SwiftUI
        // region binding for downstream consumers (scale bar, MGRS
        // grid, overlay coordinator).
        let coord = context.coordinator
        coord.mapView = mapView

        coord.styleLoadedToken = mapView.mapboxMap.onStyleLoaded.observe { [weak coord] _ in
            DispatchQueue.main.async {
                coord?.installTerrainAndAtmosphere()
                coord?.refreshAll()
            }
        }

        coord.cameraChangedToken = mapView.mapboxMap.onCameraChanged.observe { [weak coord, weak mapView] _ in
            guard let coord = coord, let mapView = mapView else { return }
            coord.handleCameraChanged(mapView: mapView)
        }

        // Issue #72/#73 — listen for the north-snap notification so
        // both the compass tap and the north-lock toggle route through
        // the same path on the 2D engine.
        coord.resetNorthObserver = NotificationCenter.default.addObserver(
            forName: .mapboxResetNorth, object: nil, queue: .main
        ) { [weak coord, weak mapView] _ in
            guard let mapView = mapView else { return }
            coord?.isProgrammaticUpdate = true
            let state = mapView.mapboxMap.cameraState
            mapView.mapboxMap.setCamera(to: CameraOptions(
                center: state.center,
                zoom: state.zoom,
                bearing: 0,
                pitch: state.pitch
            ))
        }

        return mapView
    }

    func updateUIView(_ mapView: MapView, context: Context) {
        context.coordinator.parent = self

        // Style swap on mapType change
        let desiredStyle = TacticalMapView.styleURI(for: mapType)
        if context.coordinator.lastAppliedStyle != desiredStyle {
            context.coordinator.lastAppliedStyle = desiredStyle
            let coord = context.coordinator
            mapView.mapboxMap.loadStyle(desiredStyle) { [weak coord] _ in
                DispatchQueue.main.async {
                    coord?.installTerrainAndAtmosphere()
                    coord?.refreshAll()
                }
            }
        }

        // Issue #72 — north-lock: disable rotation gesture while locked,
        // re-enable when released. The Mapbox API exposes this cleanly on
        // gestures.options without tearing down the whole gesture stack.
        mapView.gestures.options.rotateEnabled = !isNorthLocked

        // Issue #60 (move/reposition follow-up) — while repositioning a shape,
        // disable the map's own pan so the single-finger drag moves the SHAPE
        // (via the movePan recognizer), not the camera. Restore pan on exit.
        // Issue #84 — same while vertex-editing (the vertexPan owns the drag).
        mapView.gestures.options.panEnabled =
            !drawingMoveSession.isActive && !drawingVertexEditSession.isActive

        // Region sync — only push to Mapbox if the SwiftUI region
        // diverges from the camera state by more than a hair. This is
        // the same feedback-loop guard MKMapView needed.
        if !context.coordinator.isUserInteracting {
            let cameraState = mapView.mapboxMap.cameraState
            let centerChanged =
                abs(cameraState.center.latitude - region.center.latitude) > 0.0001 ||
                abs(cameraState.center.longitude - region.center.longitude) > 0.0001
            let zoomChanged = abs(cameraState.zoom - TacticalMapView.zoom(forSpan: region.span, mapHeight: mapView.bounds.height)) > 0.25
            // Issue #72 — when north-locked, always keep bearing at 0.
            let bearingForUpdate = isNorthLocked ? 0.0 : cameraState.bearing
            if centerChanged || zoomChanged {
                context.coordinator.isProgrammaticUpdate = true
                // Explicitly preserve current pitch + bearing — MKCoordinateRegion
                // has no concept of either, so a naïve CameraOptions(center:zoom:)
                // would let Mapbox flatten the 3D camera back to top-down on every
                // SwiftUI re-invalidation.
                let opts = CameraOptions(
                    center: region.center,
                    zoom: TacticalMapView.zoom(forSpan: region.span, mapHeight: mapView.bounds.height),
                    bearing: bearingForUpdate,
                    pitch: cameraState.pitch
                )
                mapView.mapboxMap.setCamera(to: opts)
                context.coordinator.isProgrammaticUpdate = false
            }
        }

        // Self-position puck style (Settings → "Self-position marker").
        // Re-apply when the persisted style changes so the picker takes
        // effect live, without rebuilding the map view.
        if showsUserLocation {
            let style = UserDefaults.standard.string(forKey: "selfMarkerStyle") ?? "milstd"
            if context.coordinator.lastSelfMarkerStyle != style {
                context.coordinator.lastSelfMarkerStyle = style
                mapView.location.options.puckType = TacticalMapView.selfPuckType()
                // Issue #66 — also update the bearing mode so the arrow puck
                // rotates with device heading when the user switches to it.
                TacticalMapView.applyPuckBearing(to: mapView)
            }
        }

        // Re-publish all annotation layers from the latest model state.
        context.coordinator.refreshAll()

        // MGRS center label + visible-region housekeeping. The MGRS
        // grid itself is rendered by SwiftUI `GridOverlayView` over
        // the map (set up in ATAKMapView), so we just keep the
        // coordinator aware of the camera.
        overlayCoordinator.updateVisibleOverlays(in: region)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// User-location puck honoring the Settings "Self-position marker"
    /// picker:
    ///   "milstd"   → MIL-STD-2525 friendly-combat frame (default)
    ///   "bullseye" → legacy tactical bullseye
    ///   "arrow"    → heading-indicating triangle (Issue #66). Puck bearing
    ///                is set to .heading via `applyPuckBearing(_:)` after
    ///                this returns.
    static func selfPuckType() -> PuckType {
        let style = UserDefaults.standard.string(forKey: "selfMarkerStyle") ?? "milstd"
        let image: UIImage
        switch style {
        case "bullseye":
            image = SelfPositionMarkerImage.bullseye
        case "arrow":
            image = SelfPositionMarkerImage.arrowMarker()
        default:
            image = SelfPositionMarkerImage.milStdFriendlyCombat
        }
        var config = Puck2DConfiguration(topImage: image)
        config.showsAccuracyRing = true
        return .puck2D(config)
    }

    /// Apply the bearing-tracking option that pairs with the chosen puck style.
    /// "arrow" uses .heading (north-relative, rotates with device heading);
    /// other styles keep puckBearingEnabled false so the puck stays upright.
    static func applyPuckBearing(to mapView: MapView) {
        let style = UserDefaults.standard.string(forKey: "selfMarkerStyle") ?? "milstd"
        mapView.location.options.puckBearing = .heading
        mapView.location.options.puckBearingEnabled = (style == "arrow")
    }

    // MARK: - Style mapping

    /// Translate the legacy `MKMapType` chosen in the bottom toolbar to a
    /// Mapbox `StyleURI`. We default to Standard (3D buildings + atmos
    /// + lighting) for the strongest first-launch impression, and fall
    /// back to satellite/streets variants when the operator switches
    /// layers in the layers panel.
    static func styleURI(for mapType: MKMapType) -> StyleURI {
        switch mapType {
        case .satellite, .satelliteFlyover:
            return .satellite
        case .hybrid, .hybridFlyover:
            return .satelliteStreets
        case .mutedStandard:
            return .light
        case .standard:
            return .standard
        @unknown default:
            return .standard
        }
    }

    /// Approximate a Mapbox zoom level from an `MKCoordinateSpan`. The
    /// legacy MKMapView toolbar speaks in degrees-per-span; Mapbox in
    /// power-of-two zoom. We hold latitude constant and pick the zoom
    /// where one tile (~256pt) covers the requested longitude span,
    /// clamped to the standard range.
    static func zoom(forSpan span: MKCoordinateSpan, mapHeight: CGFloat) -> Double {
        let lonDelta = max(span.longitudeDelta, 0.0005)
        // Mercator zoom: 360° = full world at zoom 0; each zoom level
        // halves the visible span.
        let zoom = log2(360.0 / lonDelta)
        return min(max(zoom, 0), 22)
    }

    /// Inverse of `zoom(forSpan:)` so the coordinator can round-trip
    /// camera state into the `MKCoordinateSpan` the SwiftUI region
    /// binding expects.
    static func span(forZoom zoom: Double, latitude: Double) -> MKCoordinateSpan {
        let lonDelta = 360.0 / pow(2.0, max(zoom, 0))
        let latDelta = lonDelta * cos(latitude * .pi / 180)
        return MKCoordinateSpan(
            latitudeDelta: max(latDelta, 0.0005),
            longitudeDelta: max(lonDelta, 0.0005)
        )
    }

    // MARK: - Coordinator

    /// All of the per-MapView state lives here: annotation managers,
    /// observation tokens, lasso layer, marker image cache. The
    /// SwiftUI struct above only forwards bindings and triggers
    /// refreshes — every actual Mapbox call goes through this class.
    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TacticalMapView
        weak var mapView: MapView?

        // Lifecycle / observation tokens
        var styleLoadedToken: AnyCancelable?
        var cameraChangedToken: AnyCancelable?
        var lastAppliedStyle: StyleURI = .standard
        /// Last applied self-puck style ("milstd" | "bullseye") so
        /// updateUIView only re-pushes the puck config on change.
        var lastSelfMarkerStyle: String = "milstd"

        // Camera feedback-loop guards
        var isUserInteracting = false
        var isProgrammaticUpdate = false

        // Issue #72/#73 — reset-north observer (removes itself on dealloc)
        var resetNorthObserver: NSObjectProtocol?

        // Annotation managers — one per geometry kind. Mapbox v11
        // wants us to reuse these (cheap to create, expensive to
        // churn). `ensure*Manager` lazily attaches them after the
        // first style load.
        private var cotMarkerManager: PointAnnotationManager?
        private var pointMarkerManager: PointAnnotationManager?
        private var aircraftManager: PointAnnotationManager?
        private var drawingMarkerManager: PointAnnotationManager?
        private var drawingLabelManager: PointAnnotationManager?
        private var measurementVertexManager: PointAnnotationManager?
        // Issue #84 — draggable vertex handles for the shape under vertex edit.
        private var vertexHandleManager: PointAnnotationManager?
        private var drawingLineManager: PolylineAnnotationManager?
        private var drawingPolygonManager: PolygonAnnotationManager?
        private var drawingTempLineManager: PolylineAnnotationManager?
        private var measurementLineManager: PolylineAnnotationManager?
        private var rangeBearingLineManager: PolylineAnnotationManager?
        private var rangeBearingLabelManager: PointAnnotationManager?
        private var breadcrumbLineManager: PolylineAnnotationManager?
        private var rangeRingManager: PolygonAnnotationManager?
        private var lassoSelectionRingManager: PolygonAnnotationManager?

        // Annotation signature cache — `refreshAll()` runs on every
        // SwiftUI `updateUIView` *and* every camera tick (because
        // `handleCameraChanged` re-publishes `parent.region`). Without
        // this guard each refresh re-assigns `manager.annotations`,
        // and Mapbox treats every assignment as a fresh symbol layer
        // which produces visible flicker on labels + markers. We hash
        // the stable inputs (id + coordinate + text + color) per
        // layer and short-circuit the assignment when nothing
        // material has changed.
        private var annotationSignatures: [String: Int] = [:]
        private func shouldPublish(layer: String, signature: Int) -> Bool {
            if annotationSignatures[layer] == signature { return false }
            annotationSignatures[layer] = signature
            return true
        }

        // Lasso — same CAShapeLayer approach the MKMapView version
        // used, just attached to the Mapbox MapView's layer. Cheaper
        // and flicker-free vs. churning annotations on every touch.
        weak var lassoGesture: UILongPressGestureRecognizer?
        private var lassoPathLayer: CAShapeLayer?
        private var lassoViewPoints: [CGPoint] = []

        // Issue #60 (move/reposition follow-up) — drag-to-reposition recognizer
        // and the last screen point we translated from (to derive per-frame
        // lat/lon deltas as the finger moves).
        weak var movePanGesture: UIPanGestureRecognizer?
        private var lastMovePanPoint: CGPoint?

        // Issue #84 — vertex-edit drag recognizer. Unlike move (which tracks a
        // delta), this forwards absolute coordinates: the grabbed vertex on
        // touch-down, then the dragged coordinate each frame.
        weak var vertexEditPanGesture: UIPanGestureRecognizer?

        // MIL-STD-2525 symbol cache — UIHostingController snapshots
        // keyed by (cotType, callsign) so we don't rebuild the image
        // on every frame. Bounded; cleared on memory warnings.
        private var symbolImageCache: [String: UIImage] = [:]
        private let symbolImageCacheCapacity = 256

        init(_ parent: TacticalMapView) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleMemoryWarning),
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleMemoryWarning() {
            symbolImageCache.removeAll(keepingCapacity: false)
        }

        // MARK: - Terrain / atmosphere

        /// Wire up the DEM source, terrain expression, and atmosphere
        /// after the style finishes loading. Idempotent — safe to
        /// call again after a style swap.
        func installTerrainAndAtmosphere() {
            guard let mapView = mapView else { return }
            do {
                if !mapView.mapboxMap.sourceExists(withId: "mapbox-dem") {
                    var dem = RasterDemSource(id: "mapbox-dem")
                    dem.url = "mapbox://mapbox.mapbox-terrain-dem-v1"
                    dem.tileSize = 514
                    dem.maxzoom = 14.0
                    try mapView.mapboxMap.addSource(dem)
                }

                var terrain = Terrain(sourceId: "mapbox-dem")
                terrain.exaggeration = .constant(1.5)
                try mapView.mapboxMap.setTerrain(terrain)

                var atmosphere = Atmosphere()
                atmosphere.color = .constant(StyleColor(red: 0, green: 128, blue: 255, alpha: 1.0)!)
                atmosphere.highColor = .constant(StyleColor(red: 25, green: 77, blue: 179, alpha: 1.0)!)
                atmosphere.horizonBlend = .constant(0.1)
                atmosphere.spaceColor = .constant(StyleColor(red: 0, green: 0, blue: 13, alpha: 1.0)!)
                atmosphere.starIntensity = .constant(0.15)
                try mapView.mapboxMap.setAtmosphere(atmosphere)

                // Force the 3D camera back on after every style load. Mapbox
                // Standard (and most v11 styles) reset pitch to whatever the
                // style declares — usually 0° — when loadStyle resolves, even
                // if MapInitOptions asked for 60°. Re-apply pitch (and bearing
                // for consistency) once terrain is wired up so the operator
                // actually sees the 3D tilt the engine swap was supposed to
                // deliver.
                let state = mapView.mapboxMap.cameraState
                if state.pitch < 30 {
                    mapView.mapboxMap.setCamera(to: CameraOptions(pitch: 60))
                }
            } catch {
                print("TacticalMapView: terrain/atmosphere setup failed — \(error)")
            }
        }

        // MARK: - Camera plumbing

        /// React to a Mapbox camera-change event by mirroring the new
        /// state back to the SwiftUI `region` binding so the rest of
        /// the app (scale bar, MGRS center label, layer toggles) keeps
        /// up with whatever the operator is doing on screen.
        func handleCameraChanged(mapView: MapView) {
            let state = mapView.mapboxMap.cameraState
            if !isProgrammaticUpdate {
                isUserInteracting = true
            }
            let newRegion = MKCoordinateRegion(
                center: state.center,
                span: TacticalMapView.span(forZoom: state.zoom, latitude: state.center.latitude)
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.parent.region = newRegion
                // Issue #73 — report bearing so the compass overlay needle tracks
                // the 2D map's rotation (not just the device's magnetometer).
                self.parent.onBearingChanged?(state.bearing)
                // Issue #72 — if north-lock is engaged, snap back to 0° on any
                // user-initiated rotation (bearing drift > 0.5° threshold).
                if self.parent.isNorthLocked && !self.isProgrammaticUpdate && abs(state.bearing) > 0.5 {
                    self.isProgrammaticUpdate = true
                    mapView.mapboxMap.setCamera(to: CameraOptions(
                        center: state.center,
                        zoom: state.zoom,
                        bearing: 0,
                        pitch: state.pitch
                    ))
                    self.isProgrammaticUpdate = false
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isUserInteracting = false
            }
        }

        // MARK: - Annotation refresh fan-out

        /// Single entry-point that updateUIView calls every time the
        /// SwiftUI parent re-renders. Each refresh function diffs the
        /// model against the live annotations on its own manager, so
        /// repeated calls stay cheap.
        func refreshAll() {
            refreshCotMarkers()
            refreshPointMarkers()
            refreshAircraftMarkers()
            refreshDrawingMarkers()
            refreshDrawingLabels()
            refreshDrawingLines()
            refreshDrawingPolygons()
            refreshDrawingCircles()
            refreshDrawingTempOverlay()
            refreshVertexHandles()
            refreshMeasurementOverlay()
            refreshRangeBearing()
            refreshBreadcrumbTrail()
            refreshLassoHighlightRings()
            refreshKMLVectorOverlays()
            refreshRasterOverlays()
            refreshMBTilesOverlays()
        }

        // MARK: - Large-KML vector overlays (GeoJSONSource + line/fill/circle)
        //
        // Unlike the per-feature annotation managers above, imported KML
        // overlays render through a single Mapbox GeoJSONSource per overlay
        // (data loaded natively from the on-disk .geojson) plus shared
        // line / fill / circle layers. This is what lets a 50,000-trail
        // import render + toggle smoothly where the annotation path (and
        // competitors) crash. Toggling is a layer-visibility flip.
        private var installedKMLOverlayIDs = Set<String>()

        func refreshKMLVectorOverlays() {
            guard let mapView = mapView else { return }
            let map: MapboxMap = mapView.mapboxMap
            guard map.isStyleLoaded else { return }
            let overlays = parent.kmlVectorStore.overlays
            let wanted = Set(overlays.map { $0.id })

            // Tear down overlays that are gone.
            for id in installedKMLOverlayIDs where !wanted.contains(id) {
                for layerID in kmlLayerIDs(id) where map.layerExists(withId: layerID) {
                    try? map.removeLayer(withId: layerID)
                }
                let sourceID = "kmlsrc-\(id)"
                if map.sourceExists(withId: sourceID) { try? map.removeSource(withId: sourceID) }
            }
            installedKMLOverlayIDs = wanted

            for overlay in overlays {
                let sourceID = "kmlsrc-\(overlay.id)"
                if !map.sourceExists(withId: sourceID) {
                    addKMLOverlayLayers(map: map, overlay: overlay, sourceID: sourceID)
                }
                // Re-apply styling every refresh so edits (color / opacity /
                // line width / visibility) take effect live without a reload.
                styleKMLLayers(map: map, overlay: overlay)
            }
        }

        private func kmlLayerIDs(_ overlayID: String) -> [String] {
            // Issue #93 — kmlsym- replaces kmlpt- (circle) for Point placemarks.
            ["kmlfill-\(overlayID)", "kmlline-\(overlayID)", "kmlpt-\(overlayID)", "kmlsym-\(overlayID)"]
        }

        // MARK: - KML pushpin image (Issue #93)
        //
        // A classic teardrop pin rendered once and reused across all KML overlays.
        // Yellow fill (#FFD400), dark outline, white centre dot — matches ATAK /
        // Google Earth style. Registered into the map style by image ID so the
        // SymbolLayer can reference it by name.
        private static let kmlPushpinImageID = "kml-pushpin"

        /// Draw the yellow pushpin and register it in the map style. Idempotent:
        /// skips registration if the image is already present.
        private func ensureKMLPushpinImage(map: MapboxMap) {
            guard !map.imageExists(withId: Self.kmlPushpinImageID) else { return }
            let pinSize = CGSize(width: 28, height: 40)
            let renderer = UIGraphicsImageRenderer(size: pinSize)
            let pinImage = renderer.image { ctx in
                let cgCtx = ctx.cgContext
                let w = pinSize.width
                let h = pinSize.height
                // Teardrop body: rounded top half + triangular bottom tip.
                // The tip touches the bottom-centre; the round cap sits at the top.
                let radius: CGFloat = w / 2.0
                let bodyBottom: CGFloat = h * 0.58   // where the circle meets the stem
                let tipY: CGFloat = h - 1            // pin tip

                let path = UIBezierPath()
                // Start at the top-left of the circle
                path.move(to: CGPoint(x: 0, y: radius))
                // Top arc (full circle at the top)
                path.addArc(withCenter: CGPoint(x: w / 2, y: radius),
                            radius: radius,
                            startAngle: .pi,
                            endAngle: 0,
                            clockwise: true)
                // Right side down to the tip
                path.addLine(to: CGPoint(x: w / 2 + radius * 0.25, y: bodyBottom))
                // Curve to the tip
                path.addQuadCurve(to: CGPoint(x: w / 2, y: tipY),
                                  controlPoint: CGPoint(x: w / 2 + radius * 0.12, y: tipY - 4))
                // Left side from tip back up
                path.addQuadCurve(to: CGPoint(x: w / 2 - radius * 0.25, y: bodyBottom),
                                  controlPoint: CGPoint(x: w / 2 - radius * 0.12, y: tipY - 4))
                path.addLine(to: CGPoint(x: 0, y: radius))
                path.close()

                // Dark outline
                UIColor(red: 0.18, green: 0.12, blue: 0.0, alpha: 1.0).setFill()
                path.fill()

                // Yellow fill (inset by stroke width)
                let fillPath = UIBezierPath()
                let s: CGFloat = 2.0   // stroke width
                let fr = radius - s
                fillPath.move(to: CGPoint(x: s, y: radius))
                fillPath.addArc(withCenter: CGPoint(x: w / 2, y: radius),
                                radius: fr,
                                startAngle: .pi,
                                endAngle: 0,
                                clockwise: true)
                fillPath.addLine(to: CGPoint(x: w / 2 + fr * 0.25, y: bodyBottom))
                fillPath.addQuadCurve(to: CGPoint(x: w / 2, y: tipY - s),
                                      controlPoint: CGPoint(x: w / 2 + fr * 0.12, y: tipY - s - 3))
                fillPath.addQuadCurve(to: CGPoint(x: w / 2 - fr * 0.25, y: bodyBottom),
                                      controlPoint: CGPoint(x: w / 2 - fr * 0.12, y: tipY - s - 3))
                fillPath.addLine(to: CGPoint(x: s, y: radius))
                fillPath.close()
                UIColor(red: 1.0, green: 0.831, blue: 0.0, alpha: 1.0).setFill()  // #FFD400
                fillPath.fill()

                // White centre dot
                let dotR: CGFloat = radius * 0.28
                let dotRect = CGRect(x: w / 2 - dotR, y: radius - dotR, width: dotR * 2, height: dotR * 2)
                cgCtx.setFillColor(UIColor.white.cgColor)
                cgCtx.fillEllipse(in: dotRect)
            }
            try? map.addImage(pinImage, id: Self.kmlPushpinImageID, sdf: false)
        }

        private func addKMLOverlayLayers(map: MapboxMap, overlay: KMLVectorOverlay, sourceID: String) {
            var source = GeoJSONSource(id: sourceID)
            // Load the parsed GeoJSON natively from disk (Mapbox parses +
            // tiles it off the main thread — no giant in-memory feature list).
            source.data = .url(parent.kmlVectorStore.fileURL(overlay))
            // Douglas-Peucker simplification during tiling — drops redundant
            // vertices on dense trail geometry without a visible change.
            source.tolerance = 1.0
            do { try map.addSource(source) } catch { return }

            let fill = FillLayer(id: "kmlfill-\(overlay.id)", source: sourceID)
            try? map.addLayer(fill)
            var line = LineLayer(id: "kmlline-\(overlay.id)", source: sourceID)
            line.lineCap = .constant(.round)
            line.lineJoin = .constant(.round)
            try? map.addLayer(line)

            // Issue #93 — Point placemarks render as yellow pushpin + name label
            // via a SymbolLayer. The legacy CircleLayer (kmlpt-) is kept hidden
            // under it as a fallback; the SymbolLayer (kmlsym-) is the visible layer.
            var circle = CircleLayer(id: "kmlpt-\(overlay.id)", source: sourceID)
            circle.circleStrokeColor = .constant(StyleColor(.white))
            circle.circleStrokeWidth = .constant(1.0)
            // Point-only filter — lines and polygons generate centroid points in
            // Mapbox tiling; hide those from the circle layer too.
            circle.filter = Exp(.eq) { Exp(.geometryType); "Point" }
            try? map.addLayer(circle)

            ensureKMLPushpinImage(map: map)

            // SymbolLayer: yellow pushpin + placemark name label for Point features.
            var sym = SymbolLayer(id: "kmlsym-\(overlay.id)", source: sourceID)
            sym.filter = Exp(.eq) { Exp(.geometryType); "Point" }
            sym.iconImage = .constant(.name(Self.kmlPushpinImageID))
            sym.iconAnchor = .constant(.bottom)
            sym.iconAllowOverlap = .constant(true)
            sym.textField = .expression(Exp(.get) { "name" })
            sym.textColor = .constant(StyleColor(.white))
            sym.textHaloColor = .constant(StyleColor(.black))
            sym.textHaloWidth = .constant(1.2)
            sym.textSize = .constant(12)
            sym.textAnchor = .constant(.top)
            sym.textOffset = .constant([0, 0.6])
            sym.textOptional = .constant(true)
            sym.textAllowOverlap = .constant(false)
            try? map.addLayer(sym)
        }

        /// Apply the overlay's color / opacity / line width / visibility to its
        /// layers. Idempotent — safe to call on every refresh.
        private func styleKMLLayers(map: MapboxMap, overlay: KMLVectorOverlay) {
            let hex = overlay.colorHex
            let vis = overlay.visible ? "visible" : "none"
            let m = overlay.lineWidth
            // Width interpolates with zoom (fine when out, bolder when in),
            // scaled by the per-overlay line-width multiplier.
            let widthExpr: [Any] = ["interpolate", ["linear"], ["zoom"],
                                    6.0, 0.6 * m, 12.0, 1.6 * m, 16.0, 3.0 * m]
            let fillID = "kmlfill-\(overlay.id)"
            try? map.setLayerProperty(for: fillID, property: "visibility", value: vis)
            try? map.setLayerProperty(for: fillID, property: "fill-color", value: hex)
            try? map.setLayerProperty(for: fillID, property: "fill-outline-color", value: hex)
            try? map.setLayerProperty(for: fillID, property: "fill-opacity", value: overlay.opacity * 0.25)
            let lineID = "kmlline-\(overlay.id)"
            try? map.setLayerProperty(for: lineID, property: "visibility", value: vis)
            try? map.setLayerProperty(for: lineID, property: "line-color", value: hex)
            try? map.setLayerProperty(for: lineID, property: "line-opacity", value: overlay.opacity)
            try? map.setLayerProperty(for: lineID, property: "line-width", value: widthExpr)
            // Issue #93 — circle layer hidden; symbol layer drives point visibility.
            // Keep the circle properties synced anyway so toggling still works if
            // the symbol layer ever needs a fallback.
            let ptID = "kmlpt-\(overlay.id)"
            try? map.setLayerProperty(for: ptID, property: "visibility", value: "none")
            try? map.setLayerProperty(for: ptID, property: "circle-color", value: hex)
            try? map.setLayerProperty(for: ptID, property: "circle-opacity", value: overlay.opacity)
            let symID = "kmlsym-\(overlay.id)"
            try? map.setLayerProperty(for: symID, property: "visibility", value: vis)
        }

        // MARK: - Raster / imagery overlays (ImageSource + RasterLayer)
        //
        // Georeferenced single-image overlays (KMZ GroundOverlay now; GeoTIFF
        // etc. later) render as a Mapbox ImageSource positioned by its corner
        // box, with a RasterLayer on top. Opacity + visibility apply live.
        private var installedRasterOverlayIDs = Set<String>()

        func refreshRasterOverlays() {
            guard let mapView = mapView else { return }
            let map: MapboxMap = mapView.mapboxMap
            guard map.isStyleLoaded else { return }
            let overlays = parent.rasterStore.overlays
            let wanted = Set(overlays.map { $0.id })

            for id in installedRasterOverlayIDs where !wanted.contains(id) {
                let layerID = "rasterlyr-\(id)"
                if map.layerExists(withId: layerID) { try? map.removeLayer(withId: layerID) }
                let sourceID = "rastersrc-\(id)"
                if map.sourceExists(withId: sourceID) { try? map.removeSource(withId: sourceID) }
            }
            installedRasterOverlayIDs = wanted

            for overlay in overlays {
                let sourceID = "rastersrc-\(overlay.id)"
                let layerID = "rasterlyr-\(overlay.id)"
                if !map.sourceExists(withId: sourceID) {
                    var source = ImageSource(id: sourceID)
                    // Corner order: top-left, top-right, bottom-right, bottom-left.
                    source.coordinates = [
                        [overlay.west, overlay.north], [overlay.east, overlay.north],
                        [overlay.east, overlay.south], [overlay.west, overlay.south],
                    ]
                    source.url = parent.rasterStore.imageURL(overlay).absoluteString
                    do { try map.addSource(source) } catch { continue }
                    var layer = RasterLayer(id: layerID, source: sourceID)
                    layer.rasterOpacity = .constant(overlay.opacity)
                    try? map.addLayer(layer)
                }
                let vis = overlay.visible ? "visible" : "none"
                try? map.setLayerProperty(for: layerID, property: "visibility", value: vis)
                try? map.setLayerProperty(for: layerID, property: "raster-opacity", value: overlay.opacity)
            }
        }

        // MARK: - MBTiles raster basemaps (RasterSource → local tile server)
        private var installedMBTilesIDs = Set<String>()

        func refreshMBTilesOverlays() {
            guard let mapView = mapView else { return }
            let map: MapboxMap = mapView.mapboxMap
            guard map.isStyleLoaded else { return }
            let overlays = parent.mbtilesStore.overlays
            let wanted = Set(overlays.map { $0.id })

            for id in installedMBTilesIDs where !wanted.contains(id) {
                let layerID = "mbtileslyr-\(id)"
                if map.layerExists(withId: layerID) { try? map.removeLayer(withId: layerID) }
                let sourceID = "mbtilessrc-\(id)"
                if map.sourceExists(withId: sourceID) { try? map.removeSource(withId: sourceID) }
            }
            installedMBTilesIDs = wanted

            for overlay in overlays {
                let sourceID = "mbtilessrc-\(overlay.id)"
                let layerID = "mbtileslyr-\(overlay.id)"
                if !map.sourceExists(withId: sourceID) {
                    guard let template = parent.mbtilesStore.tileURLTemplate(overlay) else { continue }
                    var source = RasterSource(id: sourceID)
                    source.tiles = [template]
                    source.tileSize = 256
                    source.minzoom = Double(overlay.minZoom)
                    source.maxzoom = Double(overlay.maxZoom)
                    do { try map.addSource(source) } catch { continue }
                    var layer = RasterLayer(id: layerID, source: sourceID)
                    layer.rasterOpacity = .constant(overlay.opacity)
                    try? map.addLayer(layer)
                }
                let vis = overlay.visible ? "visible" : "none"
                try? map.setLayerProperty(for: layerID, property: "visibility", value: vis)
                try? map.setLayerProperty(for: layerID, property: "raster-opacity", value: overlay.opacity)
            }
        }

        // Lazy-attach helpers — one per annotation kind. Mapbox v11
        // returns ready-to-use managers; we keep our own refs so we
        // can clear/replace their `.annotations` arrays per refresh.
        private func ensurePoint(_ keyPath: ReferenceWritableKeyPath<Coordinator, PointAnnotationManager?>) -> PointAnnotationManager? {
            if let m = self[keyPath: keyPath] { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePointAnnotationManager()
            self[keyPath: keyPath] = m
            return m
        }
        private func ensureLine(_ keyPath: ReferenceWritableKeyPath<Coordinator, PolylineAnnotationManager?>) -> PolylineAnnotationManager? {
            if let m = self[keyPath: keyPath] { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePolylineAnnotationManager()
            self[keyPath: keyPath] = m
            return m
        }
        private func ensurePolygon(_ keyPath: ReferenceWritableKeyPath<Coordinator, PolygonAnnotationManager?>) -> PolygonAnnotationManager? {
            if let m = self[keyPath: keyPath] { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePolygonAnnotationManager()
            self[keyPath: keyPath] = m
            return m
        }

        // MARK: - CoT markers (live contacts)

        private func refreshCotMarkers() {
            guard let manager = ensurePoint(\.cotMarkerManager) else { return }
            var fresh: [PointAnnotation] = []
            fresh.reserveCapacity(parent.markers.count)
            for marker in parent.markers {
                // Style-image key folds in the icon source so a spot-map dot and
                // an affiliation frame of the same type don't share one image.
                let key = "cot|\(marker.type)|\(marker.iconsetPath ?? "")|\(marker.argbColor ?? 0)|\(marker.callsign)"
                let img = symbolImage(for: marker)
                var ann = PointAnnotation(id: "cot-\(marker.uid)", coordinate: marker.coordinate)
                ann.image = .init(image: img, name: key)
                ann.iconSize = 1.0
                ann.iconAnchor = .bottom
                fresh.append(ann)
            }
            manager.annotations = fresh
        }

        private func symbolImage(for marker: CoTMarker) -> UIImage {
            // Issue #75 — TAK icon suite. If the marker carries a known iconset
            // path (e.g. COT_MAPPING_SPOTMAP/red) or is a spot-map CoT type,
            // resolve it to the standard TAK icon. Falls through to MIL-STD-2525
            // when the registry has no match (the existing affiliation frames).
            if let img = TAKIconRegistry.shared.resolveImage(
                cotType: marker.type,
                iconsetPath: marker.iconsetPath,
                argb: marker.argbColor,
                size: 28
            ) {
                return img
            }

            let key = "cot|\(marker.type)|\(marker.callsign)"
            if let cached = symbolImageCache[key] { return cached }

            // Reuse the SwiftUI MilStdMarkerSymbolView used elsewhere
            // in the app so the symbology matches the radial menu and
            // overlay sheets pixel-for-pixel.
            let view = MilStdMarkerSymbolView(
                cotType: marker.type,
                callsign: marker.callsign,
                echelon: nil,
                size: 28,
                isSelected: false
            )
            let img = Self.snapshot(view, size: CGSize(width: 80, height: 56))
            if symbolImageCache.count >= symbolImageCacheCapacity {
                symbolImageCache.removeAll(keepingCapacity: true)
            }
            symbolImageCache[key] = img
            return img
        }

        /// SwiftUI → UIImage. Wrapped with `try?` so a transient
        /// rendering glitch returns an empty image rather than
        /// crashing the map.
        private static func snapshot<Content: View>(_ view: Content, size: CGSize) -> UIImage {
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = .clear
            host.view.frame = CGRect(origin: .zero, size: size)
            let renderer = UIGraphicsImageRenderer(size: size)
            return renderer.image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
        }

        // MARK: - Point markers (radial-menu-dropped pins)

        private func refreshPointMarkers() {
            guard let manager = ensurePoint(\.pointMarkerManager) else { return }
            var sigHasher = Hasher()
            sigHasher.combine(parent.pointMarkers.count)
            for pm in parent.pointMarkers {
                sigHasher.combine(pm.id); sigHasher.combine(pm.name)
                sigHasher.combine(pm.coordinate.latitude); sigHasher.combine(pm.coordinate.longitude)
                sigHasher.combine(pm.affiliation.rawValue)
            }
            guard shouldPublish(layer: "pointMarkers", signature: sigHasher.finalize()) else { return }
            var fresh: [PointAnnotation] = []
            fresh.reserveCapacity(parent.pointMarkers.count)
            for pm in parent.pointMarkers {
                let img = pointMarkerImage(for: pm)
                // Style-image key must distinguish each TAK icon pack from plain
                // affiliation glyphs, else two markers sharing an affiliation
                // but different pack icons would collide on one cached image.
                let key: String
                if let spot = pm.takIcon { key = "pm|spot|\(spot.rawValue)" }
                else if let mk = pm.markersIcon { key = "pm|mk|\(mk.rawValue)" }
                else if let g = pm.googleIcon { key = "pm|google|\(g.rawValue)" }
                else { key = "pm|\(pm.affiliation.rawValue)" }
                var ann = PointAnnotation(id: "pm-\(pm.id.uuidString)", coordinate: pm.coordinate)
                ann.image = .init(image: img, name: key)
                ann.textField = pm.name
                ann.textAnchor = .top
                ann.textOffset = [0, 1.2]
                ann.textColor = StyleColor(.white)
                ann.textHaloColor = StyleColor(.black)
                ann.textHaloWidth = 1.0
                ann.textSize = 11
                // Circular glyphs (spot dots, 2525 frames, affiliation) center on
                // the coordinate; the Google teardrop pin points at its tip, so
                // it anchors at the bottom.
                ann.iconAnchor = pm.googleIcon != nil ? .bottom : .center
                fresh.append(ann)
            }
            manager.annotations = fresh
        }

        private func pointMarkerImage(for marker: PointMarker) -> UIImage {
            // TAK icon suite (issue #75) — render the picked pack icon via the
            // shared registry so it matches the picker swatch and the 3D globe.
            if let spot = marker.takIcon {
                return TAKIconRegistry.shared.image(for: spot, size: 36)
            }
            if let mk = marker.markersIcon {
                return TAKIconRegistry.shared.image(for: mk, size: 36)
            }
            if let g = marker.googleIcon {
                return TAKIconRegistry.shared.image(for: g, size: 40)
            }
            let key = "pmimg|\(marker.affiliation.rawValue)"
            if let cached = symbolImageCache[key] { return cached }
            let size = CGSize(width: 36, height: 36)
            let renderer = UIGraphicsImageRenderer(size: size)
            let img = renderer.image { _ in
                let rect = CGRect(origin: .zero, size: size)
                marker.affiliation.color.uiColor.setFill()
                let outer = UIBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2))
                outer.fill()
                UIColor.white.setStroke()
                outer.lineWidth = 2
                outer.stroke()
                let iconRect = rect.insetBy(dx: 8, dy: 8).insetBy(dx: 2, dy: 2)
                UIColor.white.setFill()
                switch marker.affiliation {
                case .hostile:
                    let p = UIBezierPath()
                    p.move(to: CGPoint(x: iconRect.midX, y: iconRect.minY))
                    p.addLine(to: CGPoint(x: iconRect.maxX, y: iconRect.midY))
                    p.addLine(to: CGPoint(x: iconRect.midX, y: iconRect.maxY))
                    p.addLine(to: CGPoint(x: iconRect.minX, y: iconRect.midY))
                    p.close()
                    p.fill()
                case .friendly, .unknown:
                    UIBezierPath(ovalIn: iconRect).fill()
                case .neutral:
                    UIBezierPath(rect: iconRect).fill()
                }
            }
            symbolImageCache[key] = img
            return img
        }

        // MARK: - Aircraft (ADS-B)

        private func refreshAircraftMarkers() {
            guard let manager = ensurePoint(\.aircraftManager) else { return }
            var fresh: [PointAnnotation] = []
            fresh.reserveCapacity(parent.aircraft.count)
            for ac in parent.aircraft {
                var ann = PointAnnotation(id: "ac-\(ac.id)", coordinate: ac.coordinate)
                ann.image = PointAnnotation.Image(image: Self.aircraftImage, name: "aircraft-icon")
                ann.iconRotate = ac.heading
                ann.iconSize = 1.0
                ann.iconAnchor = IconAnchor.center
                ann.textField = ac.callsign.isEmpty ? ac.id : ac.callsign
                ann.textAnchor = TextAnchor.top
                ann.textOffset = [0, 1.2]
                ann.textColor = StyleColor(.systemBlue)
                ann.textHaloColor = StyleColor(.black)
                ann.textHaloWidth = 1
                ann.textSize = 10
                fresh.append(ann)
            }
            manager.annotations = fresh
        }

        private static let aircraftImage: UIImage = {
            let size = CGSize(width: 24, height: 24)
            let r = UIGraphicsImageRenderer(size: size)
            return r.image { ctx in
                let c = ctx.cgContext
                c.translateBy(x: size.width / 2, y: size.height / 2)
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: -10))
                path.addLine(to: CGPoint(x: 9, y: 6))
                path.addLine(to: CGPoint(x: 0, y: 2))
                path.addLine(to: CGPoint(x: -9, y: 6))
                path.close()
                UIColor.systemBlue.setFill()
                path.fill()
                UIColor.white.setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }()

        // MARK: - Drawings

        private func refreshDrawingMarkers() {
            guard let manager = ensurePoint(\.drawingMarkerManager) else { return }
            var sigHasher = Hasher()
            sigHasher.combine(parent.drawingStore.markers.count)
            for m in parent.drawingStore.markers {
                sigHasher.combine(m.id)
                sigHasher.combine(m.coordinate.latitude)
                sigHasher.combine(m.coordinate.longitude)
                sigHasher.combine(m.color.rawValue)
            }
            guard shouldPublish(layer: "drawingMarkers", signature: sigHasher.finalize()) else { return }
            var fresh: [PointAnnotation] = []
            for m in parent.drawingStore.markers {
                let img = drawingMarkerImage(color: m.color.uiColor)
                var ann = PointAnnotation(id: "dm-\(m.id.uuidString)", coordinate: m.coordinate)
                ann.image = .init(image: img, name: "drawmarker-\(m.color.rawValue)")
                ann.iconAnchor = .bottom
                fresh.append(ann)
            }
            manager.annotations = fresh
        }

        private func drawingMarkerImage(color: UIColor) -> UIImage {
            let key = "dm|\(color.description)"
            if let cached = symbolImageCache[key] { return cached }
            let size = CGSize(width: 30, height: 30)
            let r = UIGraphicsImageRenderer(size: size)
            let img = r.image { _ in
                color.setFill()
                let p = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size))
                p.fill()
                UIColor.white.setStroke()
                p.lineWidth = 2
                p.stroke()
            }
            symbolImageCache[key] = img
            return img
        }

        private func refreshDrawingLabels() {
            guard let manager = ensurePoint(\.drawingLabelManager) else { return }
            var sigHasher = Hasher()
            for c in parent.drawingStore.circles {
                sigHasher.combine(c.id); sigHasher.combine(c.label)
                sigHasher.combine(c.center.latitude); sigHasher.combine(c.center.longitude)
                sigHasher.combine(c.color.rawValue)
            }
            for p in parent.drawingStore.polygons {
                sigHasher.combine(p.id); sigHasher.combine(p.label)
                sigHasher.combine(p.coordinates.count); sigHasher.combine(p.color.rawValue)
            }
            for l in parent.drawingStore.lines {
                sigHasher.combine(l.id); sigHasher.combine(l.label)
                sigHasher.combine(l.coordinates.count); sigHasher.combine(l.color.rawValue)
            }
            guard shouldPublish(layer: "drawingLabels", signature: sigHasher.finalize()) else { return }
            var fresh: [PointAnnotation] = []
            for c in parent.drawingStore.circles {
                fresh.append(labelAnnotation(id: "lbl-c-\(c.id.uuidString)", coordinate: c.center, text: c.label, color: c.color.uiColor))
            }
            for p in parent.drawingStore.polygons {
                if let centroid = Self.centroid(of: p.coordinates) {
                    fresh.append(labelAnnotation(id: "lbl-p-\(p.id.uuidString)", coordinate: centroid, text: p.label, color: p.color.uiColor))
                }
            }
            for l in parent.drawingStore.lines where l.coordinates.count >= 2 {
                let mid = l.coordinates[l.coordinates.count / 2]
                fresh.append(labelAnnotation(id: "lbl-l-\(l.id.uuidString)", coordinate: mid, text: l.label, color: l.color.uiColor))
            }
            manager.annotations = fresh
        }

        private func labelAnnotation(id: String, coordinate: CLLocationCoordinate2D, text: String, color: UIColor) -> PointAnnotation {
            var ann = PointAnnotation(id: id, coordinate: coordinate)
            ann.textField = text
            ann.textColor = StyleColor(.white)
            ann.textHaloColor = StyleColor(color)
            ann.textHaloWidth = 2
            ann.textSize = 11
            ann.iconImage = ""  // text only
            return ann
        }

        private static func centroid(of coords: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
            guard !coords.isEmpty else { return nil }
            var lat = 0.0, lon = 0.0
            for c in coords { lat += c.latitude; lon += c.longitude }
            let n = Double(coords.count)
            return CLLocationCoordinate2D(latitude: lat / n, longitude: lon / n)
        }

        private func refreshDrawingLines() {
            guard let manager = ensureLine(\.drawingLineManager) else { return }
            var sigHasher = Hasher()
            for l in parent.drawingStore.lines {
                sigHasher.combine(l.id); sigHasher.combine(l.color.rawValue)
                sigHasher.combine(l.coordinates.count)
                for c in l.coordinates { sigHasher.combine(c.latitude); sigHasher.combine(c.longitude) }
            }
            guard shouldPublish(layer: "drawingLines", signature: sigHasher.finalize()) else { return }
            var fresh: [PolylineAnnotation] = []
            for l in parent.drawingStore.lines where l.coordinates.count >= 2 {
                var p = PolylineAnnotation(id: "dl-\(l.id.uuidString)", lineCoordinates: l.coordinates)
                p.lineColor = StyleColor(l.color.uiColor)
                p.lineWidth = 3
                fresh.append(p)
            }
            manager.annotations = fresh
        }

        private func refreshDrawingPolygons() {
            guard let manager = ensurePolygon(\.drawingPolygonManager) else { return }
            var sigHasher = Hasher()
            for poly in parent.drawingStore.polygons {
                sigHasher.combine(poly.id); sigHasher.combine(poly.color.rawValue)
                sigHasher.combine(poly.coordinates.count)
                for c in poly.coordinates { sigHasher.combine(c.latitude); sigHasher.combine(c.longitude) }
            }
            guard shouldPublish(layer: "drawingPolygons", signature: sigHasher.finalize()) else { return }
            var fresh: [PolygonAnnotation] = []
            for poly in parent.drawingStore.polygons where poly.coordinates.count >= 3 {
                let ring = Ring(coordinates: poly.coordinates)
                let polygon = Polygon(outerRing: ring)
                var p = PolygonAnnotation(id: "dp-\(poly.id.uuidString)", polygon: polygon)
                p.fillColor = StyleColor(poly.color.uiColor.withAlphaComponent(0.2))
                p.fillOutlineColor = StyleColor(poly.color.uiColor)
                fresh.append(p)
            }
            manager.annotations = fresh
        }

        private func refreshDrawingCircles() {
            // Circles are meter-radius — Mapbox CircleAnnotation is
            // pixel-radius, so we approximate as a 64-segment polygon
            // and feed it through the same polygon manager so fill
            // & outline styling stay consistent with hand-drawn polys.
            // Keep them on a separate manager keyed by id so the
            // diff stays clean.
            guard let mapView = mapView else { return }
            let id = "circles"
            // Lazily create a dedicated polygon manager for circles.
            if !circleManagerAttached {
                circlePolygonManager = mapView.annotations.makePolygonAnnotationManager(id: id)
                circleManagerAttached = true
            }
            var sigHasher = Hasher()
            for c in parent.drawingStore.circles {
                sigHasher.combine(c.id); sigHasher.combine(c.color.rawValue)
                sigHasher.combine(c.center.latitude); sigHasher.combine(c.center.longitude)
                sigHasher.combine(c.radius)
            }
            guard shouldPublish(layer: "drawingCircles", signature: sigHasher.finalize()) else { return }
            var fresh: [PolygonAnnotation] = []
            for c in parent.drawingStore.circles {
                let coords = Self.circleCoordinates(center: c.center, radiusMeters: c.radius, segments: 64)
                let ring = Ring(coordinates: coords)
                let polygon = Polygon(outerRing: ring)
                var ann = PolygonAnnotation(id: "dc-\(c.id.uuidString)", polygon: polygon)
                ann.fillColor = StyleColor(c.color.uiColor.withAlphaComponent(0.2))
                ann.fillOutlineColor = StyleColor(c.color.uiColor)
                fresh.append(ann)
            }
            circlePolygonManager?.annotations = fresh
        }

        private var circleManagerAttached = false
        private var circlePolygonManager: PolygonAnnotationManager?

        /// Approximate a great-circle ring of `radiusMeters` around
        /// `center` as a polygon. Latitude scaling accounts for
        /// longitude convergence near the poles so the visual stays
        /// circular at high latitudes.
        private static func circleCoordinates(center: CLLocationCoordinate2D, radiusMeters: Double, segments: Int) -> [CLLocationCoordinate2D] {
            let earthRadius = 6_378_137.0
            let lat = center.latitude * .pi / 180
            let lon = center.longitude * .pi / 180
            let d = radiusMeters / earthRadius
            var coords: [CLLocationCoordinate2D] = []
            coords.reserveCapacity(segments + 1)
            for i in 0...segments {
                let bearing = Double(i) / Double(segments) * 2 * .pi
                let lat2 = asin(sin(lat) * cos(d) + cos(lat) * sin(d) * cos(bearing))
                let lon2 = lon + atan2(
                    sin(bearing) * sin(d) * cos(lat),
                    cos(d) - sin(lat) * sin(lat2)
                )
                coords.append(CLLocationCoordinate2D(
                    latitude: lat2 * 180 / .pi,
                    longitude: lon2 * 180 / .pi
                ))
            }
            return coords
        }

        // MARK: - Drawing temp overlay (in-progress)

        private func refreshDrawingTempOverlay() {
            guard let lineManager = ensureLine(\.drawingTempLineManager) else { return }
            let dm = parent.drawingManager

            // Bug #3: dedup so the in-progress shape only repaints when the
            // user adds/removes a point, not on every camera tick. Otherwise
            // the temp vertices visibly flicker during pan/zoom.
            var sigHasher = Hasher()
            sigHasher.combine("drawingTemp")
            sigHasher.combine(dm.isDrawingActive)
            if dm.isDrawingActive {
                for c in dm.getTemporaryAnnotations().map({ $0.coordinate }) {
                    sigHasher.combine(c.latitude); sigHasher.combine(c.longitude)
                }
            }
            guard shouldPublish(layer: "drawingTemp", signature: sigHasher.finalize()) else { return }

            var lines: [PolylineAnnotation] = []
            var verts: [PointAnnotation] = []

            if dm.isDrawingActive {
                let temps = dm.getTemporaryAnnotations().map { $0.coordinate }
                if temps.count >= 2 {
                    // Mapbox v11 PolylineAnnotation does not expose dash
                    // patterns at the annotation level (those live on the
                    // LineLayer). The temp overlay is short-lived enough
                    // that a solid blue line reads fine; if we want dashes
                    // we'll promote this to a LineLayer + GeoJSONSource.
                    var p = PolylineAnnotation(id: "dtemp-line", lineCoordinates: temps)
                    p.lineColor = StyleColor(.systemBlue)
                    p.lineWidth = 2
                    lines.append(p)
                }
                for (i, c) in temps.enumerated() {
                    var ann = PointAnnotation(id: "dtemp-v\(i)", coordinate: c)
                    ann.image = .init(image: Self.tempVertexImage, name: "temp-vertex")
                    ann.iconAnchor = .center
                    verts.append(ann)
                }
            }
            lineManager.annotations = lines
            // Reuse drawingLabelManager? No — use a dedicated vertex
            // manager so labels and temp dots don't fight for the same
            // text/icon configuration.
            ensureTempVertexManager()?.annotations = verts
        }

        private var tempVertexManager: PointAnnotationManager?
        private func ensureTempVertexManager() -> PointAnnotationManager? {
            if let m = tempVertexManager { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePointAnnotationManager(id: "temp-vertices")
            tempVertexManager = m
            return m
        }

        private static let tempVertexImage: UIImage = {
            let size = CGSize(width: 20, height: 20)
            let r = UIGraphicsImageRenderer(size: size)
            return r.image { _ in
                UIColor(red: 1.0, green: 252/255, blue: 0, alpha: 1).setFill()
                let p = UIBezierPath(ovalIn: CGRect(origin: .zero, size: size))
                p.fill()
                UIColor.white.setStroke()
                p.lineWidth = 3
                p.stroke()
                UIColor.black.setFill()
                UIBezierPath(ovalIn: CGRect(x: size.width / 2 - 2, y: size.height / 2 - 2, width: 4, height: 4)).fill()
            }
        }()

        // MARK: - Measurement overlay

        private func refreshMeasurementOverlay() {
            guard let lineManager = ensureLine(\.measurementLineManager) else { return }
            let mm = parent.measurementManager

            // Bug #3: dedup so yellow waypoints + range rings only repaint
            // when the underlying measurement changes, not on every camera
            // tick. Without this the static temp-vertex image re-uploads
            // every frame and the operator sees yellow flicker.
            var sigHasher = Hasher()
            sigHasher.combine("measurement")
            sigHasher.combine(mm.isActive)
            if mm.isActive {
                for c in mm.getTemporaryAnnotations().map({ $0.coordinate }) {
                    sigHasher.combine(c.latitude); sigHasher.combine(c.longitude)
                }
            }
            for ring in mm.rangeRings {
                sigHasher.combine(ring.center.latitude); sigHasher.combine(ring.center.longitude)
                sigHasher.combine(ring.radiusMeters); sigHasher.combine(ring.isVisible)
            }
            guard shouldPublish(layer: "measurement", signature: sigHasher.finalize()) else { return }

            var lines: [PolylineAnnotation] = []
            var rings: [PolygonAnnotation] = []
            var verts: [PointAnnotation] = []

            if mm.isActive {
                let verticesIn = mm.getTemporaryAnnotations().map { $0.coordinate }
                if verticesIn.count >= 2 {
                    var p = PolylineAnnotation(id: "meas-line", lineCoordinates: verticesIn)
                    p.lineColor = StyleColor(.systemYellow)
                    p.lineWidth = 3
                    lines.append(p)
                }
                for (i, c) in verticesIn.enumerated() {
                    var ann = PointAnnotation(id: "meas-v\(i)", coordinate: c)
                    ann.image = .init(image: Self.tempVertexImage, name: "temp-vertex")
                    ann.iconAnchor = .center
                    verts.append(ann)
                }
            }

            // Range rings — meter-radius circles approximated as
            // polygons so they scale with map zoom.
            for ring in mm.rangeRings {
                let coords = Self.circleCoordinates(center: ring.center, radiusMeters: ring.radiusMeters, segments: 64)
                let polygon = Polygon(outerRing: Ring(coordinates: coords))
                var p = PolygonAnnotation(id: "rangering-\(ring.center.latitude)-\(ring.center.longitude)-\(ring.radiusMeters)", polygon: polygon)
                p.fillColor = StyleColor(UIColor.systemOrange.withAlphaComponent(0.1))
                p.fillOutlineColor = StyleColor(UIColor.systemOrange)
                rings.append(p)
            }

            lineManager.annotations = lines
            ensureMeasurementVertexManager()?.annotations = verts
            ensureRangeRingManager()?.annotations = rings
        }

        private func ensureMeasurementVertexManager() -> PointAnnotationManager? {
            if let m = measurementVertexManager { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePointAnnotationManager(id: "meas-vertices")
            measurementVertexManager = m
            return m
        }

        // MARK: - Vertex-edit handles (issue #84)

        /// Render draggable handles for the shape under vertex edit (or clear
        /// them when not editing). Every vertex of a line/polygon, the single
        /// point of a marker, or `[center, radiusHandle]` for a circle. Read
        /// live from the store so handles follow the shape as the operator drags.
        private func refreshVertexHandles() {
            let session = parent.drawingVertexEditSession
            guard session.isActive, let id = session.drawingId, let type = session.drawingType else {
                // Not editing — clear handles only if some are still shown, so we
                // don't churn an already-empty manager on every camera tick.
                if vertexHandlesShown {
                    vertexHandleManager?.annotations = []
                    vertexHandlesShown = false
                    annotationSignatures["vertexHandles"] = nil
                }
                return
            }
            guard let manager = ensureVertexHandleManager() else { return }
            let handles: [CLLocationCoordinate2D]
            switch type {
            case .marker:
                handles = parent.drawingStore.markers.first(where: { $0.id == id }).map { [$0.coordinate] } ?? []
            case .line:
                handles = parent.drawingStore.lines.first(where: { $0.id == id })?.coordinates ?? []
            case .polygon:
                handles = parent.drawingStore.polygons.first(where: { $0.id == id })?.coordinates ?? []
            case .circle:
                guard let c = parent.drawingStore.circles.first(where: { $0.id == id }) else { handles = []; break }
                handles = [c.center, c.radiusHandleCoordinate]
            }
            // Dedup vs camera ticks: only re-publish when the handle set changes.
            var sigHasher = Hasher()
            sigHasher.combine("vertexHandles"); sigHasher.combine(id)
            for h in handles { sigHasher.combine(h.latitude); sigHasher.combine(h.longitude) }
            guard shouldPublish(layer: "vertexHandles", signature: sigHasher.finalize()) else { return }
            manager.annotations = handles.enumerated().map { (i, c) in
                var ann = PointAnnotation(id: "vh-\(i)", coordinate: c)
                ann.image = .init(image: Self.tempVertexImage, name: "temp-vertex")
                ann.iconAnchor = .center
                return ann
            }
            vertexHandlesShown = true
        }

        /// Whether vertex handles are currently displayed (to avoid clearing an
        /// already-empty manager every camera tick once editing ends).
        private var vertexHandlesShown = false

        private func ensureVertexHandleManager() -> PointAnnotationManager? {
            if let m = vertexHandleManager { return m }
            guard let mapView = mapView else { return nil }
            // Make this the topmost annotation manager so handles sit above the
            // shape outlines the operator is editing.
            let m = mapView.annotations.makePointAnnotationManager(id: "vertex-handles")
            vertexHandleManager = m
            return m
        }
        private func ensureRangeRingManager() -> PolygonAnnotationManager? {
            if let m = rangeRingManager { return m }
            guard let mapView = mapView else { return nil }
            let m = mapView.annotations.makePolygonAnnotationManager(id: "range-rings")
            rangeRingManager = m
            return m
        }

        // MARK: - Range & Bearing

        private func refreshRangeBearing() {
            guard let lineManager = ensureLine(\.rangeBearingLineManager) else { return }
            guard parent.overlayCoordinator.rangeBearingEnabled else {
                lineManager.annotations = []
                rangeBearingLabelManager?.annotations = []
                return
            }
            let service = RangeBearingService.shared
            var lines: [PolylineAnnotation] = []
            var labels: [PointAnnotation] = []

            for line in service.lines {
                var p = PolylineAnnotation(id: "rb-\(line.id)", lineCoordinates: [line.origin, line.destination])
                p.lineColor = StyleColor(.systemOrange)
                p.lineWidth = service.configuration.lineWidth
                lines.append(p)

                let mid = Self.midpoint(line.origin, line.destination)
                var label = PointAnnotation(id: "rb-lbl-\(line.id)", coordinate: mid)
                let distance = service.formatDistance(line.distanceMeters)
                let bearing: String
                switch service.configuration.bearingType {
                case .magnetic: bearing = "\(service.formatBearing(line.magneticBearing))M"
                case .true:     bearing = "\(service.formatBearing(line.trueBearing))T"
                case .grid:     bearing = "\(service.formatBearing(line.gridBearing))G"
                }
                label.textField = "\(distance) / \(bearing)"
                label.textColor = StyleColor(.white)
                label.textHaloColor = StyleColor(.black)
                label.textHaloWidth = 1.5
                label.textSize = 11
                labels.append(label)
            }
            lineManager.annotations = lines
            if rangeBearingLabelManager == nil, let mapView = mapView {
                rangeBearingLabelManager = mapView.annotations.makePointAnnotationManager(id: "rb-labels")
            }
            rangeBearingLabelManager?.annotations = labels
        }

        private static func midpoint(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        }

        // MARK: - Breadcrumb trail

        private func refreshBreadcrumbTrail() {
            guard let manager = ensureLine(\.breadcrumbLineManager) else { return }
            guard parent.overlayCoordinator.breadcrumbTrailsEnabled else {
                manager.annotations = []
                return
            }
            let service = BreadcrumbTrailService.shared
            let coords = service.trailCoordinates
            guard coords.count >= 2 else { manager.annotations = []; return }
            let teamColorStr = PositionBroadcastService.shared.teamColor
            let color = UIColor(hexString: teamColorStr) ?? UIColor.green
            var p = PolylineAnnotation(id: "breadcrumb", lineCoordinates: coords)
            p.lineColor = StyleColor(color)
            p.lineWidth = service.configuration.lineWidth
            manager.annotations = [p]
        }

        // MARK: - Lasso highlight rings (selected markers)

        private func refreshLassoHighlightRings() {
            guard let manager = ensurePolygon(\.lassoSelectionRingManager) else { return }
            let sel = parent.lassoService.current
            guard !sel.isEmpty else { manager.annotations = []; return }
            var rings: [PolygonAnnotation] = []
            func addRing(at coord: CLLocationCoordinate2D, id: String) {
                let coords = Self.circleCoordinates(center: coord, radiusMeters: 40, segments: 32)
                let polygon = Polygon(outerRing: Ring(coordinates: coords))
                var ring = PolygonAnnotation(id: "ring-\(id)", polygon: polygon)
                ring.fillColor = StyleColor(UIColor.systemOrange.withAlphaComponent(0.12))
                ring.fillOutlineColor = StyleColor(UIColor.systemOrange)
                rings.append(ring)
            }
            for cot in parent.markers where sel.markerIDs.contains(cot.uid) {
                addRing(at: cot.coordinate, id: "cot-\(cot.uid)")
            }
            for pt in parent.pointMarkers where sel.markerIDs.contains(pt.id.uuidString) {
                addRing(at: pt.coordinate, id: "pt-\(pt.id.uuidString)")
            }
            for m in parent.drawingStore.markers where sel.markerIDs.contains(m.id.uuidString) {
                addRing(at: m.coordinate, id: "dm-\(m.id.uuidString)")
            }
            manager.annotations = rings
        }

        // MARK: - Tap gesture (contact hit-test, then map tap)

        @objc func handleMapTap(_ gesture: UITapGestureRecognizer) {
            guard let mapView = mapView else { return }
            let point = gesture.location(in: mapView)
            let coordinate = mapView.mapboxMap.coordinate(for: point)

            // Issue #65 — tap the self-position puck to open the manual
            // position edit sheet. The puck center is the GPS coordinate
            // projected to screen; we use a 28pt hit radius (larger than
            // the smallest puck image so it's easy to tap).
            if !parent.drawingManager.isDrawingActive && !parent.measurementManager.isActive {
                if let gpsCoord = mapView.location.latestLocation?.coordinate {
                    let puckScreenPoint = mapView.mapboxMap.point(for: gpsCoord)
                    let dx = point.x - puckScreenPoint.x
                    let dy = point.y - puckScreenPoint.y
                    if sqrt(dx * dx + dy * dy) < 28 {
                        NotificationCenter.default.post(name: .selfMarkerTapped, object: nil)
                        return
                    }
                }
            }

            // Bug #1: tap (not just long-press) on a marker / shape body or
            // its floating name label should open the radial context menu.
            // Only when no drawing/measurement tool is active — otherwise the
            // tap must reach the tool for placement.
            if !parent.drawingManager.isDrawingActive && !parent.measurementManager.isActive {
                if let pm = nearestPointMarker(to: point, in: mapView) {
                    parent.radialMenuCoordinator.showPointMarkerMenu(at: point, coordinate: coordinate, marker: pm)
                    return
                }
                if let dm = nearestDrawingMarker(to: point, in: mapView) {
                    parent.radialMenuCoordinator.showContextMenu(at: point, for: coordinate, menuType: .markerContext, drawingId: dm.id, drawingType: .marker)
                    return
                }
                if let hit = drawingShapeHit(at: coordinate) ?? drawingShapeLabelHit(at: point, in: mapView) {
                    parent.radialMenuCoordinator.showContextMenu(at: point, for: coordinate, menuType: .markerContext, drawingId: hit.id, drawingType: hit.type)
                    return
                }
            }

            parent.onMapTap(coordinate)
        }

        // MARK: - Long-press → radial menu

        /// Map the long-press to the right radial-menu surface:
        /// point markers, drawing shapes, or empty-map context. We do
        /// the hit-test ourselves against the model data (cheaper and
        /// more reliable than projecting every annotation through
        /// `mapboxMap.point(for:)` for each press).
        @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let mapView = mapView else { return }
            let screenPoint = gesture.location(in: mapView)
            let coordinate = mapView.mapboxMap.coordinate(for: screenPoint)

            // 1) Point markers
            if let pm = nearestPointMarker(to: screenPoint, in: mapView) {
                parent.radialMenuCoordinator.showPointMarkerMenu(
                    at: screenPoint,
                    coordinate: coordinate,
                    marker: pm
                )
                return
            }

            // 2) Drawing markers
            if let dm = nearestDrawingMarker(to: screenPoint, in: mapView) {
                parent.radialMenuCoordinator.showContextMenu(
                    at: screenPoint,
                    for: coordinate,
                    menuType: .markerContext,
                    drawingId: dm.id,
                    drawingType: .marker
                )
                return
            }

            // 3) Drawing shapes (lines, polygons, circles) — geometry
            // hit first, then label rect (so the floating centroid /
            // midpoint name label is also a valid selection target).
            if let hit = drawingShapeHit(at: coordinate)
                ?? drawingShapeLabelHit(at: screenPoint, in: mapView) {
                parent.radialMenuCoordinator.showContextMenu(
                    at: screenPoint,
                    for: coordinate,
                    menuType: .markerContext,
                    drawingId: hit.id,
                    drawingType: hit.type
                )
                return
            }

            // 4) Empty map
            parent.radialMenuCoordinator.showContextMenu(
                at: screenPoint,
                for: coordinate,
                menuType: .mapContext
            )
        }

        private func nearestPointMarker(to screenPoint: CGPoint, in mapView: MapView) -> PointMarker? {
            let radius: CGFloat = 44
            var best: (PointMarker, CGFloat)?
            for pm in parent.pointMarkers {
                let p = mapView.mapboxMap.point(for: pm.coordinate)
                let dIcon = hypot(p.x - screenPoint.x, p.y - screenPoint.y)
                // Label hit-region — refreshPointMarkers anchors the
                // text at `.top` with `textOffset = [0, 1.2]` em (≈16px
                // at textSize 11). Approximate the label rect above
                // the icon so long-press on the name resolves the same
                // marker the icon would. Without this the floating
                // text label is dead — only the dot itself reacts.
                let labelCenter = CGPoint(x: p.x, y: p.y + 18)
                let nameWidth = max(40, min(180, CGFloat(pm.name.count) * 7))
                let labelRect = CGRect(x: labelCenter.x - nameWidth / 2,
                                       y: labelCenter.y - 10,
                                       width: nameWidth,
                                       height: 20).insetBy(dx: -8, dy: -6)
                let dLabel: CGFloat = labelRect.contains(screenPoint) ? 0 : .greatestFiniteMagnitude
                let d = min(dIcon, dLabel)
                if d < radius, best == nil || d < best!.1 {
                    best = (pm, d)
                }
            }
            return best?.0
        }

        private func nearestDrawingMarker(to screenPoint: CGPoint, in mapView: MapView) -> MarkerDrawing? {
            let radius: CGFloat = 44
            var best: (MarkerDrawing, CGFloat)?
            for m in parent.drawingStore.markers {
                let p = mapView.mapboxMap.point(for: m.coordinate)
                let d = hypot(p.x - screenPoint.x, p.y - screenPoint.y)
                if d < radius, best == nil || d < best!.1 {
                    best = (m, d)
                }
            }
            return best?.0
        }

        private struct DrawingShapeHit { let id: UUID; let type: RadialMenuContext.DrawingType }

        private func drawingShapeHit(at coordinate: CLLocationCoordinate2D) -> DrawingShapeHit? {
            // Circles — radial distance check is the cheapest.
            for c in parent.drawingStore.circles {
                let d = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    .distance(from: CLLocation(latitude: c.center.latitude, longitude: c.center.longitude))
                if d <= c.radius {
                    return DrawingShapeHit(id: c.id, type: .circle)
                }
            }
            // Polygons — ray casting in lat/lon space (cheap enough at
            // typical hit-test scales; we're not trying to win the
            // GIS olympics here).
            for poly in parent.drawingStore.polygons {
                if Self.pointInPolygon(point: coordinate, polygon: poly.coordinates) {
                    return DrawingShapeHit(id: poly.id, type: .polygon)
                }
            }
            // Lines — sample-based proximity. Tolerance scales with
            // zoom indirectly via meters-per-pixel; 30m at world
            // scale is generous, fine at tactical scale.
            let tolerance: CLLocationDistance = 30
            for line in parent.drawingStore.lines where line.coordinates.count >= 2 {
                for i in 0..<(line.coordinates.count - 1) {
                    if Self.distance(from: coordinate, toSegmentFrom: line.coordinates[i], to: line.coordinates[i + 1]) <= tolerance {
                        return DrawingShapeHit(id: line.id, type: .line)
                    }
                }
            }
            return nil
        }

        /// Screen-space hit-test against the floating drawing labels
        /// (circle center, polygon centroid, line midpoint). Mirrors
        /// the positions emitted by `refreshDrawingLabels` so a
        /// long-press on the name text resolves the underlying shape
        /// even when the shape itself is small or far from the label.
        private func drawingShapeLabelHit(at screenPoint: CGPoint, in mapView: MapView) -> DrawingShapeHit? {
            func labelRect(at coord: CLLocationCoordinate2D, textLength: Int) -> CGRect {
                let p = mapView.mapboxMap.point(for: coord)
                let w = max(40, min(180, CGFloat(textLength) * 7))
                return CGRect(x: p.x - w / 2, y: p.y - 10, width: w, height: 20).insetBy(dx: -8, dy: -6)
            }
            for c in parent.drawingStore.circles {
                if labelRect(at: c.center, textLength: c.label.count).contains(screenPoint) {
                    return DrawingShapeHit(id: c.id, type: .circle)
                }
            }
            for p in parent.drawingStore.polygons {
                if let centroid = Self.centroid(of: p.coordinates),
                   labelRect(at: centroid, textLength: p.label.count).contains(screenPoint) {
                    return DrawingShapeHit(id: p.id, type: .polygon)
                }
            }
            for l in parent.drawingStore.lines where l.coordinates.count >= 2 {
                let mid = l.coordinates[l.coordinates.count / 2]
                if labelRect(at: mid, textLength: l.label.count).contains(screenPoint) {
                    return DrawingShapeHit(id: l.id, type: .line)
                }
            }
            return nil
        }

        private static func pointInPolygon(point: CLLocationCoordinate2D, polygon: [CLLocationCoordinate2D]) -> Bool {
            guard polygon.count >= 3 else { return false }
            var inside = false
            var j = polygon.count - 1
            for i in 0..<polygon.count {
                let pi = polygon[i], pj = polygon[j]
                if ((pi.latitude > point.latitude) != (pj.latitude > point.latitude)) &&
                   (point.longitude < (pj.longitude - pi.longitude) *
                    (point.latitude - pi.latitude) /
                    (pj.latitude - pi.latitude) + pi.longitude) {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }

        private static func distance(from point: CLLocationCoordinate2D,
                                     toSegmentFrom a: CLLocationCoordinate2D,
                                     to b: CLLocationCoordinate2D) -> CLLocationDistance {
            let locP = CLLocation(latitude: point.latitude, longitude: point.longitude)
            let locA = CLLocation(latitude: a.latitude, longitude: a.longitude)
            let locB = CLLocation(latitude: b.latitude, longitude: b.longitude)
            let ab = locA.distance(from: locB)
            guard ab > 0 else { return locP.distance(from: locA) }
            // Project P onto AB in flat lat/lon space — good enough
            // at tactical distances.
            let t = max(0, min(1,
                ((point.latitude - a.latitude) * (b.latitude - a.latitude) +
                 (point.longitude - a.longitude) * (b.longitude - a.longitude)) /
                (pow(b.latitude - a.latitude, 2) + pow(b.longitude - a.longitude, 2))
            ))
            let closest = CLLocationCoordinate2D(
                latitude: a.latitude + t * (b.latitude - a.latitude),
                longitude: a.longitude + t * (b.longitude - a.longitude)
            )
            return locP.distance(from: CLLocation(latitude: closest.latitude, longitude: closest.longitude))
        }

        // MARK: - Lasso gesture (issue #16)

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === lassoGesture { return false }
            return false
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === lassoGesture {
                return parent.drawingManager.isDrawingActive &&
                       parent.drawingManager.currentMode == .lasso
            }
            // Issue #60 — the reposition pan only begins while a move session is
            // active; otherwise it stands down so normal pan/tap work.
            if gestureRecognizer === movePanGesture {
                return parent.drawingMoveSession.isActive
            }
            // Issue #84 — the vertex-edit pan only begins while a vertex-edit
            // session is active; otherwise it stands down.
            if gestureRecognizer === vertexEditPanGesture {
                return parent.drawingVertexEditSession.isActive
            }
            return true
        }

        @objc func handleLassoGesture(_ gesture: UILongPressGestureRecognizer) {
            guard let mapView = mapView else { return }
            let service = parent.lassoService
            switch gesture.state {
            case .began:
                let point = gesture.location(in: mapView)
                let coord = mapView.mapboxMap.coordinate(for: point)
                service.beginLasso()
                service.appendVertex(coord)
                installLassoOverlay(on: mapView, firstPoint: point)
            case .changed:
                let point = gesture.location(in: mapView)
                let coord = mapView.mapboxMap.coordinate(for: point)
                service.appendVertex(coord)
                refreshLassoOverlay(on: mapView, point: point)
            case .ended, .cancelled, .failed:
                let markers: [LassoMarker] =
                    parent.markers.map(LassoMarker.init(cot:)) +
                    parent.pointMarkers.map(LassoMarker.init(point:)) +
                    parent.drawingStore.markers.map(LassoMarker.init(marker:))
                let drawings: [LassoDrawing] =
                    parent.drawingStore.lines.map { LassoDrawing(id: $0.id, coordinates: $0.coordinates) } +
                    parent.drawingStore.polygons.map { LassoDrawing(id: $0.id, coordinates: $0.coordinates) } +
                    parent.drawingStore.circles.map { LassoDrawing(id: $0.id, coordinates: [$0.center]) }
                _ = service.endLasso(markers: markers, drawings: drawings)
                removeLassoOverlay(on: mapView)
                parent.drawingManager.cancelDrawing()
            default:
                break
            }
        }

        // MARK: - Drawing move gesture (issue #60 — move/reposition follow-up)

        /// Single-finger drag in reposition mode → rigidly translate the
        /// selected shape. We convert the previous and current screen points to
        /// map coordinates and forward the (latΔ, lonΔ) to the parent, which
        /// updates the store live. Using a coordinate delta (rather than a fixed
        /// metres-per-pixel) keeps the shape under the finger at any zoom/pitch.
        @objc func handleMovePanGesture(_ gesture: UIPanGestureRecognizer) {
            guard let mapView = mapView, parent.drawingMoveSession.isActive else { return }
            let point = gesture.location(in: mapView)
            switch gesture.state {
            case .began:
                lastMovePanPoint = point
            case .changed:
                guard let last = lastMovePanPoint else { lastMovePanPoint = point; return }
                let fromCoord = mapView.mapboxMap.coordinate(for: last)
                let toCoord = mapView.mapboxMap.coordinate(for: point)
                let latDelta = toCoord.latitude - fromCoord.latitude
                let lonDelta = toCoord.longitude - fromCoord.longitude
                if latDelta != 0 || lonDelta != 0 {
                    parent.onDrawingMoveDragged?(latDelta, lonDelta)
                }
                lastMovePanPoint = point
            case .ended, .cancelled, .failed:
                lastMovePanPoint = nil
            default:
                break
            }
        }

        // MARK: - Drawing vertex-edit gesture (issue #84)

        /// Single-finger drag in vertex-edit mode → move one vertex. On
        /// touch-down we forward the touched map coordinate so the parent
        /// hit-tests the nearest handle and grabs it; each frame we forward the
        /// dragged coordinate so the parent sets that vertex to it (the parent
        /// owns the geometry so both engines share the same logic). Using the
        /// absolute coordinate under the finger keeps the vertex pinned to the
        /// touch at any zoom/pitch.
        @objc func handleVertexEditPanGesture(_ gesture: UIPanGestureRecognizer) {
            guard let mapView = mapView, parent.drawingVertexEditSession.isActive else { return }
            let point = gesture.location(in: mapView)
            let coord = mapView.mapboxMap.coordinate(for: point)
            switch gesture.state {
            case .began:
                parent.onVertexDragBegan?(coord)
                parent.onVertexDragMoved?(coord)
            case .changed:
                parent.onVertexDragMoved?(coord)
            case .ended, .cancelled, .failed:
                parent.onVertexDragEnded?()
            default:
                break
            }
        }

        private func installLassoOverlay(on mapView: MapView, firstPoint: CGPoint) {
            removeLassoOverlay(on: mapView)
            let layer = CAShapeLayer()
            layer.frame = mapView.bounds
            layer.strokeColor = UIColor.systemOrange.cgColor
            layer.fillColor = UIColor.systemOrange.withAlphaComponent(0.05).cgColor
            layer.lineWidth = 3
            layer.lineDashPattern = [6, 4]
            layer.lineJoin = .round
            layer.lineCap = .round
            mapView.layer.addSublayer(layer)
            lassoPathLayer = layer
            lassoViewPoints = [firstPoint]
            updateLassoLayerPath()
        }

        private func refreshLassoOverlay(on mapView: MapView, point: CGPoint) {
            lassoViewPoints.append(point)
            updateLassoLayerPath()
        }

        private func updateLassoLayerPath() {
            guard let layer = lassoPathLayer, lassoViewPoints.count >= 2 else { return }
            let path = UIBezierPath()
            path.move(to: lassoViewPoints[0])
            for pt in lassoViewPoints.dropFirst() { path.addLine(to: pt) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.path = path.cgPath
            CATransaction.commit()
        }

        private func removeLassoOverlay(on mapView: MapView) {
            lassoPathLayer?.removeFromSuperlayer()
            lassoPathLayer = nil
            lassoViewPoints = []
        }
    }
}

// MARK: - Radial menu Mapbox bridge
//
// Decouple the radial-menu coordinator from MKMapView so the Mapbox
// `TacticalMapView` can drive it without smuggling in an MKMapView
// reference. Mirrors the same context-building logic as the legacy
// `handleLongPress(at:on:)` path.

extension RadialMenuMapCoordinator {
    /// Show the point-marker radial menu using a coordinate already
    /// resolved by the Mapbox layer. Bypasses the MKMapView
    /// hit-test path that the legacy MapKit map relied on.
    func showPointMarkerMenu(at screenPoint: CGPoint,
                              coordinate: CLLocationCoordinate2D,
                              marker: PointMarker) {
        guard isRadialMenuEnabled else { return }

        // Build a synthetic annotation-bearing context so downstream
        // handlers (executeAction, highlightedItemIndex, etc.) see the
        // same shape they always have.
        let annotation = PointMarkerAnnotation(marker: marker)
        let context = RadialMenuContext(
            screenPoint: screenPoint,
            mapCoordinate: coordinate,
            pressedAnnotation: annotation,
            pressedMarker: marker,
            pressedWaypoint: nil,
            pressedDrawingId: nil,
            pressedDrawingType: nil,
            contextType: .pointMarker
        )
        menuConfiguration = .markerContextMenu(for: marker).filteringDisabledPlugins()
        currentContext = context
        menuCenterPoint = adjustMenuPositionForMapbox(screenPoint, menuRadius: menuConfiguration.radius)
        RadialMenuHaptic.menuAppear.trigger()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            showRadialMenu = true
        }
        onMenuShown?(context)
    }

    /// Local copy of the private `adjustMenuPosition` used by the
    /// legacy `handleLongPress(at:on:)` path. Mirrors the screen-edge
    /// avoidance behaviour without exposing it as part of the public
    /// API of the original coordinator.
    private func adjustMenuPositionForMapbox(_ point: CGPoint, menuRadius: CGFloat) -> CGPoint {
        let screenBounds = UIScreen.main.bounds
        let padding: CGFloat = 20.0
        let requiredSpace = menuRadius + padding
        var p = point
        if p.x < requiredSpace { p.x = requiredSpace }
        else if p.x > screenBounds.width - requiredSpace { p.x = screenBounds.width - requiredSpace }
        if p.y < requiredSpace + 100 { p.y = requiredSpace + 100 }
        else if p.y > screenBounds.height - requiredSpace - 100 { p.y = screenBounds.height - requiredSpace - 100 }
        return p
    }
}
