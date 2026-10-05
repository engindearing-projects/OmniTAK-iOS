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

/// The operator's saved list as the service sees it in these tests: a plain array
/// the tests edit (switch a server off, delete it, change its port). The service
/// asks it through `serverLookup` and `enabledServers`, so `ServerManager` and the
/// servers saved on the simulator are never touched.
private final class SavedServers {
    var servers: [TAKServer] = []

    func lookup(_ id: UUID) -> TAKServer? { servers.first { $0.id == id } }
    var enabled: [TAKServer] { servers.filter { $0.enabled } }

    func edit(_ id: UUID, _ change: (inout TAKServer) -> Void) {
        if let index = servers.firstIndex(where: { $0.id == id }) { change(&servers[index]) }
    }
}

final class TAKServiceDialTests: XCTestCase {

    private var server: LoopbackTAKServer!
    private var record: TAKServer!
    private var saved: SavedServers!
    private let service = TAKService.shared
    private var originalLookup: ((UUID) -> TAKServer?)!
    private var originalEnabled: (() -> [TAKServer])!
    private var savedMonitorSwitch: Any?
    private let monitorKey = DirectTCPSender.monitorServerConnectionsKey

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The ping tests need the "Monitor Server Connections" switch on, which is
        // its default. A simulator where it was left off must not fail them: start
        // from the default and put back whatever was there.
        savedMonitorSwitch = UserDefaults.standard.object(forKey: monitorKey)
        UserDefaults.standard.removeObject(forKey: monitorKey)

        service.disconnect()
        originalLookup = service.serverLookup
        originalEnabled = service.enabledServers
        let list = SavedServers()
        saved = list
        service.serverLookup = { id in list.lookup(id) }
        service.enabledServers = { list.enabled }

        server = LoopbackTAKServer()
        try server.start()
        record = TAKServer(name: "Loopback", host: "127.0.0.1", port: server.port, protocolType: "tcp", useTLS: false)
        saved.servers = [record]
    }

    override func tearDown() {
        service.disconnect()
        service.livenessTiming = TAKLinkLiveness.Timing()
        service.connectTimeout = 15
        service.serverLookup = originalLookup
        service.enabledServers = originalEnabled
        server?.stop()
        server = nil
        record = nil
        saved = nil
        if let previous = savedMonitorSwitch {
            UserDefaults.standard.set(previous, forKey: monitorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: monitorKey)
        }
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

    /// A second loopback server, and a record for it.
    private func anotherServer(name: String = "Other", enabled: Bool = true) throws -> (server: LoopbackTAKServer, record: TAKServer) {
        let other = LoopbackTAKServer()
        try other.start()
        var r = TAKServer(name: name, host: "127.0.0.1", port: other.port, protocolType: "tcp", useTLS: false)
        r.enabled = enabled
        return (other, r)
    }

    // MARK: - One dial at a time, dial again after a drop

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

    // MARK: - Switching a server off stops the dials

    func testNothingDialsAfterDisconnectFromServer() throws {
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        // After the second connection dropped, the next dial is scheduled 2 s ahead.
        waitUntil("the link to be waiting for its third dial") {
            server.acceptedCount >= 2 && phase == .waiting
        }
        let accepted = server.acceptedCount
        let scheduled = try XCTUnwrap(service.scheduledDial(of: record.id))

        service.disconnectFromServer(serverId: record.id)
        XCTAssertNil(phase, "the operator's entry is gone")
        // Two guards keep the scheduled dial from dialing: it is cancelled here,
        // and when it runs it finds no entry to dial. This pins the cancel.
        XCTAssertTrue(scheduled.isCancelled, "the scheduled dial is cancelled, not only made harmless")

        // The scheduled dial would have run 2 s after the drop. Three seconds
        // is the evidence that nothing dialed.
        observe(for: 3)
        XCTAssertEqual(server.acceptedCount, accepted)
    }

    func testNothingDialsAfterDisconnectAll() throws {
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        waitUntil("the link to be waiting for its third dial") {
            server.acceptedCount >= 2 && phase == .waiting
        }
        let accepted = server.acceptedCount
        let scheduled = try XCTUnwrap(service.scheduledDial(of: record.id))

        service.disconnect()
        XCTAssertNil(phase)
        XCTAssertTrue(scheduled.isCancelled)
        observe(for: 3)
        XCTAssertEqual(server.acceptedCount, accepted)
    }

    // MARK: - Only a server that is saved and switched on is dialed, as saved now

    func testAServerThatIsSwitchedOffInTheSavedListIsNotDialed() {
        saved.edit(record.id) { $0.enabled = false }
        // The record the caller holds still says it is on. The saved list decides.
        service.connectToServer(record)
        XCTAssertNil(phase, "no entry for a server that is switched off")
        observe(for: 0.5)
        XCTAssertEqual(server.acceptedCount, 0)
    }

    func testAServerThatIsNotSavedIsNotDialed() {
        saved.servers = []
        service.connectToServer(record)
        XCTAssertNil(phase)
        observe(for: 0.5)
        XCTAssertEqual(server.acceptedCount, 0)
    }

    func testALinkForAServerThatWasSwitchedOffIsLetGoWhenItIsAskedForAgain() {
        service.connectToServer(record)
        waitUntilUp()

        saved.edit(record.id) { $0.enabled = false }
        service.connectToServer(record)        // what the foreground check does
        XCTAssertNil(phase, "the link is let go")
        waitUntil("the server to see the app close the link") { server.closedByClient(connection: 0) }
        observe(for: 0.5)
        XCTAssertEqual(server.acceptedCount, 1, "and nothing dials it again")
    }

    func testAWaitingLinkForAServerSwitchedOffIsNotDialedAtItsScheduledTime() {
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        waitUntil("the link to be waiting for its third dial") {
            server.acceptedCount >= 2 && phase == .waiting
        }
        let accepted = server.acceptedCount

        // Switched off in the saved list and nobody told the service: the path that
        // forgets to call disconnectFromServer. The dial scheduled 2 s ahead has to
        // find that out for itself.
        saved.edit(record.id) { $0.enabled = false }
        waitUntil(6, "the scheduled dial to let the link go") { phase == nil }
        observe(for: 0.5)
        XCTAssertEqual(server.acceptedCount, accepted)
    }

    func testAWaitingLinkForAServerThatWasDeletedIsNotDialedAtItsScheduledTime() {
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        waitUntil("the link to be waiting for its third dial") {
            server.acceptedCount >= 2 && phase == .waiting
        }
        let accepted = server.acceptedCount

        saved.servers = []
        waitUntil(6, "the scheduled dial to let the link go") { phase == nil }
        observe(for: 0.5)
        XCTAssertEqual(server.acceptedCount, accepted)
    }

    func testTheForegroundCheckDialsEveryServerThatIsOnAndNoneThatIsOff() throws {
        let second = try anotherServer(name: "Second")
        let off = try anotherServer(name: "Off", enabled: false)
        defer { second.server.stop(); off.server.stop() }
        saved.servers = [record, second.record, off.record]

        // Not the active server: every server that is switched on.
        service.verifyAndReconnectIfNeeded()
        waitUntil("both servers that are on to be dialed") {
            server.acceptedCount == 1 && second.server.acceptedCount == 1
        }
        // A dial for the server that is off would have arrived by now.
        observe(for: 0.5)
        XCTAssertEqual(off.server.acceptedCount, 0)
        XCTAssertNil(service.connectionPhase(of: off.record.id))

        // Asking again leaves the links that are up alone.
        service.verifyAndReconnectIfNeeded()
        observe(for: 0.3)
        XCTAssertEqual(server.acceptedCount, 1)
        XCTAssertEqual(second.server.acceptedCount, 1)
    }

    func testTheForegroundCheckDialsALinkThatIsWaitingAtOnce() {
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        waitUntil("the link to be waiting for its third dial") {
            server.acceptedCount >= 2 && phase == .waiting
        }
        let accepted = server.acceptedCount

        service.verifyAndReconnectIfNeeded()
        // The scheduled dial was 2 s away.
        waitUntil(1.5, "an immediate dial") { server.acceptedCount > accepted }
    }

    // MARK: - An edited server is dialed as it is saved now

    func testAnEditMadeWhileTheLinkWaitsIsUsedByTheNextDial() throws {
        let other = try anotherServer()
        defer { other.server.stop() }
        server.closeNewConnectionsAtOnce = true
        service.connectToServer(record)
        waitUntil("the link to be waiting for its third dial") {
            server.acceptedCount >= 2 && phase == .waiting
        }
        let before = server.acceptedCount

        saved.edit(record.id) { $0.port = other.record.port }
        // The dial that was scheduled goes to the new address, not the old one.
        waitUntil(6, "the scheduled dial to reach the edited address") { other.server.acceptedCount >= 1 }
        XCTAssertEqual(server.acceptedCount, before)
    }

    func testAnEditMadeWhileADialIsInFlightIsUsedByTheNextDial() throws {
        let other = try anotherServer()
        defer { other.server.stop() }
        // Hold the first dial in flight: a TLS handshake with a server that
        // accepts the TCP connection and says nothing.
        var tls = record!
        tls.useTLS = true
        tls.protocolType = "tls"
        tls.allowUntrustedTLS = true
        saved.servers = [tls]
        server.pingBehavior = .ignore
        service.connectTimeout = 2.0
        service.connectToServer(tls)
        waitUntil("the TLS dial to reach the server") { server.acceptedCount == 1 }
        XCTAssertEqual(phase, .dialing)

        // Edit it to a plain TCP server elsewhere. The dial in flight is not touched.
        saved.edit(record.id) { $0.useTLS = false; $0.protocolType = "tcp"; $0.port = other.record.port }
        XCTAssertEqual(phase, .dialing, "an edit does not cancel a dial in flight")

        // When that dial times out, the next one uses the record as saved now.
        waitUntil(10, "the next dial to reach the edited address") { other.server.acceptedCount == 1 }
        XCTAssertEqual(server.acceptedCount, 1, "the old address was not dialed again")
    }

    func testAnEditMadeWhileTheLinkIsUpDoesNotReconnectItButTheNextDialUsesIt() throws {
        let other = try anotherServer()
        defer { other.server.stop() }
        service.connectToServer(record)
        waitUntilUp()

        saved.edit(record.id) { $0.port = other.record.port }
        // An edit that reconnected the link would have dialed by now (main does not).
        observe(for: 0.6)
        XCTAssertEqual(server.acceptedCount, 1)
        XCTAssertEqual(other.server.acceptedCount, 0)
        XCTAssertFalse(server.closedByClient(connection: 0))
        XCTAssertTrue(service.isConnectedTo(serverId: record.id))

        // When the link drops, the dial that follows goes to the edited address.
        server.close(connection: 0)
        waitUntil(10, "the next dial to reach the edited address") { other.server.acceptedCount == 1 }
        XCTAssertEqual(server.acceptedCount, 1)
    }

    // MARK: - What the service hands to every sender

    func testWhatIsKnownAboutAServerCarriesToTheNextDial() {
        useShortLivenessTimings()
        service.connectToServer(record)
        waitUntilUp()
        // A second ping goes out only after the first one's answer was read, so
        // two pings mean the app has learned that this server answers.
        waitUntil("two pings, so the first answer has been read") { server.pingCount >= 2 }

        // The server stops answering and drops that connection. The app dials
        // again; the second connection gets no answers and the app closes it.
        // That shows the new sender knew this server answers pings: silence is
        // a reason to give up on a server that has answered before. (That a
        // server that never answered is not given up on is in
        // TAKSenderLivenessTests.)
        server.pingBehavior = .ignore
        server.close(connection: 0)
        waitUntil(10, "the app to close the second connection") { server.closedByClient(connection: 1) }
    }

    func testThePingUIDIsTheDeviceUIDPlusPing() {
        useShortLivenessTimings()
        server.pingBehavior = .ignore
        service.connectToServer(record)
        waitUntil("a ping") { server.pingCount >= 1 }
        let ping = server.allFrames.first { $0.type == TAKPing.pingType }
        XCTAssertEqual(ping?.uid, (PositionBroadcastService.shared.userUID + "-ping").xmlEscaped)
    }

    func testEverySenderTheServiceMakesGetsThePingUIDAndTheTimings() {
        service.livenessTiming = TAKLinkLiveness.Timing(pingIdle: 1, pongWait: 2, tick: 0.5)
        service.connectTimeout = 7
        let expected = PositionBroadcastService.shared.userUID + "-ping"

        // The older single connection is given the same in `connect`; this is the
        // function both use.
        let sender = DirectTCPSender()
        service.prepare(sender)
        XCTAssertEqual(sender.pingUID(), expected)
        XCTAssertEqual(sender.livenessTiming, service.livenessTiming)
        XCTAssertEqual(sender.connectTimeoutSeconds, 7)

        // From a thread that is not the main thread (the device uid lives in UIKit
        // state and is read on the main thread).
        let done = expectation(description: "prepared off the main thread")
        DispatchQueue.global().async {
            let other = DirectTCPSender()
            TAKService.shared.prepare(other)
            XCTAssertEqual(other.pingUID(), expected)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    func testConnectToServerFromABackgroundThreadDialsOnTheMainThread() {
        // Record which thread the saved list is asked on: main-thread state must
        // only be read there.
        let lock = NSLock()
        var askedOnMain: [Bool] = []
        let list = saved!
        service.serverLookup = { id in
            lock.lock(); askedOnMain.append(Thread.isMainThread); lock.unlock()
            return list.lookup(id)
        }

        let copy = record!
        // Enrollment and import code can call addServer, and so connectToServer,
        // from a thread that is not the main thread.
        DispatchQueue.global().async { TAKService.shared.connectToServer(copy) }
        waitUntil("the dial to reach the server") { server.acceptedCount == 1 }
        waitUntilUp()
        guard case .connected? = phase else { return XCTFail("expected connected, got \(String(describing: phase))") }

        lock.lock(); let threads = askedOnMain; lock.unlock()
        XCTAssertFalse(threads.isEmpty)
        XCTAssertTrue(threads.allSatisfy { $0 }, "the saved list is read on the main thread only")
    }
}
