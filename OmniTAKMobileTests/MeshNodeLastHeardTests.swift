//
//  MeshNodeLastHeardTests.swift
//  OmniTAKMobileTests
//
//  #146: a node's "last heard" can be unknown, and unknown is neither "now"
//  nor 1970. A radio sends last_heard = 0 for a node it has no time for. The
//  decoder used to turn that into "now" (or, with the wrong field number, into
//  a date in 1970), so the node list showed a fresh node or "487000h ago".
//
//  Covers the model (MeshNode.lastHeard is optional, its labels, how a later
//  frame merges), saved data that predates the change, and what the CoT
//  converter does with a known and an unknown last heard.
//
//  Node ids, names, coordinates and times are made up.
//

import XCTest
@testable import OmniTAK

final class MeshNodeLastHeardTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_790_003_600)
    private let oneHourAgo = Date(timeIntervalSince1970: 1_790_000_000)

    private func node(lastHeard: Date?, battery: Int? = nil, role: Int? = nil) -> MeshNode {
        MeshNode(
            id: 0x0A0B0C0D,
            shortName: "TNA",
            longName: "Test Node Alpha",
            position: MeshPosition(latitude: 1.2345678, longitude: -2.3456789, altitude: 15),
            lastHeard: lastHeard,
            snr: nil,
            hopDistance: nil,
            batteryLevel: battery,
            role: role
        )
    }

    // MARK: - Label

    func testUnknownLastHeardShowsADash() {
        XCTAssertEqual(node(lastHeard: nil).lastHeardLabel(now: now), MeshNode.unknownLastHeardLabel)
        XCTAssertEqual(MeshNode.unknownLastHeardLabel, "\u{2013}")
    }

    func testTheEpochShowsADashNotTensOfThousandsOfDays() {
        // A zero timestamp becomes this date once it is a Date.
        let label = MeshNode.lastHeardLabel(for: Date(timeIntervalSince1970: 0), now: now)
        XCTAssertEqual(label, MeshNode.unknownLastHeardLabel)
        XCTAssertFalse(label.contains("ago"))
    }

    func testAgeLabels() {
        func label(_ secondsAgo: TimeInterval) -> String {
            node(lastHeard: now.addingTimeInterval(-secondsAgo)).lastHeardLabel(now: now)
        }
        XCTAssertEqual(label(0), "0s ago")
        XCTAssertEqual(label(5), "5s ago")
        XCTAssertEqual(label(59), "59s ago")
        XCTAssertEqual(label(180), "3m ago")
        XCTAssertEqual(label(2 * 3600 + 120), "2h ago")
        XCTAssertEqual(label(3 * 86_400 + 3600), "3d ago")
    }

    func testALastHeardAheadOfNowReadsZeroSeconds() {
        // The radio's clock can run ahead of the phone's.
        XCTAssertEqual(node(lastHeard: now.addingTimeInterval(600)).lastHeardLabel(now: now), "0s ago")
    }

    // MARK: - Battery

    func testBatteryLabel() {
        XCTAssertNil(node(lastHeard: nil, battery: nil).batteryLabel)
        XCTAssertEqual(node(lastHeard: nil, battery: 0).batteryLabel, "0%")
        XCTAssertEqual(node(lastHeard: nil, battery: 64).batteryLabel, "64%")
        XCTAssertEqual(node(lastHeard: nil, battery: 100).batteryLabel, "100%")
    }

    func testAboveOneHundredMeansExternalPower() {
        // telemetry.proto: battery_level above 100 means the node is powered.
        let powered = node(lastHeard: nil, battery: 101)
        XCTAssertTrue(powered.isPowered)
        XCTAssertEqual(powered.batteryLabel, "powered")
        XCTAssertEqual(powered.batteryPercentCapped, 100)

        XCTAssertFalse(node(lastHeard: nil, battery: 100).isPowered)
        XCTAssertFalse(node(lastHeard: nil, battery: nil).isPowered)
    }

    // MARK: - Merging a later frame

    func testAnUnknownLastHeardDoesNotEraseAKnownOne() {
        let merged = node(lastHeard: nil).carryingForward(from: node(lastHeard: oneHourAgo))
        XCTAssertEqual(merged.lastHeard, oneHourAgo)
    }

    func testAKnownLastHeardReplacesTheOldOne() {
        let merged = node(lastHeard: now).carryingForward(from: node(lastHeard: oneHourAgo))
        XCTAssertEqual(merged.lastHeard, now)
    }

    func testTheRoleIsCarriedForwardToo() {
        let merged = node(lastHeard: now, role: nil).carryingForward(from: node(lastHeard: nil, role: MeshNode.roleTAK))
        XCTAssertEqual(merged.role, MeshNode.roleTAK)
    }

    func testAFirstFrameHasNothingToCarryForward() {
        let first = node(lastHeard: nil)
        XCTAssertEqual(first.carryingForward(from: nil), first)
    }

    func testNoteHeardOnlyMovesForward() {
        var unknown = node(lastHeard: nil)
        unknown.noteHeard(at: oneHourAgo)
        XCTAssertEqual(unknown.lastHeard, oneHourAgo, "a heard packet makes an unknown last heard known")

        var known = node(lastHeard: now)
        known.noteHeard(at: oneHourAgo)
        XCTAssertEqual(known.lastHeard, now, "a queued older packet does not pull it back")

        var older = node(lastHeard: oneHourAgo)
        older.noteHeard(at: now)
        XCTAssertEqual(older.lastHeard, now)
    }

    // MARK: - Saved data

    func testSavedDataFromBeforeLastHeardWasOptionalStillDecodes() throws {
        // lastHeard was a non-optional Date, which the default JSON strategy
        // writes as seconds since 2001-01-01.
        let legacy = Data("""
        {"id":168496141,"shortName":"TNA","longName":"Test Node Alpha","lastHeard":780000000.5}
        """.utf8)
        let decoded = try JSONDecoder().decode(MeshNode.self, from: legacy)
        XCTAssertEqual(decoded.id, 0x0A0B0C0D)
        XCTAssertEqual(decoded.lastHeard, Date(timeIntervalSinceReferenceDate: 780_000_000.5))
    }

    func testASavedNodeWithoutLastHeardDecodesAsUnknown() throws {
        let saved = Data("""
        {"id":168496141,"shortName":"TNA","longName":"Test Node Alpha"}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(MeshNode.self, from: saved).lastHeard)
    }

    func testAnUnknownLastHeardSurvivesARoundTrip() throws {
        let original = node(lastHeard: nil, battery: 55)
        let decoded = try JSONDecoder().decode(MeshNode.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.lastHeard)
    }

    // MARK: - CoT event

    private func event(_ node: MeshNode) throws -> CoTEvent {
        try XCTUnwrap(MeshtasticCoTConverter.toCoTEvent(node: node, now: now))
    }

    func testTheEventTimeIsWhenTheRadioLastHeardTheNode() throws {
        XCTAssertEqual(try event(node(lastHeard: oneHourAgo)).time, oneHourAgo)
    }

    func testTheEventTimeIsNeverAfterNow() throws {
        XCTAssertEqual(try event(node(lastHeard: now.addingTimeInterval(86_400))).time, now)
    }

    func testTheEventTimeIsTheBuildTimeWhenLastHeardIsUnknown() throws {
        // The event needs some time. The moment it is built is the true one. It
        // must not be 1970, which is where an unknown last heard used to land.
        let built = try event(node(lastHeard: nil)).time
        XCTAssertEqual(built, now)
        XCTAssertGreaterThan(built.timeIntervalSince1970, 1_000_000_000)
    }

    func testTheEventRemarksShowPoweredAboveOneHundred() throws {
        let powered = try XCTUnwrap(event(node(lastHeard: oneHourAgo, battery: 101)).detail.remarks)
        XCTAssertTrue(powered.contains("Bat: powered"), powered)
        XCTAssertFalse(powered.contains("101%"), powered)

        let normal = try XCTUnwrap(event(node(lastHeard: oneHourAgo, battery: 64)).detail.remarks)
        XCTAssertTrue(normal.contains("Bat: 64%"), normal)
    }

    func testTheContactBatteryIsCappedAtOneHundred() throws {
        XCTAssertEqual(try event(node(lastHeard: oneHourAgo, battery: 101)).detail.battery, 100)
        XCTAssertEqual(try event(node(lastHeard: oneHourAgo, battery: 64)).detail.battery, 64)
        XCTAssertNil(try event(node(lastHeard: oneHourAgo, battery: nil)).detail.battery)
    }

    // MARK: - CoT XML

    private func cotXML(_ node: MeshNode) throws -> String {
        try XCTUnwrap(MeshtasticCoTConverter.generateCoT(for: node, now: now))
    }

    func testTheXMLCarriesLastHeardWhenKnown() throws {
        let xml = try cotXML(node(lastHeard: oneHourAgo))
        XCTAssertTrue(xml.contains("<last_heard>\(CoTXMLBuilder.timestamp(oneHourAgo))</last_heard>"), xml)
        XCTAssertTrue(xml.contains("Last Heard: 1 hour ago"), xml)
        XCTAssertFalse(xml.contains("1970-"), xml)
    }

    func testTheXMLLeavesLastHeardOutWhenUnknown() throws {
        let xml = try cotXML(node(lastHeard: nil))
        XCTAssertFalse(xml.contains("<last_heard>"), xml)
        XCTAssertFalse(xml.contains("Last Heard:"), xml)
        XCTAssertFalse(xml.contains("1970-"), "an unknown last heard must not turn into 1970")
    }

    func testTheXMLRemarksShowPoweredAboveOneHundred() throws {
        let xml = try cotXML(node(lastHeard: oneHourAgo, battery: 101))
        XCTAssertTrue(xml.contains("Battery: powered"), xml)
        XCTAssertFalse(xml.contains("101%"), xml)
    }

    func testLastHeardSurvivesTheXMLRoundTrip() throws {
        let parsed = try XCTUnwrap(MeshtasticCoTConverter.parseMeshtasticNode(from: cotXML(node(lastHeard: oneHourAgo))))
        XCTAssertEqual(try XCTUnwrap(parsed.lastHeard).timeIntervalSince1970, oneHourAgo.timeIntervalSince1970, accuracy: 0.001)
    }

    func testAnUnknownLastHeardStaysUnknownThroughTheXMLRoundTrip() throws {
        let parsed = try XCTUnwrap(MeshtasticCoTConverter.parseMeshtasticNode(from: cotXML(node(lastHeard: nil))))
        XCTAssertNil(parsed.lastHeard, "absent last_heard must not become the time it was parsed")
    }
}
