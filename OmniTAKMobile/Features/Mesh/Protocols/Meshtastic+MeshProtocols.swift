//
//  Meshtastic+MeshProtocols.swift
//  OmniTAK Mobile
//
//  Conform the existing Meshtastic types to the framework-neutral mesh
//  protocols WITHOUT touching their implementations. Meshtastic already exposes
//  every member these protocols require, so these are pure retroactive
//  conformances — Meshtastic behavior is unchanged.
//

import Foundation
import CoreBluetooth

// MARK: - MeshManager

@available(iOS 13.0, *)
extension MeshtasticManager: MeshManager {
    /// Meshtastic is the framework this manager drives.
    public var framework: MeshFramework { .meshtastic }
    // isConnected, connectionState, myNodeNum, meshNodes, disconnect(),
    // publishMeshNodesToMap(), sendCoTOverMesh(_:channelIndex:) are all already
    // declared on MeshtasticManager.
}

// MARK: - MeshTransport

@available(iOS 13.0, *)
extension MeshtasticBLEClient: MeshTransport {
    // isConnected, nodes, myNodeNum, disconnect() already exist.
}

@available(iOS 13.0, *)
extension MeshtasticTCPClient: MeshTransport {
    // MeshtasticTCPClient exposes isConnected, nodes, myNodeNum and disconnect()
    // already; this conformance just names the seam.
}
