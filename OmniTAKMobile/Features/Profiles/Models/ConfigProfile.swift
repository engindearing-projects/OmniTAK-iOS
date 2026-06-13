//
//  ConfigProfile.swift
//  OmniTAKMobile
//
//  A shareable configuration profile that captures team/org settings.
//  Explicitly excludes secrets: no private keys, cert passphrases, passwords.
//  Teammates scan the QR, enroll their own cert, and set their own callsign.
//

import Foundation

// MARK: - Safe Server Snapshot

/// A server configuration stripped of all credential secrets.
/// Retains enough for a teammate to know which server to connect to and
/// initiate enrollment.  Does NOT include certificatePassword, caCertificatePassword,
/// the user's password, or the enrollment username — those are per-device secrets /
/// PII (the callsign / username is unique to each operator; teammates set their own).
struct ProfileServer: Codable, Equatable {
    var name: String
    var host: String
    var port: UInt16
    var protocolType: String   // tcp | ssl
    var useTLS: Bool
    var enabled: Bool
    /// Optional enrollment pointer (server host may differ from streaming host)
    var enrollmentPort: UInt16?
    /// Username — stored locally for UX, intentionally excluded from QR/Codable
    /// so teammate callsigns / PII are never embedded in a shared QR code.
    var enrollmentUsername: String?

    init(from server: TAKServer) {
        self.name = server.name
        self.host = server.host
        self.port = server.port
        self.protocolType = server.protocolType
        self.useTLS = server.useTLS
        self.enabled = server.enabled
        self.enrollmentPort = server.enrollmentPort
        self.enrollmentUsername = server.username
        // certificatePassword, caCertificatePassword, password, enrollmentUsername
        // intentionally omitted from the serialised (Codable) form below.
    }

    // MARK: - Codable (excludes enrollmentUsername)

    enum CodingKeys: String, CodingKey {
        case name, host, port, protocolType, useTLS, enabled, enrollmentPort
        // enrollmentUsername is intentionally absent — PII, not shared in QR
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name         = try c.decode(String.self,  forKey: .name)
        host         = try c.decode(String.self,  forKey: .host)
        port         = try c.decode(UInt16.self,  forKey: .port)
        protocolType = try c.decode(String.self,  forKey: .protocolType)
        useTLS       = try c.decode(Bool.self,    forKey: .useTLS)
        enabled      = try c.decode(Bool.self,    forKey: .enabled)
        enrollmentPort     = try c.decodeIfPresent(UInt16.self, forKey: .enrollmentPort)
        enrollmentUsername = nil  // never decoded from QR; operator enters at enrollment
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name,         forKey: .name)
        try c.encode(host,         forKey: .host)
        try c.encode(port,         forKey: .port)
        try c.encode(protocolType, forKey: .protocolType)
        try c.encode(useTLS,       forKey: .useTLS)
        try c.encode(enabled,      forKey: .enabled)
        try c.encodeIfPresent(enrollmentPort, forKey: .enrollmentPort)
        // enrollmentUsername intentionally not encoded
    }

    /// Reconstruct a TAKServer from this snapshot.
    /// The returned server has no certificates or passwords; the user must enroll.
    func toTAKServer() -> TAKServer {
        TAKServer(
            name: name,
            host: host,
            port: port,
            protocolType: protocolType,
            useTLS: useTLS,
            isDefault: false,
            enabled: enabled,
            certificateName: nil,
            certificatePassword: nil,
            caCertificateName: nil,
            caCertificatePassword: nil,
            allowLegacyTLS: false,
            // Intentional security policy (matches Android profile import behaviour):
            // never propagate trust-disable via a shared profile — the operator's
            // self-signed-server setting is per-device and set at enrollment time.
            // Keeping this false-on-import is the safe default; it prevents a
            // crafted QR from silently disabling TLS validation for a teammate.
            allowUntrustedTLS: false,
            username: enrollmentUsername,
            password: nil,
            enrollmentPort: enrollmentPort
        )
    }
}

// MARK: - Config Profile

/// A named, shareable configuration snapshot.
/// QR payload: omnitak://profile?d=<base64url(gzip(json))>
struct ConfigProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date

    // Identity template — NOT a fixed callsign; teammate fills in their own
    var teamName: String?       // e.g. "Alpha Team"
    var teamRole: String?       // e.g. "Team Member" / "Team Lead"
    var teamColor: String?      // TAK team colour name e.g. "Blue"

    // Server configuration (secrets stripped)
    var servers: [ProfileServer]

    // Map settings
    var mapEngine: String?          // "cesium_3d" | "mapbox_2d"
    var coordinateFormat: String?   // "MGRS" | "DD" | "DM" | "DMS" | "UTM" | "BNG" | "TWD97"
    var unitSystem: String?         // "Metric" | "Imperial"

    // Feature toggles
    var mgrsGridEnabled: Bool?
    var mgrsGridDensity: String?
    var showMGRSLabels: Bool?
    var breadcrumbTrailsEnabled: Bool?
    var selfMarkerStyle: String?    // "milstd" | "bullseye"

    // Drone detection
    var remoteIdScanEnabled: Bool?
    var gybDetectorEnabled: Bool?

    // Mesh framework selection
    var selectedMeshFramework: String?  // "meshtastic" | "meshcore" | "none"

    // Version marker for forward compatibility
    var schemaVersion: Int = 1

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        teamName: String? = nil,
        teamRole: String? = nil,
        teamColor: String? = nil,
        servers: [ProfileServer] = [],
        mapEngine: String? = nil,
        coordinateFormat: String? = nil,
        unitSystem: String? = nil,
        mgrsGridEnabled: Bool? = nil,
        mgrsGridDensity: String? = nil,
        showMGRSLabels: Bool? = nil,
        breadcrumbTrailsEnabled: Bool? = nil,
        selfMarkerStyle: String? = nil,
        remoteIdScanEnabled: Bool? = nil,
        gybDetectorEnabled: Bool? = nil,
        selectedMeshFramework: String? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.teamName = teamName
        self.teamRole = teamRole
        self.teamColor = teamColor
        self.servers = servers
        self.mapEngine = mapEngine
        self.coordinateFormat = coordinateFormat
        self.unitSystem = unitSystem
        self.mgrsGridEnabled = mgrsGridEnabled
        self.mgrsGridDensity = mgrsGridDensity
        self.showMGRSLabels = showMGRSLabels
        self.breadcrumbTrailsEnabled = breadcrumbTrailsEnabled
        self.selfMarkerStyle = selfMarkerStyle
        self.remoteIdScanEnabled = remoteIdScanEnabled
        self.gybDetectorEnabled = gybDetectorEnabled
        self.selectedMeshFramework = selectedMeshFramework
    }
}

// MARK: - Display helpers

extension ConfigProfile {
    /// One-line summary for the profile list
    var subtitle: String {
        var parts: [String] = []
        if let teamName = teamName { parts.append(teamName) }
        if !servers.isEmpty {
            parts.append(servers.count == 1 ? "1 server" : "\(servers.count) servers")
        }
        return parts.isEmpty ? "No servers configured" : parts.joined(separator: " · ")
    }

    var firstServerSummary: String? {
        guard let s = servers.first else { return nil }
        return "\(s.host):\(s.port)"
    }
}
