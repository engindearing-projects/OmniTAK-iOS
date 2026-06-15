//
//  MeshFramework.swift
//  OmniTAK Mobile
//
//  Framework-neutral mesh abstractions. OmniTAK supports two mesh radio
//  families that both bridge to CoT: Meshtastic (protobuf streaming) and
//  MeshCore (companion BLE protocol). The app picks the active framework via
//  @AppStorage("selectedMeshFramework"); the rest of the app talks to whichever
//  manager conforms to `MeshManager`.
//
//  These protocols are deliberately thin and match the public surface the
//  existing MeshtasticManager / Meshtastic clients already expose, so adopting
//  them does NOT change Meshtastic behavior — it just names the seam.
//

import Foundation
import Combine
import CoreBluetooth

// MARK: - Mesh Framework Selection

/// Which mesh radio family the operator has selected. Persisted via
/// `@AppStorage("selectedMeshFramework")` using `rawValue`.
public enum MeshFramework: String, CaseIterable, Identifiable, Codable {
    case meshtastic
    case meshcore

    public var id: String { rawValue }

    /// UserDefaults / @AppStorage key shared across the app.
    public static let storageKey = "selectedMeshFramework"

    public var displayName: String {
        switch self {
        case .meshtastic: return "Meshtastic"
        case .meshcore:   return "MeshCore"
        }
    }

    public var iconName: String {
        switch self {
        case .meshtastic: return "antenna.radiowaves.left.and.right"
        case .meshcore:   return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Mesh Transport

/// A byte-level link to a mesh radio (BLE or TCP). Conformed by the Meshtastic
/// BLE/TCP clients and by `MeshCoreBLETransport`.
///
/// The Meshtastic clients already publish these via `@Published` on
/// `ObservableObject`; the protocol simply records that contract. Transports
/// own framing/parsing internally and surface decoded nodes through `nodes`.
@available(iOS 13.0, *)
protocol MeshTransport: AnyObject {
    /// True once the link is up and ready for I/O.
    var isConnected: Bool { get }

    /// Decoded node table keyed by a framework-local node id.
    var nodes: [UInt32: MeshNode] { get }

    /// This radio's own node number (0 until known).
    var myNodeNum: UInt32 { get }

    /// Tear the link down.
    func disconnect()
}

// MARK: - Mesh Manager

/// The app-facing manager for a mesh framework — owns its transport(s), exposes
/// an observable node list and connection state, bridges inbound traffic to CoT,
/// and can push OmniTAK's self-position / GeoChat back onto the mesh.
///
/// `MeshtasticManager` already implements this surface; `MeshCoreManager`
/// mirrors it. Both are `@MainActor ObservableObject` singletons so SwiftUI
/// views can `@ObservedObject` them directly.
@MainActor
protocol MeshManager: ObservableObject {
    /// Which framework this manager drives.
    var framework: MeshFramework { get }

    /// True when a radio is connected.
    var isConnected: Bool { get }

    /// Human-readable connection state ("Disconnected", "Connecting…", …).
    var connectionState: String { get }

    /// This radio's own node number (0 until known).
    var myNodeNum: UInt32 { get }

    /// All known mesh nodes (with or without positions).
    var meshNodes: [MeshNode] { get }

    /// Disconnect from the current radio.
    func disconnect()

    /// Push every known node with a position onto the TAK map.
    func publishMeshNodesToMap()

    /// Bridge a CoT event out over the mesh (PLI / GeoChat). Returns true if the
    /// payload was dispatched to the radio.
    @discardableResult
    func sendCoTOverMesh(_ event: CoTEvent, channelIndex: UInt32) -> Bool
}

// MARK: - Mesh TAK Routing (Issue #46)

/// Pure decision layer for the off-grid mesh path.
///
/// `MeshtasticManager.sendCoTOverMesh` couples three things: deciding which wire
/// format a CoT event takes, building those bytes, and handing them to a live
/// BLE/TCP transport. Only the first two are testable without a radio, so they
/// live here as side-effect-free functions; the manager keeps the transport I/O.
///
/// Format selection (matches the Phase 2 interop contract):
///   - `a-*`  (PLI)     → compact `TAKPacket` (atak.proto) so stock Meshtastic
///                        gear, the phone-app TAK role, and TAK_Meshtastic_Gateway
///                        all read it.
///   - `b-t-f` (GeoChat) → compact `TAKPacket` GeoChat (unishox2-compressed).
///   - everything else  → the OmniTAK↔OmniTAK `TAKMessage{CoTEvent}` fallback,
///                        which the inbound parser still accepts.
enum MeshTAKRouting {

    /// Which on-the-wire encoder a given CoT event takes over the mesh.
    enum Format: Equatable {
        /// Compact `TAKPacket` (atak.proto) — PLI or GeoChat.
        case takPacket
        /// `TAKMessage{CoTEvent}` fallback (OmniTAK↔OmniTAK, non-PLI/non-chat).
        case takMessage
    }

    /// Decide the wire format for an outbound CoT event. Pure — no radio, no I/O.
    static func decide(for event: CoTEvent) -> Format {
        if event.type.hasPrefix("a-") || event.type == "b-t-f" {
            return .takPacket
        }
        return .takMessage
    }

    /// Encode the bytes to put on the mesh for an outbound CoT event, choosing
    /// the encoder per `decide(for:)`. Pure — returns the payload, sends nothing.
    ///
    /// `TAKPacketCodec.encode` only returns nil for types it doesn't handle; in
    /// that case (which `decide` already routes to `.takMessage`) we fall back to
    /// the `TAKMessage` serializer so a payload is always produced.
    static func encodePayload(for event: CoTEvent) -> Data? {
        switch decide(for: event) {
        case .takPacket:
            return TAKPacketCodec.encode(event) ?? ATAKPluginSerializer.serialize(event)
        case .takMessage:
            return ATAKPluginSerializer.serialize(event)
        }
    }
}
