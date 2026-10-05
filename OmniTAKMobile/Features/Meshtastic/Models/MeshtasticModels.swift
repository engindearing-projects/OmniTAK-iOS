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

    /// When the radio last heard this node, or nil when that is not known
    /// (`NodeInfo.last_heard` missing or 0, which is what the firmware sends
    /// for a node it has no time for). Nil is a real state: it is never filled
    /// in with "now", and the UI shows a dash for it. Saved data written before
    /// this was optional still decodes, because the synthesized Codable reads
    /// an optional with `decodeIfPresent`.
    public var lastHeard: Date?
    public var snr: Double?
    public var hopDistance: Int?

    /// `DeviceMetrics.battery_level`: 0 to 100, or above 100 (101 in practice)
    /// when the node runs on external power. Use `batteryLabel` for display.
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
        lastHeard: Date?,
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

// MARK: - MeshNode display and merge helpers

extension MeshNode {

    /// Highest real battery percentage. `DeviceMetrics.battery_level` is above
    /// this when the node runs on external power.
    public static let maxBatteryPercent = 100

    /// Shown in place of an age when last heard is unknown.
    public static let unknownLastHeardLabel = "\u{2013}"

    /// True when the node reports external power instead of a battery level.
    public var isPowered: Bool {
        guard let level = batteryLevel else { return false }
        return level > MeshNode.maxBatteryPercent
    }

    /// Battery text for the UI: "73%", "powered" for the above-100 external
    /// power value, or nil when the level is unknown.
    public var batteryLabel: String? {
        guard let level = batteryLevel else { return nil }
        return level > MeshNode.maxBatteryPercent ? "powered" : "\(level)%"
    }

    /// The battery level for a consumer that expects 0 to 100, such as a CoT
    /// contact. A powered node reads 100 there instead of 101.
    public var batteryPercentCapped: Int? {
        batteryLevel.map { min($0, MeshNode.maxBatteryPercent) }
    }

    /// What to show for last heard: a dash when it is unknown, otherwise the
    /// age as "12s ago", "5m ago", "3h ago" or "2d ago". A date ahead of `now`
    /// (the radio's clock running fast) reads "0s ago".
    public func lastHeardLabel(now: Date = Date()) -> String {
        MeshNode.lastHeardLabel(for: lastHeard, now: now)
    }

    public static func lastHeardLabel(for date: Date?, now: Date = Date()) -> String {
        // A zero timestamp turns into the 1970 epoch once it is a Date. That is
        // "unknown", not 20,000 days ago.
        guard let date, date.timeIntervalSince1970 > 0 else { return unknownLastHeardLabel }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    /// Record that a packet from this node was just heard. Last heard only
    /// moves forward: a queued packet with an older receive time than what the
    /// node database already holds does not pull it back.
    public mutating func noteHeard(at date: Date) {
        if let known = lastHeard, known >= date { return }
        lastHeard = date
    }

    /// A later NodeInfo frame often leaves out fields an earlier one carried.
    /// Role and last heard must not be erased by a frame that simply does not
    /// have them, so a missing value keeps what is already known.
    public func carryingForward(from existing: MeshNode?) -> MeshNode {
        guard let existing else { return self }
        var merged = self
        if merged.role == nil { merged.role = existing.role }
        if merged.lastHeard == nil { merged.lastHeard = existing.lastHeard }
        return merged
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

