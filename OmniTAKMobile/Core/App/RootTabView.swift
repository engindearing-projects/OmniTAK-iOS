//
//  RootTabView.swift
//  OmniTAKMobile
//
//  Top-level navigation. The system TabView caps visible tabs at 5 before
//  forcing a "More" overflow, so we hide its built-in bar and overlay our
//  own fully-customizable floating bar (CustomToolbar). The underlying
//  TabView still owns all five destinations so switching tabs preserves
//  each screen's state (map region, chat scroll, etc.).
//
//  The bar is no longer hardcoded: ToolbarConfigStore holds the operator's
//  chosen, reorderable set of shortcuts. Long-press the bar to customize.
//  Every shortcut routes to a real feature — destinations switch tabs,
//  map commands post the same notifications the radial menu uses, and tool
//  shortcuts open the same sheets the Full Tools grid opens (ToolSheetHost).
//

import SwiftUI

struct RootTabView: View {
    @SceneStorage("selectedRootTab") private var selectedTab: RootTab = .map
    @ObservedObject private var toolbarStore = ToolbarConfigStore.shared
    /// Drives the Mesh tab's link-state dot.
    @ObservedObject private var meshtastic = MeshtasticManager.shared

    /// Mesh tab dot: green connected, amber connecting, red failed, grey no
    /// device — same ladder as Android.
    private var meshLinkColor: Color {
        switch meshtastic.linkState {
        case .connected:  return .green
        case .connecting: return .orange
        case .failed:     return .red
        case .noDevice:   return Color.white.opacity(0.35)
        }
    }
    @State private var showToolsLauncher = false
    @State private var showAddPalette = false

    @AppStorage("mapEngine") private var mapEngineRaw: String = MapEngine.cesium3D.rawValue
    private var mapEngine: MapEngine { MapEngine(rawValue: mapEngineRaw) ?? .cesium3D }

    init() {
        // The custom bar is the only bar we want; the system one would
        // auto-collapse extra tabs into a "More" overflow or stack behind.
        UITabBar.appearance().isHidden = true
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ATAKMapView()
                .tag(RootTab.map)
                .ignoresSafeArea(edges: .bottom)

            ChatView(chatManager: ChatManager.shared)
                .tag(RootTab.chat)

            // As tabs, nothing is "presented", so these views' Done buttons
            // can't dismiss — hand them "back to the map" instead.
            ServersView(onDone: { selectedTab = .map })
                .tag(RootTab.servers)

            MeshtasticConnectionView()
                .tag(RootTab.mesh)

            SettingsView(onDone: { selectedTab = .map })
                .tag(RootTab.settings)
        }
        // Tap-away scrim while editing so tapping the map exits edit mode.
        // Applied BEFORE the toolbar overlay so the bar renders on top of it
        // and stays interactive (drag/remove/add) while editing.
        .overlay {
            if toolbarStore.isEditing {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            toolbarStore.isEditing = false
                        }
                    }
            }
        }
        .overlay(alignment: .bottom) {
            CustomToolbar(
                selectedTab: $selectedTab,
                onSelect: dispatch,
                onAddTapped: { showAddPalette = true },
                statusDots: ["tab.mesh": meshLinkColor]
            )
        }
        // Tools popup overlay (tap-outside-to-dismiss; map stays interactive).
        .overlay {
            if showToolsLauncher {
                ToolsLauncherOverlay(
                    onLasso: handleLasso,
                    onFullTools: handleFullTools,
                    onCustomize: handleCustomize,
                    onDismiss: { withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { showToolsLauncher = false } }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(2000)
            }
        }
        // Add-a-shortcut palette.
        .sheet(isPresented: $showAddPalette) {
            ToolbarAddPalette()
        }
        // Hosts the real tool sheets opened by tool shortcuts.
        .toolSheetHost()
        // Settings / Tools popup can ask the bar to enter edit mode.
        .onReceive(NotificationCenter.default.publisher(for: .enterToolbarEditMode)) { _ in
            selectedTab = .map
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                toolbarStore.isEditing = true
            }
        }
    }

    // MARK: - Routing

    private func dispatch(_ item: BarItem) {
        switch item.kind {
        case .tab(let tab):
            selectedTab = tab
        case .command(let command):
            run(command)
        }
    }

    private func run(_ command: BarCommand) {
        switch command {
        case .tools:
            withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) { showToolsLauncher = true }
        case .fullTools:
            handleFullTools()
        case .lasso:
            handleLasso()
        case .measure:
            selectedTab = .map
            NotificationCenter.default.post(name: .radialMenuMeasurementStarted, object: nil,
                                            userInfo: ["type": MeasurementType.distance])
        case .drawing:
            selectedTab = .map
            NotificationCenter.default.post(name: .radialMenuOpenDrawingTools, object: nil)
        case .layers:
            selectedTab = .map
            NotificationCenter.default.post(name: .radialMenuShowLayers, object: nil)
        case .drawingsList:
            selectedTab = .map
            NotificationCenter.default.post(name: .radialMenuOpenDrawingsList, object: nil)
        case .dropPin:
            selectedTab = .map
            NotificationCenter.default.post(name: .barDropPin, object: nil)
        case .engineToggle:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            mapEngineRaw = (mapEngine == .cesium3D ? MapEngine.mapbox2D : MapEngine.cesium3D).rawValue
        case .openTool(let id):
            NotificationCenter.default.post(name: .openToolSheet, object: nil, userInfo: ["id": id])
        }
    }

    private func handleLasso() {
        showToolsLauncher = false
        selectedTab = .map
        NotificationCenter.default.post(name: .startLassoMode, object: nil)
    }

    private func handleFullTools() {
        showToolsLauncher = false
        selectedTab = .map
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NotificationCenter.default.post(name: .showFullTools, object: nil)
        }
    }

    private func handleCustomize() {
        showToolsLauncher = false
        selectedTab = .map
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                toolbarStore.isEditing = true
            }
        }
    }
}
