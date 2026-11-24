//
//  EmergencyBeaconService.swift
//  OmniTAKMobile
//
//  Emergency beacon/SOS service for safety-critical situations
//  Generates and broadcasts emergency CoT messages following ATAK standards
//

import Foundation
import Combine
import CoreLocation
import UIKit
import AudioToolbox

// MARK: - Emergency Types

enum EmergencyType: String, CaseIterable {
    case alert911 = "911 Alert"
    case inContact = "In Contact"
    case alert = "Alert"
    case cancel = "Cancel"

    var cotType: String {
        switch self {
        case .alert911:
            return "b-a-o-tbl"
        case .inContact:
            return "a-f-G-U-C-I"
        case .alert:
            return "b-a-o-tbl"
        case .cancel:
            return "b-a-o-can"
        }
    }

    var displayName: String {
        switch self {
        case .alert911:
            return "911 Emergency"
        case .inContact:
            return "In Contact"
        case .alert:
            return "Alert"
        case .cancel:
            return "Cancel Emergency"
        }
    }

    var icon: String {
        switch self {
        case .alert911:
            return "phone.fill"
        case .inContact:
            return "person.wave.2.fill"
        case .alert:
            return "exclamationmark.triangle.fill"
        case .cancel:
            return "xmark.circle.fill"
        }
    }

    var color: String {
        switch self {
        case .alert911:
            return "#FF0000"
        case .inContact:
            return "#FFA500"
        case .alert:
            return "#FF6600"
        case .cancel:
            return "#00FF00"
        }
    }

    var defaultMessage: String {
        switch self {
        case .alert911:
            return "EMERGENCY - NEED 911"
        case .inContact:
            return "IN CONTACT - NEED ASSISTANCE"
        case .alert:
            return "ALERT - ATTENTION NEEDED"
        case .cancel:
            return "EMERGENCY CANCELLED"
        }
    }
}

// MARK: - Emergency State

struct EmergencyState: Codable {
    var isActive: Bool
    var type: String
    var message: String
    var activatedAt: Date?
    var lastBroadcast: Date?
    var broadcastCount: Int

    static var inactive: EmergencyState {
        EmergencyState(
            isActive: false,
            type: "",
            message: "",
            activatedAt: nil,
            lastBroadcast: nil,
            broadcastCount: 0
        )
    }
}

// MARK: - Emergency Beacon Service

class EmergencyBeaconService: ObservableObject {
    static let shared = EmergencyBeaconService()

    // Published state
    @Published var emergencyState: EmergencyState = .inactive
    @Published var isBroadcasting: Bool = false
    @Published var lastBroadcastStatus: String = ""

    // Configuration
    private let broadcastInterval: TimeInterval = 30 // Broadcast every 30 seconds
    private let staleTime: TimeInterval = 120 // Message stale after 2 minutes
    private let userDefaultsKey = "com.omnitak.emergencyState"

    // Services
    private var takService: TAKService?

    /// Nothing in the app ever called `configure(takService:locationManager:)`,
    /// so every emergency broadcast failed with "TAKService not configured"
    /// (both the Emergency tool and a speaker-mic emergency button). Fall back
    /// to the app-wide TAK service and the app's own location.
    private var effectiveTAKService: TAKService { takService ?? TAKService.shared }

    private var currentCoordinate: (lat: Double, lon: Double, alt: Double) {
        if let c = locationManager?.location {
            return (c.latitude, c.longitude, locationManager?.altitude ?? 0)
        }
        if let l = LocationManager.shared.location {
            return (l.coordinate.latitude, l.coordinate.longitude, l.altitude)
        }
        return (0, 0, 0)
    }
    private var locationManager: BeaconLocationManager?
    private var broadcastTimer: Timer?

    // User info
    // Single operator source (PositionBroadcastService), read at
    // CoT-build time. No cached copy, no divergent default.
    private var userCallsign: String { PositionBroadcastService.shared.userCallsign }
    private var userUID: String = ""

    private init() {
        loadState()
        generateUserUID()
    }

    // MARK: - Configuration

    func configure(takService: TAKService, locationManager: BeaconLocationManager) {
        self.takService = takService
        self.locationManager = locationManager

        // Resume broadcasting if emergency was active
        if emergencyState.isActive {
            startBroadcasting()
        }
    }

    private func generateUserUID() {
        userUID = "EMERGENCY-\(UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)"
    }

    // MARK: - Emergency Activation

    /// - Parameter playSound: false for a hardware trigger (e.g. a speaker-mic
    ///   emergency key): the system alert sound plays at full volume through
    ///   the active audio route — straight into the operator's speaker-mic —
    ///   and a man-down / covert trigger shouldn't sound at all. The phone
    ///   still vibrates.
    func activateEmergency(type: EmergencyType, message: String? = nil, playSound: Bool = true) {
        let finalMessage = message ?? type.defaultMessage

        emergencyState = EmergencyState(
            isActive: true,
            type: type.rawValue,
            message: finalMessage,
            activatedAt: Date(),
            lastBroadcast: nil,
            broadcastCount: 0
        )

        saveState()
        startBroadcasting()

        // Provide haptic feedback
        provideHapticFeedback(.heavy)
        if playSound { playAlertSound() }
        else { AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate)) }

        // Send initial broadcast immediately
        sendEmergencyBroadcast()

        print("EMERGENCY ACTIVATED: \(type.displayName) - \(finalMessage)")
    }

    func cancelEmergency() {
        guard emergencyState.isActive else { return }

        // Send cancellation message
        sendCancellationBroadcast()

        stopBroadcasting()

        emergencyState = .inactive
        saveState()

        // Provide feedback
        provideHapticFeedback(.medium)

        print("EMERGENCY CANCELLED")
    }

    // MARK: - Broadcasting

    private func startBroadcasting() {
        guard broadcastTimer == nil else { return }

        isBroadcasting = true

        // Schedule periodic broadcasts
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: broadcastInterval, repeats: true) { [weak self] _ in
            self?.sendEmergencyBroadcast()
        }

        print("Started emergency broadcasting (interval: \(broadcastInterval)s)")
    }

    private func stopBroadcasting() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        isBroadcasting = false

        print("Stopped emergency broadcasting")
    }

    private func sendEmergencyBroadcast() {
        guard emergencyState.isActive else { return }
        let takService = effectiveTAKService

        // Get current location
        let pos = currentCoordinate
        let latitude = pos.lat
        let longitude = pos.lon
        let altitude = pos.alt

        // Generate CoT XML
        let xml = generateEmergencyCoT(
            type: EmergencyType(rawValue: emergencyState.type) ?? .alert,
            message: emergencyState.message,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude
        )

        // Send via TAKService
        if takService.sendCoT(xml: xml) {
            emergencyState.lastBroadcast = Date()
            emergencyState.broadcastCount += 1
            saveState()

            lastBroadcastStatus = "Broadcast #\(emergencyState.broadcastCount) sent at \(formattedTime(Date()))"
            print("Emergency broadcast #\(emergencyState.broadcastCount) sent")

            // Provide subtle haptic feedback for each broadcast
            provideHapticFeedback(.light)
        } else {
            lastBroadcastStatus = "Failed to send broadcast"
            print("Failed to send emergency broadcast")
        }
    }

    private func sendCancellationBroadcast() {
        let takService = effectiveTAKService

        let pos = currentCoordinate
        let latitude = pos.lat
        let longitude = pos.lon
        let altitude = pos.alt

        let xml = generateEmergencyCoT(
            type: .cancel,
            message: "EMERGENCY CANCELLED",
            latitude: latitude,
            longitude: longitude,
            altitude: altitude
        )

        _ = takService.sendCoT(xml: xml)
        print("Cancellation broadcast sent")
    }

    // MARK: - CoT XML Generation

    private func generateEmergencyCoT(
        type: EmergencyType,
        message: String,
        latitude: Double,
        longitude: Double,
        altitude: Double
    ) -> String {
        let now = Date()
        let uid = "\(userUID)-\(Int(now.timeIntervalSince1970))"

        // Emergency CoT detail following ATAK standards
        let detail = """
                <contact callsign="\(userCallsign.xmlEscaped)"/>
                <emergency type="\(type.rawValue.xmlEscaped)">\(message.xmlEscaped)</emergency>
                <remarks>\(message.xmlEscaped)</remarks>
                <status readiness="true"/>
                <takv device="\(UIDevice.current.model)" platform="OmniTAK-iOS" os="\(UIDevice.current.systemVersion)" version="\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0")"/>
                <__group name="Emergency" role="Team Member"/>
        """

        return CoTXMLBuilder.buildEvent(
            uid: uid,
            type: type.cotType,
            how: "h-g-i-g-o",
            time: now,
            staleAfter: staleTime,
            lat: latitude,
            lon: longitude,
            hae: altitude,
            ce: 9999,
            le: 9999,
            detail: detail
        )
    }

    // MARK: - Persistence

    private func saveState() {
        if let encoded = try? JSONEncoder().encode(emergencyState) {
            UserDefaults.standard.set(encoded, forKey: userDefaultsKey)
        }
    }

    private func loadState() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let state = try? JSONDecoder().decode(EmergencyState.self, from: data) {
            emergencyState = state
            print("Loaded emergency state: active=\(state.isActive)")
        }
    }

    // MARK: - Feedback

    private func provideHapticFeedback(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    private func playAlertSound() {
        // Play system alert sound
        AudioServicesPlaySystemSound(SystemSoundID(1005)) // SMS tone

        // Vibrate for emphasis
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
    }

    // MARK: - Helpers

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    var timeSinceActivation: String {
        guard let activatedAt = emergencyState.activatedAt else { return "N/A" }
        let elapsed = Date().timeIntervalSince(activatedAt)
        let minutes = Int(elapsed / 60)
        let seconds = Int(elapsed.truncatingRemainder(dividingBy: 60))
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var currentEmergencyType: EmergencyType? {
        guard emergencyState.isActive else { return nil }
        return EmergencyType(rawValue: emergencyState.type)
    }
}

// MARK: - Location Manager Protocol (if not already defined)

protocol LocationManagerProtocol {
    var location: CLLocationCoordinate2D? { get }
}

// Simple location wrapper for compatibility
class BeaconLocationManager: ObservableObject {
    @Published var location: CLLocationCoordinate2D?
    @Published var altitude: Double = 0.0

    private let clLocationManager = CLLocationManager()

    init() {
        clLocationManager.desiredAccuracy = kCLLocationAccuracyBest
        clLocationManager.requestWhenInUseAuthorization()
        clLocationManager.startUpdatingLocation()

        // Update location periodically
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            if let clLocation = self?.clLocationManager.location {
                self?.location = clLocation.coordinate
                self?.altitude = clLocation.altitude
            }
        }
    }
}
