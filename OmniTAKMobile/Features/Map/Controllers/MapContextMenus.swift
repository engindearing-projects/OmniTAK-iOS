//
//  MapContextMenus.swift
//  OmniTAKMobile
//
//  Context-specific menu configurations for different map interactions
//  Mode-aware radial menus that adapt to Tactical/Fire/SAR/Civilian modes
//

import Foundation
import SwiftUI
import CoreLocation
import MapKit

// MARK: - Range ring entries

/// What the map's radial menus say about range rings.
enum RangeRingMenu {
    static let clearLabel = "Clear Rings"

    /// "Clear Rings" is offered only while there is something to clear.
    static func offersClear(rangeRingCount: Int) -> Bool {
        rangeRingCount > 0
    }
}

extension RadialMenuConfiguration {
    /// This menu plus "Clear Rings" when rings exist. "Rings" is left as it is,
    /// so a second set can still be placed.
    func offeringClearRings(rangeRingCount: Int) -> RadialMenuConfiguration {
        guard RangeRingMenu.offersClear(rangeRingCount: rangeRingCount),
              !items.contains(where: { $0.action == .clearRangeRings }) else { return self }
        var copy = self
        copy.items.append(RadialMenuItem(
            icon: "circle.slash",
            label: RangeRingMenu.clearLabel,
            color: Self.atakPurple,
            action: .clearRangeRings
        ))
        return copy
    }
}

// MARK: - Map Context Menu Configurations

extension RadialMenuConfiguration {

    // ATAK-style tactical colors
    private static let atakRed = Color(hex: "#C62828")      // Hostile red
    private static let atakBlue = Color(hex: "#1565C0")     // Friendly blue
    private static let atakGreen = Color(hex: "#2E7D32")    // Navigation green
    private static let atakOrange = Color(hex: "#EF6C00")   // Warning/Measure orange
    private static let atakTan = Color(hex: "#8D6E63")      // Neutral tan
    private static let atakGray = Color(hex: "#546E7A")     // Tool gray
    private static let atakOlive = Color(hex: "#7CB342")    // Olive/action
    private static let atakPurple = Color(hex: "#7B1FA2")   // Drawing purple
    private static let atakYellow = Color(hex: "#FDD835")   // Unknown yellow

    // MARK: - Mode-Aware Map Context Menu

    /// Returns the appropriate radial menu based on current app mode
    static func mapContextMenu(at coordinate: CLLocationCoordinate2D) -> RadialMenuConfiguration {
        let currentMode = AppModeManager.shared.currentMode

        switch currentMode {
        case .tactical:
            return tacticalMapMenu(at: coordinate)
        case .fireRescue:
            return fireRescueMapMenu(at: coordinate)
        case .sar:
            return sarMapMenu(at: coordinate)
        case .civilian:
            return civilianMapMenu(at: coordinate)
        }
    }

    // MARK: - Tactical Mode Menu

    /// Military/Law Enforcement focused menu - ATAK colors
    private static func tacticalMapMenu(at coordinate: CLLocationCoordinate2D) -> RadialMenuConfiguration {
        let items = [
            // Top - Hostile marker (primary threat marking)
            RadialMenuItem(
                icon: "scope",
                label: "Hostile",
                color: atakRed,
                action: .dropMarker(.hostile)
            ),
            // Top-right - Friendly marker
            RadialMenuItem(
                icon: "shield.fill",
                label: "Friendly",
                color: atakBlue,
                action: .dropMarker(.friendly)
            ),
            // Right - Waypoint
            RadialMenuItem(
                icon: "mappin.circle.fill",
                label: "Point",
                color: atakOlive,
                action: .addWaypoint
            ),
            // Bottom-right - Route/Navigate
            RadialMenuItem(
                icon: "arrow.triangle.turn.up.right.diamond.fill",
                label: "Route",
                color: atakGreen,
                action: .navigate
            ),
            // Bottom - Measure
            RadialMenuItem(
                icon: "ruler.fill",
                label: "Measure",
                color: atakOrange,
                action: .measure
            ),
            // Bottom-left - Layers
            RadialMenuItem(
                icon: "square.stack.3d.up.fill",
                label: "Layers",
                color: atakTan,
                action: .custom("show_layers")
            ),
            // Left - Mode switch
            RadialMenuItem(
                icon: "shield.checkered",
                label: "Mode",
                color: atakGray,
                action: .custom("toggle_app_mode")
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 130,   // Slightly smaller with fewer items
            itemSize: 56,  // Larger touch targets
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - Fire/Rescue Mode Menu

    /// Firefighting and EMS focused menu - ATAK colors
    private static func fireRescueMapMenu(at coordinate: CLLocationCoordinate2D) -> RadialMenuConfiguration {
        let items = [
            // Top - Hazard marker (fire, chemical, etc.)
            RadialMenuItem(
                icon: "flame.fill",
                label: "Hazard",
                color: atakRed,
                action: .dropMarker(.hostile)
            ),
            // Top-right - Crew/Unit marker
            RadialMenuItem(
                icon: "person.3.fill",
                label: "Crew",
                color: atakBlue,
                action: .dropMarker(.friendly)
            ),
            // Right - Resource (equipment, water source)
            RadialMenuItem(
                icon: "wrench.and.screwdriver.fill",
                label: "Resource",
                color: atakGreen,
                action: .dropMarker(.neutral)
            ),
            // Bottom-right - ICP (Incident Command Post)
            RadialMenuItem(
                icon: "building.2.fill",
                label: "ICP",
                color: atakOlive,
                action: .addWaypoint
            ),
            // Bottom - Draw (perimeters, staging)
            RadialMenuItem(
                icon: "pencil.tip.crop.circle",
                label: "Draw",
                color: atakPurple,
                action: .openDrawingTools
            ),
            // Bottom-left - Layers
            RadialMenuItem(
                icon: "square.stack.3d.up.fill",
                label: "Layers",
                color: atakTan,
                action: .custom("show_layers")
            ),
            // Left - Mode switch
            RadialMenuItem(
                icon: "flame.fill",
                label: "Mode",
                color: atakGray,
                action: .custom("toggle_app_mode")
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 130,
            itemSize: 56,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - SAR Mode Menu

    /// Search and Rescue focused menu - ATAK colors
    private static func sarMapMenu(at coordinate: CLLocationCoordinate2D) -> RadialMenuConfiguration {
        let items = [
            // Top - Clue marker (evidence, sighting)
            RadialMenuItem(
                icon: "eye.fill",
                label: "Clue",
                color: atakYellow,
                action: .dropMarker(.unknown)
            ),
            // Top-right - Searcher/Team position
            RadialMenuItem(
                icon: "figure.walk",
                label: "Searcher",
                color: atakBlue,
                action: .dropMarker(.friendly)
            ),
            // Right - POI (Point of Interest)
            RadialMenuItem(
                icon: "star.fill",
                label: "POI",
                color: atakOlive,
                action: .addWaypoint
            ),
            // Bottom-right - Hazard
            RadialMenuItem(
                icon: "exclamationmark.triangle.fill",
                label: "Hazard",
                color: atakRed,
                action: .dropMarker(.hostile)
            ),
            // Bottom - Draw (search areas)
            RadialMenuItem(
                icon: "pencil.tip.crop.circle",
                label: "Draw",
                color: atakPurple,
                action: .openDrawingTools
            ),
            // Bottom-left - Layers
            RadialMenuItem(
                icon: "square.stack.3d.up.fill",
                label: "Layers",
                color: atakTan,
                action: .custom("show_layers")
            ),
            // Left - Mode switch
            RadialMenuItem(
                icon: "binoculars.fill",
                label: "Mode",
                color: atakGray,
                action: .custom("toggle_app_mode")
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 130,
            itemSize: 56,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - Civilian Mode Menu

    /// General use / consumer focused menu - ATAK colors
    private static func civilianMapMenu(at coordinate: CLLocationCoordinate2D) -> RadialMenuConfiguration {
        let items = [
            // Top - Drop pin (primary action)
            RadialMenuItem(
                icon: "mappin.circle.fill",
                label: "Pin",
                color: atakOlive,
                action: .addWaypoint
            ),
            // Top-right - Navigate
            RadialMenuItem(
                icon: "location.fill",
                label: "Navigate",
                color: atakGreen,
                action: .navigate
            ),
            // Right - Measure
            RadialMenuItem(
                icon: "ruler.fill",
                label: "Measure",
                color: atakOrange,
                action: .measure
            ),
            // Bottom-right - Draw
            RadialMenuItem(
                icon: "pencil.tip.crop.circle",
                label: "Draw",
                color: atakPurple,
                action: .openDrawingTools
            ),
            // Bottom - Layers
            RadialMenuItem(
                icon: "map.fill",
                label: "Layers",
                color: atakTan,
                action: .custom("show_layers")
            ),
            // Bottom-left - Saved places
            RadialMenuItem(
                icon: "heart.fill",
                label: "Save",
                color: atakRed,
                action: .custom("save_location")
            ),
            // Left - Mode switch
            RadialMenuItem(
                icon: "figure.wave",
                label: "Mode",
                color: atakGray,
                action: .custom("toggle_app_mode")
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 130,
            itemSize: 56,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - Extended Map Context Menu (with affiliation markers)

    /// Extended menu for quick marker placement with affiliation options
    static func extendedMapContextMenu(at coordinate: CLLocationCoordinate2D) -> RadialMenuConfiguration {
        let items = [
            // Top - Hostile (red in ATAK)
            RadialMenuItem(
                icon: "scope",
                label: "Hostile",
                color: atakRed,
                action: .dropMarker(.hostile)
            ),
            // Top-right - Friendly
            RadialMenuItem(
                icon: "shield.fill",
                label: "Friendly",
                color: atakBlue,
                action: .dropMarker(.friendly)
            ),
            // Right - Unknown
            RadialMenuItem(
                icon: "questionmark.diamond.fill",
                label: "Unknown",
                color: atakYellow,
                action: .dropMarker(.unknown)
            ),
            // Bottom-right - Neutral
            RadialMenuItem(
                icon: "circle.fill",
                label: "Neutral",
                color: atakGreen,
                action: .dropMarker(.neutral)
            ),
            // Bottom - Waypoint
            RadialMenuItem(
                icon: "mappin.circle.fill",
                label: "Point",
                color: atakOlive,
                action: .addWaypoint
            ),
            // Bottom-left - Measure
            RadialMenuItem(
                icon: "ruler.fill",
                label: "Meas",
                color: atakOrange,
                action: .measure
            ),
            // Left - Navigate
            RadialMenuItem(
                icon: "arrow.triangle.turn.up.right.diamond.fill",
                label: "Route",
                color: atakTan,
                action: .navigate
            ),
            // Top-left - Copy Location
            RadialMenuItem(
                icon: "doc.on.clipboard",
                label: "Copy",
                color: atakGray,
                action: .copyCoordinates
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 140,
            itemSize: 54,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - Point Marker Context Menu

    /// Menu for long-press on existing point marker - ATAK style
    static func markerContextMenu(for marker: PointMarker) -> RadialMenuConfiguration {
        let items = [
            // Top - Navigate to
            RadialMenuItem(
                icon: "arrow.triangle.turn.up.right.diamond.fill",
                label: "Navigate",
                color: atakGreen,
                action: .navigateToMarker
            ),
            // Top-right - Edit
            RadialMenuItem(
                icon: "pencil",
                label: "Edit",
                color: atakOrange,
                action: .editMarker
            ),
            // Right - Share
            RadialMenuItem(
                icon: "square.and.arrow.up.fill",
                label: "Share",
                color: atakBlue,
                action: .shareMarker
            ),
            // Bottom-right - Measure to
            RadialMenuItem(
                icon: "ruler.fill",
                label: "Distance",
                color: atakTan,
                action: .measureDistance
            ),
            // Bottom - Delete (red)
            RadialMenuItem(
                icon: "trash.fill",
                label: "Delete",
                color: atakRed,
                action: .deleteMarker
            ),
            // Bottom-left - Copy coordinates
            RadialMenuItem(
                icon: "doc.on.clipboard",
                label: "Copy",
                color: atakGray,
                action: .copyCoordinates
            ),
            // Left - Range rings
            RadialMenuItem(
                icon: "circle.dashed",
                label: "Rings",
                color: atakPurple,
                action: .setRangeRings
            ),
            // Top-left - Info
            RadialMenuItem(
                icon: "info.circle.fill",
                label: "Info",
                color: atakOlive,
                action: .markerInfo
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 140,
            itemSize: 54,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - Waypoint Context Menu

    /// Menu for long-press on waypoint - ATAK style
    static func waypointContextMenu(for waypoint: Waypoint) -> RadialMenuConfiguration {
        let items = [
            RadialMenuItem(
                icon: "arrow.triangle.turn.up.right.diamond.fill",
                label: "Navigate",
                color: atakGreen,
                action: .navigateToMarker
            ),
            RadialMenuItem(
                icon: "pencil",
                label: "Edit",
                color: atakOrange,
                action: .editMarker
            ),
            RadialMenuItem(
                icon: "ruler.fill",
                label: "Distance",
                color: atakTan,
                action: .measureDistance
            ),
            RadialMenuItem(
                icon: "trash.fill",
                label: "Delete",
                color: atakRed,
                action: .deleteMarker
            ),
            RadialMenuItem(
                icon: "doc.on.clipboard",
                label: "Copy",
                color: atakGray,
                action: .copyCoordinates
            ),
            RadialMenuItem(
                icon: "info.circle.fill",
                label: "Info",
                color: atakBlue,
                action: .getInfo
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 130,
            itemSize: 54,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - CoT Unit Context Menu

    /// Menu for long-press on CoT unit (friendly, hostile, etc.) - ATAK style
    static func unitContextMenu(for annotation: MKAnnotation) -> RadialMenuConfiguration {
        let items = [
            RadialMenuItem(
                icon: "arrow.triangle.turn.up.right.diamond.fill",
                label: "Navigate",
                color: atakGreen,
                action: .navigateToMarker
            ),
            RadialMenuItem(
                icon: "message.fill",
                label: "Chat",
                color: atakBlue,
                action: .quickChat
            ),
            RadialMenuItem(
                icon: "ruler.fill",
                label: "Distance",
                color: atakOrange,
                action: .measureDistance
            ),
            RadialMenuItem(
                icon: "doc.on.clipboard",
                label: "Copy",
                color: atakGray,
                action: .copyCoordinates
            ),
            RadialMenuItem(
                icon: "circle.dashed",
                label: "Rings",
                color: atakPurple,
                action: .setRangeRings
            ),
            RadialMenuItem(
                icon: "info.circle.fill",
                label: "Info",
                color: atakOlive,
                action: .getInfo
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 130,
            itemSize: 54,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - Measurement Context Menu

    /// Menu for measurement-specific actions - ATAK style
    static func measurementContextMenu() -> RadialMenuConfiguration {
        let items = [
            RadialMenuItem(
                icon: "ruler.fill",
                label: "Distance",
                color: atakOrange,
                action: .measureDistance
            ),
            RadialMenuItem(
                icon: "square.dashed",
                label: "Area",
                color: atakTan,
                action: .measureArea
            ),
            RadialMenuItem(
                icon: "location.north.line.fill",
                label: "Bearing",
                color: atakBlue,
                action: .measureBearing
            ),
            RadialMenuItem(
                icon: "circle.dashed",
                label: "Rings",
                color: atakPurple,
                action: .setRangeRings
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 115,
            itemSize: 54,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - Quick Actions Menu

    /// Compact 4-item menu for quick tactical actions - ATAK style
    static func quickActionsMenu(at coordinate: CLLocationCoordinate2D) -> RadialMenuConfiguration {
        let items = [
            RadialMenuItem(
                icon: "scope",
                label: "Hostile",
                color: atakRed,
                action: .dropMarker(.hostile)
            ),
            RadialMenuItem(
                icon: "shield.fill",
                label: "Friendly",
                color: atakBlue,
                action: .dropMarker(.friendly)
            ),
            RadialMenuItem(
                icon: "mappin.circle.fill",
                label: "Waypoint",
                color: atakOlive,
                action: .addWaypoint
            ),
            RadialMenuItem(
                icon: "ruler.fill",
                label: "Measure",
                color: atakOrange,
                action: .measure
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 115,
            itemSize: 54,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - Emergency Context Menu

    /// Menu for emergency/SOS actions - ATAK style
    static func emergencyMenu() -> RadialMenuConfiguration {
        let items = [
            RadialMenuItem(
                icon: "exclamationmark.triangle.fill",
                label: "SOS",
                color: atakRed,
                action: .emergency
            ),
            RadialMenuItem(
                icon: "cross.circle.fill",
                label: "Medical",
                color: Color(hex: "#E91E63"),  // Medical pink/magenta
                action: .custom("medical_emergency")
            ),
            RadialMenuItem(
                icon: "shield.fill",
                label: "Security",
                color: atakBlue,
                action: .custom("security_alert")
            ),
            RadialMenuItem(
                icon: "location.fill",
                label: "Broadcast",
                color: atakOrange,
                action: .custom("broadcast_position")
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 115,
            itemSize: 54,
            hapticFeedback: true,
            showLabels: true
        )
    }

    // MARK: - Drawing Context Menu

    /// Menu for drawing/annotation actions - ATAK style
    static func drawingContextMenu() -> RadialMenuConfiguration {
        let items = [
            RadialMenuItem(
                icon: "pencil.tip",
                label: "Freehand",
                color: atakPurple,
                action: .custom("freehand_draw")
            ),
            RadialMenuItem(
                icon: "line.diagonal",
                label: "Line",
                color: atakOrange,
                action: .drawLine
            ),
            RadialMenuItem(
                icon: "circle",
                label: "Circle",
                color: atakBlue,
                action: .drawCircle
            ),
            RadialMenuItem(
                icon: "square",
                label: "Rectangle",
                color: atakGreen,
                action: .custom("draw_rectangle")
            ),
            RadialMenuItem(
                icon: "pentagon",
                label: "Polygon",
                color: atakTan,
                action: .drawPolygon
            ),
            RadialMenuItem(
                icon: "arrow.uturn.backward",
                label: "Undo",
                color: atakGray,
                action: .custom("undo_draw")
            )
        ]

        return RadialMenuConfiguration(
            items: items,
            radius: 130,
            itemSize: 54,
            hapticFeedback: true,
            showLabels: true
        )
    }
}

// MARK: - Marker Radial Feedback (Info / Share / Copy)

/// Body-level observers for the marker radial actions that previously posted
/// notifications with no subscriber — silent dead taps in a shipping build:
///   - `.radialMenuShowMarkerInfo`    → present `MarkerInfoSheet` (modal sheet)
///   - `.radialMenuShareMarker`       → present the system share sheet
///   - `.radialMenuCoordinatesCopied` → transient "Copied" HUD toast
///
/// Attached at `ATAKMapView.body` level (next to modalSheets / lifecycle
/// handlers) so it fires on BOTH map engines, per the design law that modal
/// sheets are the only chrome allowed over the sacred full-screen map. Lives
/// in its own ViewModifier so the observers type-check independently of the
/// already-maxed ATAKMapView body expression.
struct MarkerRadialFeedback: ViewModifier {
    @ObservedObject private var loc = LocalizationManager.shared
    @State private var infoMarker: PointMarker?
    @State private var shareItem: ShareTextItem?
    @State private var toast: String?

    /// Identifiable wrapper so `.sheet(item:)` accepts the share text.
    private struct ShareTextItem: Identifiable {
        let text: String
        var id: String { text }
    }

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuShowMarkerInfo)) { note in
                if let marker = note.userInfo?["marker"] as? PointMarker {
                    infoMarker = marker
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuShareMarker)) { note in
                if let text = note.userInfo?["shareText"] as? String {
                    shareItem = ShareTextItem(text: text)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .radialMenuCoordinatesCopied)) { _ in
                showToast(loc.t("radial.copied"))
            }
            .sheet(item: $infoMarker) { marker in
                MarkerInfoSheet(marker: marker)
            }
            .sheet(item: $shareItem) { item in
                LassoShareSheet(activityItems: [item.text])
            }
            .overlay(alignment: .top) {
                if let toast {
                    Text(toast)
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.black.opacity(0.8)))
                        .padding(.top, 60)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { toast = nil }
        }
    }
}

// MARK: - Marker Info Sheet

/// Read-only detail sheet for a point marker, presented by the radial "Info"
/// action. Replaces the deleted MarkerInfoPanel (which depended on the dead
/// EnhancedCoTMarker store) with a plain modal over the live PointMarker.
struct MarkerInfoSheet: View {
    let marker: PointMarker
    @ObservedObject private var loc = LocalizationManager.shared
    @Environment(\.dismiss) private var dismiss
    /// #178 — drives the live "Age: Nm ago" relative label while the sheet is
    /// open (ticks once a second), mirroring the Android marker detail sheet.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            List {
                Section {
                    infoRow(loc.t("markerInfo.name"), marker.name)
                    infoRow(loc.t("markerInfo.affiliation"), marker.affiliation.displayName)
                    // CoT is a bare acronym — intentionally untranslated.
                    infoRow("CoT", marker.cotType)
                    // #178 / #180 — age (since drop) + source. A marker the
                    // operator dropped never traversed a link, so it's Local.
                    if let age = CoTAge.relative(receivedAt: marker.timestamp, now: now) {
                        infoRow("Age", age)
                    }
                    infoRow("Source", CoTSource.local.label)
                }
                Section(loc.t("markerInfo.coordinates")) {
                    // MGRS / Lat-Lon labels are acronyms, left as-is (same
                    // convention as the Settings coordinate-format picker).
                    infoRow("MGRS", MGRSConverter.latLonToMGRS(marker.coordinate).formatted())
                    infoRow("Lat / Lon", String(format: "%.6f, %.6f",
                                                marker.coordinate.latitude,
                                                marker.coordinate.longitude))
                    if let alt = marker.altitude {
                        infoRow(loc.t("markerInfo.altitude"), String(format: "%.0f m HAE", alt))
                    }
                }
                Section {
                    infoRow(loc.t("markerInfo.created"), marker.formattedTimestamp)
                    if let remarks = marker.remarks, !remarks.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(loc.t("markerInfo.remarks"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(remarks)
                        }
                    }
                }
            }
            .navigationTitle(loc.t("markerInfo.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(loc.t("settings.done")) { dismiss() }
                }
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
