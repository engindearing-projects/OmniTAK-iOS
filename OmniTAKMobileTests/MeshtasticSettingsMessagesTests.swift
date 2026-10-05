//
//  MeshtasticSettingsMessagesTests.swift
//  OmniTAKMobileTests
//
//  What the Mesh Settings screen says about a write (#148). A message that says
//  more than the app knows is a defect: each rule in MeshtasticSettingsMessages is
//  read here.
//
//  Names and numbers are made up.
//

import XCTest
@testable import OmniTAK

@MainActor
final class MeshtasticSettingsMessagesTests: XCTestCase {

    typealias Messages = MeshtasticSettingsMessages
    typealias Outcome = MeshtasticManager.ChannelOutcome
    typealias Import = MeshtasticManager.ImportOutcome

    // MARK: - A channel create

    func testACreatedChannelSaysWhatTheRadioReports() {
        XCTAssertEqual(Messages.create(Outcome(result: .applied, slot: 3), name: "delta"),
                       "Channel \"delta\" applied to slot 3. The radio reports it.")
    }

    func testAChannelThatIsAlreadyThereIsSaidToBeSoBecauseTheRadioReportedIt() {
        let text = Messages.create(Outcome(result: .unchanged, slot: 1), name: "delta")
        XCTAssertEqual(text, "Slot 1: the radio reports this channel is already there. Nothing was sent.")
    }

    func testAChannelSavedWithNoRadioSaysItIsNotOnOne() {
        let text = Messages.create(Outcome(result: .refused(MeshtasticWriteResult.notConnected), slot: nil, savedOnly: true),
                                   name: "delta")
        XCTAssertTrue(text.contains("not on a radio"), text)
        XCTAssertTrue(text.contains("saved in this list only"), text)
    }

    func testTheNameDefaultIsSaidToBeKeptAsNoName() {
        let text = Messages.create(Outcome(result: .applied, slot: 2), name: "Default")
        XCTAssertTrue(text.contains("keeps the name Default as no name"), text)
        XCTAssertFalse(Messages.create(Outcome(result: .applied, slot: 2), name: "delta").contains("no name"))
    }

    func testNoChannelMessageEverPromisesARestart() {
        let outcomes: [Outcome] = [
            Outcome(result: .applied, slot: 1),
            Outcome(result: .notConfirmed("The radio kept its own value (\"x\")."), slot: 1),
            Outcome(result: .notConfirmed("The radio did not confirm. If it answers later, the line under Channel writes changes."), slot: 1),
            Outcome(result: .unchanged, slot: 1),
            Outcome(result: .refused("No free channel slot."), slot: nil),
        ]
        for outcome in outcomes {
            let text = Messages.create(outcome, name: "x")
            XCTAssertFalse(text.lowercased().contains("restart"), "a channel is saved without a restart: \(text)")
        }
    }

    // MARK: - An import

    func testAnImportThatWasAppliedSaysWhichSlotsAndThatTheRadioReportsThem() {
        var outcome = Import()
        outcome.confirmed = [1, 2, 4]
        let text = Messages.importSummary(outcome, total: 3)
        XCTAssertEqual(text, "Applied 3 of 3 to slot 1, 2, 4. The radio reports them.")
        XCTAssertFalse(text.lowercased().contains("restart"), text)
    }

    func testAnImportWithNoRadioSaysTheChannelsAreSavedAndNotOnARadio() {
        var outcome = Import()
        outcome.savedOnly = 2
        outcome.skipped = ["\"bad\" has no key."]
        let text = Messages.importSummary(outcome, total: 3)
        XCTAssertTrue(text.hasPrefix("Saved 2 of 3 in this list only. They are not on a radio."), text)
        XCTAssertFalse(text.contains("Imported"), "it does not say it imported what it only kept")
    }

    func testNoFreeSlotIsSaidOnlyForSlotsKnownToBeInUse() {
        var known = Import()
        known.noRoom = 2
        XCTAssertTrue(Messages.importSummary(known, total: 2).contains("all seven secondary slots on the radio are in use"))

        // Slots nothing is known about: the import stopped, and says what was not tried.
        var unknown = Import()
        unknown.refusal = MeshtasticManager.slotsNotKnownReason([2, 3])
        unknown.notTried = 2
        let text = Messages.importSummary(unknown, total: 2)
        XCTAssertFalse(text.lowercased().contains("no free slot"), text)
        XCTAssertFalse(text.contains("all seven"), text)
        XCTAssertTrue(text.contains("not known yet"), text)
        XCTAssertTrue(text.contains("2 not tried."), text)
    }

    func testAlreadyOnTheRadioIsSaidOnlyForWhatTheRadioReportedWhenAsked() {
        var outcome = Import()
        outcome.alreadyThere = 1
        outcome.waiting = 1
        let text = Messages.importSummary(outcome, total: 2)
        XCTAssertTrue(text.contains("1 already on the radio: it reported them when asked just now."), text)
        XCTAssertTrue(text.contains("1 have a write waiting for the radio's answer and were not sent again."), text)
    }

    func testAnImportThatStoppedSaysWhyAndHowManyWereNotTried() {
        var outcome = Import()
        outcome.unconfirmed = [1]
        outcome.refusal = MeshtasticWriteResult.linkChanged
        outcome.notTried = 3
        let text = Messages.importSummary(outcome, total: 4)
        XCTAssertTrue(text.contains("Stopped: \(MeshtasticWriteResult.linkChanged)"), text)
        XCTAssertTrue(text.contains("3 not tried."), text)

        var nothing = Import()
        nothing.refusal = MeshtasticWriteResult.noAnswer
        nothing.notTried = 2
        XCTAssertTrue(Messages.importSummary(nothing, total: 2).contains("Not applied to the radio: \(MeshtasticWriteResult.noAnswer)"))
    }

    func testAnImportRefusedWholeSaysSo() {
        var outcome = Import()
        outcome.refusal = MeshtasticWriteResult.notLoaded
        XCTAssertEqual(Messages.importSummary(outcome, total: 2), "Not applied to the radio: \(MeshtasticWriteResult.notLoaded)")
    }

    // MARK: - Asking the radio again

    func testARereadThatStoppedSaysWhatWasNotAsked() {
        var outcome = MeshtasticManager.RereadOutcome()
        outcome.answered = 1
        outcome.missing = ["position config"]
        outcome.notAsked = ["channel 0", "channel 1"]
        let text = Messages.reread(outcome)
        XCTAssertTrue(text.contains("Read 1 settings. No answer for position config."), text)
        XCTAssertTrue(text.contains("Not asked, because the radio had stopped answering: channel 0, channel 1."), text)
    }

    func testARereadThatAnsweredEverythingSaysSo() {
        var outcome = MeshtasticManager.RereadOutcome()
        outcome.answered = 10
        XCTAssertEqual(Messages.reread(outcome), "Read 10 settings from the radio.")
    }

    // MARK: - The line under Channel writes

    func testALineThatPromisesAChangeIsOnlyThereWhileSomethingCanChangeIt() {
        let waiting = MeshtasticChannelReport(slot: 2, name: "delta", state: .noAnswer).text
        XCTAssertTrue(waiting.contains("If the radio answers later this line changes"), waiting)

        let lost = MeshtasticChannelReport(slot: 2, name: "delta", state: .linkLost).text
        XCTAssertFalse(lost.contains("If the radio answers later"), lost)
        XCTAssertTrue(lost.contains("when the radio reports the slot again"), lost)
    }

    func testAConfigReportNeverPromisesWhatNothingWillDo() {
        for state in [MeshtasticConfigReport.State.noAnswer, .linkLost, .confirmed] {
            let report = MeshtasticConfigReport(
                variant: 2, node: 1, what: "Position interval", sent: [.positionInterval: 900], state: state)
            XCTAssertTrue(report.text.contains("checked"), "what it will be checked against, and when: \(report.text)")
        }
    }
}
