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
//     in front of a simulated radio, which does what a radio does over Bluetooth:
//     it cuts the link as soon as it takes a config that needs a restart, so the
//     read after the write cannot arrive, and what the operator is told is that
//     it was sent and not confirmed. The write is checked when the radio is back.
//
//  The Bluetooth link itself, a peripheral and its characteristics, was never
//  run here: that needs a radio.
//
//  Names, keys and numbers are made up.
//

import XCTest
import Combine
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
        XCTAssertEqual(client.lastRefusal, MeshtasticWriteResult.notConnected,
                       "the client had the right node and no peripheral: \(client.lastRefusal ?? "no refusal")")
    }

    func testTheBluetoothClientRefusesAWriteForAnotherNode() async throws {
        let client = MeshtasticBLEClient()
        client.parseFromRadio(RadioFixtures.myInfoFrame(nodeNum: node))
        let held = try await eventually { client.myNodeNum == self.node }
        XCTAssertTrue(held)
        let payload = MeshtasticAdminCodec.encodeGetChannelRequest(index: 0)

        XCTAssertFalse(client.sendAdmin(payload: payload, to: otherNode, connection: 0, wantResponse: true))
        XCTAssertEqual(client.lastRefusal, MeshtasticWriteResult.linkChanged,
                       "a write for another radio is refused on the node, before anything else")

        // For its own node it gets as far as the missing peripheral.
        XCTAssertFalse(client.sendAdmin(payload: payload, to: node, connection: 0, wantResponse: true))
        XCTAssertEqual(client.lastRefusal, MeshtasticWriteResult.notConnected)
    }

    func testARefusalByTheBluetoothClientIsNotAConnectionError() async throws {
        let client = MeshtasticBLEClient()
        client.parseFromRadio(RadioFixtures.myInfoFrame(nodeNum: node))
        _ = try await eventually { client.myNodeNum == self.node }

        // Every value lastError takes from here on. The Bluetooth state callback
        // writes it whenever the system reports the radio's state (on a simulator
        // without Bluetooth: "Bluetooth is not supported on this device"), at a
        // moment no test controls, so comparing lastError before and after races
        // that callback. What matters is that a refusal never writes it.
        let written = WrittenValues()
        let watch = client.$lastError.sink { written.append($0) }
        defer { watch.cancel() }

        _ = client.sendAdmin(payload: MeshtasticAdminCodec.encodeGetChannelRequest(index: 0),
                             to: otherNode, connection: 0, wantResponse: true)
        _ = client.sendAdmin(payload: MeshtasticAdminCodec.encodeGetChannelRequest(index: 0),
                             to: node, connection: 0, wantResponse: true)
        // The old code wrote lastError from a block on the main queue: give such a
        // block time to run.
        try await Task.sleep(nanoseconds: 200_000_000)

        // A refusal is the caller's answer (lastRefusal), not a banner on the
        // connection screens.
        let values = written.all
        XCTAssertFalse(values.contains(MeshtasticWriteResult.linkChanged), "lastError took: \(values)")
        XCTAssertFalse(values.contains(MeshtasticWriteResult.notConnected), "lastError took: \(values)")
        XCTAssertEqual(client.lastRefusal, MeshtasticWriteResult.notConnected)
    }

    func testTheBluetoothClientSendsNothingWithoutANodeNumber() {
        let client = MeshtasticBLEClient()
        XCTAssertFalse(client.sendAdmin(payload: MeshtasticAdminCodec.encodeGetChannelRequest(index: 0),
                                        to: 0, connection: 0, wantResponse: true))
        XCTAssertFalse(client.sendAdmin(payload: MeshtasticAdminCodec.encodeGetChannelRequest(index: 0),
                                        to: MeshtasticAdminCodec.broadcastNodeNum, connection: 0, wantResponse: true))
    }

    // MARK: - The same operations through a Bluetooth-tagged link

    func testAChannelWriteThroughABluetoothLinkIsReadWrittenAndReadBack() async throws {
        // A channel saves itself and the radio does not cut the link for it.
        await withRig(transport: .bluetooth) { rig in
            rig.download()

            let outcome = await rig.manager.createChannel(
                name: "delta", keyText: WriteRig.hex(RadioFixtures.key), noEncryption: false, replacePrimary: false)

            XCTAssertEqual(outcome.result, .applied)
            XCTAssertEqual(rig.manager.activeLink?.transport, .bluetooth)
            XCTAssertEqual(rig.link.kinds, [.getChannel(index: 2), .setChannel(index: 2), .getChannel(index: 2)])
            XCTAssertTrue(rig.link.isUp)
            XCTAssertFalse(rig.radio.restartRequested)
        }
    }

    // MARK: - A config write over Bluetooth: the radio cuts the link

    func testAConfigWriteOverBluetoothIsSentAndTheLinkIsCutBeforeTheRadioConfirms() async throws {
        await withRig(transport: .bluetooth) { rig in
            rig.download()

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            await rig.settle()

            // What the operator will see: it was sent, and the link changed before
            // the radio confirmed. It is not "applied", and not "did not answer".
            XCTAssertEqual(result, .notConfirmed(
                "The link changed before the radio confirmed. It is checked when the radio reconnects."))
            let position = RadioProto.Config.position
            XCTAssertEqual(rig.link.kinds, [.getConfig(variant: position), .setConfig(variant: position)])
            XCTAssertEqual(MeshtasticAdminCodec.positionBroadcastSeconds(in: rig.radio.positionConfig), 900,
                           "the radio took it")
            XCTAssertTrue(rig.radio.restartRequested)
            XCTAssertFalse(rig.manager.isConnected, "and cut the link")
            XCTAssertTrue(rig.manager.radioSettings.isEmpty, "what it said before is no longer what it holds")
            let report = rig.manager.configReports.first
            XCTAssertEqual(report?.state, .linkLost)
            XCTAssertEqual(report?.text,
                           "Position interval: 900 s sent. The link changed before the radio confirmed. "
                           + "It is checked when the radio reconnects.")
            let status = MeshtasticSettingsMessages.config(result, what: "Position interval")
            XCTAssertEqual(status, "Position interval sent. The link changed before the radio confirmed. "
                           + "It is checked when the radio reconnects.")
            XCTAssertFalse(status.contains("restarts a few seconds later"), "a restart is not promised for a write nothing confirmed")
        }
    }

    func testAfterTheReconnectTheReportSaysAppliedWhenTheRadioHoldsWhatWasSent() async throws {
        await withRig(transport: .bluetooth) { rig in
            rig.download()
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            await rig.settle()

            rig.reconnect()
            await rig.settle()

            XCTAssertTrue(rig.manager.isConnected)
            let report = rig.manager.configReports.first
            XCTAssertEqual(report?.state, .appliedAfterRestart)
            XCTAssertEqual(report?.text, "Position interval: applied. The radio reports 900 s after reconnecting.")
            XCTAssertTrue(rig.manager.pendingConfigWrites.isEmpty, "it is checked once")
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 900)
        }
    }

    func testAfterTheReconnectTheReportSaysWhatTheRadioReportsWhenItDidNotKeepIt() async throws {
        await withRig(transport: .bluetooth) { rig in
            rig.download()
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            await rig.settle()
            // The radio starts with the one hour it had saved.
            rig.radio.set(position: RadioFixtures.positionConfig())

            rig.reconnect()
            await rig.settle()

            let report = rig.manager.configReports.first
            XCTAssertEqual(report?.state, .differsAfterRestart([.positionInterval: 3600]))
            XCTAssertEqual(report?.text,
                           "Position interval: the radio reports 3600 s after reconnecting. 900 s was sent.")
        }
    }

    func testADeviceWriteOverBluetoothIsCheckedAfterTheReconnectToo() async throws {
        await withRig(transport: .bluetooth) { rig in
            rig.download()
            let result = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .knownOnly)
            await rig.settle()
            guard case .notConfirmed = result else { return XCTFail("\(result)") }
            XCTAssertEqual(rig.manager.configReports.first?.state, .linkLost)

            rig.reconnect()
            await rig.settle()

            XCTAssertEqual(rig.manager.configReports.first?.state, .appliedAfterRestart)
            XCTAssertEqual(rig.manager.configReports.first?.text,
                           "Device config: applied. The radio reports role TAK, rebroadcast Known channels only after reconnecting.")
        }
    }

    func testAnotherRadioReportingInDropsWhatWasSentToThisOne() async throws {
        await withRig(transport: .bluetooth) { rig in
            rig.download()
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            await rig.settle()
            XCTAssertFalse(rig.manager.configReports.isEmpty)

            // The operator connects to another radio. It reports another node.
            rig.chooseAnotherRadio(node: 0x0D0E_0F10)
            rig.download()

            XCTAssertTrue(rig.manager.configReports.isEmpty, "it cannot be checked against another radio")
            XCTAssertTrue(rig.manager.pendingConfigWrites.isEmpty)
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

/// Values written to a published property, from whichever thread writes them.
private final class WrittenValues {
    private let lock = NSLock()
    private var values: [String?] = []

    func append(_ value: String?) {
        lock.lock(); values.append(value); lock.unlock()
    }

    var all: [String?] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}
