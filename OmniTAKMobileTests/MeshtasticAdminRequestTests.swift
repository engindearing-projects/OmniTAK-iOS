//
//  MeshtasticAdminRequestTests.swift
//  OmniTAKMobileTests
//
//  What the app requires of an answer before it keeps it, and how fast it sends
//  (#148). A get request goes out in a packet with an id the app made up. An
//  answer is kept only when it is from this radio, on this connection, echoes an
//  id that is on the table for the same thing, and carries none of the metadata
//  of a packet that was received by radio. The config download's own frames are
//  not packets and are taken as they come.
//
//  The radio is silent here and the answers are put in by hand, so that each rule
//  can be shown to be the one that kept an answer out. Frames are at least
//  100 ms apart, which a radio that holds four packets for itself and drops the
//  oldest needs.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

@MainActor
final class MeshtasticAdminRequestTests: XCTestCase {

    private typealias Answer = MeshtasticAdminCodec.Answer

    private let position = RadioProto.Config.position
    private let device = RadioProto.Config.device

    /// An interval write waiting for its first answer. The radio says nothing, so
    /// what the manager does is down to what is put in.
    private func startWaitingWrite(_ rig: WriteRig) async -> (task: Task<MeshtasticWriteResult, Never>, request: FakeRadioLink.Sent) {
        rig.radio.answersGets = false
        rig.manager.answerTimeout = 0.3
        let manager = rig.manager
        let task = Task { await manager.applyPositionBroadcastInterval(seconds: 900) }
        while rig.link.gets.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        return (task, rig.link.gets[0])
    }

    private func positionAnswer(
        to request: FakeRadioLink.Sent,
        from node: UInt32 = WriteRig.nodeNum,
        requestId: UInt32? = nil,
        body: ProtoFixture = RadioFixtures.positionConfig()
    ) -> Answer {
        Answer(from: node, requestId: requestId ?? request.packetID, hasReceiveSignals: false,
               content: .config(variant: RadioProto.Config.position, body: body.data))
    }

    // MARK: - What makes an answer one of ours

    func testAnAnswerThatMatchesTheRequestIsKept() async {
        await withRig { rig in
            rig.download()
            let (task, request) = await startWaitingWrite(rig)
            rig.manager.handleSettingsEvent(.answer(positionAnswer(to: request)))
            // It was taken: the write went.
            for _ in 0..<200 where rig.link.sets.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertEqual(rig.link.sets.count, 1)
            _ = await task.value
        }
    }

    func testAnAnswerFromAnotherNodeIsNotKept() async {
        await withRig { rig in
            rig.download()
            let (task, request) = await startWaitingWrite(rig)
            rig.manager.handleSettingsEvent(.answer(positionAnswer(to: request, from: 0x0F0F_0F0F)))
            let result = await task.value
            XCTAssertEqual(result, .noAnswerRefusal)
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }

    func testAnAnswerThatDoesNotEchoTheRequestsIdIsNotKept() async {
        let variants: [(String, (FakeRadioLink.Sent) -> UInt32?)] = [
            ("no id", { _ in nil }),
            ("id 0", { _ in 0 }),
            ("another id", { $0.packetID &+ 1 }),
            ("an id nobody sent", { _ in 12_345 }),
        ]
        for (label, id) in variants {
            await withRig { rig in
                rig.download()
                let (task, request) = await startWaitingWrite(rig)
                let answer = Answer(from: WriteRig.nodeNum, requestId: id(request), hasReceiveSignals: false,
                                    content: .config(variant: position, body: RadioFixtures.positionConfig().data))
                rig.manager.handleSettingsEvent(.answer(answer))
                let result = await task.value
                XCTAssertEqual(result, .noAnswerRefusal, label)
                XCTAssertTrue(rig.link.sets.isEmpty, label)
            }
        }
    }

    func testAnAnswerForAnotherThingIsNotKeptEvenWithTheRightId() async {
        await withRig { rig in
            rig.download()
            let (task, request) = await startWaitingWrite(rig)
            let deviceAnswer = Answer(from: WriteRig.nodeNum, requestId: request.packetID, hasReceiveSignals: false,
                                      content: .config(variant: device, body: RadioFixtures.deviceConfig().data))
            let channelAnswer = Answer(from: WriteRig.nodeNum, requestId: request.packetID, hasReceiveSignals: false,
                                       content: .channel(index: 0, body: RadioFixtures.channelSlots()[0]!.data))
            rig.manager.handleSettingsEvent(.answer(deviceAnswer))
            rig.manager.handleSettingsEvent(.answer(channelAnswer))
            let result = await task.value
            XCTAssertEqual(result, .noAnswerRefusal)
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }

    func testAnAnswerForAnotherSlotIsNotKept() async {
        await withRig { rig in
            rig.download()
            rig.radio.answersGets = false
            rig.manager.answerTimeout = 0.3
            let manager = rig.manager
            let task = Task { await manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                          noEncryption: false, replacePrimary: false) }
            while rig.link.gets.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            let request = rig.link.gets[0]          // slot 2
            let other = RadioFixtures.disabledChannel(index: 5)
            manager.handleSettingsEvent(.answer(Answer(
                from: WriteRig.nodeNum, requestId: request.packetID, hasReceiveSignals: false,
                content: .channel(index: 5, body: other.data))))

            let outcome = await task.value
            XCTAssertEqual(outcome.result, .noAnswerRefusal)
            XCTAssertTrue(rig.link.sets.isEmpty)
        }
    }

    // MARK: - Nothing that shows it was received by radio

    func testAnAnswerThatCarriesAnyReceiveMetadataIsNotKept() async {
        let variants: [(String, (inout SimulatedRadioModel.Signals) -> Void)] = [
            ("signal strength", { $0.rxRssi = -80 }),
            ("signal-to-noise ratio", { $0.rxSnr = 6.5 }),
            ("MQTT flag", { $0.viaMqtt = true }),
            ("transport mechanism", { $0.transportMechanism = 1 }),
        ]
        for (label, mutate) in variants {
            await withRig { rig in
                rig.download()
                var signals = SimulatedRadioModel.Signals()
                mutate(&signals)
                rig.radio.signals = signals
                rig.manager.answerTimeout = 0.2

                let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

                XCTAssertEqual(result, .noAnswerRefusal, label)
                XCTAssertTrue(rig.link.sets.isEmpty, label)
            }
        }
    }

    func testAnAnswerWithNoReceiveMetadataIsKept() async {
        await withRig { rig in
            rig.download()
            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(result, .applied)
        }
    }

    func testTheReceiveFieldsAreRecognisedWhenTheyAreDecodedFromAPacket() {
        // Each of the four is seen in the bytes of a packet, not only in a flag
        // somebody set on a struct.
        func decoded(_ build: (ProtoFixture) -> ProtoFixture) -> Answer? {
            let admin = ProtoFixture().bytes(RadioProto.Admin.getChannelResponse, RadioFixtures.disabledChannel(index: 3).data)
            let data = ProtoFixture()
                .varint(RadioProto.DataMessage.portnum, RadioProto.adminPortnum)
                .bytes(RadioProto.DataMessage.payload, admin.data)
                .fixed32(RadioProto.DataMessage.requestId, 77)
            let packet = build(ProtoFixture()
                .fixed32(RadioProto.MeshPacket.from, 5)
                .fixed32(RadioProto.MeshPacket.to, 5)
                .message(RadioProto.MeshPacket.decoded, data))
            let frame = ProtoFixture().message(RadioProto.FromRadio.packet, packet).data
            guard let payload = MeshtasticProtoDecoder.decodeFromRadio(frame),
                  case .packet(let mesh) = payload else { return nil }
            return MeshtasticAdminCodec.answer(in: mesh)
        }
        XCTAssertEqual(decoded { $0 }?.hasReceiveSignals, false)
        XCTAssertEqual(decoded { $0.varint(RadioProto.MeshPacket.rxRssi, UInt64(bitPattern: -90)) }?.hasReceiveSignals, true)
        XCTAssertEqual(decoded { $0.fixed32(RadioProto.MeshPacket.rxSnr, Float(4.25).bitPattern) }?.hasReceiveSignals, true)
        XCTAssertEqual(decoded { $0.bool(RadioProto.MeshPacket.viaMqtt, true) }?.hasReceiveSignals, true)
        XCTAssertEqual(decoded { $0.varint(RadioProto.MeshPacket.transportMechanism, 2) }?.hasReceiveSignals, true)
        // A time of arrival and a hop count are set on packets the radio makes
        // itself, so they say nothing.
        XCTAssertEqual(decoded { $0.fixed32(RadioProto.MeshPacket.rxTime, 1_700_000_000) }?.hasReceiveSignals, false)
        XCTAssertEqual(decoded { $0.varint(RadioProto.MeshPacket.hopStart, 3) }?.hasReceiveSignals, false)
        // Zero is the same as absent.
        XCTAssertEqual(decoded { $0.varint(RadioProto.MeshPacket.rxRssi, 0).bool(RadioProto.MeshPacket.viaMqtt, false) }?.hasReceiveSignals, false)
        XCTAssertEqual(decoded { $0 }?.requestId, 77)
    }

    // MARK: - One answer per request, and nothing nobody asked for

    func testAnAnswerIsKeptOnceAndAnotherForTheSameRequestIsNot() async {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = false
            let (task, request) = await startWaitingWrite(rig)
            rig.manager.handleSettingsEvent(.answer(positionAnswer(to: request)))
            // The same id again, with something else in it.
            rig.manager.handleSettingsEvent(.answer(positionAnswer(
                to: request, body: ProtoFixture().varint(RadioProto.Position.broadcastSecs, 7))))
            for _ in 0..<200 where rig.link.sets.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
            _ = await task.value
            // What was written back is the first answer, not the second.
            let sent = FixtureReader.setConfig(in: rig.link.sets[0].payload)
            XCTAssertEqual(FixtureReader.varint(RadioProto.Position.flags, in: sent?.body ?? Data()), 811)
        }
    }

    func testAnAnswerNobodyAskedForChangesNothing() async {
        await withRig { rig in
            rig.download()
            let before = rig.manager.radioSettings
            let somebody = Answer(from: WriteRig.nodeNum, requestId: 987_654, hasReceiveSignals: false,
                                  content: .channel(index: 0, body: RadioFixtures.channel(index: 0, name: "other", role: RadioProto.ChannelRole.primary).data))
            rig.manager.handleSettingsEvent(.answer(somebody))
            let withoutAnId = Answer(from: WriteRig.nodeNum, requestId: nil, hasReceiveSignals: false,
                                     content: .channel(index: 0, body: RadioFixtures.channel(index: 0, name: "other", role: RadioProto.ChannelRole.primary).data))
            rig.manager.handleSettingsEvent(.answer(withoutAnId))
            XCTAssertEqual(rig.manager.radioSettings, before)
        }
    }

    func testAnAnswerForARequestOfAnEarlierConnectionIsNotKeptOnTheNewOne() async {
        await withRig { rig in
            rig.download()
            let (task, request) = await startWaitingWrite(rig)

            // The operator chooses another radio while the first request waits.
            rig.chooseAnotherRadio(node: 0x0B0B_0B0B)
            rig.download()
            let result = await task.value
            XCTAssertEqual(result, .linkChangedRefusal)

            // The old radio's answer turns up on the new connection.
            let stale = Answer(from: WriteRig.nodeNum, requestId: request.packetID, hasReceiveSignals: false,
                               content: .config(variant: position, body: RadioFixtures.positionConfig(broadcastSecs: 111).data))
            rig.manager.handleSettingsEvent(.answer(stale))
            XCTAssertEqual(rig.manager.radioSettings.nodeNum, 0x0B0B_0B0B)
            XCTAssertNotEqual(rig.manager.radioSettings.positionBroadcastSeconds, 111)
        }
    }

    // MARK: - Ids

    func testEveryRequestHasAnIdOfItsOwnAndNeverZero() async {
        await withRig { rig in
            rig.download()
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            _ = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)
            _ = await rig.manager.createChannel(name: "delta", keyText: WriteRig.hex(RadioFixtures.key),
                                                noEncryption: false, replacePrimary: false)
            let ids = rig.link.sent.map(\.packetID)
            XCTAssertGreaterThanOrEqual(ids.count, 10)
            XCTAssertFalse(ids.contains(0))
            XCTAssertEqual(Set(ids).count, ids.count, "no id twice")
        }
    }

    func testAnIdOfZeroIsNotUsed() async {
        await withRig { rig in
            rig.download()
            var supply: [UInt32] = [0, 0, 41, 42, 43, 44, 45]
            rig.manager.requestIDSource = { supply.isEmpty ? 99 : supply.removeFirst() }
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(rig.link.sent.map(\.packetID), [41, 42, 43])
        }
    }

    // MARK: - A late answer to a config

    func testALateAnswerToAConfigReadBackStillUpdatesTheSettings() async throws {
        try await withRig { rig in
            rig.download()
            rig.manager.answerTimeout = 0.1
            rig.radio.holdsAnswersAfterAWrite = true

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            guard case .notConfirmed = result else { return XCTFail("\(result)") }
            XCTAssertNil(rig.manager.radioSettings.positionBroadcastSeconds)

            rig.radio.releaseAnswers()
            for _ in 0..<200 where rig.manager.radioSettings.positionBroadcastSeconds == nil {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 900)
            XCTAssertFalse(rig.manager.radioSettings.isAwaitingRestart(variant: position))
        }
    }

    // MARK: - Pace

    private func gaps(_ rig: WriteRig) -> [Double] {
        let times = rig.link.sent.map(\.uptime)
        return zip(times, times.dropFirst()).map { Double($1 &- $0) / 1_000_000_000 }
    }

    func testFramesAreAtLeastOneHundredMillisecondsApart() async {
        await withRig { rig in
            rig.download()
            rig.manager.frameSpacing = 0.1

            _ = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            let spacing = gaps(rig)
            XCTAssertGreaterThanOrEqual(rig.link.sent.count, 7)
            XCTAssertGreaterThanOrEqual(spacing.min() ?? 0, 0.0999, "gaps in seconds: \(spacing)")
        }
    }

    func testTheDefaultSpacingIsOneHundredMilliseconds() {
        XCTAssertEqual(MeshtasticManager().frameSpacing, 0.1)
    }

    /// Six packets, back to back, to a radio that is busy with each for 50 ms.
    private func burst(_ rig: WriteRig, spacing: TimeInterval) async throws {
        rig.radio.processingDelay = 0.05
        rig.manager.frameSpacing = spacing
        guard case .go(let route) = rig.manager.route() else { return XCTFail("no route") }
        for _ in 0..<6 {
            let sent = await rig.manager.sendFrame(MeshtasticAdminCodec.encodeBeginEditSettings(), wantResponse: false,
                                                   packetID: rig.manager.freshPacketID(), route: route)
            XCTAssertTrue(sent)
        }
        try await Task.sleep(nanoseconds: 700_000_000)
    }

    func testABurstLosesTheEarliestPacketsAndPacingDoesNot() async throws {
        try await withRig { rig in
            rig.download()
            try await burst(rig, spacing: 0)
            // Four wait, and a fifth and a sixth push the oldest out: the earliest are lost.
            XCTAssertEqual(rig.radio.dropped.count, 2)
            XCTAssertEqual(rig.radio.processed.count, 4)
            let lostFirst = rig.radio.dropped.map(\.packet.packetID)
            let sentIDs = rig.link.sent.map(\.packetID)
            XCTAssertEqual(lostFirst, Array(sentIDs.prefix(2)))
        }
        try await withRig { rig in
            rig.download()
            try await burst(rig, spacing: 0.1)
            XCTAssertTrue(rig.radio.dropped.isEmpty)
            XCTAssertEqual(rig.radio.processed.count, 6)
        }
    }

    func testAnImportToARadioThatHoldsOnePacketIsNotLostBecauseOfThePace() async {
        // A radio with a queue of one that is busy for 40 ms per packet: a write
        // and the read that follows it, sent back to back, would lose the write.
        await withRig { rig in
            rig.download(channels: RadioFixtures.channelSlots(used: []))
            rig.radio.queueDepth = 1
            rig.radio.processingDelay = 0.04
            rig.manager.frameSpacing = 0.1
            rig.manager.answerTimeout = 2

            let outcome = await rig.manager.importChannels((0..<3).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) })

            XCTAssertEqual(outcome.confirmed, [1, 2, 3])
            XCTAssertTrue(rig.radio.dropped.isEmpty)
        }
        await withRig { rig in
            rig.download(channels: RadioFixtures.channelSlots(used: []))
            rig.radio.queueDepth = 1
            rig.radio.processingDelay = 0.04
            rig.manager.frameSpacing = 0
            rig.manager.answerTimeout = 0.5

            let outcome = await rig.manager.importChannels((0..<3).map { MeshChannel(name: "imp\($0)", psk: RadioFixtures.key) })

            XCTAssertFalse(rig.radio.dropped.isEmpty, "without the pace the radio loses a write")
            XCTAssertNotEqual(outcome.confirmed, [1, 2, 3])
        }
    }
}
