//
//  ContactMaxAgeTests.swift
//  OmniTAKMobileTests
//
//  #137: hide a teammate not heard from for a while, then remove them. The same
//  behaviour as Android #215.
//
//  The rule is a pure function of (now, last received, max age), so most of this
//  runs against fixed dates with no clock and no timer. The monitor tests use a
//  fake clock, in-memory stores and a 20 ms interval of their own, wait for a
//  condition with a deadline, and each owns the one timer it is about.
//

import XCTest
@testable import OmniTAK

// MARK: - Fixtures

/// "Now" for every test that does not need a moving clock.
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func minutes(_ m: Double) -> TimeInterval { m * 60 }

private let bravo = "ANDROID-bravo2"

/// A position report as the handler stores it. `receivedAt` is when this device
/// received it; `cotTime` is the time inside the CoT, the sender's clock. `how` is
/// the CoT `how`: `m-g` is a device reporting its GPS, `h-e` is a person placing it.
private func report(uid: String = bravo,
                    type: String = "a-f-G-U-C",
                    how: String? = "m-g",
                    receivedAt: Date?,
                    cotTime: Date = t0,
                    source: CoTSource? = .takServer("Stand-in")) -> CoTEvent {
    var event = CoTEvent(
        uid: uid,
        type: type,
        time: cotTime,
        point: CoTPoint(lat: 38.8899, lon: -77.0340, hae: 10, ce: 10, le: 10),
        detail: CoTDetail(callsign: "BRAVO-2", team: nil, teamRole: nil, speed: nil, course: nil,
                          remarks: nil, battery: nil, device: nil, platform: nil),
        how: how
    )
    event.receivedAt = receivedAt
    event.source = source
    return event
}

/// A saved contact. `fromReport` is `ChatParticipant.fromPositionReport`: true when it was
/// saved from another operator's own position report, nil for any other way.
private func contact(_ id: String, fromReport: Bool? = true, lastSeen: Date = t0) -> ChatParticipant {
    ChatParticipant(id: id, callsign: id, lastSeen: lastSeen, fromPositionReport: fromReport)
}

// MARK: - The rule

final class ContactMaxAgeRuleTests: XCTestCase {

    /// The decision for a report received `age` seconds before `t0`.
    private func decide(_ age: TimeInterval, maxMinutes: Int = 30) -> ContactMaxAge.Decision {
        ContactMaxAge.decision(now: t0, lastReceived: t0.addingTimeInterval(-age), maxAgeMinutes: maxMinutes)
    }

    func testYoungerThanTheMaxAgeIsFresh() {
        XCTAssertEqual(decide(0), .fresh)
        XCTAssertEqual(decide(minutes(30) - 1), .fresh, "one second under the max age")
    }

    func testExactlyTheMaxAgeIsHidden() {
        XCTAssertEqual(decide(minutes(30)), .hidden)
    }

    func testJustUnderTwiceTheMaxAgeIsStillHidden() {
        XCTAssertEqual(decide(minutes(60) - 1), .hidden)
    }

    func testExactlyTwiceTheMaxAgeIsRemoved() {
        XCTAssertEqual(decide(minutes(60)), .remove)
    }

    func testMuchOlderIsRemoved() {
        XCTAssertEqual(decide(minutes(60) + 1), .remove)
        XCTAssertEqual(decide(86_400 * 30), .remove)
    }

    func testEveryChoiceHasItsOwnBoundaries() {
        for choice in ContactMaxAge.choices where choice > 0 {
            let max = TimeInterval(choice) * 60
            XCTAssertEqual(decide(max - 1, maxMinutes: choice), .fresh, "\(choice) min: 1 s under the max age")
            XCTAssertEqual(decide(max, maxMinutes: choice), .hidden, "\(choice) min: at the max age")
            XCTAssertEqual(decide(2 * max - 1, maxMinutes: choice), .hidden, "\(choice) min: 1 s under twice")
            XCTAssertEqual(decide(2 * max, maxMinutes: choice), .remove, "\(choice) min: at twice")
        }
    }

    func testNeverIsAlwaysFresh() {
        XCTAssertEqual(decide(0, maxMinutes: ContactMaxAge.never), .fresh)
        XCTAssertEqual(decide(minutes(6), maxMinutes: ContactMaxAge.never), .fresh)
        XCTAssertEqual(decide(86_400 * 400, maxMinutes: ContactMaxAge.never), .fresh)
        XCTAssertEqual(decide(86_400 * 400, maxMinutes: -5), .fresh, "a negative value is also off")
    }

    func testAClockEarlierThanTheLastReportIsFresh() {
        // The phone's clock was set back: the last report is 10 hours "in the future".
        XCTAssertEqual(
            ContactMaxAge.decision(now: t0, lastReceived: t0.addingTimeInterval(36_000), maxAgeMinutes: 5),
            .fresh
        )
        XCTAssertEqual(decide(-1), .fresh)
    }
}

// MARK: - What it applies to

final class ContactMaxAgeAppliesToTests: XCTestCase {

    private let selfUID = "OMNI-iOS-1234ABCD"

    private func applies(_ event: CoTEvent) -> Bool {
        ContactMaxAge.appliesTo(event, selfUID: selfUID)
    }

    func testAnOperatorsPositionReportApplies() {
        XCTAssertTrue(applies(report(receivedAt: t0)))
    }

    func testAMarkerAPersonPlacedDoesNotApply() {
        // A friendly marker someone placed: a friendly type, but entered by a person (h-).
        XCTAssertFalse(applies(report(uid: "7d1f6e1c-1c2b-4a52-9d57-5f3a0c5d7b11", type: "a-f-G", how: "h-e", receivedAt: t0)))
        XCTAssertFalse(applies(report(type: "a-f-G", how: "h-g-i-g-o", receivedAt: t0)))
    }

    func testAnEventWithNoHowIsLeftAlone() {
        XCTAssertFalse(applies(report(how: nil, receivedAt: t0)), "no how: unclear, left alone")
        XCTAssertFalse(applies(report(how: "", receivedAt: t0)))
    }

    func testAnyMachineReportedHowApplies() {
        for how in ["m-g", "m-r", "m-f", "m-i", "m-p"] {
            XCTAssertTrue(applies(report(how: how, receivedAt: t0)), "how \(how) is machine reported")
        }
    }

    func testOnlyFriendlyTypesApply() {
        // Hostile, neutral, unknown, suspect and assumed-friendly reports are not governed
        // even when machine reported: they are often dropped markers, not people.
        for type in ["a-h-G", "a-n-G-U-C", "a-u-G", "a-s-G", "a-a-G", "a-j-G", "a-k-G"] {
            XCTAssertFalse(applies(report(type: type, receivedAt: t0)), "\(type) must not be governed")
        }
        for type in ["a-f-G-U-C", "a-f-G", "a-f-A-M-F"] {
            XCTAssertTrue(applies(report(type: type, receivedAt: t0)), "\(type) is a friendly position report")
        }
    }

    func testAWaypointOrSpotMarkerTypeDoesNotApplyEvenWhenMachineReported() {
        XCTAssertFalse(applies(report(type: "b-m-p-w", receivedAt: t0)))
        XCTAssertFalse(applies(report(type: "b-m-p-s-m", receivedAt: t0)))
    }

    func testTheOperatorsOwnMarkerDoesNotApply() {
        XCTAssertFalse(applies(report(uid: selfUID, receivedAt: t0)))
        XCTAssertTrue(ContactMaxAge.appliesTo(report(uid: selfUID, receivedAt: t0), selfUID: nil),
                      "with no own uid known, the uid is not special")
    }

    func testDroppedMarkersDronesAndMeshNodesDoNotApply() {
        for uid in ["marker-550E8400-E29B-41D4-A716-446655440000",
                    "RID-DJI-ABC123",
                    "mesh-00be0001",
                    "mesh-self-00be0001",
                    "MESHCORE-DEADBEEFCAFE",
                    "MESHTASTIC-abcdef01"] {
            XCTAssertFalse(applies(report(uid: uid, receivedAt: t0)), "\(uid) must not be governed")
        }
    }

    func testAReportFromAMeshRadioOrThisDeviceDoesNotApply() {
        XCTAssertFalse(applies(report(receivedAt: t0, source: .mesh("Meshtastic"))))
        XCTAssertFalse(applies(report(receivedAt: t0, source: .local)))
        XCTAssertFalse(applies(report(receivedAt: t0, source: CoTSource(transport: .other, detail: "x"))))
        XCTAssertTrue(applies(report(receivedAt: t0, source: .takServer(nil))))
        XCTAssertTrue(applies(report(receivedAt: t0, source: nil)), "no source recorded: judged by the rest")
    }

    func testASavedContactAppliesOnlyWhenItWasSavedFromAQualifyingReport() {
        XCTAssertTrue(ContactMaxAge.appliesTo(contact(bravo), selfUID: selfUID))
        XCTAssertFalse(ContactMaxAge.appliesTo(contact(bravo, fromReport: nil), selfUID: selfUID),
                       "saved any other way, or by an older build: left alone")
        XCTAssertFalse(ContactMaxAge.appliesTo(contact(bravo, fromReport: false), selfUID: selfUID))
        XCTAssertFalse(ContactMaxAge.appliesTo(contact(selfUID), selfUID: selfUID))
        XCTAssertFalse(ContactMaxAge.appliesTo(contact("marker-1234"), selfUID: selfUID))
        XCTAssertFalse(ContactMaxAge.appliesTo(contact("RID-1234"), selfUID: selfUID))
    }
}

// MARK: - One pass over both stores

final class ContactMaxAgeSweepTests: XCTestCase {

    private let selfUID = "OMNI-iOS-1234ABCD"

    private func sweep(_ events: [CoTEvent] = [],
                       _ participants: [ChatParticipant] = [],
                       maxMinutes: Int = 30,
                       now: Date = t0) -> ContactMaxAge.Outcome {
        ContactMaxAge.evaluate(now: now, maxAgeMinutes: maxMinutes, selfUID: selfUID,
                               events: events, participants: participants)
    }

    func testEachContactGetsTheDecisionOfItsOwnAge() {
        let fresh = report(uid: "ANDROID-fresh", receivedAt: t0.addingTimeInterval(-minutes(29)))
        let hidden = report(uid: "ANDROID-hidden", receivedAt: t0.addingTimeInterval(-minutes(31)))
        let gone = report(uid: "ANDROID-gone", receivedAt: t0.addingTimeInterval(-minutes(61)))

        let outcome = sweep([fresh, hidden, gone])

        XCTAssertEqual(outcome.hidden, ["ANDROID-hidden": t0.addingTimeInterval(-minutes(31))])
        XCTAssertEqual(outcome.removed, ["ANDROID-gone"])
    }

    func testAgeCountsFromWhenThisDeviceReceivedTheReportNotFromTheTimeInsideIt() {
        // The sender's clock is 3 hours behind, but the report arrived a minute ago.
        let skewed = report(uid: "ANDROID-skew", receivedAt: t0.addingTimeInterval(-60),
                            cotTime: t0.addingTimeInterval(-3 * 3600))
        // The sender's clock reads "now", but the report was received 40 minutes ago.
        let quiet = report(uid: "ANDROID-quiet", receivedAt: t0.addingTimeInterval(-minutes(40)), cotTime: t0)

        let outcome = sweep([skewed, quiet])

        XCTAssertNil(outcome.hidden["ANDROID-skew"])
        XCTAssertFalse(outcome.removed.contains("ANDROID-skew"))
        XCTAssertNotNil(outcome.hidden["ANDROID-quiet"])
    }

    func testNothingOutsideTheRuleIsEverHiddenOrRemoved() {
        let old = t0.addingTimeInterval(-86_400)
        let events = [
            report(uid: "7d1f6e1c-hostile", type: "a-h-G", how: "h-e", receivedAt: old),      // placed hostile marker
            report(uid: "7d1f6e1c-friend", type: "a-f-G", how: "h-e", receivedAt: old),       // placed friendly marker
            report(uid: "marker-AABB", how: "h-g-i-g-o", receivedAt: old),                     // dropped marker
            report(uid: "marker-CCDD", receivedAt: old),                                       // even when machine reported
            report(uid: selfUID, receivedAt: old),                                             // own marker
            report(uid: "RID-FA1234", receivedAt: old),                                        // drone
            report(uid: "mesh-00be0001", receivedAt: old, source: .mesh("Meshtastic")),        // mesh node
            report(uid: "7d1f6e1c-wpt", type: "b-m-p-w", receivedAt: old),                     // waypoint
            report(uid: "ANDROID-neutral", type: "a-n-G-U-C", receivedAt: old),                // neutral
            report(uid: "ANDROID-nohow", how: nil, receivedAt: old),                           // no how at all
        ]
        XCTAssertEqual(sweep(events), ContactMaxAge.Outcome())
    }

    func testAnEventWithNoReceiveTimeCannotBeAgedAndIsLeftAlone() {
        XCTAssertEqual(sweep([report(receivedAt: nil)]), ContactMaxAge.Outcome())
    }

    func testNeverLeavesEverythingAlone() {
        let events = [report(uid: "ANDROID-a", receivedAt: t0.addingTimeInterval(-86_400 * 3)),
                      report(uid: "ANDROID-b", receivedAt: t0.addingTimeInterval(-minutes(6)))]
        let saved = [contact("ANDROID-c", lastSeen: t0.addingTimeInterval(-86_400 * 9))]
        XCTAssertEqual(sweep(events, saved, maxMinutes: ContactMaxAge.never), ContactMaxAge.Outcome())
    }

    func testANewReportAfterHidingMakesTheContactFreshAgain() {
        let quietSince = t0.addingTimeInterval(-minutes(35))
        XCTAssertNotNil(sweep([report(receivedAt: quietSince)]).hidden[bravo], "hidden while quiet")

        // It reports again: the same uid, stamped with the receive time of now.
        let again = sweep([report(receivedAt: t0)])

        XCTAssertNil(again.hidden[bravo])
        XCTAssertFalse(again.removed.contains(bravo))
    }

    func testAContactWhoWasRemovedAndReportsAgainIsJustAFreshContact() {
        XCTAssertEqual(sweep([report(receivedAt: t0.addingTimeInterval(-minutes(75)))]).removed, [bravo])
        XCTAssertEqual(sweep([report(receivedAt: t0)]), ContactMaxAge.Outcome())
    }

    func testASavedContactWithNoEventIsJudgedByWhenItWasLastSeen() {
        let quiet = contact("ANDROID-quiet", lastSeen: t0.addingTimeInterval(-minutes(40)))
        let gone = contact("ANDROID-gone", lastSeen: t0.addingTimeInterval(-minutes(90)))
        let fresh = contact("ANDROID-fresh", lastSeen: t0.addingTimeInterval(-minutes(2)))
        let oldFormat = contact("ANDROID-old", fromReport: nil, lastSeen: t0.addingTimeInterval(-86_400 * 5))

        let outcome = sweep([], [quiet, gone, fresh, oldFormat])

        XCTAssertEqual(outcome.hidden, ["ANDROID-quiet": quiet.lastSeen])
        XCTAssertEqual(outcome.removed, ["ANDROID-gone"])
    }

    func testAContactWithAnEventIsJudgedByTheEventNotByItsSavedLastSeen() {
        // lastSeen is refreshed by chat messages too; the position report is what counts.
        let saved = contact(bravo, lastSeen: t0.addingTimeInterval(-minutes(120)))
        XCTAssertEqual(sweep([report(receivedAt: t0.addingTimeInterval(-minutes(1)))], [saved]),
                       ContactMaxAge.Outcome())
        // ... and the other way round: a recent lastSeen does not save a quiet position.
        let chatty = contact(bravo, lastSeen: t0)
        XCTAssertNotNil(sweep([report(receivedAt: t0.addingTimeInterval(-minutes(40)))], [chatty]).hidden[bravo])
    }

    func testAContactWhoseEventDoesNotQualifyIsNotJudgedByItsSavedEntry() {
        // The event is a placed marker (entered by a person), so the saved entry with an
        // old lastSeen must not pull it into the rule through the back door.
        let marker = report(uid: "7d1f6e1c-hostile", type: "a-f-G", how: "h-e", receivedAt: t0.addingTimeInterval(-86_400))
        let saved = contact("7d1f6e1c-hostile", lastSeen: t0.addingTimeInterval(-86_400))
        XCTAssertEqual(sweep([marker], [saved]), ContactMaxAge.Outcome())
    }

    func testThePartitionPutsHiddenContactsInTheSectionMostRecentFirst() {
        let a = contact("ANDROID-a"), b = contact("ANDROID-b"), c = contact("ANDROID-c"), d = contact("ANDROID-d")
        let hidden = ["ANDROID-b": t0.addingTimeInterval(-minutes(50)),
                      "ANDROID-d": t0.addingTimeInterval(-minutes(35))]

        let parts = ContactMaxAge.partition([a, b, c, d], hidden: hidden)

        XCTAssertEqual(parts.visible.map(\.id), ["ANDROID-a", "ANDROID-c"])
        XCTAssertEqual(parts.stale.map(\.id), ["ANDROID-d", "ANDROID-b"], "heard from most recently first")
        XCTAssertEqual(ContactMaxAge.partition([a, b], hidden: [:]).stale.count, 0)
    }
}

// MARK: - The existing hourly sweep

final class ContactMaxAgeHourlySweepTests: XCTestCase {

    private let selfUID = "OMNI-iOS-1234ABCD"
    private let cutoff = t0.addingTimeInterval(-3600)

    private func swept(_ event: CoTEvent, maxMinutes: Int) -> Bool {
        ContactMaxAge.hourlySweepRemoves(event, cutoff: cutoff, maxAgeMinutes: maxMinutes, selfUID: selfUID)
    }

    /// An operator's report whose CoT time is 70 minutes old.
    private var oldOperator: CoTEvent {
        report(receivedAt: t0.addingTimeInterval(-minutes(70)), cotTime: t0.addingTimeInterval(-minutes(70)))
    }

    func testWithNeverTheSweepIsWhatItAlwaysWas() {
        XCTAssertTrue(swept(oldOperator, maxMinutes: ContactMaxAge.never), "older than an hour: removed, as before")
        XCTAssertFalse(swept(report(receivedAt: t0, cotTime: t0.addingTimeInterval(-minutes(10))), maxMinutes: 0))
    }

    func testWithTheRuleOnTheSweepLeavesTheContactsTheRuleGoverns() {
        // 1 h and 2 h would otherwise be cut short at about an hour.
        XCTAssertFalse(swept(oldOperator, maxMinutes: 60))
        XCTAssertFalse(swept(oldOperator, maxMinutes: 120))
        XCTAssertFalse(swept(oldOperator, maxMinutes: 30))
    }

    func testWithTheRuleOnTheSweepStillRemovesWhatTheRuleDoesNotGovern() {
        let placed = report(uid: "7d1f6e1c-hostile", type: "a-h-G", how: "h-e",
                            receivedAt: t0.addingTimeInterval(-minutes(70)),
                            cotTime: t0.addingTimeInterval(-minutes(70)))
        XCTAssertTrue(swept(placed, maxMinutes: 60), "not an operator's report: the hour rule is unchanged")
    }

    func testDroppedMarkersAreStillNeverSwept() {
        let dropped = report(uid: "marker-AABB", how: "h-g-i-g-o", receivedAt: nil,
                             cotTime: t0.addingTimeInterval(-86_400))
        XCTAssertFalse(swept(dropped, maxMinutes: 0))
        XCTAssertFalse(swept(dropped, maxMinutes: 30))
    }
}

// MARK: - The setting and its words

final class ContactMaxAgeSettingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "ContactMaxAgeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testTheDefaultIsThirtyMinutes() {
        XCTAssertEqual(ContactMaxAge.defaultMinutes, 30)
        XCTAssertEqual(ContactMaxAge.currentMinutes(defaults: defaults), 30, "nothing stored: the default")
    }

    func testNeverIsStoredAsZeroAndIsNotTheDefault() {
        XCTAssertEqual(ContactMaxAge.never, 0)
        defaults.set(0, forKey: ContactMaxAge.defaultsKey)
        XCTAssertEqual(ContactMaxAge.currentMinutes(defaults: defaults), 0, "a stored 0 is Never, not unset")
    }

    func testAChosenValueIsWhatIsRead() {
        for choice in ContactMaxAge.choices {
            defaults.set(choice, forKey: ContactMaxAge.defaultsKey)
            XCTAssertEqual(ContactMaxAge.currentMinutes(defaults: defaults), choice)
        }
    }

    func testTheKeyIsTheOneTheIssueNames() {
        XCTAssertEqual(ContactMaxAge.defaultsKey, "contactMaxAgeMinutes")
    }

    func testTheChoicesAreTheSpecifiedOnesInOrderAndIncludeTheDefault() {
        XCTAssertEqual(ContactMaxAge.choices, [5, 10, 15, 30, 60, 120, 0])
        XCTAssertTrue(ContactMaxAge.choices.contains(ContactMaxAge.defaultMinutes))
        XCTAssertEqual(ContactMaxAge.choices.map { ContactMaxAge.label(forMinutes: $0) },
                       ["5 min", "10 min", "15 min", "30 min", "1 h", "2 h", "Never"])
    }

    func testTheWordsAreThePlainOnesFromTheSpec() {
        XCTAssertEqual(ContactMaxAge.settingTitle, "Hide teammates not heard from for")
        XCTAssertEqual(ContactMaxAge.settingHelp,
                       "Their marker leaves the map after this time without a report, " +
                       "and they are removed after twice this time. A new report brings them back.")
        XCTAssertEqual(ContactMaxAge.staleSectionTitle(maxAgeMinutes: 30), "Not heard from for over 30 min")
        XCTAssertEqual(ContactMaxAge.staleSectionTitle(maxAgeMinutes: 5), "Not heard from for over 5 min")
        XCTAssertEqual(ContactMaxAge.staleSectionTitle(maxAgeMinutes: 60), "Not heard from for over 1 h")
        XCTAssertEqual(ContactMaxAge.label(forMinutes: 90), "90 min")
    }

    func testNoEmDashInAnyWord() {
        let words = [ContactMaxAge.settingTitle, ContactMaxAge.settingHelp,
                     ContactMaxAge.staleSectionTitle(maxAgeMinutes: 30)]
            + ContactMaxAge.choices.map { ContactMaxAge.label(forMinutes: $0) }
        for word in words {
            XCTAssertFalse(word.contains("\u{2014}"), "no em dash in: \(word)")
        }
    }
}

// MARK: - What tells a position report from a placed marker, as parsed

final class ContactHowParseTests: XCTestCase {

    private func parsed(_ xml: String) -> CoTEvent? {
        if case .positionUpdate(let event)? = CoTMessageParser.parse(xml: xml) { return event }
        return nil
    }

    func testADevicesReportKeepsItsMachineHow() {
        let xml = """
        <event version="2.0" uid="ANDROID-bravo2" type="a-f-G-U-C" how="m-g" \
        time="2026-10-06T20:00:00.000Z" start="2026-10-06T20:00:00.000Z" stale="2026-10-06T20:02:00.000Z">\
        <point lat="38.8899" lon="-77.0340" hae="10.0" ce="10.0" le="10.0"/>\
        <detail><contact callsign="BRAVO-2" endpoint="*:-1:stcp"/><__group name="Cyan" role="Team Member"/>\
        <takv device="StandIn" platform="ATAK-CIV" os="34" version="5.4.0"/></detail></event>
        """
        let event = parsed(xml)
        XCTAssertEqual(event?.detail.callsign, "BRAVO-2")
        XCTAssertEqual(event?.how, "m-g")
        if let event {
            XCTAssertTrue(ContactMaxAge.appliesTo(event, selfUID: nil), "a parsed device report is governed")
        }
    }

    func testAMarkerAPersonPlacedKeepsItsHumanHow() {
        let xml = """
        <event version="2.0" uid="7d1f6e1c-1c2b-4a52-9d57-5f3a0c5d7b11" type="a-f-G" how="h-g-i-g-o" \
        time="2026-10-06T20:00:00.000Z" start="2026-10-06T20:00:00.000Z" stale="2026-10-06T20:30:00.000Z">\
        <point lat="38.8899" lon="-77.0340" hae="10.0" ce="9999999.0" le="9999999.0"/>\
        <detail><contact callsign="F.1.1"/><remarks/><color argb="-16776961"/></detail></event>
        """
        let event = parsed(xml)
        XCTAssertEqual(event?.detail.callsign, "F.1.1")
        XCTAssertEqual(event?.how, "h-g-i-g-o")
        if let event {
            XCTAssertFalse(ContactMaxAge.appliesTo(event, selfUID: nil), "a placed marker is not governed")
        }
    }

    func testAnEventWithNoHowHasNoHowAndIsLeftAlone() {
        let xml = """
        <event version="2.0" uid="ANDROID-nohow" type="a-f-G-U-C" \
        time="2026-10-06T20:00:00.000Z" start="2026-10-06T20:00:00.000Z" stale="2026-10-06T20:02:00.000Z">\
        <point lat="38.8899" lon="-77.0340" hae="10.0" ce="10.0" le="10.0"/>\
        <detail><contact callsign="NOHOW-1"/></detail></event>
        """
        let event = parsed(xml)
        XCTAssertNil(event?.how)
        if let event {
            XCTAssertFalse(ContactMaxAge.appliesTo(event, selfUID: nil))
        }
    }

    func testTheHowIsReadFromTheEventTagOnly() {
        // A how that appears only deeper in the XML, and one in a longer attribute name
        // (`show`), must not be taken for the event's own.
        let xml = """
        <event version="2.0" uid="ANDROID-deep" type="a-f-G-U-C" \
        time="2026-10-06T20:00:00.000Z" start="2026-10-06T20:00:00.000Z" stale="2026-10-06T20:02:00.000Z">\
        <point lat="38.8899" lon="-77.0340" hae="10.0" ce="10.0" le="10.0"/>\
        <detail><contact callsign="DEEP-1"/><precisionlocation how="m-g" show="m-g"/></detail></event>
        """
        XCTAssertNil(parsed(xml)?.how)
    }
}

// MARK: - A saved contact keeps what the rule needs, and old saved contacts still load

final class SavedContactFlagTests: XCTestCase {

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func testAContactSavedBeforeThisFlagExistedStillDecodesAndIsLeftAlone() throws {
        let saved = """
        [{"id":"ANDROID-old","callsign":"OLD-1","lastSeen":"2026-10-01T12:00:00Z","isOnline":true}]
        """
        let contacts = try decoder().decode([ChatParticipant].self, from: Data(saved.utf8))
        XCTAssertEqual(contacts.map(\.id), ["ANDROID-old"])
        XCTAssertNil(contacts.first?.fromPositionReport)
        XCTAssertFalse(ContactMaxAge.appliesTo(contacts[0], selfUID: nil))
    }

    func testTheFlagSurvivesBeingSavedAndLoaded() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = [ChatParticipant(id: "ANDROID-bravo2", callsign: "BRAVO-2", lastSeen: t0, fromPositionReport: true),
                        ChatParticipant(id: "ANDROID-chat", callsign: "CHAT-1", lastSeen: t0)]
        let loaded = try decoder().decode([ChatParticipant].self, from: encoder.encode(original))

        XCTAssertEqual(loaded.map(\.fromPositionReport), [true, nil])
        XCTAssertTrue(ContactMaxAge.appliesTo(loaded[0], selfUID: nil))
        XCTAssertFalse(ContactMaxAge.appliesTo(loaded[1], selfUID: nil))
    }
}

// MARK: - The monitor: timer, new reports, setting changes

/// In-memory stand-ins for the two stores the monitor reads and removes from.
private final class FakeStores {
    var events: [CoTEvent] = []
    var participants: [ChatParticipant] = []
    var selfUID: String? = "OMNI-iOS-1234ABCD"
    private(set) var removed: [Set<String>] = []

    var stores: ContactMaxAgeMonitor.Stores {
        ContactMaxAgeMonitor.Stores(
            events: { [unowned self] in self.events },
            participants: { [unowned self] in self.participants },
            selfUID: { [unowned self] in self.selfUID },
            remove: { [unowned self] uids in
                self.removed.append(uids)
                self.events.removeAll { uids.contains($0.uid) }
                self.participants.removeAll { uids.contains($0.id) }
            }
        )
    }
}

private final class FakeClock {
    var current = t0
}

final class ContactMaxAgeMonitorTests: XCTestCase {

    private var fake = FakeStores()
    private var clock = FakeClock()
    /// The setting, in minutes, as the monitor reads it at each pass.
    private var maxMinutes = 5

    override func setUp() {
        super.setUp()
        fake = FakeStores()
        clock = FakeClock()
        maxMinutes = 5
    }

    private func makeMonitor(interval: TimeInterval = 0.02) -> ContactMaxAgeMonitor {
        ContactMaxAgeMonitor(interval: interval,
                             now: { [unowned self] in self.clock.current },
                             maxAgeMinutes: { [unowned self] in self.maxMinutes },
                             stores: fake.stores)
    }

    func testAContactThatGoesQuietIsHiddenThenRemovedByTheTimerAlone() {
        fake.events = [report(receivedAt: t0)]
        fake.participants = [contact(bravo, lastSeen: t0)]
        let monitor = makeMonitor()
        monitor.start()
        defer { monitor.stop() }

        // No report arrives from here on. Only the clock moves, and only the
        // timer can notice.
        clock.current = t0.addingTimeInterval(minutes(5))
        waitUntil("the quiet contact to be hidden at 5 min") { monitor.hidden[bravo] != nil }
        XCTAssertEqual(fake.events.count, 1, "hidden, but still in the store")
        XCTAssertEqual(fake.participants.count, 1, "and still in the contact list store")
        XCTAssertEqual(monitor.hidden[bravo], t0, "its age counts from when the report was received")
        XCTAssertTrue(fake.removed.isEmpty)

        clock.current = t0.addingTimeInterval(minutes(10))
        waitUntil("the contact to be removed at 10 min") { fake.events.isEmpty }
        waitUntil("the hidden list to empty once it is removed") { monitor.hidden.isEmpty }
        XCTAssertTrue(fake.participants.isEmpty, "removed from the contact list store too")
        XCTAssertEqual(fake.removed, [[bravo]], "removed exactly once")
    }

    func testANewReportBringsTheContactBackAtOnce() {
        fake.events = [report(receivedAt: t0)]
        clock.current = t0.addingTimeInterval(minutes(6))
        let monitor = makeMonitor()
        monitor.evaluate()
        XCTAssertNotNil(monitor.hidden[bravo], "hidden after 6 min with a 5 min setting")

        // It reports again: the handler stores the event stamped with the receive
        // time of now and tells the monitor.
        fake.events = [report(receivedAt: clock.current)]
        monitor.reportReceived(uid: bravo)

        XCTAssertNil(monitor.hidden[bravo], "back at once, without waiting for the next pass")
        monitor.evaluate()
        XCTAssertTrue(monitor.hidden.isEmpty, "and the next pass agrees")
        XCTAssertTrue(fake.removed.isEmpty)
    }

    func testAReportFromAnotherContactChangesNothingForThisOne() {
        fake.events = [report(receivedAt: t0)]
        clock.current = t0.addingTimeInterval(minutes(6))
        let monitor = makeMonitor()
        monitor.evaluate()

        monitor.reportReceived(uid: "ANDROID-someone-else")

        XCTAssertNotNil(monitor.hidden[bravo])
    }

    func testChangingTheSettingAppliesAtOnce() {
        fake.events = [report(receivedAt: t0)]
        clock.current = t0.addingTimeInterval(minutes(10))
        maxMinutes = 30
        let monitor = makeMonitor()
        monitor.evaluate()
        XCTAssertTrue(monitor.hidden.isEmpty, "10 min old with a 30 min setting: fresh")

        maxMinutes = 5
        monitor.settingChanged()
        XCTAssertNil(monitor.hidden[bravo], "10 min old with a 5 min setting is twice the age: removed, not hidden")
        XCTAssertEqual(fake.removed, [[bravo]])

        // And back to Never: nothing hidden, nothing more removed.
        fake.events = [report(receivedAt: t0)]
        maxMinutes = ContactMaxAge.never
        monitor.settingChanged()
        XCTAssertTrue(monitor.hidden.isEmpty)
        XCTAssertEqual(fake.removed.count, 1)
        XCTAssertEqual(fake.events.count, 1)
    }

    func testNeverKeepsAContactForever() {
        fake.events = [report(receivedAt: t0)]
        fake.participants = [contact(bravo, lastSeen: t0)]
        clock.current = t0.addingTimeInterval(86_400 * 30)
        maxMinutes = ContactMaxAge.never
        let monitor = makeMonitor()
        monitor.evaluate()

        XCTAssertTrue(monitor.hidden.isEmpty)
        XCTAssertTrue(fake.removed.isEmpty)
        XCTAssertEqual(fake.events.count, 1)
        XCTAssertEqual(fake.participants.count, 1)
    }

    func testAPlacedMarkerStaysWhateverItsAge() {
        fake.events = [report(uid: "7d1f6e1c-hostile", type: "a-h-G", how: "h-e", receivedAt: t0),
                       report(uid: "7d1f6e1c-friend", type: "a-f-G", how: "h-e", receivedAt: t0),
                       report(uid: "marker-AABB", how: "h-g-i-g-o", receivedAt: t0)]
        clock.current = t0.addingTimeInterval(86_400)
        let monitor = makeMonitor()
        monitor.evaluate()

        XCTAssertTrue(monitor.hidden.isEmpty)
        XCTAssertTrue(fake.removed.isEmpty)
        XCTAssertEqual(fake.events.count, 3)
    }

    func testStartingTwiceKeepsOneTimerAndStopEndsIt() {
        fake.events = [report(receivedAt: t0)]
        let monitor = makeMonitor()
        monitor.start()
        monitor.start()
        clock.current = t0.addingTimeInterval(minutes(6))
        waitUntil("the timer to hide the contact") { monitor.hidden[bravo] != nil }

        monitor.stop()
        clock.current = t0.addingTimeInterval(minutes(20))
        // A stopped monitor makes no more passes. The window is the evidence: ten
        // timer intervals would have removed the contact.
        observe(for: 0.2)
        XCTAssertEqual(fake.events.count, 1, "a stopped monitor removes nothing")
    }
}

// MARK: - Removing a contact leaves its chat alone

final class ContactRemovalKeepsChatTests: XCTestCase {

    func testRemovingAContactKeepsItsConversationAndMessages() {
        let manager = ChatManager.shared
        // Put back exactly what was there, in memory and on disk (removing a contact
        // saves the contact list).
        let savedParticipants = manager.participants
        let savedConversations = manager.conversations
        let savedMessages = manager.messages
        let onDisk = ChatPersistence.shared.loadParticipants()
        defer {
            manager.participants = savedParticipants
            manager.conversations = savedConversations
            manager.messages = savedMessages
            ChatPersistence.shared.saveParticipants(onDisk)
        }

        let gone = contact("ANDROID-bravo2")
        let stays = contact("ANDROID-charlie3")
        let thread = Conversation(id: "DM-test-bravo2", title: "BRAVO-2", participants: [gone], isGroupChat: false)
        let message = ChatMessage(conversationId: thread.id, senderId: gone.id, senderCallsign: "BRAVO-2",
                                  messageText: "on my way")
        manager.participants = [gone, stays]
        manager.conversations = [thread]
        manager.messages = [message]

        manager.removeParticipants(ids: [gone.id])

        XCTAssertEqual(manager.participants.map(\.id), [stays.id], "the contact is gone from the list")
        XCTAssertEqual(manager.conversations.map(\.id), [thread.id], "its conversation is still there")
        XCTAssertEqual(manager.conversations.first?.participants.map(\.id), [gone.id])
        XCTAssertEqual(manager.messages.map(\.id), [message.id], "and so are its messages")
        XCTAssertEqual(manager.getMessages(for: thread.id).count, 1)
    }

    func testRemovingNobodyChangesNothing() {
        let manager = ChatManager.shared
        let saved = manager.participants
        let onDisk = ChatPersistence.shared.loadParticipants()
        defer {
            manager.participants = saved
            ChatPersistence.shared.saveParticipants(onDisk)
        }
        manager.participants = [contact("ANDROID-a")]

        manager.removeParticipants(ids: [])
        manager.removeParticipants(ids: ["ANDROID-not-there"])

        XCTAssertEqual(manager.participants.map(\.id), ["ANDROID-a"])
    }
}
