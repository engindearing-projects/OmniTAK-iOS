import SwiftUI
import MapKit
import CoreLocation
import MapboxMaps
import UIKit
import WebKit

// MARK: - Map engine selection

/// Which engine renders the Map tab. Cesium 3D is the default first-class
/// experience (photoreal terrain + atmosphere + true-altitude entities once
/// the Phase 2 bridge lands). Mapbox 2D stays available as an offline /
/// low-bandwidth / older-device fallback.
enum MapEngine: String, CaseIterable, Identifiable, Codable {
    case cesium3D = "cesium_3d"
    case mapbox2D = "mapbox_2d"
    var id: String { rawValue }
    var displayName: String { self == .cesium3D ? "3D Globe" : "2D Map" }
    var icon: String { self == .cesium3D ? "globe.americas.fill" : "map.fill" }
}

// ATAK-style Map View with tactical interface
struct ATAKMapView: View {
    @ObservedObject private var takService = TAKService.shared
    @StateObject private var locationManager = LocationManager()
    @StateObject private var drawingStore: DrawingStore
    @StateObject private var drawingManager: DrawingToolsManager
    @StateObject private var radialMenuCoordinator = RadialMenuMapCoordinator()
    @ObservedObject private var chatManager = ChatManager.shared
    @StateObject private var trackRecordingService = TrackRecordingService()
    @StateObject private var overlayCoordinator = MapOverlayCoordinator()
    @StateObject private var routeOverlayCoordinator = RouteOverlayCoordinator()
    @ObservedObject private var routeService = RoutePlanningService.shared
    @StateObject private var mapStateManager = MapStateManager()
    @StateObject private var measurementManager = MeasurementManager()
    @ObservedObject private var adsbService = ADSBTrafficService.shared
    // Plugin SDK — registered map overlays render in the engine-agnostic
    // chrome (see `registeredPluginOverlays`), so they appear on BOTH engines.
    @ObservedObject private var pluginHost = AppPluginHost.shared
    @ObservedObject private var pointDropperService = PointDropperService.shared
    @ObservedObject private var serverManager = ServerManager.shared
    // Issue #16 — lasso multi-select. Singleton so the pill, ring
    // renderers, and gesture coordinator all see the same state.
    @ObservedObject private var lassoService = LassoSelectionService.shared
    // Issue #16 — confirmation dialog for the lasso selection actions
    // (Add to Data Package / Export KML / Send to Contacts / Bulk
    // Delete / Clear). Driven from `lassoSelectionPill`.
    @State private var showLassoActions = false
    @State private var lassoActionNotice: String?
    @State private var lassoExportShareItem: URL?
    @State private var showLassoContactPicker = false
    // Issue #16 — Tools tab in the bottom bar opens a short popup
    // (handled in RootTabView). MapViewController only needs to
    // observe the notifications it posts: .startLassoMode +
    // .showFullTools. No local launcher state required here.

    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365), // Default: DC
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var showServerConfig = false
    @State private var showLayersPanel = false
    @State private var showDrawingPanel = false
    @State private var showDrawingList = false
    // Radial menu → Edit on a PointMarker posts .radialMenuEditMarker;
    // we hold the marker id here so a sheet can open the edit form.
    @State private var editingPointMarkerID: UUID?
    @State private var mapType: MKMapType = .standard
    @State private var showToolsMenu = false
    @State private var showLoadingScreen = true
    @State private var showGPSError = false
    @State private var showGeofenceAlert = false
    @State private var showTraffic = false
    @State private var trackingMode: MapUserTrackingMode = .none
    @State private var orientation = UIDeviceOrientation.unknown

    // Map engine selection — Cesium 3D is the default first-class experience;
    // Mapbox 2D stays available as an offline / low-bandwidth fallback. The
    // operator can flip between them via the engineToggleFAB in the map's
    // bottom-left corner or from Settings.
    @AppStorage("mapEngine") private var mapEngineRaw: String = MapEngine.cesium3D.rawValue
    private var mapEngine: MapEngine { MapEngine(rawValue: mapEngineRaw) ?? .cesium3D }
    @ObservedObject private var pointDropAim = PointDropUIState.shared
    // (userCallsign is already declared further down; we reference it from
    // cesiumEngineView for the self-position label.)

    // Feature screen states
    @State private var showTeamManagement = false
    @State private var showRoutePlanning = false
    @State private var showGeofences = false
    @State private var showTrackRecording = false
    @State private var showChat = false
    @State private var showContacts = false
    @State private var showEmergencySOS = false
    @State private var showSettings = false
    @State private var showPlugins = false
    @State private var showAbout = false
    @State private var showPositionBroadcast = false
    @State private var showElevationProfile = false

    // User settings
    @AppStorage("userCallsign") private var userCallsign = "ALPHA-1"
    // Self-position marker style (Settings → "Self-position marker").
    // "milstd" = MIL-STD-2525 friendly-combat frame, "bullseye" = legacy
    // tactical bullseye. Consumed by both engines: the Mapbox puck image
    // and the Cesium self-pip billboard.
    @AppStorage("selfMarkerStyle") private var selfMarkerStyle = "milstd"
    @State private var showLineOfSight = false
    @State private var showEchelonHierarchy = false
    @State private var showMissionSync = false
    @State private var showMeshtastic = false
    @State private var showMeasurement = false
    @State private var showAppModePicker = false

    // Position broadcasting service
    @ObservedObject private var positionBroadcastService = PositionBroadcastService.shared

    // Layer states
    @State private var activeMapLayer = "satellite"
    @State private var showFriendly = true
    @State private var showHostile = true
    @State private var showNeutral = true      // Added: Neutral units (a-n-*)
    @State private var showUnknown = true      // Changed: Default to TRUE - show unknown by default

    // Map overlay states
    @State private var showCompass = false  // Hidden by default for max map space
    @State private var showCoordinates = false  // Hidden by default for max map space
    @State private var showScaleBar = true  // ATAK-style: Enabled by default in bottom-left
    @State private var showGrid = false

    // Issue #72 — north-up lock (persisted so it survives restarts)
    @AppStorage("map_northLocked") private var isNorthLocked: Bool = false
    // Issue #73 — current map bearing in degrees CW from north. Updated by
    // both engines on every camera-change event so the compass overlay always
    // reflects the live map rotation (not just device heading).
    @State private var mapBearing: Double = 0

    // New ATAK-style UI states
    @State private var isCursorModeActive = false
    @State private var showQuickActionToolbar = false  // Hidden - user can access tools via radial menu and ATAK tools menu
    @StateObject private var cursorModeCoordinator = MapCursorModeCoordinator()
    @State private var showRangeBearingLine = false
    @State private var showRouteHere = false
    @State private var showOverlaySettings = false
    @State private var showBreadcrumbTrails = false
    @State private var showRBLines = false
    @State private var showCallsignPanel = true  // ATAK-style: Enabled by default in bottom-right
    @State private var isNavigationPanelExpanded = false  // Route navigation panel state

    init() {
        let store = DrawingStore()
        _drawingStore = StateObject(wrappedValue: store)
        _drawingManager = StateObject(wrappedValue: DrawingToolsManager(drawingStore: store))
    }

    // Detect device orientation
    @Environment(\.verticalSizeClass) var verticalSizeClass
    @Environment(\.horizontalSizeClass) var horizontalSizeClass

    var isLandscape: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    // Computed CoT markers from TAK service - filtered by overlay settings
    private var cotMarkers: [CoTMarker] {
        takService.cotEvents.compactMap { event in
            // Air-dimension tracks (a-?-A-…, e.g. Remote ID / gyb drones,
            // ADS-B) carry their HAE so the 3D globe floats them at altitude
            // with a TAK leader line; ground units stay clamped (hae nil).
            let typeTokens = event.type.split(separator: "-")
            let isAir = typeTokens.count > 2 && typeTokens[2].lowercased() == "a"
            let marker = CoTMarker(
                uid: event.uid,
                coordinate: CLLocationCoordinate2D(
                    latitude: event.point.lat,
                    longitude: event.point.lon
                ),
                type: event.type,
                callsign: event.detail.callsign,
                team: event.detail.team ?? "Unknown",
                hae: (isAir && event.point.hae > 0) ? event.point.hae : nil,
                // Issue #75 — carry the usericon path + color so spot-map /
                // iconset markers resolve to the right TAK icon on the map.
                iconsetPath: event.detail.iconsetPath,
                argbColor: event.detail.argbColor
            )

            // Filter based on overlay settings and CoT affiliation
            // CoT type format: a-{affiliation}-{dimension}-{function}
            // Affiliations: f=friendly, h=hostile, n=neutral, u=unknown
            //               j=joker (exercise hostile), k=faker (exercise friendly)
            //               s=suspect, a=assumed friendly

            // Determine affiliation from CoT type
            let type = event.type.lowercased()

            if type.hasPrefix("a-f") || type.hasPrefix("a-k") || type.hasPrefix("a-a") {
                // Friendly, Faker (exercise friendly), Assumed Friendly
                if !showFriendly {
                    return nil
                }
            } else if type.hasPrefix("a-h") || type.hasPrefix("a-j") || type.hasPrefix("a-s") {
                // Hostile, Joker (exercise hostile), Suspect
                if !showHostile {
                    return nil
                }
            } else if type.hasPrefix("a-n") {
                // Neutral
                if !showNeutral {
                    return nil
                }
            } else if type.hasPrefix("a-u") {
                // Unknown affiliation
                if !showUnknown {
                    return nil
                }
            } else if type.hasPrefix("a-") {
                // Any other 'a-' type we don't recognize - treat as unknown
                // This ensures we don't accidentally hide valid units
                if !showUnknown {
                    return nil
                }
            }
            // Non 'a-' types (waypoints, markers, etc.) are ALWAYS shown
            // They don't have affiliations and should never be filtered

            return marker
        }
    }

    // MARK: - Computed Properties to Fix Type Checking

    @ViewBuilder
    private var mainMapView: some View {
        TacticalMapView(
            region: $mapRegion,
            mapType: $mapType,
            trackingMode: $trackingMode,
            markers: cotMarkers,
            pointMarkers: pointDropperService.markers,
            aircraft: adsbService.settings.isEnabled ? adsbService.aircraft : [],
            showsUserLocation: true,
            drawingStore: drawingStore,
            drawingManager: drawingManager,
            radialMenuCoordinator: radialMenuCoordinator,
            overlayCoordinator: overlayCoordinator,
            routeOverlayCoordinator: routeOverlayCoordinator,
            mapStateManager: mapStateManager,
            measurementManager: measurementManager,
            lassoService: lassoService,
            onMapTap: handleMapTap,
            // Issue #72 — forward the north-lock flag so TacticalMapView
            // can disable rotation gestures when engaged.
            isNorthLocked: isNorthLocked,
            // Issue #73 — callback so the 2D engine reports its live
            // bearing to the parent for the compass overlay needle.
            onBearingChanged: { bearing in
                mapBearing = bearing
            }
        )
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var gridOverlay: some View {
        // No explicit zIndex — the ZStack child order keeps the grid above
        // the map but below UI chrome (status bar, zoom buttons, panels,
        // which all use zIndex 1000+). A prior zIndex(100) was lifting the
        // grid over the top status bar / zoom controls (#43).
        GridOverlayView(region: mapRegion, isVisible: overlayCoordinator.mgrsGridEnabled)
            .opacity(overlayCoordinator.mgrsGridEnabled ? 1 : 0)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var topToolbars: some View {
        VStack(spacing: 0) {
            ATAKStatusBar(
                connectionStatus: takService.isConnected ? "Connected" : "Disconnected",
                isConnected: takService.isConnected,
                messagesReceived: takService.messagesReceived,
                messagesSent: takService.messagesSent,
                gpsAccuracy: locationManager.accuracy,
                serverName: serverManager.activeServer?.name ?? "Offline",
                serverConnectedFlags: serverManager.servers
                    .filter { $0.enabled }
                    .map { takService.connectedServerIds.contains($0.id) },
                onServerTap: { showServerConfig = true },
                onMenuTap: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showToolsMenu = true
                    }
                }
            )
            // Identity keyed on connection state only. Message counters were
            // in here too, which tore down + rebuilt the whole status-bar
            // subtree on every counter change; they're passed as params and
            // re-render naturally without an identity reset.
            .id("statusbar-\(takService.isConnected)-\(takService.connectedServerIds.count)")

            Spacer()

            bottomToolbars
        }
    }

    @ViewBuilder
    private var bottomToolbars: some View {
        VStack(spacing: 0) {
            ATAKBottomToolbar(
                mapType: $mapType,
                showLayersPanel: $showLayersPanel,
                showDrawingPanel: $showDrawingPanel,
                showDrawingList: $showDrawingList,
                onZoomIn: zoomIn,
                onZoomOut: zoomOut
            )
            .padding(.horizontal, 8)
            .padding(.bottom, isCursorModeActive ? 240 : 140)

            if showQuickActionToolbar && !isCursorModeActive {
                QuickActionToolbar(
                    mapRegion: $mapRegion,
                    showGrid: $showGrid,
                    showLayersPanel: $showLayersPanel,
                    isCursorModeActive: $isCursorModeActive,
                    userLocation: locationManager.location,
                    onDropPoint: { coordinate in
                        dropMarkerAtLocation(coordinate: coordinate, affiliation: .friendly)
                    },
                    onToggleMeasure: {
                        showMeasurement = true
                    },
                    lassoModeActive: drawingManager.currentMode == .lasso,
                    onToggleLasso: {
                        // Issue #16: lasso lives on the quick-action
                        // toolbar now. Single tap toggles in/out — if
                        // we're already in lasso mode (button glowing),
                        // cancel back to idle so the user can re-enter
                        // pan/zoom without making a stray selection.
                        if drawingManager.currentMode == .lasso {
                            drawingManager.cancelDrawing()
                        } else {
                            drawingManager.startDrawing(mode: .lasso)
                        }
                    }
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 15)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private var sidePanels: some View {
        Group {
            layersPanel
            drawingToolsPanel
            drawingListPanel
        }
    }

    @ViewBuilder
    private var layersPanel: some View {
        if showLayersPanel {
            HStack {
                ATAKSidePanel(
                    isExpanded: $showLayersPanel,
                    activeMapLayer: $activeMapLayer,
                    is3D: mapEngine == .cesium3D,
                    showFriendly: $showFriendly,
                    showHostile: $showHostile,
                    showNeutral: $showNeutral,
                    showUnknown: $showUnknown,
                    showCompass: $showCompass,
                    showCoordinates: $showCoordinates,
                    showScaleBar: $showScaleBar,
                    showGrid: $showGrid,
                    showCallsignPanel: $showCallsignPanel,
                    isNorthLocked: $isNorthLocked,
                    adsbService: ADSBTrafficService.shared,
                    onLayerToggle: { layer in
                        toggleLayer(layer)
                    },
                    onOverlayToggle: { overlay in
                        toggleOverlay(overlay)
                    },
                    onMapOverlayToggle: { overlay in
                        toggleMapOverlay(overlay)
                    },
                    onNorthLockToggle: {
                        toggleNorthLock()
                    }
                )
                .background(Color.black.opacity(0.9))
                .cornerRadius(12)
                .padding(.leading, 8)
                .padding(.vertical, isLandscape ? 80 : 120)
                .transition(.move(edge: .leading))

                Spacer()
            }
            .zIndex(1010)
        }
    }

    @ViewBuilder
    private var drawingToolsPanel: some View {
        if showDrawingPanel {
            HStack {
                Spacer()
                DrawingToolsPanel(
                    drawingManager: drawingManager,
                    isVisible: $showDrawingPanel,
                    onComplete: {
                        // Drawing completed
                    },
                    onCancel: {
                        // Drawing cancelled
                    }
                )
                .padding(.trailing, 8)
                .padding(.vertical, isLandscape ? 80 : 120)
                .transition(.move(edge: .trailing))
            }
            .zIndex(1010)
        }
    }

    @ViewBuilder
    private var drawingListPanel: some View {
        if showDrawingList {
            HStack {
                Spacer()
                DrawingListPanel(
                    drawingStore: drawingStore,
                    isVisible: $showDrawingList,
                    onZoomToDrawing: { coordinate, radius in
                        zoomToDrawing(coordinate: coordinate, radius: radius)
                    }
                )
                .padding(.trailing, 8)
                .padding(.vertical, isLandscape ? 80 : 120)
                .transition(.move(edge: .trailing))
            }
            .zIndex(1010)
        }
    }

    @ViewBuilder
    private var statusIndicators: some View {
        Group {
            // GPS status indicator removed - GPS lock button at bottom left serves this purpose
            callsignDisplay
            geofenceAlert
            adsbStatusPill
        }
    }

    @ViewBuilder
    private var adsbStatusPill: some View {
        if adsbService.settings.isEnabled {
            VStack {
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "airplane")
                            .font(.system(size: 11, weight: .semibold))
                        Text("\(adsbService.aircraft.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                    .foregroundColor(Color(hex: "#FFFC00"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.55))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule().stroke(Color(hex: "#FFFC00").opacity(0.4), lineWidth: 1)
                    )
                    .padding(.leading, 16)
                    .padding(.top, 60)
                    Spacer()
                }
                Spacer()
            }
            .allowsHitTesting(false)
            .zIndex(1002)
        }
    }

    @ViewBuilder
    private var callsignDisplay: some View {
        if showCallsignPanel, let location = locationManager.location {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    CallsignDisplay(
                        callsign: userCallsign,
                        coordinates: formatCoordinates(location.coordinate),
                        altitude: formatAltitude(location.altitude),
                        speed: formatSpeed(location.speed),
                        heading: formatHeading(locationManager.heading),
                        accuracy: "+/- \(Int(location.horizontalAccuracy))m",
                        onDismiss: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showCallsignPanel = false
                            }
                        }
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 120)
                }
            }
            .zIndex(1003)
        }
    }

    @ViewBuilder
    private var geofenceAlert: some View {
        if showGeofenceAlert {
            VStack {
                GeofenceAlertNotification(
                    geofenceName: "Circle 1",
                    action: "Entered",
                    callsign: userCallsign,
                    isPresented: $showGeofenceAlert
                )
                .padding(.top, 60)
                Spacer()
            }
            .zIndex(1004)
        }
    }

    @ViewBuilder
    private var mapOverlayComponents: some View {
        Group {
            compassOverlay
            // coordinateDisplay now integrated with GPS button to avoid overlap
            scaleBar
        }
    }

    @ViewBuilder
    private var compassOverlay: some View {
        // CLHeading (magnetometer) is the right source — location.course is
        // the direction of travel and freezes at the last value when the
        // user stops moving (what was causing #44 "always 347°"). Fall back
        // to course only if heading is unavailable (e.g., no magnetometer).
        // Issue #73 — compass is always visible (not gated on showCompass) so
        // the tap-to-north affordance and north-lock badge are always reachable.
        // The showCompass toggle in the layers panel now just controls whether
        // the compass starts visible; the overlay still mounts so the lock
        // indicator is never hidden while north-lock is engaged.
        CompassOverlayView(
            heading: compassHeading,
            isVisible: showCompass || isNorthLocked,
            mapBearing: mapBearing,
            isNorthLocked: isNorthLocked,
            onResetNorth: { resetMapToNorth() }
        )
        .zIndex(1005)
    }

    private var compassHeading: CLLocationDirection? {
        if let heading = locationManager.heading {
            return heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        }
        let course = locationManager.location?.course ?? -1
        return course >= 0 ? course : nil
    }

    @ViewBuilder
    private var coordinateDisplay: some View {
        CoordinateDisplayView(
            coordinate: locationManager.location?.coordinate,
            isVisible: showCoordinates
        )
        .zIndex(1006)
    }

    @ViewBuilder
    private var scaleBar: some View {
        ScaleBarView(
            region: mapRegion,
            isVisible: showScaleBar
        )
        .zIndex(1007)
    }

    // interactiveOverlays was dissolved into the engine-agnostic `mapChrome`
    // (radialMenu, lassoSelectionPill) and the 2D-only conditional in `body`
    // (loadingScreen, cursorModeOverlay).

    // == Issue #16: lasso selection pill BEGIN ==
    // Compact floating pill that surfaces the current selection count
    // and a clear (✕) affordance. Floats next to the radial-menu
    // anchor with NO grey backplate per feedback_radial_menu_no_backdrop
    // MARK: - Lasso selection actions
    // Issue #16 — drives the confirmationDialog wired off the
    // selection pill. v1 ships Bulk Delete + Clear with real
    // implementations; the other three surface a notice banner with
    // an explicit "next iteration" message so users see the affordance
    // and we capture which actions get the most traction before deeper
    // implementation work.
    private enum LassoAction {
        case addToDataPackage
        case exportKML
        case sendToContacts
        case bulkDelete
    }

    private func performLassoAction(_ action: LassoAction) {
        let sel = lassoService.current
        guard !sel.isEmpty else { return }

        switch action {
        case .bulkDelete:
            let (deleted, broadcast) = bulkDeleteLassoSelection(sel)
            lassoService.clear()
            if broadcast == deleted {
                lassoActionNotice = "Deleted \(deleted) item(s) + broadcast tombstones."
            } else {
                lassoActionNotice = "Deleted \(deleted) item(s) locally — \(broadcast) tombstones broadcast (others were local-only)."
            }

        case .exportKML:
            let markers = resolveLassoMarkers(sel)
            guard !markers.isEmpty else {
                lassoActionNotice = "Selection empty after resolving — nothing to export."
                return
            }
            do {
                let url = try LassoKMLBuilder.write(
                    name: "Lasso selection (\(markers.count))",
                    markers: markers
                )
                lassoExportShareItem = url
            } catch {
                lassoActionNotice = "Export failed: \(error.localizedDescription)"
            }

        case .addToDataPackage:
            let markers = resolveLassoMarkers(sel)
            guard !markers.isEmpty else {
                lassoActionNotice = "Selection empty after resolving — nothing to package."
                return
            }
            do {
                let url = try LassoMissionPackageBuilder.build(
                    name: "Lasso selection (\(markers.count))",
                    markers: markers
                )
                lassoExportShareItem = url
            } catch {
                lassoActionNotice = "Package build failed: \(error.localizedDescription)"
            }

        case .sendToContacts:
            // Hand off to the picker — the actual broadcast happens
            // when the user confirms the recipient UIDs (see
            // lassoContactPickerSheet view).
            showLassoContactPicker = true
        }
    }

    /// Resolve the selection back to LassoExportMarker DTOs across the
    /// three iOS source types (live CoT events, dropped PointMarkers,
    /// drawing-store MarkerDrawings).
    private func resolveLassoMarkers(_ sel: SelectionContext) -> [LassoExportMarker] {
        var out: [LassoExportMarker] = []

        // 1) Live CoT events (server-pushed)
        for e in takService.cotEvents where sel.markerIDs.contains(e.uid) {
            out.append(LassoExportMarker(
                uid: e.uid,
                type: e.type,
                callsign: e.detail.callsign,
                coordinate: CLLocationCoordinate2D(latitude: e.point.lat, longitude: e.point.lon),
                remarks: ""
            ))
        }
        // 2) Dropped points — PointMarker uses `name` for callsign-like
        //    label and an optional `remarks` field.
        for p in pointDropperService.markers
            where sel.markerIDs.contains(p.id.uuidString) || sel.markerIDs.contains(p.uid)
        {
            out.append(LassoExportMarker(
                uid: p.uid,
                type: p.cotType,
                callsign: p.name,
                coordinate: p.coordinate,
                remarks: p.remarks ?? ""
            ))
        }
        // 3) Drawing-store markers — MarkerDrawing's display label
        //    lives on `name`.
        for m in drawingStore.markers
            where sel.markerIDs.contains(m.id.uuidString)
        {
            out.append(LassoExportMarker(
                uid: m.id.uuidString,
                type: "a-u-G",
                callsign: m.name,
                coordinate: m.coordinate,
                remarks: ""
            ))
        }
        return out
    }

    /// Walk every selected ID, delete locally + broadcast a CoT
    /// tombstone (`t-x-d-d`) for marker UIDs that came from the server
    /// so other EUDs propagate the removal. Returns (deletedCount,
    /// broadcastCount) so the caller can pick the right toast copy.
    @discardableResult
    private func bulkDeleteLassoSelection(_ sel: SelectionContext) -> (deleted: Int, broadcast: Int) {
        var deleted = 0
        var broadcast = 0
        let senderUid = "OMNI-iOS-\(UIDevice.current.identifierForVendor?.uuidString.prefix(8) ?? "unknown")"

        // Self-marker guard — never tombstone our own CoT or we tell
        // every peer to forget us.
        let selfUids = Set(takService.cotEvents
            .filter { $0.uid.contains(senderUid) }
            .map { $0.uid })

        for markerID in sel.markerIDs where !selfUids.contains(markerID) {
            // PointDropperService keys by UUID (string form in markerID).
            if let uuid = UUID(uuidString: markerID),
               pointDropperService.markers.contains(where: { $0.id == uuid })
            {
                pointDropperService.deleteMarker(id: uuid)
                deleted += 1
            }
            // Drawing-store markers
            if let uuid = UUID(uuidString: markerID),
               let m = drawingStore.markers.first(where: { $0.id == uuid })
            {
                drawingStore.deleteMarker(m)
                deleted += 1
            }
            // Live CoT (server-pushed) — broadcast a tombstone so the
            // delete propagates to other clients.
            if takService.cotEvents.contains(where: { $0.uid == markerID }) {
                let xml = LassoCotBuilders.buildDeleteEvent(
                    targetUid: markerID,
                    senderUid: senderUid
                )
                if takService.sendCoT(xml: xml) {
                    broadcast += 1
                }
                deleted += 1
            }
        }
        for drawingID in sel.drawingIDs {
            if let line = drawingStore.lines.first(where: { $0.id == drawingID }) {
                drawingStore.deleteLine(line)
            } else if let poly = drawingStore.polygons.first(where: { $0.id == drawingID }) {
                drawingStore.deletePolygon(poly)
            } else if let circle = drawingStore.circles.first(where: { $0.id == drawingID }) {
                drawingStore.deleteCircle(circle)
            }
            deleted += 1
        }
        return (deleted, broadcast)
    }

    /// Broadcast the lasso selection to specific contact UIDs by
    /// rebuilding each marker's CoT with `<dest>` elements for the
    /// chosen recipients. Wired from the contact picker's confirm.
    private func sendLassoSelectionToContacts(_ destUids: Set<String>) {
        let sel = lassoService.current
        let markers = resolveLassoMarkers(sel)
        guard !markers.isEmpty, !destUids.isEmpty else { return }
        let dests = Array(destUids)
        var sent = 0
        for m in markers {
            let xml = LassoCotBuilders.rebuildEvent(
                uid: m.uid,
                type: m.type,
                callsign: m.callsign,
                coordinate: m.coordinate,
                remarks: m.remarks,
                destUids: dests
            )
            if takService.sendCoT(xml: xml) { sent += 1 }
        }
        lassoActionNotice = "Sent \(sent)/\(markers.count) marker(s) to \(destUids.count) recipient(s)."
    }

    // — the orange tint is the only chrome.
    @ViewBuilder
    private var lassoSelectionPill: some View {
        if !lassoService.current.isEmpty {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    LassoSelectionPill(
                        count: lassoService.current.totalCount,
                        onShowActions: {
                            showLassoActions = true
                        }
                    )
                    .padding(.trailing, 16)
                    .padding(.bottom, 200) // above the bottom toolbar
                }
            }
            .zIndex(2000)
            .transition(.opacity)
            .confirmationDialog(
                "\(lassoService.current.totalCount) selected",
                isPresented: $showLassoActions,
                titleVisibility: .visible
            ) {
                // The K9Blue trio (data package, bulk delete, export)
                // plus send-to-contacts, plus an explicit clear.
                Button("Add to Data Package…") {
                    performLassoAction(.addToDataPackage)
                }
                Button("Export as KML…") {
                    performLassoAction(.exportKML)
                }
                Button("Send to Contacts…") {
                    performLassoAction(.sendToContacts)
                }
                Button("Delete \(lassoService.current.totalCount) item(s)", role: .destructive) {
                    performLassoAction(.bulkDelete)
                }
                Button("Clear Selection", role: .cancel) {
                    lassoService.clear()
                }
            } message: {
                Text("Choose an action for the lasso selection.")
            }
            .alert(
                "Selection Action",
                isPresented: Binding(
                    get: { lassoActionNotice != nil },
                    set: { if !$0 { lassoActionNotice = nil } }
                ),
                presenting: lassoActionNotice
            ) { _ in
                Button("OK") { lassoActionNotice = nil }
            } message: { msg in
                Text(msg)
            }
            // KML / Mission Package share sheet — driven by the
            // exporters' returned URL. UIActivityViewController wrapped
            // for SwiftUI in LassoShareSheet below.
            .sheet(item: Binding(
                get: { lassoExportShareItem.map { LassoShareItem(url: $0) } },
                set: { _ in lassoExportShareItem = nil }
            )) { item in
                LassoShareSheet(activityItems: [item.url])
            }
            // Send-to-Contacts picker. Confirm hands the chosen
            // recipient UIDs back; sendLassoSelectionToContacts walks
            // the selection and re-emits each CoT with <dest> elements.
            .sheet(isPresented: $showLassoContactPicker) {
                LassoContactPickerSheet(
                    candidates: takService.cotEvents.map { e in
                        CoTEventLike(uid: e.uid, type: e.type, callsign: e.detail.callsign)
                    },
                    excludeUIDs: lassoService.current.markerIDs,
                    onCancel: {},
                    onConfirm: { uids in
                        sendLassoSelectionToContacts(uids)
                    }
                )
            }
        }
    }
    // == Issue #16: lasso selection pill END ==

    // Identifiable wrapper so .sheet(item:) accepts the URL — SwiftUI
    // needs an Identifiable for that overload.
    private struct LassoShareItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    // Engine toggle pill — flips between 3D Cesium globe and 2D Mapbox
    // map. Lives in the bottom-left over the LiquidGlass tab bar so it's
    // visible regardless of which engine is rendering underneath.
    @ViewBuilder
    private var engineToggleFAB: some View {
        Button {
            let nextEngine: MapEngine = (mapEngine == .cesium3D) ? .mapbox2D : .cesium3D
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            mapEngineRaw = nextEngine.rawValue
        } label: {
            Image(systemName: mapEngine == .cesium3D ? "map.fill" : "globe.americas.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.65))
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 1))
                )
                .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
        }
        .accessibilityLabel(mapEngine == .cesium3D ? "Switch to 2D Map" : "Switch to 3D Globe")
        .accessibilityHint("Toggles between the photoreal Cesium 3D globe and the offline-capable Mapbox 2D map")
    }

    @ViewBuilder
    private var loadingScreen: some View {
        if showLoadingScreen {
            ATAKLoadingScreen(isLoading: $showLoadingScreen)
                .zIndex(2000)
        }
    }

    @ViewBuilder
    private var radialMenu: some View {
        if radialMenuCoordinator.showRadialMenu {
            RadialMenuView(
                isPresented: $radialMenuCoordinator.showRadialMenu,
                centerPoint: radialMenuCoordinator.menuCenterPoint,
                configuration: radialMenuCoordinator.menuConfiguration,
                onSelect: { action in
                    radialMenuCoordinator.executeAction(action)
                }
            )
            .zIndex(3000)
        }
    }

    @ViewBuilder
    private var cursorModeOverlay: some View {
        if isCursorModeActive {
            CursorModeOverlayView(
                coordinator: cursorModeCoordinator,
                mapRegion: mapRegion,
                onDropMarker: { coordinate in
                    dropMarkerAtLocation(coordinate: coordinate, affiliation: .friendly)
                },
                onClose: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isCursorModeActive = false
                        cursorModeCoordinator.deactivate()
                    }
                }
            )
            .zIndex(2500)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var overlaySettingsButton: some View {
        VStack {
            HStack {
                Button(action: {
                    withAnimation(.spring()) {
                        showOverlaySettings.toggle()
                    }
                }) {
                    Image(systemName: "square.stack.3d.up.badge.a")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(8)
                }
                .padding(.leading, 12)
                .padding(.top, 120)
                Spacer()
            }
            Spacer()
        }
        .zIndex(1008)
    }

    @ViewBuilder
    private var overlaySettingsPanel: some View {
        if showOverlaySettings {
            VStack {
                HStack {
                    OverlaySettingsPanel(
                        overlayCoordinator: overlayCoordinator,
                        mapStateManager: mapStateManager,
                        showMGRSGrid: Binding(
                            get: { overlayCoordinator.mgrsGridEnabled },
                            set: { overlayCoordinator.mgrsGridEnabled = $0 }
                        ),
                        showBreadcrumbTrails: Binding(
                            get: { overlayCoordinator.breadcrumbTrailsEnabled },
                            set: { overlayCoordinator.breadcrumbTrailsEnabled = $0 }
                        ),
                        showRBLines: Binding(
                            get: { overlayCoordinator.rangeBearingEnabled },
                            set: { overlayCoordinator.rangeBearingEnabled = $0 }
                        ),
                        onDismiss: {
                            withAnimation(.spring()) {
                                showOverlaySettings = false
                            }
                        }
                    )
                    .padding(.leading, 12)
                    .padding(.top, 170)
                    Spacer()
                }
                Spacer()
            }
            .zIndex(1009)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    // mapCenterDisplay removed - coordinates available via radial menu and settings

    @ViewBuilder
    private var gpsFollowButton: some View {
        VStack {
            Spacer()
            HStack(alignment: .bottom, spacing: 8) {
                // ATAK-style left-side control cluster
                VStack(spacing: 8) {
                    // GPS Lock/Center Button (crosshair icon)
                    Button(action: centerOnUser) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.75))
                                .frame(width: 44, height: 44)

                            Circle()
                                .stroke(trackingMode == .follow ? Color.cyan : Color.white.opacity(0.6), lineWidth: 2)
                                .frame(width: 44, height: 44)

                            Image(systemName: trackingMode == .follow ? "location.fill" : "location")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(trackingMode == .follow ? Color.cyan : .white)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)

                    // Zoom controls moved to bottom toolbar to match ATAK
                }

                // Coordinate display next to GPS button
                if showCoordinates {
                    CoordinateDisplayView(
                        coordinate: locationManager.location?.coordinate,
                        isVisible: true
                    )
                }

                Spacer()
            }
            .padding(.leading, 12)
            .padding(.bottom, isCursorModeActive ? 222 : (showQuickActionToolbar ? 150 : 90))
        }
        .zIndex(1012)
    }

    var body: some View {
        // Engine-agnostic composition: the switch renders ONLY the bare map
        // engine; every piece of shared chrome mounts once via `mapChrome`,
        // and the modal sheets / error overlays / lifecycle + radial-menu
        // observers attach at the body level. Nothing visible to the
        // operator may be added inside an engine view unless it is truly
        // engine-specific — that structure is what killed the recurring
        // "feature wired into one engine only" bug class (radial menu,
        // measurement HUD, side panels all shipped broken on Cesium once).
        ZStack {
            Group {
                switch mapEngine {
                case .cesium3D: cesiumEngineView
                case .mapbox2D: mapboxEngineView
                }
            }
            // Engine-specific overlays stay conditional. Both are 2D-only:
            // the loading splash never mounted on the (default) globe, and
            // cursor mode drives the Mapbox camera. Their zIndexes (2000 /
            // 2500) must compete with the chrome's in the SAME ZStack so
            // the splash keeps covering the toolbars and the radial menu
            // (3000) keeps floating above cursor mode.
            if mapEngine == .mapbox2D {
                loadingScreen
                cursorModeOverlay
            }
            mapChrome
        }
        .background(modalSheets)
        .background(errorOverlays)
        .background(lifecycleHandlers)
        // Marker radial Info / Share / Copy feedback (sheet + share sheet +
        // HUD toast). Bundled in a ViewModifier (type-checked independently)
        // and attached here so it covers BOTH engines.
        .modifier(MarkerRadialFeedback())
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuEditMarker)) { notification in
            if let marker = notification.userInfo?["marker"] as? PointMarker {
                editingPointMarkerID = marker.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .radialMenuEditDrawing)) { notification in
            if let drawingId = notification.userInfo?["drawingId"] as? UUID {
                drawingManager.pendingRenameID = drawingId
            }
        }
    }

    /// The bare 3D engine — the Cesium scene and nothing else. All shared
    /// chrome (toolbars, panels, radial menu, HUDs) mounts engine-
    /// agnostically via `mapChrome` in `body`; entities/drawings/
    /// measurements bridge into the scene through CesiumMainMap's
    /// JS bridge parameters below.
    @ViewBuilder
    private var cesiumEngineView: some View {
        CesiumMainMap(
                contacts: cotMarkers,
                aircraft: adsbService.settings.isEnabled ? adsbService.aircraft : [],
                lineDrawings: drawingStore.lines,
                circleDrawings: drawingStore.circles,
                polygonDrawings: drawingStore.polygons,
                rangeRings: measurementManager.rangeRings,
                // Dropped pins — same source the 2D Mapbox path reads, so
                // a pin shows on whichever engine is active.
                pointMarkers: pointDropperService.markers,
                selfLocation: locationManager.location,
                // Follow mode parity with the 2D map — when on, Cesium keeps
                // the camera centered on the operator as their GPS updates.
                isFollowing: trackingMode == .follow,
                // Lasso multi-select — lock the globe camera and capture the
                // freehand drag when the operator is in lasso mode.
                lassoActive: drawingManager.currentMode == .lasso && drawingManager.isDrawingActive,
                // Base layer (satellite / hybrid / standard) so the layers
                // panel switches the globe's imagery, not just the 2D style.
                baseLayer: activeMapLayer,
                // Issue #72 — north-up lock state so the globe pins north-up
                // (persisted via @AppStorage; survives engine toggle / relaunch).
                isNorthLocked: isNorthLocked,
                selfCallsign: userCallsign,
                // Self-pip style parity with the Mapbox puck (Settings →
                // Self-position marker).
                selfMarkerStyle: selfMarkerStyle,
                // Phase 3b — saved distance / area measurements mirrored
                // through the Cesium bridge as dashed polylines + segment
                // labels.
                measurements: measurementManager.savedMeasurements,
                // Live in-progress measurement → yellow polyline on the
                // globe (parity with the Mapbox temp line).
                liveMeasurementPoints: measurementManager.isActive
                    ? measurementManager.temporaryPoints
                    : [],
                // Active navigation route → polyline + waypoint billboards.
                activeRoute: routeService.activeRoute,
                // Phase 3b — operator's own recorded breadcrumb trail.
                // The service models a single trail; if no recording is
                // active or it's been cleared the coords list is empty
                // and the bridge sends `[]` (clears any prior trail).
                breadcrumbTrailCoords: overlayCoordinator.breadcrumbTrailsEnabled
                    ? BreadcrumbTrailService.shared.trailCoordinates
                    : [],
                // The service stores `teamColor` as a hex string (e.g.
                // "#00FF00") — direct feed to the bridge. We deliberately
                // skip PositionBroadcastService.teamColor here (it's a
                // CoT color name like "Cyan", not hex).
                breadcrumbTrailColor: BreadcrumbTrailService.shared.configuration.teamColor,
                // Phase 4a — feed Cesium tap/long-press back into the
                // same radial-menu coordinator the Mapbox path uses. The
                // ZStack still owns the radial overlay, so the menu pops
                // wherever the operator pressed.
                onMapEvent: { event in
                    handleCesiumMapEvent(event)
                }
            )
            .ignoresSafeArea()
    }

    /// Compact measurement HUD (ATAK-style) — engine-agnostic SwiftUI
    /// chrome, mounted on both engines via `mapChrome`.
    @ViewBuilder
    private var measurementChrome: some View {
        if showMeasurement {
            CompactMeasurementOverlay(manager: measurementManager, isPresented: $showMeasurement)
                .zIndex(1000)
        }
    }

    /// Route navigation panel (ATAK-style, top-left) — engine-agnostic,
    /// mounted on both engine bodies. Renders content only while a route
    /// is active / navigating.
    @ViewBuilder
    private var routeNavigationChrome: some View {
        VStack {
            HStack {
                RouteNavigationPanel(
                    routeService: routeService,
                    isExpanded: $isNavigationPanelExpanded
                )
                .frame(maxWidth: 320) // ATAK-style compact width
                .padding(.leading, 8)
                .padding(.top, 70) // Below status bar
                Spacer()
            }
            Spacer()
        }
        .zIndex(1100)
    }

    /// The bare 2D engine — the Mapbox map plus its only truly
    /// engine-specific overlay, the MGRS grid (rendered against the 2D
    /// camera). Everything else lives in `mapChrome` / `body`.
    @ViewBuilder
    private var mapboxEngineView: some View {
        ZStack {
            mainMapView
            gridOverlay
        }
    }

    /// Engine-agnostic map chrome — the single overlay stack shared by BOTH
    /// engines, mounted once in `body` above whichever engine is active.
    /// Add new shared chrome HERE, never inside an engine view: chrome that
    /// was chained onto one engine's ZStack is exactly how the radial menu,
    /// side panels, measurement HUD, and GPS-follow button each shipped
    /// broken on the other engine.
    @ViewBuilder
    private var mapChrome: some View {
        // Point Dropper aim crosshair — drop lands where this sits. Centered
        // on the full screen (not the safe area) so it coincides with the
        // camera-center coordinate the drop uses on both engines.
        if pointDropAim.isAiming {
            Color.clear
                .overlay(PointDropCrosshair())
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .zIndex(900)
        }
        topToolbars
        sidePanels
        statusIndicators
        mapOverlayComponents
        registeredPluginOverlays
        radialMenu
        gpsFollowButton
        lassoSelectionPill
        measurementChrome
        routeNavigationChrome
    }

    /// Plugin SDK map-overlay seam. Renders every overlay a plugin registered
    /// via `host.registerMapOverlay(...)`. Because it mounts inside the
    /// engine-agnostic `mapChrome` (NOT inside cesiumEngineView /
    /// mapboxEngineView), every plugin overlay shows on BOTH engines. zIndex
    /// 1500 keeps it above the map / static chrome and below the radial menu
    /// (3000). Overlays are non-interactive by default so they never steal
    /// map gestures; a plugin that needs hit-testing renders its own
    /// interactive controls.
    @ViewBuilder
    private var registeredPluginOverlays: some View {
        if !pluginHost.mapOverlays.isEmpty {
            ForEach(pluginHost.mapOverlays) { entry in
                Color.clear
                    .overlay(entry.view())
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .zIndex(1500)
            }
        }
    }

    private var modalSheets: some View {
        EmptyView()
            .sheet(isPresented: $showServerConfig) {
                NetworkPreferencesView()
            }
            // #38: prompt the user to name a shape immediately after creating
            // it. DrawingToolsManager publishes the new shape's id; we pop
            // the existing properties sheet (which already has a Name field).
            .sheet(isPresented: Binding(
                get: { drawingManager.pendingRenameID != nil },
                set: { if !$0 { drawingManager.pendingRenameID = nil } }
            )) {
                if let id = drawingManager.pendingRenameID {
                    DrawingPropertiesView(
                        drawingStore: drawingStore,
                        drawingID: id,
                        isPresented: Binding(
                            get: { drawingManager.pendingRenameID != nil },
                            set: { if !$0 { drawingManager.pendingRenameID = nil } }
                        )
                    )
                }
            }
            // Radial menu Edit → open PointMarker edit form. The radial
            // posts .radialMenuEditMarker (see RadialMenuActionExecutor);
            // without this observer the menu just dismissed silently.
            .sheet(isPresented: Binding(
                get: { editingPointMarkerID != nil },
                set: { if !$0 { editingPointMarkerID = nil } }
            )) {
                if let id = editingPointMarkerID {
                    PointMarkerEditView(
                        pointDropperService: pointDropperService,
                        markerID: id,
                        isPresented: Binding(
                            get: { editingPointMarkerID != nil },
                            set: { if !$0 { editingPointMarkerID = nil } }
                        )
                    )
                }
            }
            .fullScreenCover(isPresented: $showToolsMenu) {
                ATAKToolsView(isPresented: $showToolsMenu, showMeasurement: $showMeasurement)
            }
            .sheet(isPresented: $showTeamManagement) {
                TeamListView()
            }
            .sheet(isPresented: $showRoutePlanning) {
                RouteListView()
            }
            .sheet(isPresented: $showGeofences) {
                GeofenceListView()
            }
            .sheet(isPresented: $showTrackRecording) {
                TrackListView(recordingService: trackRecordingService)
            }
            .sheet(isPresented: $showChat) {
                ChatView(chatManager: chatManager)
            }
            .sheet(isPresented: $showContacts) {
                ContactListView(chatManager: chatManager)
            }
            .sheet(isPresented: $showEmergencySOS) {
                EmergencyBeaconView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .environmentObject(LocalizationManager.shared)
            }
            .sheet(isPresented: $showPlugins) {
                PluginsListView()
            }
            .sheet(isPresented: $showAbout) {
                AboutView()
            }
            .sheet(isPresented: $showPositionBroadcast) {
                PositionBroadcastView()
            }
            .sheet(isPresented: $showMeshtastic) {
                MeshtasticConnectionView()
            }
            .sheet(isPresented: $showElevationProfile) {
                ElevationProfileView()
            }
            .sheet(isPresented: $showLineOfSight) {
                LineOfSightView()
            }
            .sheet(isPresented: $showEchelonHierarchy) {
                EchelonHierarchyView()
            }
            .sheet(isPresented: $showMissionSync) {
                MissionSyncView()
            }
    }

    private var errorOverlays: some View {
        EmptyView()
            .overlay(
                Group {
                    if showGPSError {
                        GPSErrorAlert(isPresented: $showGPSError, onSettings: {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        })
                        .zIndex(2001)
                    }
                }
            )
    }

    /// Notification observers for the "Go to Coordinate" entry sheet, kept on
    /// a separate EmptyView so they don't extend `lifecycleHandlers`' chain.
    private var coordinateHandlers: some View {
        EmptyView()
            .onReceive(NotificationCenter.default.publisher(for: .goToCoordinate)) { note in
                handleGoToCoordinate(note)
            }
    }

    private var lifecycleHandlers: some View {
        EmptyView()
            .onAppear {
                setupTAKConnection()
                startLocationUpdates()
                radialMenuCoordinator.configure(drawingStore: drawingStore)
                positionBroadcastService.configure(takService: takService, locationManager: locationManager)
                positionBroadcastService.isEnabled = true
                overlayCoordinator.loadSettings()
                mapStateManager.loadPreferences()
                mapStateManager.updateMapRegion(mapRegion)

                // Hook up self-healing route callback
                routeService.onRouteOverlayUpdate = { [weak routeOverlayCoordinator] route, currentLocation, waypointIndex in
                    DispatchQueue.main.async {
                        routeOverlayCoordinator?.updateSelfHealingRoute(
                            route: route,
                            currentLocation: currentLocation,
                            currentWaypointIndex: waypointIndex
                        )
                    }
                }
            }
            .onChange(of: isCursorModeActive) { newValue in
                DispatchQueue.main.async {
                    if newValue {
                        cursorModeCoordinator.activate()
                        mapStateManager.isCursorModeActive = true
                    } else {
                        cursorModeCoordinator.deactivate()
                        mapStateManager.isCursorModeActive = false
                    }
                }
            }
            .onChange(of: mapRegion.center.latitude) { _ in
                DispatchQueue.main.async {
                    mapStateManager.updateMapRegion(mapRegion)
                    // MGRS update handled by updateVisibleOverlays in map coordinator
                }
            }
            .onChange(of: mapRegion.center.longitude) { _ in
                DispatchQueue.main.async {
                    mapStateManager.updateMapRegion(mapRegion)
                    // MGRS update handled by updateVisibleOverlays in map coordinator
                }
            }
            .onChange(of: overlayCoordinator.mgrsGridEnabled) { newValue in
                DispatchQueue.main.async {
                    showGrid = newValue
                    // The MGRS grid renders only on the 2D engine; enabling
                    // it on the Cesium globe used to silently no-op. Auto-
                    // switch to the 2D map instead (same prompt-free
                    // precedent as kmlZoomToOverlay above).
                    if newValue && mapEngine == .cesium3D {
                        mapEngineRaw = MapEngine.mapbox2D.rawValue
                    }
                }
            }
            .onChange(of: locationManager.location?.coordinate.latitude) { _ in
                // Update map region to follow user if in follow mode (no animation)
                if trackingMode == .follow, let location = locationManager.location {
                    mapRegion.center = location.coordinate
                }
            }
            .onChange(of: locationManager.location?.coordinate.longitude) { _ in
                // Update map region to follow user if in follow mode (no animation)
                if trackingMode == .follow, let location = locationManager.location {
                    mapRegion.center = location.coordinate
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuCustomAction)) { notification in
                guard let userInfo = notification.userInfo,
                      let identifier = userInfo["identifier"] as? String else {
                    return
                }

                switch identifier {
                case "draw_shape":
                    withAnimation(.spring()) {
                        showDrawingPanel.toggle()
                    }
                case "meshtastic":
                    showMeshtastic = true
                default:
                    break // Unknown custom action
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuMeasurementStarted)) { notification in
                // Radial menu wants to start measurement - show the CompactMeasurementOverlay
                DispatchQueue.main.async {
                    showMeasurement = true

                    // If a specific measurement type was requested, start it
                    if let userInfo = notification.userInfo,
                       let type = userInfo["type"] as? MeasurementType {
                        measurementManager.startMeasurement(type: type)

                        // If a coordinate was provided (from radial menu), add it as the first tap
                        if let coordinate = userInfo["coordinate"] as? CLLocationCoordinate2D {
                            measurementManager.handleMapTap(at: coordinate)
                        }
                    }
                }
            }
            // Drawing action observers from radial menu
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuOpenDrawingTools)) { _ in
                withAnimation(.spring()) {
                    showDrawingPanel = true
                    showDrawingList = false
                    showLayersPanel = false
                }
            }
            // Issue #16 — Tools tab posts this when the user picks
            // "Lasso Select". Activate lasso mode here so the in-map
            // gesture recognizer (UILongPressGestureRecognizer keyed on
            // drawingManager.currentMode == .lasso) starts firing.
            .onReceive(NotificationCenter.default.publisher(for: .startLassoMode)) { _ in
                drawingManager.startDrawing(mode: .lasso)
            }
            // Issue #16 — Tools tab "Full Tools…" passthrough. Reuses
            // the existing in-map ATAKToolsView presentation
            // (showToolsMenu / .fullScreenCover) so all the tool
            // wiring stays exactly where it was.
            .onReceive(NotificationCenter.default.publisher(for: .showFullTools)) { _ in
                showToolsMenu = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuOpenDrawingsList)) { _ in
                withAnimation(.spring()) {
                    showDrawingList = true
                    showDrawingPanel = false
                    showLayersPanel = false
                }
            }
            // App mode picker from radial menu
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuShowAppModePicker)) { _ in
                showAppModePicker = true
            }
            // Layers panel from radial menu
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuShowLayers)) { _ in
                withAnimation(.spring()) {
                    showLayersPanel.toggle()
                }
            }
            // Radial "Center Map" + draw shortcuts. Bundled into a single
            // ViewModifier (type-checked independently) so the four extra
            // `.onReceive`s don't push this already-maxed body expression past
            // the Swift type-checker's complexity limit. Each of these
            // notifications previously had no observer — they were dead taps.
            .modifier(RadialMenuExtraObservers(mapRegion: $mapRegion, drawingManager: drawingManager, mapEngineRaw: $mapEngineRaw))
            // Customizable bar "Drop Pin" shortcut — drop a marker at the
            // current map center on whichever engine is active. Cesium uses
            // its persisted camera center; Mapbox uses the tracked region.
            .onReceive(NotificationCenter.default.publisher(for: .barDropPin)) { _ in
                let center: CLLocationCoordinate2D = mapEngine == .cesium3D
                    ? CLLocationCoordinate2D(latitude: cesiumLastLat, longitude: cesiumLastLon)
                    : mapRegion.center
                dropMarkerAtLocation(coordinate: center, affiliation: .friendly)
            }
            // Frame a KML overlay's bounds. Overlays render on the 2D engine,
            // so switch to it first.
            .onReceive(NotificationCenter.default.publisher(for: .kmlZoomToOverlay)) { note in
                guard let id = note.userInfo?["id"] as? String else { return }
                // Look the id up in either store — vector KML or raster imagery.
                let box: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double)?
                if let o = KMLVectorOverlayStore.shared.overlays.first(where: { $0.id == id }) {
                    box = (o.minLat, o.minLon, o.maxLat, o.maxLon)
                } else if let r = RasterOverlayStore.shared.overlays.first(where: { $0.id == id }) {
                    box = (r.south, r.west, r.north, r.east)
                } else if let m = MBTilesOverlayStore.shared.overlays.first(where: { $0.id == id }), m.hasBounds {
                    box = (m.south, m.west, m.north, m.east)
                } else {
                    box = nil
                }
                guard let b = box else { return }
                mapEngineRaw = MapEngine.mapbox2D.rawValue
                let latSpan = max((b.maxLat - b.minLat) * 1.3, 0.02)
                let lonSpan = max((b.maxLon - b.minLon) * 1.3, 0.02)
                mapRegion = MKCoordinateRegion(
                    center: CLLocationCoordinate2D(latitude: (b.minLat + b.maxLat) / 2,
                                                   longitude: (b.minLon + b.maxLon) / 2),
                    span: MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: lonSpan)
                )
            }
            // Bug #9: Contact actions from ContactDetailView ("Show on Map" /
            // "Navigate to Contact"). Previously these notifications had no
            // subscriber — sheet just dismissed and dropped user back on list.
            .onReceive(NotificationCenter.default.publisher(for: .centerMapOnContact)) { note in
                handleCenterMapOnContact(note)
            }
            .onReceive(NotificationCenter.default.publisher(for: .startNavigationToContact)) { note in
                handleStartNavigationToContact(note)
            }
            // Coordinate-entry handler lives on a sibling EmptyView (attached
            // via .background) to keep this already-large modifier chain under
            // the Swift type-checker ceiling.
            .background(coordinateHandlers)
            .sheet(isPresented: $showAppModePicker) {
                AppModePickerView()
            }
            // Route navigation changes
            .onChange(of: routeService.activeRoute?.id) { newRouteId in
                DispatchQueue.main.async {
                    if let route = routeService.activeRoute {
                        // Display the active route on the map
                        routeOverlayCoordinator.displayRoute(route, isActive: routeService.isNavigating)
                    } else {
                        // Clear route overlays when navigation stops
                        routeOverlayCoordinator.clearRouteOverlays()
                    }
                }
            }
            .onChange(of: routeService.isNavigating) { isNavigating in
                DispatchQueue.main.async {
                    if let route = routeService.activeRoute {
                        // Update route display based on navigation state
                        routeOverlayCoordinator.displayRoute(route, isActive: isNavigating)
                    }
                    // Collapse navigation panel when not navigating
                    if !isNavigating {
                        isNavigationPanelExpanded = false
                    }
                }
            }
    }

    // MARK: - Drawing and Measurement Handlers

    private func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        // Handle measurement tool taps first
        if measurementManager.isActive {
            measurementManager.handleMapTap(at: coordinate)
            return
        }

        // Then handle drawing tool taps
        if drawingManager.isDrawingActive {
            drawingManager.handleMapTap(at: coordinate)
        }
    }

    // MARK: - Phase 4a — Cesium → native event dispatch
    //
    // Map the bridged tap/long-press events onto the same radial-menu
    // surface the 2D Mapbox path uses. Empty-map long-press opens the
    // map-context menu; entity tap surfaces the marker-context menu so
    // the operator can hit Edit/Delete/etc. (CoT contact edit flows
    // through `.radialMenuEditMarker`, same as Mapbox.) Single tap on
    // empty map is a no-op to match Mapbox's default.
    // Persisted Cesium camera pose so an engine toggle (3D Cesium →
    // 2D Mapbox → back) restores the operator's last view instead of
    // snapping to the hardcoded DC default. Defaults seed Washington DC
    // tilted 30°. Phase 4c will mirror these into the 2D Mapbox path's
    // mapRegion so cross-engine continuity is fully bidirectional.
    // Defaults match the bootstrap flyTo (KJFK at 50km, -60° pitch) so an
    // engine-toggle on first launch doesn't snap the camera somewhere
    // unrelated. Updated on every Cesium camera-changed event.
    @AppStorage("cesium.lastLat")     private var cesiumLastLat: Double = 40.6413
    @AppStorage("cesium.lastLon")     private var cesiumLastLon: Double = -73.7781
    @AppStorage("cesium.lastHeight")  private var cesiumLastHeight: Double = 50000
    @AppStorage("cesium.lastHeading") private var cesiumLastHeading: Double = 0
    @AppStorage("cesium.lastPitch")   private var cesiumLastPitch: Double = -60

    private func handleCesiumMapEvent(_ event: CesiumMapEvent) {
        switch event.kind {
        case .cameraChanged:
            guard let cam = event.camera else { return }
            cesiumLastLat = event.coordinate.latitude
            cesiumLastLon = event.coordinate.longitude
            cesiumLastHeight = cam.height
            cesiumLastHeading = cam.heading
            cesiumLastPitch = cam.pitch
            // Issue #73 — mirror Cesium heading into mapBearing so the compass
            // overlay stays in sync with the 3D globe's rotation. When the lock
            // is engaged the JS side pins heading to 0° itself (setNorthLock),
            // so this just reflects the corrected value — no native re-snap loop.
            mapBearing = isNorthLocked ? 0 : cam.heading
            // Mirror the Cesium camera into mapRegion so 2D-derived chrome
            // (scale bar, MGRS grid) reads the right scale on the globe, an
            // engine toggle lands at the same view, and — crucially — the
            // point-drop coordinate (MapCenterStore, fed from mapRegion) is
            // the globe point under the screen-center crosshair, not the
            // tilted camera's sub-point. Span approximated from camera height.
            let regionCenter = event.centerCoordinate ?? event.coordinate
            let lat = regionCenter.latitude
            let metersVisible = max(50.0, 1.15 * cam.height)
            let latDelta = min(metersVisible / 111_320.0, 90.0)
            let lonDelta = min(latDelta / max(cos(lat * .pi / 180), 0.01), 180.0)
            mapRegion = MKCoordinateRegion(
                center: regionCenter,
                span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
            )
        case .longpress:
            // A long-press landing on a dropped pin opens the same
            // point-marker menu (Edit/Delete/Share/Navigate) the 2D
            // Mapbox long-press path produces. Empty-map and other
            // entities fall through to the map-context menu.
            if openCesiumPointMarkerMenu(uid: event.entityUid, at: event) { return }
            radialMenuCoordinator.showContextMenu(
                at: event.screenPoint,
                for: event.coordinate,
                menuType: .mapContext
            )
        case .tap:
            guard let uid = event.entityUid else {
                // Empty-map single tap mirrors the 2D Mapbox path —
                // measurement / drawing tool consume the tap if active,
                // otherwise it's a no-op.
                handleMapTap(at: event.coordinate)
                return
            }
            // A tap on a dropped pin surfaces its radial menu so the
            // operator can edit it without hunting for the long-press —
            // the 3D engine has no MKMapView callout to lean on.
            if openCesiumPointMarkerMenu(uid: uid, at: event) { return }
            // The HTML emits `__self__` for the operator's own pip and
            // namespaced uids (`ads-…`, `line-…`, `poly-…`, `circ-…`,
            // `rring-…`, `meas-…`, `trail-…`, `:v<idx>` vertex labels)
            // for non-contact entities. None of those have a CoT event
            // behind them, so skip the marker-context menu for them.
            if uid == "__self__" { return }
            let nonContactPrefixes = ["ads-", "line-", "poly-", "circ-", "rring-", "meas-", "trail-", "route-"]
            if nonContactPrefixes.contains(where: { uid.hasPrefix($0) }) { return }
            if uid.contains(":v") { return }
            // CoT contact match — open the marker-context radial menu
            // anchored at the tap point. Edit/Delete on that menu post
            // .radialMenuEditMarker etc., same as the Mapbox long-press
            // path, so downstream wiring is shared.
            if cotMarkers.contains(where: { $0.uid == uid }) {
                radialMenuCoordinator.showContextMenu(
                    at: event.screenPoint,
                    for: event.coordinate,
                    menuType: .markerContext
                )
            }
        case .lasso:
            // The globe posted the freehand selection polygon. Run the exact
            // same point-in-polygon selection the 2D Mapbox lasso uses, then
            // exit lasso mode (which flips setLassoMode off on the bridge).
            defer { drawingManager.cancelDrawing() }
            guard let poly = event.polygon, poly.count >= 3 else { return }
            lassoService.beginLasso()
            for c in poly { lassoService.appendVertex(c) }
            let markers: [LassoMarker] =
                cotMarkers.map(LassoMarker.init(cot:)) +
                pointDropperService.markers.map(LassoMarker.init(point:)) +
                drawingStore.markers.map(LassoMarker.init(marker:))
            let drawings: [LassoDrawing] =
                drawingStore.lines.map { LassoDrawing(id: $0.id, coordinates: $0.coordinates) } +
                drawingStore.polygons.map { LassoDrawing(id: $0.id, coordinates: $0.coordinates) } +
                drawingStore.circles.map { LassoDrawing(id: $0.id, coordinates: [$0.center]) }
            _ = lassoService.endLasso(markers: markers, drawings: drawings)
        }
    }

    /// If `uid` belongs to a dropped point marker, open the point-marker
    /// radial menu anchored at the press and return true. Shared by the
    /// Cesium tap + long-press paths so a pin is editable on the 3D engine
    /// exactly like the 2D Mapbox long-press path (showPointMarkerMenu).
    private func openCesiumPointMarkerMenu(uid: String?, at event: CesiumMapEvent) -> Bool {
        guard let uid,
              let pm = pointDropperService.markers.first(where: { $0.uid == uid })
        else { return false }
        radialMenuCoordinator.showPointMarkerMenu(
            at: event.screenPoint,
            coordinate: pm.coordinate,
            marker: pm
        )
        return true
    }

    // MARK: - Marker Actions

    private func dropMarkerAtLocation(coordinate: CLLocationCoordinate2D, affiliation: MarkerAffiliation) {
        // Create a new marker at the specified location
        let callsign = generateCallsign(for: affiliation)

        // Use PointDropperService quickDrop
        _ = PointDropperService.shared.quickDrop(
            at: coordinate,
            name: callsign,
            broadcast: false
        )

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func generateCallsign(for affiliation: MarkerAffiliation) -> String {
        let prefix: String
        switch affiliation {
        case .friendly:
            prefix = "FRD"
        case .hostile:
            prefix = "HST"
        case .neutral:
            prefix = "NEU"
        case .unknown:
            prefix = "UNK"
        }

        let timestamp = Int(Date().timeIntervalSince1970) % 10000
        return "\(prefix)-\(timestamp)"
    }

    // MARK: - Actions

    private func setupTAKConnection() {
        // Connect to all enabled servers (respects user's toggle state)
        ServerManager.shared.connectToEnabledServers()
    }

    private func startLocationUpdates() {
        locationManager.startUpdating()

        // Check GPS status and show error if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if self.locationManager.location == nil {
                self.showGPSError = false  // Don't show error immediately
            }
        }
    }

    private func centerOnUser() {
        // Toggle tracking mode
        if trackingMode == .follow {
            // Disable follow mode - allow free panning
            trackingMode = .none
        } else {
            // Enable follow mode and center on user
            if let location = locationManager.location {
                withAnimation {
                    mapRegion.center = location.coordinate
                    mapRegion.span = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                }
                trackingMode = .follow
            }
        }
    }

    private func zoomIn() {
        // On the Cesium globe the camera is driven over the JS bridge, not by
        // mapRegion — push a zoom command instead. mapRegion is then refreshed
        // from the camera via handleCesiumMapEvent.
        if mapEngine == .cesium3D {
            NotificationCenter.default.post(name: .cesiumZoom, object: nil, userInfo: ["factor": 0.5])
            return
        }
        mapRegion.span.latitudeDelta = max(mapRegion.span.latitudeDelta / 2, 0.001)
        mapRegion.span.longitudeDelta = max(mapRegion.span.longitudeDelta / 2, 0.001)
    }

    private func zoomOut() {
        if mapEngine == .cesium3D {
            NotificationCenter.default.post(name: .cesiumZoom, object: nil, userInfo: ["factor": 2.0])
            return
        }
        mapRegion.span.latitudeDelta = min(mapRegion.span.latitudeDelta * 2, 180)
        mapRegion.span.longitudeDelta = min(mapRegion.span.longitudeDelta * 2, 180)
    }

    private func zoomToDrawing(coordinate: CLLocationCoordinate2D, radius: Double?) {
        let span: MKCoordinateSpan
        if let radius = radius {
            let degrees = (radius * 3) / 111000
            span = MKCoordinateSpan(
                latitudeDelta: max(degrees, 0.005),
                longitudeDelta: max(degrees, 0.005)
            )
        } else {
            span = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        }

        withAnimation(.easeInOut(duration: 0.3)) {
            mapRegion = MKCoordinateRegion(center: coordinate, span: span)
        }
    }

    private func toggleLayer(_ layer: String) {
        // Haptic feedback
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        // Update active layer
        activeMapLayer = layer

        // Toggle map layers
        withAnimation(.easeInOut(duration: 0.3)) {
            switch layer {
            case "satellite": mapType = .satellite
            case "hybrid": mapType = .hybrid
            case "standard": mapType = .standard
            default: break
            }
        }
    }

    private func toggleOverlay(_ overlay: String) {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        switch overlay {
        case "friendly": showFriendly.toggle()
        case "hostile": showHostile.toggle()
        case "neutral": showNeutral.toggle()
        case "unknown": showUnknown.toggle()
        default: break
        }
    }

    private func toggleMapOverlay(_ overlay: String) {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        withAnimation(.easeInOut(duration: 0.3)) {
            switch overlay {
            case "compass": showCompass.toggle()
            case "coordinates": showCoordinates.toggle()
            case "scale": showScaleBar.toggle()
            case "grid": showGrid.toggle()
            case "callsign": showCallsignPanel.toggle()
            default: break
            }
        }
    }

    // MARK: - North-Up Lock (Issue #72/#73)

    /// Toggle the north-up lock on/off. When engaged, rotation gestures
    /// snap back to north and the compass badge turns cyan.
    private func toggleNorthLock() {
        isNorthLocked.toggle()
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.impactOccurred()
        // Mapbox: rotate disable/enable is applied in TacticalMapView.updateUIView
        // via the isNorthLocked binding (gestures.options.rotateEnabled).
        // Cesium: engage/release the real lock so the globe stays north-up and
        // can't be twisted off north — the JS side snaps to north on engage and
        // self-corrects any drift.
        NotificationCenter.default.post(
            name: .cesiumSetNorthLock, object: nil, userInfo: ["on": isNorthLocked]
        )
        if isNorthLocked {
            // Snap the 2D engine to north now (Cesium snaps inside setNorthLock).
            NotificationCenter.default.post(name: .mapboxResetNorth, object: nil)
            withAnimation(.easeInOut(duration: 0.3)) { mapBearing = 0 }
        }
    }

    /// Snap both map engines back to north (heading 0°).
    private func resetMapToNorth() {
        // Cesium — post the notification; the Coordinator forwards it to the JS bridge.
        NotificationCenter.default.post(name: .cesiumResetNorth, object: nil)
        // Mapbox — post a dedicated notification that TacticalMapView's
        // coordinator listens to and applies via setCamera(bearing:0).
        NotificationCenter.default.post(name: .mapboxResetNorth, object: nil)
        withAnimation(.easeInOut(duration: 0.3)) {
            mapBearing = 0
        }
    }

    // MARK: - Formatting Helpers

    private func formatCoordinates(_ coordinate: CLLocationCoordinate2D) -> String {
        // Honor the user's coordinate-format preference (Settings → Coordinate
        // Format) and delegate to the canonical converters. Read the stored
        // value at format time so a settings change takes effect on the next
        // location update without requiring a reload.
        let stored = UserDefaults.standard.string(forKey: "coordinateDisplayFormat")
        let format = stored.flatMap(CoordinateDisplayFormat.init(rawValue:)) ?? .mgrs
        return format.format(coordinate)
    }

    private func formatAltitude(_ altitude: CLLocationDistance) -> String {
        return UnitPreferences.shared.formatAltitude(altitude) + " MSL"
    }

    private func formatSpeed(_ speed: CLLocationSpeed) -> String {
        return UnitPreferences.shared.formatSpeed(max(0, speed))
    }

    private func formatHeading(_ heading: CLHeading?) -> String {
        guard let heading = heading else {
            // Fall back to course from location if heading not available
            if locationManager.course >= 0 {
                return String(format: "%.0f°M", locationManager.course)
            }
            return ""
        }
        // Use magnetic heading for ATAK compatibility
        return String(format: "%.0f°M", heading.magneticHeading)
    }

    // MARK: - Multi-Server Helpers

    // Multi-server connection status for status bar (reads TAKService.shared
    // native multi-server state — the dead MultiServerFederation stack that
    // previously fed these helpers always reported zero servers)
    private func multiServerConnectionStatus() -> String {
        let connectedIds = takService.connectedServerIds
        let totalCount = ServerManager.shared.servers.count

        if connectedIds.isEmpty {
            return "Disconnected"
        } else if connectedIds.count == 1 {
            if let id = connectedIds.first,
               let server = ServerManager.shared.servers.first(where: { $0.id == id }) {
                return "Connected - \(server.name)"
            }
            return "Connected"
        } else {
            return "Connected to \(connectedIds.count)/\(totalCount) servers"
        }
    }

    // Multi-server display name for status bar
    private func multiServerDisplayName() -> String? {
        let connectedIds = takService.connectedServerIds
        let connectedNames = ServerManager.shared.servers
            .filter { connectedIds.contains($0.id) }
            .map { $0.name }

        if connectedNames.isEmpty {
            return ServerManager.shared.activeServer?.name
        } else if connectedNames.count == 1 {
            return connectedNames.first
        } else {
            let shown = connectedNames.prefix(2).joined(separator: ", ")
            return connectedNames.count > 2 ? "\(shown) +\(connectedNames.count - 2)" : shown
        }
    }

    // MARK: - Contact Detail Actions (Bug #9)
    //
    // Subscribers for ContactDetailView's "Show on Map" / "Navigate to Contact"
    // notifications. Posting was already wired on the Teams side; until this
    // fix there was no receiver, so tapping either button just dismissed the
    // sheet and dropped the user back on the contact list with no visible
    // change.

    private func handleCenterMapOnContact(_ note: Notification) {
        guard let uid = note.userInfo?["uid"] as? String else { return }
        guard let event = takService.cotEvents.first(where: { $0.uid == uid }) else { return }
        let target = CLLocationCoordinate2D(latitude: event.point.lat, longitude: event.point.lon)
        showContacts = false
        withAnimation {
            mapRegion = MKCoordinateRegion(
                center: target,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        }
        NotificationCenter.default.post(
            name: .cesiumCenterOn,
            object: nil,
            userInfo: ["lat": target.latitude, "lon": target.longitude]
        )
    }

    /// Jump the map to a typed coordinate (from the "Go to Coordinate"
    /// sheet), optionally dropping a marker. Centers both the 2D (MapLibre)
    /// and 3D (Cesium) engines, mirroring handleCenterMapOnContact.
    private func handleGoToCoordinate(_ note: Notification) {
        guard let lat = note.userInfo?["lat"] as? Double,
              let lon = note.userInfo?["lon"] as? Double else { return }
        let target = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let drop = note.userInfo?["drop"] as? Bool ?? false

        withAnimation {
            mapRegion = MKCoordinateRegion(
                center: target,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            )
        }
        NotificationCenter.default.post(
            name: .cesiumCenterOn,
            object: nil,
            userInfo: ["lat": target.latitude, "lon": target.longitude]
        )
        if drop {
            dropMarkerAtLocation(coordinate: target, affiliation: .unknown)
        }
    }

    private func handleStartNavigationToContact(_ note: Notification) {
        guard let uid = note.userInfo?["uid"] as? String,
              let event = takService.cotEvents.first(where: { $0.uid == uid }) else { return }
        let target = CLLocationCoordinate2D(latitude: event.point.lat, longitude: event.point.lon)
        let name = event.detail.callsign
        showContacts = false
        guard let here = locationManager.location?.coordinate else {
            NotificationCenter.default.post(
                name: .radialMenuNavigationStarted,
                object: nil,
                userInfo: ["destination": target, "destinationName": name]
            )
            return
        }
        let start = RouteWaypoint(coordinate: here, name: "Current Location",
                                  order: 0, instruction: "Start navigation")
        let end = RouteWaypoint(coordinate: target, name: name,
                                order: 1, instruction: "Arrive at \(name)")
        let route = routeService.createRoute(
            name: "Navigate to \(name)",
            waypoints: [start, end],
            color: "#4CAF50",
            lineStyle: .solid,
            lineOpacity: 0.9,
            lineWidth: 5.0,
            waypointIconStyle: .numbered,
            waypointPrefix: "",
            showDirectionArrows: true
        )
        routeService.startNavigation(for: route)
    }
}


// MARK: - Radial Menu Extra Observers

/// Wires the radial-menu "Center Map" and draw-shape shortcuts that previously
/// posted notifications with no observer (dead taps). Lives in its own
/// ViewModifier so its `.onReceive`s are type-checked independently of
/// `ATAKMapView`'s body, which is already at the Swift type-checker's
/// expression-complexity ceiling.
private struct RadialMenuExtraObservers: ViewModifier {
    @Binding var mapRegion: MKCoordinateRegion
    let drawingManager: DrawingToolsManager
    @Binding var mapEngineRaw: String
    @State private var showLoadFallbackNote = false

    func body(content: Content) -> some View {
        content
            // 3D globe load watchdog fired — fall back to 2D so the user isn't
            // stuck on an infinite spinner when the Cesium CDN is unreachable.
            .onReceive(NotificationCenter.default.publisher(for: .cesiumLoadTimedOut)) { _ in
                guard mapEngineRaw == MapEngine.cesium3D.rawValue else { return }
                mapEngineRaw = MapEngine.mapbox2D.rawValue
                withAnimation { showLoadFallbackNote = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    withAnimation { showLoadFallbackNote = false }
                }
            }
            .overlay(alignment: .top) {
                if showLoadFallbackNote {
                    Text("3D globe couldn't load — switched to 2D map")
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.top, 60)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuCenterMap)) { note in
                guard let coordinate = note.userInfo?["coordinate"] as? CLLocationCoordinate2D else { return }
                withAnimation {
                    mapRegion = MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                    )
                }
                NotificationCenter.default.post(
                    name: .cesiumCenterOn,
                    object: nil,
                    userInfo: ["lat": coordinate.latitude, "lon": coordinate.longitude]
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuDrawLine)) { _ in
                drawingManager.startDrawing(mode: .line)
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuDrawCircle)) { _ in
                drawingManager.startDrawing(mode: .circle)
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuDrawPolygon)) { _ in
                drawingManager.startDrawing(mode: .polygon)
            }
    }
}

// MARK: - CoT Marker

struct CoTMarker: Identifiable {
    let id = UUID()
    let uid: String
    let coordinate: CLLocationCoordinate2D
    let type: String
    let callsign: String
    let team: String
    /// Height above ellipsoid (m) for airborne tracks (air-dimension CoT).
    /// nil → clamp to ground. Drives the Cesium 3D altitude + TAK leader line.
    var hae: Double? = nil
    /// Issue #75 — `usericon iconsetpath` from the incoming CoT (e.g.
    /// `COT_MAPPING_SPOTMAP/red`), so a received spot-map / iconset marker
    /// resolves to the right TAK icon instead of a generic affiliation frame.
    var iconsetPath: String? = nil
    /// Issue #75 — signed ARGB color from the CoT `<color>` element. Spot-map
    /// points carry their color here rather than in the type.
    var argbColor: Int? = nil
}

struct CoTMarkerView: View {
    let marker: CoTMarker

    var body: some View {
        VStack(spacing: 2) {
            // Icon based on type
            Image(systemName: markerIcon)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(markerColor)
                .shadow(color: .black, radius: 2)

            // Callsign
            Text(marker.callsign)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(markerColor.opacity(0.8))
                .cornerRadius(4)
                .shadow(color: .black, radius: 1)
        }
    }

    private var markerIcon: String {
        if marker.type.contains("a-f") {
            return "shield.fill"  // Friendly
        } else if marker.type.contains("a-h") {
            return "exclamationmark.triangle.fill"  // Hostile
        } else {
            return "questionmark.circle.fill"  // Unknown
        }
    }

    private var markerColor: Color {
        if marker.type.contains("a-f") {
            return .cyan  // Friendly = cyan (ATAK standard)
        } else if marker.type.contains("a-h") {
            return .red  // Hostile = red
        } else {
            return .yellow  // Unknown = yellow
        }
    }
}

// MARK: - View Extensions

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content) -> some View {

        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}


// MARK: - Point Drop aim crosshair

/// Center crosshair shown while the Point Dropper is open. The marker drops at
/// the map center this marks — pan the map to aim, tap an affiliation to drop.
private struct PointDropCrosshair: View {
    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.9), lineWidth: 2).frame(width: 46, height: 46)
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 2, height: 16).offset(y: -30)
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 2, height: 16).offset(y: 30)
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 16, height: 2).offset(x: -30)
            Rectangle().fill(Color.white.opacity(0.9)).frame(width: 16, height: 2).offset(x: 30)
            Circle().fill(Color.cyan).frame(width: 6, height: 6)
        }
        .shadow(color: .black.opacity(0.7), radius: 2)
    }
}
