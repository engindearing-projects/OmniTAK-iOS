import Foundation
import MapKit
import Combine

// MARK: - Drawing Tools Manager

class DrawingToolsManager: ObservableObject {
    @Published var isDrawingActive: Bool = false
    @Published var currentMode: DrawingMode?
    @Published var currentColor: DrawingColor = .red
    @Published var temporaryPoints: [CLLocationCoordinate2D] = []
    @Published var isSelectingRadius: Bool = false

    // Set to the new shape's id right after creation so the map view can
    // auto-present the rename sheet (#38). Reset to nil when the user
    // dismisses the sheet.
    @Published var pendingRenameID: UUID?

    // Circle-specific properties
    private var circleCenter: CLLocationCoordinate2D?

    private let drawingStore: DrawingStore

    init(drawingStore: DrawingStore) {
        self.drawingStore = drawingStore
    }

    // MARK: - Start Drawing

    func startDrawing(mode: DrawingMode) {
        isDrawingActive = true
        currentMode = mode
        temporaryPoints.removeAll()
        circleCenter = nil
        isSelectingRadius = false
        print("Started drawing mode: \(mode.rawValue)")
    }

    // MARK: - Handle Map Tap

    func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        guard isDrawingActive, let mode = currentMode else { return }

        switch mode {
        case .marker:
            createMarker(at: coordinate)

        case .line:
            temporaryPoints.append(coordinate)
            print("Line point added (\(temporaryPoints.count) points)")

        case .circle:
            if circleCenter == nil {
                // First tap - set center
                circleCenter = coordinate
                isSelectingRadius = true
                temporaryPoints = [coordinate]
                print("Circle center set, select radius point")
            } else {
                // Second tap - calculate radius and create circle
                createCircle(radiusPoint: coordinate)
            }

        case .polygon:
            temporaryPoints.append(coordinate)
            print("Polygon point added (\(temporaryPoints.count) points)")
        }
    }

    // MARK: - Create Drawings

    private func createMarker(at coordinate: CLLocationCoordinate2D) {
        let marker = MarkerDrawing(
            name: "Marker \(drawingStore.markers.count + 1)",
            color: currentColor,
            coordinate: coordinate
        )
        drawingStore.addMarker(marker)
        pendingRenameID = marker.id
        cancelDrawing()
        print("Created marker at \(coordinate.latitude), \(coordinate.longitude)")
    }

    private func createCircle(radiusPoint: CLLocationCoordinate2D) {
        guard let center = circleCenter else { return }

        let radius = center.distance(to: radiusPoint)
        let circle = CircleDrawing(
            name: "Circle \(drawingStore.circles.count + 1)",
            color: currentColor,
            center: center,
            radius: radius
        )
        drawingStore.addCircle(circle)
        // == S3:drawing-cot-broadcast BEGIN ==
        broadcastCircle(circle)
        // == S3:drawing-cot-broadcast END ==
        pendingRenameID = circle.id
        cancelDrawing()
        print("Created circle with radius: \(radius)m")
    }

    // MARK: - Complete Drawing

    func completeDrawing() {
        guard isDrawingActive, let mode = currentMode else { return }

        switch mode {
        case .marker:
            // Markers are created immediately
            cancelDrawing()

        case .line:
            if temporaryPoints.count >= 2 {
                let line = LineDrawing(
                    name: "Line \(drawingStore.lines.count + 1)",
                    color: currentColor,
                    coordinates: temporaryPoints
                )
                drawingStore.addLine(line)
                // == S3:drawing-cot-broadcast BEGIN ==
                broadcastLine(line)
                // == S3:drawing-cot-broadcast END ==
                pendingRenameID = line.id
                print("Created line with \(temporaryPoints.count) points")
            } else {
                print("Line needs at least 2 points")
            }
            cancelDrawing()

        case .circle:
            // Circles need two points (handled in handleMapTap)
            if circleCenter == nil {
                print("Circle needs center point")
            } else {
                print("Circle needs radius point")
            }

        case .polygon:
            if temporaryPoints.count >= 3 {
                let polygon = PolygonDrawing(
                    name: "Polygon \(drawingStore.polygons.count + 1)",
                    color: currentColor,
                    coordinates: temporaryPoints
                )
                drawingStore.addPolygon(polygon)
                // == S3:drawing-cot-broadcast BEGIN ==
                broadcastPolygon(polygon)
                // == S3:drawing-cot-broadcast END ==
                pendingRenameID = polygon.id
                print("Created polygon with \(temporaryPoints.count) points")
            } else {
                print("Polygon needs at least 3 points")
            }
            cancelDrawing()
        }
    }

    // == S3:drawing-cot-broadcast BEGIN ==
    /// Fan out a finished line as a `u-d-f` CoT event across every
    /// connected TAK server. Fire-and-forget; TAKService.sendCoT is
    /// tolerant of zero connected servers.
    private func broadcastLine(_ line: LineDrawing) {
        let xml = DrawingCoT.buildLine(
            uid: line.id.uuidString,
            callsign: line.label,
            points: line.coordinates,
            closed: false,
            colorHex: hexFor(line.color),
            widthPx: 3
        )
        _ = TAKService.shared.sendCoT(xml: xml)
    }

    private func broadcastPolygon(_ polygon: PolygonDrawing) {
        let xml = DrawingCoT.buildLine(
            uid: polygon.id.uuidString,
            callsign: polygon.label,
            points: polygon.coordinates,
            closed: true,
            colorHex: hexFor(polygon.color),
            widthPx: 3
        )
        _ = TAKService.shared.sendCoT(xml: xml)
    }

    private func broadcastCircle(_ circle: CircleDrawing) {
        let xml = DrawingCoT.buildCircle(
            uid: circle.id.uuidString,
            callsign: circle.label,
            center: circle.center,
            radiusM: circle.radius,
            colorHex: hexFor(circle.color),
            widthPx: 3
        )
        _ = TAKService.shared.sendCoT(xml: xml)
    }

    /// Map `DrawingColor` enum → "#RRGGBB" so the wire format matches
    /// what Android's `DrawingCoT.hexToArgbInt` expects.
    private func hexFor(_ color: DrawingColor) -> String {
        switch color {
        case .red: return "#FF0000"
        case .blue: return "#1E90FF"
        case .green: return "#4ADE80"
        case .yellow: return "#FFD700"
        case .orange: return "#FFA500"
        case .purple: return "#A020F0"
        case .cyan: return "#00FFFF"
        case .white: return "#FFFFFF"
        }
    }
    // == S3:drawing-cot-broadcast END ==

    // MARK: - Cancel Drawing

    func cancelDrawing() {
        isDrawingActive = false
        currentMode = nil
        temporaryPoints.removeAll()
        circleCenter = nil
        isSelectingRadius = false
        print("Drawing cancelled")
    }

    // MARK: - Temporary Overlays

    func getTemporaryOverlay() -> MKOverlay? {
        guard isDrawingActive, let mode = currentMode else { return nil }

        switch mode {
        case .marker:
            return nil

        case .line:
            if temporaryPoints.count >= 2 {
                return MKPolyline(coordinates: temporaryPoints, count: temporaryPoints.count)
            }

        case .circle:
            if let center = circleCenter, temporaryPoints.count == 2 {
                let radius = center.distance(to: temporaryPoints[1])
                return MKCircle(center: center, radius: radius)
            } else if let center = circleCenter {
                // Show small circle at center while selecting radius
                return MKCircle(center: center, radius: 50)
            }

        case .polygon:
            if temporaryPoints.count >= 2 {
                return MKPolyline(coordinates: temporaryPoints, count: temporaryPoints.count)
            }
        }

        return nil
    }

    func getTemporaryAnnotations() -> [MKPointAnnotation] {
        guard isDrawingActive else { return [] }

        return temporaryPoints.enumerated().map { index, coordinate in
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            annotation.title = "Point \(index + 1)"
            return annotation
        }
    }

    // MARK: - Helper Methods

    func canComplete() -> Bool {
        guard isDrawingActive, let mode = currentMode else { return false }

        switch mode {
        case .marker:
            return false // Markers are created immediately

        case .line:
            return temporaryPoints.count >= 2

        case .circle:
            return circleCenter != nil && temporaryPoints.count == 2

        case .polygon:
            return temporaryPoints.count >= 3
        }
    }

    func undoLastPoint() {
        guard isDrawingActive else { return }

        if currentMode == .circle && circleCenter != nil {
            // For circle, reset to center selection
            circleCenter = nil
            isSelectingRadius = false
            temporaryPoints.removeAll()
            print("Circle reset to center selection")
        } else if !temporaryPoints.isEmpty {
            temporaryPoints.removeLast()
            print("Removed last point (\(temporaryPoints.count) points remaining)")
        }
    }

    func getInstructions() -> String {
        guard isDrawingActive, let mode = currentMode else { return "" }

        switch mode {
        case .marker:
            return "Tap map to place marker"

        case .line:
            if temporaryPoints.isEmpty {
                return "Tap map to start line"
            } else if temporaryPoints.count == 1 {
                return "Tap map to add points (need 1+ more)"
            } else {
                return "Tap to add points, press Complete when done"
            }

        case .circle:
            if circleCenter == nil {
                return "Tap map to set circle center"
            } else {
                return "Tap map to set circle radius"
            }

        case .polygon:
            if temporaryPoints.isEmpty {
                return "Tap map to start polygon"
            } else if temporaryPoints.count < 3 {
                return "Tap map to add points (need \(3 - temporaryPoints.count) more)"
            } else {
                return "Tap to add points, press Complete when done"
            }
        }
    }
}
