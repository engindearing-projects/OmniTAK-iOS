//
//  MeasurementManager.swift
//  OmniTAKMobile
//
//  State management for measurement tools
//

import Foundation
import CoreLocation
import MapKit
import Combine

// MARK: - Measurement Manager

/// One set of range rings placed together: the ids of its rings, so "Remove" on
/// the banner can take back exactly that set and no other.
struct RangeRingPlacement: Equatable, Identifiable {
    let id: UUID
    let ringIDs: [UUID]
}

class MeasurementManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isActive: Bool = false
    @Published var currentMeasurementType: MeasurementType?
    @Published var currentMeasurement: Measurement?
    @Published var temporaryPoints: [CLLocationCoordinate2D] = []
    @Published var savedMeasurements: [Measurement] = []
    @Published var rangeRings: [RangeRing] = []
    @Published var rangeRingConfiguration: RangeRingConfiguration = .defaultConfiguration()
    @Published var liveResult: MeasurementResult = .empty()
    /// The set of rings placed last, while its "Range rings placed" banner is up.
    /// nil once the operator picks Remove or Keep, the banner times out, or the
    /// rings are cleared.
    @Published private(set) var lastRangeRingPlacement: RangeRingPlacement?

    // MARK: - Private Properties

    private let persistenceKey = "saved_measurements"
    private let rangeRingsKey = "saved_range_rings"
    private let configurationKey = "range_ring_configuration"
    private let defaults: UserDefaults
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void

    /// How long the banner stays up on its own after rings are placed.
    static let placementBannerSeconds: TimeInterval = 8

    // MARK: - Initialization

    /// - Parameters:
    ///   - defaults: where measurements, rings and the ring configuration are
    ///     kept. The app uses the standard store; tests pass an isolated suite.
    ///   - scheduleAfter: runs the banner's time-out. Tests capture it to fire by hand.
    init(
        defaults: UserDefaults = .standard,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.defaults = defaults
        self.scheduleAfter = scheduleAfter
        loadSavedData()
    }

    // MARK: - Range ring placement

    /// Puts down one set of rings, one per configured distance, around `center`.
    /// The set is remembered in `lastRangeRingPlacement` so the banner can take
    /// it back, and the banner hides itself after `placementBannerSeconds`.
    /// Every way of placing rings (the Measure tool's tap, the radial "Rings"
    /// item) comes through here.
    /// - Returns: the set, or nil when no distances are configured.
    @discardableResult
    func placeRangeRings(at center: CLLocationCoordinate2D) -> RangeRingPlacement? {
        let config = rangeRingConfiguration
        let rings = config.distances.map { distance in
            RangeRing(
                center: center,
                radiusMeters: distance,
                color: config.color,
                label: formatRangeRingLabel(distance)
            )
        }
        guard !rings.isEmpty else { return nil }

        rangeRings.append(contentsOf: rings)
        saveRangeRings()

        let placement = RangeRingPlacement(id: UUID(), ringIDs: rings.map(\.id))
        lastRangeRingPlacement = placement
        scheduleAfter(Self.placementBannerSeconds) { [weak self] in
            self?.acknowledgeRangeRingPlacement(placement)
        }
        return placement
    }

    /// Takes back one set of rings and nothing else: the banner's "Remove".
    /// Rings placed earlier, even at the same spot, stay. Saved either way.
    func removeRangeRings(of placement: RangeRingPlacement) {
        let doomed = Set(placement.ringIDs)
        if rangeRings.contains(where: { doomed.contains($0.id) }) {
            rangeRings.removeAll { doomed.contains($0.id) }
            saveRangeRings()
        }
        acknowledgeRangeRingPlacement(placement)
    }

    /// Hides the banner for `placement` and keeps its rings: "Keep", or the
    /// time-out. Does nothing if a newer set has replaced it, so an older
    /// timer cannot hide a newer banner.
    func acknowledgeRangeRingPlacement(_ placement: RangeRingPlacement) {
        if lastRangeRingPlacement == placement {
            lastRangeRingPlacement = nil
        }
    }

    // MARK: - Start Measurement

    func startMeasurement(type: MeasurementType) {
        isActive = true
        currentMeasurementType = type
        temporaryPoints.removeAll()
        currentMeasurement = Measurement(type: type)
        liveResult = .empty()
        print("Started measurement mode: \(type.rawValue)")
    }

    // MARK: - Handle Map Tap

    func handleMapTap(at coordinate: CLLocationCoordinate2D) {
        guard isActive, let type = currentMeasurementType else { return }

        switch type {
        case .distance:
            temporaryPoints.append(coordinate)
            updateLiveResult()
            print("Distance point added (\(temporaryPoints.count) points)")

        case .bearing:
            if temporaryPoints.count < 2 {
                temporaryPoints.append(coordinate)
                updateLiveResult()
                print("Bearing point \(temporaryPoints.count) added")

                if temporaryPoints.count == 2 {
                    // Bearing measurement complete
                    completeMeasurement()
                }
            }

        case .area:
            temporaryPoints.append(coordinate)
            updateLiveResult()
            print("Area point added (\(temporaryPoints.count) points)")

        case .rangeRing:
            if temporaryPoints.isEmpty {
                temporaryPoints = [coordinate]
                placeRangeRings(at: coordinate)
                cancelMeasurement()
                print("Range ring center set")
            }
        }
    }

    // MARK: - Update Live Result

    private func updateLiveResult() {
        guard let type = currentMeasurementType else { return }
        liveResult = MeasurementCalculator.calculate(type: type, points: temporaryPoints)
    }

    private func formatRangeRingLabel(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters))m"
        } else {
            return String(format: "%.1fkm", meters / 1000.0)
        }
    }

    // MARK: - Complete Measurement

    func completeMeasurement() {
        guard isActive, let type = currentMeasurementType else { return }

        var canComplete = false

        switch type {
        case .distance:
            canComplete = temporaryPoints.count >= 2

        case .bearing:
            canComplete = temporaryPoints.count >= 2

        case .area:
            canComplete = temporaryPoints.count >= 3

        case .rangeRing:
            canComplete = !temporaryPoints.isEmpty
        }

        if canComplete {
            var measurement = Measurement(type: type, points: temporaryPoints)
            measurement.result = liveResult
            savedMeasurements.append(measurement)
            saveMeasurements()
            print("Completed \(type.rawValue) measurement")
        } else {
            print("Cannot complete measurement - insufficient points")
        }

        cancelMeasurement()
    }

    // MARK: - Cancel Measurement

    func cancelMeasurement() {
        isActive = false
        currentMeasurementType = nil
        currentMeasurement = nil
        temporaryPoints.removeAll()
        liveResult = .empty()
        print("Measurement cancelled")
    }

    // MARK: - Undo Last Point

    func undoLastPoint() {
        guard isActive, !temporaryPoints.isEmpty else { return }
        temporaryPoints.removeLast()
        updateLiveResult()
        print("Removed last point (\(temporaryPoints.count) points remaining)")
    }

    // MARK: - Clear All Measurements

    func clearAllMeasurements() {
        savedMeasurements.removeAll()
        saveMeasurements()
        print("Cleared all measurements")
    }

    // MARK: - Remove Measurement

    func removeMeasurement(_ measurement: Measurement) {
        savedMeasurements.removeAll { $0.id == measurement.id }
        saveMeasurements()
        print("Removed measurement: \(measurement.name)")
    }

    // MARK: - Clear All Range Rings

    func clearAllRangeRings() {
        rangeRings.removeAll()
        lastRangeRingPlacement = nil
        saveRangeRings()
        print("Cleared all range rings")
    }

    // MARK: - Remove Range Ring

    func removeRangeRing(_ ring: RangeRing) {
        rangeRings.removeAll { $0.id == ring.id }
        saveRangeRings()
        print("Removed range ring: \(ring.label)")
    }

    // MARK: - Update Range Ring Configuration

    func updateRangeRingConfiguration(_ config: RangeRingConfiguration) {
        rangeRingConfiguration = config
        saveConfiguration()
    }

    func addCustomRangeRingDistance(_ distance: Double) {
        if !rangeRingConfiguration.distances.contains(distance) {
            rangeRingConfiguration.distances.append(distance)
            rangeRingConfiguration.distances.sort()
            saveConfiguration()
        }
    }

    func removeRangeRingDistance(_ distance: Double) {
        rangeRingConfiguration.distances.removeAll { $0 == distance }
        saveConfiguration()
    }

    // MARK: - Get Instructions

    func getInstructions() -> String {
        guard isActive, let type = currentMeasurementType else {
            return "Select a measurement tool to begin"
        }

        switch type {
        case .distance:
            if temporaryPoints.isEmpty {
                return "Tap map to start distance measurement"
            } else if temporaryPoints.count == 1 {
                return "Tap map to add more points (1 point placed)"
            } else {
                return "Tap to add points or press Complete (\(temporaryPoints.count) points)"
            }

        case .bearing:
            if temporaryPoints.isEmpty {
                return "Tap map to set start point"
            } else if temporaryPoints.count == 1 {
                return "Tap map to set end point"
            } else {
                return "Bearing measurement complete"
            }

        case .area:
            if temporaryPoints.isEmpty {
                return "Tap map to start polygon"
            } else if temporaryPoints.count < 3 {
                return "Tap to add vertices (need \(3 - temporaryPoints.count) more)"
            } else {
                return "Tap to add vertices or press Complete (\(temporaryPoints.count) vertices)"
            }

        case .rangeRing:
            if temporaryPoints.isEmpty {
                return "Tap map to set range ring center"
            } else {
                return "Range rings created"
            }
        }
    }

    // MARK: - Can Complete

    func canComplete() -> Bool {
        guard isActive, let type = currentMeasurementType else { return false }

        switch type {
        case .distance:
            return temporaryPoints.count >= 2

        case .bearing:
            return temporaryPoints.count >= 2

        case .area:
            return temporaryPoints.count >= 3

        case .rangeRing:
            return !temporaryPoints.isEmpty
        }
    }

    // MARK: - Get Temporary Overlay

    func getTemporaryOverlay() -> MKOverlay? {
        guard isActive, let type = currentMeasurementType else { return nil }

        switch type {
        case .distance:
            if temporaryPoints.count >= 2 {
                return MKPolyline(coordinates: temporaryPoints, count: temporaryPoints.count)
            }

        case .bearing:
            if temporaryPoints.count >= 2 {
                return MKPolyline(coordinates: temporaryPoints, count: temporaryPoints.count)
            }

        case .area:
            if temporaryPoints.count >= 3 {
                return MKPolygon(coordinates: temporaryPoints, count: temporaryPoints.count)
            } else if temporaryPoints.count >= 2 {
                return MKPolyline(coordinates: temporaryPoints, count: temporaryPoints.count)
            }

        case .rangeRing:
            // Range rings are rendered separately
            break
        }

        return nil
    }

    // MARK: - Get Temporary Annotations

    func getTemporaryAnnotations() -> [MKPointAnnotation] {
        guard isActive else { return [] }

        return temporaryPoints.enumerated().map { index, coordinate in
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            annotation.title = "Point \(index + 1)"

            if let type = currentMeasurementType {
                switch type {
                case .bearing:
                    if index == 0 {
                        annotation.title = "Start"
                    } else if index == 1 {
                        annotation.title = "End"
                    }
                case .area:
                    annotation.title = "Vertex \(index + 1)"
                default:
                    break
                }
            }

            return annotation
        }
    }

    // MARK: - Persistence

    private func saveMeasurements() {
        if let encoded = try? JSONEncoder().encode(savedMeasurements) {
            defaults.set(encoded, forKey: persistenceKey)
        }
    }

    private func saveRangeRings() {
        if let encoded = try? JSONEncoder().encode(rangeRings) {
            defaults.set(encoded, forKey: rangeRingsKey)
        }
    }

    private func saveConfiguration() {
        if let encoded = try? JSONEncoder().encode(rangeRingConfiguration) {
            defaults.set(encoded, forKey: configurationKey)
        }
    }

    private func loadSavedData() {
        // Load measurements
        if let data = defaults.data(forKey: persistenceKey),
           let measurements = try? JSONDecoder().decode([Measurement].self, from: data) {
            savedMeasurements = measurements
        }

        // Load range rings
        if let data = defaults.data(forKey: rangeRingsKey),
           let rings = try? JSONDecoder().decode([RangeRing].self, from: data) {
            rangeRings = rings
        }

        // Load configuration
        if let data = defaults.data(forKey: configurationKey),
           let config = try? JSONDecoder().decode(RangeRingConfiguration.self, from: data) {
            rangeRingConfiguration = config
        }
    }

    // MARK: - Copy to Clipboard

    func copyResultToClipboard() -> String {
        guard let type = currentMeasurementType else { return "" }

        var text = ""

        switch type {
        case .distance:
            if let meters = liveResult.distanceMeters {
                text = "Distance: \(MeasurementCalculator.formatDistance(meters))\n"
                text += "Miles: \(String(format: "%.3f mi", liveResult.distanceMiles ?? 0))\n"
                text += "Nautical Miles: \(String(format: "%.3f NM", liveResult.distanceNauticalMiles ?? 0))\n"
                text += "Feet: \(String(format: "%.1f ft", liveResult.distanceFeet ?? 0))"
            }

        case .bearing:
            if let degrees = liveResult.bearingDegrees {
                text = "Bearing: \(MeasurementCalculator.formatBearing(degrees))\n"
                text += "Mils: \(String(format: "%.0f mil", liveResult.bearingMils ?? 0))\n"
                text += "Back Bearing: \(String(format: "%.1f\u{00B0}", liveResult.backBearingDegrees ?? 0))"

                if let meters = liveResult.distanceMeters {
                    text += "\nDistance: \(MeasurementCalculator.formatDistance(meters))"
                }
            }

        case .area:
            if let sqMeters = liveResult.areaSquareMeters {
                text = "Area: \(MeasurementCalculator.formatArea(sqMeters))\n"
                text += "Acres: \(String(format: "%.3f ac", liveResult.areaAcres ?? 0))\n"
                text += "Hectares: \(String(format: "%.3f ha", liveResult.areaHectares ?? 0))\n"
                text += "Square Miles: \(String(format: "%.6f mi\u{00B2}", liveResult.areaSquareMiles ?? 0))"

                if let perimeter = liveResult.perimeterMeters {
                    text += "\nPerimeter: \(MeasurementCalculator.formatDistance(perimeter))"
                }
            }

        case .rangeRing:
            text = "Range Ring Center\n"
            if let center = temporaryPoints.first {
                text += "Location: \(center.formatDecimalDegrees())\n"
                text += "Rings: \(rangeRingConfiguration.distances.map { formatRangeRingLabel($0) }.joined(separator: ", "))"
            }
        }

        return text
    }
}
