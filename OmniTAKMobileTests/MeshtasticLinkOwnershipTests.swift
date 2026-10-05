//
//  MeshtasticLinkOwnershipTests.swift
//  OmniTAKMobileTests
//
//  #148: everything the app holds about a radio belongs to the one connection
//  that is talking to it. The settings, the node number and the connected state
//  are that connection's, only its frames fill them, a write goes down it and is
//  addressed to the radio that sent the settings, and a new connect starts from
//  nothing.
//
//  These run the app's real MeshtasticTCPClient, decoder and manager against
//  radios in the test process (LoopbackRadio), and a Bluetooth client with no
//  radio behind it for the second link. The Bluetooth link itself, and the
//  connectBLE path, which needs a CBPeripheral, are not run.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

@MainActor
final class MeshtasticLinkOwnershipTests: XCTestCase {

    private let savedHostsKey = "meshtastic_saved_hosts"
    private var savedHosts: Any?

    private let nodeA: UInt32 = 0x0000_AAAA
    private let nodeB: UInt32 = 0x0000_BBBB
    private let nodeX: UInt32 = 0x0000_CCCC

    override func setUp() async throws {
        // connectTCP remembers the host in the app's defaults. Put it back.
        savedHosts = UserDefaults.standard.object(forKey: savedHostsKey)
    }

    override func tearDown() async throws {
        if let savedHosts {
            UserDefaults.standard.set(savedHosts, forKey: savedHostsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: savedHostsKey)
        }
    }

    // MARK: - Helpers

    /// Poll until `condition` holds, for up to five seconds.
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Let queued main-queue hops run, for a check that something did not happen.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 250_000_000)
    }

    private func deviceConfig(zone: String, role: UInt64? = nil) -> ProtoFixture {
        var config = ProtoFixture().string(RadioProto.Device.tzdef, zone)
        if let role { config = config.varint(RadioProto.Device.role, role) }
        return config
    }

    private struct Rig {
        let manager: MeshtasticManager
        let client: MeshtasticTCPClient
    }

    private func makeRig() -> Rig {
        let manager = MeshtasticManager()
        let client = MeshtasticTCPClient()
        manager.useTCPClient(client)
        return Rig(manager: manager, client: client)
    }

    /// Connect to a radio and wait for its download.
    private func connect(_ rig: Rig, to radio: LoopbackRadio, port: UInt16) async throws {
        rig.manager.connectTCP(host: "127.0.0.1", port: port)
        let loaded = try await eventually {
            rig.manager.isConnected
                && rig.manager.radioSettings.nodeNum == radio.nodeNum
                && rig.manager.radioSettings.hasDeviceConfig
                && rig.manager.radioSettings.hasPositionConfig
        }
        XCTAssertTrue(loaded, "the download of node \(radio.nodeNum) did not arrive")
    }

    private func bluetoothClient(for manager: MeshtasticManager) -> MeshtasticBLEClient {
        let client = MeshtasticBLEClient()
        manager.useBLEClient(client)
        return client
    }

    /// The download a Bluetooth radio X sends, as events from its client: X's
    /// own time zone, role, interval and a named primary channel.
    private func sendBluetoothDownload(on client: MeshtasticBLEClient) {
        func send(_ event: MeshtasticRadioSettings.Event) {
            client.settingsEvents.send(MeshtasticLinkEvent(transport: .bluetooth, connection: 0, event: event))
        }
        send(.downloadStarted(nodeNum: nodeX))
        send(.channel(index: 0, body: RadioFixtures.channel(index: 0, name: "xray", role: RadioProto.ChannelRole.primary).data))
        send(.config(variant: RadioProto.Config.device, body: deviceConfig(zone: "XRAYZONE", role: RadioProto.DeviceRole.router).data))
        send(.config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig(broadcastSecs: 111).data))
    }

    // MARK: - A radio that connects in the background

    func testTheDownloadOfABluetoothRadioDoesNotReachTheScreenOrAWriteWhileATCPRadioIsConnected() async throws {
        let radioB = LoopbackRadio(nodeNum: nodeB, device: deviceConfig(zone: "BRAVOZONE"))
        let port = try await radioB.start()
        defer { radioB.stop() }
        let rig = makeRig()
        try await connect(rig, to: radioB, port: port)
        defer { rig.manager.disconnect() }

        // The Bluetooth client reconnects to the last paired radio by itself and
        // its download lands while the TCP radio is the connected device.
        let ble = bluetoothClient(for: rig.manager)
        ble.myNodeNum = nodeX
        ble.isConnected = true
        ble.connectionState = .connected
        sendBluetoothDownload(on: ble)
        try await settle()

        // None of it is on the screen.
        let settings = rig.manager.radioSettings
        XCTAssertEqual(settings.nodeNum, nodeB)
        XCTAssertEqual(settings.config(variant: RadioProto.Config.device), deviceConfig(zone: "BRAVOZONE").data)
        XCTAssertEqual(settings.positionBroadcastSeconds, 3600, "the TCP radio's interval, not 111")
        XCTAssertEqual(settings.channelSummary(index: 0)?.name, "simtest", "the TCP radio's primary, not xray")
        XCTAssertEqual(settings.deviceRole, 0, "CLIENT, not the Bluetooth radio's router")
        XCTAssertEqual(rig.manager.myNodeNum, nodeB, "the node number is the connected radio's")

        // And none of it reaches a write: the write is the TCP radio's own
        // settings, addressed to it, down its socket.
        XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .sent)
        let sent = try await eventually { !radioB.admin.isEmpty }
        XCTAssertTrue(sent)
        XCTAssertEqual(radioB.admin.count, 1)
        XCTAssertEqual(radioB.admin[0].to, nodeB)
        let body = try XCTUnwrap(FixtureReader.setConfig(in: radioB.admin[0].payload)).body
        XCTAssertEqual(FixtureReader.bytes(RadioProto.Device.tzdef, in: body), Data("BRAVOZONE".utf8))
        XCTAssertNotEqual(FixtureReader.bytes(RadioProto.Device.tzdef, in: body), Data("XRAYZONE".utf8))
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: body), RadioProto.DeviceRole.tak)
    }

    func testABluetoothDropWhileATCPRadioIsConnectedChangesNothing() async throws {
        let radioB = LoopbackRadio(nodeNum: nodeB)
        let port = try await radioB.start()
        defer { radioB.stop() }
        let rig = makeRig()
        try await connect(rig, to: radioB, port: port)
        defer { rig.manager.disconnect() }
        let ble = bluetoothClient(for: rig.manager)
        let before = rig.manager.radioSettings

        // It comes up, the connection watchdog fires, Bluetooth is switched off:
        // whichever it is, the Bluetooth client reports a drop.
        ble.isConnected = true
        ble.connectionState = .connected
        try await settle()
        ble.isConnected = false
        ble.connectionState = .failed
        ble.lastError = "Connection timed out."
        try await settle()

        XCTAssertTrue(rig.manager.isConnected, "the TCP radio is still connected")
        XCTAssertEqual(rig.manager.connectedDevice?.connectionType, .tcp)
        XCTAssertEqual(rig.manager.connectedDevice?.isConnected, true)
        XCTAssertEqual(rig.manager.radioSettings, before, "and its settings are still there")
        XCTAssertEqual(rig.manager.connectionState, "Connected", "the Bluetooth failure is not shown as the TCP radio's")
        XCTAssertNil(rig.manager.lastError)
        XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent, "and it can still be written to")
    }

    func testABluetoothRadioComingUpDoesNotChangeTheConnectedDevice() async throws {
        let radioB = LoopbackRadio(nodeNum: nodeB)
        let port = try await radioB.start()
        defer { radioB.stop() }
        let rig = makeRig()
        try await connect(rig, to: radioB, port: port)
        defer { rig.manager.disconnect() }
        let ble = bluetoothClient(for: rig.manager)

        ble.myNodeNum = nodeX
        ble.firmwareVersion = "9.9.9"
        ble.isConnected = true
        try await settle()

        XCTAssertEqual(rig.manager.connectedDevice?.connectionType, .tcp)
        XCTAssertEqual(rig.manager.myNodeNum, nodeB)
        XCTAssertNotEqual(rig.manager.firmwareVersion, "9.9.9")
    }

    func testConnectingTCPClosesABluetoothConnectionStillOpen() async throws {
        let radioB = LoopbackRadio(nodeNum: nodeB)
        let port = try await radioB.start()
        defer { radioB.stop() }
        let rig = makeRig()
        let ble = bluetoothClient(for: rig.manager)
        ble.isConnected = true
        ble.connectionState = .connected

        rig.manager.connectTCP(host: "127.0.0.1", port: port)
        defer { rig.manager.disconnect() }

        let closed = try await eventually { !ble.isConnected }
        XCTAssertTrue(closed, "one radio at a time: the Bluetooth connection is the old radio")
    }

    // MARK: - Another host while one is connected

    func testSwitchingTCPHostsWhileConnectedStartsFromNothing() async throws {
        let radioA = LoopbackRadio(nodeNum: nodeA, device: deviceConfig(zone: "ALPHAZONE"))
        let radioB = LoopbackRadio(nodeNum: nodeB, device: deviceConfig(zone: "BRAVOZONE"))
        radioB.answersConfigRequests = false          // connects, and says nothing
        let portA = try await radioA.start()
        let portB = try await radioB.start()
        defer { radioA.stop(); radioB.stop() }
        let rig = makeRig()
        try await connect(rig, to: radioA, port: portA)
        defer { rig.manager.disconnect() }
        let firstConnection = try XCTUnwrap(rig.manager.activeLink)

        // The operator taps the other saved host.
        rig.manager.connectTCP(host: "127.0.0.1", port: portB)

        // At once, and before the new radio has said anything: nothing of the
        // old one is left, and the connection is a new one.
        XCTAssertTrue(rig.manager.radioSettings.isEmpty)
        XCTAssertEqual(rig.manager.myNodeNum, 0)
        XCTAssertFalse(rig.manager.isConnected, "not connected until the new link is up")
        XCTAssertNotEqual(rig.manager.activeLink, firstConnection)
        XCTAssertEqual(rig.client.myNodeNum, 0, "the client's own node number is reset too")

        // The old connection was cancelled, not left open beside the new one.
        let closed = try await eventually { !radioA.isClientConnected }
        XCTAssertTrue(closed, "the first radio's connection is closed")
        let asked = try await eventually { radioB.configRequests == 1 }
        XCTAssertTrue(asked)

        // The new radio is silent, so there is nothing to write against, and
        // the old radio's bytes are not sent to it, addressed to the old radio.
        XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .notLoadedRefusal)
        XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notLoadedRefusal)
        try await settle()
        XCTAssertTrue(radioB.admin.isEmpty, "nothing reached the silent radio")
        XCTAssertTrue(radioA.admin.isEmpty, "and nothing more went to the first")

        // When it does answer, the settings are its own, and so is the write.
        radioB.sendDownload(configID: 5)
        let loaded = try await eventually {
            rig.manager.radioSettings.nodeNum == self.nodeB && rig.manager.radioSettings.hasDeviceConfig
        }
        XCTAssertTrue(loaded)
        XCTAssertEqual(rig.manager.radioSettings.config(variant: RadioProto.Config.device), deviceConfig(zone: "BRAVOZONE").data)
        XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .sent)
        let sent = try await eventually { !radioB.admin.isEmpty }
        XCTAssertTrue(sent)
        XCTAssertEqual(radioB.admin[0].to, nodeB, "addressed to the radio that is there")
        let body = try XCTUnwrap(FixtureReader.setConfig(in: radioB.admin[0].payload)).body
        XCTAssertEqual(FixtureReader.bytes(RadioProto.Device.tzdef, in: body), Data("BRAVOZONE".utf8))
        XCTAssertTrue(radioA.admin.isEmpty)
    }

    func testWhatTheOldConnectionStillDeliversIsIgnored() async throws {
        let radioA = LoopbackRadio(nodeNum: nodeA)
        let radioB = LoopbackRadio(nodeNum: nodeB)
        radioB.answersConfigRequests = false
        let portA = try await radioA.start()
        let portB = try await radioB.start()
        defer { radioA.stop(); radioB.stop() }
        let rig = makeRig()
        try await connect(rig, to: radioA, port: portA)
        defer { rig.manager.disconnect() }
        let oldSerial = try XCTUnwrap(rig.manager.activeLink).connection

        rig.manager.connectTCP(host: "127.0.0.1", port: portB)
        XCTAssertNotEqual(try XCTUnwrap(rig.manager.activeLink).connection, oldSerial)

        // A frame of the first radio's that was already on its way, tagged with
        // the connection it was read on.
        for event: MeshtasticRadioSettings.Event in [
            .downloadStarted(nodeNum: nodeA),
            .config(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig().data),
            .config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig().data),
        ] {
            rig.manager.handleLinkEvent(MeshtasticLinkEvent(transport: .tcp, connection: oldSerial, event: event))
        }

        XCTAssertTrue(rig.manager.radioSettings.isEmpty)
        XCTAssertNil(rig.manager.radioSettings.nodeNum, "the first radio's download did not start anything")

        // Once the new link is up there is still nothing to write against.
        let up = try await eventually { rig.manager.isConnected }
        XCTAssertTrue(up)
        XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notLoadedRefusal)
    }

    func testAHalfReadFrameOfTheOldConnectionIsNotTheStartOfTheNewOnes() async throws {
        let radioA = LoopbackRadio(nodeNum: nodeA)
        let radioB = LoopbackRadio(nodeNum: nodeB, device: deviceConfig(zone: "BRAVOZONE"))
        let portA = try await radioA.start()
        let portB = try await radioB.start()
        defer { radioA.stop(); radioB.stop() }
        let rig = makeRig()
        try await connect(rig, to: radioA, port: portA)
        defer { rig.manager.disconnect() }

        // The first radio claims a frame of 80 bytes and sends 10 of them.
        radioA.sendRaw(Data([0x94, 0xC3, 0x00, 0x50]) + Data(repeating: 0x0A, count: 10))
        try await settle()

        // The new connection's download must not be swallowed to finish it.
        try await connect(rig, to: radioB, port: portB)
        XCTAssertEqual(rig.manager.radioSettings.nodeNum, nodeB)
        XCTAssertEqual(rig.manager.radioSettings.config(variant: RadioProto.Config.device), deviceConfig(zone: "BRAVOZONE").data)
        XCTAssertEqual(Set(rig.manager.radioSettings.channels.keys), Set(0...7), "every channel frame arrived")
    }

    func testTheClientRefusesAWriteBuiltOnAnOlderConnection() async throws {
        let radioA = LoopbackRadio(nodeNum: nodeA)
        let portA = try await radioA.start()
        defer { radioA.stop() }
        let rig = makeRig()
        try await connect(rig, to: radioA, port: portA)
        defer { rig.manager.disconnect() }
        let oldSerial = rig.client.connectionSerial

        // The connection is replaced (the same host again) and the download
        // arrives again, as it would.
        try await connect(rig, to: radioA, port: portA)
        XCTAssertNotEqual(rig.client.connectionSerial, oldSerial)

        // A write built on the first connection is refused by the client.
        let payload = MeshtasticAdminCodec.encodeGetChannelRequest(index: 0)
        XCTAssertFalse(rig.client.sendAdmin(payload: payload, to: nodeA, connection: oldSerial))
        // And so is one for another radio on the current connection.
        XCTAssertFalse(rig.client.sendAdmin(payload: payload, to: nodeB, connection: rig.client.connectionSerial))
        try await settle()
        XCTAssertTrue(radioA.admin.isEmpty, "nothing was sent")

        // One for this radio on this connection goes.
        XCTAssertTrue(rig.client.sendAdmin(payload: payload, to: nodeA, connection: rig.client.connectionSerial))
        let received = try await eventually { radioA.admin.count == 1 }
        XCTAssertTrue(received)
        XCTAssertEqual(radioA.admin[0].to, nodeA)
    }

    // MARK: - The connected state is the link's

    func testTheDeviceIsConnectedOnlyOnceTheLinkIsUp() async throws {
        let radioB = LoopbackRadio(nodeNum: nodeB)
        let port = try await radioB.start()
        defer { radioB.stop() }
        let rig = makeRig()

        rig.manager.connectTCP(host: "127.0.0.1", port: port)
        defer { rig.manager.disconnect() }
        XCTAssertFalse(rig.manager.isConnected, "asked for, not yet up")

        let up = try await eventually { rig.manager.isConnected }
        XCTAssertTrue(up, "the first connection of a session is marked connected when the link is up")
    }

    func testTheRadioClosingTheLinkEmptiesTheSettingsAndMarksTheDeviceDisconnected() async throws {
        let radioB = LoopbackRadio(nodeNum: nodeB)
        let port = try await radioB.start()
        defer { radioB.stop() }
        let rig = makeRig()
        try await connect(rig, to: radioB, port: port)
        defer { rig.manager.disconnect() }

        radioB.dropClient()                           // a restart closes the socket

        let down = try await eventually { !rig.manager.isConnected }
        XCTAssertTrue(down)
        XCTAssertTrue(rig.manager.radioSettings.isEmpty)
        XCTAssertEqual(rig.manager.myNodeNum, 0)
        XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notConnectedRefusal)
    }

    func testAReconnectToTheSameRadioStartsFromNothingAndDownloadsAgain() async throws {
        let radioB = LoopbackRadio(nodeNum: nodeB)
        let port = try await radioB.start()
        defer { radioB.stop() }
        let rig = makeRig()
        try await connect(rig, to: radioB, port: port)
        defer { rig.manager.disconnect() }
        XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
        XCTAssertFalse(rig.manager.radioSettings.hasPositionConfig, "dropped after the write")

        try await connect(rig, to: radioB, port: port)

        XCTAssertTrue(rig.manager.radioSettings.hasPositionConfig, "the download brought it back")
        XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 900, "and the radio now holds what was sent")
        XCTAssertEqual(radioB.accepted, 2)
    }
}
