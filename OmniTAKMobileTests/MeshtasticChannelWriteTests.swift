//
//  MeshtasticChannelWriteTests.swift
//  OmniTAKMobileTests
//
//  #148 for channels: what the operator typed is never turned into something
//  else, a key is only removed when that is asked for, a new channel goes into a
//  slot the radio says is free, and a channel is only reported applied when the
//  radio's own answer says so.
//
//  The recording link sees what is sent and the radio's answers are fed in by
//  hand. The last tests run the real TCP client and decoder against a radio in
//  the test process (LoopbackRadio), which answers read-backs the way the
//  firmware does. What meshtasticd does is in MeshtasticSimulatedRadioTests.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

final class MeshtasticChannelWriteTests: XCTestCase {

    private typealias Codec = MeshtasticAdminCodec

    /// The Channel inside the set_channel of a write.
    private func channel(of write: RecordingLink.Sent,
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

    // MARK: - Where a new channel goes

    @MainActor
    func testACreatedChannelGoesIntoTheFirstSlotTheRadioReportsAsDisabled() throws {
        try withRig { rig in
            rig.download(channels: slots(used: [1, 2]))       // 0 primary, 1 and 2 in use, 3 to 7 free

            let outcome = rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                    noEncryption: false, replacePrimary: false)

            XCTAssertEqual(outcome, MeshtasticManager.ChannelOutcome(result: .sent, slot: 3))
            let written = try channel(of: try XCTUnwrap(rig.link.writes.first))
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.index, in: written), 3)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: written), RadioProto.ChannelRole.secondary)
            let inner = try settings(of: written)
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: inner), Data("delta".utf8))
            XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner) == RadioFixtures.key)
        }
    }

    @MainActor
    func testACreatedChannelNeverOverwritesASlotInUseOrThePrimary() throws {
        try withRig { rig in
            rig.download(channels: slots(used: [1, 2, 3, 4, 5, 6]))   // only 7 is free

            XCTAssertEqual(rig.manager.createChannel(name: "one", keyText: WriteRig.hex(RadioFixtures.key),
                                                     noEncryption: false, replacePrimary: false).slot, 7)

            // 7 is spoken for now, and nothing is free: every slot is in use or
            // waiting for the radio's answer.
            let again = rig.manager.createChannel(name: "two", keyText: WriteRig.hex(RadioFixtures.key),
                                                  noEncryption: false, replacePrimary: false)
            XCTAssertNil(again.slot)
            XCTAssertEqual(again.result.refusal, "No free channel slot. All seven secondary slots on this radio are in use.")

            let indices = try rig.link.writes.map {
                Int(FixtureReader.varint(RadioProto.Channel.index, in: try channel(of: $0)) ?? 0)
            }
            XCTAssertEqual(indices, [7], "one write, to the one free slot, and none to slot 0 or a slot in use")
        }
    }

    @MainActor
    func testACreatedChannelInheritsNothingFromTheSlotsOldOccupant() throws {
        try withRig { rig in
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

            let outcome = rig.manager.createChannel(name: "fresh", keyText: WriteRig.hex(RadioFixtures.key),
                                                    noEncryption: false, replacePrimary: false)
            XCTAssertEqual(outcome.slot, 3)

            let written = try channel(of: try XCTUnwrap(rig.link.writes.first))
            XCTAssertEqual(FixtureReader.fields(written)?.map(\.number), [1, 2, 3], "index, settings, role")
            let inner = try settings(of: written)
            XCTAssertEqual(FixtureReader.fields(inner)?.map(\.number), [RadioProto.ChannelSettings.psk, RadioProto.ChannelSettings.name],
                           "a key and a name: no id, no uplink, no location precision from the old channel")
            XCTAssertEqual(FixtureReader.bytes(RadioProto.ChannelSettings.name, in: inner), Data("fresh".utf8))
        }
    }

    @MainActor
    func testTheSlotsAreTheRadiosAndNotTheAppsOwnList() {
        withRig { rig in
            // The app's own list says slot 1 is taken; the radio says it is free.
            rig.manager.upsertAppChannel(.init(index: 1, name: "stale", pskHex: "", isPrimary: false))
            rig.download(channels: slots(used: []))

            XCTAssertEqual(rig.manager.createChannel(name: "x", keyText: WriteRig.hex(RadioFixtures.key),
                                                     noEncryption: false, replacePrimary: false).slot, 1)

            // And the other way: the radio's slot 1 is in use though the list is empty.
            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: WriteRig.nodeNum))
            for (index, body) in slots(used: [1]) { rig.manager.handleSettingsEvent(.channel(index: index, body: body.data)) }
            rig.manager.removeAppChannel(index: 1)
            XCTAssertEqual(rig.manager.createChannel(name: "y", keyText: WriteRig.hex(RadioFixtures.key),
                                                     noEncryption: false, replacePrimary: false).slot, 2)
        }
    }

    @MainActor
    func testWithNoFreeSlotNothingIsSentAndTheOperatorIsToldSo() {
        withRig { rig in
            rig.download(channels: slots(used: [1, 2, 3, 4, 5, 6, 7]))
            let outcome = rig.manager.createChannel(name: "x", keyText: WriteRig.hex(RadioFixtures.key),
                                                    noEncryption: false, replacePrimary: false)
            XCTAssertEqual(outcome.result.refusal, "No free channel slot. All seven secondary slots on this radio are in use.")
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    // MARK: - The primary is only replaced on purpose

    @MainActor
    func testReplacingThePrimaryKeepsItsKeyWhenTheKeyFieldIsBlank() throws {
        try withRig { rig in
            rig.download()

            let outcome = rig.manager.createChannel(name: "renamed", keyText: "", noEncryption: false, replacePrimary: true)

            XCTAssertEqual(outcome, MeshtasticManager.ChannelOutcome(result: .sent, slot: 0))
            let written = try channel(of: try XCTUnwrap(rig.link.writes.first))
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

    @MainActor
    func testReplacingThePrimaryWithAKeyChangesTheKeyAndKeepsTheRest() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.createChannel(name: "simtest", keyText: base64(RadioFixtures.otherKey),
                                                     noEncryption: false, replacePrimary: true).result, .sent)

            let inner = try settings(of: try channel(of: try XCTUnwrap(rig.link.writes.first)))
            XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner) == RadioFixtures.otherKey)
            let module = try XCTUnwrap(FixtureReader.bytes(RadioProto.ChannelSettings.moduleSettings, in: inner))
            XCTAssertEqual(FixtureReader.varint(RadioProto.ModuleSettings.positionPrecision, in: module), 13)
        }
    }

    @MainActor
    func testAnOrdinaryCreateNeverWritesTheSlotOfThePrimary() throws {
        try withRig { rig in
            rig.download()
            for name in ["a", "b", "c"] {
                _ = rig.manager.createChannel(name: name, keyText: WriteRig.hex(RadioFixtures.key),
                                              noEncryption: false, replacePrimary: false)
            }
            let indices = try rig.link.writes.map { Int(FixtureReader.varint(RadioProto.Channel.index, in: try channel(of: $0)) ?? 0) }
            XCTAssertFalse(indices.contains(0))
            XCTAssertEqual(indices, [2, 3, 4], "slot 1 is in use on the default radio")
        }
    }

    // MARK: - A key is never removed by accident

    @MainActor
    func testABase64KeyIsAccepted() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.createChannel(name: "b64", keyText: base64(RadioFixtures.key),
                                                     noEncryption: false, replacePrimary: false).result, .sent)
            let inner = try settings(of: try channel(of: try XCTUnwrap(rig.link.writes.first)))
            XCTAssertTrue(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner) == RadioFixtures.key)
        }
    }

    @MainActor
    func testAHexKeyOfEitherLengthIsAccepted() throws {
        try withRig { rig in
            rig.download()
            let short = Data(RadioFixtures.key.prefix(16))
            XCTAssertEqual(rig.manager.createChannel(name: "k16", keyText: WriteRig.hex(short),
                                                     noEncryption: false, replacePrimary: false).result, .sent)
            XCTAssertEqual(rig.manager.createChannel(name: "k32", keyText: WriteRig.hex(RadioFixtures.key),
                                                     noEncryption: false, replacePrimary: false).result, .sent)
            let lengths = try rig.link.writes.map {
                try XCTUnwrap(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: try settings(of: try channel(of: $0)))).count
            }
            XCTAssertEqual(lengths, [16, 32])
        }
    }

    @MainActor
    func testAKeyThatIsNotAKeyIsRefusedAndNothingIsSent() {
        withRig { rig in
            rig.download()
            let bad = [
                "not a key",
                "abc",                                   // odd number of hex digits
                "zz" + WriteRig.hex(RadioFixtures.key),  // not hex, not base64 of a valid length
                base64(Data(repeating: 1, count: 24)),   // base64 of 24 bytes
                WriteRig.hex(Data(repeating: 1, count: 15)),
                WriteRig.hex(Data(repeating: 1, count: 33)),
            ]
            for text in bad {
                let outcome = rig.manager.createChannel(name: "x", keyText: text, noEncryption: false, replacePrimary: false)
                XCTAssertEqual(outcome.result.refusal, MeshtasticChannelKey.invalidMessage, "key \(text.count) characters long")
                let primary = rig.manager.createChannel(name: "x", keyText: text, noEncryption: false, replacePrimary: true)
                XCTAssertEqual(primary.result.refusal, MeshtasticChannelKey.invalidMessage)
            }
            XCTAssertTrue(rig.link.sent.isEmpty, "a typo never becomes an open channel, or a channel without its key")
            XCTAssertTrue(rig.manager.channelReports.isEmpty)
        }
    }

    @MainActor
    func testABlankKeyForANewChannelIsRefusedUnlessNoEncryptionIsChosen() throws {
        try withRig { rig in
            rig.download()
            let blank = rig.manager.createChannel(name: "x", keyText: "  ", noEncryption: false, replacePrimary: false)
            XCTAssertEqual(blank.result.refusal, "Enter a key (hex or base64), or choose No encryption for an open channel.")
            XCTAssertTrue(rig.link.sent.isEmpty)

            let open = rig.manager.createChannel(name: "open", keyText: "", noEncryption: true, replacePrimary: false)
            XCTAssertEqual(open.result, .sent)
            let inner = try settings(of: try channel(of: try XCTUnwrap(rig.link.writes.first)))
            XCTAssertNil(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner), "an open channel, on purpose")
        }
    }

    @MainActor
    func testAKeyAndNoEncryptionTogetherIsRefused() {
        withRig { rig in
            rig.download()
            let outcome = rig.manager.createChannel(name: "x", keyText: WriteRig.hex(RadioFixtures.key),
                                                    noEncryption: true, replacePrimary: false)
            XCTAssertEqual(outcome.result.refusal, "Enter a key or choose No encryption, not both.")
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    @MainActor
    func testRemovingThePrimarysKeyIsAnExplicitChoice() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.createChannel(name: "simtest", keyText: "", noEncryption: true, replacePrimary: true).result, .sent)
            let inner = try settings(of: try channel(of: try XCTUnwrap(rig.link.writes.first)))
            XCTAssertNil(FixtureReader.bytes(RadioProto.ChannelSettings.psk, in: inner))
        }
    }

    @MainActor
    func testANameOverElevenBytesIsRefusedAndTheOperatorIsToldWhy() {
        withRig { rig in
            rig.download()
            let twelve = "abcdefghijkl"
            let outcome = rig.manager.createChannel(name: twelve, keyText: WriteRig.hex(RadioFixtures.key),
                                                    noEncryption: false, replacePrimary: false)
            XCTAssertEqual(outcome.result.refusal,
                           "Channel names are at most 11 bytes. \"abcdefghijkl\" is 12. The radio would drop the whole message.")
            XCTAssertTrue(rig.link.sent.isEmpty)

            // Bytes, not characters: six two-byte characters are twelve bytes.
            let accents = rig.manager.createChannel(name: "éééééé", keyText: WriteRig.hex(RadioFixtures.key),
                                                    noEncryption: false, replacePrimary: false)
            XCTAssertNotNil(accents.result.refusal)

            let eleven = rig.manager.createChannel(name: "abcdefghijk", keyText: WriteRig.hex(RadioFixtures.key),
                                                   noEncryption: false, replacePrimary: false)
            XCTAssertEqual(eleven.result, .sent)
        }
    }

    @MainActor
    func testTheWorkingSetOnlyHoldsChannelsWhoseKeyIsKnown() {
        withRig { rig in
            rig.download()
            let before = rig.manager.appChannels
            _ = rig.manager.createChannel(name: "kept", keyText: "", noEncryption: false, replacePrimary: true)
            XCTAssertEqual(rig.manager.appChannels, before, "a kept key is not known to the app, so it is not listed or shared")
            _ = rig.manager.createChannel(name: "bad", keyText: "nope", noEncryption: false, replacePrimary: false)
            XCTAssertEqual(rig.manager.appChannels, before, "a refused channel is not saved")

            _ = rig.manager.createChannel(name: "good", keyText: WriteRig.hex(RadioFixtures.key), noEncryption: false, replacePrimary: false)
            XCTAssertEqual(rig.manager.appChannels.filter { $0.name == "good" }.map(\.index), [2])
        }
    }

    // MARK: - Import

    @MainActor
    func testImportGoesIntoFreeSlotsInOrderAndNeverOverwritesOne() throws {
        try withRig { rig in
            rig.download(channels: slots(used: [1, 3]))      // free: 2, 4, 5, 6, 7
            let channels = (0..<3).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.sent, [2, 4, 5])
            XCTAssertEqual(outcome.noRoom, 0)
            XCTAssertNil(outcome.refusal)
            let indices = try rig.link.writes.map { Int(FixtureReader.varint(RadioProto.Channel.index, in: try channel(of: $0)) ?? 0) }
            XCTAssertEqual(indices, [2, 4, 5], "never slot 0, 1 or 3")
            // Each is clean and secondary.
            for write in rig.link.writes {
                let written = try channel(of: write)
                XCTAssertEqual(FixtureReader.varint(RadioProto.Channel.role, in: written), RadioProto.ChannelRole.secondary)
                XCTAssertEqual(FixtureReader.fields(try settings(of: written))?.map(\.number),
                               [RadioProto.ChannelSettings.psk, RadioProto.ChannelSettings.name])
            }
        }
    }

    @MainActor
    func testImportWithMoreChannelsThanFreeSlotsSaysSoAndCountsWhatWasSent() {
        withRig { rig in
            rig.download(channels: slots(used: [1, 2, 3, 4]))    // free: 5, 6, 7
            let channels = (0..<8).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.sent, [5, 6, 7])
            XCTAssertEqual(outcome.noRoom, 5)
            XCTAssertEqual(outcome.sent.count + outcome.noRoom + outcome.alreadyThere + outcome.skipped.count, 8,
                           "every channel is accounted for")
            XCTAssertEqual(rig.link.writes.count, 3)
        }
    }

    @MainActor
    func testImportOfNineChannelsOnARadioWithOnlyAPrimaryReportsSevenSentAndTwoLeftOut() {
        withRig { rig in
            rig.download(channels: slots(used: []))
            let channels = (0..<9).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) }

            let outcome = rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.sent, [1, 2, 3, 4, 5, 6, 7])
            XCTAssertEqual(outcome.noRoom, 2, "the old code reported seven applied and said nothing about the rest")
        }
    }

    @MainActor
    func testImportDoesNotAddAChannelTheRadioAlreadyHasOrAddTheSameOneTwice() {
        withRig { rig in
            rig.download(channels: slots(used: [1]))     // slot 1: "used1" with otherKey
            let channels = [
                MeshChannel(name: "used1", psk: RadioFixtures.otherKey),  // already there
                MeshChannel(name: "fresh", psk: RadioFixtures.key),
                MeshChannel(name: "fresh", psk: RadioFixtures.key),       // the same again, in the same set
            ]

            let outcome = rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.sent, [2])
            XCTAssertEqual(outcome.alreadyThere, 2)
            XCTAssertEqual(rig.link.writes.count, 1)
        }
    }

    @MainActor
    func testImportLeavesOutAChannelThatCannotBeWrittenAndSaysWhy() {
        withRig { rig in
            rig.download(channels: slots(used: []))
            let channels = [
                MeshChannel(name: "abcdefghijkl", psk: RadioFixtures.key),
                MeshChannel(name: "badkey", psk: Data(repeating: 1, count: 20)),
                MeshChannel(name: "fine", psk: RadioFixtures.key),
            ]

            let outcome = rig.manager.importChannels(channels)

            XCTAssertEqual(outcome.sent, [1])
            XCTAssertEqual(outcome.skipped.count, 2)
            XCTAssertTrue(outcome.skipped[0].contains("at most 11 bytes"))
            XCTAssertTrue(outcome.skipped[1].contains("1, 16 or 32 bytes"))
        }
    }

    @MainActor
    func testImportWithTheRadioNotLoadedIsRefusedWhole() {
        withRig { rig in
            rig.download(node: nil)
            let outcome = rig.manager.importChannels([MeshChannel(name: "x", psk: RadioFixtures.key)])
            XCTAssertEqual(outcome.refusal, MeshtasticWriteResult.notLoaded)
            XCTAssertTrue(outcome.sent.isEmpty)
            XCTAssertTrue(rig.link.sent.isEmpty)
        }
    }

    // MARK: - Said to be applied only when the radio says so

    @MainActor
    func testAChannelWriteIsFollowedByAReadBackRequestForThatSlot() throws {
        try withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                     noEncryption: false, replacePrimary: false).slot, 2)

            XCTAssertEqual(rig.link.writes.count, 1)
            XCTAssertEqual(rig.link.requests.count, 1)
            let request = try XCTUnwrap(rig.link.requests.first)
            XCTAssertTrue(request.wantResponse, "the radio only answers a request that asks for an answer")
            XCTAssertEqual(request.node, WriteRig.nodeNum)
            XCTAssertEqual(request.connection, rig.link.connectionSerial)
            // AdminMessage.get_channel_request is field 1, the index plus one.
            XCTAssertEqual(request.payload, Data([0x08, 0x03]))
        }
    }

    @MainActor
    func testAChannelIsOnlySentUntilTheRadioAnswers() {
        withRig { rig in
            rig.download()
            _ = rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                          noEncryption: false, replacePrimary: false)

            XCTAssertEqual(rig.manager.channelReports, [MeshtasticChannelReport(slot: 2, name: "delta", state: .sent)])
            XCTAssertEqual(rig.manager.channelReports.first?.text, "Slot 2 \"delta\": sent, waiting for the radio to confirm.")
            XCTAssertNil(rig.manager.radioSettings.channel(index: 2), "what was sent is not taken for what the radio holds")
            XCTAssertTrue(rig.manager.radioSettings.isAwaitingReadBack(index: 2))
            XCTAssertFalse(rig.manager.radioSettings.freeChannelSlots.contains(2), "and the slot is not free")
        }
    }

    @MainActor
    func testAnAnswerThatMatchesMakesItAppliedAndRefillsTheSettings() {
        withRig { rig in
            rig.download()
            _ = rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                          noEncryption: false, replacePrimary: false)

            let answer = ProtoFixture()
                .varint(RadioProto.Channel.index, 2)
                .message(RadioProto.Channel.settings, ProtoFixture()
                    .bytes(RadioProto.ChannelSettings.psk, RadioFixtures.key)
                    .string(RadioProto.ChannelSettings.name, "delta"))
                .varint(RadioProto.Channel.role, RadioProto.ChannelRole.secondary)
            rig.answer(answer)

            XCTAssertEqual(rig.manager.channelReports, [MeshtasticChannelReport(slot: 2, name: "delta", state: .applied)])
            XCTAssertEqual(rig.manager.radioSettings.channel(index: 2), answer.data, "the radio's own answer is what is held")
            XCTAssertFalse(rig.manager.radioSettings.isAwaitingReadBack(index: 2))
        }
    }

    @MainActor
    func testAnAnswerThatDiffersMeansTheRadioKeptItsOwnValue() {
        withRig { rig in
            rig.download()
            _ = rig.manager.createChannel(name: "simtest2", keyText: "", noEncryption: false, replacePrimary: true)

            // The radio still has the old name in slot 0.
            rig.answer(RadioFixtures.channel(index: 0, name: "simtest", role: RadioProto.ChannelRole.primary))

            XCTAssertEqual(rig.manager.channelReports,
                           [MeshtasticChannelReport(slot: 0, name: "simtest2", state: .radioKept("simtest"))])
            XCTAssertEqual(rig.manager.channelReports.first?.text,
                           "Slot 0 \"simtest2\": the radio kept its own value (\"simtest\").")
            XCTAssertEqual(rig.manager.radioSettings.channelSummary(index: 0)?.name, "simtest", "and that is what is held")
        }
    }

    @MainActor
    func testAKeyThatDiffersIsNotApplied() {
        withRig { rig in
            rig.download()
            _ = rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                          noEncryption: false, replacePrimary: false)
            // The name is right and the key is not what was sent.
            rig.answer(RadioFixtures.channel(index: 2, name: "delta", psk: RadioFixtures.otherKey))
            XCTAssertEqual(rig.manager.channelReports.first?.state, .radioKept("delta"))
        }
    }

    @MainActor
    func testAnAnswerFromAnotherNodeIsIgnored() {
        withRig { rig in
            rig.download()
            _ = rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                          noEncryption: false, replacePrimary: false)

            rig.answer(RadioFixtures.channel(index: 2, name: "delta", psk: RadioFixtures.key), from: 0x0F0F_0F0F)

            XCTAssertEqual(rig.manager.channelReports.first?.state, .sent, "not the radio these settings are from")
            XCTAssertNil(rig.manager.radioSettings.channel(index: 2))
        }
    }

    @MainActor
    func testAnAnswerForAnotherSlotDoesNotSettleThisOne() {
        withRig { rig in
            rig.download()
            _ = rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                          noEncryption: false, replacePrimary: false)
            rig.answer(RadioFixtures.channel(index: 4, name: "delta", psk: RadioFixtures.key))
            XCTAssertEqual(rig.manager.channelReports.first?.state, .sent)
            XCTAssertTrue(rig.manager.radioSettings.isAwaitingReadBack(index: 2))
        }
    }

    @MainActor
    func testAnAnswerThatNeverComesIsReported() async throws {
        let rig = WriteRig()
        defer { rig.restore() }
        rig.manager.readBackTimeout = 0.1
        rig.download()
        _ = rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                      noEncryption: false, replacePrimary: false)

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(rig.manager.channelReports.first?.state, .noAnswer)
        XCTAssertEqual(rig.manager.channelReports.first?.text,
                       "Slot 2 \"delta\": the radio did not confirm. The change may not have been applied.")
    }

    @MainActor
    func testARequestTheLinkRefusedIsReportedAtOnce() {
        withRig { rig in
            rig.download()
            rig.link.acceptsRequests = false
            _ = rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                          noEncryption: false, replacePrimary: false)
            XCTAssertEqual(rig.manager.channelReports.first?.state, .noAnswer)
            XCTAssertEqual(rig.link.writes.count, 1, "the write went; only the read-back could not be asked for")
        }
    }

    @MainActor
    func testALinkThatDropsWhileWaitingReportsNoAnswer() {
        withRig { rig in
            rig.download()
            _ = rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                          noEncryption: false, replacePrimary: false)

            rig.manager.handleLinkDown(.tcp)

            XCTAssertEqual(rig.manager.channelReports.first?.state, .noAnswer)
        }
    }

    @MainActor
    func testASlotWaitingForTheRadioCannotBeWrittenAgainUntilItAnswers() {
        withRig { rig in
            rig.download()
            XCTAssertEqual(rig.manager.createChannel(name: "one", keyText: "", noEncryption: false, replacePrimary: true).slot, 0)

            let second = rig.manager.createChannel(name: "two", keyText: "", noEncryption: false, replacePrimary: true)

            XCTAssertEqual(second.result.refusal, "Slot 0 was just written. Wait for the radio to confirm it.")
            XCTAssertEqual(rig.link.writes.count, 1)
        }
    }

    @MainActor
    func testAnUnchangedChannelIsNotSentAndNothingIsDropped() {
        withRig { rig in
            rig.download()
            let outcome = rig.manager.createChannel(name: "simtest", keyText: "", noEncryption: false, replacePrimary: true)
            XCTAssertEqual(outcome.result, .unchanged)
            XCTAssertTrue(rig.link.sent.isEmpty)
            XCTAssertNotNil(rig.manager.radioSettings.channel(index: 0))
        }
    }

    // MARK: - Over the real link

    private let savedHostsKey = "meshtastic_saved_hosts"

    @MainActor
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
        manager.connectTCP(host: "127.0.0.1", port: port)
        defer { manager.disconnect() }
        let end = Date().addingTimeInterval(5)
        while Date() < end, !(manager.isConnected && manager.radioSettings.hasPositionConfig) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(manager.radioSettings.hasPositionConfig, "the download did not arrive")
        try await body(manager)
    }

    @MainActor
    private func waitForReport(_ manager: MeshtasticManager, slot: Int) async throws -> MeshtasticChannelReport.State? {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if let report = manager.channelReports.first(where: { $0.slot == slot }), report.state != .sent {
                return report.state
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return manager.channelReports.first(where: { $0.slot == slot })?.state
    }

    @MainActor
    func testAChannelCreatedOverTheRealLinkIsAppliedWhenTheRadioAnswers() async throws {
        let radio = LoopbackRadio(nodeNum: 0x0000_AAAA)
        try await realLink(radio) { manager in
            let outcome = manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                noEncryption: false, replacePrimary: false)
            XCTAssertEqual(outcome.slot, 2)

            let state = try await waitForReport(manager, slot: 2)
            XCTAssertEqual(state, .applied, "the radio's own answer matched")

            // What the radio received: the write, then the read-back request,
            // both addressed to it.
            XCTAssertEqual(radio.channelWrites.count, 1)
            XCTAssertEqual(radio.admin.count, 2)
            XCTAssertEqual(radio.admin.map(\.to), [radio.nodeNum, radio.nodeNum])
            XCTAssertEqual(radio.admin.map(\.wantResponse), [false, true])
            // And what the app holds is what the radio holds.
            XCTAssertEqual(manager.radioSettings.channel(index: 2), radio.channels[2])
        }
    }

    @MainActor
    func testARadioThatKeepsItsOwnValueIsReportedAsHavingDoneSoOverTheRealLink() async throws {
        let radio = LoopbackRadio(nodeNum: 0x0000_AAAA)
        radio.appliesChannelWrites = false
        try await realLink(radio) { manager in
            XCTAssertEqual(manager.createChannel(name: "renamed", keyText: "", noEncryption: false, replacePrimary: true).slot, 0)

            let state = try await waitForReport(manager, slot: 0)
            XCTAssertEqual(state, .radioKept("simtest"))
            XCTAssertEqual(manager.radioSettings.channelSummary(index: 0)?.name, "simtest")
        }
    }
}
