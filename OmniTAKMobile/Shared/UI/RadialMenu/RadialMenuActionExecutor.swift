//
//  RadialMenuActionExecutor.swift
//  OmniTAKMobile
//
//  Executes actions selected from the radial menu
//

import Foundation
import CoreLocation
import MapKit
import UIKit

// MARK: - Radial Menu Action Executor

/// Handles execution of radial menu actions with appropriate service calls
class RadialMenuActionExecutor {

    // MARK: - Main Execution

    /// Execute an action with the given context and services
    @discardableResult
    static func execute(
        action: RadialMenuAction,
        context: RadialMenuContext,
        services: RadialMenuServices
    ) -> Bool {
        switch action {
        case .dropMarker(let affiliation):
            return executeDropMarker(affiliation: affiliation, context: context, services: services)
        case .editMarker:
            return executeEditMarker(context: context, services: services)
        case .deleteMarker:
            return executeDeleteMarker(context: context, services: services)
        case .shareMarker:
            return executeShareMarker(context: context, services: services)
        case .navigateToMarker:
            return executeNavigateToMarker(context: context, services: services)
        case .markerInfo:
            return executeMarkerInfo(context: context, services: services)
        case .measure:
            return executeMeasure(context: context, services: services)
        case .measureDistance:
            return executeMeasureDistance(context: context, services: services)
        case .measureArea:
            return executeMeasureArea(context: context, services: services)
        case .measureBearing:
            return executeMeasureBearing(context: context, services: services)
        case .navigate:
            return executeNavigate(context: context, services: services)
        case .addWaypoint:
            return executeAddWaypoint(context: context, services: services)
        case .createRoute:
            return executeCreateRoute(context: context, services: services)
        case .openDrawingTools:
            return executeOpenDrawingTools(context: context)
        case .openDrawingsList:
            return executeOpenDrawingsList(context: context)
        case .openLayers:
            return executeOpenLayers(context: context)
        case .drawLine:
            return executeDrawLine(context: context)
        case .drawCircle:
            return executeDrawCircle(context: context)
        case .drawPolygon:
            return executeDrawPolygon(context: context)
        case .editDrawing:
            return executeEditDrawing(context: context, services: services)
        case .moveDrawing:
            return executeMoveDrawing(context: context, services: services)
        case .editVertices:
            return executeEditVertices(context: context, services: services)
        case .deleteDrawing:
            return executeDeleteDrawing(context: context, services: services)
        case .copyCoordinates:
            return executeCopyCoordinates(context: context)
        case .setRangeRings:
            return executeSetRangeRings(context: context, services: services)
        case .centerMap:
            return executeCenterMap(context: context)
        case .quickChat:
            return executeQuickChat(context: context)
        case .emergency:
            return executeEmergency(context: context)
        case .getInfo:
            return executeGetInfo(context: context)
        case .custom(let identifier):
            return executeCustomAction(identifier: identifier, context: context, services: services)
        }
    }

    // MARK: - Marker Drop Implementation

    private static func executeDropMarker(
        affiliation: MarkerAffiliation,
        context: RadialMenuContext,
        services: RadialMenuServices
    ) -> Bool {
        guard let pointDropperService = services.pointDropperService else { return false }

        let marker = pointDropperService.quickDrop(
            at: context.mapCoordinate,
            broadcast: false
        )

        if marker.affiliation != affiliation {
            var updatedMarker = marker
            updatedMarker.affiliation = affiliation
            updatedMarker.cotType = affiliation.cotType
            updatedMarker.iconName = affiliation.iconName
            pointDropperService.updateMarker(updatedMarker)
        }

        NotificationCenter.default.post(
            name: .radialMenuMarkerDropped,
            object: nil,
            userInfo: ["marker": marker, "affiliation": affiliation]
        )

        return true
    }

    // MARK: - Marker Management Implementation

    private static func executeEditMarker(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        // The shared markerContext radial menu is shown both for PointMarkers
        // (radial/point-dropper markers) AND for drawing shapes (marker, line,
        // circle, polygon) — so the Edit action has to dispatch to whichever
        // one was actually long-pressed. Matches the fallthrough already in
        // executeDeleteMarker.
        if let marker = context.pressedMarker {
            NotificationCenter.default.post(
                name: .radialMenuEditMarker,
                object: nil,
                userInfo: ["marker": marker]
            )
            return true
        }

        if let drawingId = context.pressedDrawingId,
           let drawingType = context.pressedDrawingType {
            NotificationCenter.default.post(
                name: .radialMenuEditDrawing,
                object: nil,
                userInfo: ["drawingId": drawingId, "drawingType": drawingType]
            )
            return true
        }

        return false
    }

    private static func executeDeleteMarker(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        if context.contextType == .drawing,
           let drawingId = context.pressedDrawingId,
           let drawingType = context.pressedDrawingType,
           let drawingStore = services.drawingStore {

            switch drawingType {
            case .marker:
                if let marker = drawingStore.markers.first(where: { $0.id == drawingId }) {
                    drawingStore.deleteMarker(marker)
                }
            case .line:
                if let line = drawingStore.lines.first(where: { $0.id == drawingId }) {
                    drawingStore.deleteLine(line)
                }
            case .circle:
                if let circle = drawingStore.circles.first(where: { $0.id == drawingId }) {
                    drawingStore.deleteCircle(circle)
                }
            case .polygon:
                if let polygon = drawingStore.polygons.first(where: { $0.id == drawingId }) {
                    drawingStore.deletePolygon(polygon)
                }
            }

            NotificationCenter.default.post(
                name: .radialMenuDrawingDeleted,
                object: nil,
                userInfo: ["drawingId": drawingId, "drawingType": drawingType]
            )

            return true
        }

        guard let marker = context.pressedMarker,
              let pointDropperService = services.pointDropperService else { return false }

        pointDropperService.deleteMarker(marker)

        NotificationCenter.default.post(
            name: .radialMenuMarkerDeleted,
            object: nil,
            userInfo: ["marker": marker]
        )

        return true
    }

    private static func executeShareMarker(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        guard let marker = context.pressedMarker else { return false }

        let shareText = generateShareText(for: marker)
        UIPasteboard.general.string = shareText

        NotificationCenter.default.post(
            name: .radialMenuShareMarker,
            object: nil,
            userInfo: ["marker": marker, "shareText": shareText]
        )

        return true
    }

    private static func executeNavigateToMarker(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        guard let routePlanningService = services.routePlanningService else { return false }

        // Get target coordinate and name
        let targetCoordinate: CLLocationCoordinate2D
        let targetName: String

        if let marker = context.pressedMarker {
            targetCoordinate = marker.coordinate
            targetName = marker.name
        } else if let waypoint = context.pressedWaypoint {
            targetCoordinate = waypoint.coordinate
            targetName = waypoint.name
        } else {
            targetCoordinate = context.mapCoordinate
            targetName = "Selected Location"
        }

        // Get current location for start point
        guard let currentLocation = routePlanningService.currentLocation else {
            // Fall back to posting notification to show route planning UI
            NotificationCenter.default.post(
                name: .radialMenuNavigationStarted,
                object: nil,
                userInfo: ["destination": targetCoordinate, "destinationName": targetName]
            )
            return true
        }

        // Create quick 2-point route from current location to target
        let startWaypoint = RouteWaypoint(
            coordinate: currentLocation.coordinate,
            name: "Current Location",
            order: 0,
            instruction: "Start navigation"
        )

        let endWaypoint = RouteWaypoint(
            coordinate: targetCoordinate,
            name: targetName,
            order: 1,
            instruction: "Arrive at \(targetName)"
        )

        // Create and start navigation route
        let route = routePlanningService.createRoute(
            name: "Navigate to \(targetName)",
            waypoints: [startWaypoint, endWaypoint],
            color: "#4CAF50",  // Green for navigation route
            lineStyle: .solid,
            lineOpacity: 0.9,
            lineWidth: 5.0,
            waypointIconStyle: .numbered,
            waypointPrefix: "",
            showDirectionArrows: true
        )

        // Start navigation on this route
        routePlanningService.startNavigation(for: route)

        NotificationCenter.default.post(
            name: .radialMenuNavigationStarted,
            object: nil,
            userInfo: ["route": route, "destination": targetCoordinate]
        )

        return true
    }

    private static func executeMarkerInfo(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        guard let marker = context.pressedMarker else { return false }

        NotificationCenter.default.post(
            name: .radialMenuShowMarkerInfo,
            object: nil,
            userInfo: ["marker": marker]
        )

        return true
    }

    // MARK: - Measurement Implementation

    private static func executeMeasure(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuMeasurementStarted,
            object: nil,
            userInfo: ["type": MeasurementType.distance, "coordinate": context.mapCoordinate]
        )
        return true
    }

    private static func executeMeasureDistance(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuMeasurementStarted,
            object: nil,
            userInfo: ["type": MeasurementType.distance, "coordinate": context.mapCoordinate]
        )
        return true
    }

    private static func executeMeasureArea(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuMeasurementStarted,
            object: nil,
            userInfo: ["type": MeasurementType.area, "coordinate": context.mapCoordinate]
        )
        return true
    }

    private static func executeMeasureBearing(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuMeasurementStarted,
            object: nil,
            userInfo: ["type": MeasurementType.bearing, "coordinate": context.mapCoordinate]
        )
        return true
    }

    // MARK: - Navigation Implementation

    private static func executeNavigate(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        guard let routePlanningService = services.routePlanningService else { return false }

        let targetCoordinate = context.mapCoordinate

        // Get current location for start point
        guard let currentLocation = routePlanningService.currentLocation else {
            // Fall back to posting notification to show route planning UI
            NotificationCenter.default.post(
                name: .radialMenuNavigationStarted,
                object: nil,
                userInfo: ["destination": targetCoordinate, "destinationName": "Nav Target"]
            )
            return true
        }

        // Create quick 2-point route from current location to target
        let startWaypoint = RouteWaypoint(
            coordinate: currentLocation.coordinate,
            name: "Current Location",
            order: 0,
            instruction: "Start navigation"
        )

        let endWaypoint = RouteWaypoint(
            coordinate: targetCoordinate,
            name: "Nav Target",
            order: 1,
            instruction: "Arrive at destination"
        )

        // Create and start navigation route
        let route = routePlanningService.createRoute(
            name: "Quick Route",
            waypoints: [startWaypoint, endWaypoint],
            color: "#4CAF50",  // Green for navigation route
            lineStyle: .solid,
            lineOpacity: 0.9,
            lineWidth: 5.0,
            waypointIconStyle: .numbered,
            waypointPrefix: "",
            showDirectionArrows: true
        )

        // Start navigation on this route
        routePlanningService.startNavigation(for: route)

        NotificationCenter.default.post(
            name: .radialMenuNavigationStarted,
            object: nil,
            userInfo: ["route": route, "coordinate": targetCoordinate]
        )

        return true
    }

    private static func executeAddWaypoint(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        // Use PointDropperService to create a visible marker on the map
        guard let pointDropperService = services.pointDropperService else { return false }

        // Create a neutral waypoint marker that displays immediately
        let marker = pointDropperService.quickDrop(
            at: context.mapCoordinate,
            broadcast: false
        )

        // Update to neutral affiliation with waypoint styling
        var updatedMarker = marker
        updatedMarker.affiliation = .neutral
        updatedMarker.cotType = MarkerAffiliation.neutral.cotType
        updatedMarker.iconName = "mappin.circle.fill"
        updatedMarker.name = generateWaypointName()
        pointDropperService.updateMarker(updatedMarker)

        NotificationCenter.default.post(
            name: .radialMenuWaypointAdded,
            object: nil,
            userInfo: ["marker": updatedMarker]
        )

        return true
    }

    private static func executeCreateRoute(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        // Open the real route planning screen (the same RouteListView the Tools
        // catalog opens). Previously this posted `radialMenuCreateRoute`, which
        // had no observer anywhere — a dead tap.
        NotificationCenter.default.post(
            name: .openToolSheet,
            object: nil,
            userInfo: ["id": "routes"]
        )
        return true
    }

    // MARK: - Drawing Implementation

    private static func executeOpenDrawingTools(context: RadialMenuContext) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuOpenDrawingTools,
            object: nil,
            userInfo: ["coordinate": context.mapCoordinate]
        )
        return true
    }

    private static func executeOpenDrawingsList(context: RadialMenuContext) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuOpenDrawingsList,
            object: nil,
            userInfo: [:]
        )
        return true
    }

    private static func executeOpenLayers(context: RadialMenuContext) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuShowLayers,
            object: nil,
            userInfo: [:]
        )
        return true
    }

    private static func executeDrawLine(context: RadialMenuContext) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuDrawLine,
            object: nil,
            userInfo: ["startCoordinate": context.mapCoordinate]
        )
        return true
    }

    private static func executeDrawCircle(context: RadialMenuContext) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuDrawCircle,
            object: nil,
            userInfo: ["centerCoordinate": context.mapCoordinate]
        )
        return true
    }

    private static func executeDrawPolygon(context: RadialMenuContext) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuDrawPolygon,
            object: nil,
            userInfo: ["startCoordinate": context.mapCoordinate]
        )
        return true
    }

    private static func executeEditDrawing(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        guard let drawingId = context.pressedDrawingId,
              let drawingType = context.pressedDrawingType else { return false }

        NotificationCenter.default.post(
            name: .radialMenuEditDrawing,
            object: nil,
            userInfo: ["drawingId": drawingId, "drawingType": drawingType]
        )

        return true
    }

    /// Issue #60 (move/reposition follow-up) — enter reposition mode for the
    /// pressed drawing. The map view observes `radialMenuMoveDrawing`, starts a
    /// DrawingMoveSession, and locks the camera while the operator drags the
    /// whole shape to a new position. Works for shapes selected from either
    /// engine (the radial Move action routes through here identically).
    private static func executeMoveDrawing(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        guard let drawingId = context.pressedDrawingId,
              let drawingType = context.pressedDrawingType else { return false }

        NotificationCenter.default.post(
            name: .radialMenuMoveDrawing,
            object: nil,
            userInfo: ["drawingId": drawingId, "drawingType": drawingType]
        )

        return true
    }

    /// Issue #84 — enter vertex-edit mode for the pressed drawing. The map view
    /// observes `radialMenuEditVertices`, starts a DrawingVertexEditSession,
    /// locks the camera, and renders draggable per-vertex handles (plus a
    /// radius handle for a circle) the operator drags to reshape. Routes through
    /// here identically for shapes selected from either engine.
    private static func executeEditVertices(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        guard let drawingId = context.pressedDrawingId,
              let drawingType = context.pressedDrawingType else { return false }

        NotificationCenter.default.post(
            name: .radialMenuEditVertices,
            object: nil,
            userInfo: ["drawingId": drawingId, "drawingType": drawingType]
        )

        return true
    }

    private static func executeDeleteDrawing(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        guard let drawingId = context.pressedDrawingId,
              let drawingType = context.pressedDrawingType,
              let drawingStore = services.drawingStore else { return false }

        switch drawingType {
        case .marker:
            if let marker = drawingStore.markers.first(where: { $0.id == drawingId }) {
                drawingStore.deleteMarker(marker)
            }
        case .line:
            if let line = drawingStore.lines.first(where: { $0.id == drawingId }) {
                drawingStore.deleteLine(line)
            }
        case .circle:
            if let circle = drawingStore.circles.first(where: { $0.id == drawingId }) {
                drawingStore.deleteCircle(circle)
            }
        case .polygon:
            if let polygon = drawingStore.polygons.first(where: { $0.id == drawingId }) {
                drawingStore.deletePolygon(polygon)
            }
        }

        NotificationCenter.default.post(
            name: .radialMenuDrawingDeleted,
            object: nil,
            userInfo: ["drawingId": drawingId, "drawingType": drawingType]
        )

        return true
    }

    // MARK: - Utility Implementation

    private static func executeCopyCoordinates(context: RadialMenuContext) -> Bool {
        let coordinate = context.mapCoordinate
        let coordString = formatCoordinate(coordinate)

        UIPasteboard.general.string = coordString

        NotificationCenter.default.post(
            name: .radialMenuCoordinatesCopied,
            object: nil,
            userInfo: ["coordinate": coordinate, "formattedString": coordString]
        )

        return true
    }

    private static func executeSetRangeRings(context: RadialMenuContext, services: RadialMenuServices) -> Bool {
        guard let measurementManager = services.measurementManager else { return false }

        measurementManager.startMeasurement(type: .rangeRing)
        measurementManager.handleMapTap(at: context.mapCoordinate)

        NotificationCenter.default.post(
            name: .radialMenuRangeRingsSet,
            object: nil,
            userInfo: ["center": context.mapCoordinate]
        )

        return true
    }

    private static func executeCenterMap(context: RadialMenuContext) -> Bool {
        NotificationCenter.default.post(
            name: .radialMenuCenterMap,
            object: nil,
            userInfo: ["coordinate": context.mapCoordinate]
        )
        return true
    }

    private static func executeQuickChat(context: RadialMenuContext) -> Bool {
        // Open the contacts list to start a chat — the real screen the Tools
        // catalog opens. Previously posted `radialMenuQuickChat` (no observer).
        NotificationCenter.default.post(
            name: .openToolSheet,
            object: nil,
            userInfo: ["id": "contacts"]
        )
        return true
    }

    private static func executeEmergency(context: RadialMenuContext) -> Bool {
        // Open the emergency beacon screen (confirm-first; does NOT auto-
        // broadcast). Previously posted `radialMenuEmergency` (no observer).
        NotificationCenter.default.post(
            name: .openToolSheet,
            object: nil,
            userInfo: ["id": "alert"]
        )
        return true
    }

    private static func executeGetInfo(context: RadialMenuContext) -> Bool {
        // "Get info" on a long-pressed point: copy the formatted coordinate to
        // the clipboard — a real, useful effect with no new UI. Previously
        // posted `radialMenuGetInfo`, which had no observer (a dead tap).
        let coordString = formatCoordinate(context.mapCoordinate)
        UIPasteboard.general.string = coordString
        NotificationCenter.default.post(
            name: .radialMenuCoordinatesCopied,
            object: nil,
            userInfo: ["coordinate": context.mapCoordinate, "formattedString": coordString]
        )
        return true
    }

    private static func executeCustomAction(
        identifier: String,
        context: RadialMenuContext,
        services: RadialMenuServices
    ) -> Bool {
        // Handle known custom actions with specific notifications
        switch identifier {
        case "dismiss":
            // Just dismiss the menu - no action needed
            // The menu dismisses automatically when any action is selected
            return true

        case "toggle_app_mode":
            NotificationCenter.default.post(
                name: .radialMenuShowAppModePicker,
                object: nil,
                userInfo: [:]
            )
            return true

        case "show_layers":
            NotificationCenter.default.post(
                name: .radialMenuShowLayers,
                object: nil,
                userInfo: [:]
            )
            return true

        case "meshtastic":
            // Open Meshtastic/mesh radio integration
            NotificationCenter.default.post(
                name: .radialMenuCustomAction,
                object: nil,
                userInfo: ["identifier": "open_meshtastic", "context": context]
            )
            return true

        case "save_location":
            // Civilian-mode "Save" — drop a neutral favorite marker at the
            // pressed point through the same PointDropperService path as
            // executeAddWaypoint. Previously this fell through to the
            // generic .radialMenuCustomAction post, whose only observer
            // handles draw_shape/meshtastic — a dead tap.
            guard let pointDropperService = services.pointDropperService else { return false }
            let marker = pointDropperService.quickDrop(
                at: context.mapCoordinate,
                broadcast: false
            )
            var updatedMarker = marker
            updatedMarker.affiliation = .neutral
            updatedMarker.cotType = MarkerAffiliation.neutral.cotType
            updatedMarker.iconName = "heart.fill"
            updatedMarker.name = generateSavedLocationName()
            pointDropperService.updateMarker(updatedMarker)
            NotificationCenter.default.post(
                name: .radialMenuWaypointAdded,
                object: nil,
                userInfo: ["marker": updatedMarker]
            )
            return true

        default:
            // Plugin SDK — registered radial action. `RadialMenuAction.custom`
            // wraps the identifier as "custom_<id>"; look it up in the host and
            // fire its onSelect with the pressed coordinate.
            if AppPluginHost.shared.fireRadialAction(
                identifier: "custom_\(identifier)",
                at: context.mapCoordinate
            ) {
                return true
            }

            NotificationCenter.default.post(
                name: .radialMenuCustomAction,
                object: nil,
                userInfo: ["identifier": identifier, "context": context]
            )
            return true
        }
    }

    // MARK: - Helper Methods

    private static func generateShareText(for marker: PointMarker) -> String {
        let coord = marker.coordinate
        let lat = String(format: "%.6f", coord.latitude)
        let lon = String(format: "%.6f", coord.longitude)

        var text = "\(marker.name)\n"
        text += "Affiliation: \(marker.affiliation.displayName)\n"
        text += "Location: \(lat), \(lon)\n"
        text += "Time: \(marker.formattedTimestamp)\n"

        if let remarks = marker.remarks, !remarks.isEmpty {
            text += "Remarks: \(remarks)\n"
        }

        if let salute = marker.saluteReport {
            text += "\n--- SALUTE ---\n"
            text += salute.formattedReport
        }

        return text
    }

    private static func generateWaypointName() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HHmm"
        return "WP-\(dateFormatter.string(from: Date()))"
    }

    private static func generateSavedLocationName() -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HHmm"
        return "SAVED-\(dateFormatter.string(from: Date()))"
    }

    /// Format a coordinate using the app-wide selected format.
    ///
    /// Reads "coordinateDisplayFormat" from UserDefaults — the same key that
    /// SettingsView, CoordinateDisplayView (self-position chip, PR #58), and
    /// MapStateManager all share.  Falls back to DMS when the key is absent or
    /// unrecognised (first-launch / mid-migration).
    private static func formatCoordinate(_ coord: CLLocationCoordinate2D) -> String {
        let formatString = UserDefaults.standard.string(forKey: "coordinateDisplayFormat") ?? ""
        let format = CoordinateDisplayFormat(rawValue: formatString) ?? .degreesMinutesSeconds
        return format.format(coord)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let radialMenuMarkerDropped = Notification.Name("radialMenuMarkerDropped")
    static let radialMenuEditMarker = Notification.Name("radialMenuEditMarker")
    static let radialMenuMarkerDeleted = Notification.Name("radialMenuMarkerDeleted")
    static let radialMenuDrawingDeleted = Notification.Name("radialMenuDrawingDeleted")
    static let radialMenuShareMarker = Notification.Name("radialMenuShareMarker")
    static let radialMenuNavigationStarted = Notification.Name("radialMenuNavigationStarted")
    static let radialMenuShowMarkerInfo = Notification.Name("radialMenuShowMarkerInfo")
    static let radialMenuMeasurementStarted = Notification.Name("radialMenuMeasurementStarted")
    static let radialMenuWaypointAdded = Notification.Name("radialMenuWaypointAdded")
    static let radialMenuCreateRoute = Notification.Name("radialMenuCreateRoute")
    static let radialMenuCoordinatesCopied = Notification.Name("radialMenuCoordinatesCopied")
    static let radialMenuRangeRingsSet = Notification.Name("radialMenuRangeRingsSet")
    static let radialMenuCenterMap = Notification.Name("radialMenuCenterMap")
    static let radialMenuQuickChat = Notification.Name("radialMenuQuickChat")
    static let radialMenuEmergency = Notification.Name("radialMenuEmergency")
    static let radialMenuGetInfo = Notification.Name("radialMenuGetInfo")
    static let radialMenuCustomAction = Notification.Name("radialMenuCustomAction")
    // Drawing notifications
    static let radialMenuOpenDrawingTools = Notification.Name("radialMenuOpenDrawingTools")
    static let radialMenuOpenDrawingsList = Notification.Name("radialMenuOpenDrawingsList")
    static let radialMenuDrawLine = Notification.Name("radialMenuDrawLine")
    static let radialMenuDrawCircle = Notification.Name("radialMenuDrawCircle")
    static let radialMenuDrawPolygon = Notification.Name("radialMenuDrawPolygon")
    /// Issue #16 — posted by the Tools tab (and the ATAKToolsView lasso
    /// entry) to ask the map to enter freehand multi-select mode.
    static let startLassoMode = Notification.Name("startLassoMode")
    /// Issue #16 — Tools tab popup posts this when the user taps the
    /// "Full Tools…" passthrough; MapViewController flips its existing
    /// showToolsMenu state so the 5x4 grid presents.
    static let showFullTools = Notification.Name("showFullTools")
    static let radialMenuEditDrawing = Notification.Name("radialMenuEditDrawing")
    /// Issue #60 (move/reposition follow-up) — posted by the drawing radial
    /// menu's Move action; the map view enters reposition mode for the shape.
    static let radialMenuMoveDrawing = Notification.Name("radialMenuMoveDrawing")
    /// Issue #84 — posted by the drawing radial menu's Edit Vertices action;
    /// the map view enters vertex-edit mode for the shape.
    static let radialMenuEditVertices = Notification.Name("radialMenuEditVertices")
    // App mode & layers
    static let radialMenuShowAppModePicker = Notification.Name("radialMenuShowAppModePicker")
    static let radialMenuShowLayers = Notification.Name("radialMenuShowLayers")
}
