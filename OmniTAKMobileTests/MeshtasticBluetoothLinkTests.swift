//
//  MeshtasticBluetoothLinkTests.swift
//  OmniTAKMobileTests
//
//  #148 with Bluetooth as the chosen link. The tests of the TCP link run a real
//  client against a radio in the test process. There is no radio to put behind
//  the Bluetooth client, so these feed it the frames a radio would send through
//  its own decoding path, and ask what it would do with a write:
//   - what the client reads reaches the manager's settings, tagged with the
//     connection the manager accepts;
//   - a write the manager makes goes to the Bluetooth client, with the node the
//     settings came from, and the client refuses it for any other node;
//   - the same reads, writes and read-backs go through a Bluetooth-tagged link
//     in front of a simulated radio.
//
//  The Bluetooth link itself, a peripheral and its characteristics, was never
//  run here: that needs a radio.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

@MainActor
final class MeshtasticBluetoothLinkTests: XCTestCase {

    private let node: UInt32 = 0x00BE_EF01
    private let otherNode: UInt32 = 0x00BE_EF02

    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// A manager whose chosen link is Bluetooth, with the real client and no
    /// peripheral behind it.
    private func bluetoothRig() async throws -> (manager: MeshtasticManager, client: MeshtasticBLEClient) {
        let manager = MeshtasticManager()
        let client = MeshtasticBLEClient()
        manager.useBLEClient(client)
        client.isConnected = true
        client.connectionState = .connected
        manager.beginLink(
            .init(transport: .bluetooth, connection: 0),
            device: MeshtasticDevice(id: "ble-radio", name: "ble radio", connectionType: .bluetooth,
                                     devicePath: "ble", isConnected: true))
        // The client's initial values reach the manager.
        try await Task.sleep(nanoseconds: 250_000_000)
        return (manager, client)
    }

    /// The frames of a download, as the Bluetooth client reads them.
    private func feedDownload(to client: MeshtasticBLEClient) {
        client.parseFromRadio(RadioFixtures.myInfoFrame(nodeNum: node))
        let slots = RadioFixtures.channelSlots()
        for index in 0...7 { client.parseFromRadio(RadioFixtures.channelFrame(slots[index]!)) }
        client.parseFromRadio(RadioFixtures.configFrame(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig()))
        client.parseFromRadio(RadioFixtures.configFrame(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig()))
    }

    // MARK: - What the client reads

    func testADownloadReadByTheBluetoothClientReachesTheSettingsWhenBluetoothIsTheChosenLink() async throws {
        let (manager, client) = try await bluetoothRig()
        defer { manager.disconnect() }

        feedDownload(to: client)

        let loaded = try await eventually {
            manager.radioSettings.nodeNum == self.node
                && manager.radioSettings.hasDeviceConfig && manager.radioSettings.hasPositionConfig
                && manager.radioSettings.channels.count == 8
        }
        XCTAssertTrue(loaded, "the client tags what it reads with the connection the manager chose")
        XCTAssertEqual(manager.radioSettings.positionBroadcastSeconds, 3600)
    }

    func testWhatAnotherConnectionNumberDeliversIsNotKept() async throws {
        let (manager, _) = try await bluetoothRig()
        defer { manager.disconnect() }

        manager.handleLinkEvent(MeshtasticLinkEvent(transport: .bluetooth, connection: 1, event: .downloadStarted(nodeNum: node)))
        manager.handleLinkEvent(MeshtasticLinkEvent(transport: .tcp, connection: 0, event: .downloadStarted(nodeNum: node)))

        XCTAssertNil(manager.radioSettings.nodeNum)
    }

    // MARK: - What the client sends

    func testAWriteTheManagerMakesGoesToTheBluetoothClientWithTheNodeTheSettingsCameFrom() async throws {
        let (manager, client) = try await bluetoothRig()
        defer { manager.disconnect() }
        feedDownload(to: client)
        _ = try await eventually { manager.radioSettings.hasPositionConfig && client.myNodeNum == self.node }

        // There is no peripheral, so nothing can go. What shows that the
        // Bluetooth client was asked, and for the right radio, is what it says
        // about it: it checked the node and then found no link.
        let result = await manager.applyPositionBroadcastInterval(seconds: 900)

        XCTAssertEqual(result, .linkChangedRefusal, "the read could not be sent, so nothing was written")
        let noLink = try await eventually { client.lastError == MeshtasticWriteResult.notConnected }
        XCTAssertTrue(noLink, "the client had the right node and no peripheral: \(client.lastError ?? "no error")")
    }

    func testTheBluetoothClientRefusesAWriteForAnotherNode() async throws {
        let client = MeshtasticBLEClient()
        client.parseFromRadio(RadioFixtures.myInfoFrame(nodeNum: node))
        let held = try await eventually { client.myNodeNum == self.node }
        XCTAssertTrue(held)
        let payload = MeshtasticAdminCodec.encodeGetChannelRequest(index: 0)

        XCTAssertFalse(client.sendAdmin(payload: payload, to: otherNode, connection: 0, wantResponse: true))
        let refused = try await eventually { client.lastError == MeshtasticWriteResult.linkChanged }
        XCTAssertTrue(refused, "a write for another radio is refused on the node, before anything else")

        // For its own node it gets as far as the missing peripheral.
        client.lastError = nil
        XCTAssertFalse(client.sendAdmin(payload: payload, to: node, connection: 0, wantResponse: true))
        let noLink = try await eventually { client.lastError == MeshtasticWriteResult.notConnected }
        XCTAssertTrue(noLink)
    }

    func testTheBluetoothClientSendsNothingWithoutANodeNumber() {
        let client = MeshtasticBLEClient()
        XCTAssertFalse(client.sendAdmin(payload: MeshtasticAdminCodec.encodeGetChannelRequest(index: 0),
                                        to: 0, connection: 0, wantResponse: true))
        XCTAssertFalse(client.sendAdmin(payload: MeshtasticAdminCodec.encodeGetChannelRequest(index: 0),
                                        to: MeshtasticAdminCodec.broadcastNodeNum, connection: 0, wantResponse: true))
    }

    // MARK: - The same operations through a Bluetooth-tagged link

    func testAWriteThroughABluetoothLinkIsReadWrittenAndReadBack() async throws {
        await withRig(transport: .bluetooth) { rig in
            rig.download()

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .applied)
            XCTAssertEqual(rig.manager.activeLink?.transport, .bluetooth)
            let position = RadioProto.Config.position
            XCTAssertEqual(rig.link.kinds, [.getConfig(variant: position), .setConfig(variant: position), .getConfig(variant: position)])
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 900)
        }
    }

    func testAnAnswerTaggedForTheOtherTransportIsNotKeptWhileBluetoothIsChosen() async throws {
        await withRig(transport: .bluetooth) { rig in
            rig.download()
            rig.radio.answersGets = false
            rig.manager.answerTimeout = 0.3
            let manager = rig.manager
            let task = Task { await manager.applyPositionBroadcastInterval(seconds: 900) }
            while rig.link.gets.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            let request = rig.link.gets[0]

            let answer = MeshtasticAdminCodec.Answer(
                from: WriteRig.nodeNum, requestId: request.packetID, hasReceiveSignals: false,
                content: .config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig().data))
            manager.handleLinkEvent(MeshtasticLinkEvent(transport: .tcp, connection: 7, event: .answer(answer)))

            let result = await task.value
            XCTAssertEqual(result, .noAnswerRefusal)
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }
}
