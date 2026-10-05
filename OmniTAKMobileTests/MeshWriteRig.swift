//
//  MeshWriteRig.swift
//  OmniTAKMobileTests
//
//  A manager wired to a simulated radio behind the manager's link seam, for the
//  tests of what the app sends, in what order, and what it does with the answers
//  (#148). The link records every admin message with the node it was addressed
//  to, the connection it was sent on and when, and refuses what the real clients
//  refuse: a write for another radio, or for a connection that is not the current
//  one. What it accepts goes to a SimulatedRadioModel, whose answers come back as
//  the events a client would deliver.
//
//  Names, keys and numbers are made up.
//

import Combine
import Foundation
import XCTest
@testable import OmniTAK

/// A radio link in front of a simulated radio. It records.
final class FakeRadioLink: MeshtasticAdminLink {

    struct Sent {
        let payload: Data
        let node: UInt32
        let connection: Int
        let wantResponse: Bool
        let packetID: UInt32
        let uptime: UInt64
        var kind: SimulatedRadioModel.Kind { SimulatedRadioModel.kind(of: payload) }
    }

    let radio: SimulatedRadioModel
    /// What the radio sends, as the events a client delivers for the link.
    let events = PassthroughSubject<MeshtasticLinkEvent, Never>()
    /// Which transport the events are tagged with.
    let transport: MeshtasticConnectionType

    /// The client's connection number. A write for another one is refused.
    var connectionSerial = 7
    /// The node number the client holds for its radio. A write for another one
    /// is refused.
    var heldNode: UInt32
    /// False: refuses everything.
    var accepts = true
    /// False: refuses the requests that ask for an answer, and takes the writes.
    var acceptsRequests = true

    private(set) var sent: [Sent] = []

    init(radio: SimulatedRadioModel, transport: MeshtasticConnectionType = .tcp) {
        self.radio = radio
        self.transport = transport
        self.heldNode = radio.nodeNum
    }

    func sendAdmin(payload: Data, to nodeNum: UInt32, connection: Int, wantResponse: Bool, packetID: UInt32) -> Bool {
        guard accepts, connection == connectionSerial, nodeNum == heldNode else { return false }
        if wantResponse && !acceptsRequests { return false }
        sent.append(Sent(payload: payload, node: nodeNum, connection: connection,
                         wantResponse: wantResponse, packetID: packetID, uptime: SimulatedRadioModel.uptime()))
        let tag = connectionSerial
        radio.receive(SimulatedRadioModel.Packet(
            to: nodeNum, admin: payload, wantResponse: wantResponse, packetID: packetID)
        ) { [weak self] fromRadio in
            guard let self = self,
                  let decoded = MeshtasticProtoDecoder.decodeFromRadio(fromRadio),
                  let event = MeshtasticRadioSettings.Event(decoded) else { return }
            self.events.send(MeshtasticLinkEvent(transport: self.transport, connection: tag, event: event))
        }
        return true
    }

    /// Forget what was sent so far.
    func forgetSent() { sent.removeAll() }

    /// What was sent, by what it asked.
    var kinds: [SimulatedRadioModel.Kind] { sent.map(\.kind) }

    /// The set_config and set_channel frames.
    var sets: [Sent] {
        sent.filter {
            switch $0.kind {
            case .setConfig, .setChannel: return true
            default: return false
            }
        }
    }

    /// The get requests.
    var gets: [Sent] {
        sent.filter {
            switch $0.kind {
            case .getConfig, .getChannel: return true
            default: return false
            }
        }
    }
}

/// A manager with a link chosen, a fake link and a simulated radio under it, and
/// the app's saved channels put back afterwards (a channel write records the
/// channel).
@MainActor
final class WriteRig {
    nonisolated static let nodeNum: UInt32 = 0x0A0B_0C0D

    let manager = MeshtasticManager()
    private(set) var radio: SimulatedRadioModel
    private(set) var link: FakeRadioLink
    private var cancellables = Set<AnyCancellable>()
    private let savedChannels: [MeshtasticManager.StoredChannel]

    init(transport: MeshtasticConnectionType = .tcp) {
        radio = SimulatedRadioModel(nodeNum: WriteRig.nodeNum)
        link = FakeRadioLink(radio: radio, transport: transport)
        savedChannels = manager.appChannels
        manager.appChannels = []
        manager.adminLinkOverride = link
        manager.frameSpacing = 0
        manager.answerTimeout = 0.4
        manager.lateAnswerWindow = 5
        attach(link, transport: transport)
    }

    /// Make `link` the chosen connection.
    private func attach(_ link: FakeRadioLink, transport: MeshtasticConnectionType) {
        cancellables.removeAll()
        link.events
            .receive(on: DispatchQueue.main)
            .sink { [weak manager] event in manager?.handleLinkEvent(event) }
            .store(in: &cancellables)
        manager.adminLinkOverride = link
        manager.beginLink(
            .init(transport: transport, connection: link.connectionSerial),
            device: MeshtasticDevice(
                id: "test-radio-\(link.heldNode)", name: "test radio", connectionType: transport == .tcp ? .tcp : .bluetooth,
                devicePath: "127.0.0.1", isConnected: true))
    }

    /// The operator chooses another radio: a new connection, a new node and a new
    /// simulated radio behind it. It has not downloaded anything yet.
    func chooseAnotherRadio(node: UInt32) {
        radio = SimulatedRadioModel(nodeNum: node)
        let next = FakeRadioLink(radio: radio, transport: link.transport)
        next.connectionSerial = link.connectionSerial + 1
        link = next
        attach(next, transport: next.transport)
    }

    func restore() {
        manager.appChannels = savedChannels
        cancellables.removeAll()
    }

    /// What the radio sends in a config download, for the parts a test names, and
    /// what the simulated radio holds from then on. With `started` false the
    /// download never started, which is what a radio that has not sent a my_info
    /// looks like.
    func download(
        started: Bool = true,
        device: ProtoFixture? = RadioFixtures.deviceConfig(),
        position: ProtoFixture? = RadioFixtures.positionConfig(),
        channels: [Int: ProtoFixture] = RadioFixtures.channelSlots()
    ) {
        radio.set(device: device, position: position, channels: channels)
        if started { manager.handleSettingsEvent(.downloadStarted(nodeNum: radio.nodeNum)) }
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

    /// The key as the hex the app keeps for a channel.
    static func hex(_ data: Data) -> String { MeshCoreChannelCodec.hex(data) }
}

/// Run `body` with a rig, and put the app's saved channels back afterwards.
@MainActor
func withRig(
    transport: MeshtasticConnectionType = .tcp,
    _ body: (WriteRig) async throws -> Void
) async rethrows {
    let rig = WriteRig(transport: transport)
    defer { rig.restore() }
    try await body(rig)
}

/// The base64 of a key, as the stock apps show it.
func base64(_ data: Data) -> String { data.base64EncodedString() }

extension MeshtasticWriteResult {
    static let notLoadedRefusal = MeshtasticWriteResult.refused(MeshtasticWriteResult.notLoaded)
    static let notConnectedRefusal = MeshtasticWriteResult.refused(MeshtasticWriteResult.notConnected)
    static let linkChangedRefusal = MeshtasticWriteResult.refused(MeshtasticWriteResult.linkChanged)
    static let noAnswerRefusal = MeshtasticWriteResult.refused(MeshtasticWriteResult.noAnswer)
}
