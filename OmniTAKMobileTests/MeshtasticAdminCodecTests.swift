//
//  MeshtasticAdminCodecTests.swift
//  OmniTAKMobileTests
//
//  #148: a radio replaces a whole sub-config (or channel) with the set_config
//  (or set_channel) it receives, so every write has to carry the radio's own
//  values for everything the operator did not edit. Measured on firmware 2.7.26
//  (meshtasticd), the old encoders turned the GPS off, cleared the time zone and
//  reset a channel's location precision.
//
//  Each test starts from a sub-config or channel the way a radio sends it, with
//  non-default values and a field the app has never heard of, and checks that
//  what the encoder writes is the changed field plus every other field as it
//  was. The checks read the output with FixtureReader, which does not use the
//  code under test.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

final class MeshtasticAdminCodecTests: XCTestCase {

    private typealias Codec = MeshtasticAdminCodec

    /// Every field of `message` except the ones numbered in `except`, raw, in order.
    private func rest(_ message: Data, except: Set<Int>,
                      file: StaticString = #filePath, line: UInt = #line) throws -> [Data] {
        try XCTUnwrap(FixtureReader.rawFields(of: message, except: except), "not well formed",
                      file: file, line: line)
    }

    // MARK: - Position broadcast interval

    func testPositionIntervalChangesTheIntervalAndKeepsEveryOtherField() throws {
        let current = RadioFixtures.positionConfig(broadcastSecs: 3600).data
        let write = try XCTUnwrap(Codec.encodeSetPositionBroadcastInterval(current: current, seconds: 900))

        let sent = try XCTUnwrap(FixtureReader.setConfig(in: write.payload), "an AdminMessage with only set_config")
        XCTAssertEqual(sent.variant, RadioProto.Config.position)
        XCTAssertEqual(write.stored, sent.body, "what the app keeps is what it sent")

        XCTAssertEqual(FixtureReader.varint(RadioProto.Position.broadcastSecs, in: sent.body), 900)
        XCTAssertEqual(try rest(sent.body, except: [RadioProto.Position.broadcastSecs]),
                       try rest(current, except: [RadioProto.Position.broadcastSecs]),
                       "every other field comes back byte for byte")

        // The values the issue measured being reset, by name.
        XCTAssertEqual(FixtureReader.varint(RadioProto.Position.gpsMode, in: sent.body), 1, "GPS stays enabled")
        XCTAssertEqual(FixtureReader.varint(RadioProto.Position.flags, in: sent.body), 811)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Position.smartEnabled, in: sent.body), 1)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Position.gpsUpdateInterval, in: sent.body), 120)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Position.smartMinimumDistance, in: sent.body), 150)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Position.smartMinimumIntervalSecs, in: sent.body), 300)
        XCTAssertTrue(FixtureReader.fields(sent.body)?.contains { $0.number == 77 } ?? false,
                      "the field the app does not know is still there")
    }

    func testPositionIntervalIsAddedWhenTheRadioHadItAtItsDefault() throws {
        let current = ProtoFixture().varint(RadioProto.Position.gpsMode, 1).data
        let write = try XCTUnwrap(Codec.encodeSetPositionBroadcastInterval(current: current, seconds: 900))
        XCTAssertEqual(write.stored, ProtoFixture()
            .varint(RadioProto.Position.broadcastSecs, 900)
            .varint(RadioProto.Position.gpsMode, 1).data)
    }

    func testAPositionIntervalOfZeroLeavesTheFieldOutAsARadioDoes() throws {
        let current = RadioFixtures.positionConfig(broadcastSecs: 3600).data
        let write = try XCTUnwrap(Codec.encodeSetPositionBroadcastInterval(current: current, seconds: 0))
        XCTAssertNil(FixtureReader.varint(RadioProto.Position.broadcastSecs, in: write.stored))
        XCTAssertEqual(try rest(write.stored, except: []),
                       try rest(current, except: [RadioProto.Position.broadcastSecs]))
    }

    func testPositionIntervalOnAnAllDefaultConfigIsTheOneFieldAndTheEnvelope() throws {
        let write = try XCTUnwrap(Codec.encodeSetPositionBroadcastInterval(current: Data(), seconds: 900))
        // 900 = 0x384 = 84 07. PositionConfig is 08 84 07; Config.position (2)
        // wraps it as 12 03 ...; AdminMessage.set_config (34) is tag 92 02.
        XCTAssertEqual(write.stored, Data([0x08, 0x84, 0x07]))
        XCTAssertEqual(write.payload, Data([0x92, 0x02, 0x05, 0x12, 0x03, 0x08, 0x84, 0x07]))
    }

    // MARK: - Device role and rebroadcast mode

    func testDeviceConfigChangesRoleAndRebroadcastAndKeepsEveryOtherField() throws {
        let current = RadioFixtures.deviceConfig().data
        let write = try XCTUnwrap(Codec.encodeSetDeviceConfig(
            current: current, role: .tak, rebroadcastMode: .localOnly))

        let sent = try XCTUnwrap(FixtureReader.setConfig(in: write.payload))
        XCTAssertEqual(sent.variant, RadioProto.Config.device)
        XCTAssertEqual(write.stored, sent.body)

        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: sent.body), RadioProto.DeviceRole.tak)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: sent.body), RadioProto.Rebroadcast.localOnly)

        let changed: Set = [RadioProto.Device.role, RadioProto.Device.rebroadcastMode]
        XCTAssertEqual(try rest(sent.body, except: changed), try rest(current, except: changed))

        // What the issue measured being reset, by name.
        XCTAssertEqual(FixtureReader.bytes(RadioProto.Device.tzdef, in: sent.body), Data(RadioFixtures.timeZone.utf8))
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.ledHeartbeatDisabled, in: sent.body), 1)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.buttonGpio, in: sent.body), 12)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.buzzerGpio, in: sent.body), 13)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.buzzerMode, in: sent.body), 2)
        XCTAssertEqual(FixtureReader.varint(99, in: sent.body), 5, "a field the app does not know")
        XCTAssertEqual(FixtureReader.bytes(RadioProto.futureField, in: sent.body), Data("future".utf8))
    }

    func testChangingOnlyTheRebroadcastModeLeavesTheRoleAsTheRadioHasIt() throws {
        // A role change makes the firmware install that role's defaults, so a
        // write that only means to change the rebroadcast mode must not touch it.
        let current = RadioFixtures.deviceConfig().varint(RadioProto.Device.role, RadioProto.DeviceRole.router).data
        let write = try XCTUnwrap(Codec.encodeSetDeviceConfig(
            current: current, role: nil, rebroadcastMode: .knownOnly))

        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: write.stored), RadioProto.DeviceRole.router)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: write.stored), RadioProto.Rebroadcast.knownOnly)
        XCTAssertEqual(try rest(write.stored, except: [RadioProto.Device.rebroadcastMode]),
                       try rest(current, except: [RadioProto.Device.rebroadcastMode]))
    }

    func testChangingOnlyTheRoleLeavesTheRebroadcastModeAsTheRadioHasIt() throws {
        let current = RadioFixtures.deviceConfig()
            .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.coreOnly).data
        let write = try XCTUnwrap(Codec.encodeSetDeviceConfig(current: current, role: .router, rebroadcastMode: nil))

        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.role, in: write.stored), RadioProto.DeviceRole.router)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: write.stored), RadioProto.Rebroadcast.coreOnly,
                       "a mode the app has no name for is kept")
        XCTAssertEqual(try rest(write.stored, except: [RadioProto.Device.role]),
                       try rest(current, except: [RadioProto.Device.role]))
    }

    func testTheClientRoleIsTheDefaultAndIsLeftOut() throws {
        let current = RadioFixtures.deviceConfig().varint(RadioProto.Device.role, RadioProto.DeviceRole.tak).data
        let write = try XCTUnwrap(Codec.encodeSetDeviceConfig(current: current, role: .client, rebroadcastMode: nil))
        XCTAssertNil(FixtureReader.varint(RadioProto.Device.role, in: write.stored))
        XCTAssertEqual(try rest(write.stored, except: []), try rest(current, except: [RadioProto.Device.role]))
    }

    func testApplyingTheValuesTheRadioAlreadyHasSendsTheConfigAsItWas() throws {
        let current = RadioFixtures.deviceConfig()
            .varint(RadioProto.Device.role, RadioProto.DeviceRole.tak)
            .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.knownOnly).data
        let write = try XCTUnwrap(Codec.encodeSetDeviceConfig(current: current, role: .tak, rebroadcastMode: .knownOnly))
        XCTAssertEqual(write.stored, current)
        XCTAssertTrue(write.changesNothing, "so there is nothing to send")
    }

    func testDeviceConfigOnAnAllDefaultConfigIsTheTwoFieldsAndTheEnvelope() throws {
        let write = try XCTUnwrap(Codec.encodeSetDeviceConfig(current: Data(), role: .tak, rebroadcastMode: .knownOnly))
        // DeviceConfig: role (1) = 7, rebroadcast_mode (6) = 3.
        XCTAssertEqual(write.stored, Data([0x08, 0x07, 0x30, 0x03]))
        // Config.device (1) wraps it as 0A 04 ...; set_config (34) is tag 92 02.
        XCTAssertEqual(write.payload, Data([0x92, 0x02, 0x06, 0x0A, 0x04, 0x08, 0x07, 0x30, 0x03]))
    }

    // MARK: - Channel

    func testChannelApplyChangesNameKeyAndRoleAndKeepsEverythingElse() throws {
        let current = RadioFixtures.channel(index: 2, name: "alpha", psk: RadioFixtures.key).data
        let write = try XCTUnwrap(Codec.encodeSetChannel(
            current: current, name: "bravo2", key: .set(RadioFixtures.otherKey), role: .primary))

        let sentChannel = try XCTUnwrap(FixtureReader.setChannel(in: write.payload), "an AdminMessage with only set_channel")
        XCTAssertEqual(write.stored, sentChannel)

        // Channel: the index and role
        XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.index, in: sentChannel), 2)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: sentChannel), RadioProto.ChannelRole.primary)
        XCTAssertEqual(try rest(sentChannel, except: [RadioProto.Channel.settings, RadioProto.Channel.role]),
                       try rest(current, except: [RadioProto.Channel.settings, RadioProto.Channel.role]))

        // ChannelSettings: the name and key changed, everything else as it was.
        let oldSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: current))
        let newSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: sentChannel))
        XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: newSettings), Data("bravo2".utf8))
        XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: newSettings)?.count, 32)
        XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: newSettings) == RadioFixtures.otherKey,
                      "the new key was written")
        let edited: Set = [RadioProto.ChannelSettings.psk, RadioProto.ChannelSettings.name]
        XCTAssertEqual(try rest(newSettings, except: edited), try rest(oldSettings, except: edited))
    }

    func testChannelApplyKeepsTheLocationPrecisionAndTheOtherModuleSettings() throws {
        // The issue: position_precision 13 -> 0 on a rename.
        let current = RadioFixtures.channel(index: 0, name: "simtest", role: RadioProto.ChannelRole.primary).data
        let write = try XCTUnwrap(Codec.encodeSetChannel(
            current: current, name: "renamed", key: .set(RadioFixtures.key), role: .primary))

        let settings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: write.stored))
        let module = try XCTUnwrap(FixtureReader.bytes(RadioProto.ChannelSettings.moduleSettings, in: settings))
        XCTAssertEqual(FixtureReader.varint(RadioProto.ModuleSettings.positionPrecision, in: module), 13)
        XCTAssertEqual(FixtureReader.varint(RadioProto.ModuleSettings.isMuted, in: module), 1)
        XCTAssertEqual(FixtureReader.fields(settings)?.first { $0.number == RadioProto.ChannelSettings.id }?.value,
                       Data([0x04, 0x03, 0x02, 0x01]), "the channel id is a fixed32 and stays")
        XCTAssertEqual(FixtureReader.varint(RadioProto.ChannelSettings.uplinkEnabled, in: settings), 1)
        XCTAssertEqual(FixtureReader.varint(RadioProto.ChannelSettings.useAead, in: settings), 1)
        XCTAssertEqual(FixtureReader.varint(40, in: settings), 9, "a field the app does not know")
    }

    func testChannelApplyOnlyRenamingChangesOnlyTheName() throws {
        let current = RadioFixtures.channel(index: 3, name: "alpha", psk: RadioFixtures.key).data
        let write = try XCTUnwrap(Codec.encodeSetChannel(
            current: current, name: "alpha2", key: .keep, role: .secondary))

        let oldSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: current))
        let newSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: write.stored))
        XCTAssertEqual(try rest(newSettings, except: [RadioProto.ChannelSettings.name]),
                       try rest(oldSettings, except: [RadioProto.ChannelSettings.name]),
                       "the key and every other setting are byte for byte what the radio sent")
        XCTAssertEqual(try rest(write.stored, except: [RadioProto.Channel.settings]),
                       try rest(current, except: [RadioProto.Channel.settings]))
    }

    func testChannelApplyToADisabledSlotKeepsItsIndexAndFillsInTheRest() throws {
        let current = RadioFixtures.disabledChannel(index: 5).data
        XCTAssertEqual(current, Data([0x08, 0x05]), "a disabled slot is its index and nothing else")

        let write = try XCTUnwrap(Codec.encodeSetChannel(
            current: current, name: "charlie", key: .set(RadioFixtures.key), role: .secondary))

        let fields = try XCTUnwrap(FixtureReader.fields(write.stored))
        XCTAssertEqual(fields.map(\.number), [1, 2, 3], "index, settings, role and nothing else")
        XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.index, in: write.stored), 5)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: write.stored), RadioProto.ChannelRole.secondary)
        let settings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: write.stored))
        XCTAssertEqual(FixtureReader.fields(settings)?.map(\.number), [2, 3])
        XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: settings), Data("charlie".utf8))
    }

    func testChannelApplyToSlotZeroDoesNotInventAnIndex() throws {
        // Slot 0 is index 0, a default, so the radio leaves it out.
        let write = try XCTUnwrap(Codec.encodeSetChannel(
            current: Data(), name: "ops", key: .set(Data([0x01])), role: .primary))
        XCTAssertNil(FixtureReader.varint(RadioProto.Channel.index, in: write.stored))
        XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: write.stored), RadioProto.ChannelRole.primary)
        let settings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: write.stored))
        XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: settings), Data([0x01]),
                       "a one-byte key is the default-key shorthand and is passed through")
    }

    func testABlankNameAndKeyClearThemAndNothingElse() throws {
        let current = RadioFixtures.channel(index: 4).data
        let write = try XCTUnwrap(Codec.encodeSetChannel(current: current, name: "", key: .clear, role: .secondary))

        let oldSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: current))
        let newSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: write.stored))
        let edited: Set = [RadioProto.ChannelSettings.psk, RadioProto.ChannelSettings.name]
        XCTAssertEqual(try rest(newSettings, except: []), try rest(oldSettings, except: edited))
        XCTAssertTrue(FixtureReader.fields(write.stored)?.contains { $0.number == RadioProto.Channel.settings } ?? false,
                      "the settings message stays")
    }

    func testAnEmptySettingsMessageStaysWhenThereIsNothingToPutInIt() throws {
        let current = ProtoFixture()
            .varint(RadioProto.Channel.index, 6)
            .message(RadioProto.Channel.settings, ProtoFixture())
            .varint(RadioProto.Channel.role, RadioProto.ChannelRole.secondary).data
        let write = try XCTUnwrap(Codec.encodeSetChannel(current: current, name: "", key: .keep, role: .secondary))
        XCTAssertEqual(write.stored, current)
    }

    func testAChannelEncodedWithTheSameValuesAsTheRadioHasSendsItAsItWas() throws {
        let current = RadioFixtures.channel(index: 2, name: "alpha", psk: RadioFixtures.key).data
        let write = try XCTUnwrap(Codec.encodeSetChannel(
            current: current, name: "alpha", key: .set(RadioFixtures.key), role: .secondary))
        XCTAssertEqual(write.stored, current)
        XCTAssertTrue(write.changesNothing, "so there is nothing to send")
    }

    func testTheSetChannelEnvelopeIsFieldThirtyThree() throws {
        let write = try XCTUnwrap(Codec.encodeSetChannel(
            current: Data([0x08, 0x01]), name: "x", key: .keep, role: .secondary))
        // tag (33 << 3) | 2 = 266 = 8A 02, then the length of the Channel.
        XCTAssertEqual(write.payload.prefix(2), Data([0x8A, 0x02]))
        XCTAssertEqual(Array(write.payload.dropFirst(2)).first, UInt8(write.stored.count))
    }

    // MARK: - A value the radio already has is not written

    func testAFactoryRadioAskedForItsOwnValuesChangesNothing() throws {
        // A radio nobody has configured sends no role and no rebroadcast mode.
        // That means CLIENT and ALL, not "unknown".
        let current = RadioFixtures.factoryDeviceConfig().data
        let write = try XCTUnwrap(Codec.encodeSetDeviceConfig(current: current, role: .client, rebroadcastMode: .all))
        XCTAssertTrue(write.changesNothing)
        XCTAssertEqual(write.stored, current, "no role and no mode are put in where the radio had none")
    }

    func testAFactoryRadioAskedForAnotherRebroadcastModeKeepsItsRole() throws {
        let current = RadioFixtures.factoryDeviceConfig().data
        // The role control stands at CLIENT, which is what the radio has.
        let write = try XCTUnwrap(Codec.encodeSetDeviceConfig(current: current, role: .client, rebroadcastMode: .localOnly))

        XCTAssertFalse(write.changesNothing)
        XCTAssertNil(FixtureReader.varint(RadioProto.Device.role, in: write.stored), "the role is still CLIENT, still no field")
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: write.stored), RadioProto.Rebroadcast.localOnly)
        XCTAssertEqual(try rest(write.stored, except: [RadioProto.Device.rebroadcastMode]),
                       try rest(current, except: []))
    }

    func testAFieldThatIsNotChangedKeepsItsBytesWhateverTheyWere() throws {
        // The role is written with a longer varint than it needs (82 00 is 2).
        // Asking for the role the radio has must not rewrite it.
        let current = Data([0x08, 0x82, 0x00]) + RadioFixtures.factoryDeviceConfig().data
        let write = try XCTUnwrap(Codec.encodeSetDeviceConfig(current: current, role: .router, rebroadcastMode: .knownOnly))

        XCTAssertFalse(write.changesNothing)
        XCTAssertEqual(Data(write.stored.prefix(3)), Data([0x08, 0x82, 0x00]), "the role field is as the radio wrote it")
        XCTAssertEqual(FixtureReader.varint(RadioProto.Device.rebroadcastMode, in: write.stored), RadioProto.Rebroadcast.knownOnly)
    }

    func testAnIntervalTheRadioAlreadyHasChangesNothing() throws {
        let current = RadioFixtures.positionConfig(broadcastSecs: 3600).data
        let same = try XCTUnwrap(Codec.encodeSetPositionBroadcastInterval(current: current, seconds: 3600))
        XCTAssertTrue(same.changesNothing)
        XCTAssertEqual(same.stored, current)

        // A radio with no interval is using its own default. 0 is that.
        let none = ProtoFixture().varint(RadioProto.Position.gpsMode, 1).data
        let zero = try XCTUnwrap(Codec.encodeSetPositionBroadcastInterval(current: none, seconds: 0))
        XCTAssertTrue(zero.changesNothing)

        let other = try XCTUnwrap(Codec.encodeSetPositionBroadcastInterval(current: current, seconds: 3601))
        XCTAssertFalse(other.changesNothing)
    }

    func testAnUnnamedChannelStaysUnnamedAndNothingIsPutInThePlaceOfItsName() throws {
        let current = RadioFixtures.factoryPrimaryChannel().data

        // The same blank name, the same key, the same role: nothing to send.
        let same = try XCTUnwrap(Codec.encodeSetChannel(
            current: current, name: "", key: .set(Data([0x01])), role: .primary))
        XCTAssertTrue(same.changesNothing)
        XCTAssertEqual(same.stored, current)

        // Another key and no name: the name stays out of the message.
        let rekeyed = try XCTUnwrap(Codec.encodeSetChannel(
            current: current, name: "", key: .set(RadioFixtures.key), role: .primary))
        XCTAssertFalse(rekeyed.changesNothing)
        let settings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: rekeyed.stored))
        XCTAssertEqual(FixtureReader.fields(settings)?.map(\.number), [RadioProto.ChannelSettings.psk],
                       "a key and nothing else: no name field")
        XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: rekeyed.stored), RadioProto.ChannelRole.primary)
    }

    // MARK: - A key is only changed when asked

    func testKeepingTheKeyLeavesTheRadiosKeyBytesAlone() throws {
        let current = RadioFixtures.channel(index: 2, name: "alpha", psk: RadioFixtures.key).data
        let write = try XCTUnwrap(Codec.encodeSetChannel(current: current, name: "renamed", key: .keep, role: .secondary))

        let oldSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: current))
        let newSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: write.stored))
        XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: newSettings), Data("renamed".utf8))
        XCTAssertEqual(try rest(newSettings, except: [RadioProto.ChannelSettings.name]),
                       try rest(oldSettings, except: [RadioProto.ChannelSettings.name]),
                       "the key and every other setting are byte for byte what the radio sent")
    }

    func testRemovingTheKeyIsItsOwnCaseAndTouchesNothingElse() throws {
        let current = RadioFixtures.channel(index: 2, name: "alpha", psk: RadioFixtures.key).data
        let write = try XCTUnwrap(Codec.encodeSetChannel(current: current, name: "alpha", key: .clear, role: .secondary))

        let oldSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: current))
        let newSettings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: write.stored))
        XCTAssertNil(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: newSettings))
        XCTAssertEqual(try rest(newSettings, except: []), try rest(oldSettings, except: [RadioProto.ChannelSettings.psk]))
    }

    func testASetKeyWithNoBytesIsRefusedNotTakenForARemoval() {
        let current = RadioFixtures.channel(index: 2).data
        XCTAssertNil(Codec.encodeSetChannel(current: current, name: "x", key: .set(Data()), role: .secondary))
    }

    func testKeyChangesDescribeThemselvesWithoutTheBytes() {
        XCTAssertEqual(Codec.KeyChange.set(RadioFixtures.key).description, "set(32 bytes)")
        XCTAssertEqual(Codec.KeyChange.keep.description, "keep")
        XCTAssertEqual(Codec.KeyChange.clear.description, "clear")
    }

    // MARK: - A new channel in a free slot

    func testANewChannelIsBuiltFromTheSlotsIndexAlone() throws {
        // The slot is disabled and carries leftovers from its last channel.
        let leftovers = ProtoFixture()
            .varint(RadioProto.Channel.index, 4)
            .message(RadioProto.Channel.settings, ProtoFixture()
                .bytes(RadioProto.ChannelSettings.psk, RadioFixtures.otherKey)
                .string(RadioProto.ChannelSettings.name, "old")
                .fixed32(RadioProto.ChannelSettings.id, 0x0A0B_0C0D)
                .bool(RadioProto.ChannelSettings.uplinkEnabled, true)
                .message(RadioProto.ChannelSettings.moduleSettings, ProtoFixture().varint(RadioProto.ModuleSettings.positionPrecision, 13)))
            .varint(99, 7)
        let write = try XCTUnwrap(Codec.encodeNewChannel(index: 4, current: leftovers.data, name: "fresh", psk: RadioFixtures.key))

        let channel = try XCTUnwrap(FixtureReader.setChannel(in: write.payload))
        XCTAssertEqual(write.stored, channel)
        XCTAssertEqual(FixtureReader.fields(channel)?.map(\.number), [1, 2, 3], "no field of the old channel, known or not")
        XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.index, in: channel), 4)
        XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: channel), RadioProto.ChannelRole.secondary)
        let settings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: channel))
        XCTAssertEqual(FixtureReader.fields(settings)?.map(\.number), [RadioProto.ChannelSettings.psk, RadioProto.ChannelSettings.name])
        XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: settings), Data("fresh".utf8))
        XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: settings) == RadioFixtures.key)
    }

    func testANewChannelWithNoKeyIsAnOpenChannelOnlyBecauseTheCallerAskedForOne() throws {
        let write = try XCTUnwrap(Codec.encodeNewChannel(
            index: 2, current: RadioFixtures.disabledChannel(index: 2).data, name: "open", psk: Data()))
        let channel = try XCTUnwrap(FixtureReader.setChannel(in: write.payload))
        let settings = try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: channel))
        XCTAssertNil(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: settings))
    }

    func testANewChannelIsOnlyBuiltForASlotTheRadioReportsAsDisabled() {
        let inUse = RadioFixtures.channel(index: 3, name: "busy").data
        XCTAssertNil(Codec.encodeNewChannel(index: 3, current: inUse, name: "x", psk: RadioFixtures.key), "in use")
        XCTAssertNil(Codec.encodeNewChannel(index: 3, current: Data([0x08, 0x04]), name: "x", psk: RadioFixtures.key), "another slot's bytes")
        XCTAssertNil(Codec.encodeNewChannel(index: 0, current: Data(), name: "x", psk: RadioFixtures.key), "slot 0 is the primary")
        XCTAssertNil(Codec.encodeNewChannel(index: 8, current: Data([0x08, 0x08]), name: "x", psk: RadioFixtures.key), "no such slot")
        XCTAssertNil(Codec.encodeNewChannel(index: 3, current: Data([0x08, 0x80]), name: "x", psk: RadioFixtures.key), "not well formed")
        XCTAssertNotNil(Codec.encodeNewChannel(index: 3, current: Data([0x08, 0x03]), name: "x", psk: RadioFixtures.key))
    }

    // MARK: - Reading a channel

    func testAChannelSummaryHasTheIndexNameKeyAndRole() throws {
        let summary = try XCTUnwrap(Codec.channelSummary(in: RadioFixtures.channel(index: 5, name: "echo", psk: RadioFixtures.otherKey).data))
        XCTAssertEqual(summary.index, 5)
        XCTAssertEqual(summary.name, "echo")
        XCTAssertTrue(summary.psk == RadioFixtures.otherKey)
        XCTAssertEqual(summary.role, RadioProto.ChannelRole.secondary)
        XCTAssertFalse(summary.isDisabled)
        XCTAssertEqual(summary.description, "slot 5 \"echo\" role 2 key 32 bytes", "the key is never printed")
    }

    func testASlotThatIsOnlyItsIndexIsDisabledAndEmptyIsSlotZero() throws {
        let disabled = try XCTUnwrap(Codec.channelSummary(in: RadioFixtures.disabledChannel(index: 6).data))
        XCTAssertTrue(disabled.isDisabled)
        XCTAssertEqual(disabled.index, 6)
        XCTAssertEqual(disabled.name, "")
        XCTAssertEqual(disabled.psk, Data())
        XCTAssertEqual(try XCTUnwrap(Codec.channelSummary(in: Data())).index, 0)
    }

    func testAChannelSummaryIsNilForAChannelThatIsNotWellFormed() {
        XCTAssertNil(Codec.channelSummary(in: Data([0x08, 0x80])))
        // settings written as a varint, and settings cut short
        XCTAssertNil(Codec.channelSummary(in: ProtoFixture().varint(RadioProto.Channel.settings, 5).data))
        XCTAssertNil(Codec.channelSummary(in: ProtoFixture().message(RadioProto.Channel.settings, ProtoFixture().raw([0x1A, 0x09, 0x01])).data))
        // a negative index
        XCTAssertNil(Codec.channelSummary(in: ProtoFixture().varint(RadioProto.Channel.index, UInt64(bitPattern: -1)).data))
    }

    // MARK: - Asking the radio for a channel

    func testAGetChannelRequestIsFieldOneWithTheIndexPlusOne() {
        XCTAssertEqual(Codec.encodeGetChannelRequest(index: 0), Data([0x08, 0x01]))
        XCTAssertEqual(Codec.encodeGetChannelRequest(index: 7), Data([0x08, 0x08]))
    }

    func testTheChannelInAGetChannelResponseIsFieldTwo() {
        let channel = RadioFixtures.channel(index: 2, name: "echo")
        let admin = ProtoFixture().bytes(2, channel.data).data
        XCTAssertEqual(Codec.channelResponse(in: admin), channel.data)
        XCTAssertNil(Codec.channelResponse(in: ProtoFixture().bytes(34, channel.data).data), "a set_config is not an answer")
        XCTAssertNil(Codec.channelResponse(in: Data([0x12, 0x09, 0x01])), "not well formed")
        XCTAssertNil(Codec.channelResponse(in: ProtoFixture().varint(2, 5).data), "field 2 as a varint")
    }

    func testARequestFrameAsksForAResponseAndAWriteFrameDoesNot() throws {
        let payload = Codec.encodeGetChannelRequest(index: 2)
        let request = try XCTUnwrap(Codec.toRadioFrame(adminPayload: payload, myNodeNum: 0x1234, wantResponse: true))
        let write = try XCTUnwrap(Codec.toRadioFrame(adminPayload: payload, myNodeNum: 0x1234))

        func decoded(_ frame: Data) throws -> Data {
            let toRadio = try XCTUnwrap(FixtureReader.fields(frame))
            let packet = try XCTUnwrap(toRadio.first)
            return try XCTUnwrap(FixtureReader.bytes(RadioProto.MeshPacket.decoded, in: packet.value))
        }
        // Data.want_response is field 3.
        XCTAssertEqual(FixtureReader.varint(3, in: try decoded(request)), 1)
        XCTAssertNil(FixtureReader.varint(3, in: try decoded(write)))
        XCTAssertEqual(FixtureReader.varint(RadioProto.DataMessage.portnum, in: try decoded(request)), RadioProto.adminPortnum)
        XCTAssertEqual(FixtureReader.bytes(RadioProto.DataMessage.payload, in: try decoded(request)), payload)
    }

    func testAChannelNameMayBeElevenBytes() {
        XCTAssertEqual(Codec.maxChannelNameBytes, 11)
    }

    // MARK: - Malformed bytes from the radio

    func testNothingIsBuiltFromBytesThatAreNotAWellFormedMessage() {
        let cut = Data([0x08, 0x80])       // a varint that never ends
        XCTAssertNil(Codec.encodeSetPositionBroadcastInterval(current: cut, seconds: 900))
        XCTAssertNil(Codec.encodeSetDeviceConfig(current: cut, role: .tak, rebroadcastMode: .all))
        XCTAssertNil(Codec.encodeSetChannel(current: cut, name: "x", key: .keep, role: .secondary))
    }

    func testNothingIsBuiltFromAChannelWhoseSettingsAreNotAMessage() {
        // settings (2) written as a varint.
        let current = ProtoFixture().varint(RadioProto.Channel.index, 1).varint(RadioProto.Channel.settings, 5).data
        XCTAssertNil(Codec.encodeSetChannel(current: current, name: "x", key: .keep, role: .secondary))
    }

    func testNothingIsBuiltFromAChannelWhoseSettingsAreCutShort() {
        let current = ProtoFixture()
            .varint(RadioProto.Channel.index, 1)
            .message(RadioProto.Channel.settings, ProtoFixture().raw([0x1A, 0x09, 0x01]))
            .data
        XCTAssertNil(Codec.encodeSetChannel(current: current, name: "x", key: .keep, role: .secondary))
    }

    // MARK: - Reading the radio's values

    func testTheDeviceValuesAreReadFromTheConfigTheRadioSent() {
        let config = RadioFixtures.deviceConfig()
            .varint(RadioProto.Device.role, RadioProto.DeviceRole.sensor)
            .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.coreOnly).data
        XCTAssertEqual(Codec.deviceRole(in: config), 6, "a role the app has no name for is still reported")
        XCTAssertEqual(Codec.rebroadcastMode(in: config), 5)
    }

    func testAValueTheRadioLeftOutIsItsDefault() {
        let config = RadioFixtures.deviceConfig().data
        XCTAssertEqual(Codec.deviceRole(in: config), 0)
        XCTAssertEqual(Codec.rebroadcastMode(in: config), 0)
        XCTAssertEqual(Codec.deviceRole(in: Data()), 0)
        XCTAssertEqual(Codec.positionBroadcastSeconds(in: RadioFixtures.positionConfig().data), 3600)
        XCTAssertEqual(Codec.positionBroadcastSeconds(in: ProtoFixture().varint(RadioProto.Position.gpsMode, 1).data), 0)
    }

    func testNoValueIsReadFromBytesThatAreNotAWellFormedMessage() {
        let cut = Data([0x08, 0x80])
        XCTAssertNil(Codec.deviceRole(in: cut))
        XCTAssertNil(Codec.rebroadcastMode(in: cut))
        XCTAssertNil(Codec.positionBroadcastSeconds(in: cut))
    }

    // MARK: - The frame that carries it

    func testTheAdminFrameIsAddressedToTheRadiosOwnNode() throws {
        let payload = Data([0x92, 0x02, 0x00])
        let nodeNum: UInt32 = 0xA1B2_C3D4
        let frame = try XCTUnwrap(Codec.toRadioFrame(adminPayload: payload, myNodeNum: nodeNum))

        // ToRadio { packet (1) = MeshPacket }
        let toRadio = try XCTUnwrap(FixtureReader.fields(frame))
        XCTAssertEqual(toRadio.map(\.number), [RadioProto.ToRadio.packet])
        let toRadioPacket = try XCTUnwrap(toRadio.first)
        let packet = try XCTUnwrap(FixtureReader.fields(toRadioPacket.value))

        // MeshPacket.to (2) is a fixed32 holding the radio's own node number.
        let to = try XCTUnwrap(packet.first { $0.number == RadioProto.MeshPacket.to })
        XCTAssertEqual(to.wire, 5)
        XCTAssertEqual(to.value, Data([0xD4, 0xC3, 0xB2, 0xA1]))
        XCTAssertNotEqual(to.value, Data([0xFF, 0xFF, 0xFF, 0xFF]), "never the broadcast address")

        // decoded (4): portnum ADMIN_APP and the payload
        let decoded = try XCTUnwrap(FixtureReader.bytes(RadioProto.MeshPacket.decoded, in: toRadioPacket.value))
        XCTAssertEqual(FixtureReader.varint(RadioProto.DataMessage.portnum, in: decoded), RadioProto.adminPortnum)
        XCTAssertEqual(FixtureReader.bytes(RadioProto.DataMessage.payload, in: decoded), payload)

        // want_ack, so the radio applies and saves it
        XCTAssertEqual(FixtureReader.varint(RadioProto.MeshPacket.wantAck, in: toRadioPacket.value), 1)
    }

    func testNoAdminFrameIsBuiltWithoutTheRadiosNodeNumber() {
        // The old code fell back to the broadcast address, which would put the
        // frame, and for set_channel the channel key, on the air.
        let payload = Data([0x92, 0x02, 0x00])
        XCTAssertNil(Codec.toRadioFrame(adminPayload: payload, myNodeNum: 0))
        XCTAssertNil(Codec.toRadioFrame(adminPayload: payload, myNodeNum: 0xFFFF_FFFF))
    }
}
