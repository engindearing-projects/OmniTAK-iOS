//
//  MeshDeviceConfigStore.swift
//  OmniTAK Mobile
//
//  GAP-109 — operator's draft device config (long/short name, role, PLI
//  cadence, primary channel name + LoRa preset). Persisted in
//  UserDefaults; mutated by the Device Settings screen; read back from
//  the radio via AdminMessageParser.
//

import Foundation
import Combine

/// Persisted operator-intent config. Mirrors Android `MeshDeviceConfig`.
public struct MeshDeviceConfig: Equatable {
    public var longName: String
    public var shortName: String
    public var role: MeshRole
    /// Position broadcast interval in seconds. 0 disables PLI broadcasts.
    public var positionBroadcastSecs: Int
    public var channelName: String
    public var channelPreset: MeshChannelPreset

    public static let `default` = MeshDeviceConfig(
        longName: "OmniTAK",
        shortName: "OTK",
        role: .tak,
        positionBroadcastSecs: 30,
        channelName: "OmniTAK",
        channelPreset: .longFast
    )
}

/// UserDefaults-backed observable store. Same shape as Android's
/// DataStore-backed `MeshDeviceConfigStore`.
@MainActor
public final class MeshDeviceConfigStore: ObservableObject {
    public static let shared = MeshDeviceConfigStore()

    @Published public private(set) var config: MeshDeviceConfig

    private let defaults: UserDefaults

    private enum Key {
        static let longName = "mesh.device.longName"
        static let shortName = "mesh.device.shortName"
        static let role = "mesh.device.role"
        static let pli = "mesh.device.pliSecs"
        static let channelName = "mesh.device.ch0.name"
        static let channelPreset = "mesh.device.ch0.preset"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.config = Self.load(from: defaults)
    }

    private static func load(from defaults: UserDefaults) -> MeshDeviceConfig {
        let d = MeshDeviceConfig.default
        return MeshDeviceConfig(
            longName: defaults.string(forKey: Key.longName) ?? d.longName,
            shortName: defaults.string(forKey: Key.shortName) ?? d.shortName,
            role: (defaults.string(forKey: Key.role).flatMap(MeshRole.init(rawValue:))) ?? d.role,
            positionBroadcastSecs: defaults.object(forKey: Key.pli) as? Int ?? d.positionBroadcastSecs,
            channelName: defaults.string(forKey: Key.channelName) ?? d.channelName,
            channelPreset: (defaults.string(forKey: Key.channelPreset).flatMap(MeshChannelPreset.init(rawValue:))) ?? d.channelPreset
        )
    }

    public func update(_ block: (inout MeshDeviceConfig) -> Void) {
        var next = config
        block(&next)
        next.positionBroadcastSecs = max(0, min(next.positionBroadcastSecs, 24 * 60 * 60))
        config = next
        persist(next)
    }

    private func persist(_ c: MeshDeviceConfig) {
        defaults.set(c.longName, forKey: Key.longName)
        defaults.set(c.shortName, forKey: Key.shortName)
        defaults.set(c.role.rawValue, forKey: Key.role)
        defaults.set(c.positionBroadcastSecs, forKey: Key.pli)
        defaults.set(c.channelName, forKey: Key.channelName)
        defaults.set(c.channelPreset.rawValue, forKey: Key.channelPreset)
    }

    /// GAP-109 read-back — fold an incoming admin response into the
    /// persisted draft so the Device Settings screen reflects the
    /// radio's actual state after a `requestDeviceConfig()`.
    public func applyAdminResponse(_ response: AdminResponse) {
        update { current in
            switch response {
            case .owner(let longName, let shortName):
                if !longName.isEmpty { current.longName = longName }
                if !shortName.isEmpty { current.shortName = shortName }
            case .deviceConfig(let role):
                if let role = role { current.role = role }
            case .positionConfig(let secs):
                current.positionBroadcastSecs = secs
            case .loraConfig(let preset):
                if let preset = preset { current.channelPreset = preset }
            case .channel(let index, let name, let role):
                // Only mirror the primary channel (index 0 / role=PRIMARY) — the
                // settings screen edits CH0 and treating CH3+ as the "primary"
                // would clobber the operator's draft.
                if (role == 1 || index == 0), !name.isEmpty {
                    current.channelName = name
                }
            }
        }
    }
}
