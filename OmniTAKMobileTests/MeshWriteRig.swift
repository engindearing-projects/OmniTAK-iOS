//
//  MeshWriteRig.swift
//  OmniTAKMobileTests
//
//  A manager wired to a recording link, for the tests of what the app sends and
//  when it does not (#148). The link records every admin message with the node
//  it was addressed to and the connection it was sent on, and refuses what the
//  real clients refuse: a write for another radio, or for a connection that is
//  not the current one.
//
//  Names, keys and numbers are made up.
//

import Foundation
import XCTest
@testable import OmniTAK

/// A radio link that records.
final class RecordingLink: MeshtasticAdminLink {

    struct Sent {
        let payload: Data
        let node: UInt32
        let connection: Int
        let wantResponse: Bool
    }

    /// The client's connection number. A write for another one is refused.
    var connectionSerial = 7
    /// The node number the client holds for its radio. A write for another one
    /// is refused.
    var heldNode: UInt32 = WriteRig.nodeNum
    /// False: refuses everything.
    var accepts = true
    /// False: refuses the requests that ask for an answer, and takes the writes.
    var acceptsRequests = true

    private(set) var sent: [Sent] = []

    func sendAdmin(payload: Data, to nodeNum: UInt32, connection: Int, wantResponse: Bool) -> Bool {
        guard accepts, connection == connectionSerial, nodeNum == heldNode else { return false }
        if wantResponse && !acceptsRequests { return false }
        sent.append(Sent(payload: payload, node: nodeNum, connection: connection, wantResponse: wantResponse))
        return true
    }

    /// The writes (set_config, set_channel), without the read-back requests.
    var writes: [Sent] { sent.filter { !$0.wantResponse } }
    /// The requests that ask for an answer (get_channel_request).
    var requests: [Sent] { sent.filter { $0.wantResponse } }
}

/// A manager with a link chosen, a recording link under it, and the app's saved
/// channels put back afterwards (a successful channel write records the channel).
@MainActor
final class WriteRig {
    nonisolated static let nodeNum: UInt32 = 0x0A0B_0C0D

    let manager = MeshtasticManager()
    let link = RecordingLink()
    private let savedChannels: [MeshtasticManager.StoredChannel]

    init() {
        savedChannels = manager.appChannels
        manager.adminLinkOverride = link
        manager.readBackTimeout = 0.3
        manager.beginLink(
            .init(transport: .tcp, connection: link.connectionSerial),
            device: MeshtasticDevice(
                id: "test-radio", name: "test radio", connectionType: .tcp,
                devicePath: "127.0.0.1", isConnected: true))
    }

    func restore() {
        manager.appChannels = savedChannels
    }

    /// What the radio sends in a config download, for the parts a test names.
    /// With `node` nil the download never started, which is what a radio that
    /// has not sent a my_info looks like.
    func download(
        node: UInt32? = WriteRig.nodeNum,
        device: ProtoFixture? = RadioFixtures.deviceConfig(),
        position: ProtoFixture? = RadioFixtures.positionConfig(),
        channels: [Int: ProtoFixture] = RadioFixtures.channelSlots()
    ) {
        if let node { manager.handleSettingsEvent(.downloadStarted(nodeNum: node)) }
        for index in channels.keys.sorted() {
            manager.handleSettingsEvent(.channel(index: index, body: channels[index]!.data))
        }
        if let device {
            manager.handleSettingsEvent(.config(variant: RadioProto.Config.device, body: device.data))
        }
        if let position {
            manager.handleSettingsEvent(.config(variant: RadioProto.Config.position, body: position.data))
        }
    }

    /// The radio's answer to a read-back request for a slot.
    func answer(_ channel: ProtoFixture, from node: UInt32 = WriteRig.nodeNum) {
        manager.handleSettingsEvent(.channelReadBack(from: node, body: channel.data))
    }

    /// The key as the hex the app keeps for a channel.
    static func hex(_ data: Data) -> String { MeshCoreChannelCodec.hex(data) }
}

@MainActor
func withRig(_ body: (WriteRig) throws -> Void) rethrows {
    let rig = WriteRig()
    defer { rig.restore() }
    try body(rig)
}

/// The base64 of a key, as the stock apps show it.
func base64(_ data: Data) -> String { data.base64EncodedString() }

extension MeshtasticWriteResult {
    static let notLoadedRefusal = MeshtasticWriteResult.refused(MeshtasticWriteResult.notLoaded)
    static let notConnectedRefusal = MeshtasticWriteResult.refused(MeshtasticWriteResult.notConnected)
    static let linkChangedRefusal = MeshtasticWriteResult.refused(MeshtasticWriteResult.linkChanged)
    static let restartingRefusal = MeshtasticWriteResult.refused(MeshtasticWriteResult.restarting)
}
