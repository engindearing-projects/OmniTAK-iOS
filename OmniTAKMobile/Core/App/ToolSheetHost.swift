//
//  ToolSheetHost.swift
//  OmniTAKMobile
//
//  Presents a tool's sheet when a customizable-bar shortcut (or the Tools
//  popup) fires `.openToolSheet`. These are the exact same screens the 5x4
//  ATAKToolsView grid opens — routing through one host lets the bar reach
//  the full tool catalog without duplicating each tool's presentation in
//  multiple places.
//

import SwiftUI

private struct ToolSheetID: Identifiable, Equatable { let id: String }

struct ToolSheetHost: ViewModifier {
    @State private var active: ToolSheetID?
    @StateObject private var trackRecordingService = TrackRecordingService()
    @ObservedObject private var chatManager = ChatManager.shared

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .openToolSheet)) { note in
                if let id = note.userInfo?["id"] as? String {
                    active = ToolSheetID(id: id)
                }
            }
            .sheet(item: $active) { sheet in
                sheetView(for: sheet.id)
            }
    }

    @ViewBuilder
    private func sheetView(for id: String) -> some View {
        switch id {
        case "routes":       RouteListView()
        case "turnbyturn":   TurnByTurnNavigationView()
        case "teams":        TeamListView()
        case "contacts":     ContactListView(chatManager: chatManager)
        case "casevac":      MEDEVACRequestView()
        case "nineline":     CASRequestView()
        case "spotrep":      SPOTREPView()
        case "alert":        EmergencyBeaconView()
        case "tracks":       TrackListView(recordingService: trackRecordingService)
        case "geofence":     GeofenceListView()
        case "adsb":         ADSBTrafficView()
        case "selfsa":       PositionBroadcastView()
        case "elevation":    ElevationProfileView()
        case "los":          LineOfSightView()
        case "missionsync":  MissionSyncView()
        case "plugins":      PluginsListView()
        case "kml":          KMLOverlaysPanel()
        case "pointer":
            PointDropperSheetView(isPresented: Binding(
                get: { active != nil },
                set: { if !$0 { active = nil } }
            ))
        default:
            EmptyView()
        }
    }
}

extension View {
    /// Attach once near the app root so `.openToolSheet` notifications
    /// resolve to real tool screens.
    func toolSheetHost() -> some View { modifier(ToolSheetHost()) }
}
