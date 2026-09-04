//
//  ToolsLauncherSheet.swift
//  OmniTAKMobile
//
//  Bottom-sheet popup launched from the Tools shortcut. The map stays
//  visible/interactive behind it. Holds the marquee Lasso Select, the map
//  engine toggle, a set of quick tools (which open the same real screens as
//  the Full Tools grid via .openToolSheet), a "Customize toolbar" entry,
//  and a passthrough to the full 5x4 grid.
//

import SwiftUI

struct ToolsLauncherSheet: View {
    @EnvironmentObject private var loc: LocalizationManager
    let onLasso: () -> Void
    let onFullTools: () -> Void
    let onCustomize: () -> Void
    let onDismiss: () -> Void

    @AppStorage("mapEngine") private var mapEngineRaw: String = MapEngine.cesium3D.rawValue
    private var mapEngine: MapEngine { MapEngine(rawValue: mapEngineRaw) ?? .cesium3D }

    // Plugin gating — the Settings → Plugins toggles previously filtered
    // only the legacy 5x4 grid, so a "disabled" tool stayed one tap away
    // here in the primary tools surface.
    @ObservedObject private var pluginManager = PluginSettingsManager.shared

    /// `toolSections` with disabled-plugin tools removed; sections that end
    /// up empty are dropped entirely.
    private var visibleSections: [LauncherSection] {
        Self.toolSections.compactMap { section in
            let tools = section.tools.filter { pluginManager.isToolEnabled($0.id) }
            guard !tools.isEmpty else { return nil }
            return LauncherSection(title: section.title, titleKey: section.titleKey, tools: tools)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Marquee row — Lasso Select.
                row(icon: "lasso", iconColor: .orange, title: loc.t("toolsheet.lasso.title"),
                    subtitle: loc.t("toolsheet.lasso.subtitle"),
                    bold: true, action: onLasso)

                Divider().padding(.leading, 70)

                // Map engine toggle.
                row(
                    icon: mapEngine == .cesium3D ? "map.fill" : "globe.americas.fill",
                    iconColor: mapEngine == .cesium3D ? Color(white: 0.55) : Color(red: 0.31, green: 0.66, blue: 1.0),
                    title: mapEngine == .cesium3D ? loc.t("toolsheet.engine.to2d") : loc.t("toolsheet.engine.to3d"),
                    subtitle: mapEngine == .cesium3D
                        ? loc.t("toolsheet.engine.sub2d")
                        : loc.t("toolsheet.engine.sub3d"),
                    bold: false,
                    action: {
                        let next: MapEngine = mapEngine == .cesium3D ? .mapbox2D : .cesium3D
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        mapEngineRaw = next.rawValue
                    }
                )

                // Full sectioned tool catalog — everything the old full-screen
                // grid offered, as smooth rows that keep the map live behind.
                // Each routes through ToolSheetHost by id (.openToolSheet).
                // Filtered by the Settings → Plugins enable toggles.
                ForEach(visibleSections) { section in
                    sectionHeader(loc.t(section.titleKey))
                    ForEach(Array(section.tools.enumerated()), id: \.element.id) { idx, tool in
                        if idx > 0 { Divider().padding(.leading, 70) }
                        quickTool(icon: tool.icon, color: tool.color,
                                  title: loc.t("tools.\(tool.id).title"),
                                  subtitle: loc.t("tools.\(tool.id).subtitle"), toolID: tool.id)
                    }
                }

                sectionHeader(loc.t("tools.section.more"))

                // Build-your-own-bar entry.
                row(icon: "slider.horizontal.3", iconColor: BarTint.tools, title: loc.t("toolsheet.customize.title"),
                    subtitle: loc.t("toolsheet.customize.subtitle"),
                    bold: false, action: onCustomize)

                Divider().padding(.leading, 70)

                // Fallback passthrough to the legacy 5x4 grid.
                row(icon: "square.grid.3x3.fill", iconColor: .secondary, title: loc.t("toolsheet.fullgrid.title"),
                    subtitle: loc.t("toolsheet.fullgrid.subtitle"),
                    bold: false, action: onFullTools)
            }
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .frame(maxHeight: 560)
        .onAppear {
            #if DEBUG
            ToolRegistry.validate(
                ids: Self.toolSections.flatMap { $0.tools.map(\.id) },
                from: "ToolsLauncherSheet"
            )
            #endif
        }
    }

    // MARK: - Tool catalog

    /// One routed tool row (opens via ToolSheetHost using `id`).
    private struct LauncherTool: Identifiable {
        let id: String
        let icon: String
        let color: Color
        let title: String
        let subtitle: String
    }

    private struct LauncherSection: Identifiable {
        let id = UUID()
        let title: String
        let titleKey: String
        let tools: [LauncherTool]
    }

    /// The full catalog, grouped — mirrors every screen the legacy grid
    /// reached, so the popup can be the primary tools surface.
    private static let toolSections: [LauncherSection] = [
        LauncherSection(title: "Markers & Terrain", titleKey: "tools.section.markers", tools: [
            LauncherTool(id: "pointer", icon: "mappin.circle.fill", color: BarTint.red,
                         title: "Point Drop", subtitle: "Place and label a tactical marker"),
            LauncherTool(id: "kml", icon: "square.3.layers.3d", color: BarTint.purple,
                         title: "Map Overlays", subtitle: "Import & toggle KML/KMZ overlays"),
            LauncherTool(id: "elevation", icon: "chart.line.uptrend.xyaxis", color: BarTint.teal,
                         title: "Elevation Profile", subtitle: "Terrain profile along a path"),
            LauncherTool(id: "los", icon: "eye.fill", color: BarTint.teal,
                         title: "Line of Sight", subtitle: "Visibility between two points"),
        ]),
        LauncherSection(title: "Reports", titleKey: "tools.section.reports", tools: [
            LauncherTool(id: "casevac", icon: "cross.case.fill", color: BarTint.red,
                         title: "CASEVAC", subtitle: "Casualty evacuation request"),
            LauncherTool(id: "nineline", icon: "scope", color: BarTint.red,
                         title: "9-Line / CAS", subtitle: "Close air support request"),
            LauncherTool(id: "spotrep", icon: "binoculars.fill", color: BarTint.orange,
                         title: "SPOTREP", subtitle: "Spot report"),
            LauncherTool(id: "alert", icon: "exclamationmark.triangle.fill", color: BarTint.red,
                         title: "Emergency Beacon", subtitle: "Broadcast an emergency alert"),
        ]),
        LauncherSection(title: "Teams & Comms", titleKey: "tools.section.teams", tools: [
            LauncherTool(id: "teams", icon: "person.3.fill", color: BarTint.chat,
                         title: "Teams", subtitle: "Manage team members"),
            LauncherTool(id: "contacts", icon: "person.crop.circle.fill", color: BarTint.chat,
                         title: "Contacts", subtitle: "Contact list & chat"),
            LauncherTool(id: "selfsa", icon: "dot.radiowaves.left.and.right", color: BarTint.map,
                         title: "Self / Position", subtitle: "Broadcast your position (PLI)"),
            LauncherTool(id: "peermesh", icon: "point.3.connected.trianglepath.dotted", color: BarTint.mesh,
                         title: "Peer Mesh", subtitle: "Phone-to-phone CoT sync, no server"),
        ]),
        LauncherSection(title: "Navigation", titleKey: "tools.section.navigation", tools: [
            LauncherTool(id: "gotocoord", icon: "mappin.and.ellipse", color: BarTint.map,
                         title: "Go to Coordinate", subtitle: "Jump to a typed grid/lat-lon (TWD97, MGRS)"),
            LauncherTool(id: "routes", icon: "point.topleft.down.to.point.bottomright.curvepath.fill", color: BarTint.map,
                         title: "Routes", subtitle: "Plan and navigate routes"),
            LauncherTool(id: "turnbyturn", icon: "arrow.triangle.turn.up.right.diamond.fill", color: BarTint.map,
                         title: "Turn-by-Turn", subtitle: "Guided navigation"),
            LauncherTool(id: "tracks", icon: "figure.walk", color: BarTint.teal,
                         title: "Track Recording", subtitle: "Record & review your track"),
            LauncherTool(id: "geofence", icon: "circle.dashed", color: BarTint.purple,
                         title: "Geofences", subtitle: "Create alert zones"),
        ]),
        LauncherSection(title: "Air & Data", titleKey: "tools.section.airdata", tools: [
            LauncherTool(id: "adsb", icon: "airplane.circle.fill", color: BarTint.mesh,
                         title: "ADS-B", subtitle: "Live aircraft tracking"),
            LauncherTool(id: "missionsync", icon: "arrow.triangle.2.circlepath", color: BarTint.servers,
                         title: "Mission Sync", subtitle: "Sync mission packages"),
            LauncherTool(id: "plugins", icon: "puzzlepiece.extension.fill", color: BarTint.settings,
                         title: "Plugins", subtitle: "Manage installed plugins"),
        ]),
    ]

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private func quickTool(icon: String, color: Color, title: String, subtitle: String, toolID: String) -> some View {
        row(icon: icon, iconColor: color, title: title, subtitle: subtitle, bold: false) {
            onDismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                NotificationCenter.default.post(name: .openToolSheet, object: nil, userInfo: ["id": toolID])
            }
        }
    }

    @ViewBuilder
    private func row(icon: String, iconColor: Color, title: String, subtitle: String, bold: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: bold ? .semibold : .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 17, weight: bold ? .semibold : .regular))
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tap-outside-to-dismiss overlay wrapper

/// Wraps `ToolsLauncherSheet` in a tap-dismissible scrim. iOS's native
/// `.sheet` doesn't dismiss on outside taps, so the dim area behind the
/// panel is a tap target; swipe-down on the panel also dismisses.
struct ToolsLauncherOverlay: View {
    let onLasso: () -> Void
    let onFullTools: () -> Void
    let onCustomize: () -> Void
    let onDismiss: () -> Void

    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                Capsule()
                    .fill(Color.white.opacity(0.35))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                ToolsLauncherSheet(
                    onLasso: onLasso,
                    onFullTools: onFullTools,
                    onCustomize: onCustomize,
                    onDismiss: onDismiss
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 78)
            .offset(y: max(0, dragOffset))
            .gesture(
                DragGesture()
                    .updating($dragOffset) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        if value.translation.height > 60 || value.predictedEndTranslation.height > 140 {
                            onDismiss()
                        }
                    }
            )
        }
    }
}
