//
//  MeshtasticModels.swift
//  OmniTAK Mobile
//
//  Meshtastic mesh networking data models
//

import Foundation
import CoreLocation

// MARK: - Device Models

/// Connection type for Meshtastic devices
public enum MeshtasticConnectionType: String, Codable {
    case bluetooth = "Bluetooth"
    case tcp = "TCP/IP"

    public var displayName: String {
        return self.rawValue
    }

    public var iconName: String {
        switch self {
        case .bluetooth:
            return "antenna.radiowaves.left.and.right"
        case .tcp:
            return "wifi"
        }
    }
}

public struct MeshtasticDevice: Identifiable, Codable {
    public let id: String
    public var name: String
    public var connectionType: MeshtasticConnectionType
    public var devicePath: String
    public var isConnected: Bool
    public var signalStrength: Int?
    public var snr: Double?
    public var hopCount: Int?
    public var batteryLevel: Int?
    public var nodeId: String?
    public var lastSeen: Date?

    public init(
        id: String,
        name: String,
        connectionType: MeshtasticConnectionType,
        devicePath: String,
        isConnected: Bool,
        signalStrength: Int? = nil,
        snr: Double? = nil,
        hopCount: Int? = nil,
        batteryLevel: Int? = nil,
        nodeId: String? = nil,
        lastSeen: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.connectionType = connectionType
        self.devicePath = devicePath
        self.isConnected = isConnected
        self.signalStrength = signalStrength
        self.snr = snr
        self.hopCount = hopCount
        self.batteryLevel = batteryLevel
        self.nodeId = nodeId
        self.lastSeen = lastSeen
    }
}


// MARK: - Mesh Network Models

public struct MeshNode: Identifiable, Codable, Equatable {
    public let id: UInt32
    public var shortName: String
    public var longName: String
    public var position: MeshPosition?
    public var lastHeard: Date
    public var snr: Double?
    public var hopDistance: Int?
    public var batteryLevel: Int?

    /// Meshtastic `User.role` — the config.proto `Config.DeviceConfig.Role`
    /// enum value, or nil when the NodeInfo frame carried no role field
    /// (older firmware, or a node we have only heard a position packet from).
    public var role: Int?

    /// Role `TAK` — a radio paired to a phone that is itself running a TAK
    /// client. That phone already reports the operator's position, so drawing
    /// the radio too puts two mismatched dots on one person. Standalone
    /// trackers (TAK_TRACKER, sensors, vehicles) are a different case and stay
    /// visible.
    public var isTakPaired: Bool { role == MeshNode.roleTAK }

    /// config.proto `Config.DeviceConfig.Role` values we act on. Mirrors the
    /// Android `MeshNode` companion and `MeshtasticAdminCodec.DeviceRole`.
    public static let roleTAK = 7
    public static let roleTAKTracker = 10

    public init(
        id: UInt32,
        shortName: String,
        longName: String,
        position: MeshPosition? = nil,
        lastHeard: Date,
        snr: Double? = nil,
        hopDistance: Int? = nil,
        batteryLevel: Int? = nil,
        role: Int? = nil
    ) {
        self.id = id
        self.shortName = shortName
        self.longName = longName
        self.position = position
        self.lastHeard = lastHeard
        self.snr = snr
        self.hopDistance = hopDistance
        self.batteryLevel = batteryLevel
        self.role = role
    }
}

public struct MeshPosition: Codable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Int?

    public init(latitude: Double, longitude: Double, altitude: Int? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

