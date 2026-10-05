//
//  TAKLinkLivenessTests.swift
//  OmniTAKMobileTests
//
//  The ping and give-up rules of a TAK server connection (#149), run against a
//  fake clock. Time is whole seconds on a clock that starts at 1000, not at
//  zero, so a rule that quietly depends on "time since the beginning of time"
//  shows up.
//

import XCTest
@testable import OmniTAK

private let start = 1000.0

/// Seconds on the fake clock, as the monotonic nanoseconds the rules take.
private func ns(_ seconds: Double) -> UInt64 { UInt64((seconds * 1_000_000_000).rounded()) }

/// Run `tick` once a second between two moments, with `bytes` deciding whether
/// bytes arrived in that second. Returns what each tick said.
private func driveTicks(
    _ link: inout TAKLinkLiveness,
    from first: Int,
    through last: Int,
    bytes: (Int) -> Bool = { _ in false }
) -> [(second: Int, action: TAKLinkLiveness.Action)] {
    var said: [(Int, TAKLinkLiveness.Action)] = []
    for second in first...last {
        if bytes(second) { link.received(now: ns(start + Double(second))) }
        said.append((second, link.tick(now: ns(start + Double(second)))))
    }
    return said
}

final class TAKLinkLivenessTests: XCTestCase {

    // MARK: - When to ping

    func testNoPingInTheFirstFifteenSecondsOfAConnection() {
        for answers in [false, true] {
            var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: answers)
            for second in 1...14 {
                XCTAssertEqual(link.tick(now: ns(start + Double(second))), .nothing,
                               "answers=\(answers), second \(second)")
            }
            XCTAssertEqual(link.tick(now: ns(start + 14.999)), .nothing)
            XCTAssertEqual(link.tick(now: ns(start + 15)), .sendPing, "answers=\(answers)")
        }
    }

    func testUntilTheServerHasAnsweredAPingGoesOutEveryFifteenSecondsBusyStreamOrNot() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: false)
        // Bytes arrive every second: a busy stream.
        let said = driveTicks(&link, from: 1, through: 75, bytes: { _ in true })
        XCTAssertEqual(said.filter { $0.action == .sendPing }.map { $0.second }, [15, 30, 45, 60, 75])
        XCTAssertFalse(said.contains { $0.action == .giveUp })
    }

    func testAfterTheServerHasAnsweredAPingGoesOutOnlyWhenNothingArrivedForFifteenSeconds() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        // Busy for a minute: no ping at all.
        let busy = driveTicks(&link, from: 1, through: 60, bytes: { _ in true })
        XCTAssertTrue(busy.allSatisfy { $0.action == .nothing }, "a busy stream is never pinged")
        // Then silence. The last byte arrived at second 60, so the ping is due at 75.
        let quiet = driveTicks(&link, from: 61, through: 74)
        XCTAssertTrue(quiet.allSatisfy { $0.action == .nothing })
        XCTAssertEqual(link.tick(now: ns(start + 75)), .sendPing)
    }

    func testServerAnswersPingsIsAFactTheOwnerCanCarryOver() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: false)
        XCTAssertFalse(link.serverAnswersPings)
        link.answered()
        XCTAssertTrue(link.serverAnswersPings)
        let next = TAKLinkLiveness(now: ns(start), serverAnswersPings: link.serverAnswersPings)
        XCTAssertTrue(next.serverAnswersPings)
    }

    // MARK: - When to give up

    func testAServerThatAnsweredIsGivenUpOnWhenAPingHasHadNoReplyForTwentyFiveSecondsAtTwoLooksATickApart() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        // A look every second, so the spacing of the two looks is visible. The
        // default tick is 5 s.
        let said = driveTicks(&link, from: 1, through: 60)
        // The ping goes out at 15 (and again at 30 while it waits). The wait
        // began at 15, so 25 s later is 40: suspected, nothing yet. A look
        // less than a tick later (41 to 44) does not count as the second one.
        // 45 is a full tick after the first look.
        XCTAssertEqual(said.first { $0.action == .sendPing }?.second, 15)
        XCTAssertEqual(said.first { $0.second == 40 }?.action, .nothing, "the first look only suspects")
        XCTAssertTrue(said.filter { (41...44).contains($0.second) }.allSatisfy { $0.action == .nothing },
                      "a look less than a tick after the first is not the second look")
        XCTAssertEqual(said.first { $0.action == .giveUp }?.second, 45)
    }

    func testTwoLooksMillisecondsApartAfterAStallDoNotGiveUpButOneATickLaterDoes() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        XCTAssertEqual(link.tick(now: ns(start + 15)), .sendPing)
        // The process stalls for ten minutes. A timer that catches up fires
        // the look that finds the silence, and the next one right behind it.
        let after = start + 15 + 600
        XCTAssertEqual(link.tick(now: ns(after)), .nothing, "the first look only suspects")
        XCTAssertEqual(link.tick(now: ns(after + 0.001)), .nothing, "1 ms later is not a second chance for the answer to be read")
        XCTAssertEqual(link.tick(now: ns(after + 4.999)), .nothing, "still less than a tick after the first look")
        XCTAssertEqual(link.tick(now: ns(after + 5)), .giveUp, "a full tick after the first look")
    }

    func testBytesAfterTheCatchUpLookStillClearTheSuspicion() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        XCTAssertEqual(link.tick(now: ns(start + 15)), .sendPing)
        let after = start + 15 + 600
        XCTAssertEqual(link.tick(now: ns(after)), .nothing)
        XCTAssertEqual(link.tick(now: ns(after + 0.001)), .nothing)
        link.received(now: ns(after + 0.002))      // the answer, read at last
        XCTAssertEqual(link.tick(now: ns(after + 5)), .nothing, "not given up: the answer arrived")
    }

    func testTheWaitIsTwentyFiveSecondsNotLessAndExactlyTwentyFiveCounts() {
        // A long ping interval, so no second ping muddies the wait.
        let timing = TAKLinkLiveness.Timing(pingIdle: 100, pongWait: 25, tick: 5)
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true, timing: timing)
        XCTAssertEqual(link.tick(now: ns(start + 100)), .sendPing)
        XCTAssertEqual(link.tick(now: ns(start + 100 + 24.999)), .nothing, "24.999 s: not suspected yet")
        XCTAssertEqual(link.tick(now: ns(start + 100 + 25)), .nothing, "25 s: the first look only suspects")
        XCTAssertEqual(link.tick(now: ns(start + 100 + 26)), .nothing, "1 s later is less than a tick")
        XCTAssertEqual(link.tick(now: ns(start + 100 + 30)), .giveUp, "a tick after the first look")
    }

    func testBytesBetweenTheTwoLooksClearTheSuspicion() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        XCTAssertEqual(link.tick(now: ns(start + 15)), .sendPing)
        XCTAssertEqual(link.tick(now: ns(start + 40)), .nothing, "suspected")
        link.received(now: ns(start + 40.5))
        XCTAssertEqual(link.tick(now: ns(start + 41)), .nothing, "the answer arrived: not given up")
        // And the suspicion is gone: a later silent ping needs two fresh looks.
        // The last byte arrived at 40.5, so the next ping goes out at 56 and begins
        // a new wait: suspected at 81, given up on a tick later at 86.
        let later = driveTicks(&link, from: 42, through: 120)
        XCTAssertEqual(later.first { $0.action == .sendPing }?.second, 56)
        XCTAssertEqual(later.first { $0.action == .giveUp }?.second, 86,
                       "the new wait starts at the new ping, not the old one")
    }

    func testAWaitStartsAtThePingThatBeganItNotAtAnEarlierOne() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        XCTAssertEqual(link.tick(now: ns(start + 15)), .sendPing)   // first wait begins at 15
        link.received(now: ns(start + 16))                          // answered: the wait is over
        let said = driveTicks(&link, from: 17, through: 80)
        // Silence again from 16: the next ping is due at 31 and begins a new wait.
        XCTAssertEqual(said.first { $0.action == .sendPing }?.second, 31)
        // That wait began at 31, so it is suspected at 56 and given up on a tick
        // later, at 61. Had the wait stayed at 15 it would have ended at 45.
        XCTAssertEqual(said.first { $0.action == .giveUp }?.second, 61)
    }

    func testASecondPingWhileWaitingDoesNotMoveTheStartOfTheWait() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        let said = driveTicks(&link, from: 1, through: 60)
        let pings = said.filter { $0.action == .sendPing }.map { $0.second }
        XCTAssertEqual(pings, [15, 30], "a ping every 15 s while the wait lasts")
        // Suspected 25 s after the first ping (at 40), given up on a tick later,
        // at 45. Not counted from the second ping, which went out at 30.
        XCTAssertEqual(said.first { $0.action == .giveUp }?.second, 45)
    }

    func testAServerThatNeverAnsweredIsNeverGivenUpOnForBeingQuiet() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: false)
        // Twenty minutes with not one byte from the server, a tick every 5 s.
        var actions: [TAKLinkLiveness.Action] = []
        for step in 1...240 {
            actions.append(link.tick(now: ns(start + Double(step) * 5)))
        }
        XCTAssertFalse(actions.contains(.giveUp), "a plain CoT listener must not be dialed again in a loop")
        XCTAssertEqual(actions.filter { $0 == .sendPing }.count, 80, "a ping every 15 s all the same")
    }

    func testAClockJumpAloneNeverGivesUp() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        XCTAssertEqual(link.tick(now: ns(start + 15)), .sendPing)
        // The process is stalled for ten minutes (a phone in a pocket). The next
        // tick finds ten minutes of silence on its clock, but the server was
        // never given the chance to answer: this is only a suspicion.
        let after = start + 15 + 600
        XCTAssertEqual(link.tick(now: ns(after)), .nothing)
        // The answer was in the socket buffer all along. The receive loop reads
        // it before the next tick.
        link.received(now: ns(after + 1))
        XCTAssertEqual(link.tick(now: ns(after + 5)), .nothing)
    }

    func testWithNothingReadBetweenTheTwoLooksAClockJumpDoesGiveUp() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        XCTAssertEqual(link.tick(now: ns(start + 15)), .sendPing)
        let after = start + 15 + 600
        XCTAssertEqual(link.tick(now: ns(after)), .nothing)
        XCTAssertEqual(link.tick(now: ns(after + 5)), .giveUp)
    }

    func testIdleTimeAloneNeverEndsAConnection() {
        // No ping is waiting: the clock jumps ten minutes. The answer is a
        // ping, not a verdict.
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        XCTAssertEqual(link.tick(now: ns(start + 5)), .nothing)
        XCTAssertEqual(link.tick(now: ns(start + 5 + 600)), .sendPing)
    }

    func testAClockThatReadsBackwardsDoesNotTrap() {
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true)
        link.received(now: ns(start + 10))
        XCTAssertEqual(link.tick(now: ns(start + 5)), .nothing)
        XCTAssertEqual(link.tick(now: ns(start - 5)), .nothing)
    }

    func testTimingsCanBeShortened() {
        let timing = TAKLinkLiveness.Timing(pingIdle: 0.3, pongWait: 0.5, tick: 0.1)
        var link = TAKLinkLiveness(now: ns(start), serverAnswersPings: true, timing: timing)
        XCTAssertEqual(link.tick(now: ns(start + 0.2)), .nothing)
        XCTAssertEqual(link.tick(now: ns(start + 0.3)), .sendPing)
        XCTAssertEqual(link.tick(now: ns(start + 0.8)), .nothing, "suspected")
        XCTAssertEqual(link.tick(now: ns(start + 0.9)), .giveUp)
    }
}

// MARK: - The ping frame and how frames are read

private final class FrameReader: NSObject, XMLParserDelegate {
    var elements: [String] = []
    var event: [String: String] = [:]
    var point: [String: String] = [:]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        elements.append(elementName)
        if elementName == "event" { event = attributeDict }
        if elementName == "point" { point = attributeDict }
    }

    static func read(_ xml: String) -> FrameReader? {
        let reader = FrameReader()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = reader
        return parser.parse() ? reader : nil
    }
}

final class TAKPingTests: XCTestCase {

    // MARK: - The frame

    func testPingFrameIsTheSameAsAndroids() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000.25)
        let xml = TAKPing.xml(uid: "IOS-1234-ping", now: now)

        let frame = try XCTUnwrap(FrameReader.read(xml), "the ping must be well-formed XML")
        XCTAssertEqual(frame.elements, ["event", "point", "detail"])
        XCTAssertEqual(frame.event["version"], "2.0")
        XCTAssertEqual(frame.event["type"], "t-x-c-t")
        XCTAssertEqual(frame.event["uid"], "IOS-1234-ping")
        XCTAssertEqual(frame.event["how"], "m-g")
        XCTAssertEqual(frame.point["lat"], "0.0")
        XCTAssertEqual(frame.point["lon"], "0.0")
        XCTAssertEqual(frame.point["hae"], "0.0")
        XCTAssertEqual(frame.point["ce"], "9999999.0")
        XCTAssertEqual(frame.point["le"], "9999999.0")
        XCTAssertTrue(xml.hasSuffix("<detail/></event>"))

        let time = try XCTUnwrap(frame.event["time"])
        let startAttr = try XCTUnwrap(frame.event["start"])
        let stale = try XCTUnwrap(frame.event["stale"])
        XCTAssertEqual(time, startAttr, "time and start are both now")
        let timeDate = try XCTUnwrap(CoTXMLBuilder.timestampFormatter.date(from: time))
        let staleDate = try XCTUnwrap(CoTXMLBuilder.timestampFormatter.date(from: stale))
        XCTAssertEqual(timeDate.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(staleDate.timeIntervalSince(timeDate), 10, accuracy: 0.001, "stale is ten seconds after time")
    }

    func testPingUIDIsXMLEscaped() throws {
        let odd = "A&B<ping>\"it's\""
        let xml = TAKPing.xml(uid: odd, now: Date())
        let frame = try XCTUnwrap(FrameReader.read(xml), "an unescaped uid would break the XML")
        XCTAssertEqual(frame.event["uid"], odd, "escaped on the wire, the original after parsing")
        XCTAssertEqual(TAKPing.eventUID(of: xml), "A&amp;B&lt;ping&gt;&quot;it&apos;s&quot;")
    }

    // MARK: - Reading the start tag

    func testEventTypeAndUIDAnyQuotingOrderAndSpacing() {
        let cases: [(frame: String, type: String?, uid: String?)] = [
            ("<event version=\"2.0\" uid=\"u1\" type=\"a-f-G-U-C\" how=\"m-g\"><point lat=\"0\"/></event>", "a-f-G-U-C", "u1"),
            ("<event version='2.0' uid='takPong' type='t-x-c-t-r' how='h-g-i-g-o'><point lat='0'/></event>", "t-x-c-t-r", "takPong"),
            ("<event type=\"t-x-c-t\" uid=\"first\" version=\"2.0\"></event>", "t-x-c-t", "first"),
            ("<event type = 't-x-c-t'  uid  =  \"spaced\" ></event>", "t-x-c-t", "spaced"),
            ("<event\n\ttype\n=\n'tabbed'\n\tuid=\"lines\"\n>", "tabbed", "lines"),
            ("<event uid=\"mixed\" type='quotes'/>", "quotes", "mixed"),
            ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<event uid=\"decl\" type=\"t\"></event>", "t", "decl"),
            ("<event uid=\"it's\" type=\"t\"/>", "t", "it's"),
            ("<event uid='say \"hi\"' type='t'/>", "t", "say \"hi\""),
            ("<event uid=\"a>b\" type=\"t-x-c-t\"/>", "t-x-c-t", "a>b"),
            ("<event uid=\"\" type=\"\"/>", "", ""),
            ("<event uid=\"\u{00E9}-\u{00FC}\" type=\"t\"/>", "t", "\u{00E9}-\u{00FC}"),
            ("<event subtype=\"no\" type=\"yes\" uid=\"u\"/>", "yes", "u"),
            ("<event type=\"only-type\"/>", "only-type", nil),
            ("<event uid=\"only-uid\"/>", nil, "only-uid"),
        ]
        for (frame, type, uid) in cases {
            XCTAssertEqual(TAKPing.eventType(of: frame), type, "type of \(frame)")
            XCTAssertEqual(TAKPing.eventUID(of: frame), uid, "uid of \(frame)")
        }
    }

    func testATypeInsideAnotherAttributeIsNotTheType() {
        // A uid that happens to contain what looks like a type must not be
        // taken for one.
        let frame = "<event uid=\"x type='t-x-c-t'\" type=\"a-f-G-U-C\"/>"
        XCTAssertEqual(TAKPing.eventType(of: frame), "a-f-G-U-C")
        XCTAssertEqual(TAKPing.eventUID(of: frame), "x type='t-x-c-t'")
    }

    func testAFrameWithNoEventElement() {
        let frames = [
            "",
            "garbage",
            "<point lat=\"0\" lon=\"0\"/>",
            "<detail type='t-x-c-t' uid='x'/>",
            "<events type=\"t-x-c-t\" uid=\"x\"/>",
            "<eventual type=\"t-x-c-t\" uid=\"x\"/>",
            "<event",
            "<event type=\"t-x-c-t",
            "<event type=t-x-c-t>",
            "<remarks>&lt;event type=\"t-x-c-t\"/&gt;</remarks>",
        ]
        for frame in frames {
            XCTAssertNil(TAKPing.eventType(of: frame), "type of \(frame)")
            XCTAssertNil(TAKPing.eventUID(of: frame), "uid of \(frame)")
        }
    }

    // MARK: - Sorting frames

    func testAPongFromAServerCounts() {
        for quote in ["\"", "'"] as [Character] {
            let pong = LoopbackTAKServer.pongFrame(quote: quote)
            let kind = TAKPing.classify(pong, lastPingUID: nil)
            XCTAssertEqual(kind, .pong, "quote \(quote)")
            XCTAssertTrue(kind.answersOurPing)
            XCTAssertTrue(kind.isPingTraffic)
        }
    }

    func testOurOwnPingSentBackCounts() {
        let ours = TAKPing.xml(uid: "IOS-1-ping", now: Date())
        let kind = TAKPing.classify(ours, lastPingUID: "IOS-1-ping")
        XCTAssertEqual(kind, .ownPingEchoed)
        XCTAssertTrue(kind.answersOurPing)
        XCTAssertTrue(kind.isPingTraffic)
    }

    func testAnotherUIDsPingProvesNothing() {
        let theirs = TAKPing.xml(uid: "IOS-2-ping", now: Date())
        for last in ["IOS-1-ping", nil] as [String?] {
            let kind = TAKPing.classify(theirs, lastPingUID: last)
            XCTAssertEqual(kind, .otherPing, "last ping uid \(last ?? "none")")
            XCTAssertFalse(kind.answersOurPing)
            XCTAssertTrue(kind.isPingTraffic, "it is still consumed")
        }
    }

    func testOurPingWithACharacterThatGetsEscapedCounts() {
        let odd = "A&B<ping>"
        let frame = TAKPing.xml(uid: odd, now: Date())
        XCTAssertEqual(TAKPing.classify(frame, lastPingUID: odd), .ownPingEchoed)
    }

    func testEverythingElseGoesOn() {
        let position = LoopbackTAKServer.positionFrame(uid: "ALPHA-1")
        let kind = TAKPing.classify(position, lastPingUID: "IOS-1-ping")
        XCTAssertEqual(kind, .other)
        XCTAssertFalse(kind.answersOurPing)
        XCTAssertFalse(kind.isPingTraffic)
        XCTAssertEqual(TAKPing.classify("<event uid=\"x\"/>", lastPingUID: nil), .other, "no type")
        XCTAssertEqual(TAKPing.classify("not xml", lastPingUID: nil), .other)
    }

    func testTheTypeNamesAreTheTAKOnes() {
        XCTAssertEqual(TAKPing.pingType, "t-x-c-t")
        XCTAssertEqual(TAKPing.pongType, "t-x-c-t-r")
    }
}
