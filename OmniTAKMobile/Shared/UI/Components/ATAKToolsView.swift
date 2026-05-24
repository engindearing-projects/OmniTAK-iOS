import SwiftUI
import MapKit
import WebKit
import CoreLocation

// MARK: - ATAK Tools Menu View
// Comprehensive tools menu with 5x4 grid layout matching ATAK interface

struct ATAKToolsView: View {
    @Binding var isPresented: Bool
    @Binding var showMeasurement: Bool  // Shared measurement state from MapViewController
    @State private var showAlertDialog = false
    @State private var showBrightnessControl = false

    // Feature sheet states
    @State private var showTeamManagement = false
    @State private var showRoutePlanning = false
    @State private var showGeofences = false
    @State private var showTrackRecording = false
    @State private var showChat = false
    @State private var showEmergencySOS = false
    @State private var showDataPackages = false
    @State private var showVideoStreaming = false
    @State private var showOfflineMaps = false
    @State private var showPointDropper = false
    @State private var showSettings = false
    @State private var showPlugins = false
    @State private var showMEDEVAC = false
    @State private var showCASRequest = false
    @State private var showSPOTREP = false
    @State private var showBloodhound = false
    @State private var show3DView = false
    @State private var showDigitalPointer = false
    @State private var showTurnByTurnNav = false
    @State private var showMeshtastic = false
    @State private var showADSB = false
    @State private var showContacts = false
    @State private var showPositionBroadcast = false
    @State private var showMissionSync = false
    @State private var showElevationProfile = false
    @State private var showLineOfSight = false
    @State private var showEchelonHierarchy = false
    @State private var showKMLOverlays = false

    @ObservedObject private var chatManager = ChatManager.shared
    @StateObject private var trackRecordingService = TrackRecordingService()
    @ObservedObject private var pluginManager = PluginSettingsManager.shared
    @AppStorage("showDisabledTools") private var showDisabledTools: Bool = true
    // Same key ATAKMapView reads — toggle from the Tools sheet flips the
    // map engine for the whole app.
    @AppStorage("mapEngine") private var mapEngineRaw: String = MapEngine.cesium3D.rawValue
    private var mapEngine: MapEngine { MapEngine(rawValue: mapEngineRaw) ?? .cesium3D }

    let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 5)

    /// Filtered tools based on the toggle
    private var visibleTools: [ATAKTool] {
        if showDisabledTools {
            return ATAKTool.allTools
        } else {
            return ATAKTool.allTools.filter { pluginManager.isToolEnabled($0.id) }
        }
    }

    var body: some View {
        ZStack {
            // Dark background
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header with toggle
                ToolsHeader(
                    showDisabledTools: $showDisabledTools,
                    onClose: { isPresented = false }
                )

                // Tools Grid (5x4 layout)
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 0) {
                        ForEach(visibleTools) { tool in
                            let isEnabled = pluginManager.isToolEnabled(tool.id)
                            ToolButton(
                                tool: tool,
                                isEnabled: isEnabled,
                                action: {
                                    if isEnabled {
                                        handleToolSelection(tool)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
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
        .sheet(isPresented: $showEmergencySOS) {
            EmergencyBeaconView()
        }
        .sheet(isPresented: $showDataPackages) {
            DataPackageSheetView(isPresented: $showDataPackages)
        }
        .sheet(isPresented: $showVideoStreaming) {
            VideoFeedListView()
        }
        .sheet(isPresented: $showOfflineMaps) {
            OfflineMapsView()
        }
        .sheet(isPresented: $showPointDropper) {
            PointDropperSheetView(isPresented: $showPointDropper)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(LocalizationManager.shared)
        }
        .sheet(isPresented: $showPlugins) {
            PluginsListView()
        }
        .sheet(isPresented: $showMEDEVAC) {
            MEDEVACRequestView()
        }
        .sheet(isPresented: $showCASRequest) {
            CASRequestView()
        }
        .sheet(isPresented: $showSPOTREP) {
            SPOTREPView()
        }
        .sheet(isPresented: $showBloodhound) {
            BloodhoundSheetView()
        }
        .sheet(isPresented: $show3DView) {
            // CesiumJS scene with Google Photorealistic 3D Tiles + Cesium
            // World Terrain, served from the cesium.com CDN. Replaces the
            // previous MapLibre flat-3D modal — Cesium gives true 3D globe
            // + atmosphere + photoreal cities, none of which the Mapbox
            // mobile SDK can match today.
            CesiumScenePresenter()
        }
        .sheet(isPresented: $showDigitalPointer) {
            DigitalPointerControlPanel()
        }
        .sheet(isPresented: $showTurnByTurnNav) {
            TurnByTurnNavigationView()
        }
        .sheet(isPresented: $showMeshtastic) {
            MeshtasticConnectionView()
        }
        .sheet(isPresented: $showADSB) {
            ADSBTrafficView()
        }
        .sheet(isPresented: $showContacts) {
            ContactListView(chatManager: chatManager)
        }
        .sheet(isPresented: $showPositionBroadcast) {
            PositionBroadcastView()
        }
        .sheet(isPresented: $showMissionSync) {
            MissionSyncView()
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
        .sheet(isPresented: $showKMLOverlays) {
            KMLOverlaysPanel()
        }
    }

    private func handleToolSelection(_ tool: ATAKTool) {
        switch tool.id {
        // Core Features
        case "teams":
            showTeamManagement = true
        case "chat":
            showChat = true
        case "routes":
            showRoutePlanning = true
        case "geofence":
            showGeofences = true
        case "tracks":
            showTrackRecording = true

        // Data & Media
        case "data":
            showDataPackages = true
        case "video":
            showVideoStreaming = true
        case "offline":
            showOfflineMaps = true
        case "drawing":
            // Reuse the existing radial-menu notification that opens the drawing tools panel
            NotificationCenter.default.post(name: .radialMenuOpenDrawingTools, object: nil)
            isPresented = false  // Dismiss tools menu so the drawing panel is visible
        case "measure":
            // Use the shared measurement overlay from MapViewController
            showMeasurement = true
            isPresented = false  // Dismiss tools menu
        case "lasso":
            // Issue #16 — activate freehand multi-select. Same
            // notification pattern as the drawing tool entry so
            // MapViewController owns the actual mode change.
            NotificationCenter.default.post(name: .startLassoMode, object: nil)
            isPresented = false  // Dismiss tools menu so the user can draw

        // Tactical
        case "alert":
            showEmergencySOS = true
        case "pointer":
            showPointDropper = true
        case "casevac":
            showMEDEVAC = true
        case "nineline":
            showCASRequest = true
        case "bloodhound":
            showBloodhound = true
        case "spotrep":
            showSPOTREP = true

        // Utilities (engine toggle lives in ToolsLauncherSheet now)
        case "brightness":
            showBrightnessControl = true
        case "plugins":
            showPlugins = true
        case "settings":
            showSettings = true
        case "turnbyturn":
            showTurnByTurnNav = true
        case "meshtastic":
            showMeshtastic = true
        case "adsb":
            showADSB = true

        // Drawer-absorbed map-driven destinations
        case "contacts":
            showContacts = true
        case "selfsa":
            showPositionBroadcast = true
        case "missionsync":
            showMissionSync = true
        case "elevation":
            showElevationProfile = true
        case "los":
            showLineOfSight = true
        case "echelon":
            showEchelonHierarchy = true
        case "kml":
            showKMLOverlays = true

        default:
            // Unknown tool ids are a no-op — there is no fallback detail view.
            break
        }
    }
}

// MARK: - Tools Header

struct ToolsHeader: View {
    @Binding var showDisabledTools: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tools")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                // Close button
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
            }
            .padding()

            // Toggle row
            HStack {
                Text("Show disabled")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)

                Spacer()

                Toggle("", isOn: $showDisabledTools)
                    .labelsHidden()
                    .scaleEffect(0.8)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(Color.black)
    }
}

// MARK: - Tool Button

struct ToolButton: View {
    let tool: ATAKTool
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 8) {
                    Image(systemName: tool.iconName)
                        .font(.system(size: 32))
                        .foregroundColor(isEnabled ? .white : .gray.opacity(0.4))
                        .frame(height: 44)

                    Text(tool.displayName)
                        .font(.system(size: 12))
                        .foregroundColor(isEnabled ? .white : .gray.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(height: 32)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isEnabled ? Color(white: 0.15) : Color(white: 0.08))
                .overlay(
                    Rectangle()
                        .stroke(Color(white: 0.3), lineWidth: 0.5)
                )
                .overlay(
                    // Disabled overlay
                    Group {
                        if !isEnabled {
                            Color.black.opacity(0.3)
                        }
                    }
                )

                // "Beta" badge for disabled/experimental tools
                if !isEnabled {
                    Text("BETA")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .cornerRadius(3)
                        .padding(4)
                }
            }
        }
        .disabled(!isEnabled)
    }
}

// MARK: - ATAK Tool Model

struct ATAKTool: Identifiable {
    let id: String
    let displayName: String
    let iconName: String
    let description: String

    static let allTools: [ATAKTool] = [
        // Row 1 - Core Features
        ATAKTool(id: "teams", displayName: "Teams", iconName: "person.3.fill", description: "Team management and coordination"),
        ATAKTool(id: "chat", displayName: "Chat", iconName: "message.fill", description: "Team chat messaging"),
        ATAKTool(id: "routes", displayName: "Routes", iconName: "point.topleft.down.to.point.bottomright.curvepath.fill", description: "Route planning and navigation"),
        ATAKTool(id: "geofence", displayName: "Geofence", iconName: "square.dashed", description: "Create geofence alerts"),
        ATAKTool(id: "tracks", displayName: "Tracks", iconName: "record.circle", description: "Track recording and playback"),

        // Row 2 - Data & Media
        ATAKTool(id: "data", displayName: "Data Packages", iconName: "shippingbox.fill", description: "Manage data packages"),
        ATAKTool(id: "video", displayName: "Video", iconName: "video.fill", description: "Video streaming (Beta - requires TAK server)"),
        ATAKTool(id: "offline", displayName: "Offline Maps", iconName: "arrow.down.doc.fill", description: "Download maps for offline use"),
        ATAKTool(id: "kml", displayName: "Map Overlays", iconName: "square.3.layers.3d", description: "Import & toggle KML/KMZ overlays (handles huge files)"),
        ATAKTool(id: "drawing", displayName: "Drawing", iconName: "pencil.tip.crop.circle", description: "Draw on map"),
        ATAKTool(id: "measure", displayName: "Measure", iconName: "ruler", description: "Distance and area measurement"),
        ATAKTool(id: "lasso", displayName: "Select", iconName: "lasso", description: "Multi-select features in a freehand region (long-press + drag)"),

        // Row 3 - Tactical
        ATAKTool(id: "alert", displayName: "Emergency", iconName: "sos", description: "Emergency SOS beacon"),
        ATAKTool(id: "pointer", displayName: "Point Drop", iconName: "mappin.and.ellipse", description: "Drop tactical markers"),
        ATAKTool(id: "casevac", displayName: "CASEVAC", iconName: "cross.case.fill", description: "Request casualty evacuation"),
        ATAKTool(id: "nineline", displayName: "9-Line CAS", iconName: "airplane", description: "Close Air Support request"),
        ATAKTool(id: "bloodhound", displayName: "Bloodhound", iconName: "antenna.radiowaves.left.and.right", description: "Blue Force Tracking"),

        // Row 4 - Utilities & Reports
        ATAKTool(id: "spotrep", displayName: "SPOTREP", iconName: "doc.text.fill", description: "Quick tactical spot report"),
        // Map-engine toggle deliberately omitted from the grid — it lives
        // in the slick Tools popup (ToolsLauncherSheet). Mode switchers
        // don't belong in Full Tools.
        ATAKTool(id: "turnbyturn", displayName: "Navigation", iconName: "location.north.line.fill", description: "Turn-by-turn voice navigation"),
        ATAKTool(id: "meshtastic", displayName: "Meshtastic", iconName: "dot.radiowaves.left.and.right", description: "Meshtastic mesh networking"),

        // Row 5 - Map-driven destinations (absorbed from removed navigation drawer)
        ATAKTool(id: "contacts", displayName: "Contacts", iconName: "person.2.fill", description: "Team contacts and presence"),
        ATAKTool(id: "selfsa", displayName: "Self SA", iconName: "dot.radiowaves.up.forward", description: "Position broadcasting (PLI)"),
        ATAKTool(id: "missionsync", displayName: "Mission Sync", iconName: "arrow.triangle.2.circlepath", description: "Mission package sync"),
        ATAKTool(id: "elevation", displayName: "Elevation", iconName: "mountain.2.fill", description: "Elevation profile"),
        ATAKTool(id: "los", displayName: "Line of Sight", iconName: "eye.fill", description: "Line of sight analysis"),

        // Row 6 - Hierarchy & Utilities
        ATAKTool(id: "echelon", displayName: "Hierarchy", iconName: "rectangle.connected.to.line.below", description: "Unit hierarchy / echelon"),
        ATAKTool(id: "adsb", displayName: "ADS-B", iconName: "airplane.circle.fill", description: "ADS-B aircraft tracking"),
        ATAKTool(id: "plugins", displayName: "Plugins", iconName: "puzzlepiece.extension.fill", description: "Manage plugins"),
        ATAKTool(id: "settings", displayName: "Settings", iconName: "gearshape.fill", description: "App settings")
    ]
}

// MARK: - Sheet Wrapper Views

struct DataPackageSheetView: View {
    @Binding var isPresented: Bool
    @StateObject private var packageManager = DataPackageManager()

    var body: some View {
        DataPackageView(packageManager: packageManager, isPresented: $isPresented)
    }
}

struct PointDropperSheetView: View {
    @Binding var isPresented: Bool
    // Must observe the shared singleton the map renders from — newing up a
    // fresh PointDropperService here dropped markers into a throwaway object
    // the map never saw, so dropped points never appeared.
    @ObservedObject private var service = PointDropperService.shared
    @ObservedObject private var location = LocationManager.shared
    @ObservedObject private var mapCenterStore = MapCenterStore.shared

    var body: some View {
        PointDropperView(
            service: service,
            isPresented: $isPresented,
            currentLocation: location.location?.coordinate,
            mapCenter: mapCenterStore.center
        )
    }
}

struct BloodhoundSheetView: View {
    @StateObject private var bloodhoundService = BloodhoundService()
    @State private var mapRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
        span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
    )

    var body: some View {
        BloodhoundView(bloodhoundService: bloodhoundService, mapRegion: $mapRegion)
    }
}

// MARK: - Color Extension
// Color extension with hex initializer is defined in SharedUIComponents.swift

// MARK: - Cesium 3D Scene presenter

/// Full-screen wrapper around a WKWebView hosting CesiumJS with Google
/// Photorealistic 3D Tiles + Cesium World Terrain. The HTML loads
/// Cesium from cesium.com's CDN so we don't have to bundle the SDK.
struct CesiumScenePresenter: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CesiumWebView()
                .ignoresSafeArea()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .padding(16)
            }
            .accessibilityLabel("Close 3D scene")
        }
        .background(Color.black)
    }
}

private struct CesiumWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false

        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://cesium.com/"))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private static let cesiumIonToken =
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJqdGkiOiI3NDUwNGNjMy05ZGM2LTRhNjgtYWY1ZS0xNjdjMTI0OTYxMjYiLCJpZCI6NDMyNTU0LCJpc3MiOiJodHRwczovL2lvbi5jZXNpdW0uY29tIiwiYXVkIjoidW5kZWZpbmVkX2RlZmF1bHQiLCJpYXQiOjE3Nzg5OTYwNzd9.4MTmIKjioTboeXn02fm7i7Ftude-JVIg3RYW4jgIZ48"

    private static var html: String {
        """
        <!DOCTYPE html><html lang=\"en\"><head>
        <meta charset=\"utf-8\">
        <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover\">
        <link href=\"https://cesium.com/downloads/cesiumjs/releases/1.124/Build/Cesium/Widgets/widgets.css\" rel=\"stylesheet\">
        <style>
          html,body{margin:0;padding:0;height:100%;width:100%;overflow:hidden;background:#000;color:#fff;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
          #cesiumContainer{position:absolute;inset:0}
          #loading{position:absolute;top:50%;left:0;right:0;text-align:center;transform:translateY(-50%);z-index:10;pointer-events:none}
          .dot{display:inline-block;width:12px;height:12px;border-radius:50%;background:#FFCC00;margin:0 4px;animation:p 1.4s infinite}
          .dot:nth-child(2){animation-delay:.2s}.dot:nth-child(3){animation-delay:.4s}
          @keyframes p{0%,80%,100%{opacity:.3}40%{opacity:1}}
          .label{margin-top:16px;font-size:14px;opacity:.7}
          .cesium-viewer-bottom{display:none!important}
        </style></head><body>
        <div id=\"loading\"><span class=\"dot\"></span><span class=\"dot\"></span><span class=\"dot\"></span><div class=\"label\">Loading 3D world…</div></div>
        <div id=\"cesiumContainer\"></div>
        <script src=\"https://cesium.com/downloads/cesiumjs/releases/1.124/Build/Cesium/Cesium.js\"></script>
        <script>
          Cesium.Ion.defaultAccessToken='\(cesiumIonToken)';
          (async()=>{
            const v=new Cesium.Viewer('cesiumContainer',{
              terrain:Cesium.Terrain.fromWorldTerrain(),
              animation:false,timeline:false,baseLayerPicker:false,geocoder:false,
              homeButton:false,sceneModePicker:false,navigationHelpButton:false,
              fullscreenButton:false,infoBox:false,selectionIndicator:false,
              creditContainer:document.createElement('div')
            });
            v.scene.skyAtmosphere.show=true;v.scene.globe.enableLighting=true;
            try{const t=await Cesium.createGooglePhotorealistic3DTileset();v.scene.primitives.add(t);}catch(e){console.warn('Photoreal unavailable:',e);}
            v.camera.flyTo({
              destination:Cesium.Cartesian3.fromDegrees(-77.0365,38.8977,5000),
              orientation:{heading:0,pitch:Cesium.Math.toRadians(-30),roll:0},
              duration:1.5,
              complete:()=>{const el=document.getElementById('loading');if(el)el.style.display='none';}
            });
          })().catch(e=>{const el=document.getElementById('loading');if(el)el.innerHTML='<div class=\"label\">3D scene failed: '+(e&&e.message?e.message:'unknown')+'</div>';});
        </script></body></html>
        """
    }
}
