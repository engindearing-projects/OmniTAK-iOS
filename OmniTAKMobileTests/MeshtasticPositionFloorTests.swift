//
//  MeshtasticPositionFloorTests.swift
//  OmniTAKMobileTests
//
//  #153: on its default channel a radio puts a short position interval back to
//  one hour (twelve for a router) when it restarts, and the app used to say
//  nothing before the push and nothing about why after it. The rule is the
//  firmware's (NodeDB.cpp "Enforce position broadcast minimums", Channels.cpp
//  isDefaultChannel and getName, Default.h, Default.cpp and DisplayFormatters.cpp
//  of firmware 2.7.26). The expected answers here come from that source and from
//  the Android tests of the same rule, not from the code under test.
//
//  Every case is read from messages as a radio reports them, through
//  MeshtasticRadioSettings, which is where the app reads them from. The field
//  numbers are written out from the .proto files (RadioProto), not taken from
//  the app's constants. All keys and names are made up.
//
//   - The floor and its words.
//   - What is read from a channel, the LoRa config and the device config.
//   - Whether the position channel is the default channel (a truth table).
//   - The hint under the interval control, before a push.
//   - The reason added to the report of a write, after the restart.
//   - The same through the manager, with the config download in the order a
//     radio sends it: the LoRa config comes after the position config.
//

import XCTest
@testable import OmniTAK

// MARK: - Fixtures

/// Messages as a radio reports them: channels, a LoRa config and a device role,
/// and the settings the app holds after a download of them.
private enum PositionFixtures {

    /// The key of a stock radio's primary channel: one byte, the value 1.
    static let defaultKey = Data([1])

    /// A private 32 byte key, made up.
    static func privateKey(_ seed: UInt8 = 9) -> Data {
        Data((0..<32).map { UInt8($0) &+ seed })
    }

    /// A channel slot as a radio reports it. A nil `key` has no key field; a nil
    /// `precision` has no module settings.
    static func channelMessage(
        _ index: Int = 0,
        key: Data? = defaultKey,
        name: String = "",
        precision: UInt64? = 13,
        role: UInt64 = RadioProto.ChannelRole.primary
    ) -> ProtoFixture {
        var settings = ProtoFixture()
        if let key { settings = settings.bytes(RadioProto.ChannelSettings.psk, key) }
        if !name.isEmpty { settings = settings.string(RadioProto.ChannelSettings.name, name) }
        if let precision {
            settings = settings.message(
                RadioProto.ChannelSettings.moduleSettings,
                ProtoFixture().varint(RadioProto.ModuleSettings.positionPrecision, precision))
        }
        // Slot 0 is index 0, a default, so a radio leaves the field out.
        let head = index == 0 ? ProtoFixture() : ProtoFixture().varint(RadioProto.Channel.index, UInt64(index))
        return head
            .message(RadioProto.Channel.settings, settings)
            .varint(RadioProto.Channel.role, role)
    }

    /// A slot the radio has disabled: the index and nothing else.
    static func disabled(_ index: Int) -> ProtoFixture {
        RadioFixtures.disabledChannel(index: index)
    }

    /// A LoRa config. A nil `usePreset` or `preset` is not on the wire, as the
    /// proto3 default is not; `false` and 0 are written out, which means the same.
    static func loraConfig(usePreset: Bool? = true, preset: UInt64? = nil) -> ProtoFixture {
        var lora = ProtoFixture()
        if let usePreset { lora = lora.bool(RadioProto.LoRa.usePreset, usePreset) }
        if let preset { lora = lora.varint(RadioProto.LoRa.modemPreset, preset) }
        return lora.varint(RadioProto.LoRa.region, 1)
    }

    /// A device config with this role. A radio leaves the default (CLIENT) out.
    static func deviceConfig(role: UInt64) -> ProtoFixture {
        role == 0 ? ProtoFixture() : ProtoFixture().varint(RadioProto.Device.role, role)
    }

    /// A radio's eight slots: the ones in `channels`, and the rest disabled unless
    /// `fillRest` is false (a slot the radio has not reported).
    static func slots(_ channels: [Int: ProtoFixture], fillRest: Bool = true) -> [Int: ProtoFixture] {
        var out: [Int: ProtoFixture] = [:]
        for index in 0...7 {
            if let channel = channels[index] { out[index] = channel } else if fillRest { out[index] = disabled(index) }
        }
        return out
    }

    /// What the app holds after a download of these parts, in the order a radio
    /// sends them: the channels, the device config, the position config, the LoRa
    /// config. A nil part was not sent.
    static func settings(
        channels: [Int: ProtoFixture] = [0: channelMessage()],
        lora: ProtoFixture? = loraConfig(),
        role: UInt64? = 0,
        interval: UInt64? = 3600,
        fillRest: Bool = true
    ) -> MeshtasticRadioSettings {
        var settings = MeshtasticRadioSettings()
        settings.apply(.downloadStarted(nodeNum: 0x0A0B_0C0D))
        let all = slots(channels, fillRest: fillRest)
        for index in all.keys.sorted() { settings.apply(.channel(index: index, body: all[index]!.data)) }
        if let role { settings.apply(.config(variant: RadioProto.Config.device, body: deviceConfig(role: role).data)) }
        if let interval {
            settings.apply(.config(variant: RadioProto.Config.position,
                                   body: RadioFixtures.positionConfig(broadcastSecs: interval).data))
        }
        if let lora { settings.apply(.config(variant: RadioProto.Config.lora, body: lora.data)) }
        return settings
    }

    static func facts(
        channels: [Int: ProtoFixture] = [0: channelMessage()],
        lora: ProtoFixture? = loraConfig(),
        role: UInt64? = 0,
        fillRest: Bool = true
    ) -> MeshtasticPositionFacts {
        MeshtasticPositionFacts(settings(channels: channels, lora: lora, role: role, fillRest: fillRest))
    }

    /// The words next to the interval control, for the client floor and the router floor.
    static let clientReason = "This radio sends positions on its public default channel. "
        + "Meshtastic firmware 2.7.26 raises a position interval under one hour to one hour when the radio restarts. "
        + "A private channel is needed for faster position updates."
    static let routerReason = "This radio sends positions on its public default channel. "
        + "Meshtastic firmware 2.7.26 raises a position interval under twelve hours to twelve hours when the radio restarts. "
        + "A private channel is needed for faster position updates."
}

// MARK: - The rule

final class MeshtasticPositionFloorTests: XCTestCase {

    private typealias Fix = PositionFixtures

    private func onDefault(
        channels: [Int: ProtoFixture] = [0: Fix.channelMessage()],
        lora: ProtoFixture? = Fix.loraConfig()
    ) -> Bool? {
        Fix.facts(channels: channels, lora: lora).onDefaultChannel()
    }

    // MARK: The floor and its words

    func testTheFloorIsOneHourAndTwelveHoursForTheRouterRolesOnly() {
        // Role numbers from config.proto. IF_ROUTER in Default.h looks at ROUTER
        // and ROUTER_LATE and at nothing else.
        let floors: [(role: UInt64, name: String, floor: UInt32)] = [
            (0, "CLIENT", 3_600), (1, "CLIENT_MUTE", 3_600), (2, "ROUTER", 43_200),
            (3, "ROUTER_CLIENT", 3_600), (4, "REPEATER", 3_600), (5, "TRACKER", 3_600),
            (6, "SENSOR", 3_600), (7, "TAK", 3_600), (8, "CLIENT_HIDDEN", 3_600),
            (9, "LOST_AND_FOUND", 3_600), (10, "TAK_TRACKER", 3_600), (11, "ROUTER_LATE", 43_200),
            (12, "CLIENT_BASE", 3_600), (99, "a role this app has no name for", 3_600),
        ]
        for entry in floors {
            XCTAssertEqual(MeshtasticPositionFloor.floorSeconds(role: entry.role), entry.floor, entry.name)
        }
        XCTAssertEqual(MeshtasticPositionFloor.defaultFloorSeconds, 3_600)
        XCTAssertEqual(MeshtasticPositionFloor.routerFloorSeconds, 43_200)
    }

    func testTheReasonNamesTheFloorInWordsForBothFloors() {
        XCTAssertEqual(MeshtasticPositionFloor.reason(floorSeconds: 3_600), Fix.clientReason)
        XCTAssertEqual(MeshtasticPositionFloor.reason(floorSeconds: 43_200), Fix.routerReason)
        let router = MeshtasticPositionFloor.reason(floorSeconds: MeshtasticPositionFloor.routerFloorSeconds)
        XCTAssertTrue(router.contains("under twelve hours to twelve hours when the radio restarts"), router)
        XCTAssertFalse(router.contains("one hour"), router)
        XCTAssertFalse(Fix.clientReason.contains("twelve"), Fix.clientReason)
    }

    func testTheReasonIsOneParagraphOfThreeSentencesWithoutDashes() {
        for floor in [UInt32(3_600), 43_200] {
            let reason = MeshtasticPositionFloor.reason(floorSeconds: floor)
            XCTAssertEqual(reason.components(separatedBy: ". ").count, 3, reason)
            XCTAssertTrue(reason.hasSuffix("."), reason)
            XCTAssertFalse(reason.contains("\u{2014}") || reason.contains("\u{2013}"), reason)
        }
    }

    func testEveryPresetHasTheDisplayNameTheFirmwareGivesIt() {
        // getModemPresetDisplayName(preset, false, true). VERY_LONG_SLOW (2) and the
        // numbers after LONG_TURBO have no case there: "Invalid".
        let names: [UInt64: String] = [
            0: "LongFast", 1: "LongSlow", 3: "MediumSlow", 4: "MediumFast", 5: "ShortSlow",
            6: "ShortFast", 7: "LongMod", 8: "ShortTurbo", 9: "LongTurbo",
        ]
        for (preset, name) in names {
            XCTAssertEqual(MeshtasticPositionFloor.presetDisplayName(modemPreset: preset, usePreset: true), name, "preset \(preset)")
        }
        for preset: UInt64 in [2, 10, 11, 12, 13, 99, UInt64.max] {
            XCTAssertEqual(MeshtasticPositionFloor.presetDisplayName(modemPreset: preset, usePreset: true), "Invalid", "preset \(preset)")
        }
    }

    func testWithoutUsePresetEveryPresetIsCalledCustom() {
        for preset: UInt64 in [0, 1, 2, 4, 9, 99] {
            XCTAssertEqual(MeshtasticPositionFloor.presetDisplayName(modemPreset: preset, usePreset: false), "Custom", "preset \(preset)")
        }
    }

    // MARK: What is read from the messages

    func testTheDefaultKeyIsExactlyOneByteWithTheValueOne() {
        let facts = Fix.facts(channels: [0: Fix.channelMessage(key: Data([1]))])
        XCTAssertEqual(facts.channels[0], .init(defaultKey: true, name: "", positionPrecision: 13))
    }

    func testNoOtherKeyIsTheDefaultKey() {
        let keys: [(String, Data?)] = [
            ("32 bytes", Fix.privateKey()), ("one byte, 2", Data([2])), ("one byte, 0", Data([0])),
            ("one byte, 255", Data([255])), ("no key", nil), ("two bytes starting with 1", Data([1, 1])),
            ("two bytes ending with 1", Data([0, 1])), ("16 bytes of 1", Data(repeating: 1, count: 16)),
        ]
        for (label, key) in keys {
            let facts = Fix.facts(channels: [0: Fix.channelMessage(key: key)])
            XCTAssertEqual(facts.channels[0]?.defaultKey, false, label)
        }
        // An empty key field is the same as none (proto3 leaves a default out, and a zero length bytes field reads as empty).
        let empty = Fix.facts(channels: [0: Fix.channelMessage(key: Data())])
        XCTAssertEqual(empty.channels[0]?.defaultKey, false, "an empty key")
    }

    func testTheNameIsReadFromTheSettings() {
        XCTAssertEqual(Fix.facts(channels: [0: Fix.channelMessage()]).channels[0]?.name, "", "no name field")
        XCTAssertEqual(Fix.facts(channels: [0: Fix.channelMessage(name: "LongFast")]).channels[0]?.name, "LongFast")
        XCTAssertEqual(Fix.facts(channels: [0: Fix.channelMessage(name: "Alpha")]).channels[0]?.name, "Alpha")
        XCTAssertEqual(Fix.facts(channels: [0: Fix.channelMessage(name: "caf\u{e9}")]).channels[0]?.name, "caf\u{e9}")
    }

    func testThePositionPrecisionIsReadFromTheModuleSettings() {
        func precision(_ value: UInt64?) -> UInt64? {
            Fix.facts(channels: [0: Fix.channelMessage(precision: value)]).channels[0]?.positionPrecision
        }
        XCTAssertEqual(precision(13), 13)
        XCTAssertEqual(precision(32), 32)
        XCTAssertEqual(precision(1), 1)
        XCTAssertEqual(precision(0), 0, "written out as 0")
        XCTAssertEqual(precision(nil), 0, "no module settings")
    }

    func testModuleSettingsWithoutAPrecisionHaveNone() {
        // A radio leaves a 0 out: module settings that only say the channel is muted.
        let settings = ProtoFixture()
            .bytes(RadioProto.ChannelSettings.psk, Fix.defaultKey)
            .message(RadioProto.ChannelSettings.moduleSettings, ProtoFixture().bool(RadioProto.ModuleSettings.isMuted, true))
        let channel = ProtoFixture()
            .message(RadioProto.Channel.settings, settings)
            .varint(RadioProto.Channel.role, RadioProto.ChannelRole.primary)
        let facts = Fix.facts(channels: [0: channel])
        XCTAssertEqual(facts.channels[0]?.positionPrecision, 0)
        XCTAssertEqual(facts.onDefaultChannel(), false, "a channel with no precision sends no positions")
    }

    func testTheLastValueOfAFieldWrittenTwiceIsTheOneRead() {
        let settings = ProtoFixture()
            .bytes(RadioProto.ChannelSettings.psk, Fix.privateKey())
            .bytes(RadioProto.ChannelSettings.psk, Fix.defaultKey)
            .string(RadioProto.ChannelSettings.name, "Alpha")
            .string(RadioProto.ChannelSettings.name, "LongFast")
            .message(RadioProto.ChannelSettings.moduleSettings, ProtoFixture().varint(RadioProto.ModuleSettings.positionPrecision, 0))
        let channel = ProtoFixture().message(RadioProto.Channel.settings, settings)
        XCTAssertEqual(MeshtasticPositionFacts.channelFacts(in: channel.data),
                       .init(defaultKey: true, name: "LongFast", positionPrecision: 0))
    }

    func testAChannelSlotThatCannotBeReadHasNoFacts() {
        // A length that runs past the end.
        XCTAssertNil(MeshtasticPositionFacts.channelFacts(in: Data([0x12, 0x7F])))
        // Settings that are a number, not a message.
        XCTAssertNil(MeshtasticPositionFacts.channelFacts(
            in: ProtoFixture().varint(RadioProto.Channel.settings, 5).data))
        // Module settings that are a number.
        let numberedModule = ProtoFixture().varint(RadioProto.ChannelSettings.moduleSettings, 5)
        XCTAssertNil(MeshtasticPositionFacts.channelFacts(
            in: ProtoFixture().message(RadioProto.Channel.settings, numberedModule).data))
        // Module settings that are cut short inside.
        let cutModule = ProtoFixture().bytes(RadioProto.ChannelSettings.moduleSettings, Data([0x08]))
        XCTAssertNil(MeshtasticPositionFacts.channelFacts(
            in: ProtoFixture().message(RadioProto.Channel.settings, cutModule).data))
        // And an empty message is a real, readable slot with nothing in it.
        XCTAssertEqual(MeshtasticPositionFacts.channelFacts(in: Data()),
                       .init(defaultKey: false, name: "", positionPrecision: 0))
    }

    func testASlotTheRadioHasNotReportedHasNoFacts() {
        let facts = Fix.facts(channels: [0: Fix.channelMessage(), 3: Fix.channelMessage(3, key: Fix.privateKey())], fillRest: false)
        XCTAssertEqual(facts.channels.count, 8)
        XCTAssertNotNil(facts.channels[0])
        XCTAssertNotNil(facts.channels[3])
        for index in [1, 2, 4, 5, 6, 7] { XCTAssertNil(facts.channels[index], "slot \(index)") }
    }

    func testTheLoraFactsAreUsePresetAndTheModemPreset() {
        func lora(usePreset: Bool?, preset: UInt64?) -> MeshtasticPositionFacts.LoraFacts? {
            Fix.facts(lora: Fix.loraConfig(usePreset: usePreset, preset: preset)).lora
        }
        XCTAssertEqual(lora(usePreset: true, preset: nil), .init(usePreset: true, modemPreset: 0), "no preset on the wire is LONG_FAST")
        XCTAssertEqual(lora(usePreset: false, preset: nil), .init(usePreset: false, modemPreset: 0), "use_preset written as false")
        XCTAssertEqual(lora(usePreset: nil, preset: nil), .init(usePreset: false, modemPreset: 0), "use_preset left out")
        for preset in UInt64(0)...13 {
            XCTAssertEqual(lora(usePreset: true, preset: preset), .init(usePreset: true, modemPreset: preset), "preset \(preset)")
            XCTAssertEqual(lora(usePreset: false, preset: preset), .init(usePreset: false, modemPreset: preset), "preset \(preset), use_preset off")
        }
    }

    func testALoraConfigThatCannotBeReadHasNoFacts() {
        XCTAssertNil(MeshtasticPositionFacts.loraFacts(in: Data([0x10])))
        XCTAssertEqual(MeshtasticPositionFacts.loraFacts(in: Data()), .init(usePreset: false, modemPreset: 0),
                       "an empty LoRa config is every field at its default")
    }

    func testTheRoleIsReadFromTheDeviceConfig() {
        XCTAssertEqual(Fix.facts(role: 0).role, 0, "a radio leaves CLIENT out of its device config")
        XCTAssertEqual(Fix.facts(role: 2).role, 2)
        XCTAssertEqual(Fix.facts(role: 7).role, 7)
        XCTAssertEqual(Fix.facts(role: 11).role, 11)
        XCTAssertNil(Fix.facts(role: nil).role, "no device config yet")
    }

    func testNothingReportedYetSaysNothing() {
        let facts = MeshtasticPositionFacts(MeshtasticRadioSettings())
        XCTAssertNil(facts.onDefaultChannel())
        XCTAssertNil(facts.lora)
        XCTAssertNil(facts.role)
        XCTAssertEqual(facts.channels.count, 8)
        XCTAssertTrue(facts.channels.allSatisfy { $0 == nil })
    }

    func testTheFactsAreReadFromWhatTheRadioSaidAndNothingElse() {
        // Before a my_info says whose settings these are, nothing is kept, so there is nothing to read.
        var settings = MeshtasticRadioSettings()
        settings.apply(.channel(index: 0, body: Fix.channelMessage().data))
        settings.apply(.config(variant: RadioProto.Config.lora, body: Fix.loraConfig().data))
        XCTAssertNil(MeshtasticPositionFacts(settings).onDefaultChannel())
        // A write drops what the radio said about the sub-config until it says it again.
        var written = Fix.settings()
        XCTAssertEqual(MeshtasticPositionFacts(written).onDefaultChannel(), true)
        written.invalidateChannel(index: 0)
        XCTAssertNil(MeshtasticPositionFacts(written).onDefaultChannel(), "slot 0 was written and has not been read back")
        written.storeChannel(index: 0, body: Fix.channelMessage(key: Fix.privateKey()).data)
        XCTAssertEqual(MeshtasticPositionFacts(written).onDefaultChannel(), false, "the read-back says what it holds now")
    }

    // MARK: Whether the position channel is the default channel

    func testTheStockPrimaryChannelIsTheDefaultChannel() {
        XCTAssertEqual(onDefault(), true, "one byte key 1, no name, precision 13, LONG_FAST")
    }

    func testAPrivateKeyIsNotTheDefaultChannel() {
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(key: Fix.privateKey(5))]), false)
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(key: Data([2]))]), false)
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(key: Data([0]))]), false)
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(key: nil)]), false)
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(key: Data([1, 1]))]), false,
                       "a two byte key starting with 1 is not it either")
    }

    func testARenamedChannelWithTheDefaultKeyIsNotTheDefaultChannel() {
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "Alpha")]), false)
    }

    func testThePresetsOwnNameWrittenOutIsTheDefaultChannel() {
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "LongFast")]), true)
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "MediumFast")], lora: Fix.loraConfig(preset: 4)), true)
    }

    func testAnEmptyNameStandsForThePresetsNameWhateverThePreset() {
        for preset in UInt64(0)...13 {
            XCTAssertEqual(onDefault(lora: Fix.loraConfig(preset: preset)), true, "preset \(preset)")
        }
    }

    func testTheNameIsComparedWithTheRadiosOwnPreset() {
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "LongFast")], lora: Fix.loraConfig(preset: 4)), false,
                       "a MediumFast radio with a channel named LongFast")
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "MediumFast")]), false,
                       "a LongFast radio with a channel named MediumFast")
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage()], lora: Fix.loraConfig(preset: 4)), true,
                       "a MediumFast radio with no name")
    }

    func testTheNameIsCaseSensitive() {
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "longfast")]), false)
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "LONGFAST")]), false)
    }

    func testEveryPresetsDisplayNameIsTheDefaultChannelsNameAndNoOtherPresetsIs() {
        let names: [UInt64: String] = [
            0: "LongFast", 1: "LongSlow", 3: "MediumSlow", 4: "MediumFast", 5: "ShortSlow",
            6: "ShortFast", 7: "LongMod", 8: "ShortTurbo", 9: "LongTurbo",
        ]
        for (preset, name) in names {
            XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: name)], lora: Fix.loraConfig(preset: preset)),
                           true, "preset \(preset), name \(name)")
            XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "LongFast")], lora: Fix.loraConfig(preset: preset)),
                           preset == 0, "preset \(preset), name LongFast")
        }
        for preset: UInt64 in [2, 10, 11, 12, 13, 99] {
            XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "Invalid")], lora: Fix.loraConfig(preset: preset)),
                           true, "preset \(preset), name Invalid")
            XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "LongFast")], lora: Fix.loraConfig(preset: preset)),
                           false, "preset \(preset), name LongFast")
        }
    }

    func testWithoutUsePresetTheNameThatStandsForThePresetIsCustom() {
        for usePreset in [false, nil] as [Bool?] {
            let lora = Fix.loraConfig(usePreset: usePreset, preset: 4)
            XCTAssertEqual(onDefault(lora: lora), true, "use_preset \(String(describing: usePreset)), empty name")
            XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "Custom")], lora: lora), true, "name Custom")
            XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "MediumFast")], lora: lora), false, "the preset's name is not it")
        }
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(name: "Custom")]), false, "with a preset, Custom is not the name")
    }

    func testWithNoPositionPrecisionOnAnyChannelNothingIsSentAndNothingIsRaised() {
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(precision: 0)]), false, "module settings with a precision of 0")
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(precision: nil)]), false, "no module settings")
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(precision: 0), 1: Fix.channelMessage(1, precision: 0)]), false,
                       "a default channel in slot 1 with no precision either")
        XCTAssertEqual(onDefault(channels: [:]), false, "eight disabled slots")
    }

    func testTheFirstChannelWithAPrecisionDecidesAndLaterOnesDoNot() {
        let privateKey = Fix.privateKey()
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(key: privateKey), 1: Fix.channelMessage(1)]), false,
                       "private first, default second")
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(), 1: Fix.channelMessage(1, key: privateKey)]), true,
                       "default first, private second")
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(key: privateKey, precision: 0), 1: Fix.channelMessage(1)]), true,
                       "slot 0 sends no positions, slot 1 is the default channel")
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(precision: 0), 1: Fix.channelMessage(1, key: privateKey)]), false,
                       "slot 0 sends no positions, slot 1 is private")
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(precision: 0), 7: Fix.channelMessage(7)]), true,
                       "only slot 7 sends positions")
    }

    func testAChannelsRoleIsNotLookedAtAsInTheFirmware() {
        // The loop in NodeDB.cpp reads the settings of every slot, a disabled one included.
        XCTAssertEqual(onDefault(channels: [0: Fix.channelMessage(precision: 0),
                                            3: Fix.channelMessage(3, role: RadioProto.ChannelRole.disabled)]), true)
    }

    func testNothingIsDecidedWithoutTheLoraConfig() {
        XCTAssertNil(onDefault(lora: nil))
    }

    func testNothingIsDecidedWhileAChannelTheSearchHasToLookAtIsMissing() {
        XCTAssertNil(Fix.facts(channels: [:], fillRest: false).onDefaultChannel(), "no channel at all")
        XCTAssertNil(Fix.facts(channels: [1: Fix.channelMessage(1)], fillRest: false).onDefaultChannel(), "slot 0 is the first to look at")
        XCTAssertNil(Fix.facts(channels: [0: Fix.channelMessage(precision: 0)], fillRest: false).onDefaultChannel(),
                     "slot 0 sends no positions, so slot 1 matters")
        let sixDisabled = Dictionary(uniqueKeysWithValues: (0...6).map { ($0, Fix.disabled($0)) })
        XCTAssertNil(Fix.facts(channels: sixDisabled, fillRest: false).onDefaultChannel(),
                     "no channel sends positions, but slot 7 is not loaded")
        XCTAssertNil(Fix.facts(channels: [0: ProtoFixture().raw([0x12, 0x7F])]).onDefaultChannel(),
                     "slot 0 is there and cannot be read")
    }

    func testASlotAfterThePositionChannelDoesNotNeedToBeLoaded() {
        XCTAssertEqual(Fix.facts(channels: [0: Fix.channelMessage()], fillRest: false).onDefaultChannel(), true)
    }

    func testTheFactsCanBeBuiltByHandForARadioWithShortLists() {
        let stock = MeshtasticPositionFacts.ChannelFacts(defaultKey: true, name: "", positionPrecision: 13)
        let lora = MeshtasticPositionFacts.LoraFacts(usePreset: true, modemPreset: 0)
        XCTAssertEqual(MeshtasticPositionFacts(channels: [stock], lora: lora, role: 0).onDefaultChannel(), true)
        XCTAssertNil(MeshtasticPositionFacts(channels: [], lora: lora, role: 0).onDefaultChannel(), "a list shorter than the slot to look at")
    }

    // MARK: Before the push: the line under the interval control

    private func hint(_ shown: UInt32?, facts: MeshtasticPositionFacts = Fix.facts()) -> String? {
        facts.intervalHint(shownSeconds: shown)
    }

    func testTheHintIsShownOnlyForAnIntervalAboveZeroAndUnderTheFloorOnTheDefaultChannel() {
        XCTAssertNil(hint(0), "0 is how the radio says use my default, and the firmware leaves it alone")
        XCTAssertEqual(hint(1), Fix.clientReason)
        XCTAssertEqual(hint(30), Fix.clientReason)
        XCTAssertEqual(hint(120), Fix.clientReason)
        XCTAssertEqual(hint(3_599), Fix.clientReason)
        XCTAssertNil(hint(3_600), "the floor itself is not under it")
        XCTAssertNil(hint(3_601))
        XCTAssertNil(hint(43_200))
        XCTAssertNil(hint(nil), "the position config is not loaded")
    }

    func testARouterGetsTheTwelveHourFloorInTheNumbersAndInTheWords() {
        for role: UInt64 in [2, 11] {
            let router = Fix.facts(role: role)
            XCTAssertEqual(hint(120, facts: router), Fix.routerReason, "role \(role)")
            XCTAssertEqual(hint(3_600, facts: router), Fix.routerReason, "role \(role): one hour is under twelve")
            XCTAssertEqual(hint(43_199, facts: router), Fix.routerReason, "role \(role)")
            XCTAssertNil(hint(43_200, facts: router), "role \(role): twelve hours is the floor")
            XCTAssertNil(hint(0, facts: router), "role \(role)")
        }
        for role: UInt64 in [3, 4, 5, 7, 10, 12] {
            XCTAssertNil(hint(3_600, facts: Fix.facts(role: role)), "role \(role) has the one hour floor")
            XCTAssertEqual(hint(120, facts: Fix.facts(role: role)), Fix.clientReason, "role \(role)")
        }
    }

    func testThereIsNoHintOffTheDefaultChannel() {
        XCTAssertNil(hint(120, facts: Fix.facts(channels: [0: Fix.channelMessage(key: Fix.privateKey())])), "a private key")
        XCTAssertNil(hint(120, facts: Fix.facts(channels: [0: Fix.channelMessage(name: "Alpha")])), "a renamed channel")
        XCTAssertNil(hint(120, facts: Fix.facts(channels: [0: Fix.channelMessage(precision: 0)])), "no channel sends positions")
        XCTAssertNil(hint(120, facts: Fix.facts(channels: [0: Fix.channelMessage(precision: 0), 1: Fix.channelMessage(1, key: Fix.privateKey())])),
                     "the position channel is a private one in slot 1")
        XCTAssertEqual(hint(120, facts: Fix.facts(channels: [0: Fix.channelMessage(precision: 0), 1: Fix.channelMessage(1)])),
                       Fix.clientReason, "the position channel is the default one in slot 1")
    }

    func testThereIsNoHintWhileAnythingTheRuleNeedsIsNotLoaded() {
        XCTAssertNil(hint(120, facts: Fix.facts(lora: nil)), "no LoRa config")
        XCTAssertNil(hint(120, facts: Fix.facts(role: nil)), "no device config, so no floor")
        XCTAssertNil(hint(120, facts: Fix.facts(channels: [:], fillRest: false)), "no channels")
        XCTAssertNil(hint(120, facts: MeshtasticPositionFacts(MeshtasticRadioSettings())), "nothing at all")
    }

    func testTheHintIsTheReasonForTheFloorThatAppliesAndNothingElse() {
        XCTAssertEqual(hint(120), MeshtasticPositionFloor.reason(floorSeconds: MeshtasticPositionFloor.defaultFloorSeconds))
        XCTAssertEqual(hint(120, facts: Fix.facts(role: 2)),
                       MeshtasticPositionFloor.reason(floorSeconds: MeshtasticPositionFloor.routerFloorSeconds))
    }

    // MARK: After the restart: the reason on the report

    private func reason(sent: UInt64, reported: UInt64, facts: MeshtasticPositionFacts = Fix.facts()) -> String? {
        facts.intervalReason(sent: sent, reported: reported)
    }

    func testAnIntervalRaisedToTheFloorOnTheDefaultChannelHasTheReason() {
        XCTAssertEqual(reason(sent: 120, reported: 3_600), Fix.clientReason)
        XCTAssertEqual(reason(sent: 1, reported: 3_600), Fix.clientReason)
        XCTAssertEqual(reason(sent: 3_599, reported: 3_600), Fix.clientReason)
    }

    func testAnIntervalTheRadioKeptHasNoReason() {
        XCTAssertNil(reason(sent: 120, reported: 120), "reported 120, sent 120")
        XCTAssertNil(reason(sent: 900, reported: 900))
    }

    func testAnIntervalRaisedOnAPrivateChannelHasNoReason() {
        let privateChannel = Fix.facts(channels: [0: Fix.channelMessage(key: Fix.privateKey())])
        XCTAssertNil(reason(sent: 120, reported: 3_600, facts: privateChannel), "the floor did not do it")
        let renamed = Fix.facts(channels: [0: Fix.channelMessage(name: "Alpha")])
        XCTAssertNil(reason(sent: 120, reported: 3_600, facts: renamed))
        let silent = Fix.facts(channels: [0: Fix.channelMessage(precision: 0)])
        XCTAssertNil(reason(sent: 120, reported: 3_600, facts: silent))
    }

    func testTheReasonIsAddedOnlyWhenTheFloorExplainsTheValueTheRadioReports() {
        XCTAssertNil(reason(sent: 120, reported: 900), "not the floor: something else changed it")
        XCTAssertNil(reason(sent: 120, reported: 7_200), "not the floor either")
        XCTAssertNil(reason(sent: 0, reported: 3_600), "the firmware leaves 0 alone, so it is not what 0 turns into")
        XCTAssertNil(reason(sent: 7_200, reported: 3_600), "the interval that was sent was not under the floor")
        XCTAssertNil(reason(sent: 3_600, reported: 3_600), "nothing was raised")
        XCTAssertNil(reason(sent: 120, reported: 43_200), "the client floor is one hour, not twelve")
    }

    func testARoutersFloorIsTwelveHoursInTheNumbersAndInTheReason() {
        for role: UInt64 in [2, 11] {
            let router = Fix.facts(role: role)
            XCTAssertEqual(reason(sent: 3_600, reported: 43_200, facts: router), Fix.routerReason, "role \(role)")
            XCTAssertEqual(reason(sent: 120, reported: 43_200, facts: router), Fix.routerReason, "role \(role)")
            XCTAssertNil(reason(sent: 120, reported: 3_600, facts: router), "role \(role): a router's floor is not one hour")
            XCTAssertNil(reason(sent: 43_200, reported: 43_200, facts: router), "role \(role)")
        }
    }

    func testARouterThatKeepsOneHourBecauseItWasNotOnTheDefaultChannelIsNotBlamedOnTheFloor() {
        let router = Fix.facts(channels: [0: Fix.channelMessage(key: Fix.privateKey())], role: 2)
        XCTAssertNil(reason(sent: 3_600, reported: 43_200, facts: router))
    }

    func testNoReasonIsGivenWhileTheFactsAreNotAllIn() {
        for facts in [
            Fix.facts(role: nil), Fix.facts(lora: nil), Fix.facts(channels: [:], fillRest: false),
            MeshtasticPositionFacts(MeshtasticRadioSettings()),
        ] {
            XCTAssertNil(facts.floorExplains(sent: 120, reported: 3_600), "undecided is not the same as no")
            XCTAssertNil(facts.intervalReason(sent: 120, reported: 3_600))
        }
    }

    func testTheFloorExplainsReportsDecidedFalseAsAnAnswerAndNotAsMissing() {
        XCTAssertEqual(Fix.facts().floorExplains(sent: 120, reported: 3_600), true)
        XCTAssertEqual(Fix.facts().floorExplains(sent: 120, reported: 120), false)
        XCTAssertEqual(Fix.facts(channels: [0: Fix.channelMessage(key: Fix.privateKey())]).floorExplains(sent: 120, reported: 3_600), false)
    }

    // MARK: What the controls show, and the hint that goes with it

    private func hint(_ controls: MeshtasticSettingsControls, _ radio: MeshtasticRadioSettings) -> String? {
        MeshtasticPositionFacts(radio).intervalHint(shownSeconds: controls.shownSeconds(radio: radio))
    }

    func testTheShownIntervalIsTheRadiosOwnUntilTheSliderIsMoved() {
        let radio = Fix.settings(interval: 3_600)
        var controls = MeshtasticSettingsControls(radio: radio)
        XCTAssertEqual(controls.shownSeconds(radio: radio), 3_600)
        controls.sliderMoved(to: 120, radio: radio)
        XCTAssertEqual(controls.shownSeconds(radio: radio), 120)
        controls.sliderMoved(to: 3_600, radio: radio)
        XCTAssertEqual(controls.shownSeconds(radio: radio), 3_600, "the operator's choice, which happens to be the radio's value")
    }

    func testTheHintFollowsTheSliderOnTheDefaultChannel() {
        let radio = Fix.settings(interval: 3_600)
        var controls = MeshtasticSettingsControls(radio: radio)
        XCTAssertNil(hint(controls, radio), "the radio's own hour is not under the floor")
        controls.sliderMoved(to: 120, radio: radio)
        XCTAssertEqual(hint(controls, radio), Fix.clientReason)
        controls.sliderMoved(to: 30, radio: radio)
        XCTAssertEqual(hint(controls, radio), Fix.clientReason, "the shortest the slider reaches")
        controls.sliderMoved(to: 3_600, radio: radio)
        XCTAssertNil(hint(controls, radio), "the longest the slider reaches is the floor itself")
    }

    func testTheHintIsJudgedOnTheRadiosRealIntervalAndNotTheSlidersHeldCopyOfIt() {
        // A router at twelve hours is outside the slider (30 s to an hour), which shows it held at an hour.
        let router = Fix.settings(role: 2, interval: 43_200)
        var controls = MeshtasticSettingsControls(radio: router)
        XCTAssertEqual(controls.sliderValue(radio: router), 3_600)
        XCTAssertEqual(controls.shownSeconds(radio: router), 43_200)
        XCTAssertNil(hint(controls, router), "twelve hours is the router's floor, and nothing was moved")
        controls.sliderMoved(to: 3_000, radio: router)
        XCTAssertEqual(hint(controls, router), Fix.routerReason, "an hour is under a router's floor")
    }

    func testARadioAtItsDefaultIntervalGetsNoHintUntilTheSliderIsMovedUnderTheFloor() {
        let radio = Fix.settings(interval: 0)
        var controls = MeshtasticSettingsControls(radio: radio)
        XCTAssertEqual(controls.shownSeconds(radio: radio), 0, "the radio's default, which the firmware leaves alone")
        XCTAssertNil(hint(controls, radio))
        controls.sliderMoved(to: 300, radio: radio)
        XCTAssertEqual(hint(controls, radio), Fix.clientReason)
    }

    func testARadioThatSendsAShortIntervalOnTheDefaultChannelAlreadyGetsTheHint() {
        // For instance the window between a push and the restart, or a channel made the default after the radio started.
        let radio = Fix.settings(interval: 120)
        XCTAssertEqual(hint(MeshtasticSettingsControls(radio: radio), radio), Fix.clientReason)
    }

    func testThereIsNoShownIntervalAndNoHintUntilThePositionConfigIsLoaded() {
        let radio = Fix.settings(interval: nil)
        var controls = MeshtasticSettingsControls(radio: radio)
        XCTAssertNil(controls.shownSeconds(radio: radio))
        XCTAssertNil(hint(controls, radio))
        // The slider is disabled then, but a choice left from before must not make a hint out of nothing.
        controls.sliderMoved(to: 120, radio: radio)
        XCTAssertNil(controls.shownSeconds(radio: radio))
        XCTAssertNil(hint(controls, radio))
    }

    func testThereIsNoHintOnAPrivateChannelWhatEverTheSliderSays() {
        let radio = Fix.settings(channels: [0: Fix.channelMessage(key: Fix.privateKey())], interval: 900)
        var controls = MeshtasticSettingsControls(radio: radio)
        controls.sliderMoved(to: 120, radio: radio)
        XCTAssertEqual(controls.shownSeconds(radio: radio), 120)
        XCTAssertNil(hint(controls, radio))
    }

    func testThereIsNoHintBeforeTheLoraConfigIsIn() {
        let radio = Fix.settings(lora: nil, interval: 3_600)
        var controls = MeshtasticSettingsControls(radio: radio)
        controls.sliderMoved(to: 120, radio: radio)
        XCTAssertNil(hint(controls, radio))
    }
}

// MARK: - Through the manager

/// A radio that sends its configs in the order of a real download, and a report
/// of a position interval write that the radio put back.
@MainActor
final class MeshtasticPositionFloorReportTests: XCTestCase {

    private typealias Fix = PositionFixtures

    private let position = RadioProto.Config.position
    private let stockChannels = Fix.slots([0: Fix.channelMessage()])
    private let privateChannels = Fix.slots([0: Fix.channelMessage(key: Fix.privateKey())])

    /// What the operator reads for the position interval write.
    private func reportText(_ rig: WriteRig) -> String? {
        rig.manager.configReports.first(where: { $0.variant == RadioProto.Config.position })?.text
    }

    private func settled(_ rig: WriteRig) -> MeshtasticConfigReport? {
        rig.manager.configReports.first(where: { $0.variant == RadioProto.Config.position })
    }

    /// A radio that is on `channels` with the interval at the floor, a push of 120
    /// s it confirms before it restarts, and the restart that puts the floor back.
    private func writeIntervalAndRestart(
        _ rig: WriteRig, channels: [Int: ProtoFixture], role: UInt64 = 0, sent: UInt32 = 120, floor: UInt64 = 3_600
    ) async {
        rig.download(device: Fix.deviceConfig(role: role), position: RadioFixtures.positionConfig(broadcastSecs: floor),
                     channels: channels, lora: Fix.loraConfig())
        let result = await rig.manager.applyPositionBroadcastInterval(seconds: sent)
        XCTAssertEqual(result, .applied, "the radio reports what it received until it restarts")
        // The firmware raises the interval when it starts, and saves it.
        rig.radio.set(position: RadioFixtures.positionConfig(broadcastSecs: floor))
    }

    func testAnIntervalPutBackToTheFloorOnTheDefaultChannelIsReportedWithTheReason() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: stockChannels)

            rig.reconnect()

            XCTAssertEqual(settled(rig)?.state, .differsAfterRestart([.positionInterval: 3_600]))
            XCTAssertEqual(reportText(rig), "Position interval: the radio reports 3600 s after reconnecting. 120 s was sent. "
                           + Fix.clientReason)
            XCTAssertEqual(settled(rig)?.explanation, Fix.clientReason)
            XCTAssertTrue(rig.manager.configReportsAwaitingExplanation.isEmpty, "decided")
        }
    }

    func testARoutersIntervalPutBackToTwelveHoursIsReportedWithTheTwelveHourReason() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: stockChannels, role: RadioProto.DeviceRole.router, sent: 3_600, floor: 43_200)

            rig.reconnect()

            XCTAssertEqual(settled(rig)?.state, .differsAfterRestart([.positionInterval: 43_200]))
            XCTAssertEqual(reportText(rig), "Position interval: the radio reports 43200 s after reconnecting. 3600 s was sent. "
                           + Fix.routerReason)
        }
    }

    func testAnIntervalPutBackOnAPrivateChannelIsReportedWithoutTheReason() async {
        await withRig { rig in
            // Not what the firmware does on a private channel. It is what a radio that changed something else would show.
            await writeIntervalAndRestart(rig, channels: privateChannels)

            rig.reconnect()

            XCTAssertEqual(settled(rig)?.state, .differsAfterRestart([.positionInterval: 3_600]))
            XCTAssertEqual(reportText(rig), "Position interval: the radio reports 3600 s after reconnecting. 120 s was sent.")
            XCTAssertNil(settled(rig)?.explanation)
            XCTAssertTrue(rig.manager.configReportsAwaitingExplanation.isEmpty, "decided: no")
        }
    }

    func testAnIntervalTheRadioKeptIsReportedAppliedWithNothingAdded() async {
        await withRig { rig in
            rig.download(position: RadioFixtures.positionConfig(broadcastSecs: 3_600), channels: stockChannels, lora: Fix.loraConfig())
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 7_200)

            rig.reconnect()

            XCTAssertEqual(settled(rig)?.state, .appliedAfterRestart)
            XCTAssertEqual(reportText(rig), "Position interval: applied. The radio reports 7200 s after reconnecting.")
            XCTAssertTrue(rig.manager.configReportsAwaitingExplanation.isEmpty)
        }
    }

    func testTheReasonWaitsForTheLoraConfigWhichComesAfterThePositionConfigInTheDownload() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: stockChannels)
            let node = WriteRig.nodeNum

            // The download in the order a 2.7 radio sends it.
            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: node))
            for index in 0...7 { rig.manager.handleSettingsEvent(.channel(index: index, body: stockChannels[index]!.data)) }
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig().data))
            XCTAssertEqual(settled(rig)?.state, .confirmed, "not reported yet")

            rig.manager.handleSettingsEvent(.config(variant: position, body: RadioFixtures.positionConfig(broadcastSecs: 3_600).data))
            XCTAssertEqual(settled(rig)?.state, .differsAfterRestart([.positionInterval: 3_600]))
            XCTAssertEqual(reportText(rig), "Position interval: the radio reports 3600 s after reconnecting. 120 s was sent.",
                           "the LoRa config has not come, so nothing is said yet")
            XCTAssertEqual(rig.manager.configReportsAwaitingExplanation, [position])

            // Configs the app does not keep change nothing.
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.power, body: Data()))
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.display, body: Data()))
            XCTAssertNil(settled(rig)?.explanation)

            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.lora, body: Fix.loraConfig().data))
            XCTAssertEqual(reportText(rig), "Position interval: the radio reports 3600 s after reconnecting. 120 s was sent. "
                           + Fix.clientReason, "the LoRa config completes what the rule needs")
            XCTAssertTrue(rig.manager.configReportsAwaitingExplanation.isEmpty)
        }
    }

    func testTheReasonAlsoComesWhenTheChannelsArriveAfterTheConfigs() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: stockChannels)

            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: WriteRig.nodeNum))
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig().data))
            rig.manager.handleSettingsEvent(.config(variant: position, body: RadioFixtures.positionConfig(broadcastSecs: 3_600).data))
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.lora, body: Fix.loraConfig().data))
            XCTAssertNil(settled(rig)?.explanation, "no channel has been reported")
            // Slot 0 sends positions on the default channel, so slot 0 decides.
            rig.manager.handleSettingsEvent(.channel(index: 0, body: stockChannels[0]!.data))

            XCTAssertEqual(settled(rig)?.explanation, Fix.clientReason)
        }
    }

    func testAReportIsNotExplainedFromAnEarlierDownloadsChannels() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: stockChannels)

            // The new download starts: whatever the last one said is gone.
            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: WriteRig.nodeNum))
            XCTAssertTrue(rig.manager.radioSettings.channels.isEmpty)
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.device, body: RadioFixtures.deviceConfig().data))
            rig.manager.handleSettingsEvent(.config(variant: position, body: RadioFixtures.positionConfig(broadcastSecs: 3_600).data))
            rig.manager.handleSettingsEvent(.config(variant: RadioProto.Config.lora, body: Fix.loraConfig().data))

            XCTAssertNil(settled(rig)?.explanation, "the role and the LoRa config are in this download, the channels are not")
            XCTAssertEqual(rig.manager.configReportsAwaitingExplanation, [position], "still to be decided")
        }
    }

    func testWhatTheReasonWasDecidedFromIsNotChangedByWhatTheRadioReportsLater() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: stockChannels)
            rig.reconnect()
            let explained = reportText(rig)
            XCTAssertEqual(settled(rig)?.explanation, Fix.clientReason)

            // Someone gives the primary channel a private key. The restart that was reported is over.
            rig.manager.handleSettingsEvent(.channel(index: 0, body: privateChannels[0]!.data))

            XCTAssertEqual(reportText(rig), explained)
        }
    }

    func testWhatWasFoundNotToBeExplainedStaysSoWhenTheChannelBecomesTheDefault() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: privateChannels)
            rig.reconnect()
            XCTAssertNil(settled(rig)?.explanation)

            rig.manager.handleSettingsEvent(.channel(index: 0, body: stockChannels[0]!.data))

            XCTAssertNil(settled(rig)?.explanation, "decided against, and not looked at again")
        }
    }

    func testANewWriteReplacesTheReportAndItsReason() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: stockChannels)
            rig.reconnect()
            XCTAssertEqual(settled(rig)?.explanation, Fix.clientReason)

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 600)

            XCTAssertEqual(result, .applied)
            XCTAssertEqual(settled(rig)?.state, .confirmed)
            XCTAssertNil(settled(rig)?.explanation)
            XCTAssertFalse(reportText(rig)?.contains("default channel") ?? true, reportText(rig) ?? "")
        }
    }

    func testAReasonGoesWhenTheNextConnectDropsTheFinalReports() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: stockChannels)
            rig.reconnect()
            XCTAssertNotNil(settled(rig)?.explanation)

            rig.reconnect()      // the next connect: the radio has nothing outstanding

            XCTAssertTrue(rig.manager.configReports.isEmpty)
            XCTAssertTrue(rig.manager.configReportsAwaitingExplanation.isEmpty)
        }
    }

    func testAnUndecidedReportIsDroppedWithTheSettingsWhenTheLinkGoes() async {
        await withRig { rig in
            await writeIntervalAndRestart(rig, channels: stockChannels)
            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: WriteRig.nodeNum))
            rig.manager.handleSettingsEvent(.config(variant: position, body: RadioFixtures.positionConfig(broadcastSecs: 3_600).data))
            XCTAssertEqual(rig.manager.configReportsAwaitingExplanation, [position])

            rig.manager.handleLinkDown(.tcp)

            XCTAssertTrue(rig.manager.configReportsAwaitingExplanation.isEmpty)
            XCTAssertNil(settled(rig)?.explanation, "nothing is decided from settings that are gone")
            XCTAssertEqual(settled(rig)?.text, "Position interval: the radio reports 3600 s after reconnecting. 120 s was sent.")
        }
    }

    func testARoleReportIsNeverGivenThePositionReason() async {
        await withRig { rig in
            rig.download(position: RadioFixtures.positionConfig(broadcastSecs: 3_600), channels: stockChannels, lora: Fix.loraConfig())
            _ = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)
            // The radio starts as a client again.
            rig.radio.set(device: ProtoFixture())

            rig.reconnect()

            let report = rig.manager.configReports.first(where: { $0.variant == RadioProto.Config.device })
            XCTAssertEqual(report?.state, .differsAfterRestart([.role: 0]))
            XCTAssertNil(report?.explanation)
            XCTAssertTrue(rig.manager.configReportsAwaitingExplanation.isEmpty)
        }
    }

    func testTheRadiosLoraConfigIsHeldByTheManagerForTheRule() async {
        await withRig { rig in
            rig.download(channels: stockChannels, lora: Fix.loraConfig(preset: 4))

            XCTAssertEqual(MeshtasticPositionFacts(rig.manager.radioSettings).lora, .init(usePreset: true, modemPreset: 4))
            XCTAssertEqual(MeshtasticPositionFacts(rig.manager.radioSettings).onDefaultChannel(), true)
        }
    }

    // MARK: The text

    func testTheReportTextEndsWithTheReasonAsOneMoreSentence() {
        var report = MeshtasticConfigReport(
            variant: position, node: 1, what: "Position interval", sent: [.positionInterval: 120],
            state: .differsAfterRestart([.positionInterval: 3_600]))
        let plain = "Position interval: the radio reports 3600 s after reconnecting. 120 s was sent."
        XCTAssertEqual(report.text, plain)
        report.explanation = Fix.clientReason
        XCTAssertEqual(report.text, plain + " " + Fix.clientReason)
    }

    func testAReasonIsShownOnlyOnAReportThatSaysTheRadioPutTheValueBack() {
        let states: [MeshtasticConfigReport.State] = [
            .sent, .confirmed, .radioKept([.positionInterval: 3_600]), .noAnswer, .linkLost, .appliedAfterRestart,
        ]
        for state in states {
            var report = MeshtasticConfigReport(
                variant: position, node: 1, what: "Position interval", sent: [.positionInterval: 120], state: state)
            let without = report.text
            report.explanation = Fix.clientReason
            XCTAssertEqual(report.text, without, "\(state)")
        }
    }
}
