//
//  MeshtasticSettingsWriteTests.swift
//  OmniTAKMobileTests
//
//  #148 at the level of the manager: what goes out when the operator applies a
//  setting, when nothing goes out, and how long what the radio reported is kept.
//
//  A recording link stands in for the radio, so these see exactly the
//  AdminMessage that would be sent. What the radio does with it is checked
//  against a simulated radio in MeshtasticSimulatedRadioTests, which is skipped
//  unless one is running.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

// MARK: - A radio link that records

private final class RecordingLink: MeshtasticAdminLink {
    private(set) var sent: [Data] = []
    var accepts = true

    func sendAdmin(payload: Data) -> Bool {
        guard accepts else { return false }
        sent.append(payload)
        return true
    }
}

/// A manager wired to a recording link, with the app's saved channels put back
/// afterwards (applyChannel records the channel whether or not it is sent).
@MainActor
private final class Rig {
    static let nodeNum: UInt32 = 0x0A0B_0C0D

    let manager = MeshtasticManager()
    let link = RecordingLink()
    private let savedChannels: [MeshtasticManager.StoredChannel]

    init() {
        savedChannels = manager.appChannels
        manager.adminLinkOverride = link
        manager.connectedDevice = MeshtasticDevice(
            id: "test-radio", name: "test radio", connectionType: .tcp,
            devicePath: "127.0.0.1", isConnected: true)
        manager.myNodeNum = Rig.nodeNum
    }

    func restore() {
        manager.appChannels = savedChannels
    }

    /// What the radio sends in a config download, for the parts a test names.
    func download(
        device: ProtoFixture? = RadioFixtures.deviceConfig(),
        position: ProtoFixture? = RadioFixtures.positionConfig(),
        channels: [Int: ProtoFixture] = RadioFixtures.channelSlots()
    ) {
        manager.handleSettingsEvent(.downloadStarted)
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

    func stored(_ index: Int, name: String, key: Data = RadioFixtures.key, primary: Bool = false)
        -> MeshtasticManager.StoredChannel {
        MeshtasticManager.StoredChannel(
            index: index, name: name, pskHex: MeshCoreChannelCodec.hex(key), isPrimary: primary)
    }
}

@MainActor
private func withRig(_ body: (Rig) throws -> Void) rethrows {
    let rig = Rig()
    defer { rig.restore() }
    try body(rig)
}

// MARK: - What goes out

final class MeshtasticSettingsWriteTests: XCTestCase {

    private let notLoaded = MeshtasticWriteResult.refused(MeshtasticWriteResult.notLoaded)

    /// Every field of `message` except those numbered in `except`, raw, in order.
    private func rest(_ message: Data, except: Set<Int>,
                      file: StaticString = #filePath, line: UInt = #line) throws -> [Data] {
        try XCTUnwrap(FixtureReader.rawFields(of: message, except: except), "not well formed", file: file, line: line)
    }

    // MARK: Position interval

    @MainActor
    func testThePositionIntervalIsWrittenAsTheRadiosOwnConfigWithOneFieldChanged() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)

            XCTAssertEqual(rig.link.sent.count, 1)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: rig.link.sent[0]))
            XCTAssertEqual(sent.variant, RadioProto.Config.position)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.broadcastSecs, in: sent.body), 900)
            XCTAssertEqual(try rest(sent.body, except: [RadioProto.Position.broadcastSecs]),
                           try rest(RadioFixtures.positionConfig().data, except: [RadioProto.Position.broadcastSecs]))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.gpsMode, in: sent.body), 1, "the GPS stays on")
        }
    }

    // MARK: Device config

    @MainActor
    func testTheDeviceConfigIsWrittenWithTheRolesChangedAndTheRestKept() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .localOnly), .sent)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertEqual(sent.variant, RadioProto.Config.device)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: sent.body), RadioProto.DeviceRole.tak)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), RadioProto.Rebroadcast.localOnly)
            let changed: Set = [RadioProto.Device.role, RadioProto.Device.rebroadcastMode]
            XCTAssertEqual(try rest(sent.body, except: changed),
                           try rest(RadioFixtures.deviceConfig().data, except: changed))
            XCTAssertEqual(FixtureReader.bytes(RadioProto.Device.tzdef, in: sent.body), Data(RadioFixtures.timeZone.utf8))
        }
    }

    @MainActor
    func testTheRebroadcastModeCanBeChangedWithoutTouchingTheRole() throws {
        try withRig { rig in
            let device = RadioFixtures.deviceConfig().varint(RadioProto.Device.role, RadioProto.DeviceRole.router)
            rig.download(device: device)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: .knownOnly), .sent)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: sent.body), RadioProto.DeviceRole.router)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), RadioProto.Rebroadcast.knownOnly)
        }
    }

    // MARK: Channel

    @MainActor
    func testAChannelApplyKeepsTheRestOfTheSlotAsTheRadioHasIt() throws {
        try withRig { rig in
            rig.download()
            let result = rig.manager.applyChannel(rig.stored(1, name: "renamed", key: RadioFixtures.key))
            XCTAssertEqual(result, .sent)

            let channel = try XCTUnwrap(FixtureReader.setChannel(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.index, in: channel), 1)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: channel), RadioProto.ChannelRole.secondary)

            let before = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: RadioFixtures.channelSlots()[1]!.data))
            let after = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: channel))
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: after), Data("renamed".utf8))
            XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: after) == RadioFixtures.key)
            let edited: Set = [RadioProto.ChannelSettings.psk, RadioProto.ChannelSettings.name]
            XCTAssertEqual(try rest(after, except: edited), try rest(before, except: edited),
                           "the location precision and every other setting is what the radio sent")
        }
    }

    @MainActor
    func testAChannelCanBeAppliedToASlotTheRadioHasDisabled() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyChannel(rig.stored(5, name: "charlie")), .sent)

            let channel = try XCTUnwrap(FixtureReader.setChannel(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.index, in: channel), 5)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: channel), RadioProto.ChannelRole.secondary)
            let settings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: channel))
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: settings), Data("charlie".utf8))
        }
    }

    // MARK: Edits that follow each other

    @MainActor
    func testASecondEditStartsFromTheFirst() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .sent)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: .localOnly), .sent)

            XCTAssertEqual(rig.link.sent.count, 2)
            let second = try XCTUnwrap(FixtureReader.setConfig(in: rig.link.sent[1]))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: second.body), RadioProto.DeviceRole.tak,
                           "the role the first write set is still there")
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: second.body), RadioProto.Rebroadcast.localOnly)
            let changed: Set = [RadioProto.Device.role, RadioProto.Device.rebroadcastMode]
            XCTAssertEqual(try rest(second.body, except: changed),
                           try rest(RadioFixtures.deviceConfig().data, except: changed))
        }
    }

    @MainActor
    func testTwoPositionIntervalsInARowEachChangeOnlyTheInterval() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 1800), .sent)

            let second = try XCTUnwrap(FixtureReader.setConfig(in: rig.link.sent[1]))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.broadcastSecs, in: second.body), 1800)
            XCTAssertEqual(try rest(second.body, except: [RadioProto.Position.broadcastSecs]),
                           try rest(RadioFixtures.positionConfig().data, except: [RadioProto.Position.broadcastSecs]))
        }
    }

    @MainActor
    func testWhatWasSentIsWhatTheAppKeepsForTheNextEdit() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertEqual(rig.manager.radioSettings.config(variant: RadioProto.Config.position), sent.body)
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 900)
        }
    }

    @MainActor
    func testAWriteTheLinkRefusedIsNotRemembered() throws {
        try withRig { rig in
            rig.download()
            rig.link.accepts = false
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900),
                           .refused(MeshtasticWriteResult.notConnected))
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 3600, "still what the radio said")

            // The next write starts from what the radio said.
            rig.link.accepts = true
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 1200), .sent)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertEqual(try rest(sent.body, except: [RadioProto.Position.broadcastSecs]),
                           try rest(RadioFixtures.positionConfig().data, except: [RadioProto.Position.broadcastSecs]))
        }
    }

    // MARK: - When nothing is sent

    @MainActor
    func testNothingIsSentForASubConfigTheRadioHasNotReported() {
        withRig { rig in
            rig.download(device: nil, position: nil)

            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), notLoaded)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .all), notLoaded)
            XCTAssertEqual(rig.manager.lastError, "Radio settings are not loaded yet. Reconnect and try again.")
            XCTAssertTrue(rig.link.sent.isEmpty, "no write was built from scratch")
        }
    }

    @MainActor
    func testEachSettingNeedsItsOwnSubConfig() {
        withRig { rig in
            rig.download(device: RadioFixtures.deviceConfig(), position: nil)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), notLoaded)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .sent)

            rig.manager.handleSettingsEvent(.downloadStarted)
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig().data))
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), notLoaded)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
        }
    }

    @MainActor
    func testNothingIsSentForAChannelSlotTheRadioHasNotReported() {
        withRig { rig in
            rig.download(channels: [0: RadioFixtures.channelSlots()[0]!, 1: RadioFixtures.channelSlots()[1]!])

            XCTAssertEqual(rig.manager.applyChannel(rig.stored(3, name: "delta")), notLoaded)
            XCTAssertTrue(rig.link.sent.isEmpty)
            XCTAssertEqual(rig.manager.applyChannel(rig.stored(1, name: "bravo2")), .sent, "a slot it has reported works")
        }
    }

    @MainActor
    func testNothingIsSentWhileTheRadiosNodeNumberIsUnknown() {
        withRig { rig in
            rig.download()
            rig.manager.myNodeNum = 0

            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), notLoaded)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .all), notLoaded)
            XCTAssertEqual(rig.manager.applyChannel(rig.stored(1, name: "bravo2")), notLoaded)
            XCTAssertTrue(rig.link.sent.isEmpty, "nothing that could be addressed to everyone")

            rig.manager.myNodeNum = Rig.nodeNum
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
        }
    }

    @MainActor
    func testNothingIsSentWhenNoRadioIsConnected() {
        withRig { rig in
            rig.download()
            rig.manager.connectedDevice = nil

            let notConnected = MeshtasticWriteResult.refused(MeshtasticWriteResult.notConnected)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), notConnected)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .all), notConnected)
            XCTAssertEqual(rig.manager.applyChannel(rig.stored(1, name: "bravo2")), notConnected)
            XCTAssertTrue(rig.link.sent.isEmpty)
            XCTAssertTrue(rig.manager.appChannels.contains { $0.index == 1 && $0.name == "bravo2" },
                          "the channel is still saved in the app's own list")
        }
    }

    @MainActor
    func testNothingIsSentFromSettingsThatAreNotAWellFormedMessage() {
        withRig { rig in
            rig.download(device: nil, position: nil)
            let cut = Data([0x08, 0x80])
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.device, body: cut))
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.position, body: cut))
            rig.manager.handleSettingsEvent(.channel(index: 2, body: cut))

            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .all), notLoaded)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), notLoaded)
            XCTAssertEqual(rig.manager.applyChannel(rig.stored(2, name: "echo")), notLoaded)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    @MainActor
    func testNothingIsSentWhenNoFieldIsAskedFor() {
        withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: nil), .unchanged)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    @MainActor
    func testNothingIsSentWhenTheValuesAreTheOnesTheRadioHas() {
        withRig { rig in
            let device = RadioFixtures.deviceConfig()
                .varint(RadioProto.Device.role, RadioProto.DeviceRole.tak)
                .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.knownOnly)
            rig.download(device: device, position: RadioFixtures.positionConfig(broadcastSecs: 3600))

            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .knownOnly), .unchanged)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 3600), .unchanged)
            XCTAssertEqual(rig.manager.applyChannel(rig.stored(1, name: "bravo", key: RadioFixtures.otherKey)), .unchanged)
            XCTAssertTrue(rig.link.sent.isEmpty, "the radio restarts after a config write, so none is sent for nothing")
            XCTAssertNil(rig.manager.lastError, "nothing to change is not an error")
        }
    }

    @MainActor
    func testOnlyTheFieldTheOperatorChangedIsWritten() throws {
        try withRig { rig in
            // The radio is a TAK radio that rebroadcasts known channels. The
            // operator moves the rebroadcast scope; the role control still
            // stands at TAK, and is passed along with it.
            let device = RadioFixtures.deviceConfig()
                .varint(RadioProto.Device.role, RadioProto.DeviceRole.tak)
                .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.knownOnly)
            rig.download(device: device)

            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .noRebroadcast), .sent)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), 4)
            XCTAssertEqual(try rest(sent.body, except: [RadioProto.Device.rebroadcastMode]),
                           try rest(device.data, except: [RadioProto.Device.rebroadcastMode]),
                           "the role is the bytes the radio sent")
        }
    }

    // MARK: - A radio at factory settings

    /// What the radio sends when nobody has configured it: a device config with
    /// no role and no rebroadcast mode (CLIENT and ALL, both defaults), and an
    /// unnamed primary channel with the one-byte default key.
    @MainActor
    private func downloadFactoryRadio(_ rig: Rig, interval: UInt64 = 900) {
        rig.download(device: RadioFixtures.factoryDeviceConfig(),
                     position: RadioFixtures.factoryPositionConfig(broadcastSecs: interval),
                     channels: RadioFixtures.factoryChannelSlots())
    }

    @MainActor
    func testOnAFactoryRadioTheControlsReadClientAllAndTheRadiosInterval() {
        withRig { rig in
            downloadFactoryRadio(rig, interval: 900)
            let radio = rig.manager.radioSettings
            XCTAssertTrue(radio.hasDeviceConfig && radio.hasPositionConfig, "loaded, not unknown")
            XCTAssertEqual(radio.namedDeviceRole, .client)
            XCTAssertEqual(radio.namedRebroadcastMode, .all)
            XCTAssertEqual(radio.positionBroadcastSeconds, 900)
        }
    }

    @MainActor
    func testOnAFactoryRadioChangingOnlyTheIntervalSendsOnePositionConfigAndNothingElse() throws {
        try withRig { rig in
            downloadFactoryRadio(rig, interval: 900)

            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 1800), .sent)

            XCTAssertEqual(rig.link.sent.count, 1, "one write")
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sent.first)),
                                     "a set_config and nothing else: no device config, no channel")
            XCTAssertEqual(sent.variant, RadioProto.Config.position)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.broadcastSecs, in: sent.body), 1800)

            // The role is still CLIENT and the primary channel is as it was.
            let radio = rig.manager.radioSettings
            XCTAssertEqual(radio.config(variant: RadioProto.Config.device), RadioFixtures.factoryDeviceConfig().data)
            XCTAssertEqual(radio.namedDeviceRole, .client)
            XCTAssertEqual(radio.channel(index: 0), RadioFixtures.factoryPrimaryChannel().data)
        }
    }

    @MainActor
    func testOnAFactoryRadioApplyingTheControlsAsTheyStandSendsNothingAndSaysSo() {
        withRig { rig in
            downloadFactoryRadio(rig, interval: 900)

            // What the screen holds before the operator has touched anything.
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .client, rebroadcastMode: .all), .unchanged)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .unchanged)
            XCTAssertEqual(rig.manager.applyChannel(rig.stored(0, name: "", key: Data([0x01]), primary: true)), .unchanged)

            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    @MainActor
    func testOnAFactoryRadioChangingOnlyTheRebroadcastModeLeavesTheRoleClient() throws {
        try withRig { rig in
            downloadFactoryRadio(rig)

            // The role control stands at CLIENT, the radio's role.
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .client, rebroadcastMode: .localOnly), .sent)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertEqual(sent.variant, RadioProto.Config.device)
            XCTAssertNil(FixtureReader.varint(RadioProto.Device.role, in: sent.body), "still CLIENT: no role written")
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), RadioProto.Rebroadcast.localOnly)
            XCTAssertEqual(rig.manager.radioSettings.namedDeviceRole, .client)
        }
    }

    @MainActor
    func testOnAFactoryRadioALeftAloneRoleIsNotWrittenEither() throws {
        try withRig { rig in
            downloadFactoryRadio(rig)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: .knownOnly), .sent)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertNil(FixtureReader.varint(RadioProto.Device.role, in: sent.body))
        }
    }

    @MainActor
    func testAnUnnamedPrimaryChannelStaysUnnamedWhenItsKeyIsChanged() throws {
        try withRig { rig in
            downloadFactoryRadio(rig)

            XCTAssertEqual(rig.manager.applyChannel(rig.stored(0, name: "", key: RadioFixtures.key, primary: true)), .sent)

            let channel = try XCTUnwrap(FixtureReader.setChannel(in: try XCTUnwrap(rig.link.sent.first)))
            let settings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: channel))
            XCTAssertEqual(FixtureReader.fields(settings)?.map(\.number), [RadioProto.ChannelSettings.psk],
                           "a key and no name: nothing took the place of the name")
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: channel), RadioProto.ChannelRole.primary)
        }
    }

    @MainActor
    func testAnImportedSetTheRadioAlreadyHasIsNotSentAgain() {
        withRig { rig in
            rig.download()
            let channels = [MeshChannel(name: "one", psk: RadioFixtures.key), MeshChannel(name: "two", psk: RadioFixtures.otherKey)]

            let first = rig.manager.applyImportedChannels(channels)
            XCTAssertEqual(first.applied, 2)
            XCTAssertEqual(first.unchanged, 0)

            let second = rig.manager.applyImportedChannels(channels)
            XCTAssertEqual(second.applied, 0)
            XCTAssertEqual(second.unchanged, 2, "the radio has both now")
            XCTAssertNil(second.refusal)
            XCTAssertEqual(rig.link.sent.count, 2, "each channel was sent once")
        }
    }

    @MainActor
    func testAnImportedSetIsAppliedAsFarAsTheRadioHasReported() {
        withRig { rig in
            // Slots 1 and 2 are known; slot 3 is not.
            let known = RadioFixtures.channelSlots()
            rig.download(channels: [1: known[1]!, 2: known[2]!])
            let channels = [
                MeshChannel(name: "one", psk: RadioFixtures.key),
                MeshChannel(name: "two", psk: RadioFixtures.otherKey),
                MeshChannel(name: "three", psk: RadioFixtures.key),
            ]

            let outcome = rig.manager.applyImportedChannels(channels)

            XCTAssertEqual(outcome.applied, 2)
            XCTAssertEqual(outcome.refusal, MeshtasticWriteResult.notLoaded)
            XCTAssertEqual(rig.link.sent.count, 2)
            XCTAssertEqual(rig.manager.appChannels.filter { ["one", "two", "three"].contains($0.name) }.count, 3,
                           "all three are saved in the app's own list")
        }
    }

    @MainActor
    func testAnImportedSetIsAppliedInFullWhenTheRadioHasReportedEverySlot() {
        withRig { rig in
            rig.download()
            let channels = [MeshChannel(name: "one", psk: RadioFixtures.key), MeshChannel(name: "two", psk: RadioFixtures.key)]
            let outcome = rig.manager.applyImportedChannels(channels)
            XCTAssertEqual(outcome.applied, 2)
            XCTAssertNil(outcome.refusal)
        }
    }

    // MARK: - How long what the radio reported is kept

    @MainActor
    func testWhatTheRadioReportedIsForgottenWhenTheLinkDrops() {
        withRig { rig in
            rig.download()
            XCTAssertFalse(rig.manager.radioSettings.isEmpty)

            rig.manager.handleDisconnection()

            XCTAssertTrue(rig.manager.radioSettings.isEmpty)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900),
                           .refused(MeshtasticWriteResult.notConnected), "the link is down")

            // The link comes back before the download does.
            rig.manager.connectedDevice?.isConnected = true
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), notLoaded)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    @MainActor
    func testWhatTheRadioReportedIsForgottenWhenANewDownloadStarts() {
        withRig { rig in
            rig.download()
            rig.manager.handleSettingsEvent(.downloadStarted)

            XCTAssertTrue(rig.manager.radioSettings.isEmpty)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), notLoaded)

            // The new download refills it, entry by entry.
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.position,
                                                    body: RadioFixtures.positionConfig(broadcastSecs: 600).data))
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 600)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), notLoaded)
        }
    }

    @MainActor
    func testWhatTheRadioReportedIsForgottenWhenTheOperatorDisconnects() {
        withRig { rig in
            rig.download()
            rig.manager.disconnect()
            XCTAssertTrue(rig.manager.radioSettings.isEmpty)
        }
    }

    @MainActor
    func testASecondRadiosSettingsAreNotMixedWithTheFirstsInAWrite() throws {
        try withRig { rig in
            rig.download()                                   // device config has a time zone
            rig.manager.handleSettingsEvent(.downloadStarted) // another radio
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.device,
                                                    body: ProtoFixture().varint(RadioProto.Device.buttonGpio, 7).data))

            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .sent)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sent.first)))
            XCTAssertNil(FixtureReader.bytes(RadioProto.Device.tzdef, in: sent.body), "no time zone from the first radio")
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.buttonGpio, in: sent.body), 7)
        }
    }

    // MARK: - A download through the real decoder

    @MainActor
    func testADownloadThroughTheDecoderLeavesTheSettingsReadyToWriteAgainst() {
        withRig { rig in
            var frames = [RadioFixtures.myInfoFrame(nodeNum: Rig.nodeNum)]
            let slots = RadioFixtures.channelSlots()
            for index in 0...7 { frames.append(RadioFixtures.channelFrame(slots[index]!)) }
            frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig()))
            frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig()))
            frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.security,
                                                    body: ProtoFixture().bytes(2, RadioFixtures.key)))

            for frame in frames {
                guard let payload = MeshtasticProtoDecoder.decodeFromRadio(frame),
                      let event = MeshtasticRadioSettings.Event(payload) else { continue }
                rig.manager.handleSettingsEvent(event)
            }

            XCTAssertEqual(Set(rig.manager.radioSettings.configs.keys),
                           [RadioProto.Config.device, RadioProto.Config.position])
            XCTAssertEqual(Set(rig.manager.radioSettings.channels.keys), Set(0...7))
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
            XCTAssertEqual(rig.link.sent.count, 1)
        }
    }
}

// MARK: - The TCP client and the manager

/// The manager listens to its clients through Combine, with a hop to the main
/// queue. These feed a real MeshtasticTCPClient, with no radio behind it, and
/// check what the manager ends up holding.
final class MeshtasticTCPWiringTests: XCTestCase {

    /// Poll until `condition` holds, for up to three seconds. The hops of the
    /// client's publishers to the main queue are quick, but a loaded machine
    /// is not a reason to fail.
    @MainActor
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            if condition() { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @MainActor
    private func connectingManager() -> (MeshtasticManager, MeshtasticTCPClient) {
        let manager = MeshtasticManager()
        let client = MeshtasticTCPClient()
        manager.useTCPClient(client)
        // What connectTCP does once it has a client.
        manager.connectedDevice = MeshtasticDevice(
            id: "tcp-test", name: "test radio", connectionType: .tcp,
            devicePath: "127.0.0.1", isConnected: true)
        return (manager, client)
    }

    /// The first connection of a session: the client has just been made, so its
    /// first "not connected" reaches the manager after connectTCP marked the
    /// device connected. The device must end up connected once the link is up.
    @MainActor
    func testTheDeviceIsConnectedOnceTheFirstTCPLinkIsUp() async throws {
        let (manager, client) = connectingManager()
        // The client's first value, "not connected", arrives and marks it so.
        let firstValueArrived = try await eventually { !manager.isConnected }
        XCTAssertTrue(firstValueArrived)

        client.isConnected = true   // the link came up

        let connected = try await eventually { manager.isConnected }
        XCTAssertTrue(connected, "the link is up, so the device is connected")
    }

    @MainActor
    func testTheDeviceIsNotConnectedWhenTheTCPLinkGoesDown() async throws {
        let (manager, client) = connectingManager()
        _ = try await eventually { !manager.isConnected }
        client.isConnected = true
        let up = try await eventually { manager.isConnected }
        XCTAssertTrue(up)

        client.isConnected = false

        let down = try await eventually { !manager.isConnected }
        XCTAssertTrue(down)
    }

    @MainActor
    func testSettingsFramesFromTheTCPClientReachTheManagerInOrder() async throws {
        let (manager, client) = connectingManager()
        client.isConnected = true

        // An old download, then a new one that starts with my_info.
        client.settingsEvents.send(.config(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig().data))
        client.settingsEvents.send(.downloadStarted)
        client.settingsEvents.send(.channel(index: 0, body: RadioFixtures.channelSlots()[0]!.data))
        client.settingsEvents.send(.config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig().data))

        // The last event is in, so all of them are.
        let arrived = try await eventually { manager.radioSettings.hasPositionConfig }
        XCTAssertTrue(arrived)
        XCTAssertFalse(manager.radioSettings.hasDeviceConfig, "the old download was dropped when the new one began")
        XCTAssertNotNil(manager.radioSettings.channel(index: 0))
    }

    @MainActor
    func testWhatTheTCPRadioReportedIsForgottenWhenTheLinkGoesDown() async throws {
        let (manager, client) = connectingManager()
        client.isConnected = true
        client.settingsEvents.send(.config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig().data))
        let arrived = try await eventually { manager.radioSettings.hasPositionConfig }
        XCTAssertTrue(arrived)

        client.isConnected = false

        let forgotten = try await eventually { manager.radioSettings.isEmpty }
        XCTAssertTrue(forgotten)
    }

    /// With the real client and no connection behind it, a write goes nowhere
    /// and says so, and the manager does not keep what it did not send.
    @MainActor
    func testAWriteTheTCPClientCannotSendIsRefusedAndNotRemembered() async throws {
        let (manager, client) = connectingManager()
        _ = try await eventually { !manager.isConnected }
        client.isConnected = true
        client.myNodeNum = 0x0A0B_0C0D   // the manager copies the client's
        client.settingsEvents.send(.config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig().data))
        let ready = try await eventually {
            manager.isConnected && manager.myNodeNum == 0x0A0B_0C0D && manager.radioSettings.hasPositionConfig
        }
        XCTAssertTrue(ready)

        let result = manager.applyPositionBroadcastInterval(seconds: 900)

        XCTAssertEqual(result, .refused(MeshtasticWriteResult.notConnected))
        XCTAssertEqual(manager.radioSettings.positionBroadcastSeconds, 3600)
    }
}
