//
//  TAKServiceDialTests.swift
//  OmniTAKMobileTests
//
//  What TAKService does with a server the operator has switched on (#154): one
//  dial at a time, dial again after a drop on a backoff, stop when the operator
//  switches the server off, and ignore a late callback from a sender that was
//  replaced.
//
//  The first class tests the rules on a ServerConnectionState with no sockets
//  and no timers. The second drives the real TAKService singleton against a
//  loopback server.
//

import XCTest
@testable import OmniTAK

// MARK: - The rules, without sockets

final class ServerConnectionRulesTests: XCTestCase {

    private let t0: UInt64 = 5_000_000_000_000

    private func at(_ seconds: Double) -> UInt64 { t0 + UInt64((seconds * 1_000_000_000).rounded()) }

    private func makeEntry() -> ServerConnectionState {
        let server = TAKServer(name: "Rules", host: "127.0.0.1", port: 8087)
        return ServerConnectionState(serverId: server.id, serverName: server.name, isConnected: false,
                                     sender: DirectTCPSender(), server: server)
    }

    /// A dial that fails: the entry is dialing and its sender ends. Then the
    /// scheduled dial runs and replaces the sender, as TAKService.dial does.
    private func failAndDialAgain(_ entry: inout ServerConnectionState) -> TimeInterval? {
        let delay = entry.senderEnded(entry.sender, now: at(0))
        XCTAssertTrue(entry.redialDue())
        entry.sender = DirectTCPSender()
        return delay
    }

    // MARK: - Asking for a server

    func testANewEntryIsDialing() {
        let entry = makeEntry()
        XCTAssertEqual(entry.phase, .dialing)
        XCTAssertFalse(entry.isConnected)
        XCTAssertFalse(entry.answersPings)
        XCTAssertNil(entry.pendingDial)
    }

    func testAskingAgainWhileADialIsInFlightLeavesItAlone() {
        var entry = makeEntry()
        let sender = entry.sender
        XCTAssertFalse(entry.wantedAgain(entry.server), "no second dial: the first would be leaked")
        XCTAssertEqual(entry.phase, .dialing)
        XCTAssertTrue(entry.sender === sender, "the sender is not replaced")
    }

    func testAskingAgainWhileTheLinkIsUpLeavesItAlone() {
        var entry = makeEntry()
        XCTAssertTrue(entry.senderUp(entry.sender, now: at(0)))
        XCTAssertFalse(entry.wantedAgain(entry.server))
        XCTAssertEqual(entry.phase, .connected(since: at(0)))
        XCTAssertTrue(entry.isConnected)
    }

    func testAskingAgainWhileWaitingCancelsTheWaitAndDialsNow() {
        var entry = makeEntry()
        XCTAssertEqual(entry.senderEnded(entry.sender, now: at(0)), 0)
        let scheduled = DispatchWorkItem {}
        entry.pendingDial = scheduled
        XCTAssertEqual(entry.phase, .waiting)

        var edited = entry.server
        edited.host = "10.0.0.9"
        XCTAssertTrue(entry.wantedAgain(edited), "the caller should dial now")
        XCTAssertTrue(scheduled.isCancelled, "the scheduled dial is cancelled")
        XCTAssertNil(entry.pendingDial)
        XCTAssertEqual(entry.phase, .dialing)
        XCTAssertEqual(entry.server.host, "10.0.0.9", "what is dialed is what the operator asked for")
    }

    // MARK: - Coming up

    func testASenderComingUpMovesADialToConnected() {
        var entry = makeEntry()
        XCTAssertTrue(entry.senderUp(entry.sender, now: at(3)))
        XCTAssertEqual(entry.phase, .connected(since: at(3)))
        XCTAssertTrue(entry.isConnected)
        XCTAssertFalse(entry.senderUp(entry.sender, now: at(4)), "a second up report is not news")
        XCTAssertEqual(entry.phase, .connected(since: at(3)), "and does not move the start")
    }

    func testAnUpReportFromAnotherSenderChangesNothing() {
        var entry = makeEntry()
        XCTAssertFalse(entry.senderUp(DirectTCPSender(), now: at(1)))
        XCTAssertEqual(entry.phase, .dialing)
        XCTAssertFalse(entry.isConnected)
    }

    // MARK: - Going down

    func testASenderEndsOnceHoweverManyTimesItReports() {
        var entry = makeEntry()
        let sender = entry.sender
        XCTAssertTrue(entry.senderUp(sender, now: at(0)))
        XCTAssertEqual(entry.senderEnded(sender, now: at(20)), 0, "held 20 s: dial again at once")
        XCTAssertNil(entry.senderEnded(sender, now: at(21)), "a second report schedules nothing")
        XCTAssertNil(entry.senderEnded(sender, now: at(60)))
        XCTAssertEqual(entry.phase, .waiting)
    }

    func testALateReportFromAReplacedSenderChangesNothing() {
        var entry = makeEntry()
        let old = entry.sender
        XCTAssertEqual(entry.senderEnded(old, now: at(0)), 0)
        XCTAssertTrue(entry.redialDue())
        // The dial replaces the sender, as TAKService.dial does.
        let current = DirectTCPSender()
        entry.sender = current
        XCTAssertEqual(entry.phase, .dialing)

        // Callbacks that were already on their way from the old sender arrive now.
        XCTAssertFalse(entry.senderUp(old, now: at(1)))
        XCTAssertNil(entry.senderEnded(old, now: at(1)))
        XCTAssertEqual(entry.phase, .dialing, "the live dial is untouched")
        XCTAssertFalse(entry.isConnected)

        // And the backoff did not move: the current sender's end gets the next delay, 2.
        XCTAssertEqual(entry.senderEnded(current, now: at(2)), 2)
    }

    func testTheDelaysAcrossDialsThatFail() {
        var entry = makeEntry()
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            guard let delay = failAndDialAgain(&entry) else { return XCTFail("a failed dial must schedule the next") }
            delays.append(delay)
        }
        XCTAssertEqual(delays, [0, 2, 4, 8, 16, 30, 30, 30])
    }

    func testAConnectionThatHeldTenSecondsStartsTheDelaysOver() {
        var entry = makeEntry()
        for _ in 0..<4 { _ = failAndDialAgain(&entry) }    // delays 0, 2, 4, 8 used up
        let sender = entry.sender
        XCTAssertTrue(entry.senderUp(sender, now: at(100)))
        XCTAssertEqual(entry.senderEnded(sender, now: at(110)), 0, "held exactly ten seconds: start over")
        XCTAssertTrue(entry.redialDue())
        entry.sender = DirectTCPSender()
        XCTAssertEqual(entry.senderEnded(entry.sender, now: at(111)), 2, "and the next failure is the second step again")
    }

    func testAConnectionThatDroppedAtOnceDoesNotStartTheDelaysOver() {
        var entry = makeEntry()
        for _ in 0..<3 { _ = failAndDialAgain(&entry) }    // delays 0, 2, 4 used up
        let sender = entry.sender
        XCTAssertTrue(entry.senderUp(sender, now: at(100)))
        XCTAssertEqual(entry.senderEnded(sender, now: at(109.9)), 8, "held 9.9 s: carries on, not 0")
    }

    func testWhatTheSenderLearnedAboutTheServerIsKept() {
        var entry = makeEntry()
        XCTAssertFalse(entry.answersPings)
        entry.sender.serverAnswersPings = true
        XCTAssertNotNil(entry.senderEnded(entry.sender, now: at(0)))
        XCTAssertTrue(entry.answersPings, "carried to the next sender")
    }

    func testAServerThatNeverAnsweredStillDoesNotAfterTheLinkDrops() {
        var entry = makeEntry()
        XCTAssertNotNil(entry.senderEnded(entry.sender, now: at(0)))
        XCTAssertFalse(entry.answersPings)
    }

    // MARK: - The scheduled dial

    func testAScheduledDialRunsOnlyWhileTheEntryIsStillWaiting() {
        var entry = makeEntry()
        XCTAssertFalse(entry.redialDue(), "dialing: nothing to run")

        XCTAssertTrue(entry.senderUp(entry.sender, now: at(0)))
        XCTAssertFalse(entry.redialDue(), "connected: nothing to run")

        XCTAssertNotNil(entry.senderEnded(entry.sender, now: at(30)))
        XCTAssertEqual(entry.phase, .waiting)
        // The operator asked for the server again before the timer fired: that
        // dials now, so the timer that fires later finds nothing to do.
        XCTAssertTrue(entry.wantedAgain(entry.server))
        XCTAssertFalse(entry.redialDue(), "the scheduled dial must not dial a second time")
    }

    func testAScheduledDialMovesTheEntryToDialing() {
        var entry = makeEntry()
        XCTAssertNotNil(entry.senderEnded(entry.sender, now: at(0)))
        entry.pendingDial = DispatchWorkItem {}
        XCTAssertTrue(entry.redialDue())
        XCTAssertEqual(entry.phase, .dialing)
        XCTAssertNil(entry.pendingDial)
    }
}

// MARK: - The service, against a loopback server

final class TAKServiceDialTests: XCTestCase {

    private var server: LoopbackTAKServer!
    private var record: TAKServer!
    private let service = TAKService.shared

    override func setUpWithError() throws {
        try super.setUpWithError()
        service.disconnect()
        server = LoopbackTAKServer()
        try server.start()
        record = TAKServer(name: "Loopback", host: "127.0.0.1", port: server.port, protocolType: "tcp", useTLS: false)
    }

    override func tearDown() {
        service.disconnect()
        service.livenessTiming = TAKLinkLiveness.Timing()
        server?.stop()
        server = nil
        record = nil
        super.tearDown()
    }

    /// Short timings for the senders the service makes: a ping after 0.3 s idle,
    /// 0.5 s to answer, a tick every 0.1 s.
    private func useShortLivenessTimings() {
        service.livenessTiming = TAKLinkLiveness.Timing(pingIdle: 0.3, pongWait: 0.5, tick: 0.1)
    }

    private var phase: ServerConnectionState.Phase? { service.connectionPhase(of: record.id) }

    /// The link is up when the server has accepted it and the service says so.
    private func waitUntilUp(_ what: String = "the link to come up") {
        waitUntil(what) { service.isConnectedTo(serverId: record.id) }
    }

    func testASecondConnectWhileTheFirstDialIsInFlightDoesNotDialAgain() {
        service.connectToServer(record)
        service.connectToServer(record)    // this thread has not yielded, so the first dial cannot have finished
        XCTAssertEqual(phase, .dialing)

        waitUntilUp()
        // A second dial would have reached the server by now.
        observe(for: 0.5)
        XCTAssertEqual(server.acceptedCount, 1)
    }

    func testConnectingAgainWhileTheLinkIsUpDialsNothing() {
        service.connectToServer(record)
        waitUntilUp()
        service.connectToServer(record)
        observe(for: 0.5)
        XCTAssertEqual(server.acceptedCount, 1)
        XCTAssertTrue(service.isConnectedTo(serverId: record.id))
    }

    func testALinkThatDropsIsDialedAgainAndComesUp() {
        service.connectToServer(record)
        waitUntilUp()
        XCTAssertEqual(server.acceptedCount, 1)

        server.close(connection: 0)
        waitUntil(10, "the app to dial again") { server.acceptedCount == 2 }
        waitUntilUp("the link to come up again")
        XCTAssertEqual(server.acceptedCount, 2)
    }

    func testAConnectionTheServerDropsAtOnceIsNotDialedInATightLoop() {
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        // The first drop is dialed again at once; the second waits 2 s.
        waitUntil("the second connection") { server.acceptedCount >= 2 }
        let secondAt = Date()
        waitUntil(10, "the third connection") { server.acceptedCount >= 3 }
        let waited = Date().timeIntervalSince(secondAt)
        XCTAssertGreaterThanOrEqual(waited, 1.5, "a connection that dropped at once does not start the delays over")
    }

    func testNothingDialsAfterDisconnectFromServer() {
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        // After the second connection dropped, the next dial is scheduled 2 s ahead.
        waitUntil("the link to be waiting for its third dial") {
            server.acceptedCount >= 2 && phase == .waiting
        }
        let accepted = server.acceptedCount

        service.disconnectFromServer(serverId: record.id)
        XCTAssertNil(phase, "the operator's entry is gone")

        // The scheduled dial would have run 2 s after the drop. Three seconds
        // is the evidence that it was cancelled.
        observe(for: 3)
        XCTAssertEqual(server.acceptedCount, accepted)
    }

    func testNothingDialsAfterDisconnectAll() {
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        waitUntil("the link to be waiting for its third dial") {
            server.acceptedCount >= 2 && phase == .waiting
        }
        let accepted = server.acceptedCount

        service.disconnect()
        XCTAssertNil(phase)
        observe(for: 3)
        XCTAssertEqual(server.acceptedCount, accepted)
    }

    func testWhatIsKnownAboutAServerCarriesToTheNextDial() {
        useShortLivenessTimings()
        service.connectToServer(record)
        waitUntilUp()
        // A second ping goes out only after the first one's answer was read.
        waitUntil("two pings, so the first answer has been read") { server.pingCount >= 2 }

        // The server stops answering and drops the connection. The new connection
        // gets no answer to its first ping. Only a sender that was told this
        // server answers pings gives up on that: for one that never heard an
        // answer, quiet is not a reason to drop it.
        server.pingBehavior = .ignore
        server.close(connection: 0)
        waitUntil(10, "the app to give up on the silent server on the second connection") {
            server.acceptedCount >= 2 && server.closedByClientCount >= 1
        }
    }

    func testThePingUIDIsTheDeviceUIDPlusPing() {
        useShortLivenessTimings()
        server.pingBehavior = .ignore
        service.connectToServer(record)
        waitUntil("a ping") { server.pingCount >= 1 }
        let ping = server.allFrames.first { $0.type == TAKPing.pingType }
        XCTAssertEqual(ping?.uid, (PositionBroadcastService.shared.userUID + "-ping").xmlEscaped)
    }

    func testConnectingAgainWhileWaitingDialsNowInsteadOfWaiting() {
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        waitUntil("the link to be waiting for its third dial") {
            server.acceptedCount >= 2 && phase == .waiting
        }
        let accepted = server.acceptedCount

        service.connectToServer(record)
        // The scheduled dial was 2 s away.
        waitUntil(1.5, "an immediate dial") { server.acceptedCount > accepted }
    }
}
