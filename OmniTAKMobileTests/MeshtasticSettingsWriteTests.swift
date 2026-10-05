//
//  MeshtasticSettingsWriteTests.swift
//  OmniTAKMobileTests
//
//  #148 at the level of the manager, for the device role, rebroadcast scope and
//  position interval: what goes out when the operator applies a setting, in what
//  order, when nothing goes out, and what the operator is told. Every write is
//  read, patched, sent and read back. Channels are in MeshtasticChannelWriteTests,
//  which answers the radio gives are accepted in MeshtasticAdminRequestTests, and
//  the choice of link is in MeshtasticLinkOwnershipTests.
//
//  A fake link in front of a simulated radio stands in for the radio, so these
//  see exactly the AdminMessage that would be sent, the node it is addressed to
//  and the connection it goes down, and the radio answers the way the firmware
//  does. What the firmware does with the bytes is checked against a simulated
//  radio in MeshtasticSimulatedRadioTests.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

@MainActor
final class MeshtasticSettingsWriteTests: XCTestCase {

    /// Every field of `message` except those numbered in `except`, raw, in order.
    private func rest(_ message: Data, except: Set<Int>,
                      file: StaticString = #filePath, line: UInt = #line) throws -> [Data] {
        try XCTUnwrap(FixtureReader.rawFields(of: message, except: except), "not well formed", file: file, line: line)
    }

    // MARK: Position interval

    func testThePositionIntervalIsWrittenAsTheRadiosOwnConfigWithOneFieldChanged() async throws {
        try await withRig { rig in
            rig.download()
            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(result, .applied)

            XCTAssertEqual(rig.link.sets.count, 1)
            let write = try XCTUnwrap(rig.link.sets.first)
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

    func testTheDeviceConfigIsWrittenWithTheRolesChangedAndTheRestKept() async throws {
        try await withRig { rig in
            rig.download()
            let result = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .localOnly)
            XCTAssertEqual(result, .applied)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sets.first).payload))
            XCTAssertEqual(sent.variant, RadioProto.Config.device)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: sent.body), RadioProto.DeviceRole.tak)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), RadioProto.Rebroadcast.localOnly)
            let changed: Set = [RadioProto.Device.role, RadioProto.Device.rebroadcastMode]
            XCTAssertEqual(try rest(sent.body, except: changed),
                           try rest(RadioFixtures.deviceConfig().data, except: changed))
            XCTAssertEqual(FixtureReader.bytes(RadioProto.Device.tzdef, in: sent.body), Data(RadioFixtures.timeZone.utf8))
        }
    }

    func testTheRebroadcastModeCanBeChangedWithoutTouchingTheRole() async throws {
        try await withRig { rig in
            let device = RadioFixtures.deviceConfig().varint(RadioProto.Device.role, RadioProto.DeviceRole.router)
            rig.download(device: device)
            let result = await rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: .knownOnly)
            XCTAssertEqual(result, .applied)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sets.first).payload))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: sent.body), RadioProto.DeviceRole.router)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), RadioProto.Rebroadcast.knownOnly)
        }
    }

    func testOnlyTheFieldTheOperatorChangedIsWritten() async throws {
        try await withRig { rig in
            // The radio is a TAK radio that rebroadcasts known channels. The
            // operator moves the rebroadcast scope; the role control still
            // stands at TAK, and is passed along with it.
            let device = RadioFixtures.deviceConfig()
                .varint(RadioProto.Device.role, RadioProto.DeviceRole.tak)
                .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.knownOnly)
            rig.download(device: device)

            let result = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .noRebroadcast)
            XCTAssertEqual(result, .applied)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sets.first).payload))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), 4)
            XCTAssertEqual(try rest(sent.body, except: [RadioProto.Device.rebroadcastMode]),
                           try rest(device.data, except: [RadioProto.Device.rebroadcastMode]),
                           "the role is the bytes the radio sent")
        }
    }

    // MARK: The read before a write

    func testAWriteStartsFromWhatTheRadioHoldsNowAndNotFromTheDownload() async throws {
        try await withRig { rig in
            rig.download()
            // Something else changes the radio after the download: another app
            // turns the GPS off and the position flags to 5.
            let changed = ProtoFixture()
                .varint(RadioProto.Position.broadcastSecs, 3600)
                .varint(RadioProto.Position.flags, 5)
                .varint(RadioProto.Position.gpsMode, 0)
            rig.radio.set(position: changed)

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(result, .applied)

            // The radio was asked first, and what was written back is what it
            // said then. The download's flags and GPS mode are not written.
            XCTAssertEqual(rig.link.kinds.first, .getConfig(variant: RadioProto.Config.position))
            XCTAssertTrue(rig.link.gets.first?.wantResponse ?? false)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sets.first).payload))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.flags, in: sent.body), 5)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.gpsMode, in: sent.body) ?? 0, 0, "the GPS stays off")
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.broadcastSecs, in: sent.body), 900)
        }
    }

    func testTheOrderIsReadWriteReadBack() async throws {
        await withRig { rig in
            rig.download()
            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(result, .applied)
            let position = RadioProto.Config.position
            XCTAssertEqual(rig.link.kinds, [.getConfig(variant: position), .setConfig(variant: position),
                                            .getConfig(variant: position)])
        }
    }

    func testNoAnswerToTheReadBeforeAWriteMeansNothingIsSent() async {
        await withRig { rig in
            rig.download()
            rig.radio.answersGets = false

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .noAnswerRefusal)
            XCTAssertTrue(rig.link.sets.isEmpty, "no write without the radio's own bytes")
            XCTAssertEqual(rig.link.gets.count, 1)
        }
    }

    func testAnAnswerThatIsNotTheConfigAskedForIsNotUsedToBuildAWrite() async {
        await withRig { rig in
            rig.download()
            // The radio answers a position request with its device config.
            rig.radio.answersGets = false
            let manager = rig.manager
            let task = Task { await manager.applyPositionBroadcastInterval(seconds: 900) }
            while rig.link.gets.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            let request = rig.link.gets[0]
            let wrongThing = MeshtasticAdminCodec.Answer(
                from: WriteRig.nodeNum, requestId: request.packetID, hasReceiveSignals: false,
                content: .config(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig().data))
            manager.handleSettingsEvent(.answer(wrongThing))

            let result = await task.value
            XCTAssertEqual(result, .noAnswerRefusal)
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }

    // MARK: What the operator is told

    func testAWriteIsAppliedOnlyWhenTheRadioShowsIt() async {
        await withRig { rig in
            rig.download()
            rig.radio.appliesConfigWrites = false

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .notConfirmed("The radio kept its own value."))
            XCTAssertEqual(rig.link.sets.count, 1, "it was sent")
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 3600, "and the app holds what the radio says")
        }
    }

    func testAWriteTheRadioNeverConfirmsIsNotApplied() async {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            guard case .notConfirmed(let reason) = result else { return XCTFail("\(result)") }
            XCTAssertTrue(reason.contains("did not confirm"))
            XCTAssertEqual(rig.link.sets.count, 1)
            // What the radio now holds is not known, and the app does not say.
            XCTAssertNil(rig.manager.radioSettings.positionBroadcastSeconds)
        }
    }

    func testAnAppliedWriteLeavesWhatTheRadioSaidInTheSettings() async {
        await withRig { rig in
            rig.download()
            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(result, .applied)
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 900)
            XCTAssertFalse(rig.manager.radioSettings.isAwaitingRestart(variant: RadioProto.Config.position))
            XCTAssertEqual(rig.radio.positionConfig, rig.manager.radioSettings.config(variant: RadioProto.Config.position))
        }
    }

    // MARK: A role change rewrites the position config

    private func takDefaults(_ role: UInt64) -> ProtoFixture? {
        guard role == RadioProto.DeviceRole.tak else { return nil }
        return ProtoFixture()
            .varint(RadioProto.Position.broadcastSecs, 86_400)
            .varint(RadioProto.Position.flags, 3)
            .varint(RadioProto.Position.gpsMode, 1)
    }

    func testAPositionWriteAfterARoleChangeStartsFromThePositionConfigTheRoleInstalled() async throws {
        try await withRig { rig in
            rig.download()
            rig.radio.roleDefaults = { self.takDefaults($0) }

            let role = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)
            XCTAssertEqual(role, .applied)
            let interval = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(interval, .applied)

            // The second write carries the flags the role installed, not the
            // ones the position config had before.
            let writes = rig.link.sets.compactMap { FixtureReader.setConfig(in: $0.payload) }
                .filter { $0.variant == RadioProto.Config.position }
            let sent = try XCTUnwrap(writes.first)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.flags, in: sent.body), 3)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.broadcastSecs, in: sent.body), 900)
            XCTAssertNil(FixtureReader.varint(RadioProto.Position.smartEnabled, in: sent.body),
                         "the pre-role smart broadcast setting is not written back")
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.flags, in: rig.radio.positionConfig), 3)
        }
    }

    func testTwoWritesStartedTogetherRunOneAfterTheOther() async throws {
        try await withRig { rig in
            rig.download()
            rig.radio.roleDefaults = { self.takDefaults($0) }
            let manager = rig.manager

            // Both are asked for before either has finished. The second does not
            // read until the first has been read back.
            let first = Task { await manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil) }
            let second = Task { await manager.applyPositionBroadcastInterval(seconds: 900) }
            let results = await [first.value, second.value]
            XCTAssertEqual(results, [.applied, .applied])

            let device = RadioProto.Config.device, position = RadioProto.Config.position
            XCTAssertEqual(rig.link.kinds, [
                // the role: read, write, read back, and the position config the role rewrote
                .getConfig(variant: device), .setConfig(variant: device), .getConfig(variant: device),
                .getConfig(variant: position),
                // the interval: read, write, read back
                .getConfig(variant: position), .setConfig(variant: position), .getConfig(variant: position),
            ])
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(
                rig.link.sets.first(where: { $0.kind == .setConfig(variant: position) })).payload))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.flags, in: sent.body), 3,
                           "the interval was written onto the position config the role installed")
        }
    }

    func testARoleChangeLeavesTheSettingsWithThePositionConfigTheRoleInstalled() async {
        await withRig { rig in
            rig.download()
            rig.radio.roleDefaults = { self.takDefaults($0) }

            let role = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)

            XCTAssertEqual(role, .applied)
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 86_400,
                           "the screen shows what the radio holds now")
        }
    }

    // MARK: When the link refuses

    func testAWriteTheLinkRefusedIsRefused() async {
        await withRig { rig in
            rig.download()
            rig.link.accepts = false

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .linkChangedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty)
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 3600, "still what the radio said")
        }
    }

    func testAWriteForAnotherRadioIsRefusedByTheLink() async {
        await withRig { rig in
            rig.download()
            // The client holds another radio's node number: its connection has
            // moved on to a radio these settings are not from.
            rig.link.heldNode = 0x0F0F_0F0F

            let position = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            let device = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)

            XCTAssertEqual(position, .linkChangedRefusal)
            XCTAssertEqual(device, .linkChangedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    func testAWriteForAConnectionThatIsNotTheCurrentOneIsRefused() async {
        await withRig { rig in
            rig.download()
            // The client has begun a newer connection since the operator chose this one.
            rig.link.connectionSerial += 1

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .linkChangedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    func testARefusalIsNotAConnectionError() async {
        await withRig { rig in
            rig.download()
            rig.link.accepts = false

            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            _ = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)

            XCTAssertNil(rig.manager.lastError, "the connection screens show lastError as a banner")
        }
    }

    // MARK: - When nothing is sent

    func testNothingIsSentBeforeTheRadioHasSaidWhoItIs() async {
        await withRig { rig in
            // Frames, and no my_info before them.
            rig.download(started: false)

            XCTAssertNil(rig.manager.radioSettings.nodeNum)
            XCTAssertTrue(rig.manager.radioSettings.isEmpty, "frames of nobody's are not kept")
            let position = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            let device = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)
            XCTAssertEqual(position, .notLoadedRefusal)
            XCTAssertEqual(device, .notLoadedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty, "nothing that could be addressed to everyone, or to the wrong radio")
        }
    }

    func testNothingIsSentWhenNoLinkIsChosen() async {
        await withRig { rig in
            rig.download()
            rig.manager.disconnect()

            let position = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            let device = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .all)
            XCTAssertEqual(position, .notConnectedRefusal)
            XCTAssertEqual(device, .notConnectedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    func testNothingIsSentFromAnAnswerThatIsNotAWellFormedMessage() async {
        await withRig { rig in
            rig.download()
            // The radio's config is cut short.
            rig.radio.set(position: ProtoFixture(Data([0x08, 0x80])))

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .refused(MeshtasticWriteResult.unreadable))
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }

    func testNothingIsSentWhenNoFieldIsAskedFor() async {
        await withRig { rig in
            rig.download()
            let result = await rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: nil)
            XCTAssertEqual(result, .unchanged)
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }

    func testNothingIsSentWhenTheValuesAreTheOnesTheRadioHas() async {
        await withRig { rig in
            let device = RadioFixtures.deviceConfig()
                .varint(RadioProto.Device.role, RadioProto.DeviceRole.tak)
                .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.knownOnly)
            rig.download(device: device, position: RadioFixtures.positionConfig(broadcastSecs: 3600))

            let deviceResult = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: .knownOnly)
            let positionResult = await rig.manager.applyPositionBroadcastInterval(seconds: 3600)

            XCTAssertEqual(deviceResult, .unchanged)
            XCTAssertEqual(positionResult, .unchanged)
            XCTAssertTrue(rig.link.sets.isEmpty, "the radio restarts after a config write, so none is sent for nothing")
            XCTAssertNil(rig.manager.lastError, "nothing to change is not an error")
        }
    }

    func testTheRadioIsToldNothingWhenItsOwnValueIsTheOneAskedForEvenIfTheAppHeldAnother() async {
        await withRig { rig in
            rig.download()
            // The radio has been set to 900 since the download.
            rig.radio.set(position: RadioFixtures.positionConfig(broadcastSecs: 900))

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .unchanged)
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }

    // MARK: - A radio at factory settings

    /// What the radio sends when nobody has configured it: a device config with
    /// no role and no rebroadcast mode (CLIENT and ALL, both defaults), and an
    /// unnamed primary channel with the one-byte default key.
    private func downloadFactoryRadio(_ rig: WriteRig, interval: UInt64 = 900) {
        rig.download(device: RadioFixtures.factoryDeviceConfig(),
                     position: RadioFixtures.factoryPositionConfig(broadcastSecs: interval),
                     channels: RadioFixtures.factoryChannelSlots())
    }

    func testOnAFactoryRadioTheControlsReadClientAllAndTheRadiosInterval() async {
        await withRig { rig in
            downloadFactoryRadio(rig, interval: 900)
            let radio = rig.manager.radioSettings
            XCTAssertTrue(radio.hasDeviceConfig && radio.hasPositionConfig, "loaded, not unknown")
            XCTAssertEqual(radio.namedDeviceRole, .client)
            XCTAssertEqual(radio.namedRebroadcastMode, .all)
            XCTAssertEqual(radio.positionBroadcastSeconds, 900)
        }
    }

    func testOnAFactoryRadioChangingOnlyTheIntervalSendsOnePositionConfigAndNothingElse() async throws {
        try await withRig { rig in
            downloadFactoryRadio(rig, interval: 900)

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 1800)
            XCTAssertEqual(result, .applied)

            XCTAssertEqual(rig.link.sets.count, 1, "one write")
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sets.first).payload),
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

    func testOnAFactoryRadioApplyingTheControlsAsTheyStandSendsNothingAndSaysSo() async {
        await withRig { rig in
            downloadFactoryRadio(rig, interval: 900)

            // What the screen holds before the operator has touched anything.
            let device = await rig.manager.applyDeviceConfig(role: .client, rebroadcastMode: .all)
            let position = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(device, .unchanged)
            XCTAssertEqual(position, .unchanged)
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }

    func testOnAFactoryRadioChangingOnlyTheRebroadcastModeLeavesTheRoleClient() async throws {
        try await withRig { rig in
            downloadFactoryRadio(rig)

            // The role control stands at CLIENT, the radio's role.
            let result = await rig.manager.applyDeviceConfig(role: .client, rebroadcastMode: .localOnly)
            XCTAssertEqual(result, .applied)

            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sets.first).payload))
            XCTAssertEqual(sent.variant, RadioProto.Config.device)
            XCTAssertNil(FixtureReader.varint(RadioProto.Device.role, in: sent.body), "still CLIENT: no role written")
            XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), RadioProto.Rebroadcast.localOnly)
        }
    }

    func testOnAFactoryRadioALeftAloneRoleIsNotWrittenEither() async throws {
        try await withRig { rig in
            downloadFactoryRadio(rig)
            let result = await rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: .knownOnly)
            XCTAssertEqual(result, .applied)
            let sent = try XCTUnwrap(FixtureReader.setConfig(in: try XCTUnwrap(rig.link.sets.first).payload))
            XCTAssertNil(FixtureReader.varint(RadioProto.Device.role, in: sent.body))
        }
    }

    // MARK: - How long what the radio reported is kept

    func testWhatTheRadioReportedIsForgottenWhenTheLinkDrops() async {
        await withRig { rig in
            rig.download()
            XCTAssertFalse(rig.manager.radioSettings.isEmpty)

            rig.manager.handleLinkDown(.tcp)

            XCTAssertTrue(rig.manager.radioSettings.isEmpty)
            let down = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(down, .notConnectedRefusal, "the link is down")
            XCTAssertFalse(rig.manager.isConnected)

            // The link comes back before the download does.
            rig.manager.connectedDevice?.isConnected = true
            let back = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(back, .notLoadedRefusal)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    func testWhatTheRadioReportedIsForgottenWhenANewDownloadStarts() async {
        await withRig { rig in
            rig.download()
            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: WriteRig.nodeNum))

            XCTAssertNil(rig.manager.radioSettings.config(variant: RadioProto.Config.position))
            XCTAssertNil(rig.manager.radioSettings.channel(index: 0))

            // The new download refills it, entry by entry.
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.position,
                                                    body: RadioFixtures.positionConfig(broadcastSecs: 600).data))
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 600)
        }
    }

    func testWhatTheRadioReportedIsForgottenWhenTheOperatorDisconnects() async {
        await withRig { rig in
            rig.download()
            rig.manager.disconnect()
            XCTAssertTrue(rig.manager.radioSettings.isEmpty)
            XCTAssertNil(rig.manager.activeLink)
        }
    }

    func testAnOperationThatIsWaitingWhenTheLinkDropsEndsWithoutWriting() async {
        await withRig { rig in
            rig.download()
            rig.radio.answersGets = false
            rig.manager.answerTimeout = 30
            let manager = rig.manager
            let task = Task { await manager.applyPositionBroadcastInterval(seconds: 900) }
            while rig.link.gets.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }

            manager.handleLinkDown(.tcp)

            let result = await task.value
            XCTAssertEqual(result, .linkChangedRefusal)
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }

    // MARK: - A download through the real decoder

    func testADownloadThroughTheDecoderLeavesTheSettingsReadyToWriteAgainst() async {
        await withRig { rig in
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
            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(result, .applied)
            XCTAssertEqual(rig.link.sets.count, 1)
        }
    }
}
