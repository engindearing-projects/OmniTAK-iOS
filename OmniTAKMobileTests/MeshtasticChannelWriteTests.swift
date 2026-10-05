//
//  MeshtasticChannelWriteTests.swift
//  OmniTAKMobileTests
//
//  #148 for channels: what the operator typed is never turned into something
//  else, a key is only removed when that is asked for and then means "open" the
//  way the radio understands it, a new channel goes into a slot the radio says is
//  free after the slot is read again, the primary is only replaced when the radio
//  says slot 0 is the primary, and a channel is only reported applied when the
//  radio's own answer says so, now or later.
//
//  A fake link in front of a simulated radio sees what is sent and answers the
//  way the firmware does. The last tests run the real TCP client and decoder
//  against a radio in the test process (LoopbackRadio). What meshtasticd does is
//  in MeshtasticSimulatedRadioTests.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

@MainActor
final class MeshtasticChannelWriteTests: XCTestCase {

    private typealias Codec = MeshtasticAdminCodec
    private typealias Kind = SimulatedRadioModel.Kind

    /// The Channel inside the set_channel of a write.
    private func channel(of write: FakeRadioLink.Sent,
                         file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        try XCTUnwrap(FixtureReader.setChannel(in: write.payload), "not a lone set_channel", file: file, line: line)
    }

    private func settings(of channel: Data,
                          file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        try XCTUnwrap(FixtureReader.bytes(RadioProto.Channel.settings, in: channel), "no settings", file: file, line: line)
    }

    /// Slots in use and slots the radio reports as disabled, as a download.
    private func slots(used: Set<Int>, primary: ProtoFixture? = nil) -> [Int: ProtoFixture] {
        var out: [Int: ProtoFixture] = [:]
        for index in 0...7 {
            out[index] = used.contains(index)
                ? RadioFixtures.channel(index: index, name: "used\(index)", psk: RadioFixtures.otherKey)
                : RadioFixtures.disabledChannel(index: index)
        }
        out[0] = primary ?? RadioFixtures.channel(index: 0, name: "simtest", role: RadioProto.ChannelRole.primary)
        return out
    }

    private func hex(_ data: Data) -> String { WriteRig.hex(data) }

    /// The indices of the set_channel writes, in order.
    private func writtenSlots(_ rig: WriteRig) -> [Int] {
        rig.link.sets.compactMap {
            guard case .setChannel(let index) = $0.kind else { return nil }
            return index
        }
    }

    private func create(
        _ rig: WriteRig, _ name: String, key: String? = nil, noEncryption: Bool = false, primary: Bool = false
    ) async -> MeshtasticManager.ChannelOutcome {
        await rig.manager.createChannel(
            name: name, keyText: key ?? hex(RadioFixtures.key), noEncryption: noEncryption, replacePrimary: primary)
    }

    // MARK: - Where a new channel goes

    func testACreatedChannelGoesIntoTheFirstSlotTheRadioReportsAsDisabled() async throws {
        try await withRig { rig in
            rig.download(channels: slots(used: [1, 2]))       // 0 primary, 1 and 2 in use, 3 to 7 free

            let outcome = await create(rig, "delta")

            XCTAssertEqual(outcome, MeshtasticManager.ChannelOutcome(result: .applied, slot: 3))
            let written = try channel(of: try XCTUnwrap(rig.link.sets.first))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.index, in: written), 3)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: written), RadioProto.ChannelRole.secondary)
            let inner = try settings(of: written)
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: inner), Data("delta".utf8))
            XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner) == RadioFixtures.key)
        }
    }

    func testACreatedChannelIsReadWrittenAndReadBack() async {
        await withRig { rig in
            rig.download()
            let outcome = await create(rig, "delta")
            XCTAssertEqual(outcome.slot, 2)
            XCTAssertEqual(rig.link.kinds, [.getChannel(index: 2), .setChannel(index: 2), .getChannel(index: 2)])
            XCTAssertTrue(rig.link.gets.allSatisfy { $0.wantResponse }, "the radio only answers a request that asks")
            XCTAssertTrue(rig.link.sets.allSatisfy { !$0.wantResponse })
            XCTAssertTrue(rig.link.sent.allSatisfy { $0.node == WriteRig.nodeNum && $0.connection == rig.link.connectionSerial })
        }
    }

    func testACreatedChannelNeverOverwritesASlotInUseOrThePrimary() async {
        await withRig { rig in
            rig.download(channels: slots(used: [1, 2, 3, 4, 5, 6]))   // only 7 is free

            let first = await create(rig, "one")
            XCTAssertEqual(first.slot, 7)

            // 7 is in use now, and nothing is free.
            let again = await create(rig, "two")
            XCTAssertNil(again.slot)
            XCTAssertEqual(again.result.refusal, "No free channel slot. All seven secondary slots on this radio are in use.")
            XCTAssertEqual(writtenSlots(rig), [7], "one write, to the one free slot, and none to slot 0 or a slot in use")
        }
    }

    func testACreatedChannelInheritsNothingFromTheSlotsOldOccupant() async throws {
        try await withRig { rig in
            // Slot 3 is disabled and still carries what its last channel left:
            // uplink, location precision, mute, an id.
            var all = slots(used: [])
            all[3] = ProtoFixture()
                .varint(RadioProto.Channel.index, 3)
                .message(RadioProto.Channel.settings, ProtoFixture()
                    .bytes(RadioProto.ChannelSettings.psk, RadioFixtures.otherKey)
                    .string(RadioProto.ChannelSettings.name, "old")
                    .fixed32(RadioProto.ChannelSettings.id, 0x0A0B_0C0D)
                    .bool(RadioProto.ChannelSettings.uplinkEnabled, true)
                    .message(RadioProto.ChannelSettings.moduleSettings, ProtoFixture()
                        .varint(RadioProto.ModuleSettings.positionPrecision, 13)
                        .bool(RadioProto.ModuleSettings.isMuted, true)))
            all[1] = RadioFixtures.channel(index: 1, name: "used1")
            all[2] = RadioFixtures.channel(index: 2, name: "used2")
            rig.download(channels: all)

            let outcome = await create(rig, "fresh")
            XCTAssertEqual(outcome.slot, 3)

            let written = try channel(of: try XCTUnwrap(rig.link.sets.first))
            XCTAssertEqual(FixtureReader.fields(written)?.map(\.number), [1, 2, 3], "index, settings, role")
            let inner = try settings(of: written)
            XCTAssertEqual(FixtureReader.fields(inner)?.map(\.number), [RadioProto.ChannelSettings.psk, RadioProto.ChannelSettings.name],
                           "a key and a name: no id, no uplink, no location precision from the old channel")
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: inner), Data("fresh".utf8))
        }
    }

    func testTheSlotsAreTheRadiosAndNotTheAppsOwnList() async {
        await withRig { rig in
            // The app's own list says slot 1 is taken; the radio says it is free.
            rig.manager.upsertAppChannel(.init(index: 1, name: "stale", pskHex: "", isPrimary: false,
                                               nodeNum: WriteRig.nodeNum, state: .onRadio))
            rig.download(channels: slots(used: []))

            let first = await create(rig, "x")
            XCTAssertEqual(first.slot, 1)

            // And the other way: the radio's slot 1 is in use though the list is empty.
            rig.manager.appChannels = []
            rig.download(channels: slots(used: [1]))
            let second = await create(rig, "y")
            XCTAssertEqual(second.slot, 2)
        }
    }

    func testASlotTheRadioHasTakenSinceTheDownloadIsNotWrittenOver() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            // Another app puts a channel in slot 1 after the download.
            rig.radio.set(channel: RadioFixtures.channel(index: 1, name: "taken", psk: RadioFixtures.otherKey), at: 1)

            let outcome = await create(rig, "delta")

            XCTAssertEqual(outcome.slot, 2, "the slot was read again and found in use")
            XCTAssertEqual(rig.link.kinds, [.getChannel(index: 1), .getChannel(index: 2), .setChannel(index: 2), .getChannel(index: 2)])
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name,
                                               in: FixtureReader.bytes(RadioProto.Channel.settings, in: rig.radio.channels[1]!)!),
                           Data("taken".utf8), "and the other channel is untouched")
        }
    }

    func testWithNoFreeSlotNothingIsSentAndTheOperatorIsToldSo() async {
        await withRig { rig in
            rig.download(channels: slots(used: [1, 2, 3, 4, 5, 6, 7]))
            let outcome = await create(rig, "x")
            XCTAssertEqual(outcome.result.refusal, "No free channel slot. All seven secondary slots on this radio are in use.")
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    func testSlotsThatAreNotKnownAreNotCalledInUse() async {
        await withRig { rig in
            // The radio has reported two of its eight slots.
            var partial = slots(used: [1])
            for index in 2...7 { partial[index] = nil }
            rig.download(channels: partial)

            let outcome = await create(rig, "x")

            let reason = outcome.result.refusal ?? ""
            XCTAssertTrue(reason.contains("not known yet"), reason)
            XCTAssertTrue(reason.contains("Re-read"), reason)
            XCTAssertFalse(reason.contains("All seven"), "unknown is not the same as in use")
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    // MARK: - The primary is only replaced on purpose

    func testReplacingThePrimaryKeepsItsKeyWhenTheKeyFieldIsBlank() async throws {
        try await withRig { rig in
            rig.download()

            let outcome = await create(rig, "renamed", key: "", primary: true)

            XCTAssertEqual(outcome, MeshtasticManager.ChannelOutcome(result: .applied, slot: 0))
            let written = try channel(of: try XCTUnwrap(rig.link.sets.first))
            let inner = try settings(of: written)
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: inner), Data("renamed".utf8))
            XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner) == RadioFixtures.key,
                          "the radio's key, untouched")
            let module = try XCTUnwrap(FixtureReader.bytes(RadioProto.ChannelSettings.moduleSettings, in: inner))
            XCTAssertEqual(FixtureReader.varint(RadioProto.ModuleSettings.positionPrecision, in: module), 13)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: written), RadioProto.ChannelRole.primary)
            XCTAssertNil(FixtureReader.varint(RadioProto.Channel.index, in: written), "slot 0 has no index field")
        }
    }

    func testReplacingThePrimaryWithAKeyChangesTheKeyAndKeepsTheRest() async throws {
        try await withRig { rig in
            rig.download()
            let outcome = await create(rig, "simtest", key: base64(RadioFixtures.otherKey), primary: true)
            XCTAssertEqual(outcome.result, .applied)

            let inner = try settings(of: try channel(of: try XCTUnwrap(rig.link.sets.first)))
            XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner) == RadioFixtures.otherKey)
            let module = try XCTUnwrap(FixtureReader.bytes(RadioProto.ChannelSettings.moduleSettings, in: inner))
            XCTAssertEqual(FixtureReader.varint(RadioProto.ModuleSettings.positionPrecision, in: module), 13)
        }
    }

    func testAnOrdinaryCreateNeverWritesTheSlotOfThePrimary() async {
        await withRig { rig in
            rig.download()
            for name in ["a", "b", "c"] {
                _ = await create(rig, name)
            }
            XCTAssertFalse(writtenSlots(rig).contains(0))
            XCTAssertEqual(writtenSlots(rig), [2, 3, 4], "slot 1 is in use on the default radio")
        }
    }

    func testThePrimaryIsNotReplacedWhenTheRadioSaysSlotZeroIsNotThePrimary() async {
        await withRig { rig in
            // The radio's primary is slot 3. Slot 0 is a secondary channel.
            var all = slots(used: [])
            all[0] = RadioFixtures.channel(index: 0, name: "zero", role: RadioProto.ChannelRole.secondary)
            all[3] = RadioFixtures.channel(index: 3, name: "real", role: RadioProto.ChannelRole.primary)
            rig.download(channels: all)

            let outcome = await create(rig, "renamed", key: "", primary: true)

            let reason = outcome.result.refusal ?? ""
            XCTAssertTrue(reason.contains("not this radio's primary"), reason)
            XCTAssertTrue(rig.link.sets.isEmpty, "nothing was written, so the real primary was not demoted")
            XCTAssertEqual(rig.radio.channels[3], all[3]?.data)
        }
    }

    func testThePrimaryIsReadAgainBeforeItIsReplaced() async {
        await withRig { rig in
            rig.download()
            // The primary is renamed on the radio after the download.
            rig.radio.set(channel: RadioFixtures.channel(index: 0, name: "elsewhere", role: RadioProto.ChannelRole.primary), at: 0)

            let outcome = await create(rig, "elsewhere", key: "", primary: true)

            XCTAssertEqual(outcome.result, .unchanged, "the radio already has that name")
            XCTAssertEqual(rig.link.kinds, [.getChannel(index: 0)])
        }
    }

    func testReplacingThePrimaryIsNotRefusedBecauseAnEarlierWriteDidNotConfirm() async {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            let first = await create(rig, "one", key: "", primary: true)
            guard case .notConfirmed = first.result else { return XCTFail("\(first.result)") }

            // The radio answers again. The next attempt reads the slot afresh and goes.
            rig.radio.stopsAnsweringAfterAWrite = false
            rig.radio.answersGets = true
            let second = await create(rig, "two", key: "", primary: true)

            XCTAssertEqual(second, MeshtasticManager.ChannelOutcome(result: .applied, slot: 0))
        }
    }

    // MARK: - A key means what the radio takes it to mean

    func testABase64KeyIsAccepted() async throws {
        try await withRig { rig in
            rig.download()
            let outcome = await create(rig, "b64", key: base64(RadioFixtures.key))
            XCTAssertEqual(outcome.result, .applied)
            let inner = try settings(of: try channel(of: try XCTUnwrap(rig.link.sets.first)))
            XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner) == RadioFixtures.key)
        }
    }

    func testAHexKeyOfEitherLengthIsAccepted() async throws {
        try await withRig { rig in
            rig.download()
            let short = Data(RadioFixtures.key.prefix(16))
            let a = await create(rig, "k16", key: hex(short))
            let b = await create(rig, "k32", key: hex(RadioFixtures.key))
            XCTAssertEqual(a.result, .applied)
            XCTAssertEqual(b.result, .applied)
            let lengths = try rig.link.sets.map {
                try XCTUnwrap(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: try settings(of: try channel(of: $0)))).count
            }
            XCTAssertEqual(lengths, [16, 32])
        }
    }

    func testAKeyThatIsNotAKeyIsRefusedAndNothingIsSent() async {
        await withRig { rig in
            rig.download()
            let bad = [
                "not a key",
                "abc",                                   // odd number of hex digits
                "zz" + hex(RadioFixtures.key),           // not hex, not base64 of a valid length
                base64(Data(repeating: 1, count: 24)),   // base64 of 24 bytes
                hex(Data(repeating: 1, count: 15)),
                hex(Data(repeating: 1, count: 33)),
                "AA==",                                  // one byte as base64: not accepted
                "ab",                                    // two characters: hex 0xAB, not a key the radio knows
                "0B",                                    // one byte, above the default key family
                "AQ==",
            ]
            for text in bad {
                let created = await create(rig, "x", key: text)
                XCTAssertEqual(created.result.refusal, MeshtasticChannelKey.invalidMessage, "key \(text.count) characters long")
                let primary = await create(rig, "x", key: text, primary: true)
                XCTAssertEqual(primary.result.refusal, MeshtasticChannelKey.invalidMessage)
            }
            XCTAssertTrue(rig.link.sent.isEmpty, "a typo never becomes an open channel, or a channel without its key")
            XCTAssertTrue(rig.manager.channelReports.isEmpty)
        }
    }

    func testABlankKeyForANewChannelIsRefusedUnlessNoEncryptionIsChosen() async {
        await withRig { rig in
            rig.download()
            let blank = await create(rig, "x", key: "  ")
            XCTAssertEqual(blank.result.refusal, "Enter a key (hex or base64), or choose No encryption for an open channel.")
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    func testNoEncryptionWritesTheOneByteZeroBecauseNoKeyAtAllIsNotOpen() async throws {
        try await withRig { rig in
            rig.download()

            let open = await create(rig, "open", key: "", noEncryption: true)

            XCTAssertEqual(open.result, .applied)
            let inner = try settings(of: try channel(of: try XCTUnwrap(rig.link.sets.first)))
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner), Data([0]),
                           "open is the one byte 0: with no key a secondary channel uses the primary's key")
            // The radio's answer agrees.
            let held = try XCTUnwrap(rig.manager.radioSettings.channelSummary(index: 2))
            XCTAssertEqual(held.psk, Data([0]))
            XCTAssertEqual(MeshtasticChannelKey.kind(of: held.psk, isPrimary: false), .open)
        }
    }

    func testTheOneByteShorthandIsAcceptedAsTwoHexDigits() async throws {
        try await withRig { rig in
            rig.download()
            let open = await create(rig, "zero", key: "00")
            let standard = await create(rig, "std", key: "01")
            XCTAssertEqual(open.result, .applied)
            XCTAssertEqual(standard.result, .applied)
            let keys = try rig.link.sets.map {
                try XCTUnwrap(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: try settings(of: try channel(of: $0))))
            }
            XCTAssertEqual(keys, [Data([0]), Data([1])])
        }
    }

    func testAKeyAndNoEncryptionTogetherIsRefused() async {
        await withRig { rig in
            rig.download()
            let outcome = await create(rig, "x", noEncryption: true)
            XCTAssertEqual(outcome.result.refusal, "Enter a key or choose No encryption, not both.")
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    func testRemovingThePrimarysKeyIsAnExplicitChoiceAndWritesTheOneByteZero() async throws {
        try await withRig { rig in
            rig.download()
            let outcome = await create(rig, "simtest", key: "", noEncryption: true, primary: true)
            XCTAssertEqual(outcome.result, .applied)
            let inner = try settings(of: try channel(of: try XCTUnwrap(rig.link.sets.first)))
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner), Data([0]))
        }
    }

    func testANameOverElevenBytesIsRefusedAndTheOperatorIsToldWhy() async {
        await withRig { rig in
            rig.download()
            let twelve = await create(rig, "abcdefghijkl")
            XCTAssertEqual(twelve.result.refusal,
                           "Channel names are at most 11 bytes. \"abcdefghijkl\" is 12. The radio would drop the whole message.")
            XCTAssertTrue(rig.link.sent.isEmpty)

            // Bytes, not characters: six two-byte characters are twelve bytes.
            let accents = await create(rig, "éééééé")
            XCTAssertNotNil(accents.result.refusal)

            let eleven = await create(rig, "abcdefghijk")
            XCTAssertEqual(eleven.result, .applied)
        }
    }

    // MARK: - The saved list

    func testTheSavedListOnlyHoldsChannelsWhoseKeyIsKnown() async {
        await withRig { rig in
            rig.download()
            let before = rig.manager.appChannels
            _ = await create(rig, "kept", key: "", primary: true)
            XCTAssertEqual(rig.manager.appChannels, before, "a kept key is not known to the app, so it is not listed or shared")
            _ = await create(rig, "bad", key: "nope")
            XCTAssertEqual(rig.manager.appChannels, before, "a refused channel is not saved")

            _ = await create(rig, "good")
            XCTAssertEqual(rig.manager.appChannels.filter { $0.name == "good" }.map(\.index), [2])
        }
    }

    func testASavedChannelIsTiedToTheRadioItWasWrittenTo() async {
        await withRig { rig in
            rig.download()
            _ = await create(rig, "delta")
            let entry = rig.manager.appChannels.first(where: { $0.name == "delta" })
            XCTAssertEqual(entry?.nodeNum, WriteRig.nodeNum)
            XCTAssertEqual(entry?.index, 2)
            XCTAssertEqual(entry?.effectiveState, .onRadio, "the radio's own answer shows it")
        }
    }

    func testAChannelCreatedOnAnotherRadioDoesNotReplaceTheFirstRadiosEntry() async {
        await withRig { rig in
            rig.download()
            _ = await create(rig, "delta")

            rig.chooseAnotherRadio(node: 0x0B0B_0B0B)
            rig.download()
            let second = await create(rig, "echo")
            XCTAssertEqual(second.slot, 2, "the same slot, on a different radio")

            let entries = rig.manager.appChannels
            XCTAssertEqual(entries.count, 2)
            XCTAssertEqual(entries.first(where: { $0.name == "delta" })?.nodeNum, WriteRig.nodeNum)
            XCTAssertEqual(entries.first(where: { $0.name == "echo" })?.nodeNum, 0x0B0B_0B0B)
        }
    }

    func testAChannelTheRadioRefusedStaysListedAndSaysSo() async {
        await withRig { rig in
            rig.download()
            rig.radio.appliesChannelWrites = false

            let outcome = await create(rig, "delta")

            XCTAssertEqual(outcome.result, .notConfirmed("The radio kept its own value."))
            let entry = rig.manager.appChannels.first(where: { $0.name == "delta" })
            XCTAssertEqual(entry?.effectiveState, .radioKept)
            XCTAssertEqual(entry?.effectiveState.label, "refused: the radio kept its own value")
        }
    }

    func testASavedChannelIsCheckedAgainstWhatTheConnectedRadioSaysNow() async throws {
        try await withRig { rig in
            rig.download()
            _ = await create(rig, "delta")
            let entry = try XCTUnwrap(rig.manager.appChannels.first(where: { $0.name == "delta" }))
            XCTAssertEqual(rig.manager.standing(of: entry).label, "on the radio")
            XCTAssertTrue(rig.manager.standing(of: entry).onRadio)

            // The slot is changed behind the app's back, and the app asks again.
            rig.radio.set(channel: RadioFixtures.channel(index: 2, name: "other", psk: RadioFixtures.otherKey), at: 2)
            _ = await rig.manager.rereadFromRadio()
            XCTAssertEqual(rig.manager.standing(of: entry).label, "not on the radio now: slot 2 holds another channel")
            XCTAssertFalse(rig.manager.standing(of: entry).onRadio)

            rig.radio.set(channel: RadioFixtures.disabledChannel(index: 2), at: 2)
            _ = await rig.manager.rereadFromRadio()
            XCTAssertEqual(rig.manager.standing(of: entry).label, "not on the radio now: slot 2 is empty")

            // Connected to another radio, the entry is what was last known of the
            // radio it was written to.
            rig.chooseAnotherRadio(node: 0x0B0B_0B0B)
            rig.download()
            XCTAssertEqual(rig.manager.standing(of: entry).label, "another radio: on the radio")
            XCTAssertFalse(rig.manager.standing(of: entry).onRadio)
        }
    }

    func testRemovingAnEntryFromTheListLeavesTheChannelOnTheRadio() async {
        await withRig { rig in
            rig.download()
            _ = await create(rig, "delta")
            let entry = rig.manager.appChannels.first(where: { $0.name == "delta" })!

            rig.manager.removeAppChannel(entry)

            XCTAssertTrue(rig.manager.appChannels.isEmpty)
            let held = rig.radio.channels[2].flatMap { MeshtasticAdminCodec.channelSummary(in: $0) }
            XCTAssertEqual(held?.name, "delta", "the radio still has it")
        }
    }

    func testAnOpenChannelIsSavedAndSharedAsOpen() async throws {
        try await withRig { rig in
            rig.download()
            _ = await create(rig, "open", key: "", noEncryption: true)
            let entry = try XCTUnwrap(rig.manager.appChannels.first(where: { $0.name == "open" }))

            XCTAssertEqual(entry.pskHex, "00")
            XCTAssertEqual(entry.keyKind, .open)
            let url = try XCTUnwrap(rig.manager.channelShareURL(only: entry))
            guard case .meshtastic(let shared)? = MeshChannelShare.parse(url) else { return XCTFail("not a channel link") }
            XCTAssertEqual(shared.first?.psk, Data([0]), "the link carries what the radio holds")
        }
    }

    // MARK: - With no radio connected

    func testACreateWithNoRadioConnectedIsKeptForSharingAndSaysItIsNotOnARadio() async throws {
        try await withRig { rig in
            rig.manager.disconnect()

            let outcome = await create(rig, "solo")

            XCTAssertTrue(outcome.savedOnly)
            XCTAssertEqual(outcome.result.refusal, MeshtasticWriteResult.notConnected)
            XCTAssertNil(outcome.slot)
            XCTAssertTrue(rig.link.sent.isEmpty)
            let entry = try XCTUnwrap(rig.manager.appChannels.first)
            XCTAssertEqual(entry.name, "solo")
            XCTAssertNil(entry.nodeNum)
            XCTAssertEqual(entry.effectiveState, .savedOnly)
            XCTAssertEqual(entry.pskHex, hex(RadioFixtures.key))
            XCTAssertNotNil(rig.manager.channelShareURL(only: entry), "kept for sharing")
        }
    }

    func testAnOpenChannelWithNoRadioIsSavedWithTheOneByteZero() async {
        await withRig { rig in
            rig.manager.disconnect()
            let outcome = await create(rig, "open", key: "", noEncryption: true)
            XCTAssertTrue(outcome.savedOnly)
            XCTAssertEqual(rig.manager.appChannels.first?.pskHex, "00")
        }
    }

    func testReplacingThePrimaryNeedsARadioAndSavesNothing() async {
        await withRig { rig in
            rig.manager.disconnect()
            let outcome = await create(rig, "x", key: "", primary: true)
            XCTAssertFalse(outcome.savedOnly)
            XCTAssertEqual(outcome.result.refusal, "Connect a radio to replace its primary channel.")
            XCTAssertTrue(rig.manager.appChannels.isEmpty)
        }
    }

    func testAnInvalidKeyWithNoRadioIsStillRefusedAndNotSaved() async {
        await withRig { rig in
            rig.manager.disconnect()
            let outcome = await create(rig, "x", key: "nope")
            XCTAssertFalse(outcome.savedOnly)
            XCTAssertEqual(outcome.result.refusal, MeshtasticChannelKey.invalidMessage)
            XCTAssertTrue(rig.manager.appChannels.isEmpty)
        }
    }

    // MARK: - Said to be applied only when the radio says so

    func testAChannelIsAppliedWhenTheRadiosAnswerMatches() async throws {
        await withRig { rig in
            rig.download()
            let outcome = await create(rig, "delta")

            XCTAssertEqual(outcome.result, .applied)
            XCTAssertEqual(rig.manager.channelReports, [MeshtasticChannelReport(slot: 2, name: "delta", state: .applied)])
            XCTAssertEqual(rig.manager.radioSettings.channel(index: 2), rig.radio.channels[2],
                           "the radio's own answer is what is held")
            XCTAssertFalse(rig.manager.radioSettings.isAwaitingReadBack(index: 2))
            XCTAssertEqual(rig.manager.channelReports.first?.text, "Slot 2 \"delta\": applied. The radio reports it.")
        }
    }

    func testARadioThatKeepsItsOwnValueIsReportedAsHavingDoneSo() async {
        await withRig { rig in
            rig.download()
            rig.radio.appliesChannelWrites = false

            let outcome = await create(rig, "simtest2", key: "", primary: true)

            XCTAssertEqual(outcome.result, .notConfirmed("The radio kept its own value (\"simtest\")."))
            XCTAssertEqual(rig.manager.channelReports,
                           [MeshtasticChannelReport(slot: 0, name: "simtest2", state: .radioKept("simtest"))])
            XCTAssertEqual(rig.manager.channelReports.first?.text,
                           "Slot 0 \"simtest2\": the radio kept its own value (\"simtest\").")
            XCTAssertEqual(rig.manager.radioSettings.channelSummary(index: 0)?.name, "simtest", "and that is what is held")
        }
    }

    func testAKeyThatDiffersIsNotApplied() async {
        await withRig { rig in
            rig.download()
            // The radio takes the name and not the key.
            rig.radio.transformChannelWrite = { _ in
                RadioFixtures.channel(index: 2, name: "delta", psk: RadioFixtures.otherKey).data
            }

            let outcome = await create(rig, "delta")

            XCTAssertEqual(rig.manager.channelReports.first?.state, .radioKept("delta"))
            XCTAssertEqual(outcome.result, .notConfirmed("The radio kept its own value (\"delta\")."))
        }
    }

    func testAnAnswerThatNeverComesIsReportedAndTheWriteWasSent() async {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true

            let outcome = await create(rig, "delta")

            guard case .notConfirmed(let reason) = outcome.result else { return XCTFail("\(outcome.result)") }
            XCTAssertTrue(reason.contains("did not confirm"))
            XCTAssertEqual(outcome.slot, 2)
            XCTAssertEqual(rig.manager.channelReports.first?.state, .noAnswer)
            XCTAssertEqual(rig.manager.channelReports.first?.text,
                           "Slot 2 \"delta\": the radio did not confirm. The change may not have been applied. "
                           + "If the radio answers later this line changes.")
            XCTAssertEqual(rig.manager.appChannels.first(where: { $0.name == "delta" })?.effectiveState, .notConfirmed)
        }
    }

    func testTheRowSaysSentWhileTheRadioHasNotAnswered() async throws {
        try await withRig { rig in
            rig.download()
            rig.manager.answerTimeout = 30
            rig.radio.holdsAnswersAfterAWrite = true
            let manager = rig.manager
            let task = Task { await manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                          noEncryption: false, replacePrimary: false) }
            // The write has gone and its read-back has been asked for.
            while rig.link.kinds.last != .getChannel(index: 2) || !rig.link.kinds.contains(.setChannel(index: 2)) {
                try await Task.sleep(nanoseconds: 5_000_000)
            }

            XCTAssertEqual(manager.channelReports, [MeshtasticChannelReport(slot: 2, name: "delta", state: .sent)])
            XCTAssertEqual(manager.channelReports.first?.text, "Slot 2 \"delta\": sent, waiting for the radio to confirm.")
            XCTAssertEqual(manager.appChannels.first(where: { $0.name == "delta" })?.effectiveState, .sent)
            XCTAssertNil(manager.radioSettings.channel(index: 2), "what was sent is not taken for what the radio holds")
            XCTAssertTrue(manager.radioSettings.isAwaitingReadBack(index: 2))
            XCTAssertFalse(manager.radioSettings.freeChannelSlots.contains(2), "and the slot is not free")

            rig.radio.releaseAnswers()
            let outcome = await task.value
            XCTAssertEqual(outcome.result, .applied)
            XCTAssertEqual(manager.channelReports.first?.state, .applied)
        }
    }

    func testALateAnswerUpdatesTheRow() async throws {
        try await withRig { rig in
            rig.download()
            rig.manager.answerTimeout = 0.1
            rig.radio.holdsAnswersAfterAWrite = true

            let outcome = await create(rig, "delta")
            guard case .notConfirmed = outcome.result else { return XCTFail("\(outcome.result)") }
            XCTAssertEqual(rig.manager.channelReports.first?.state, .noAnswer)

            // The radio's answer comes after the deadline.
            rig.radio.releaseAnswers()
            for _ in 0..<200 where rig.manager.channelReports.first?.state != .applied {
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            XCTAssertEqual(rig.manager.channelReports.first?.state, .applied)
            XCTAssertEqual(rig.manager.appChannels.first(where: { $0.name == "delta" })?.effectiveState, .onRadio)
            XCTAssertEqual(rig.manager.radioSettings.channel(index: 2), rig.radio.channels[2])
        }
    }

    func testALateAnswerIsNotTakenWhenANewerRequestForTheSlotWasSent() async throws {
        try await withRig { rig in
            rig.download()
            rig.manager.answerTimeout = 0.1
            rig.radio.holdsAnswersAfterAWrite = true
            _ = await create(rig, "delta")            // the read-back goes unanswered, for now

            // The radio answers what is asked from here on, and the slot changes
            // and is asked about again.
            rig.radio.holdAnswers = false
            rig.radio.holdsAnswersAfterAWrite = false
            rig.radio.set(channel: RadioFixtures.channel(index: 2, name: "later", psk: RadioFixtures.otherKey), at: 2)
            let outcome = await rig.manager.rereadFromRadio()
            XCTAssertNil(outcome.refusal)
            XCTAssertEqual(rig.manager.radioSettings.channelSummary(index: 2)?.name, "later")

            // The old answer, "delta", arrives now. It is older than what the app holds.
            rig.radio.releaseAnswers()
            try await Task.sleep(nanoseconds: 150_000_000)

            XCTAssertEqual(rig.manager.radioSettings.channelSummary(index: 2)?.name, "later")
        }
    }

    func testASlotWithAnUnconfirmedWriteIsNotFreeAndTheSameChannelIsNotAddedTwice() async throws {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            let first = await create(rig, "delta")
            guard case .notConfirmed = first.result else { return XCTFail("\(first.result)") }
            rig.radio.stopsAnsweringAfterAWrite = false
            rig.radio.answersGets = true
            rig.link.forgetSent()

            // The same channel again: not sent, and the operator is told why.
            let again = await create(rig, "delta")
            XCTAssertNil(again.slot)
            XCTAssertTrue((again.result.refusal ?? "").contains("already sent to slot 2"), again.result.refusal ?? "")
            XCTAssertTrue(rig.link.sent.isEmpty)

            // Another channel does not go into the slot that is waiting.
            let other = await create(rig, "echo", key: hex(RadioFixtures.otherKey))
            XCTAssertEqual(other.slot, 3)
            XCTAssertEqual(writtenSlots(rig), [3])
        }
    }

    func testARereadSettlesAnUnconfirmedWrite() async throws {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            _ = await create(rig, "delta")
            XCTAssertEqual(rig.manager.channelReports.first?.state, .noAnswer)
            rig.radio.answersGets = true

            let outcome = await rig.manager.rereadFromRadio()

            XCTAssertEqual(outcome, MeshtasticManager.RereadOutcome(answered: 10, missing: [], refusal: nil))
            XCTAssertEqual(rig.manager.channelReports.first?.state, .applied, "the radio did take it")
            XCTAssertEqual(rig.manager.appChannels.first(where: { $0.name == "delta" })?.effectiveState, .onRadio)
        }
    }

    func testAWriteWaitingForItsAnswerIsLeftUnconfirmedWhenTheLinkDrops() async {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            rig.manager.answerTimeout = 30
            let manager = rig.manager
            let task = Task { await manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                          noEncryption: false, replacePrimary: false) }
            while !rig.link.kinds.contains(.setChannel(index: 2)) || rig.link.kinds.last != .getChannel(index: 2) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }

            manager.handleLinkDown(.tcp)

            let outcome = await task.value
            guard case .notConfirmed = outcome.result else { return XCTFail("\(outcome.result)") }
            XCTAssertEqual(manager.channelReports.first?.state, .linkLost,
                           "nothing waits for the answer any more, so the line does not promise one")
            XCTAssertFalse(manager.channelReports.first?.text.contains("this line changes") ?? true)
            XCTAssertEqual(manager.appChannels.first(where: { $0.name == "delta" })?.effectiveState, .notConfirmed)
        }
    }

    // MARK: - Import

    func testImportGoesIntoFreeSlotsInOrderAndNeverOverwritesOne() async throws {
        try await withRig { rig in
            rig.download(channels: slots(used: [1, 3]))      // free: 2, 4, 5, 6, 7
            let channels = (0..<3).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = await rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.confirmed, [2, 4, 5])
            XCTAssertEqual(outcome.noRoom, 0)
            XCTAssertNil(outcome.refusal)
            XCTAssertEqual(writtenSlots(rig), [2, 4, 5], "never slot 0, 1 or 3")
            // Each is clean and secondary.
            for write in rig.link.sets {
                let written = try channel(of: write)
                XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: written), RadioProto.ChannelRole.secondary)
                XCTAssertEqual(FixtureReader.fields(try settings(of: written))?.map(\.number),
                               [RadioProto.ChannelSettings.psk, RadioProto.ChannelSettings.name])
            }
        }
    }

    func testImportWithMoreChannelsThanFreeSlotsSaysSoAndCountsWhatTheRadioConfirmed() async {
        await withRig { rig in
            rig.download(channels: slots(used: [1, 2, 3, 4]))    // free: 5, 6, 7
            let channels = (0..<8).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = await rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.confirmed, [5, 6, 7])
            XCTAssertEqual(outcome.noRoom, 5)
            XCTAssertEqual(outcome.sent.count + outcome.noRoom + outcome.alreadyThere + outcome.skipped.count, 8,
                           "every channel is accounted for")
            XCTAssertEqual(writtenSlots(rig).count, 3)
        }
    }

    func testImportOfNineChannelsOnARadioWithOnlyAPrimaryReportsSevenConfirmedAndTwoLeftOut() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            let channels = (0..<9).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = await rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.confirmed, [1, 2, 3, 4, 5, 6, 7])
            XCTAssertEqual(outcome.noRoom, 2, "the old code reported seven applied and said nothing about the rest")
        }
    }

    func testImportDoesNotAddAChannelTheRadioAlreadyHasOrAddTheSameOneTwice() async {
        await withRig { rig in
            rig.download(channels: slots(used: [1]))     // slot 1: "used1" with otherKey
            let channels = [
                MeshChannel(name: "used1", psk: RadioFixtures.otherKey),  // already there
                MeshChannel(name: "fresh", psk: RadioFixtures.key),
                MeshChannel(name: "fresh", psk: RadioFixtures.key),       // the same again, in the same set
            ]

            let outcome = await rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.confirmed, [2])
            XCTAssertEqual(outcome.alreadyThere, 1, "the radio reported slot 1 when it was asked")
            XCTAssertEqual(outcome.skipped.count, 1, "the same channel twice in one link is added once")
            XCTAssertTrue(outcome.skipped[0].contains("more than once"))
            XCTAssertEqual(writtenSlots(rig), [2])
        }
    }

    func testImportDoesNotAddAChannelThatHasAnUnconfirmedWriteWaiting() async {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            _ = await create(rig, "delta")                    // slot 2, not confirmed
            rig.radio.stopsAnsweringAfterAWrite = false
            rig.radio.answersGets = true
            rig.link.forgetSent()

            let outcome = await rig.manager.importChannels([
                MeshChannel(name: "delta", psk: RadioFixtures.key),
                MeshChannel(name: "echo", psk: RadioFixtures.otherKey),
            ])

            XCTAssertEqual(outcome.waiting, 1, "the same channel does not land twice, and is not called already there")
            XCTAssertEqual(outcome.alreadyThere, 0, "the radio has not said it has it")
            XCTAssertEqual(outcome.confirmed, [3], "and slot 2, which is waiting, is not used for the other")
        }
    }

    func testImportLeavesOutAChannelThatCannotBeWrittenAndSaysWhy() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            let channels = [
                MeshChannel(name: "abcdefghijkl", psk: RadioFixtures.key),
                MeshChannel(name: "badkey", psk: Data(repeating: 1, count: 20)),
                MeshChannel(name: "nokey", psk: Data()),
                MeshChannel(name: "fine", psk: RadioFixtures.key),
            ]

            let outcome = await rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.confirmed, [1])
            XCTAssertEqual(outcome.skipped.count, 3)
            XCTAssertTrue(outcome.skipped[0].contains("at most 11 bytes"))
            XCTAssertTrue(outcome.skipped[1].contains("16 or 32 bytes"))
            XCTAssertTrue(outcome.skipped[2].contains("no key"), "a channel with no key would use this radio's primary key")
        }
    }

    func testImportAcceptsTheOneByteKeys() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            let outcome = await rig.manager.importChannels([
                MeshChannel(name: "open", psk: Data([0])),
                MeshChannel(name: "default", psk: Data([1])),
            ])
            XCTAssertEqual(outcome.confirmed, [1, 2])
            XCTAssertTrue(outcome.skipped.isEmpty)
        }
    }

    func testImportWithTheRadioNotLoadedIsRefusedWhole() async {
        await withRig { rig in
            rig.download(started: false)
            let outcome = await rig.manager.importChannels([MeshChannel(name: "x", psk: RadioFixtures.key)])
            XCTAssertEqual(outcome.refusal, MeshtasticWriteResult.notLoaded)
            XCTAssertTrue(outcome.sent.isEmpty)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    // MARK: - An import opens no transaction

    // While an edit is open the radio holds off saving, and off restarting, until
    // a commit or a restart. An open one that is never committed leaves every later
    // write in the radio's memory only. A set_channel saves itself and does not
    // restart the radio, so nothing here needs one.

    func testAnImportSendsOneSetChannelAfterAnotherAndNoTransaction() async {
        for count in [1, 3] {
            await withRig { rig in
                rig.download(channels: slots(used: []))
                let channels = (0..<count).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

                let outcome = await rig.manager.importChannels(channels)

                XCTAssertEqual(outcome.confirmed, Array(1...count))
                var expected: [SimulatedRadioModel.Kind] = []
                for slot in 1...count {
                    expected += [.getChannel(index: slot), .setChannel(index: slot), .getChannel(index: slot)]
                }
                XCTAssertEqual(rig.link.kinds, expected, "a read, a write and a read back for each, and nothing else")
                XCTAssertFalse(rig.radio.transactionOpen)
                XCTAssertEqual(rig.radio.commits, 0)
                XCTAssertFalse(rig.radio.restartRequested, "a channel is saved without a restart")
            }
        }
    }

    func testAnImportOfFourChannelsIsStillOnTheRadioAfterItRestarts() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            let channels = (0..<4).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = await rig.manager.importChannels(channels)
            XCTAssertEqual(outcome.confirmed, [1, 2, 3, 4])

            rig.radio.restart()      // a power cycle: only what was saved is left
            for slot in 1...4 {
                let held = rig.radio.channels[slot].flatMap { MeshtasticAdminCodec.channelSummary(in: $0) }
                XCTAssertEqual(held?.name, "imp\(slot - 1)", "slot \(slot)")
                XCTAssertFalse(held?.isDisabled ?? true)
            }
        }
    }

    func testTheModelLosesWhatIsWrittenWhileAnEditIsOpenAtARestart() async {
        // What the transaction would cost: it is why the app never opens one. The
        // radio takes the writes, and the app says applied, and a restart takes
        // them back.
        await withRig { rig in
            rig.download(channels: slots(used: []))
            guard case .go(let route) = rig.manager.route() else { return XCTFail("no route") }
            let begun = await rig.manager.sendFrame(
                ProtoFixture().bool(RadioProto.Admin.beginEditSettings, true).data,
                wantResponse: false, packetID: rig.manager.freshPacketID(), route: route)
            XCTAssertTrue(begun)
            XCTAssertTrue(rig.radio.transactionOpen)

            let outcome = await create(rig, "lost")
            XCTAssertEqual(outcome.result, .applied, "the radio answers from memory")

            rig.radio.restart()
            XCTAssertTrue(rig.radio.channels[1].flatMap { MeshtasticAdminCodec.channelSummary(in: $0) }?.isDisabled ?? false,
                          "and it is gone after the restart")
            XCTAssertFalse(rig.radio.transactionOpen)
        }
    }

    func testALinkLostDuringAnImportLeavesNoTransactionAndTheRestAreNotTried() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            // The link is lost as the first channel is written.
            rig.link.onSent = { kind in
                if kind == .setChannel(index: 1) {
                    rig.link.isUp = false
                    DispatchQueue.main.async { rig.manager.handleLinkDown(.tcp) }
                }
            }
            let channels = (0..<4).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = await rig.manager.importChannels(channels)
            await rig.settle()

            XCTAssertEqual(outcome.unconfirmed, [1], "it went, and was not read back")
            XCTAssertTrue(outcome.confirmed.isEmpty)
            XCTAssertEqual(outcome.notTried, 3, "the other three were not tried")
            XCTAssertEqual(outcome.noRoom, 0, "and are not said to have no room")
            XCTAssertEqual(outcome.refusal, MeshtasticWriteResult.linkChanged)
            XCTAssertFalse(rig.radio.transactionOpen)
            XCTAssertFalse(rig.link.kinds.contains(.beginEdit))
            XCTAssertFalse(rig.link.kinds.contains(.commitEdit))
            let summary = MeshtasticSettingsMessages.importSummary(outcome, total: 4)
            XCTAssertTrue(summary.contains("3 not tried"), summary)
            XCTAssertFalse(summary.lowercased().contains("no free slot"), summary)
        }
    }

    func testALinkLostBetweenTwoChannelsOfAnImportStopsItAndCountsTheRest() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            // Frames are paced, and the link is lost while the import waits to ask
            // about the second channel's slot.
            rig.manager.frameSpacing = 0.3
            var readBacks = 0
            rig.link.onSent = { kind in
                guard kind == .getChannel(index: 1) else { return }
                readBacks += 1
                if readBacks == 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { rig.manager.handleLinkDown(.tcp) }
                }
            }
            let channels = (0..<3).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = await rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.confirmed, [1])
            XCTAssertEqual(outcome.notTried, 2)
            XCTAssertEqual(outcome.noRoom, 0)
            XCTAssertEqual(outcome.refusal, MeshtasticWriteResult.linkChanged)
            XCTAssertFalse(rig.radio.transactionOpen)
            XCTAssertEqual(rig.link.sets.count, 1, "nothing was written after the link was lost")
        }
    }

    func testAnImportWithNothingToWriteSendsNothingThatRestartsTheRadio() async {
        // Every slot is known to be in use.
        await withRig { rig in
            rig.download(channels: slots(used: [1, 2, 3, 4, 5, 6, 7]))
            let outcome = await rig.manager.importChannels((0..<2).map { MeshChannel(name: "new\($0)", psk: RadioFixtures.key) })
            XCTAssertEqual(outcome.noRoom, 2)
            XCTAssertTrue(rig.link.sent.isEmpty, "nothing to ask, nothing to write")
            XCTAssertFalse(rig.radio.restartRequested)
            XCTAssertEqual(rig.radio.commits, 0)
        }
        // Everything is already there: the radio is asked, and nothing is written.
        await withRig { rig in
            rig.download(channels: slots(used: [1, 2]))
            let outcome = await rig.manager.importChannels([
                MeshChannel(name: "used1", psk: RadioFixtures.otherKey),
                MeshChannel(name: "used2", psk: RadioFixtures.otherKey),
            ])
            XCTAssertEqual(outcome.alreadyThere, 2)
            XCTAssertEqual(rig.link.kinds, [.getChannel(index: 1), .getChannel(index: 2)], "only reads")
            XCTAssertTrue(rig.link.sets.isEmpty)
            XCTAssertFalse(rig.radio.restartRequested)
            XCTAssertEqual(rig.radio.commits, 0)
        }
        // The first read gets no answer.
        await withRig { rig in
            rig.download(channels: slots(used: []))
            rig.radio.answersGets = false
            let outcome = await rig.manager.importChannels((0..<2).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) })
            XCTAssertEqual(outcome.refusal, MeshtasticWriteResult.noAnswer)
            XCTAssertEqual(outcome.notTried, 2)
            XCTAssertEqual(rig.link.kinds, [.getChannel(index: 1)])
            XCTAssertFalse(rig.radio.restartRequested)
            XCTAssertEqual(rig.radio.commits, 0)
        }
    }

    func testAnImportWhenSlotsAreNotKnownDoesNotSayThereIsNoRoom() async {
        await withRig { rig in
            // The download reported slots 0 and 1 only.
            let known = slots(used: [1]).filter { $0.key <= 1 }
            rig.download(channels: known)
            let outcome = await rig.manager.importChannels((0..<2).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) })

            XCTAssertEqual(outcome.noRoom, 0, "slots that are not known are not slots in use")
            XCTAssertEqual(outcome.notTried, 2)
            XCTAssertNotNil(outcome.refusal)
            XCTAssertTrue(outcome.refusal?.contains("not known yet") ?? false, outcome.refusal ?? "")
            XCTAssertTrue(rig.link.sent.isEmpty)
            let summary = MeshtasticSettingsMessages.importSummary(outcome, total: 2)
            XCTAssertFalse(summary.lowercased().contains("no free slot"), summary)
            XCTAssertFalse(summary.contains("all seven"), summary)
        }
    }

    func testAnImportAsksTheRadioBeforeSayingItAlreadyHasAChannel() async {
        // What was downloaded says slot 1 holds "used1". The radio has since put
        // another channel there.
        await withRig { rig in
            rig.download(channels: slots(used: [1]))
            rig.radio.set(channel: RadioFixtures.channel(index: 1, name: "other", psk: RadioFixtures.key), at: 1)

            let outcome = await rig.manager.importChannels([MeshChannel(name: "used1", psk: RadioFixtures.otherKey)])

            XCTAssertEqual(outcome.alreadyThere, 0, "the radio no longer has it")
            XCTAssertEqual(outcome.confirmed, [2], "so it is added, where there is room")
        }
        // The radio still has it: it says so when asked, and nothing is written.
        await withRig { rig in
            rig.download(channels: slots(used: [1]))
            let outcome = await rig.manager.importChannels([MeshChannel(name: "used1", psk: RadioFixtures.otherKey)])
            XCTAssertEqual(outcome.alreadyThere, 1)
            XCTAssertEqual(rig.link.kinds, [.getChannel(index: 1)], "it was asked, and not written")
        }
    }

    func testAnImportDoesNotAddAChannelTheRadioGainedSinceTheDownload() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            // Another app puts this very channel in slot 1 after the download.
            rig.radio.set(channel: RadioFixtures.channel(index: 1, name: "team", psk: RadioFixtures.key), at: 1)

            let outcome = await rig.manager.importChannels([MeshChannel(name: "team", psk: RadioFixtures.key)])

            XCTAssertEqual(outcome.alreadyThere, 1)
            XCTAssertTrue(outcome.confirmed.isEmpty)
            XCTAssertTrue(rig.link.sets.isEmpty, "it is not put in a second slot")
        }
    }

    func testACreateOfAChannelTheRadioGainedSinceTheDownloadIsNotMadeASecondTime() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            rig.radio.set(channel: RadioFixtures.channel(index: 1, name: "team", psk: RadioFixtures.key), at: 1)

            let outcome = await create(rig, "team")

            XCTAssertEqual(outcome, MeshtasticManager.ChannelOutcome(result: .unchanged, slot: 1))
            XCTAssertTrue(rig.link.sets.isEmpty, "slot 2 is not written")
            let slotsHoldingIt = rig.radio.channels.values.compactMap { MeshtasticAdminCodec.channelSummary(in: $0) }
                .filter { $0.name == "team" && !$0.isDisabled }
            XCTAssertEqual(slotsHoldingIt.count, 1)
        }
    }

    func testACreateAsksTheRadioBeforeSayingItAlreadyHasTheChannel() async {
        await withRig { rig in
            rig.download(channels: slots(used: [1]))
            rig.radio.set(channel: RadioFixtures.channel(index: 1, name: "other", psk: RadioFixtures.key), at: 1)

            let outcome = await create(rig, "used1", key: WriteRig.hex(RadioFixtures.otherKey))

            XCTAssertEqual(outcome.result, .applied, "the slot no longer holds it, so it is created")
            XCTAssertEqual(outcome.slot, 2)
        }
        await withRig { rig in
            rig.download(channels: slots(used: [1]))
            let outcome = await create(rig, "used1", key: WriteRig.hex(RadioFixtures.otherKey))
            XCTAssertEqual(outcome, MeshtasticManager.ChannelOutcome(result: .unchanged, slot: 1))
            XCTAssertEqual(rig.link.kinds, [.getChannel(index: 1)], "asked, and not written")
        }
    }

    func testAnImportReportsOnlyWhatTheRadioConfirmed() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            rig.radio.appliesChannelWrites = false
            let channels = (0..<2).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = await rig.manager.importChannels(channels)

            XCTAssertTrue(outcome.confirmed.isEmpty, "the radio kept its own values")
            XCTAssertEqual(outcome.unconfirmed.count, 2)
        }
    }

    // MARK: - The saved list keeps what the radio still holds

    func testARefusedReplaceKeepsTheEntryForTheChannelTheRadioStillHolds() async throws {
        try await withRig { rig in
            rig.download()
            let first = await create(rig, "p1", key: hex(RadioFixtures.key), primary: true)
            XCTAssertEqual(first.result, .applied)

            rig.radio.appliesChannelWrites = false
            let second = await create(rig, "p2", key: hex(RadioFixtures.otherKey), primary: true)
            guard case .notConfirmed = second.result else { return XCTFail("\(second.result)") }

            let kept = rig.manager.appChannels.filter { $0.index == 0 }
            XCTAssertEqual(kept.count, 1)
            XCTAssertEqual(kept.first?.name, "p1", "the radio still holds p1")
            XCTAssertEqual(kept.first?.pskHex, hex(RadioFixtures.key), "with its key")
            XCTAssertTrue(rig.manager.standing(of: try XCTUnwrap(kept.first)).onRadio)
        }
    }

    func testAReplaceThatCannotBeSentKeepsTheEntryToo() async throws {
        try await withRig { rig in
            rig.download()
            _ = await create(rig, "p1", key: hex(RadioFixtures.key), primary: true)
            // The link refuses what comes after the read of the primary.
            rig.link.onSent = { kind in
                if kind == .getChannel(index: 0) { rig.link.accepts = false }
            }

            let second = await create(rig, "p2", key: hex(RadioFixtures.otherKey), primary: true)

            XCTAssertEqual(second.result, .linkChangedRefusal)
            let kept = rig.manager.appChannels.filter { $0.index == 0 }
            XCTAssertEqual(kept.count, 1)
            XCTAssertEqual(kept.first?.name, "p1")
            XCTAssertEqual(kept.first?.pskHex, hex(RadioFixtures.key))
            XCTAssertEqual(kept.first?.effectiveState, .onRadio)
        }
    }

    func testALateAnswerThatShowsTheReplacementReplacesTheEntry() async throws {
        try await withRig { rig in
            rig.download()
            _ = await create(rig, "p1", key: hex(RadioFixtures.key), primary: true)
            rig.radio.holdsAnswersAfterAWrite = true
            rig.manager.answerTimeout = 0.2

            let second = await create(rig, "p2", key: hex(RadioFixtures.otherKey), primary: true)
            guard case .notConfirmed = second.result else { return XCTFail("\(second.result)") }
            XCTAssertEqual(rig.manager.appChannels.first { $0.index == 0 }?.name, "p1",
                           "until the radio confirms the new one the old entry is as it was")

            rig.radio.releaseAnswers()
            await rig.settle()

            let entry = rig.manager.appChannels.first { $0.index == 0 }
            XCTAssertEqual(entry?.name, "p2")
            XCTAssertEqual(entry?.pskHex, hex(RadioFixtures.otherKey))
            XCTAssertEqual(entry?.effectiveState, .onRadio)
        }
    }

    func testAnEntryAnEarlierVersionSavedIsAdoptedWhenTheRadioHoldsThatChannel() async throws {
        try await withRig { rig in
            // Saved by a build that recorded neither the radio nor a state.
            let legacy = MeshtasticManager.StoredChannel(
                index: 1, name: "used1", pskHex: hex(RadioFixtures.otherKey), isPrimary: false)
            rig.manager.appChannels = [legacy]
            XCTAssertEqual(rig.manager.standing(of: legacy).label, "saved earlier, not checked against a radio")

            rig.download(channels: slots(used: [1]))      // slot 1: "used1" with otherKey

            let adopted = try XCTUnwrap(rig.manager.appChannels.first)
            XCTAssertEqual(rig.manager.appChannels.count, 1)
            XCTAssertEqual(adopted.nodeNum, WriteRig.nodeNum)
            XCTAssertEqual(adopted.effectiveState, .onRadio)
            XCTAssertEqual(rig.manager.standing(of: adopted).label, "on the radio")
            XCTAssertTrue(rig.manager.standing(of: adopted).onRadio)
        }
    }

    func testAnEntryAnEarlierVersionSavedIsAlsoAdoptedFromAnAnswerToARead() async throws {
        try await withRig { rig in
            rig.download(channels: slots(used: []))
            let legacy = MeshtasticManager.StoredChannel(
                index: 3, name: "later", pskHex: hex(RadioFixtures.otherKey), isPrimary: false)
            rig.manager.appChannels = [legacy]
            XCTAssertEqual(rig.manager.standing(of: legacy).label, "saved earlier, not on the connected radio")
            // The radio gets that channel in slot 3 (from another app), and is read again.
            rig.radio.set(channel: RadioFixtures.channel(index: 3, name: "later", psk: RadioFixtures.otherKey), at: 3)

            _ = await rig.manager.rereadFromRadio()

            XCTAssertEqual(rig.manager.appChannels.first?.nodeNum, WriteRig.nodeNum)
            XCTAssertEqual(rig.manager.appChannels.first?.effectiveState, .onRadio)
        }
    }

    func testAnEntryAnEarlierVersionSavedThatTheRadioDoesNotHoldIsNotAdoptedAndSaysSo() async throws {
        try await withRig { rig in
            let legacy = MeshtasticManager.StoredChannel(
                index: 1, name: "gone", pskHex: hex(RadioFixtures.key), isPrimary: false)
            rig.manager.appChannels = [legacy]

            rig.download(channels: slots(used: [1]))      // slot 1 holds "used1", not "gone"

            let entry = try XCTUnwrap(rig.manager.appChannels.first)
            XCTAssertNil(entry.nodeNum)
            XCTAssertEqual(rig.manager.standing(of: entry).label, "saved earlier, not on the connected radio")
            XCTAssertFalse(rig.manager.standing(of: entry).onRadio)
        }
    }

    func testASavedOnlyCreateDoesNotReplaceAnEntryAnEarlierVersionSaved() async throws {
        try await withRig { rig in
            let legacy = MeshtasticManager.StoredChannel(
                index: 1, name: "bravo", pskHex: hex(RadioFixtures.otherKey), isPrimary: false)
            rig.manager.appChannels = [legacy]
            rig.manager.disconnect()

            let outcome = await rig.manager.createChannel(
                name: "bravo", keyText: hex(RadioFixtures.key), noEncryption: false, replacePrimary: false)

            XCTAssertTrue(outcome.savedOnly)
            let list = rig.manager.appChannels
            XCTAssertEqual(list.count, 2)
            XCTAssertTrue(list.contains { $0.index == 1 && $0.pskHex == hex(RadioFixtures.otherKey) },
                          "the older entry, and its key, is still there")
            XCTAssertTrue(list.contains { $0.index == -1 && $0.pskHex == hex(RadioFixtures.key) })
        }
    }

    func testASecondSavedOnlyCreateOfTheSameNameIsStillOneEntry() async {
        await withRig { rig in
            rig.manager.disconnect()
            _ = await rig.manager.createChannel(name: "bravo", keyText: hex(RadioFixtures.key), noEncryption: false, replacePrimary: false)
            _ = await rig.manager.createChannel(name: "bravo", keyText: hex(RadioFixtures.otherKey), noEncryption: false, replacePrimary: false)
            XCTAssertEqual(rig.manager.appChannels.count, 1)
            XCTAssertEqual(rig.manager.appChannels.first?.pskHex, hex(RadioFixtures.otherKey))
        }
    }

    func testACreateOfAnAdoptedChannelIsNotMadeASecondTime() async {
        await withRig { rig in
            let legacy = MeshtasticManager.StoredChannel(
                index: 1, name: "used1", pskHex: hex(RadioFixtures.otherKey), isPrimary: false)
            rig.manager.appChannels = [legacy]
            rig.download(channels: slots(used: [1]))

            let outcome = await create(rig, "used1", key: hex(RadioFixtures.otherKey))

            XCTAssertEqual(outcome, MeshtasticManager.ChannelOutcome(result: .unchanged, slot: 1))
            XCTAssertEqual(rig.manager.appChannels.count, 1)
        }
    }

    func testAChannelSavedForSharingBecomesTheRadiosWhenTheRadioHoldsIt() async throws {
        try await withRig { rig in
            rig.manager.appChannels = [MeshtasticManager.StoredChannel(
                index: -1, name: "used1", pskHex: hex(RadioFixtures.otherKey), isPrimary: false, nodeNum: nil, state: .savedOnly)]

            rig.download(channels: slots(used: [1]))      // slot 1: "used1" with otherKey

            let list = rig.manager.appChannels
            XCTAssertEqual(list.count, 1)
            XCTAssertEqual(list.first?.index, 1)
            XCTAssertEqual(list.first?.nodeNum, WriteRig.nodeNum)
            XCTAssertEqual(list.first?.effectiveState, .onRadio)
            XCTAssertEqual(rig.manager.standing(of: try XCTUnwrap(list.first)).label, "on the radio")
        }
    }

    func testWritingAChannelThatWasSavedForSharingLeavesOneEntryAndNotATwin() async {
        await withRig { rig in
            rig.manager.appChannels = [MeshtasticManager.StoredChannel(
                index: -1, name: "fresh", pskHex: hex(RadioFixtures.key), isPrimary: false, nodeNum: nil, state: .savedOnly)]
            rig.download(channels: slots(used: []))

            let outcome = await create(rig, "fresh")

            XCTAssertEqual(outcome.result, .applied)
            let list = rig.manager.appChannels
            XCTAssertEqual(list.count, 1, "the channel is listed once")
            XCTAssertEqual(list.first?.nodeNum, WriteRig.nodeNum)
            XCTAssertEqual(list.first?.effectiveState, .onRadio)
        }
    }

    func testJoiningALinkThatWasSavedForSharingPutsItOnTheRadioAndListsEachChannelOnce() async {
        await withRig { rig in
            let channels = (0..<3).map { MeshChannel(name: "ops\($0)", psk: RadioFixtures.key) }
            rig.manager.appChannels = channels.map {
                MeshtasticManager.StoredChannel(
                    index: -1, name: $0.name, pskHex: hex($0.psk), isPrimary: false, nodeNum: nil, state: .savedOnly)
            }
            rig.download(channels: slots(used: []))

            let outcome = await rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.confirmed, [1, 2, 3])
            let list = rig.manager.appChannels
            XCTAssertEqual(list.count, 3, "the saved-only entries became the radio's, with no twins")
            XCTAssertTrue(list.allSatisfy { $0.nodeNum == WriteRig.nodeNum && $0.effectiveState == .onRadio })
        }
    }

    func testAChannelSavedForSharingThatTheRadioDoesNotHoldStaysSavedOnly() async {
        await withRig { rig in
            rig.manager.appChannels = [MeshtasticManager.StoredChannel(
                index: -1, name: "mine", pskHex: hex(RadioFixtures.key), isPrimary: false, nodeNum: nil, state: .savedOnly)]
            rig.download(channels: slots(used: [1, 2]))
            XCTAssertEqual(rig.manager.appChannels.first?.nodeNum, nil)
            XCTAssertEqual(rig.manager.appChannels.first?.effectiveState, .savedOnly)
            XCTAssertEqual(rig.manager.standing(of: rig.manager.appChannels[0]).label, "saved only, not on a radio")
        }
    }

    // MARK: - Joining with no radio connected

    func testJoiningWithNoRadioConnectedKeepsTheChannelsForSharingAndSaysSo() async {
        await withRig { rig in
            rig.manager.disconnect()
            let outcome = await rig.manager.importChannels([
                MeshChannel(name: "alpha", psk: RadioFixtures.key),
                MeshChannel(name: "open", psk: Data([0])),
                MeshChannel(name: "badkey", psk: Data(repeating: 1, count: 20)),
            ])

            XCTAssertEqual(outcome.savedOnly, 2)
            XCTAssertEqual(outcome.skipped.count, 1)
            XCTAssertNil(outcome.refusal)
            XCTAssertTrue(outcome.sent.isEmpty)
            let list = rig.manager.appChannels
            XCTAssertEqual(list.count, 2)
            XCTAssertTrue(list.allSatisfy { $0.index == -1 && $0.nodeNum == nil && $0.effectiveState == .savedOnly })
            XCTAssertEqual(list.first { $0.name == "open" }?.pskHex, "00", "an open channel is saved as the one byte 0")
            XCTAssertEqual(rig.manager.standing(of: list[0]).label, "saved only, not on a radio")
            let text = MeshtasticSettingsMessages.importSummary(outcome, total: 3)
            XCTAssertTrue(text.contains("not on a radio"), text)
            XCTAssertFalse(text.contains("Imported"), text)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    // MARK: - The name Default

    func testAChannelNamedDefaultIsStoredByTheRadioWithNoNameAndIsStillApplied() async throws {
        try await withRig { rig in
            rig.download()

            let outcome = await create(rig, "Default")

            XCTAssertEqual(outcome.result, .applied, "keeping the name Default as no name is not keeping its own value")
            XCTAssertEqual(rig.manager.channelReports.first?.state, .applied)
            let held = try XCTUnwrap(rig.manager.radioSettings.channelSummary(index: 2))
            XCTAssertEqual(held.name, "", "that is what the radio holds")
            let entry = try XCTUnwrap(rig.manager.appChannels.first)
            XCTAssertEqual(entry.name, "Default")
            XCTAssertTrue(rig.manager.standing(of: entry).onRadio)
            XCTAssertTrue(MeshtasticSettingsMessages.create(outcome, name: "Default").contains("keeps the name Default as no name"))

            // The same channel again is not a second copy.
            let again = await create(rig, "Default")
            XCTAssertEqual(again, MeshtasticManager.ChannelOutcome(result: .unchanged, slot: 2))
        }
    }

    func testAnImportOfAChannelNamedDefaultIsConfirmed() async {
        await withRig { rig in
            rig.download(channels: slots(used: []))
            let outcome = await rig.manager.importChannels([MeshChannel(name: "Default", psk: RadioFixtures.key)])
            XCTAssertEqual(outcome.confirmed, [1])
            XCTAssertTrue(outcome.unconfirmed.isEmpty)
        }
    }

    // MARK: - A link lost before a channel write goes

    func testAChannelWriteWhoseLinkWasLostWhileItWaitedItsTurnDoesNotPutTheSlotBackOnTheOldLink() async {
        await withRig { rig in
            rig.download()
            rig.manager.frameSpacing = 0.3
            // The link is lost while the write waits its turn after the read.
            rig.link.onSent = { kind in
                guard kind == .getChannel(index: 2) else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { rig.manager.handleLinkDown(.tcp) }
            }

            let outcome = await create(rig, "delta")

            XCTAssertEqual(outcome.result, .linkChangedRefusal)
            XCTAssertTrue(rig.link.sets.isEmpty)
            XCTAssertTrue(rig.manager.radioSettings.isEmpty, "the slot the radio reported on a link that is gone is not put back")
            XCTAssertTrue(rig.manager.pendingChannelWrites.isEmpty)
            XCTAssertTrue(rig.manager.channelReports.isEmpty)
            XCTAssertTrue(rig.manager.appChannels.isEmpty, "nothing was sent, so no entry stays")
        }
    }

    func testALinkLostRightAfterTheSlotWasReadMarksNothingAndSendsNothing() async {
        await withRig { rig in
            rig.download()
            // The link is heard to drop right after the answer to the read is taken.
            rig.link.onSent = { kind in
                if kind == .getChannel(index: 2) {
                    DispatchQueue.main.async { rig.manager.handleLinkDown(.tcp) }
                }
            }

            let outcome = await create(rig, "delta")
            await rig.settle()

            XCTAssertEqual(outcome.result, .linkChangedRefusal)
            XCTAssertEqual(rig.link.kinds, [.getChannel(index: 2)])
            XCTAssertTrue(rig.manager.radioSettings.isEmpty, "the slot was not marked as waiting on a connection that is gone")
            XCTAssertTrue(rig.manager.pendingChannelWrites.isEmpty)
            XCTAssertTrue(rig.manager.appChannels.isEmpty)
        }
    }

    // MARK: - A write that is not settled

    func testDisconnectingWhileAChannelWriteWaitsLeavesTheEntryNotConfirmedAndNotWaiting() async throws {
        try await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            rig.manager.answerTimeout = 30
            let manager = rig.manager
            let task = Task { await manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                          noEncryption: false, replacePrimary: false) }
            while !rig.link.kinds.contains(.setChannel(index: 2)) || rig.link.kinds.last != .getChannel(index: 2) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }

            manager.disconnect()
            _ = await task.value

            let entry = try XCTUnwrap(manager.appChannels.first { $0.name == "delta" })
            XCTAssertEqual(entry.effectiveState, .notConfirmed, "nothing is waiting for the radio any more")
            XCTAssertEqual(manager.standing(of: entry).label, "not confirmed by the radio")
            XCTAssertTrue(manager.channelReports.isEmpty)
        }
    }

    func testTheDownloadAfterALinkWasLostSettlesTheLineUnderChannelWrites() async throws {
        try await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            rig.manager.answerTimeout = 30
            let manager = rig.manager
            let task = Task { await manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                          noEncryption: false, replacePrimary: false) }
            while !rig.link.kinds.contains(.setChannel(index: 2)) || rig.link.kinds.last != .getChannel(index: 2) {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            manager.handleLinkDown(.tcp)
            _ = await task.value
            XCTAssertEqual(manager.channelReports.first?.state, .linkLost)

            rig.radio.answersGets = true
            rig.reconnect()

            XCTAssertEqual(manager.channelReports.first?.state, .applied, "the line changes once the radio reports the slot")
            XCTAssertEqual(manager.appChannels.first { $0.name == "delta" }?.effectiveState, .onRadio)
            XCTAssertTrue(manager.pendingChannelWrites.isEmpty)
        }
    }

    func testAnotherRadioReportingInDropsAnUnsettledChannelWrite() async {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            rig.manager.answerTimeout = 0.2
            _ = await create(rig, "delta")
            XCTAssertFalse(rig.manager.pendingChannelWrites.isEmpty)

            rig.chooseAnotherRadio(node: 0x0D0E_0F10)
            rig.download()

            XCTAssertTrue(rig.manager.pendingChannelWrites.isEmpty)
            XCTAssertTrue(rig.manager.channelReports.isEmpty)
        }
    }

    // MARK: - Over the real link

    private let savedHostsKey = "meshtastic_saved_hosts"

    private func realLink(_ radio: LoopbackRadio, body: (MeshtasticManager) async throws -> Void) async throws {
        // connectTCP remembers the host and a channel write remembers the
        // channel, in the app's defaults. Put both back.
        let channelsKey = "meshtastic_app_channels"
        let savedHosts = UserDefaults.standard.object(forKey: savedHostsKey)
        let savedChannels = UserDefaults.standard.object(forKey: channelsKey)
        defer {
            for (key, value) in [(savedHostsKey, savedHosts), (channelsKey, savedChannels)] {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        let port = try await radio.start()
        defer { radio.stop() }
        let manager = MeshtasticManager()
        manager.appChannels = []
        manager.connectTCP(host: "127.0.0.1", port: port)
        defer { manager.disconnect() }
        let end = Date().addingTimeInterval(5)
        while Date() < end, !(manager.isConnected && manager.radioSettings.hasPositionConfig) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(manager.radioSettings.hasPositionConfig, "the download did not arrive")
        try await body(manager)
    }

    func testAChannelCreatedOverTheRealLinkIsAppliedWhenTheRadioAnswers() async throws {
        let radio = LoopbackRadio(nodeNum: 0x0000_AAAA)
        try await realLink(radio) { manager in
            let outcome = await manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                      noEncryption: false, replacePrimary: false)
            XCTAssertEqual(outcome, MeshtasticManager.ChannelOutcome(result: .applied, slot: 2))

            // What the radio received: the slot read, the write, the read-back,
            // all addressed to it, in packets with ids of their own.
            XCTAssertEqual(radio.admin.map(\.kind), [.getChannel(index: 2), .setChannel(index: 2), .getChannel(index: 2)])
            XCTAssertEqual(radio.admin.map(\.to), [radio.nodeNum, radio.nodeNum, radio.nodeNum])
            XCTAssertEqual(radio.admin.map(\.wantResponse), [true, false, true])
            XCTAssertEqual(Set(radio.admin.map(\.packetID)).count, 3, "a packet id each")
            XCTAssertFalse(radio.admin.contains(where: { $0.packetID == 0 }))
            // And what the app holds is what the radio holds.
            XCTAssertEqual(manager.radioSettings.channel(index: 2), radio.channels[2])
        }
    }

    func testARadioThatKeepsItsOwnValueIsReportedAsHavingDoneSoOverTheRealLink() async throws {
        let radio = LoopbackRadio(nodeNum: 0x0000_AAAA)
        radio.appliesChannelWrites = false
        try await realLink(radio) { manager in
            let outcome = await manager.createChannel(name: "renamed", keyText: "", noEncryption: false, replacePrimary: true)
            XCTAssertEqual(outcome.slot, 0)
            XCTAssertEqual(outcome.result, .notConfirmed("The radio kept its own value (\"simtest\")."))
            XCTAssertEqual(manager.radioSettings.channelSummary(index: 0)?.name, "simtest")
        }
    }
}
