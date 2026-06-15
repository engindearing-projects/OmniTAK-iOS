//
//  ATAKMapChrome.swift
//  OmniTAKMobile
//
//  ATAK-style map chrome: status bar, bottom toolbar, side panel,
//  overlay settings panel, and their button helpers.
//  Extracted from MapViewController.swift — mechanical move, no behavior change.
//

import SwiftUI
import MapKit
import CoreLocation

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
                        Text(serverName ?? (isConnected ? "Connected" : "Offline"))
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
    /// True on the Cesium 3D globe — gates 3D-only base options (Photoreal).
    var is3D: Bool = false
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
                // Photorealistic 3D tiles (Google) — globe only, loaded on
                // demand. Heavy on GPU/network, so it's opt-in rather than
                // always-on: picking another base unloads it.
                if is3D {
                    LayerButton(icon: "building.2.fill", title: "Photoreal 3D", isActive: activeMapLayer == "photoreal", compact: true) {
                        onLayerToggle("photoreal")
                    }
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

// MARK: - Overlay Settings Panel

struct OverlaySettingsPanel: View {
    @ObservedObject var overlayCoordinator: MapOverlayCoordinator
    @ObservedObject var mapStateManager: MapStateManager
    @ObservedObject private var loc = LocalizationManager.shared

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

            // MGRS Grid Toggle. 2D-engine-only: the map auto-switches to
            // 2D when the grid is enabled while on the Cesium globe.
            OverlayToggleButton(
                icon: "grid",
                title: "MGRS Grid",
                isActive: showMGRSGrid
            ) {
                showMGRSGrid.toggle()
                overlayCoordinator.saveSettings()
            }

            Text(loc.t("settings.mgrsGrid.2dOnly"))
                .font(.system(size: 9))
                .foregroundColor(.gray)
                .padding(.horizontal, 10)

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
