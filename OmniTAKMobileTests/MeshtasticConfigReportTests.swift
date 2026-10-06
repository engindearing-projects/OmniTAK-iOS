//
//  MeshtasticConfigReportTests.swift
//  OmniTAKMobileTests
//
//  What a config write leaves behind (#148, #153). A config write makes the radio
//  restart to save it, and the radio can put a value back as it starts, so the
//  answer it gives before the restart is not the last word. The app remembers what
//  it sent, and when the radio reports the config again, in the download that
//  follows a reconnect, says "applied" or what the radio reports instead.
//
//  The tests here cover that for the link that stays up (TCP: the read-back
//  arrives, and the restart follows), and the surrounding rules: writes to one
//  sub-config merge, a late answer settles the report, a role write leaves the
//  position config unknown until the radio says, and a write that never went
//  leaves nothing behind. The Bluetooth case, where the radio cuts the link as it
//  takes the config, is in MeshtasticBluetoothLinkTests.
//
//  Names, keys and numbers are made up.
//

import XCTest
@testable import OmniTAK

@MainActor
final class MeshtasticConfigReportTests: XCTestCase {

    private let position = RadioProto.Config.position
    private let device = RadioProto.Config.device

    // MARK: - What the radio reports before and after it restarts

    func testAnIntervalTheRadioKeepsThroughTheRestartIsReportedApplied() async {
        await withRig { rig in
            rig.download()

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .applied)
            XCTAssertEqual(rig.manager.configReports.first?.state, .confirmed,
                           "the answer before the restart is not the last word")
            XCTAssertEqual(rig.manager.pendingConfigWrites.count, 1)
            XCTAssertTrue(rig.radio.restartRequested)

            rig.reconnect()

            XCTAssertEqual(rig.manager.configReports.first?.state, .appliedAfterRestart)
            XCTAssertEqual(rig.manager.configReports.first?.text,
                           "Position interval: applied. The radio reports 900 s after reconnecting.")
            XCTAssertTrue(rig.manager.pendingConfigWrites.isEmpty)
        }
    }

    func testAnIntervalTheRadioPutsBackWhenItStartsIsReportedWithWhatTheRadioReports() async {
        await withRig { rig in
            rig.download()
            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(result, .applied, "the radio said so before it restarted")
            // The radio raises a short interval to one hour when it starts (#153).
            rig.radio.set(position: RadioFixtures.positionConfig(broadcastSecs: 3600))

            rig.reconnect()

            XCTAssertEqual(rig.manager.configReports.first?.state, .differsAfterRestart([.positionInterval: 3600]))
            XCTAssertEqual(rig.manager.configReports.first?.text,
                           "Position interval: the radio reports 3600 s after reconnecting. 900 s was sent.")
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 3600,
                           "and the screen shows what the radio holds")
        }
    }

    func testTwoWritesToTheSameConfigAreBothCheckedAfterTheRestart() async throws {
        try await withRig { rig in
            rig.download()
            _ = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)
            _ = await rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: .knownOnly)
            XCTAssertEqual(rig.manager.configReports.first?.sent, [.role: 7, .rebroadcastMode: 3])
            XCTAssertEqual(rig.manager.pendingConfigWrites[device]?.expected, [.role: 7, .rebroadcastMode: 3])

            // The radio starts as a client again, and keeps the rebroadcast mode.
            let patched = try XCTUnwrap(ProtoFields.patch(rig.radio.deviceConfig, [.varint(RadioProto.Device.role, 0)]))
            rig.radio.set(device: ProtoFixture(patched))
            rig.reconnect()

            XCTAssertEqual(rig.manager.configReports.first?.state, .differsAfterRestart([.role: 0]))
            XCTAssertEqual(rig.manager.configReports.first?.text,
                           "Device config: the radio reports role Client after reconnecting. "
                           + "Role TAK, rebroadcast Known channels only was sent.")
        }
    }

    func testTheReportsOfTwoConfigsAreKeptApart() async {
        await withRig { rig in
            rig.download()
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            _ = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)
            XCTAssertEqual(rig.manager.configReports.map(\.what), ["Device config", "Position interval"])
            XCTAssertEqual(rig.manager.pendingConfigWrites.count, 2)

            rig.reconnect()

            XCTAssertEqual(rig.manager.configReports.map(\.state), [.appliedAfterRestart, .appliedAfterRestart])
            XCTAssertTrue(rig.manager.pendingConfigWrites.isEmpty)
        }
    }

    func testAnAnswerThatShowsAnotherValueIsReportedWithWhatTheRadioReports() async {
        await withRig { rig in
            rig.download()
            rig.radio.appliesConfigWrites = false

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .notConfirmed("The radio reports 3600 s, not 900 s. "
                + "It is checked again when the radio is back after restarting."))
            XCTAssertEqual(rig.manager.configReports.first?.state, .radioKept([.positionInterval: 3600]))
        }
    }

    func testALateAnswerToTheReadBackSettlesTheReport() async {
        await withRig { rig in
            rig.download()
            rig.radio.holdsAnswersAfterAWrite = true
            rig.manager.answerTimeout = 0.2

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .notConfirmed("The radio did not confirm. It is checked when the radio next connects."))
            XCTAssertEqual(rig.manager.configReports.first?.state, .noAnswer)

            rig.radio.releaseAnswers()
            await rig.settle()

            XCTAssertEqual(rig.manager.configReports.first?.state, .confirmed)
        }
    }

    func testAWriteThatWasNeverSentLeavesNoReportAndTheSettingsAsTheyWere() async {
        await withRig { rig in
            rig.download()
            // The link takes the read and refuses the write.
            rig.link.onSent = { kind in
                if kind == .getConfig(variant: RadioProto.Config.position) { rig.link.accepts = false }
            }

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)

            XCTAssertEqual(result, .linkChangedRefusal)
            XCTAssertTrue(rig.manager.configReports.isEmpty)
            XCTAssertTrue(rig.manager.pendingConfigWrites.isEmpty)
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 3600)
            XCTAssertFalse(rig.manager.radioSettings.isAwaitingRestart(variant: position))
        }
    }

    func testAWriteThatWasNeverSentPutsBackTheReportOfTheEarlierWrite() async {
        await withRig { rig in
            rig.download()
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            let earlier = rig.manager.configReports

            rig.link.onSent = { kind in
                if kind == .getConfig(variant: RadioProto.Config.position) { rig.link.accepts = false }
            }
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 600)

            XCTAssertEqual(rig.manager.configReports, earlier)
            XCTAssertEqual(rig.manager.pendingConfigWrites[position]?.expected, [.positionInterval: 900])
        }
    }

    func testWhatTheRadioReportedAfterItsRestartIsShownForThatSessionAndGoesAtTheNextConnect() async {
        await withRig { rig in
            rig.download()
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            rig.reconnect()
            XCTAssertEqual(rig.manager.configReports.first?.state, .appliedAfterRestart)

            rig.reconnect()      // the next connect: the radio has nothing outstanding

            XCTAssertTrue(rig.manager.configReports.isEmpty, "a verdict about an earlier restart is not shown for ever")
        }
    }

    func testAWriteStillWaitingForTheRadioSurvivesAConnectThatDoesNotReportTheConfig() async {
        await withRig { rig in
            rig.download()
            rig.radio.holdsAnswersAfterAWrite = true
            rig.manager.answerTimeout = 0.2
            _ = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            XCTAssertEqual(rig.manager.configReports.first?.state, .noAnswer)

            // The same radio starts a download and has not sent its configs yet.
            rig.manager.handleSettingsEvent(.downloadStarted(nodeNum: WriteRig.nodeNum))

            XCTAssertEqual(rig.manager.configReports.first?.state, .noAnswer, "it is still to be checked")
            XCTAssertEqual(rig.manager.pendingConfigWrites.count, 1)
        }
    }

    // MARK: - A role change rewrites the position config

    func testARoleWriteWhoseAnswersDoNotComeLeavesThePositionConfigUnknown() async {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            rig.manager.answerTimeout = 0.2

            let result = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)

            guard case .notConfirmed = result else { return XCTFail("\(result)") }
            XCTAssertFalse(rig.manager.radioSettings.hasPositionConfig,
                           "a role change rewrites it, and the radio has not said what it is now")
            XCTAssertTrue(rig.manager.radioSettings.isAwaitingRestart(variant: position))
        }
    }

    func testARebroadcastWriteLeavesThePositionConfigAsItWas() async {
        await withRig { rig in
            rig.download()
            rig.radio.stopsAnsweringAfterAWrite = true
            rig.manager.answerTimeout = 0.2

            _ = await rig.manager.applyDeviceConfig(role: nil, rebroadcastMode: .knownOnly)

            XCTAssertTrue(rig.manager.radioSettings.hasPositionConfig, "only a role change rewrites it")
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 3600)
        }
    }

    func testARoleWriteThatWasNeverSentPutsBackTheDeviceAndPositionConfigs() async {
        await withRig { rig in
            rig.download()
            rig.link.onSent = { kind in
                if kind == .getConfig(variant: RadioProto.Config.device) { rig.link.accepts = false }
            }

            let result = await rig.manager.applyDeviceConfig(role: .tak, rebroadcastMode: nil)

            XCTAssertEqual(result, .linkChangedRefusal)
            XCTAssertTrue(rig.manager.radioSettings.hasDeviceConfig)
            XCTAssertTrue(rig.manager.radioSettings.hasPositionConfig)
            XCTAssertEqual(rig.manager.radioSettings.positionBroadcastSeconds, 3600)
        }
    }

    // MARK: - A link lost between the read and the write

    func testALinkLostBetweenTheReadAndTheSetDoesNotPutTheOldConfigBackInTheCache() async {
        await withRig { rig in
            rig.download()
            // The link is heard to drop right after the answer to the read is taken.
            rig.link.onSent = { kind in
                if kind == .getConfig(variant: RadioProto.Config.position) {
                    DispatchQueue.main.async { rig.manager.handleLinkDown(.tcp) }
                }
            }

            let result = await rig.manager.applyPositionBroadcastInterval(seconds: 900)
            await rig.settle()

            XCTAssertEqual(result, .linkChangedRefusal)
            XCTAssertTrue(rig.manager.radioSettings.isEmpty,
                          "what a radio said on a link that is gone is not put back: \(rig.manager.radioSettings.hasPositionConfig)")
            XCTAssertNil(rig.manager.radioSettings.nodeNum)
            XCTAssertEqual(rig.link.kinds, [.getConfig(variant: RadioProto.Config.position)])
            XCTAssertTrue(rig.manager.configReports.isEmpty)
        }
    }

    // MARK: - What the operator reads

    func testTheStatusAfterAConfirmedWritePromisesTheRestartAndTheCheck() {
        let text = MeshtasticSettingsMessages.config(.applied, what: "Position interval")
        XCTAssertTrue(text.contains("restarts a few seconds later"))
        XCTAssertTrue(text.contains("checked again"))
    }

    func testTheStatusAfterAWriteThatWasNotConfirmedPromisesNoRestart() {
        for reason in ["The radio did not confirm. It is checked when the radio next connects.",
                       "The radio reports 3600 s, not 900 s. It is checked again when the radio is back after restarting.",
                       "The link changed before the radio confirmed. It is checked when the radio reconnects."] {
            let text = MeshtasticSettingsMessages.config(.notConfirmed(reason), what: "Position interval")
            XCTAssertFalse(text.contains("restarts a few seconds later"), text)
            XCTAssertTrue(text.hasPrefix("Position interval sent."), text)
        }
    }

    func testEveryStateOfAConfigReportReadsAsASentence() {
        let sent: [MeshtasticConfigField: UInt64] = [.positionInterval: 900]
        let states: [MeshtasticConfigReport.State] = [
            .sent, .confirmed, .radioKept([.positionInterval: 3600]), .noAnswer, .linkLost,
            .appliedAfterRestart, .differsAfterRestart([.positionInterval: 3600]),
        ]
        for state in states {
            let report = MeshtasticConfigReport(variant: position, node: 1, what: "Position interval", sent: sent, state: state)
            XCTAssertTrue(report.text.hasPrefix("Position interval: "), report.text)
            XCTAssertTrue(report.text.hasSuffix("."), report.text)
            XCTAssertTrue(report.text.contains("900 s"), report.text)
        }
    }
}
