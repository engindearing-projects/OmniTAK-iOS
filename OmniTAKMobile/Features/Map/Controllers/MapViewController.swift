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
    @StateObject private var federation = MultiServerFederation()  // Multi-server support
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
    // cesium3DBody for the self-position label.)

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
            let marker = CoTMarker(
                uid: event.uid,
                coordinate: CLLocationCoordinate2D(
                    latitude: event.point.lat,
                    longitude: event.point.lon
                ),
                type: event.type,
                callsign: event.detail.callsign,
                team: event.detail.team ?? "Unknown"
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
            onMapTap: handleMapTap
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
            .id("statusbar-\(takService.isConnected)-\(takService.connectedServerIds.count)-\(takService.messagesReceived)-\(takService.messagesSent)")

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
                    showFriendly: $showFriendly,
                    showHostile: $showHostile,
                    showNeutral: $showNeutral,
                    showUnknown: $showUnknown,
                    showCompass: $showCompass,
                    showCoordinates: $showCoordinates,
                    showScaleBar: $showScaleBar,
                    showGrid: $showGrid,
                    showCallsignPanel: $showCallsignPanel,
                    adsbService: ADSBTrafficService.shared,
                    onLayerToggle: { layer in
                        toggleLayer(layer)
                    },
                    onOverlayToggle: { overlay in
                        toggleOverlay(overlay)
                    },
                    onMapOverlayToggle: { overlay in
                        toggleMapOverlay(overlay)
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
        CompassOverlayView(
            heading: compassHeading,
            isVisible: showCompass
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

    @ViewBuilder
    private var interactiveOverlays: some View {
        Group {
            loadingScreen
            radialMenu
            cursorModeOverlay
            lassoSelectionPill  // Issue #16
            // overlaySettingsButton - Removed per user request
            // overlaySettingsPanel - Removed per user request
            // mapCenterDisplay - Removed per user request (coords available via radial menu)
        }
    }

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
        // Modal sheets / error overlays / lifecycle + radial-menu observers
        // attach here at the body level so they're mounted on BOTH engines.
        // They used to be chained on mapbox2DBody's ZStack, which meant
        // every radial-menu action (Layers, Drawings, Lasso, etc.) silently
        // no-op'd on Cesium 3D — the notification fired but no subscriber.
        Group {
            switch mapEngine {
            case .cesium3D: cesium3DBody
            case .mapbox2D: mapbox2DBody
            }
        }
        .background(modalSheets)
        .background(errorOverlays)
        .background(lifecycleHandlers)
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

    /// Phase 1: render the Cesium scene full-screen behind the existing top
    /// chrome (status bar / server indicator) and the new engine-toggle FAB.
    /// CoT entities, drawings, MGRS grid, lasso, etc. are 2D-only for now —
    /// Phase 2 wires a JS bridge that pushes them into Cesium as Entity
    /// objects at real altitude.
    @ViewBuilder
    private var cesium3DBody: some View {
        // Default ZStack alignment (.center) — matches mapbox2DBody so the
        // side panels' inner HStack { panel; Spacer() } gets full width to
        // push the panel against the leading edge. With .bottomLeading
        // alignment the HStack collapsed to content size and the Layers
        // panel never appeared even though showLayersPanel was true.
        ZStack {
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
                selfCallsign: userCallsign,
                // Phase 3b — saved distance / area measurements mirrored
                // through the Cesium bridge as dashed polylines + segment
                // labels. The live in-progress measurement stays Mapbox-
                // only; Cesium only sees committed sessions.
                measurements: measurementManager.savedMeasurements,
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
            statusIndicators
            // Side panels (Layers / Drawing Tools / Drawing List). Without
            // this, the radial menu's "Layers" / "Drawings" entries silently
            // flipped their state booleans on Cesium 3D but no panel ever
            // appeared. Some toggles inside the layers panel (satellite /
            // hybrid / standard base layers) don't apply to the 3D engine,
            // but the affiliation, overlay, and ADSB toggles all bridge
            // through to the Cesium scene.
            sidePanels
            // Phase 4a — surface the same radial menu over the Cesium
            // scene. `radialMenu` is the same view the 2D Mapbox path
            // uses (interactiveOverlays group); reusing it keeps the
            // look + executeAction wiring identical across engines.
            radialMenu
            // GPS follow toggle — the same control the 2D map has. Without
            // it the operator had no way to enable follow on the globe, so
            // the camera never tracked them here.
            gpsFollowButton
            // 2D→3D parity chrome: top status bar + bottom toolbar, and the
            // compass + scale-bar overlay group. All engine-agnostic except
            // the scale bar, which reads mapRegion — kept accurate on Cesium
            // by syncing mapRegion from the camera in handleCesiumMapEvent.
            topToolbars
            mapOverlayComponents
            // Point Dropper aim crosshair — full-screen-centered so it sits at
            // the globe point reported as the screen-center pick, which is the
            // coordinate the drop uses (via mapRegion → MapCenterStore).
            if pointDropAim.isAiming {
                Color.clear
                    .overlay(PointDropCrosshair())
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .zIndex(900)
            }
            // Lasso selection pill — shows the selected count + actions
            // (Export / Delete / Clear) after a lasso. Without it on the
            // Cesium body, a 3D lasso selected items but gave no feedback.
            lassoSelectionPill
            // Engine toggle lives in the Tools sheet (id: "engine") rather
            // than a standalone FAB — operators expect mode toggles in the
            // Tools tray, and we keep the map chrome uncluttered.
        }
    }

    @ViewBuilder
    private var mapbox2DBody: some View {
        ZStack {
            mainMapView
            gridOverlay
            // Point Dropper aim crosshair — drop lands where this sits.
            if pointDropAim.isAiming {
                // Center the crosshair on the map's full-screen geometric
                // center so it coincides with the camera-center coordinate
                // the drop uses. The map ignores safe area (fills the
                // screen); without this full-screen container the crosshair
                // would center in the safe-area frame instead, sitting below
                // true center — so the marker dropped above the crosshair.
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
            interactiveOverlays
            gpsFollowButton

            // Compact measurement overlay (ATAK-style)
            if showMeasurement {
                CompactMeasurementOverlay(manager: measurementManager, isPresented: $showMeasurement)
                    .zIndex(1000)
            }

            // Route Navigation Panel (ATAK-style, top-left position)
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
        // Modal sheets, error overlays, lifecycle handlers, and the radial-
        // menu .onReceive observers used to chain here but moved up to the
        // body switch so they fire on both engines (Cesium 3D + Mapbox 2D).
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
            let nonContactPrefixes = ["ads-", "line-", "poly-", "circ-", "rring-", "meas-", "trail-"]
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

    private func sendSelfPosition() {
        guard let location = locationManager.location else { return }

        // Send to all connected servers via federation
        if federation.getConnectedCount() > 0 {
            let cotEvent = CoTEvent(
                uid: "SELF-\(UUID().uuidString)",
                type: "a-f-G-E-S",
                time: Date(),
                point: CoTPoint(
                    lat: location.coordinate.latitude,
                    lon: location.coordinate.longitude,
                    hae: location.altitude,
                    ce: location.horizontalAccuracy,
                    le: location.verticalAccuracy
                ),
                detail: CoTDetail(
                    callsign: "OmniTAK-iOS",
                    team: "Cyan",
                    speed: location.speed >= 0 ? location.speed : nil,
                    course: location.course >= 0 ? location.course : nil,
                    remarks: nil,
                    battery: 100,
                    device: "iPhone",
                    platform: "OmniTAK"
                )
            )

            federation.broadcast(event: cotEvent)
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

    // MARK: - Formatting Helpers

    private func formatCoordinates(_ coordinate: CLLocationCoordinate2D) -> String {
        // Convert to MGRS-style format (simplified)
        let lat = abs(coordinate.latitude)
        let lon = abs(coordinate.longitude)
        let latDeg = Int(lat)
        let lonDeg = Int(lon)
        let latMin = Int((lat - Double(latDeg)) * 60)
        let lonMin = Int((lon - Double(lonDeg)) * 60)
        let latSec = Int(((lat - Double(latDeg)) * 60 - Double(latMin)) * 60)
        let lonSec = Int(((lon - Double(lonDeg)) * 60 - Double(lonMin)) * 60)

        return "11T MN \(latDeg)\(latMin)\(latSec) \(lonDeg)\(lonMin)\(lonSec)"
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

    // Multi-server connection status for status bar
    private func multiServerConnectionStatus() -> String {
        let connectedCount = federation.getConnectedCount()
        let totalCount = federation.getTotalCount()

        if connectedCount == 0 {
            return "Disconnected"
        } else if connectedCount == 1 {
            if let connectedServer = federation.servers.first(where: { $0.status == .connected }) {
                return "Connected - \(connectedServer.name)"
            }
            return "Connected"
        } else {
            return "Connected to \(connectedCount)/\(totalCount) servers"
        }
    }

    // Multi-server display name for status bar
    private func multiServerDisplayName() -> String? {
        let connectedCount = federation.getConnectedCount()

        if connectedCount == 0 {
            return ServerManager.shared.activeServer?.name
        } else if connectedCount == 1 {
            return federation.servers.first(where: { $0.status == .connected })?.name
        } else {
            let connectedNames = federation.servers
                .filter { $0.status == .connected }
                .map { $0.name }
                .prefix(2)
                .joined(separator: ", ")
            return connectedCount > 2 ? "\(connectedNames) +\(connectedCount - 2)" : connectedNames
        }
    }

    private func generateSelfCoT(location: CLLocation) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let stale = ISO8601DateFormatter().string(from: Date().addingTimeInterval(300))

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <event version="2.0" uid="SELF-\(UUID().uuidString)" type="a-f-G-E-S" how="m-g" time="\(now)" start="\(now)" stale="\(stale)">
            <point lat="\(location.coordinate.latitude)" lon="\(location.coordinate.longitude)" hae="\(location.altitude)" ce="\(location.horizontalAccuracy)" le="\(location.verticalAccuracy)"/>
            <detail>
                <contact callsign="OmniTAK-iOS" endpoint="*:-1:stcp"/>
                <__group name="Cyan" role="Team Member"/>
                <status battery="100"/>
                <takv device="iPhone" platform="OmniTAK" os="iOS" version="\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0")"/>
                <track speed="\(location.speed)" course="\(location.course)"/>
            </detail>
        </event>
        """
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

// MARK: - ATAK Status Bar

struct ATAKStatusBar: View {
    let connectionStatus: String
    let isConnected: Bool
    let messagesReceived: Int
    let messagesSent: Int
    let gpsAccuracy: Double
    let serverName: String?
    /// Per-enabled-server connection state, in display order. Drives the
    /// multi-server indicator when more than one server is enabled.
    var serverConnectedFlags: [Bool] = []
    let onServerTap: () -> Void
    let onMenuTap: () -> Void

    /// 24-hour tactical clock used by the top status strip — keeps the
    /// iOS bar in sync with the Android `timeLabel` (e.g. `19:03`).
    static let timeLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    @Environment(\.verticalSizeClass) var verticalSizeClass

    // Portrait mode detection
    var isPortrait: Bool {
        verticalSizeClass == .regular
    }

    var body: some View {
        HStack(spacing: isPortrait ? 8 : 12) {
            // Compact OmniTAK branding with status indicator
            HStack(spacing: 4) {
                // LED-style connection indicator
                Circle()
                    .fill(isConnected ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                    .shadow(color: isConnected ? .green : .red, radius: 3)

                if !isPortrait {
                    Text("OmniTAK")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(Color(red: 1.0, green: 0.988, blue: 0.0))
                }
            }

            // Server Button (compact) — single server shows its name;
            // multiple enabled servers show "connected/total" + a dot per
            // server so the operator can see every link's state at a glance.
            Button(action: onServerTap) {
                if serverConnectedFlags.count > 1 {
                    let connected = serverConnectedFlags.filter { $0 }.count
                    let total = serverConnectedFlags.count
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack").font(.system(size: 9))
                        Text("\(connected)/\(total)")
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                        HStack(spacing: 2) {
                            ForEach(Array(serverConnectedFlags.enumerated()), id: \.offset) { _, up in
                                Circle()
                                    .fill(up ? Color.green : Color.gray.opacity(0.6))
                                    .frame(width: 5, height: 5)
                            }
                        }
                    }
                    .foregroundColor(connected == total ? .green : (connected > 0 ? .yellow : .gray))
                } else {
                    HStack(spacing: 2) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 9))
                        Text(serverName ?? "Offi...")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(isConnected ? .green : .gray)
                }
            }

            // Messages (compact) — text arrows match Android ATAKStatusBar
            HStack(spacing: 2) {
                Text("↓")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 0.13, green: 0.59, blue: 0.95))
                Text("\(messagesReceived)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 0.13, green: 0.59, blue: 0.95))
            }

            HStack(spacing: 2) {
                Text("↑")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.63, blue: 0.0))
                Text("\(messagesSent)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Color(red: 1.0, green: 0.63, blue: 0.0))
            }

            Spacer()

            // GPS Status (compact)
            HStack(spacing: 2) {
                Image(systemName: gpsAccuracy < 10 ? "location.fill" : "location.slash.fill")
                    .font(.system(size: 9))
                Text(String(format: "±%.0fm", gpsAccuracy))
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(gpsAccuracy < 10 ? .green : .yellow)

            // Time (compact) — 24h tactical, matches Android
            Text(ATAKStatusBar.timeLabelFormatter.string(from: Date()))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            // Hamburger Menu Button (compact)
            Button(action: onMenuTap) {
                VStack(spacing: 2) {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 18, height: 2)
                        .cornerRadius(1)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 18, height: 2)
                        .cornerRadius(1)
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 18, height: 2)
                        .cornerRadius(1)
                }
                .frame(width: 32, height: 32)
            }
            .accessibilityIdentifier("mainMenuButton")
            .accessibilityLabel("Main Menu")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.5))  // Translucent background
    }
}

// MARK: - ATAK Bottom Toolbar

struct ATAKBottomToolbar: View {
    @Binding var mapType: MKMapType
    @Binding var showLayersPanel: Bool
    @Binding var showDrawingPanel: Bool
    @Binding var showDrawingList: Bool
    let onZoomIn: () -> Void
    let onZoomOut: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Zoom Controls only - Draw/Drawings accessible via radial menu long-press
            VStack(spacing: 4) {
                MapToolButton(icon: "plus", label: "", compact: true) {
                    onZoomIn()
                }
                MapToolButton(icon: "minus", label: "", compact: true) {
                    onZoomOut()
                }
            }

            Spacer()

            // Draw and Drawings buttons removed - accessible via radial menu (long-press on map)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// Map Tool Button Component
struct MapToolButton: View {
    let icon: String
    let label: String
    var compact: Bool = false
    var isActive: Bool = false
    let action: () -> Void
    @State private var isPressed = false

    var body: some View {
        Button(action: {
            // Haptic feedback
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            action()
        }) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 14 : 18, weight: .semibold))
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 8, weight: .medium))
                }
            }
            .foregroundColor(isActive ? Color(hex: "#FFFC00") : .white)
            .frame(width: compact ? 32 : 50, height: compact ? 32 : 50)
            .background(
                isActive ? Color(hex: "#FFFC00").opacity(0.3) :
                isPressed ? Color.cyan.opacity(0.5) : Color.black.opacity(0.6)
            )
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isActive ? Color(hex: "#FFFC00") : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
            .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - ATAK Side Panel

struct ATAKSidePanel: View {
    @Binding var isExpanded: Bool
    @Binding var activeMapLayer: String
    @Binding var showFriendly: Bool
    @Binding var showHostile: Bool
    @Binding var showNeutral: Bool
    @Binding var showUnknown: Bool
    @Binding var showCompass: Bool
    @Binding var showCoordinates: Bool
    @Binding var showScaleBar: Bool
    @Binding var showGrid: Bool
    @Binding var showCallsignPanel: Bool
    @ObservedObject var adsbService: ADSBTrafficService
    let onLayerToggle: (String) -> Void
    let onOverlayToggle: (String) -> Void
    let onMapOverlayToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                // Compact header with close button
                HStack {
                    Text("LAYERS")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: {
                        withAnimation(.spring()) {
                            isExpanded = false
                        }
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.white.opacity(0.7))
                            .font(.system(size: 16))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)

                LayerButton(icon: "map", title: "Satellite", isActive: activeMapLayer == "satellite", compact: true) {
                    onLayerToggle("satellite")
                }
                LayerButton(icon: "map.fill", title: "Hybrid", isActive: activeMapLayer == "hybrid", compact: true) {
                    onLayerToggle("hybrid")
                }
                LayerButton(icon: "map.circle", title: "Standard", isActive: activeMapLayer == "standard", compact: true) {
                    onLayerToggle("standard")
                }

                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.vertical, 4)

                Text("UNITS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)

                LayerButton(icon: "shield.fill", title: "Friendly", isActive: showFriendly, compact: true) {
                    onOverlayToggle("friendly")
                }
                LayerButton(icon: "exclamationmark.triangle.fill", title: "Hostile", isActive: showHostile, compact: true) {
                    onOverlayToggle("hostile")
                }
                LayerButton(icon: "circle.fill", title: "Neutral", isActive: showNeutral, compact: true) {
                    onOverlayToggle("neutral")
                }
                LayerButton(icon: "questionmark.circle.fill", title: "Unknown", isActive: showUnknown, compact: true) {
                    onOverlayToggle("unknown")
                }

                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.vertical, 4)

                Text("MAP OVERLAYS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)

                LayerButton(icon: "safari", title: "Compass", isActive: showCompass, compact: true) {
                    onMapOverlayToggle("compass")
                }
                LayerButton(icon: "location.circle", title: "Coordinates", isActive: showCoordinates, compact: true) {
                    onMapOverlayToggle("coordinates")
                }
                LayerButton(icon: "ruler", title: "Scale Bar", isActive: showScaleBar, compact: true) {
                    onMapOverlayToggle("scale")
                }
                LayerButton(icon: "person.text.rectangle.fill", title: "Callsign Card", isActive: showCallsignPanel, compact: true) {
                    onMapOverlayToggle("callsign")
                }

                Divider()
                    .background(Color.white.opacity(0.3))
                    .padding(.vertical, 4)

                Text("DATA FEEDS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)

                LayerButton(
                    icon: "airplane.circle.fill",
                    title: "ADS-B",
                    isActive: adsbService.settings.isEnabled,
                    compact: true
                ) {
                    var settings = adsbService.settings
                    settings.isEnabled.toggle()
                    adsbService.settings = settings
                }

                if adsbService.settings.isEnabled {
                    HStack {
                        Text("\(adsbService.aircraft.count) aircraft")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                }
            }
            .frame(width: 160)
            .padding(.vertical, 8)
            .padding(.bottom, 8)
        }
        .animation(.spring(), value: isExpanded)
    }
}

struct LayerButton: View {
    let icon: String
    let title: String
    let isActive: Bool
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 6 : 8) {
                Image(systemName: icon)
                    .font(.system(size: compact ? 12 : 14))
                    .frame(width: compact ? 16 : 20)
                Text(title)
                    .font(.system(size: compact ? 11 : 13))
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: compact ? 12 : 14))
                        .foregroundColor(.green)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 6 : 8)
            .background(isActive ? Color.green.opacity(0.2) : Color.clear)
            .cornerRadius(6)
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

// MARK: - Location Manager

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationManager()

    private let manager = CLLocationManager()
    @Published var location: CLLocation?
    @Published var accuracy: Double = 0
    @Published var heading: CLHeading?
    @Published var course: Double = 0
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest

        // Enable background location updates for navigation and position tracking
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true

        // Request authorization - start with when in use, then prompt for always
        requestLocationAuthorization()

        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    /// Request location authorization with escalation to Always
    func requestLocationAuthorization() {
        let status = manager.authorizationStatus
        authorizationStatus = status

        switch status {
        case .notDetermined:
            // First request when in use, then iOS will prompt for upgrade
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            // Request upgrade to Always for background operation
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            // Already have full access
            break
        case .denied, .restricted:
            // User denied - they'll need to enable in Settings
            print("[LocationManager] Location access denied or restricted")
        @unknown default:
            break
        }
    }

    func startUpdating() {
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        DispatchQueue.main.async {
            self.authorizationStatus = status

            // If user just granted when-in-use, request always
            if status == .authorizedWhenInUse {
                // Slight delay before requesting upgrade
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    manager.requestAlwaysAuthorization()
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
        accuracy = locations.last?.horizontalAccuracy ?? 0
        course = locations.last?.course ?? 0
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[LocationManager] Location error: \(error.localizedDescription)")
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
    @ObservedObject var kmlVectorStore: KMLVectorOverlayStore = KMLVectorOverlayStore.shared
    @ObservedObject var rasterStore: RasterOverlayStore = RasterOverlayStore.shared
    @ObservedObject var mbtilesStore: MBTilesOverlayStore = MBTilesOverlayStore.shared
    let onMapTap: (CLLocationCoordinate2D) -> Void

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

        // Native user-location puck — replaces the custom self-position
        // MKAnnotation we used to maintain. Bullseye/MIL-STD style is
        // available via Mapbox v11 puck customisation if we want it
        // later.
        mapView.location.options.puckType = .puck2D()
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

        // Region sync — only push to Mapbox if the SwiftUI region
        // diverges from the camera state by more than a hair. This is
        // the same feedback-loop guard MKMapView needed.
        if !context.coordinator.isUserInteracting {
            let cameraState = mapView.mapboxMap.cameraState
            let centerChanged =
                abs(cameraState.center.latitude - region.center.latitude) > 0.0001 ||
                abs(cameraState.center.longitude - region.center.longitude) > 0.0001
            let zoomChanged = abs(cameraState.zoom - TacticalMapView.zoom(forSpan: region.span, mapHeight: mapView.bounds.height)) > 0.25
            if centerChanged || zoomChanged {
                context.coordinator.isProgrammaticUpdate = true
                // Explicitly preserve current pitch + bearing — MKCoordinateRegion
                // has no concept of either, so a naïve CameraOptions(center:zoom:)
                // would let Mapbox flatten the 3D camera back to top-down on every
                // SwiftUI re-invalidation.
                let opts = CameraOptions(
                    center: region.center,
                    zoom: TacticalMapView.zoom(forSpan: region.span, mapHeight: mapView.bounds.height),
                    bearing: cameraState.bearing,
                    pitch: cameraState.pitch
                )
                mapView.mapboxMap.setCamera(to: opts)
                context.coordinator.isProgrammaticUpdate = false
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

        // Camera feedback-loop guards
        var isUserInteracting = false
        var isProgrammaticUpdate = false

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
                self?.parent.region = newRegion
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
            ["kmlfill-\(overlayID)", "kmlline-\(overlayID)", "kmlpt-\(overlayID)"]
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
            var circle = CircleLayer(id: "kmlpt-\(overlay.id)", source: sourceID)
            circle.circleStrokeColor = .constant(StyleColor(.white))
            circle.circleStrokeWidth = .constant(1.0)
            try? map.addLayer(circle)
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
            let ptID = "kmlpt-\(overlay.id)"
            try? map.setLayerProperty(for: ptID, property: "visibility", value: vis)
            try? map.setLayerProperty(for: ptID, property: "circle-color", value: hex)
            try? map.setLayerProperty(for: ptID, property: "circle-opacity", value: overlay.opacity)
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
                let key = "cot|\(marker.type)|\(marker.callsign)"
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
                let key = "pm|\(pm.affiliation.rawValue)"
                var ann = PointAnnotation(id: "pm-\(pm.id.uuidString)", coordinate: pm.coordinate)
                ann.image = .init(image: img, name: key)
                ann.textField = pm.name
                ann.textAnchor = .top
                ann.textOffset = [0, 1.2]
                ann.textColor = StyleColor(.white)
                ann.textHaloColor = StyleColor(.black)
                ann.textHaloWidth = 1.0
                ann.textSize = 11
                // Affiliation glyphs are circular, so center them on the
                // coordinate. `.bottom` (for teardrop pins) made the circle
                // render above its point — markers appeared to drop above
                // the aim crosshair.
                ann.iconAnchor = .center
                fresh.append(ann)
            }
            manager.annotations = fresh
        }

        private func pointMarkerImage(for marker: PointMarker) -> UIImage {
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
        menuConfiguration = .markerContextMenu(for: marker)
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

// MARK: - Drawing Marker Annotation

class DrawingMarkerAnnotation: NSObject, MKAnnotation {
    let marker: MarkerDrawing
    var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?

    init(marker: MarkerDrawing) {
        self.marker = marker
        self.coordinate = marker.coordinate
        self.title = marker.label
        self.subtitle = "Marker"
        super.init()
    }
}

// MARK: - Drawing Label Annotation (for shapes)

class DrawingLabelAnnotation: NSObject, MKAnnotation {
    let ownerID: UUID
    var coordinate: CLLocationCoordinate2D
    var label: String
    var color: DrawingColor

    init(ownerID: UUID, coordinate: CLLocationCoordinate2D, label: String, color: DrawingColor) {
        self.ownerID = ownerID
        self.coordinate = coordinate
        self.label = label
        self.color = color
        super.init()
    }
}

// Tagged annotation for in-progress drawing points so the diff-based
// update can distinguish them from other MKPointAnnotations. Measurement
// uses MeasurementPointAnnotation from MeasurementService.swift.
class DrawingTempPointAnnotation: MKPointAnnotation {}

// MARK: - Overlay Settings Panel

struct OverlaySettingsPanel: View {
    @ObservedObject var overlayCoordinator: MapOverlayCoordinator
    @ObservedObject var mapStateManager: MapStateManager

    @Binding var showMGRSGrid: Bool
    @Binding var showBreadcrumbTrails: Bool
    @Binding var showRBLines: Bool

    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("OVERLAYS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.system(size: 16))
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            // MGRS Grid Toggle
            OverlayToggleButton(
                icon: "grid",
                title: "MGRS Grid",
                isActive: showMGRSGrid
            ) {
                showMGRSGrid.toggle()
                overlayCoordinator.saveSettings()
            }

            // Grid Density Picker (only show when grid is active)
            if showMGRSGrid {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grid Density")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.gray)
                        .padding(.horizontal, 10)

                    Picker("Density", selection: $overlayCoordinator.mgrsGridDensity) {
                        ForEach(MGRSGridDensity.allCases) { density in
                            Text(density.rawValue).tag(density)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal, 10)
                }
            }

            Divider()
                .background(Color.white.opacity(0.3))
                .padding(.vertical, 4)

            // Breadcrumb Trails Toggle
            OverlayToggleButton(
                icon: "point.topleft.down.curvedto.point.bottomright.up",
                title: "Breadcrumb Trails",
                isActive: showBreadcrumbTrails
            ) {
                showBreadcrumbTrails.toggle()
                overlayCoordinator.saveSettings()
            }

            // R&B Lines Toggle
            OverlayToggleButton(
                icon: "arrow.triangle.swap",
                title: "R&B Lines",
                isActive: showRBLines
            ) {
                showRBLines.toggle()
                overlayCoordinator.saveSettings()
            }

            Divider()
                .background(Color.white.opacity(0.3))
                .padding(.vertical, 4)

            // Current Map Center MGRS
            VStack(alignment: .leading, spacing: 4) {
                Text("MAP CENTER")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.gray)

                Text(overlayCoordinator.currentCenterMGRS.isEmpty ? "--" : overlayCoordinator.currentCenterMGRS)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.cyan)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        .frame(width: 200)
        .background(Color.black.opacity(0.9))
        .cornerRadius(12)
    }
}

// MARK: - Overlay Toggle Button

struct OverlayToggleButton: View {
    let icon: String
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            // Haptic feedback
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.impactOccurred()
            action()
        }) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 12))
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.green)
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isActive ? Color.green.opacity(0.2) : Color.clear)
            .cornerRadius(6)
        }
    }
}

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
    enum Kind { case tap, longpress, cameraChanged, lasso }
    let kind: Kind
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

    struct CameraState {
        let height: Double      // metres above ellipsoid
        let heading: Double     // degrees CW from north
        let pitch: Double       // degrees (negative = looking down)
        let zoom: Double        // Mapbox-style zoom, derived from height
    }
}

extension Notification.Name {
    /// Posted by the toolbar zoom buttons so the Cesium coordinator can zoom
    /// the globe's camera (mapRegion can't drive it). userInfo["factor"]: Double.
    static let cesiumZoom = Notification.Name("cesiumZoom")
    /// Posted by `handleCenterMapOnContact` so the Cesium coordinator can fly
    /// the globe's camera to a contact's position (mapRegion only drives the
    /// 2D engine). userInfo["lat"]: Double, userInfo["lon"]: Double.
    static let cesiumCenterOn = Notification.Name("cesiumCenterOn")
}

struct CesiumMainMap: UIViewRepresentable {
    let contacts: [CoTMarker]
    let aircraft: [Aircraft]
    let lineDrawings: [LineDrawing]
    let circleDrawings: [CircleDrawing]
    let polygonDrawings: [PolygonDrawing]
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
    /// Base imagery layer for the globe ("satellite" | "hybrid" | "standard").
    var baseLayer: String = "satellite"
    let selfCallsign: String
    // Phase 3b — measurement sessions to mirror as dashed polylines with
    // per-segment distance labels. Sourced from `MeasurementManager`.
    let measurements: [Measurement]
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

        webView.loadHTMLString(CesiumMainMap.html, baseURL: URL(string: "https://cesium.com/"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        let entities = buildEntityJSON()
        let drawings = buildDrawingJSON()
        let measurementsJSON = buildMeasurementJSON()
        let trailsJSON = buildTrailJSON()
        context.coordinator.lastSnapshot = entities
        context.coordinator.lastDrawingsSnapshot = drawings
        context.coordinator.lastMeasurementsSnapshot = measurementsJSON
        context.coordinator.lastTrailsSnapshot = trailsJSON
        if context.coordinator.isReady {
            webView.evaluateJavaScript("window.OmniBridge.setEntities(\(entities));", completionHandler: nil)
            // Dedup drawings + measurements bridge calls — `updateUIView`
            // fires on every SwiftUI re-render, which a camera tick triggers
            // via published region updates. Without this guard the WKWebView
            // re-applies identical drawing/measurement payloads on every
            // pan/zoom frame, which causes visible label + waypoint flicker
            // on the 3D globe — same anti-pattern fixed on the 2D path via
            // `shouldPublish(layer:signature:)` in commit c9855f0.
            if context.coordinator.shouldPublishBridge(call: "setDrawings", signature: drawings.hashValue) {
                webView.evaluateJavaScript("window.OmniBridge.setDrawings(\(drawings));", completionHandler: nil)
            }
            if context.coordinator.shouldPublishBridge(call: "setMeasurements", signature: measurementsJSON.hashValue) {
                webView.evaluateJavaScript("window.OmniBridge.setMeasurements(\(measurementsJSON));", completionHandler: nil)
            }
            webView.evaluateJavaScript("window.OmniBridge.setTrails(\(trailsJSON));", completionHandler: nil)

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

            // Base layer (imagery) — swap the globe's imagery on change so the
            // layers panel's Satellite/Hybrid/Standard work on 3D too.
            if baseLayer != context.coordinator.lastBaseLayer {
                context.coordinator.lastBaseLayer = baseLayer
                webView.evaluateJavaScript("window.OmniBridge.setBaseLayer({type:'\(baseLayer)'});", completionHandler: nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var parent: CesiumMainMap
        weak var webView: WKWebView?
        var isReady = false
        var lastSnapshot: String = "[]"
        var lastDrawingsSnapshot: String = "[]"
        var lastMeasurementsSnapshot: String = "[]"
        var lastTrailsSnapshot: String = "[]"
        /// Last coordinate we recentered on in follow mode (dedupe key).
        var lastFollowKey: String?
        /// Whether follow was active last render (to release lookAt on exit).
        var wasFollowing = false
        /// Whether lasso mode was active last render (to toggle on transition).
        var lassoWasActive = false
        /// Last base imagery layer pushed to the globe (swap on change).
        var lastBaseLayer = "satellite"
        /// Observer token for toolbar zoom commands forwarded to the bridge.
        var zoomObserver: NSObjectProtocol?
        /// Observer token for "Show on Map" (contact-centering) commands.
        var centerOnObserver: NSObjectProtocol?

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
        }

        init(_ parent: CesiumMainMap) {
            self.parent = parent
            super.init()
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "omniBridgeReady":
                isReady = true
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
                let event = CesiumMapEvent(
                    kind: kind,
                    coordinate: CLLocationCoordinate2D(latitude: payload.lat, longitude: payload.lon),
                    screenPoint: CGPoint(x: payload.screenX ?? 0, y: payload.screenY ?? 0),
                    entityUid: payload.uid,
                    camera: cameraState,
                    centerCoordinate: centerCoord,
                    polygon: polygon
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
    }

    private func buildEntityJSON() -> String {
        var all: [BridgeEntity] = []

        if let loc = selfLocation {
            all.append(BridgeEntity(
                uid: "__self__",
                lat: loc.coordinate.latitude,
                lon: loc.coordinate.longitude,
                hae: loc.altitude > 0 ? loc.altitude : nil,
                callsign: selfCallsign,
                affiliation: "f",
                kind: "self",
                heading: nil,
                // Self renders as a friendly ground combat unit so milsymbol
                // draws the standard friendly frame the operator expects.
                sidc: "SFGPUCI----"
            ))
        }

        for c in contacts {
            all.append(BridgeEntity(
                uid: c.uid,
                lat: c.coordinate.latitude,
                lon: c.coordinate.longitude,
                hae: nil, // Phase 2 has no HAE for contacts yet — clamps to ground
                callsign: c.callsign,
                affiliation: CesiumMainMap.affiliation(fromCoTType: c.type),
                kind: "contact",
                heading: nil,
                // SIDC from the existing CoT→2525 mapping service — same
                // mapping the 2D Mapbox / MapKit paths use, so a contact
                // reads identically across all engines.
                sidc: MilStdIconService.shared.getSIDC(for: c.type)
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
                sidc: nil
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
                sidc: MilStdIconService.shared.getSIDC(for: pm.cotType)
            ))
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

        guard let data = try? JSONEncoder().encode(all),
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

    private static let cesiumIonToken =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiI3NDUwNGNjMy05ZGM2LTRhNjgtYWY1ZS0xNjdjMTI0OTYxMjYiLCJpZCI6NDMyNTU0LCJpc3MiOiJodHRwczovL2lvbi5jZXNpdW0uY29tIiwiYXVkIjoidW5kZWZpbmVkX2RlZmF1bHQiLCJpYXQiOjE3Nzg5OTYwNzd9.4MTmIKjioTboeXn02fm7i7Ftude-JVIg3RYW4jgIZ48"

    /// HTML kept in lockstep with `OmniTAK-Android/app/src/main/assets/cesium_scene.html`.
    /// When you change one, change both. Phase 4 will dedupe by bundling a
    /// shared resource.
    static var html: String {
        """
        <!DOCTYPE html><html lang=\"en\"><head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover\">
        <link href=\"https://cesium.com/downloads/cesiumjs/releases/1.124/Build/Cesium/Widgets/widgets.css\" rel=\"stylesheet\">
        <style>
          /* Pin to viewport in pixels via JS — see _fitViewport. Android
             WebView (after loadDataWithBaseURL) resolves 100%/100vh to 0,
             and Cesium captures that as canvas size at construction.
             Same fix on iOS is a no-op but keeps the HTML platform-shared. */
          /* Kill iOS WKWebView's default text-selection callout (Copy /
             Translate / Copy Link with Highlight) on long-press over the
             3D map — it otherwise stacks on top of our radial menu. Apply
             on body only so Cesium's canvas-bound long-press JS still
             fires (the universal `*` form blocked pointer events). */
          html,body{margin:0;padding:0;overflow:hidden;background:#000;color:#fff;font-family:-apple-system,BlinkMacSystemFont,sans-serif;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none}
          #cesiumContainer{position:fixed;top:0;left:0}
          #loading{position:absolute;top:50%;left:0;right:0;text-align:center;transform:translateY(-50%);z-index:10;pointer-events:none}
          .dot{display:inline-block;width:12px;height:12px;border-radius:50%;background:#FFCC00;margin:0 4px;animation:p 1.4s infinite}
          .dot:nth-child(2){animation-delay:.2s}.dot:nth-child(3){animation-delay:.4s}
          @keyframes p{0%,80%,100%{opacity:.3}40%{opacity:1}}
          .label{margin-top:16px;font-size:14px;opacity:.7}
          .cesium-viewer-bottom{display:none!important}
        </style></head><body>
        <div id=\"loading\"><span class=\"dot\"></span><span class=\"dot\"></span><span class=\"dot\"></span><div class=\"label\">Loading 3D world…</div></div>
        <div id=\"cesiumContainer\"></div>
        <canvas id=\"lassoCanvas\" style=\"position:fixed;top:0;left:0;pointer-events:none;z-index:20;display:none\"></canvas>
        <script src=\"https://cesium.com/downloads/cesiumjs/releases/1.124/Build/Cesium/Cesium.js\"></script>
        <script src=\"https://unpkg.com/milsymbol@2.2.0/dist/milsymbol.js\"></script>
        <script>
          Cesium.Ion.defaultAccessToken='\(cesiumIonToken)';
          const _state={ready:false,viewer:null,entities:new Map(),drawings:new Map(),measurements:new Map(),trails:new Map(),billboardCache:new Map(),lasso:{enabled:false,dragging:false,pts:[],handler:null}};
          // Lasso multi-select drag (issue #16, 3D parity). Camera pan is
          // disabled while the lasso is enabled; the freehand path is drawn on
          // a 2D overlay canvas and the screen points are picked to lat/lon on
          // release, posted to native as {event:'lasso',polygon:[[lat,lon]...]}.
          function _drawLasso(){const cv=document.getElementById('lassoCanvas');if(!cv)return;const ctx=cv.getContext('2d');if(!ctx)return;ctx.clearRect(0,0,cv.width,cv.height);const pts=_state.lasso.pts;if(pts.length<2)return;ctx.beginPath();ctx.moveTo(pts[0][0],pts[0][1]);for(let i=1;i<pts.length;i++)ctx.lineTo(pts[i][0],pts[i][1]);ctx.closePath();ctx.lineWidth=3;ctx.setLineDash([6,4]);ctx.strokeStyle='#FF9500';ctx.stroke();ctx.fillStyle='rgba(255,149,0,0.10)';ctx.fill();}
          function _finishLasso(){const v=_state.viewer;if(!v)return;_state.lasso.dragging=false;const pts=_state.lasso.pts.slice();const poly=[];for(const p of pts){const c=_cartoFor(v,new Cesium.Cartesian2(p[0],p[1]));if(c)poly.push([c.lat,c.lon]);}const cv=document.getElementById('lassoCanvas');if(cv){const ctx=cv.getContext('2d');ctx&&ctx.clearRect(0,0,cv.width,cv.height);}const f=poly.length?poly[0]:[0,0];_postMapEvent({event:'lasso',polygon:poly,lat:f[0],lon:f[1],count:poly.length});}
          // DOM touch capture on the overlay canvas — far more reliable than a
          // Cesium ScreenSpaceEventHandler, which stops delivering once camera
          // inputs are disabled. The canvas (pointer-events:auto when active)
          // also intercepts the touch so the globe never pans under the drag.
          function _lassoTouchStart(e){if(!_state.lasso.enabled)return;e.preventDefault();const t=e.touches[0];if(!t)return;_state.lasso.dragging=true;_state.lasso.pts=[[t.clientX,t.clientY]];_drawLasso();}
          function _lassoTouchMove(e){if(!_state.lasso.enabled||!_state.lasso.dragging)return;e.preventDefault();const t=e.touches[0];if(!t)return;_state.lasso.pts.push([t.clientX,t.clientY]);_drawLasso();}
          function _lassoTouchEnd(e){if(!_state.lasso.enabled||!_state.lasso.dragging)return;e.preventDefault();_finishLasso();}
          function _drawColor(hex,a){try{const c=Cesium.Color.fromCssColorString(hex||'#4ADE80');return a!==undefined?c.withAlpha(a):c}catch(e){return Cesium.Color.CYAN}}
          function _havDist(a,b){const R=6371000,lat1=a[1]*Math.PI/180,lat2=b[1]*Math.PI/180,dLat=(b[1]-a[1])*Math.PI/180,dLon=(b[0]-a[0])*Math.PI/180;const s=Math.sin(dLat/2)**2+Math.cos(lat1)*Math.cos(lat2)*Math.sin(dLon/2)**2;return 2*R*Math.asin(Math.min(1,Math.sqrt(s)))}
          function _fitViewport(){
            const w=window.innerWidth,h=window.innerHeight;
            document.body.style.width=w+'px';document.body.style.height=h+'px';
            const c=document.getElementById('cesiumContainer');
            if(c){c.style.width=w+'px';c.style.height=h+'px';}
            if(_state.viewer){_state.viewer.resize();_state.viewer.scene.requestRender();}
          }
          window.addEventListener('resize',_fitViewport);
          document.addEventListener('DOMContentLoaded',_fitViewport);
          function _color(a){return a==='f'?'#4ADE80':a==='h'?'#F44336':a==='n'?'#FFC107':'#B39DDB'}
          function _billboard(a,k,sidc){
            if(sidc&&window.ms&&k!=='aircraft'){const sk='sidc|'+sidc;if(_state.billboardCache.has(sk))return _state.billboardCache.get(sk);
              try{const sym=new window.ms.Symbol(sidc,{size:32,infoBackground:'transparent',infoColor:'white'});const url=sym.asCanvas().toDataURL('image/png');_state.billboardCache.set(sk,url);return url;}catch(e){console.warn('milsymbol failed for',sidc,e);}}
            const key=a+'|'+(k||'');if(_state.billboardCache.has(key))return _state.billboardCache.get(key);
            const c=document.createElement('canvas');c.width=56;c.height=56;const ctx=c.getContext('2d');
            const color=_color(a);ctx.lineWidth=4;ctx.strokeStyle=color;ctx.fillStyle=color+'55';
            if(k==='aircraft'){ctx.beginPath();ctx.moveTo(28,6);ctx.lineTo(46,48);ctx.lineTo(28,38);ctx.lineTo(10,48);ctx.closePath();ctx.fill();ctx.stroke();}
            else if(a==='f'){ctx.beginPath();ctx.arc(28,28,22,0,Math.PI*2);ctx.fill();ctx.stroke();}
            else if(a==='h'){ctx.beginPath();ctx.moveTo(28,4);ctx.lineTo(52,28);ctx.lineTo(28,52);ctx.lineTo(4,28);ctx.closePath();ctx.fill();ctx.stroke();}
            else if(a==='n'){ctx.fillRect(8,8,40,40);ctx.strokeRect(8,8,40,40);}
            else{ctx.beginPath();ctx.arc(20,28,10,0,Math.PI*2);ctx.arc(36,28,10,0,Math.PI*2);ctx.arc(28,20,10,0,Math.PI*2);ctx.arc(28,36,10,0,Math.PI*2);ctx.fill();ctx.stroke();}
            if(k!=='aircraft'){ctx.fillStyle=color;ctx.beginPath();ctx.arc(28,28,3,0,Math.PI*2);ctx.fill();}
            const url=c.toDataURL('image/png');_state.billboardCache.set(key,url);return url;
          }
          function _parse(x){return typeof x==='string'?(()=>{try{return JSON.parse(x)}catch(e){return null}})():x}
          function _hideLoading(){const el=document.getElementById('loading');if(el)el.style.display='none';}
          function _signalReady(){
            _state.ready=true;
            // Hide the spinner here too: the bootstrap flyTo's `complete`
            // callback used to be the only place that hid it, but the
            // native side immediately re-flies to a restored camera pose,
            // interrupting the bootstrap flyTo so its complete never
            // fires. Hide unconditionally once the viewer is ready.
            _hideLoading();
            try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.omniBridgeReady)window.webkit.messageHandlers.omniBridgeReady.postMessage('ready')}catch(e){}
            try{if(window.OmniBridgeNative&&window.OmniBridgeNative.onReady)window.OmniBridgeNative.onReady()}catch(e){}
          }
          // Phase 4a — Cesium → native event bridge. Posts tap + longpress
          // events with {event, lat, lon, hae, screenX, screenY, uid?} so
          // the native shell can drive radial-menu / contact-edit-sheet
          // workflows the same way the 2D Mapbox path does.
          function _postMapEvent(p){const j=JSON.stringify(p);
            try{if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.omniMapEvent)window.webkit.messageHandlers.omniMapEvent.postMessage(j)}catch(e){}
            try{if(window.OmniBridgeNative&&window.OmniBridgeNative.onMapEvent)window.OmniBridgeNative.onMapEvent(j)}catch(e){}
          }
          function _pickedUid(viewer,pos){const p=viewer.scene.pick(pos);return(p&&p.id&&typeof p.id.id==='string')?p.id.id:null}
          function _cartoFor(viewer,pos){let c=viewer.scene.pickPosition(pos);if(!Cesium.defined(c))c=viewer.camera.pickEllipsoid(pos,viewer.scene.globe.ellipsoid);if(!Cesium.defined(c))return null;const cc=Cesium.Cartographic.fromCartesian(c);return{lat:Cesium.Math.toDegrees(cc.latitude),lon:Cesium.Math.toDegrees(cc.longitude),hae:cc.height}}
          function _zoomFromHeight(h,latRad){const c=Math.max(Math.cos(latRad||0),0.01),mpp=(h*256)/1000.0,z=Math.log2(40075017*c/Math.max(mpp,1));return Math.max(0,Math.min(22,z))}
          function _postCameraChanged(v){const cam=v.camera,carto=cam.positionCartographic;if(!carto)return;const r=cam.computeViewRectangle(v.scene.globe.ellipsoid);
            // The point under the SCREEN CENTER (where the aim crosshair sits)
            // — distinct from the camera's sub-point when tilted. Used as the
            // point-drop coordinate and the scale-bar / region center.
            const cv=v.scene.canvas;const ctr=_cartoFor(v,new Cesium.Cartesian2(cv.clientWidth/2,cv.clientHeight/2));
            _postMapEvent({event:'camerachanged',lat:Cesium.Math.toDegrees(carto.latitude),lon:Cesium.Math.toDegrees(carto.longitude),height:carto.height,heading:Cesium.Math.toDegrees(cam.heading),pitch:Cesium.Math.toDegrees(cam.pitch),zoom:_zoomFromHeight(carto.height,carto.latitude),centerLat:ctr?ctr.lat:null,centerLon:ctr?ctr.lon:null,bounds:r?{north:Cesium.Math.toDegrees(r.north),south:Cesium.Math.toDegrees(r.south),east:Cesium.Math.toDegrees(r.east),west:Cesium.Math.toDegrees(r.west)}:null})}
          function _installInputHandlers(viewer){
            viewer.camera.moveEnd.addEventListener(function(){_postCameraChanged(viewer)});
            // Fire during continuous gestures (pinch-zoom / drag) too, so the
            // scale bar and coordinate readout track live, not just on settle.
            viewer.camera.percentageChanged=0.05;
            viewer.camera.changed.addEventListener(function(){_postCameraChanged(viewer)});
            const h=new Cesium.ScreenSpaceEventHandler(viewer.scene.canvas);
            h.setInputAction(function(click){const p=_cartoFor(viewer,click.position);if(!p)return;_postMapEvent({event:'tap',lat:p.lat,lon:p.lon,hae:p.hae,screenX:click.position.x,screenY:click.position.y,uid:_pickedUid(viewer,click.position)})},Cesium.ScreenSpaceEventType.LEFT_CLICK);
            let pressTimer=null,pressStart=null;
            h.setInputAction(function(down){pressStart=down.position;if(pressTimer)clearTimeout(pressTimer);pressTimer=setTimeout(function(){if(!pressStart)return;const p=_cartoFor(viewer,pressStart);if(!p)return;_postMapEvent({event:'longpress',lat:p.lat,lon:p.lon,hae:p.hae,screenX:pressStart.x,screenY:pressStart.y,uid:_pickedUid(viewer,pressStart)});pressStart=null},500)},Cesium.ScreenSpaceEventType.LEFT_DOWN);
            h.setInputAction(function(){if(pressTimer){clearTimeout(pressTimer);pressTimer=null}pressStart=null},Cesium.ScreenSpaceEventType.LEFT_UP);
            h.setInputAction(function(m){if(!pressStart)return;const dx=m.endPosition.x-pressStart.x,dy=m.endPosition.y-pressStart.y;if(Math.hypot(dx,dy)>8&&pressTimer){clearTimeout(pressTimer);pressTimer=null;pressStart=null}},Cesium.ScreenSpaceEventType.MOUSE_MOVE);
          }
          window.OmniBridge={
            upsertEntity(arg){const e=_parse(arg);if(!e||!e.uid||typeof e.lat!=='number'||typeof e.lon!=='number')return;const v=_state.viewer;if(!v)return;
              const hae=(typeof e.hae==='number'&&isFinite(e.hae))?e.hae:0;const useGround=hae===0;
              const pos=Cesium.Cartesian3.fromDegrees(e.lon,e.lat,hae);
              const rot=(typeof e.heading==='number')?-e.heading*Math.PI/180:0;
              let entity=_state.entities.get(e.uid);
              if(!entity){entity=v.entities.add({id:e.uid,position:pos,
                billboard:{image:_billboard(e.affiliation||'u',e.kind,e.sidc),verticalOrigin:Cesium.VerticalOrigin.CENTER,heightReference:useGround?Cesium.HeightReference.CLAMP_TO_GROUND:Cesium.HeightReference.NONE,disableDepthTestDistance:Number.POSITIVE_INFINITY,scale:e.kind==='aircraft'?1.5:0.7,rotation:rot},
                label:e.callsign?{text:e.callsign,font:'12px -apple-system, sans-serif',fillColor:Cesium.Color.WHITE,outlineColor:Cesium.Color.BLACK,outlineWidth:2,style:Cesium.LabelStyle.FILL_AND_OUTLINE,pixelOffset:new Cesium.Cartesian2(0,-32),heightReference:useGround?Cesium.HeightReference.CLAMP_TO_GROUND:Cesium.HeightReference.NONE,disableDepthTestDistance:Number.POSITIVE_INFINITY}:undefined,
              });_state.entities.set(e.uid,entity);}
              else{entity.position=pos;entity.billboard.image=_billboard(e.affiliation||'u',e.kind,e.sidc);entity.billboard.heightReference=useGround?Cesium.HeightReference.CLAMP_TO_GROUND:Cesium.HeightReference.NONE;entity.billboard.rotation=rot;if(entity.label&&e.callsign)entity.label.text=e.callsign;}
            },
            setEntities(arg){const list=_parse(arg);if(!Array.isArray(list))return;const seen=new Set();
              for(const e of list){if(e&&e.uid){seen.add(e.uid);window.OmniBridge.upsertEntity(e);}}
              for(const uid of Array.from(_state.entities.keys()))if(!seen.has(uid))window.OmniBridge.removeEntity(uid);
            },
            removeEntity(uid){const v=_state.viewer;if(!v)return;const e=_state.entities.get(uid);if(e){v.entities.remove(e);_state.entities.delete(uid);}},
            removeAll(){const v=_state.viewer;if(!v)return;v.entities.removeAll();_state.entities.clear();},
            flyTo(arg){const e=_parse(arg);if(!e)return;const v=_state.viewer;if(!v)return;
              v.camera.flyTo({destination:Cesium.Cartesian3.fromDegrees(e.lon,e.lat,(typeof e.range==='number')?e.range:5000),
                orientation:{heading:Cesium.Math.toRadians(e.heading||0),pitch:Cesium.Math.toRadians(typeof e.pitch==='number'?e.pitch:-30),roll:0},duration:1.2});
            },
            // GPS follow — frame the operator at SCREEN CENTER even when the
            // globe is tilted. Placing the camera straight over the user with
            // pitch pushed the marker to the bottom edge / off-screen; lookAt
            // orbits the camera around the user's ground position at the
            // current heading/pitch and the current camera-to-target distance
            // (so zoom/tilt are preserved and the marker stays centered).
            follow(arg){const e=_parse(arg);if(!e||typeof e.lat!=='number'||typeof e.lon!=='number')return;const v=_state.viewer;if(!v)return;
              const target=Cesium.Cartesian3.fromDegrees(e.lon,e.lat,0);
              let range=Cesium.Cartesian3.distance(v.camera.positionWC,target);
              if(!isFinite(range)||range<=0)range=v.camera.positionCartographic.height||5000;
              const heading=v.camera.heading,pitch=v.camera.pitch;
              v.camera.lookAt(target,new Cesium.HeadingPitchRange(heading,pitch,range));
            },
            // Release the lookAt reference frame so free pan/zoom works again
            // after the operator turns follow off.
            unfollow(){const v=_state.viewer;if(!v)return;v.camera.lookAtTransform(Cesium.Matrix4.IDENTITY);},
            // Toolbar zoom — move the camera along its view axis by the change
            // in height (factor<1 zooms in, >1 zooms out). Works whether or
            // not a lookAt follow transform is active.
            zoomBy(arg){const e=_parse(arg);if(!e)return;const v=_state.viewer;if(!v)return;
              const f=(typeof e.factor==='number'&&e.factor>0)?e.factor:1;
              const h=v.camera.positionCartographic.height;const amount=Math.abs(h-h*f);
              if(amount<1)return;
              if(f<1)v.camera.zoomIn(amount);else v.camera.zoomOut(amount);
            },
            // Lasso multi-select mode. While on, the overlay canvas captures
            // the single-finger drag (DOM touch events) and intercepts it so
            // the globe stays put; camera inputs are also disabled as a backup.
            setLassoMode(arg){const e=_parse(arg);const on=!!(e&&e.on);const v=_state.viewer;const cv=document.getElementById('lassoCanvas');if(!cv)return;
              if(on){
                _state.lasso.enabled=true;_state.lasso.dragging=false;_state.lasso.pts=[];
                cv.width=window.innerWidth;cv.height=window.innerHeight;cv.style.display='block';cv.style.pointerEvents='auto';
                cv.addEventListener('touchstart',_lassoTouchStart,{passive:false});
                cv.addEventListener('touchmove',_lassoTouchMove,{passive:false});
                cv.addEventListener('touchend',_lassoTouchEnd,{passive:false});
                cv.addEventListener('touchcancel',_lassoTouchEnd,{passive:false});
                if(v)v.scene.screenSpaceCameraController.enableInputs=false;
              }else{
                _state.lasso.enabled=false;_state.lasso.dragging=false;_state.lasso.pts=[];
                cv.removeEventListener('touchstart',_lassoTouchStart);
                cv.removeEventListener('touchmove',_lassoTouchMove);
                cv.removeEventListener('touchend',_lassoTouchEnd);
                cv.removeEventListener('touchcancel',_lassoTouchEnd);
                const ctx=cv.getContext('2d');ctx&&ctx.clearRect(0,0,cv.width,cv.height);
                cv.style.display='none';cv.style.pointerEvents='none';
                if(v)v.scene.screenSpaceCameraController.enableInputs=true;
              }
            },
            // Base imagery swap so the layers panel works on the globe:
            // satellite = Cesium World Imagery (aerial), standard = OSM streets,
            // hybrid = aerial with a translucent OSM streets/labels overlay.
            setBaseLayer(arg){const e=_parse(arg);const t=(e&&e.type)||'satellite';const v=_state.viewer;if(!v)return;
              try{
                const layers=v.imageryLayers;layers.removeAll();
                if(t==='standard'){
                  layers.addImageryProvider(new Cesium.OpenStreetMapImageryProvider({url:'https://tile.openstreetmap.org/'}));
                }else{
                  layers.add(Cesium.ImageryLayer.fromProviderAsync(Cesium.createWorldImageryAsync(),{}));
                  if(t==='hybrid'){const o=layers.addImageryProvider(new Cesium.OpenStreetMapImageryProvider({url:'https://tile.openstreetmap.org/'}));o.alpha=0.4;}
                }
                v.scene.requestRender();
              }catch(err){}
            },
            ping(){return _state.ready?'pong':'loading'},
            upsertDrawing(arg){const d=_parse(arg);if(!d||!d.uid||!d.kind||!Array.isArray(d.coords)||d.coords.length===0)return;const v=_state.viewer;if(!v)return;
              const color=_drawColor(d.color,0.85),fillC=_drawColor(d.color,0.25),width=typeof d.width==='number'?d.width:3;
              const useGround=!(typeof d.hae==='number'&&isFinite(d.hae)&&d.hae>0),hae=useGround?0:d.hae,heightRef=useGround?Cesium.HeightReference.CLAMP_TO_GROUND:Cesium.HeightReference.NONE;
              const prior=_state.drawings.get(d.uid);if(prior)v.entities.remove(prior);
              const opts={id:d.uid};
              if(d.kind==='line'){opts.polyline={positions:d.coords.map(c=>Cesium.Cartesian3.fromDegrees(c[0],c[1],hae)),width:width,material:color,clampToGround:useGround};}
              else if(d.kind==='polygon'){const positions=d.coords.map(c=>Cesium.Cartesian3.fromDegrees(c[0],c[1],hae));
                opts.polygon={hierarchy:new Cesium.PolygonHierarchy(positions),material:(d.filled===false)?undefined:fillC,outline:true,outlineColor:color,outlineWidth:width,heightReference:heightRef};
                if(useGround){opts.polyline={positions:[...positions,positions[0]],width:width,material:color,clampToGround:true};opts.polygon.outline=false;}}
              else if(d.kind==='circle'){if(d.coords.length<2)return;const center=d.coords[0],edge=d.coords[1],radius=_havDist(center,edge);
                opts.position=Cesium.Cartesian3.fromDegrees(center[0],center[1],hae);
                opts.ellipse={semiMajorAxis:radius,semiMinorAxis:radius,material:fillC,outline:true,outlineColor:color,outlineWidth:width,heightReference:heightRef};}
              else return;
              _state.drawings.set(d.uid,v.entities.add(opts));
            },
            setDrawings(arg){const list=_parse(arg);if(!Array.isArray(list))return;const seen=new Set();
              for(const d of list)if(d&&d.uid){seen.add(d.uid);window.OmniBridge.upsertDrawing(d);}
              const v=_state.viewer;if(!v)return;
              for(const uid of Array.from(_state.drawings.keys()))if(!seen.has(uid)){const e=_state.drawings.get(uid);if(e)v.entities.remove(e);_state.drawings.delete(uid);}
            },
            removeDrawing(uid){const v=_state.viewer;if(!v)return;const e=_state.drawings.get(uid);if(e){v.entities.remove(e);_state.drawings.delete(uid);}},
            upsertMeasurement(arg){const m=_parse(arg);if(!m||!m.uid||!Array.isArray(m.vertices)||m.vertices.length<2)return;const v=_state.viewer;if(!v)return;
              const color=_drawColor(m.color||'#4ADE80',0.95),fillC=_drawColor(m.color||'#4ADE80',0.7);
              const prior=_state.measurements.get(m.uid);if(prior){if(prior.entity)v.entities.remove(prior.entity);(prior.vertexEntities||[]).forEach(ve=>v.entities.remove(ve));}
              const positions=m.vertices.map(c=>Cesium.Cartesian3.fromDegrees(c[0],c[1],0));
              const line=v.entities.add({id:m.uid,polyline:{positions:positions,width:3,material:new Cesium.PolylineDashMaterialProperty({color:color,dashLength:16}),clampToGround:true}});
              const vertexEntities=m.vertices.map((c,i)=>{const labelText=(m.segments&&m.segments[i])?m.segments[i].label:undefined;
                return v.entities.add({id:m.uid+':v'+i,position:Cesium.Cartesian3.fromDegrees(c[0],c[1],0),
                  point:{pixelSize:8,color:fillC,outlineColor:Cesium.Color.BLACK,outlineWidth:1.5,heightReference:Cesium.HeightReference.CLAMP_TO_GROUND,disableDepthTestDistance:Number.POSITIVE_INFINITY},
                  label:labelText?{text:labelText,font:'11px -apple-system, sans-serif',fillColor:Cesium.Color.WHITE,outlineColor:Cesium.Color.BLACK,outlineWidth:2,style:Cesium.LabelStyle.FILL_AND_OUTLINE,pixelOffset:new Cesium.Cartesian2(0,-18),heightReference:Cesium.HeightReference.CLAMP_TO_GROUND,disableDepthTestDistance:Number.POSITIVE_INFINITY}:undefined});});
              _state.measurements.set(m.uid,{entity:line,vertexEntities:vertexEntities});
            },
            setMeasurements(arg){const list=_parse(arg);if(!Array.isArray(list))return;const seen=new Set();
              for(const m of list)if(m&&m.uid){seen.add(m.uid);window.OmniBridge.upsertMeasurement(m);}
              const v=_state.viewer;if(!v)return;
              for(const uid of Array.from(_state.measurements.keys()))if(!seen.has(uid)){const rec=_state.measurements.get(uid);if(rec.entity)v.entities.remove(rec.entity);(rec.vertexEntities||[]).forEach(ve=>v.entities.remove(ve));_state.measurements.delete(uid);}
            },
            upsertTrail(arg){const t=_parse(arg);if(!t||!t.uid||!Array.isArray(t.coords)||t.coords.length<2)return;const v=_state.viewer;if(!v)return;
              const color=_drawColor(t.color||'#FFC107',0.85),width=typeof t.width==='number'?t.width:3;
              const prior=_state.trails.get(t.uid);if(prior)v.entities.remove(prior);
              const positions=t.coords.map(c=>Cesium.Cartesian3.fromDegrees(c[0],c[1],0));
              _state.trails.set(t.uid,v.entities.add({id:t.uid,polyline:{positions:positions,width:width,material:color,clampToGround:true}}));
            },
            setTrails(arg){const list=_parse(arg);if(!Array.isArray(list))return;const seen=new Set();
              for(const t of list)if(t&&t.uid){seen.add(t.uid);window.OmniBridge.upsertTrail(t);}
              const v=_state.viewer;if(!v)return;
              for(const uid of Array.from(_state.trails.keys()))if(!seen.has(uid)){const e=_state.trails.get(uid);if(e)v.entities.remove(e);_state.trails.delete(uid);}
            }
          };
          (async()=>{
            _fitViewport();
            const v=new Cesium.Viewer('cesiumContainer',{terrain:Cesium.Terrain.fromWorldTerrain(),animation:false,timeline:false,baseLayerPicker:false,geocoder:false,homeButton:false,sceneModePicker:false,navigationHelpButton:false,fullscreenButton:false,infoBox:false,selectionIndicator:false,creditContainer:document.createElement('div')});
            v.scene.skyAtmosphere.show=true;v.scene.globe.enableLighting=true;_state.viewer=v;_fitViewport();_installInputHandlers(v);
            try{const t=await Cesium.createGooglePhotorealistic3DTileset();v.scene.primitives.add(t);}catch(e){console.warn('Photoreal unavailable:',e);}
            // Bootstrap camera over KJFK to match the ADSB pre-GPS
            // fallback — first-launch users land on a scene where the
            // aircraft data they're seeing in the pill actually appears
            // around them. 50km altitude with a steep look-down so a
            // whole metropolitan area's traffic fits in frame.
            v.camera.flyTo({destination:Cesium.Cartesian3.fromDegrees(-73.7781,40.6413,50000),orientation:{heading:0,pitch:Cesium.Math.toRadians(-60),roll:0},duration:1.5,complete:_hideLoading});
            _signalReady();
          })().catch(e=>{const el=document.getElementById('loading');if(el)el.innerHTML='<div class=\"label\">3D scene failed: '+(e&&e.message?e.message:'unknown')+'</div>';});
        </script></body></html>
        """
    }
}
