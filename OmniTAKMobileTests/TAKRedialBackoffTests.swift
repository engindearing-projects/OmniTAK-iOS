//
//  TAKRedialBackoffTests.swift
//  OmniTAKMobileTests
//
//  How long to wait before dialing a TAK server again (#154): 0, 2, 4, 8, 16,
//  30 seconds, then 30 for ever. A connection that held for ten seconds starts
//  the delays over. One that dropped sooner does not.
//

import XCTest
@testable import OmniTAK

final class TAKRedialBackoffTests: XCTestCase {

    private func delays(_ backoff: inout TAKRedialBackoff, _ count: Int) -> [TimeInterval] {
        (0..<count).map { _ in backoff.nextDelay() }
    }

    func testTheDelaysAreZeroTwoFourEightSixteenThirtyThenThirtyForEver() {
        var backoff = TAKRedialBackoff()
        XCTAssertEqual(delays(&backoff, 7), [0, 2, 4, 8, 16, 30, 30])
        XCTAssertEqual(delays(&backoff, 50), Array(repeating: 30, count: 50), "30 for ever")
    }

    func testTheTableIsWhatTheIssueSays() {
        XCTAssertEqual(TAKRedialBackoff.delays, [0, 2, 4, 8, 16, 30])
        XCTAssertEqual(TAKRedialBackoff.heldLongEnough, 10)
    }

    func testAConnectionHeldForTenSecondsOrMoreStartsTheDelaysOver() {
        var backoff = TAKRedialBackoff()
        XCTAssertEqual(delays(&backoff, 4), [0, 2, 4, 8])
        backoff.connectionEnded(after: 10)
        XCTAssertEqual(delays(&backoff, 3), [0, 2, 4], "held for exactly ten seconds counts")
    }

    func testAConnectionHeldForAWhileStartsOverFromTheLongestDelayToo() {
        var backoff = TAKRedialBackoff()
        _ = delays(&backoff, 20)
        backoff.connectionEnded(after: 3600)
        XCTAssertEqual(backoff.nextDelay(), 0, "the next dial is at once")
        XCTAssertEqual(backoff.nextDelay(), 2)
    }

    func testAConnectionThatDroppedAtOnceDoesNotStartTheDelaysOver() {
        var backoff = TAKRedialBackoff()
        XCTAssertEqual(delays(&backoff, 3), [0, 2, 4])
        // A server that accepts and drops at once: up for 9.999 s, then for 0.
        backoff.connectionEnded(after: 9.999)
        XCTAssertEqual(backoff.nextDelay(), 8, "carries on, not back to 0")
        backoff.connectionEnded(after: 0)
        XCTAssertEqual(backoff.nextDelay(), 16)
        backoff.connectionEnded(after: 0.2)
        XCTAssertEqual(backoff.nextDelay(), 30)
    }

    func testAServerThatAcceptsAndDropsAtOnceIsNotDialedInATightLoop() {
        var backoff = TAKRedialBackoff()
        var waited: [TimeInterval] = []
        // The first dial is made at once; each connection then lasts a fraction
        // of a second before the server drops it.
        for _ in 0..<8 {
            backoff.connectionEnded(after: 0.05)
            waited.append(backoff.nextDelay())
        }
        XCTAssertEqual(waited, [0, 2, 4, 8, 16, 30, 30, 30])
    }

    func testADialThatNeverCameUpCountsAsHeldForZero() {
        var backoff = TAKRedialBackoff()
        backoff.connectionEnded(after: 0)
        XCTAssertEqual(backoff.nextDelay(), 0, "the first failed dial is retried at once")
        backoff.connectionEnded(after: 0)
        XCTAssertEqual(backoff.nextDelay(), 2)
    }
}
