//
//  MeshtasticSettingsWriteTests.swift
//  OmniTAKMobileTests
//
//  #148 at the level of the manager, for the device role, rebroadcast scope and
//  position interval: what goes out when the operator applies a setting, when
//  nothing goes out, what the app believes after a write, and how long what the
//  radio reported is kept. Channels are in MeshtasticChannelWriteTests and the
//  choice of link in MeshtasticLinkOwnershipTests.
//
//  A recording link stands in for the radio, so these see exactly the
//  AdminMessage that would be sent, the node it is addressed to and the
//  connection it goes down. What the firmware does with it is checked against a
//  simulated radio in MeshtasticSimulatedRadioTests.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

final class MeshtasticSettingsWriteTests: XCTestCase {

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

            XCTAssertEqual(rig.link.writes.count, 1)
            let write = try XCTUnwrap(rig.link.writes.first)
            XCTAssertEqual(write.node, WriteRig.nodeNum, "addressed to the radio that sent the settings")
            XCTAssertEqual(write.connection, rig.link.connectionSerial, "down the connection they came on")
            XCTAssertFalse(write.wantResponse)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: write.payload))
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

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.writes.first).payload))
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

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.writes.first).payload))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: sent.body), RadioProto.DeviceRole.router)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), RadioProto.Rebroadcast.knownOnly)
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

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.writes.first).payload))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), 4)
            XCTAssertEqual(try rest(sent.body, except: [RadioProto.Device.rebroadcastMode]),
                           try rest(device.data, except: [RadioProto.Device.rebroadcastMode]),
                           "the role is the bytes the radio sent")
        }
    }

    // MARK: What a write leaves behind

    @MainActor
    func testAConfigWriteDropsTheEntryItTouchedAndTheNextEditWaitsForTheRestart() {
        withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)

            // "Sent" is all that is known. The settings do not claim the radio
            // now holds 900, and the screen reads "not loaded" for it.
            XCTAssertFalse(rig.manager.radioSettings.hasPositionConfig)
            XCTAssertNil(rig.manager.radioSettings.positionBroadcastSeconds)
            XCTAssertTrue(rig.manager.radioSettings.isAwaitingRestart(variant: RadioProto.Config.position))

            // A retry is not answered "nothing to change": the radio's value is
            // not known, and the app says the radio is restarting.
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .restartingRefusal)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 1800), .restartingRefusal)
            XCTAssertEqual(rig.link.writes.count, 1, "nothing more was sent")
        }
    }

    @MainActor
    func testAWriteDoesNotTouchWhatItDidNotChange() {
        withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)

            XCTAssertTrue(rig.manager.radioSettings.hasDeviceConfig, "the device config is still known")
            XCTAssertNotNil(rig.manager.radioSettings.channel(index: 0))
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .sent)
        }
    }

    @MainActor
    func testTheNextDownloadBringsTheConfigBack() {
        withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)

            // The radio restarted and the app downloaded its settings again,
            // and the radio holds what it holds, which is what was asked here.
            rig.download(position: RadioFixtures.positionConfig(broadcastSecs: 900))

            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 900)
            XCTAssertFalse(rig.manager.radioSettings.isAwaitingRestart(variant: RadioProto.Config.position))
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .unchanged, "now it can be said")
        }
    }

    @MainActor
    func testARoleTheFirmwareChangedAlongTheWayIsWhatTheNextDownloadShows() {
        withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .router, rebroadcastMode: nil), .sent)

            // The firmware installs a role's defaults when the role changes, so
            // the radio comes back with fields the app did not write. The app
            // never claimed otherwise: it holds what the radio says.
            let afterRestart = RadioFixtures.deviceConfig()
                .varint(RadioProto.Device.role, RadioProto.DeviceRole.router)
                .varint(RadioProto.Device.nodeInfoBroadcastSecs, 3_600)
            rig.download(device: afterRestart)

            XCTAssertEqual(rig.manager.radioSettings.config(variant: RadioProto.Config.device), afterRestart.data)
        }
    }

    // MARK: When the link refuses

    @MainActor
    func testAWriteTheLinkRefusedIsRefusedAndTheSettingsAreKept() throws {
        try withRig { rig in
            rig.download()
            rig.link.accepts = false
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .linkChangedRefusal)
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 3600, "still what the radio said")
            XCTAssertFalse(rig.manager.radioSettings.isAwaitingRestart(variant: RadioProto.Config.position))

            // Nothing was sent, so the next write starts from what the radio said.
            rig.link.accepts = true
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 1200), .sent)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.writes.first).payload))
            XCTAssertEqual(try rest(sent.body, except: [RadioProto.Position.broadcastSecs]),
                           try rest(RadioFixtures.positionConfig().data, except: [RadioProto.Position.broadcastSecs]))
        }
    }

    @MainActor
    func testAWriteForAnotherRadioIsRefusedByTheLink() {
        withRig { rig in
            rig.download()
            // The client holds another radio's node number: its connection has
            // moved on to a radio these settings are not from.
            rig.link.heldNode = 0x0F0F_0F0F

            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .linkChangedRefusal)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .linkChangedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    @MainActor
    func testAWriteForAConnectionThatIsNotTheCurrentOneIsRefused() {
        withRig { rig in
            rig.download()
            // The client has begun a newer connection since the operator chose this one.
            rig.link.connectionSerial += 1

            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .linkChangedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    // MARK: - When nothing is sent

    @MainActor
    func testNothingIsSentForASubConfigTheRadioHasNotReported() {
        withRig { rig in
            rig.download(device: nil, position: nil)

            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notLoadedRefusal)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .all), .notLoadedRefusal)
            XCTAssertEqual(rig.manager.lastError, "Radio settings are not loaded yet. Reconnect and try again.")
            XCTAssertTrue(rig.link.sent.isEmpty, "no write was built from scratch")
        }
    }

    @MainActor
    func testEachSettingNeedsItsOwnSubConfig() {
        withRig { rig in
            rig.download(device: RadioFixtures.deviceConfig(), position: nil)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notLoadedRefusal)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .sent)

            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: WriteRig.nodeNum))
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig().data))
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .notLoadedRefusal)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
        }
    }

    @MainActor
    func testNothingIsSentBeforeTheRadioHasSaidWhoItIs() {
        withRig { rig in
            // Frames, and no my_info before them.
            rig.download(node: nil)

            XCTAssertNil(rig.manager.radioSettings.nodeNum)
            XCTAssertTrue(rig.manager.radioSettings.isEmpty, "frames of nobody's are not kept")
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notLoadedRefusal)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .notLoadedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty, "nothing that could be addressed to everyone, or to the wrong radio")
        }
    }

    @MainActor
    func testNothingIsSentWhenNoLinkIsChosen() {
        withRig { rig in
            rig.download()
            rig.manager.disconnect()

            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notConnectedRefusal)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .all), .notConnectedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    @MainActor
    func testNothingIsSentFromSettingsThatAreNotAWellFormedMessage() {
        withRig { rig in
            rig.download(device: nil, position: nil)
            let cut = Data([0x08, 0x80])
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.device, body: cut))
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.position, body: cut))

            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .all), .notLoadedRefusal)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notLoadedRefusal)
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
            XCTAssertTrue(rig.link.sent.isEmpty, "the radio restarts after a config write, so none is sent for nothing")
            XCTAssertNil(rig.manager.lastError, "nothing to change is not an error")
            XCTAssertFalse(rig.manager.radioSettings.isAwaitingAnyRestart, "and nothing was dropped")
        }
    }

    // MARK: - A radio at factory settings

    /// What the radio sends when nobody has configured it: a device config with
    /// no role and no rebroadcast mode (CLIENT and ALL, both defaults), and an
    /// unnamed primary channel with the one-byte default key.
    @MainActor
    private func downloadFactoryRadio(_ rig: WriteRig, interval: UInt64 = 900) {
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

            XCTAssertEqual(rig.link.sent.count, 1, "one write, and no read-back request")
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.writes.first).payload),
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
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    @MainActor
    func testOnAFactoryRadioChangingOnlyTheRebroadcastModeLeavesTheRoleClient() throws {
        try withRig { rig in
            downloadFactoryRadio(rig)

            // The role control stands at CLIENT, the radio's role.
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .client, rebroadcastMode: .localOnly), .sent)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.writes.first).payload))
            XCTAssertEqual(sent.variant, RadioProto.Config.device)
            XCTAssertNil(FixtureReader.varint(RadioProto.Device.role, in: sent.body), "still CLIENT: no role written")
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), RadioProto.Rebroadcast.localOnly)
        }
    }

    @MainActor
    func testOnAFactoryRadioALeftAloneRoleIsNotWrittenEither() throws {
        try withRig { rig in
            downloadFactoryRadio(rig)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: .knownOnly), .sent)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.writes.first).payload))
            XCTAssertNil(FixtureReader.varint(RadioProto.Device.role, in: sent.body))
        }
    }

    // MARK: - How long what the radio reported is kept

    @MainActor
    func testWhatTheRadioReportedIsForgottenWhenTheLinkDrops() {
        withRig { rig in
            rig.download()
            XCTAssertFalse(rig.manager.radioSettings.isEmpty)

            rig.manager.handleLinkDown(.tcp)

            XCTAssertTrue(rig.manager.radioSettings.isEmpty)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notConnectedRefusal, "the link is down")
            XCTAssertFalse(rig.manager.isConnected)

            // The link comes back before the download does.
            rig.manager.connectedDevice?.isConnected = true
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notLoadedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    @MainActor
    func testWhatTheRadioReportedIsForgottenWhenANewDownloadStarts() {
        withRig { rig in
            rig.download()
            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: WriteRig.nodeNum))

            XCTAssertNil(rig.manager.radioSettings.config(variant: RadioProto.Config.position))
            XCTAssertNil(rig.manager.radioSettings.channel(index: 0))
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .notLoadedRefusal)

            // The new download refills it, entry by entry.
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.position,
                                                    body: RadioFixtures.positionConfig(broadcastSecs: 600).data))
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 600)
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .notLoadedRefusal)
        }
    }

    @MainActor
    func testWhatTheRadioReportedIsForgottenWhenTheOperatorDisconnects() {
        withRig { rig in
            rig.download()
            rig.manager.disconnect()
            XCTAssertTrue(rig.manager.radioSettings.isEmpty)
            XCTAssertNil(rig.manager.activeLink)
        }
    }

    @MainActor
    func testASecondRadiosSettingsAreNotMixedWithTheFirstsInAWrite() throws {
        try withRig { rig in
            rig.download()                                                // device config has a time zone
            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: WriteRig.nodeNum)) // the radio again, after a reset
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.device,
                                                    body: ProtoFixture().varint(RadioProto.Device.buttonGpio, 7).data))

            XCTAssertEqual(rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil), .sent)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.writes.first).payload))
            XCTAssertNil(FixtureReader.bytes(RadioProto.Device.tzdef, in: sent.body), "no time zone from before the reset")
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.buttonGpio, in: sent.body), 7)
        }
    }

    // MARK: - A download through the real decoder

    @MainActor
    func testADownloadThroughTheDecoderLeavesTheSettingsReadyToWriteAgainst() {
        withRig { rig in
            var frames = [RadioFixtures.myInfoFrame(nodeNum: WriteRig.nodeNum)]
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

            XCTAssertEqual(rig.manager.radioSettings.nodeNum, WriteRig.nodeNum)
            XCTAssertEqual(Set(rig.manager.radioSettings.configs.keys),
                           [RadioProto.Config.device, RadioProto.Config.position])
            XCTAssertEqual(Set(rig.manager.radioSettings.channels.keys), Set(0...7))
            XCTAssertEqual(rig.manager.applyPositionBroadcastInterval(seconds: 900), .sent)
            XCTAssertEqual(rig.link.writes.count, 1)
        }
    }
}
