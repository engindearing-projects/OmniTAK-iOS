//
//  TransmitGateTests.swift
//  OmniTAKMobileTests
//
//  Event sequences for X Voice's PushToTalk transmit state machine. Most of
//  these depend on timing that is hard or impossible to reproduce by hand on a
//  phone (a 10-200 ms window before the system answers, a refused stop, a phone
//  call landing while a press is queued), so they're pinned down here.
//

import XCTest
@testable import OmniTAK

final class TransmitGateTests: XCTestCase {

    private typealias Action = TransmitGate.Action
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    /// The actions without diagnostic log lines.
    private func effects(_ actions: [Action]) -> [Action] {
        actions.filter { if case .log = $0 { return false }; return true }
    }

    // MARK: Normal press

    func testNormalPressAndRelease() {
        var gate = TransmitGate()
        XCTAssertEqual(effects(gate.press(now: t0)), [.requestBegin])
        XCTAssertEqual(effects(gate.didBegin(.ours)), [.notifyBegan(.ours)])
        XCTAssertTrue(gate.isTransmitting)
        XCTAssertEqual(effects(gate.release()), [.requestStop])
        XCTAssertEqual(effects(gate.didEnd(.ours)), [.notifyEnded(.ours)])
        XCTAssertEqual(effects(gate.afterEndNotified(now: t0)), [])
        XCTAssertFalse(gate.isTransmitting)
        XCTAssertFalse(gate.stopInFlight)
    }

    func testSystemTalkButtonIsPassedThrough() {
        var gate = TransmitGate()
        XCTAssertEqual(effects(gate.didBegin(.system)), [.notifyBegan(.system)])
        XCTAssertEqual(effects(gate.didEnd(.system)), [.notifyEnded(.system)])
    }

    // MARK: Quick tap (released before the system answered)

    func testQuickTapStopsTheTransmissionWhenItBegins() {
        var gate = TransmitGate()
        XCTAssertEqual(effects(gate.press(now: t0)), [.requestBegin])
        // Released before didBegin: nothing to stop yet, but it's remembered.
        XCTAssertEqual(effects(gate.release()), [])
        XCTAssertTrue(gate.stopWhenBegun)
        // The system begins: stop it at once, and don't start a burst.
        XCTAssertEqual(effects(gate.didBegin(.ours)), [.requestStop])
        XCTAssertTrue(gate.stopInFlight)
        XCTAssertEqual(effects(gate.didEnd(.ours)), [.notifyEnded(.ours)])
        XCTAssertFalse(gate.isTransmitting)
    }

    func testRepressBeforeBeginCancelsThePendingStop() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.release()
        // Pressed again before the system answered: the request already out
        // carries this press — no duplicate request, no stop.
        XCTAssertEqual(effects(gate.press(now: t0.addingTimeInterval(0.1))), [])
        XCTAssertFalse(gate.stopWhenBegun)
        XCTAssertEqual(effects(gate.didBegin(.ours)), [.notifyBegan(.ours)])
    }

    func testUnansweredBeginRequestExpires() {
        var gate = TransmitGate()
        XCTAssertEqual(effects(gate.press(now: t0)), [.requestBegin])
        let later = t0.addingTimeInterval(TransmitGate.beginRequestTimeout + 0.1)
        XCTAssertEqual(effects(gate.press(now: later)), [.requestBegin])
    }

    func testFailedBeginAllowsANewRequest() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        gate.failedToBegin()
        XCTAssertNil(gate.beginRequestedAt)
        XCTAssertEqual(effects(gate.press(now: t0.addingTimeInterval(0.1))), [.requestBegin])
    }

    // MARK: Refused stops (transmissionNotFound)

    func testRefusedStopIsRetriedUntilItTakes() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        XCTAssertEqual(effects(gate.release()), [.requestStop])
        XCTAssertEqual(effects(gate.failedToStop()), [.scheduleStopRetry])
        XCTAssertEqual(effects(gate.stopRetryFired()), [.requestStop])
        XCTAssertEqual(gate.stopAttempts, 2)
        XCTAssertEqual(effects(gate.didEnd(.ours)), [.notifyEnded(.ours)])
        XCTAssertFalse(gate.stopInFlight)
    }

    func testRetryAfterTheTransmissionEndedDoesNothing() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        XCTAssertEqual(effects(gate.failedToStop()), [.scheduleStopRetry])
        _ = gate.didEnd(.ours)
        XCTAssertEqual(effects(gate.stopRetryFired()), [])
        XCTAssertEqual(effects(gate.failedToStop()), [])
    }

    func testRefusedStopOfAQuickTapIsRetried() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.release()
        XCTAssertEqual(effects(gate.didBegin(.ours)), [.requestStop])
        XCTAssertEqual(effects(gate.failedToStop()), [.scheduleStopRetry])
        XCTAssertEqual(effects(gate.stopRetryFired()), [.requestStop])
    }

    func testStopGivesUpAfterTheRetryLimitAndTheNextPressTakesOver() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        for _ in 1..<TransmitGate.stopRetries {
            XCTAssertEqual(effects(gate.failedToStop()), [.scheduleStopRetry])
            XCTAssertEqual(effects(gate.stopRetryFired()), [.requestStop])
        }
        XCTAssertEqual(gate.stopAttempts, TransmitGate.stopRetries)
        // The last refusal: give up rather than retry forever.
        XCTAssertEqual(effects(gate.failedToStop()), [])
        XCTAssertFalse(gate.stopInFlight)
        XCTAssertTrue(gate.isTransmitting)
        // The system is still transmitting with nobody behind it: the next
        // press takes it immediately instead of waiting for a timeout.
        XCTAssertEqual(effects(gate.press(now: t0.addingTimeInterval(2))), [.notifyBegan(.ours)])
    }

    func testSecondGiveUpTreatsTheTransmissionAsGone() {
        // After a give-up the next press takes over. If the system refuses to
        // stop that one too, it has no transmission: the gate must not stay
        // "transmitting" forever (every later press would take over nothing).
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        for _ in 1..<TransmitGate.stopRetries { _ = gate.failedToStop(); _ = gate.stopRetryFired() }
        _ = gate.failedToStop()                                   // first give-up
        XCTAssertTrue(gate.isTransmitting)
        XCTAssertEqual(effects(gate.press(now: t0.addingTimeInterval(2))), [.notifyBegan(.ours)])
        XCTAssertEqual(effects(gate.release()), [.requestStop])
        for _ in 1..<TransmitGate.stopRetries { _ = gate.failedToStop(); _ = gate.stopRetryFired() }
        XCTAssertEqual(effects(gate.failedToStop()), [])          // second give-up
        XCTAssertFalse(gate.isTransmitting)
        // A fresh press now asks the system again.
        XCTAssertEqual(effects(gate.press(now: t0.addingTimeInterval(5))), [.requestBegin])
    }

    func testGiveUpCounterResetsWhenTheSystemReportsAnEnd() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        for _ in 1..<TransmitGate.stopRetries { _ = gate.failedToStop(); _ = gate.stopRetryFired() }
        _ = gate.failedToStop()
        XCTAssertEqual(gate.consecutiveGiveUps, 1)
        _ = gate.didEnd(.system)
        XCTAssertEqual(gate.consecutiveGiveUps, 0)
    }

    // MARK: System-initiated transmissions

    func testSystemBeginWhileOurRequestIsOutstanding() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        // The lock-screen Talk button wins the race: passed through as system.
        XCTAssertEqual(effects(gate.didBegin(.system)), [.notifyBegan(.system)])
        XCTAssertTrue(gate.isTransmitting)
    }

    func testFailedBeginDoesNotClearASystemTransmission() {
        var gate = TransmitGate()
        _ = gate.didBegin(.system)
        gate.failedToBegin()
        XCTAssertTrue(gate.isTransmitting)
    }

    func testTakingOverASystemTransmissionThenReleasingStopsIt() {
        var gate = TransmitGate()
        _ = gate.didBegin(.system)
        XCTAssertEqual(effects(gate.press(now: t0)), [.notifyBegan(.ours)])
        XCTAssertEqual(effects(gate.release()), [.requestStop])
    }

    func testOurBeginWithNoRequestOutstandingIsStillReported() {
        // The controller decides what to do with it (it stops it when idle).
        var gate = TransmitGate()
        XCTAssertEqual(effects(gate.didBegin(.ours)), [.notifyBegan(.ours)])
    }

    func testStaleStopRetryDoesNotStopTheNextTransmission() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        XCTAssertEqual(effects(gate.failedToStop()), [.scheduleStopRetry])
        _ = gate.didEnd(.ours)
        // A new transmission starts before the old retry timer fires.
        _ = gate.press(now: t0.addingTimeInterval(0.1))
        _ = gate.didBegin(.ours)
        XCTAssertEqual(effects(gate.stopRetryFired()), [])
        XCTAssertTrue(gate.isTransmitting)
    }

    // MARK: Press while a stop is going through

    func testPressDuringAStopIsQueuedAndBegunWhenItEnds() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        // Pressed again while the stop is going through: queued, no request.
        XCTAssertEqual(effects(gate.press(now: t0.addingTimeInterval(0.2))), [])
        XCTAssertTrue(gate.beginAfterEnd)
        XCTAssertEqual(effects(gate.didEnd(.ours)), [.notifyEnded(.ours)])
        XCTAssertEqual(effects(gate.afterEndNotified(now: t0.addingTimeInterval(0.4))), [.requestBegin])
        XCTAssertEqual(effects(gate.didBegin(.ours)), [.notifyBegan(.ours)])
    }

    func testReleasingAQueuedPressDropsIt() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        _ = gate.press(now: t0.addingTimeInterval(0.2))
        // Let go while still queued: the stop is already in flight, nothing new.
        XCTAssertEqual(effects(gate.release()), [])
        XCTAssertFalse(gate.beginAfterEnd)
        _ = gate.didEnd(.ours)
        XCTAssertEqual(effects(gate.afterEndNotified(now: t0.addingTimeInterval(0.4))), [])
    }

    func testQueuedPressTakesOverWhenTheStopIsNeverAccepted() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        _ = gate.press(now: t0.addingTimeInterval(0.2))
        for _ in 1..<TransmitGate.stopRetries {
            _ = gate.failedToStop()
            _ = gate.stopRetryFired()
        }
        // Give up: hand the still-running transmission to the queued press.
        XCTAssertEqual(effects(gate.failedToStop()), [.notifyBegan(.ours)])
        XCTAssertFalse(gate.beginAfterEnd)
    }

    // MARK: System end (e.g. a phone call) while a press is queued

    func testSystemEndWhileAPressIsQueuedDoesNotStartAnOrphanTransmission() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        _ = gate.press(now: t0.addingTimeInterval(0.2))     // queued
        XCTAssertTrue(gate.beginAfterEnd)
        // The system ends the transmission itself (a call).
        XCTAssertEqual(effects(gate.didEnd(.system)), [.notifyEnded(.system)])
        XCTAssertFalse(gate.isTransmitting)
        // The controller aborts the queued press in response — with the
        // transmission already gone. That must still drop the queued press...
        XCTAssertEqual(effects(gate.release()), [])
        // ...so nothing begins for the press that was just cancelled.
        XCTAssertEqual(effects(gate.afterEndNotified(now: t0.addingTimeInterval(0.4))), [])
        XCTAssertFalse(gate.isTransmitting)
        XCTAssertNil(gate.beginRequestedAt)
    }

    func testSystemEndWithoutAnAbortStillBeginsTheQueuedPress() {
        // If the controller keeps the press (it didn't abort), the queued press
        // proceeds as usual.
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        _ = gate.press(now: t0.addingTimeInterval(0.2))
        _ = gate.didEnd(.system)
        XCTAssertEqual(effects(gate.afterEndNotified(now: t0.addingTimeInterval(0.4))), [.requestBegin])
    }

    // MARK: Channel left

    func testResetClearsEverything() {
        var gate = TransmitGate()
        _ = gate.press(now: t0)
        _ = gate.didBegin(.ours)
        _ = gate.release()
        _ = gate.press(now: t0.addingTimeInterval(0.2))
        gate.reset()
        XCTAssertFalse(gate.isTransmitting)
        XCTAssertFalse(gate.stopInFlight)
        XCTAssertFalse(gate.beginAfterEnd)
        XCTAssertNil(gate.beginRequestedAt)
        XCTAssertEqual(effects(gate.press(now: t0.addingTimeInterval(1))), [.requestBegin])
    }
}
