//
//  MeshtasticRadioSettingsTests.swift
//  OmniTAKMobileTests
//
//  #148: before the app writes a setting it has to know what the radio holds, so
//  it keeps the sub-configs and channels the radio sends during the config
//  download. These tests cover reading those two frames (FromRadio.config and
//  FromRadio.channel) and what is kept from them.
//
//  Frames are built from the field numbers and wire types in mesh.proto,
//  config.proto and channel.proto. Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

// MARK: - Reading the frames

final class MeshtasticSettingsFrameDecodingTests: XCTestCase {

    private func decode(_ frame: Data) -> MeshtasticProtoDecoder.FromRadioPayload? {
        MeshtasticProtoDecoder.decodeFromRadio(frame)
    }

    // MARK: Config

    func testEveryConfigVariantIsReportedByItsFieldNumberWithItsBytes() {
        // device 1 ... security 8 (config.proto), then sessionkey 9 and device_ui
        // 10, which the app does not use but the decoder does not drop.
        let variants = [
            RadioProto.Config.device, RadioProto.Config.position, RadioProto.Config.power,
            RadioProto.Config.network, RadioProto.Config.display, RadioProto.Config.lora,
            RadioProto.Config.bluetooth, RadioProto.Config.security, 9, 10,
        ]
        XCTAssertEqual(variants, Array(1...10))
        for variant in variants {
            let body = ProtoFixture().varint(1, UInt64(variant)).string(RadioProto.futureField, "kept")
            XCTAssertEqual(decode(RadioFixtures.configFrame(variant: variant, body: body)),
                           .config(variant: variant, body: body.data),
                           "variant \(variant)")
        }
    }

    func testAConfigBodyComesBackByteForByteWithItsUnknownFields() {
        let body = RadioFixtures.deviceConfig()
        XCTAssertEqual(decode(RadioFixtures.configFrame(variant: RadioProto.Config.device, body: body)),
                       .config(variant: RadioProto.Config.device, body: body.data))
    }

    func testAnEmptyConfigBodyIsKept() {
        // A radio with every field at its default sends an empty sub-config.
        XCTAssertEqual(decode(RadioFixtures.configFrame(variant: RadioProto.Config.device, body: ProtoFixture())),
                       .config(variant: RadioProto.Config.device, body: Data()))
    }

    func testAConfigWithNoVariantIsOther() {
        let frame = ProtoFixture().message(RadioProto.FromRadio.config, ProtoFixture()).data
        XCTAssertEqual(decode(frame), .other(field: RadioProto.FromRadio.config))
    }

    func testAConfigVariantThatIsNotAMessageIsOther() {
        let frame = ProtoFixture()
            .message(RadioProto.FromRadio.config, ProtoFixture().varint(RadioProto.Config.device, 1)).data
        XCTAssertEqual(decode(frame), .other(field: RadioProto.FromRadio.config))
    }

    func testAConfigThatIsCutShortIsNotKept() {
        // The bytes are what a later write sends back. A body that stops in the
        // middle of a field must not become the radio's settings.
        let cutBody = ProtoFixture().varint(RadioProto.Device.buttonGpio, 12).raw([0x08, 0x80])
        let cutVariant = RadioFixtures.configFrame(variant: RadioProto.Config.device, body: cutBody)
        XCTAssertEqual(decode(cutVariant), .other(field: RadioProto.FromRadio.config))

        // And a Config whose own length runs past the frame decodes to nothing.
        let overrun = Data([0x2A, 0x32, 0x0A, 0x02, 0x08, 0x07])
        XCTAssertNil(decode(overrun))
    }

    func testAConfigAfterAnIdIsStillFound() {
        let frame = RadioFixtures.configFrame(variant: RadioProto.Config.position,
                                              body: RadioFixtures.positionConfig(), id: 123_456)
        XCTAssertEqual(decode(frame),
                       .config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig().data))
    }

    func testWhenAConfigCarriesTwoVariantsTheLastWins() {
        let config = ProtoFixture()
            .message(RadioProto.Config.device, ProtoFixture().varint(1, 5))
            .message(RadioProto.Config.position, ProtoFixture().varint(1, 900))
        let frame = ProtoFixture().message(RadioProto.FromRadio.config, config).data
        XCTAssertEqual(decode(frame),
                       .config(variant: RadioProto.Config.position, body: ProtoFixture().varint(1, 900).data))
    }

    // MARK: Channel

    func testEveryChannelSlotIsReportedWithItsIndexAndTheWholeMessage() {
        for index in 0...7 {
            let channel = RadioFixtures.channel(index: index, name: "slot\(index)")
            XCTAssertEqual(decode(RadioFixtures.channelFrame(channel)),
                           .channel(index: index, body: channel.data),
                           "slot \(index)")
        }
    }

    func testADisabledSlotIsReported() {
        XCTAssertEqual(decode(RadioFixtures.channelFrame(RadioFixtures.disabledChannel(index: 4))),
                       .channel(index: 4, body: Data([0x08, 0x04])))
        // Slot 0 disabled is a Channel with nothing in it, which is how the
        // radio writes an all-default message.
        XCTAssertEqual(decode(RadioFixtures.channelFrame(RadioFixtures.disabledChannel(index: 0))),
                       .channel(index: 0, body: Data()))
    }

    func testAChannelWithoutAnIndexIsSlotZero() {
        let channel = ProtoFixture().varint(RadioProto.Channel.role, RadioProto.ChannelRole.primary)
        XCTAssertEqual(decode(RadioFixtures.channelFrame(channel)), .channel(index: 0, body: channel.data))
    }

    func testAChannelWithANegativeIndexIsOther() {
        // int32 -1 is a ten-byte varint.
        let channel = ProtoFixture().varint(RadioProto.Channel.index, UInt64(bitPattern: -1))
        XCTAssertEqual(decode(RadioFixtures.channelFrame(channel)), .other(field: RadioProto.FromRadio.channel))
    }

    func testAChannelWhoseIndexIsNotAVarintIsOther() {
        let channel = ProtoFixture().fixed32(RadioProto.Channel.index, 3)
        XCTAssertEqual(decode(RadioFixtures.channelFrame(channel)), .other(field: RadioProto.FromRadio.channel))
    }

    func testAChannelThatIsCutShortIsNotKept() {
        // settings claims 5 bytes and has 1.
        let channel = ProtoFixture().varint(RadioProto.Channel.index, 2).raw([0x12, 0x05, 0x61])
        XCTAssertEqual(decode(RadioFixtures.channelFrame(channel)), .other(field: RadioProto.FromRadio.channel))
    }

    func testAChannelKeepsItsKeyBytesWithoutAnyOfThemEscapingIntoTheOtherFields() {
        // The key is 32 bytes of anything, including bytes that look like tags.
        let looksLikeFields = Data((0..<32).map { UInt8([0x08, 0x12, 0x1A, 0x80, 0xFF][$0 % 5]) })
        let channel = RadioFixtures.channel(index: 1, name: "tagged", psk: looksLikeFields)
        guard case .channel(let index, let body)? = decode(RadioFixtures.channelFrame(channel)) else {
            return XCTFail("expected a channel")
        }
        XCTAssertEqual(index, 1)
        XCTAssertEqual(body, channel.data)
    }

    // MARK: Both

    func testASliceOfAFrameDecodesTheSame() {
        let config = RadioFixtures.configFrame(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig())
        let channel = RadioFixtures.channelFrame(RadioFixtures.channel(index: 2))
        for frame in [config, channel] {
            let padded = Data([0xDE, 0xAD, 0xBE, 0xEF]) + frame
            XCTAssertEqual(decode(padded.dropFirst(4)), decode(frame))
            XCTAssertNotNil(decode(frame))
        }
    }

    func testTheFramesTheAppDoesNotUseAreStillOther() {
        let metadata = ProtoFixture().message(13, ProtoFixture().string(1, "2.7.0")).data
        XCTAssertEqual(decode(metadata), .other(field: 13))
        let moduleConfig = ProtoFixture().message(9, ProtoFixture().message(1, ProtoFixture())).data
        XCTAssertEqual(decode(moduleConfig), .other(field: 9))
    }

    func testLengthsThatDoNotFitEndTheFrameWithoutTrapping() {
        let aboveIntMax: [UInt8] = Array(repeating: 0xFF, count: 9) + [0x01]
        let equalToIntMax: [UInt8] = Array(repeating: 0xFF, count: 8) + [0x7F]
        for length in [aboveIntMax, equalToIntMax] {
            for field in [RadioProto.FromRadio.config, RadioProto.FromRadio.channel] {
                XCTAssertNil(decode(Data([UInt8(field << 3 | 2)] + length)), "field \(field)")
            }
            // Inside a Config
            let config = Data([UInt8(RadioProto.Config.device << 3 | 2)] + length)
            XCTAssertNil(MeshtasticProtoDecoder.decodeConfig(config))
        }
    }
}

// MARK: - What is kept

final class MeshtasticRadioSettingsTests: XCTestCase {

    private typealias Settings = MeshtasticRadioSettings

    /// The frames of a config download in the order a 2.7 radio sends them: my
    /// info, the channels, the configs (all of them, with a made-up key and
    /// password in the two that carry secrets), then config_complete.
    private func downloadFrames() -> [Data] {
        var frames = [RadioFixtures.myInfoFrame(nodeNum: 0x0A0B_0C0D)]
        let slots = RadioFixtures.channelSlots()
        for index in 0...7 { frames.append(RadioFixtures.channelFrame(slots[index]!)) }
        frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig()))
        frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig()))
        frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.power, body: ProtoFixture().bool(1, true)))
        frames.append(RadioFixtures.configFrame(
            variant: RadioProto.Config.network,
            body: ProtoFixture().bool(1, true).string(3, "made-up-ssid").string(4, "made-up-wifi-password")))
        frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.display, body: ProtoFixture().varint(1, 30)))
        frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.lora, body: ProtoFixture().bool(1, true).varint(7, 1)))
        frames.append(RadioFixtures.configFrame(variant: RadioProto.Config.bluetooth, body: ProtoFixture().bool(1, true)))
        frames.append(RadioFixtures.configFrame(
            variant: RadioProto.Config.security,
            body: ProtoFixture().bytes(1, RadioFixtures.otherKey).bytes(2, RadioFixtures.key)))
        frames.append(ProtoFixture().varint(RadioProto.FromRadio.configCompleteId, 4242).data)
        return frames
    }

    private func settings(afterDownloading frames: [Data]) -> Settings {
        var settings = Settings()
        for frame in frames {
            if let payload = MeshtasticProtoDecoder.decodeFromRadio(frame),
               let event = Settings.Event(payload) {
                settings.apply(event)
            }
        }
        return settings
    }

    // MARK: Events

    func testTheFramesThatChangeWhatIsKnownBecomeEvents() {
        XCTAssertEqual(Settings.Event(.myInfo(nodeNum: 5)), .downloadStarted)
        XCTAssertEqual(Settings.Event(.config(variant: 2, body: Data([1]))), .config(variant: 2, body: Data([1])))
        XCTAssertEqual(Settings.Event(.channel(index: 3, body: Data([2]))), .channel(index: 3, body: Data([2])))
    }

    func testTheFramesThatDoNotChangeItBecomeNothing() {
        XCTAssertNil(Settings.Event(.configComplete(id: 1)))
        XCTAssertNil(Settings.Event(.rebooted))
        XCTAssertNil(Settings.Event(.other(field: 13)))
        XCTAssertNil(Settings.Event(.nodeInfo(MeshNode(id: 1, shortName: "A", longName: "Alpha", lastHeard: nil))))
        XCTAssertNil(Settings.Event(.packet(MeshtasticProtoDecoder.MeshPacketFrame())))
    }

    // MARK: A download

    func testADownloadFillsInTheDeviceAndPositionConfigsAndAllEightChannels() {
        let settings = settings(afterDownloading: downloadFrames())

        XCTAssertEqual(settings.config(variant: RadioProto.Config.device), RadioFixtures.deviceConfig().data)
        XCTAssertEqual(settings.config(variant: RadioProto.Config.position), RadioFixtures.positionConfig().data)
        let slots = RadioFixtures.channelSlots()
        for index in 0...7 {
            XCTAssertEqual(settings.channel(index: index), slots[index]!.data, "slot \(index)")
        }
        XCTAssertTrue(settings.hasDeviceConfig)
        XCTAssertTrue(settings.hasPositionConfig)
    }

    func testOnlyTheConfigsTheAppCanWriteAreKept() {
        let settings = settings(afterDownloading: downloadFrames())
        // The security config holds the radio's private key and the network
        // config holds the WiFi password. Nothing writes them, so they are not
        // kept.
        XCTAssertEqual(Set(settings.configs.keys), [RadioProto.Config.device, RadioProto.Config.position])
        for variant in [RadioProto.Config.power, RadioProto.Config.network, RadioProto.Config.display,
                        RadioProto.Config.lora, RadioProto.Config.bluetooth, RadioProto.Config.security, 9, 10] {
            XCTAssertNil(settings.config(variant: variant), "variant \(variant)")
        }
    }

    func testChannelSlotsThatTheRadioDoesNotHaveAreNotKept() {
        var settings = Settings()
        for index in [-1, 8, 9, 255] {
            settings.apply(.channel(index: index, body: Data([0x08, 0x01])))
        }
        XCTAssertTrue(settings.channels.isEmpty)
        settings.apply(.channel(index: 7, body: Data([0x08, 0x07])))
        XCTAssertEqual(settings.channel(index: 7), Data([0x08, 0x07]))
    }

    func testAnEmptyConfigIsARealEntryNotAMissingOne() {
        var settings = Settings()
        XCTAssertFalse(settings.hasDeviceConfig)
        settings.apply(.config(variant: RadioProto.Config.device, body: Data()))
        XCTAssertTrue(settings.hasDeviceConfig)
        XCTAssertEqual(settings.config(variant: RadioProto.Config.device), Data())
        XCTAssertEqual(settings.deviceRole, 0, "every field at its default is role CLIENT")
    }

    func testAConfigSentAgainReplacesTheOldOne() {
        var settings = Settings()
        settings.apply(.config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig(broadcastSecs: 3600).data))
        settings.apply(.config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig(broadcastSecs: 600).data))
        XCTAssertEqual(settings.positionBroadcastSeconds, 600)
    }

    // MARK: Lifecycle

    func testANewDownloadEmptiesWhatWasKnown() {
        var settings = settings(afterDownloading: downloadFrames())
        XCTAssertFalse(settings.isEmpty)

        settings.apply(.downloadStarted)

        XCTAssertTrue(settings.isEmpty)
        XCTAssertFalse(settings.hasDeviceConfig)
        XCTAssertFalse(settings.hasPositionConfig)
        XCTAssertNil(settings.channel(index: 0))
        XCTAssertNil(settings.deviceRole)
        XCTAssertNil(settings.positionBroadcastSeconds)
    }

    func testTheSecondDownloadIsTheOnlyOneThatCounts() {
        // Another radio, or the same one after a reset, with different values.
        var settings = Settings()
        let first = [RadioFixtures.myInfoFrame(nodeNum: 1),
                     RadioFixtures.configFrame(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig()),
                     RadioFixtures.channelFrame(RadioFixtures.channel(index: 2, name: "old"))]
        let second = [RadioFixtures.myInfoFrame(nodeNum: 2),
                      RadioFixtures.configFrame(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig(broadcastSecs: 60))]
        for frame in first + second {
            if let payload = MeshtasticProtoDecoder.decodeFromRadio(frame), let event = Settings.Event(payload) {
                settings.apply(event)
            }
        }
        XCTAssertFalse(settings.hasDeviceConfig, "the first radio's device config is gone")
        XCTAssertNil(settings.channel(index: 2), "and its channel")
        XCTAssertEqual(settings.positionBroadcastSeconds, 60)
    }

    func testRemovingEverythingEmptiesIt() {
        var settings = settings(afterDownloading: downloadFrames())
        settings.removeAll()
        XCTAssertTrue(settings.isEmpty)
        XCTAssertEqual(settings, Settings())
    }

    // MARK: What the screen reads

    func testTheScreenValuesAreReadFromWhatWasKept() {
        var settings = Settings()
        XCTAssertNil(settings.deviceRole)
        XCTAssertNil(settings.rebroadcastMode)
        XCTAssertNil(settings.positionBroadcastSeconds)

        let device = RadioFixtures.deviceConfig()
            .varint(RadioProto.Device.role, RadioProto.DeviceRole.router)
            .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.knownOnly)
        settings.apply(.config(variant: RadioProto.Config.device, body: device.data))
        settings.apply(.config(variant: RadioProto.Config.position, body: RadioFixtures.positionConfig(broadcastSecs: 1800).data))

        XCTAssertEqual(settings.deviceRole, 2)
        XCTAssertEqual(settings.rebroadcastMode, 3)
        XCTAssertEqual(settings.positionBroadcastSeconds, 1800)
    }

    func testARoleTheAppHasNoNameForIsReportedAsItIs() {
        var settings = Settings()
        let device = ProtoFixture()
            .varint(RadioProto.Device.role, RadioProto.DeviceRole.sensor)
            .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.coreOnly)
        settings.apply(.config(variant: RadioProto.Config.device, body: device.data))
        XCTAssertEqual(settings.deviceRole, 6)
        XCTAssertNil(MeshtasticAdminCodec.DeviceRole(rawValue: 6))
        XCTAssertEqual(settings.rebroadcastMode, 5)
        XCTAssertNil(MeshtasticAdminCodec.RebroadcastMode(rawValue: 5))
    }

    // MARK: A radio at factory settings

    func testAFactoryRadioReadsAsClientAndAllAndItsOwnInterval() {
        // The device config has neither a role nor a rebroadcast mode, because
        // both are at their defaults. They are CLIENT and ALL, not unknown.
        var settings = Settings()
        settings.apply(.config(variant: RadioProto.Config.device, body: RadioFixtures.factoryDeviceConfig().data))
        settings.apply(.config(variant: RadioProto.Config.position, body: RadioFixtures.factoryPositionConfig(broadcastSecs: 900).data))

        XCTAssertTrue(settings.hasDeviceConfig, "the settings are loaded")
        XCTAssertEqual(settings.deviceRole, 0)
        XCTAssertEqual(settings.namedDeviceRole, .client)
        XCTAssertEqual(settings.rebroadcastMode, 0)
        XCTAssertEqual(settings.namedRebroadcastMode, .all)
        XCTAssertNil(settings.unlistedDeviceRole)
        XCTAssertNil(settings.unlistedRebroadcastMode)
        XCTAssertEqual(settings.positionBroadcastSeconds, 900)
    }

    func testAnEmptyDeviceConfigIsClientAndAllNotNotLoaded() {
        var settings = Settings()
        settings.apply(.config(variant: RadioProto.Config.device, body: Data()))
        XCTAssertTrue(settings.hasDeviceConfig)
        XCTAssertEqual(settings.namedDeviceRole, .client)
        XCTAssertEqual(settings.namedRebroadcastMode, .all)
    }

    func testAPositionConfigWithoutAnIntervalReadsAsZero() {
        var settings = Settings()
        XCTAssertNil(settings.positionBroadcastSeconds, "not loaded")
        settings.apply(.config(variant: RadioProto.Config.position, body: ProtoFixture().varint(RadioProto.Position.gpsMode, 1).data))
        XCTAssertTrue(settings.hasPositionConfig)
        XCTAssertEqual(settings.positionBroadcastSeconds, 0, "the radio's own default")
    }

    func testNothingIsNamedUntilTheDeviceConfigArrives() {
        let settings = Settings()
        XCTAssertNil(settings.deviceRole)
        XCTAssertNil(settings.namedDeviceRole)
        XCTAssertNil(settings.unlistedDeviceRole, "not loaded is not an unlisted role")
        XCTAssertNil(settings.namedRebroadcastMode)
        XCTAssertNil(settings.unlistedRebroadcastMode)
    }

    func testARoleWithNoNameIsUnlistedAndNeverBecomesANamedRole() {
        var settings = Settings()
        let device = ProtoFixture()
            .varint(RadioProto.Device.role, 12)    // CLIENT_BASE, which the app has no entry for
            .varint(RadioProto.Device.rebroadcastMode, RadioProto.Rebroadcast.coreOnly)
        settings.apply(.config(variant: RadioProto.Config.device, body: device.data))

        XCTAssertNil(settings.namedDeviceRole, "no named role stands in for it")
        XCTAssertEqual(settings.unlistedDeviceRole, 12)
        XCTAssertNil(settings.namedRebroadcastMode)
        XCTAssertEqual(settings.unlistedRebroadcastMode, 5)
    }

    func testANamedRoleIsNotUnlisted() {
        var settings = Settings()
        settings.apply(.config(variant: RadioProto.Config.device, body: ProtoFixture().varint(RadioProto.Device.role, RadioProto.DeviceRole.tak).data))
        XCTAssertEqual(settings.namedDeviceRole, .tak)
        XCTAssertNil(settings.unlistedDeviceRole)
    }

    // MARK: The result of a write

    func testTheNotLoadedMessageIsTheOneTheOperatorSees() {
        XCTAssertEqual(MeshtasticWriteResult.notLoaded,
                       "Radio settings are not loaded yet. Reconnect and try again.")
    }

    func testAWriteResultSaysWhetherItWasSentAndWhyNot() {
        XCTAssertTrue(MeshtasticWriteResult.sent.isSent)
        XCTAssertNil(MeshtasticWriteResult.sent.refusal)
        XCTAssertFalse(MeshtasticWriteResult.refused("why").isSent)
        XCTAssertEqual(MeshtasticWriteResult.refused("why").refusal, "why")
    }
}
