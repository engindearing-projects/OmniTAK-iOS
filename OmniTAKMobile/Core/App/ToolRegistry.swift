//
//  ToolRegistry.swift
//  OmniTAKMobile
//
//  The single tool catalog. Previously the same catalog was encoded in
//  three+ places keyed by matching string ids with no enforcement —
//  ATAKTool.allTools + ATAKToolsView's own switch dispatcher,
//  ToolsLauncherSheet's row arrays, ToolSheetHost's switch, and
//  ToolbarCustomization.toolShortcuts — and they had drifted (the grid
//  couldn't reach UAS Connect or Go to Coordinate at all).
//
//  ToolSheetHost is the ONLY dispatcher: every surface opens a tool by
//  posting `.openToolSheet` with the descriptor id, and the destination
//  view comes from here.
//

import SwiftUI

// MARK: - Tool Descriptor

struct ToolDescriptor: Identifiable {
    /// Routing id used in `.openToolSheet` notifications.
    let id: String
    /// Canonical display name (grid label).
    let displayName: String
    /// Canonical SF Symbol (grid/toolbar icon — launcher rows may style
    /// their own presentation).
    let icon: String
    /// Short description (grid subtitle / accessibility).
    let description: String
    /// Build the tool's sheet content. `dismiss` closes the hosting
    /// sheet — only destinations that drive their own dismissal use it.
    let destination: (_ dismiss: @escaping () -> Void) -> AnyView

    init(
        id: String,
        displayName: String,
        icon: String,
        description: String,
        destination: @escaping (_ dismiss: @escaping () -> Void) -> AnyView
    ) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.description = description
        self.destination = destination
    }

    /// Convenience for destinations that don't need the dismiss handle.
    init<V: View>(
        id: String,
        displayName: String,
        icon: String,
        description: String,
        @ViewBuilder content: @escaping () -> V
    ) {
        self.init(id: id, displayName: displayName, icon: icon, description: description) { _ in
            AnyView(content())
        }
    }
}

// MARK: - Tool Registry

enum ToolRegistry {

    /// Shared recording service so every surface presents the same
    /// instance (previously the grid and the sheet host each newed up
    /// their own TrackRecordingService).
    static let trackRecordingService = TrackRecordingService()

    static func descriptor(for id: String) -> ToolDescriptor? { index[id] }

    #if DEBUG
    /// Debug guard for the presentation surfaces (launcher rows, toolbar
    /// shortcuts) that keep curated labels/icons but MUST route ids that
    /// exist here — this is the enforcement the old string-switch
    /// triplication never had.
    static func validate(ids: [String], from surface: String) {
        for id in ids where descriptor(for: id) == nil {
            assertionFailure("\(surface) routes tool id '\(id)' that is not in ToolRegistry")
        }
    }
    #endif

    private static let index: [String: ToolDescriptor] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Every sheet-presented tool in the app. Map-mode commands
    /// (drawing, measure, lasso, engine toggle) are not sheets and stay
    /// with the surfaces that own the map state.
    static let all: [ToolDescriptor] = [
        // Core Features
        ToolDescriptor(id: "teams", displayName: "Teams", icon: "person.3.fill",
                       description: "Team management and coordination") { TeamListView() },
        ToolDescriptor(id: "chat", displayName: "Chat", icon: "message.fill",
                       description: "Team chat messaging") { ChatView(chatManager: ChatManager.shared) },
        ToolDescriptor(id: "routes", displayName: "Routes", icon: "point.topleft.down.to.point.bottomright.curvepath.fill",
                       description: "Route planning and navigation") { RouteListView() },
        ToolDescriptor(id: "geofence", displayName: "Geofence", icon: "square.dashed",
                       description: "Create geofence alerts") { GeofenceListView() },
        ToolDescriptor(id: "tracks", displayName: "Tracks", icon: "record.circle",
                       description: "Track recording and playback") { TrackListView(recordingService: ToolRegistry.trackRecordingService) },

        // Data & Media
        ToolDescriptor(id: "data", displayName: "Data Packages", icon: "shippingbox.fill",
                       description: "Manage data packages",
                       destination: { dismiss in
                           AnyView(DataPackageSheetView(isPresented: Binding(
                               get: { true },
                               set: { if !$0 { dismiss() } }
                           )))
                       }),
        ToolDescriptor(id: "video", displayName: "Video", icon: "video.fill",
                       description: "Video streaming (Beta - requires TAK server)") { VideoFeedListView() },
        ToolDescriptor(id: "offline", displayName: "Offline Maps", icon: "arrow.down.doc.fill",
                       description: "Download maps for offline use") { OfflineMapsView() },
        ToolDescriptor(id: "kml", displayName: "Map Overlays", icon: "square.3.layers.3d",
                       description: "Import & toggle KML/KMZ overlays (handles huge files)") { KMLOverlaysPanel() },

        // Tactical
        ToolDescriptor(id: "alert", displayName: "Emergency", icon: "sos",
                       description: "Emergency SOS beacon") { EmergencyBeaconView() },
        ToolDescriptor(id: "pointer", displayName: "Point Drop", icon: "mappin.and.ellipse",
                       description: "Drop tactical markers",
                       destination: { dismiss in
                           AnyView(PointDropperSheetView(isPresented: Binding(
                               get: { true },
                               set: { if !$0 { dismiss() } }
                           )))
                       }),
        ToolDescriptor(id: "casevac", displayName: "CASEVAC", icon: "cross.case.fill",
                       description: "Request casualty evacuation") { MEDEVACRequestView() },
        ToolDescriptor(id: "nineline", displayName: "9-Line CAS", icon: "airplane",
                       description: "Close Air Support request") { CASRequestView() },
        ToolDescriptor(id: "bloodhound", displayName: "Bloodhound", icon: "antenna.radiowaves.left.and.right",
                       description: "Blue Force Tracking") { BloodhoundSheetView() },
        ToolDescriptor(id: "spotrep", displayName: "SPOTREP", icon: "doc.text.fill",
                       description: "Quick tactical spot report") { SPOTREPView() },

        // Utilities
        ToolDescriptor(id: "turnbyturn", displayName: "Navigation", icon: "location.north.line.fill",
                       description: "Turn-by-turn voice navigation") { TurnByTurnNavigationView() },
        ToolDescriptor(id: "meshtastic", displayName: "Meshtastic", icon: "dot.radiowaves.left.and.right",
                       description: "Meshtastic mesh networking") { MeshtasticConnectionView() },
        ToolDescriptor(id: "peermesh", displayName: "Peer Mesh", icon: "point.3.connected.trianglepath.dotted",
                       description: "Phone-to-phone CoT sync, no server") { DittoMeshSettingsView() },
        ToolDescriptor(id: "adsb", displayName: "ADS-B", icon: "airplane.circle.fill",
                       description: "ADS-B aircraft tracking") { ADSBTrafficView() },
        ToolDescriptor(id: "uas", displayName: "UAS Connect", icon: "airplane.departure",
                       description: "Connect to UAS / drone vehicles") { UASConnectView() },
        ToolDescriptor(id: "gotocoord", displayName: "Go to Coord", icon: "mappin.and.ellipse",
                       description: "Jump to a typed grid/lat-lon (TWD97, MGRS)") { CoordinateEntryView() },

        // Map-driven destinations
        ToolDescriptor(id: "contacts", displayName: "Contacts", icon: "person.2.fill",
                       description: "Team contacts and presence") { ContactListView(chatManager: ChatManager.shared) },
        ToolDescriptor(id: "selfsa", displayName: "Self SA", icon: "dot.radiowaves.up.forward",
                       description: "Position broadcasting (PLI)") { PositionBroadcastView() },
        ToolDescriptor(id: "missionsync", displayName: "Mission Sync", icon: "arrow.triangle.2.circlepath",
                       description: "Mission package sync") { MissionSyncView() },
        ToolDescriptor(id: "elevation", displayName: "Elevation", icon: "mountain.2.fill",
                       description: "Elevation profile") { ElevationProfileView() },
        ToolDescriptor(id: "los", displayName: "Line of Sight", icon: "eye.fill",
                       description: "Line of sight analysis") { LineOfSightView() },

        // Hierarchy & Settings
        ToolDescriptor(id: "echelon", displayName: "Hierarchy", icon: "rectangle.connected.to.line.below",
                       description: "Unit hierarchy / echelon") { EchelonHierarchyView() },
        ToolDescriptor(id: "plugins", displayName: "Plugins", icon: "puzzlepiece.extension.fill",
                       description: "Manage plugins") { PluginsListView() },
        ToolDescriptor(id: "settings", displayName: "Settings", icon: "gearshape.fill",
                       description: "App settings") {
            SettingsView().environmentObject(LocalizationManager.shared)
        },
    ]
}
