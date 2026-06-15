//
//  PositionBroadcastService.swift
//  OmniTAKMobile
//
//  Automatic Position Location Information (PLI) broadcasting service
//  Core TAK feature for situational awareness
//

import Foundation
import CoreLocation
import Combine
import UIKit

// MARK: - Position Broadcast Service

class PositionBroadcastService: ObservableObject {
    static let shared = PositionBroadcastService()

    // MARK: - Published Properties

    @Published var isEnabled: Bool = false {
        didSet {
            if isEnabled {
                startBroadcasting()
            } else {
                stopBroadcasting()
            }
            saveBroadcastSettings()
        }
    }

    @Published var updateInterval: TimeInterval = 30.0 {
        didSet {
            if isEnabled {
                restartTimer()
            }
            saveBroadcastSettings()
        }
    }

    // MARK: - OTS Interop: Auto-PPLI
    //
    // TAK protocol requires every connected EUD to send a periodic self-position
    // (PPLI) CoT so the server knows the client is alive and can display it to
    // other users.  ATAK/iTAK default to 1–2 s.  Some servers enforce a short
    // idle timeout and will drop the connection if no CoT arrives within that
    // window.  Auto-PPLI fires independently of the user-visible PLI broadcast
    // interval so the connection stays warm even when the user sets a slow PLI
    // rate (e.g. 30 s to conserve bandwidth on low-data links).
    //
    // The timer starts when the TAK connection is established and stops when it
    // is torn down.  If the device has no GPS fix at tick time, the tick is
    // silently skipped — the next tick will retry.

    @Published var autoPPLIEnabled: Bool = true {
        didSet { saveBroadcastSettings() }
    }

    @Published var autoPPLIInterval: TimeInterval = 1.0 {
        didSet {
            if ppliTimer != nil {
                startAutoPPLI()   // restart with new interval
            }
            saveBroadcastSettings()
        }
    }

    @Published var staleTime: TimeInterval = 180.0 {
        didSet {
            saveBroadcastSettings()
        }
    }

    // MARK: - Mesh Off-Grid PPLI
    //
    // When a Meshtastic radio is connected, OmniTAK also broadcasts self-position
    // over the mesh (portnum 72 / ATAK_PLUGIN) so peers with NO server can see
    // each other on the map.  This is throttled independently of the auto-PPLI
    // keepalive (which is server-only) to avoid flooding low-bandwidth LoRa links.

    @Published var meshBroadcastEnabled: Bool = true {
        didSet { saveBroadcastSettings() }
    }

    @Published var meshPPLIInterval: TimeInterval = 30.0 {
        didSet { saveBroadcastSettings() }
    }

    // Not @Published — mutated on ppliQueue; expose internal for @testable access.
    internal var lastMeshPPLISend: Date?

    /// Pure throttle decision for the mesh PPLI cadence (Issue #46).
    ///
    /// The mesh PPLI rides on the high-frequency server keepalive tick, so most
    /// ticks must be dropped to keep low-bandwidth LoRa from saturating. A send
    /// is allowed when there's no prior send, or when at least `interval` seconds
    /// have elapsed since the last one. Factored out so the gate is unit-testable
    /// without a radio or a running timer.
    static func shouldSendMeshPPLI(lastSend: Date?, now: Date, interval: TimeInterval) -> Bool {
        guard let lastSend = lastSend else { return true }
        return now.timeIntervalSince(lastSend) >= interval
    }

    // MARK: - Issue #65: Manual Position Override
    //
    // When the operator taps their self-pip and sets a manual coordinate,
    // `manualPosition` becomes non-nil and CoT generation uses it instead of
    // the GPS location. Cleared by toggling `isManualPositionActive = false`
    // or by tapping "Return to GPS" in the SelfPositionEditSheet.

    @Published var manualPosition: CLLocationCoordinate2D? = nil
    @Published var isManualPositionActive: Bool = false {
        didSet {
            if !isManualPositionActive {
                manualPosition = nil
            }
        }
    }

    @Published var lastBroadcastTime: Date?
    @Published var broadcastCount: Int = 0
    @Published var lastError: String?
    @Published var batteryLevel: Float = 1.0
    @Published var deviceStatus: String = "Operational"

    // User identity
    @Published var userCallsign: String = "ALPHA-1" {
        didSet {
            saveBroadcastSettings()
        }
    }

    @Published var userUID: String
    @Published var teamColor: String = "Cyan" {
        didSet {
            saveBroadcastSettings()
        }
    }

    @Published var teamRole: String = "Team Member" {
        didSet {
            saveBroadcastSettings()
        }
    }

    // MARK: - Private Properties

    private var broadcastTimer: Timer?
    private var ppliTimer: DispatchSourceTimer?
    private let ppliQueue = DispatchQueue(label: "com.omnitak.ppli", qos: .utility)
    private var takService: TAKService?
    private var locationManager: LocationManager?
    private var cancellables = Set<AnyCancellable>()
    private var isLoadingSettings = false

    // MARK: - Initialization

    private init() {
        // Generate or load UID
        if let savedUID = UserDefaults.standard.string(forKey: "selfPositionUID") {
            // Migrate old ANDROID- prefix to IOS- for proper ATAK icon display
            if savedUID.hasPrefix("ANDROID-") {
                let newUID = "IOS-\(UUID().uuidString)"
                self.userUID = newUID
                UserDefaults.standard.set(newUID, forKey: "selfPositionUID")
                print("📱 Migrated UID from ANDROID- to IOS- prefix: \(newUID)")
            } else {
                self.userUID = savedUID
            }
        } else {
            // Use iOS-specific UID prefix for proper ATAK icon display
            let newUID = "IOS-\(UUID().uuidString)"
            self.userUID = newUID
            UserDefaults.standard.set(newUID, forKey: "selfPositionUID")
        }

        loadBroadcastSettings()
        startBatteryMonitoring()

        print("PositionBroadcastService initialized with UID: \(userUID)")
    }

    // MARK: - Configuration

    func configure(takService: TAKService, locationManager: LocationManager) {
        self.takService = takService
        self.locationManager = locationManager

        print("📡 PositionBroadcastService.configure() called - isEnabled: \(isEnabled), hasTimer: \(broadcastTimer != nil)")

        // Auto-start user-visible PLI broadcast if enabled
        if isEnabled && broadcastTimer == nil {
            startBroadcasting()
        } else if !isEnabled {
            print("⚠️ Position broadcasting is disabled - enable in Settings")
        }

        // Always start the auto-PPLI keepalive when a connection is configured
        startAutoPPLI()
    }

    // MARK: - Broadcasting Control

    func startBroadcasting() {
        guard takService != nil, locationManager != nil else {
            print("Cannot start broadcasting: services not configured")
            lastError = "Services not configured"
            return
        }

        stopBroadcasting()

        // Initial broadcast
        broadcastPosition()

        // Start timer
        broadcastTimer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.broadcastPosition()
        }

        print("Position broadcasting started with interval: \(updateInterval)s")
    }

    func stopBroadcasting() {
        broadcastTimer?.invalidate()
        broadcastTimer = nil
        print("Position broadcasting stopped")
    }

    private func restartTimer() {
        if isEnabled {
            startBroadcasting()
        }
    }

    // MARK: - OTS Interop: Auto-PPLI Control

    /// Start the high-frequency PPLI keepalive timer.
    /// Called by TAKService immediately after a connection is established.
    /// Safe to call multiple times — cancels any existing timer first.
    func startAutoPPLI() {
        guard autoPPLIEnabled else { return }
        guard takService != nil else { return }

        stopAutoPPLI()

        let source = DispatchSource.makeTimerSource(queue: ppliQueue)
        let interval = autoPPLIInterval
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            self?.sendAutoPPLITick()
        }
        source.resume()
        ppliTimer = source

        print("📡 Auto-PPLI started — interval: \(interval)s")
    }

    /// Stop the PPLI keepalive timer.
    /// Called by TAKService when the connection is torn down.
    func stopAutoPPLI() {
        ppliTimer?.cancel()
        ppliTimer = nil
        print("📡 Auto-PPLI stopped")
    }

    private func sendAutoPPLITick() {
        guard let takService = takService else { return }

        // Issue #65 — manual position override takes priority over GPS.
        let effectiveLocation: CLLocation
        if isManualPositionActive, let manualCoord = manualPosition {
            effectiveLocation = CLLocation(latitude: manualCoord.latitude, longitude: manualCoord.longitude)
        } else {
            guard let location = locationManager?.location else {
                // No GPS fix yet — skip this tick rather than sending stale zeros.
                return
            }
            effectiveLocation = location
        }

        let cotXML = generateSelfSACoT(location: effectiveLocation)
        let _ = takService.sendCoT(xml: cotXML)

        // --- Mesh off-grid PPLI ---
        // Reuse the already-computed CoT XML and send to mesh if connected.
        // Throttled to meshPPLIInterval to avoid saturating low-bandwidth LoRa.
        // MeshtasticManager is @MainActor, so we must hop to the main actor
        // before touching it (prevents the off-main @Published-publish crash class).
        if meshBroadcastEnabled {
            let now = Date()
            guard Self.shouldSendMeshPPLI(
                lastSend: lastMeshPPLISend,
                now: now,
                interval: meshPPLIInterval
            ) else {
                return
            }
            lastMeshPPLISend = now
            let xmlToSend = cotXML
            Task { @MainActor in
                guard let event = CoTMessageParser.parsePositionUpdate(xml: xmlToSend) else {
                    print("⚠️ Mesh PPLI: failed to parse self-SA CoT XML for mesh send")
                    return
                }
                let frameworkKey = UserDefaults.standard.string(forKey: MeshFramework.storageKey) ?? ""
                if #available(iOS 13.0, *),
                   frameworkKey == MeshFramework.meshcore.rawValue,
                   MeshCoreManager.shared.isConnected {
                    MeshCoreManager.shared.sendCoTOverMesh(event)
                } else if MeshtasticManager.shared.isConnected {
                    MeshtasticManager.shared.sendCoTOverMesh(event)
                } else {
                    return
                }
                #if DEBUG
                print("📡 Mesh PPLI: sent self-position over mesh")
                #endif
            }
        }
    }

    // MARK: - Position Broadcast

    func broadcastPosition() {
        guard let takService = takService else {
            print("❌ broadcastPosition: TAKService is nil")
            lastError = "TAKService not configured"
            return
        }

        // Issue #65 — manual position override takes priority over GPS.
        let effectiveLocation: CLLocation
        if isManualPositionActive, let manualCoord = manualPosition {
            effectiveLocation = CLLocation(latitude: manualCoord.latitude, longitude: manualCoord.longitude)
        } else {
            guard let location = locationManager?.location else {
                print("❌ broadcastPosition: No location available (locationManager: \(locationManager != nil ? "exists" : "nil"))")
                lastError = "No location available"
                return
            }
            effectiveLocation = location
        }

        let cotXML = generateSelfSACoT(location: effectiveLocation)

        #if DEBUG
        print("📡 Sending PLI CoT for UID: \(userUID), callsign: \(userCallsign)")
        print("📡 CoT XML:\n\(cotXML)")
        #endif

        let success = takService.sendCoT(xml: cotXML)

        if success {
            lastBroadcastTime = Date()
            broadcastCount += 1
            lastError = nil
            print("Position broadcast #\(broadcastCount) at \(effectiveLocation.coordinate)")
        } else {
            lastError = "Failed to send position"
            print("Failed to broadcast position")
        }
    }

    // MARK: - CoT Message Generation

    private func generateSelfSACoT(location: CLLocation) -> String {
        // Speed in m/s, course in degrees
        let speed = location.speed >= 0 ? location.speed : 0
        let course = location.course >= 0 ? location.course : 0

        // Team color in ARGB format (signed 32-bit integer)
        // Cyan: 0xFF00FFFF = -16711681
        let colorARGB = getARGBForTeamColor(teamColor)

        let detail = """
                <contact callsign="\(userCallsign.xmlEscaped)" endpoint="*:-1:stcp"/>
                <__group name="\(teamColor.xmlEscaped)" role="\(teamRole.xmlEscaped)"/>
                <status battery="\(Int(batteryLevel * 100))"/>
                <takv device="\(deviceModel.xmlEscaped)" platform="OmniTAK-iOS" os="iOS \(iosVersion)" version="\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0")"/>
                <track speed="\(String(format: "%.2f", speed))" course="\(String(format: "%.2f", course))"/>
                <precisionlocation altsrc="GPS" geopointsrc="GPS"/>
                <uid Droid="\(userCallsign.xmlEscaped)"/>
                <usericon iconsetpath="COT_MAPPING_2525B/a-f/a-f-G-U-C"/>
                <color argb="\(colorARGB)"/>
        """

        // CoT type: a-f-G-U-C (friendly ground unit combat)
        return CoTXMLBuilder.buildEvent(
            uid: userUID,
            type: "a-f-G-U-C",
            how: "m-g",
            staleAfter: staleTime,
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            hae: location.altitude,
            ce: location.horizontalAccuracy,
            le: location.verticalAccuracy,
            detail: detail
        )
    }

    // MARK: - Battery Monitoring

    private func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBatteryLevel()

        NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)
            .sink { [weak self] _ in
                self?.updateBatteryLevel()
            }
            .store(in: &cancellables)
    }

    private func updateBatteryLevel() {
        let level = UIDevice.current.batteryLevel
        if level >= 0 {
            batteryLevel = level
        }

        // Update device status based on battery
        if batteryLevel < 0.1 {
            deviceStatus = "Low Battery"
        } else if batteryLevel < 0.2 {
            deviceStatus = "Battery Warning"
        } else {
            deviceStatus = "Operational"
        }
    }

    // MARK: - Device Info

    private var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    private var iosVersion: String {
        UIDevice.current.systemVersion
    }

    // MARK: - Persistence

    private func saveBroadcastSettings() {
        guard !isLoadingSettings else { return }
        UserDefaults.standard.set(isEnabled, forKey: "positionBroadcastEnabled")
        UserDefaults.standard.set(updateInterval, forKey: "positionUpdateInterval")
        UserDefaults.standard.set(staleTime, forKey: "positionStaleTime")
        UserDefaults.standard.set(userCallsign, forKey: "userCallsign")
        UserDefaults.standard.set(teamColor, forKey: "teamColor")
        UserDefaults.standard.set(teamRole, forKey: "teamRole")
        UserDefaults.standard.set(autoPPLIEnabled, forKey: "autoPPLIEnabled")
        UserDefaults.standard.set(autoPPLIInterval, forKey: "autoPPLIInterval")
        UserDefaults.standard.set(meshBroadcastEnabled, forKey: "meshBroadcastEnabled")
        UserDefaults.standard.set(meshPPLIInterval, forKey: "meshPPLIInterval")
    }

    private func loadBroadcastSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }

        if UserDefaults.standard.object(forKey: "positionBroadcastEnabled") != nil {
            isEnabled = UserDefaults.standard.bool(forKey: "positionBroadcastEnabled")
        }

        let savedInterval = UserDefaults.standard.double(forKey: "positionUpdateInterval")
        if savedInterval > 0 {
            updateInterval = savedInterval
        }

        let savedStale = UserDefaults.standard.double(forKey: "positionStaleTime")
        if savedStale > 0 {
            staleTime = savedStale
        }

        if let savedCallsign = UserDefaults.standard.string(forKey: "userCallsign") {
            userCallsign = savedCallsign
        }

        if let savedTeamColor = UserDefaults.standard.string(forKey: "teamColor") {
            teamColor = savedTeamColor
        }

        if let savedTeamRole = UserDefaults.standard.string(forKey: "teamRole") {
            teamRole = savedTeamRole
        }

        if UserDefaults.standard.object(forKey: "autoPPLIEnabled") != nil {
            autoPPLIEnabled = UserDefaults.standard.bool(forKey: "autoPPLIEnabled")
        }

        let savedPPLIInterval = UserDefaults.standard.double(forKey: "autoPPLIInterval")
        if savedPPLIInterval > 0 {
            autoPPLIInterval = savedPPLIInterval
        }

        if UserDefaults.standard.object(forKey: "meshBroadcastEnabled") != nil {
            meshBroadcastEnabled = UserDefaults.standard.bool(forKey: "meshBroadcastEnabled")
        }

        let savedMeshInterval = UserDefaults.standard.double(forKey: "meshPPLIInterval")
        if savedMeshInterval > 0 {
            meshPPLIInterval = savedMeshInterval
        }
    }

    // MARK: - Helpers

    /// Convert team color name to ARGB format (signed 32-bit integer)
    /// ARGB format: Alpha (FF for opaque) + Red + Green + Blue
    private func getARGBForTeamColor(_ colorName: String) -> Int {
        switch colorName.lowercased() {
        case "cyan":
            return -16711681  // 0xFF00FFFF
        case "blue":
            return -16776961  // 0xFF0000FF
        case "green":
            return -16711936  // 0xFF00FF00
        case "yellow":
            return -256       // 0xFFFFFF00
        case "orange":
            return -23296     // 0xFFFFA500
        case "red":
            return -65536     // 0xFFFF0000
        case "purple":
            return -8388480   // 0xFF800080
        case "magenta":
            return -65281     // 0xFFFF00FF
        case "white":
            return -1         // 0xFFFFFFFF
        case "dark blue":
            return -16777077  // 0xFF00008B
        case "maroon":
            return -8388608   // 0xFF800000
        case "teal":
            return -16744320  // 0xFF008080
        default:
            return -16711681  // Default to Cyan
        }
    }

    // MARK: - Manual Broadcast

    func forceBroadcast() {
        broadcastPosition()
    }

    // MARK: - Statistics

    var timeSinceLastBroadcast: String {
        guard let lastTime = lastBroadcastTime else {
            return "Never"
        }

        let interval = Date().timeIntervalSince(lastTime)
        if interval < 60 {
            return "\(Int(interval))s ago"
        } else if interval < 3600 {
            return "\(Int(interval / 60))m ago"
        } else {
            return "\(Int(interval / 3600))h ago"
        }
    }

    var nextBroadcastIn: String {
        guard let lastTime = lastBroadcastTime, isEnabled else {
            return "N/A"
        }

        let nextTime = lastTime.addingTimeInterval(updateInterval)
        let remaining = nextTime.timeIntervalSince(Date())

        if remaining <= 0 {
            return "Now"
        } else if remaining < 60 {
            return "\(Int(remaining))s"
        } else {
            return "\(Int(remaining / 60))m \(Int(remaining.truncatingRemainder(dividingBy: 60)))s"
        }
    }

    deinit {
        stopBroadcasting()
        stopAutoPPLI()
    }
}
