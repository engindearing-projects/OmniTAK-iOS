//
//  TAKSenderLivenessTests.swift
//  OmniTAKMobileTests
//
//  A real DirectTCPSender against an in-process NWListener on loopback (#149,
//  #154): the ping, the give-up rule, a closed stream, and what the sender
//  tells its owner. Timings are short (ping after 0.3 s idle, 0.5 s to answer,
//  a tick every 0.1 s). Every wait is for a condition with a deadline. The few
//  claims that something does NOT happen can only be watched for a while, and
//  each says how long and why.
//

import XCTest
import Network
@testable import OmniTAK

final class TAKSenderLivenessTests: XCTestCase {

    private var server: LoopbackTAKServer!
    private var sender: DirectTCPSender!
    private var recorder: SenderRecorder!
    private var savedMonitorSwitch: Any?
    private let monitorKey = DirectTCPSender.monitorServerConnectionsKey

    override func setUpWithError() throws {
        try super.setUpWithError()
        // The switch is read from the real defaults: start from its default (on)
        // and put back whatever was there.
        savedMonitorSwitch = UserDefaults.standard.object(forKey: monitorKey)
        UserDefaults.standard.removeObject(forKey: monitorKey)
        server = LoopbackTAKServer()
        try server.start()
        recorder = SenderRecorder()
    }

    override func tearDown() {
        sender?.disconnect()
        server?.stop()
        if let saved = savedMonitorSwitch {
            UserDefaults.standard.set(saved, forKey: monitorKey)
        } else {
            UserDefaults.standard.removeObject(forKey: monitorKey)
        }
        sender = nil
        server = nil
        recorder = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func connect(
        pingIdle: TimeInterval = 0.3,
        pongWait: TimeInterval = 0.5,
        tick: TimeInterval = 0.1,
        serverAnswersPings: Bool = false,
        pingUID: String? = nil,
        port: UInt16? = nil,
        useTLS: Bool = false,
        protocolType: String = "tcp",
        connectTimeout: TimeInterval? = nil
    ) {
        let s = DirectTCPSender()
        s.livenessTiming = TAKLinkLiveness.Timing(pingIdle: pingIdle, pongWait: pongWait, tick: tick)
        s.serverAnswersPings = serverAnswersPings
        if let pingUID = pingUID { s.pingUID = { pingUID } }
        if let connectTimeout = connectTimeout { s.connectTimeoutSeconds = connectTimeout }
        recorder.attach(to: s)
        sender = s
        let rec = recorder!
        s.connect(host: "127.0.0.1", port: port ?? server.port, protocolType: protocolType, useTLS: useTLS) { success in
            rec.recordDial(success)
        }
    }

    /// Wait until the sender has ended its session AND told its owner. `endReason`
    /// is set a moment before the owner is told (the connection is cancelled in
    /// between), so a test that asserts what the owner was told has to wait for
    /// the report itself, not only for the reason.
    private func waitForEnd(
        _ what: String = "the session to end and be reported",
        timeout: TimeInterval = 8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitUntil(timeout, what, file: file, line: line) {
            sender.endReason != nil && recorder.downCount >= 1
        }
    }

    private func waitForConnection() {
        waitUntil("the sender to be connected and the server to have accepted it") {
            sender.isConnected && server.acceptedCount >= 1
        }
    }

    private func tcpOptions(of parameters: NWParameters?) -> NWProtocolTCP.Options? {
        parameters?.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options
    }

    // MARK: - Giving up

    func testAServerThatAnswersAndThenGoesSilentIsEndedWithNoResponseFromServer() {
        connect()
        waitUntil("the server to see a ping") { server.pingCount >= 1 }
        waitUntil("the sender to read the answer") { sender.serverAnswersPings }
        XCTAssertTrue(sender.isConnected)
        XCTAssertNil(sender.endReason)

        let silentAt = Date()
        server.pingBehavior = .ignore
        waitForEnd("the sender to give up on the silent server", timeout: 10)

        XCTAssertEqual(sender.endReason, "No response from server")
        XCTAssertFalse(sender.isConnected)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(silentAt), 0.5,
                                    "not at once: a ping has to go unanswered for the whole wait first")
        XCTAssertEqual(recorder.states, [true, false], "up once, down once")
        XCTAssertEqual(recorder.isConnectedInsideDownReport, [false], "not connected from the moment it ended")
        waitUntil("the server to see the connection cancelled") { server.closedByClientCount == 1 }
    }

    func testAServerThatNeverAnswersIsNotEnded() {
        server.pingBehavior = .ignore
        connect()
        let began = Date()
        waitUntil("six unanswered pings") { server.pingCount >= 6 }
        // Three full waits for an answer (3 x 0.5 s) must have passed, whichever
        // way the timers fell.
        let still = 1.5 - Date().timeIntervalSince(began)
        if still > 0 { observe(for: still) }

        XCTAssertGreaterThanOrEqual(server.pingCount, 6)
        XCTAssertNil(sender.endReason, "a plain CoT listener that ignores pings must not be dropped for being quiet")
        XCTAssertTrue(sender.isConnected)
        XCTAssertFalse(sender.serverAnswersPings)
        XCTAssertEqual(recorder.states, [true])
    }

    func testWhatIsKnownAboutOneServerIsForgottenWhenTheSenderIsPointedAtAnother() throws {
        // The older single connection reuses its sender for whatever server it is
        // asked to dial next.
        let other = LoopbackTAKServer(pingBehavior: .ignore)
        try other.start()
        defer { other.stop() }

        connect()                                    // server: answers pings
        waitUntil("the sender to read an answer") { sender.serverAnswersPings }

        let rec = recorder!
        // The same server again: what is known about it stays.
        sender.connect(host: "127.0.0.1", port: server.port) { rec.recordDial($0) }
        XCTAssertTrue(sender.serverAnswersPings, "the same host and port: still the server that answers pings")

        // Another port: a different server. Nothing is known about it.
        sender.connect(host: "127.0.0.1", port: other.port) { rec.recordDial($0) }
        XCTAssertFalse(sender.serverAnswersPings, "a different server has not answered anything yet")
    }

    func testAFreshSenderThatIsToldTheServerAnswersKeepsTheFactOnItsFirstDial() {
        // TAKService sets this before the first dial of every new sender.
        let s = DirectTCPSender()
        s.serverAnswersPings = true
        let rec = recorder!
        recorder.attach(to: s)
        sender = s
        s.connect(host: "127.0.0.1", port: server.port) { rec.recordDial($0) }
        XCTAssertTrue(s.serverAnswersPings)
    }

    func testWhatIsKnownAboutTheServerCarriesToANewSender() {
        // The owner sets this from the previous sender for the same server.
        server.pingBehavior = .ignore
        connect(serverAnswersPings: true)
        waitForEnd("the sender to give up on a server it knew answers pings", timeout: 10)
        XCTAssertEqual(sender.endReason, "No response from server")
        XCTAssertTrue(sender.serverAnswersPings, "still readable after the session ended")
    }

    // MARK: - A closed stream

    func testTheServerClosingTheStreamEndsTheSession() {
        // No pings in this test: a ping written just after the server closed could
        // fail first and end the session as a failed send instead.
        connect(pingIdle: 60, pongWait: 60, tick: 0.1)
        waitForConnection()
        XCTAssertNil(sender.endReason)

        server.close(connection: 0)
        waitForEnd("the session to end")

        XCTAssertEqual(sender.endReason, "Closed by server")
        XCTAssertFalse(sender.isConnected, "false the moment the stream ended, not when the next send fails")
        XCTAssertEqual(recorder.states, [true, false])
        XCTAssertEqual(recorder.isConnectedInsideDownReport, [false])
        XCTAssertFalse(sender.send(xml: "<event/>"), "nothing is sent on an ended session")
        // Reported once: a second report would have shown up by now.
        observe(for: 0.3)
        XCTAssertEqual(recorder.downCount, 1)
    }

    func testAnEndedSessionCancelsItsConnection() {
        // The server answers a ping and then ignores them, so it is the SENDER that
        // ends the session ("No response from server"). The server must then see
        // the client close its end: the connection is cancelled, not left half open.
        server.pingBehavior = .answerDoubleQuoted
        connect()
        waitUntil("the sender to read an answer") { sender.serverAnswersPings }
        server.pingBehavior = .ignore
        waitForEnd("the sender to give up on the silent server", timeout: 10)
        XCTAssertEqual(sender.endReason, "No response from server")
        waitUntil("the server to see the client close the connection") { server.closedByClient(connection: 0) }
        XCTAssertNil(sender.activeConnection, "and the sender lets go of it")
    }

    func testAFailedSendEndsTheSession() throws {
        // The write side of the connection is closed (a final message) while the
        // server keeps its end open: the receive side is healthy, so the only thing
        // that can end the session is the write that fails.
        //
        // The pinger is a writer too. With the short test timings its first ping
        // is due 0.3 s after the connect, and on a slow machine that fell inside
        // the 0.2 s window below, so a ping was the write that failed. The pinger
        // waits a minute here: the write under test is the only one.
        connect(pingIdle: 60, pongWait: 60, tick: 0.1)
        waitForConnection()
        let live = try XCTUnwrap(sender.activeConnection)
        live.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        observe(for: 0.2)
        XCTAssertNil(sender.endReason, "closing the write side alone ends nothing here")

        XCTAssertTrue(sender.send(xml: "<event/>"), "the write is accepted, then fails")
        waitForEnd("the failed write to end the session")
        XCTAssertTrue(sender.endReason?.hasPrefix("Send failed") == true, sender.endReason ?? "nil")
        XCTAssertFalse(sender.isConnected)
        XCTAssertEqual(recorder.states, [true, false], "reported down once")
        XCTAssertEqual(recorder.isConnectedInsideDownReport, [false])
    }

    // MARK: - Ping exchange stays out of the CoT pipeline

    func testPingsAndPongsAreNotDeliveredAndNotCounted() {
        connect(pongWait: 5)
        waitUntil("the sender to read an answer") { sender.serverAnswersPings }

        // Between two real events: another client's ping, a double-quoted pong,
        // a TAK Server style single-quoted pong, another ping.
        server.send(
            LoopbackTAKServer.foreignPingFrame()
                + LoopbackTAKServer.pongFrame(quote: "\"")
                + LoopbackTAKServer.positionFrame(uid: "FIRST")
                + LoopbackTAKServer.pongFrame(quote: "'")
                + LoopbackTAKServer.foreignPingFrame(uid: "ANOTHER-ping")
                + LoopbackTAKServer.positionFrame(uid: "SECOND")
        )
        waitUntil("both events to be delivered") { recorder.messages.count == 2 }
        // Pings from this side keep being answered meanwhile. None of it is delivered.
        observe(for: 0.4)

        XCTAssertEqual(recorder.messages.count, 2)
        XCTAssertTrue(recorder.messages[0].contains("FIRST"))
        XCTAssertTrue(recorder.messages[1].contains("SECOND"))
        XCTAssertEqual(sender.messagesReceived, 2, "pings and pongs are not counted as messages")
    }

    func testATAKServerStyleSingleQuotedPongCounts() {
        server.pingBehavior = .answerSingleQuoted
        connect()
        waitUntil("the sender to read the answer") { sender.serverAnswersPings }
        XCTAssertEqual(sender.messagesReceived, 0)
        XCTAssertTrue(recorder.messages.isEmpty, "the pong is not CoT data")

        // It counted as an answer, so silence from now on ends the session. A
        // pong that was dropped as invalid would have left the server one that
        // never answered, and never given up on.
        server.pingBehavior = .ignore
        waitForEnd("the sender to give up on the silent server", timeout: 10)
        XCTAssertEqual(sender.endReason, "No response from server")
    }

    func testOurOwnPingSentBackCountsAsAnAnswer() {
        server.pingBehavior = .echo
        connect(pongWait: 5)
        waitUntil("the sender to see its own ping come back") { sender.serverAnswersPings }
        XCTAssertEqual(sender.messagesReceived, 0)
        XCTAssertTrue(recorder.messages.isEmpty)
    }

    func testAnotherClientsPingProvesNothing() {
        server.pingBehavior = .ignore
        connect(pongWait: 5)
        waitUntil("a ping from the sender") { server.pingCount >= 1 }

        server.send(LoopbackTAKServer.foreignPingFrame() + LoopbackTAKServer.positionFrame(uid: "MARKER"))
        waitUntil("the marker to be delivered") { recorder.messages.count == 1 }

        XCTAssertFalse(sender.serverAnswersPings, "a relayed ping is not an answer")
        XCTAssertEqual(sender.messagesReceived, 1, "and it is not a message")
    }

    func testThePingCarriesTheUIDItWasGivenEscaped() {
        server.pingBehavior = .ignore
        connect(pingUID: "IOS-AB&C-ping")
        waitUntil("a ping") { server.pingCount >= 1 }
        let ping = server.allFrames.first { $0.type == TAKPing.pingType }
        XCTAssertEqual(ping?.uid, "IOS-AB&amp;C-ping")
    }

    func testTheDefaultPingUID() {
        server.pingBehavior = .ignore
        connect()
        waitUntil("a ping") { server.pingCount >= 1 }
        XCTAssertEqual(server.allFrames.first?.uid, "OmniTAK-ping")
    }

    // MARK: - The monitoring switch

    func testWithMonitoringOffNoPingIsSentAndItCanBeSwitchedBackOnWithoutReconnecting() {
        UserDefaults.standard.set(false, forKey: monitorKey)
        connect()
        waitForConnection()

        // Five ping intervals with the switch off: not one ping.
        observe(for: 1.5)
        XCTAssertEqual(server.pingCount, 0)
        XCTAssertTrue(sender.isConnected)

        UserDefaults.standard.set(true, forKey: monitorKey)
        waitUntil("pings to resume") { server.pingCount >= 1 }
        XCTAssertEqual(server.acceptedCount, 1, "without reconnecting")
        XCTAssertEqual(recorder.states, [true])
    }

    func testWithMonitoringOffASilentServerIsNotDroppedAndIsOnceItIsBackOn() {
        connect()
        waitUntil("the sender to read an answer") { sender.serverAnswersPings }

        UserDefaults.standard.set(false, forKey: monitorKey)
        server.pingBehavior = .ignore
        // Three seconds of silence is six times the wait for an answer.
        observe(for: 3)
        XCTAssertNil(sender.endReason, "no give-up while monitoring is off")
        XCTAssertTrue(sender.isConnected)

        UserDefaults.standard.set(true, forKey: monitorKey)
        waitForEnd("the silent server to be given up on once monitoring is back", timeout: 10)
        XCTAssertEqual(sender.endReason, "No response from server")
    }

    // MARK: - disconnect() is the operator's own

    func testDisconnectCancelsQuietlyAndNothingIsReportedAfterwards() {
        connect()
        waitForConnection()
        waitUntil("the dial to be reported") { recorder.dials == [true] }

        sender.disconnect()
        XCTAssertFalse(sender.isConnected, "from the moment of the call")
        let statesAtDisconnect = recorder.states

        server.send(LoopbackTAKServer.positionFrame(uid: "TOO-LATE"))
        waitUntil("the server to see the connection cancelled") { server.closedByClientCount == 1 }
        observe(for: 0.3)

        XCTAssertEqual(recorder.states, statesAtDisconnect, "no callback after disconnect()")
        XCTAssertEqual(recorder.states, [true])
        XCTAssertTrue(recorder.messages.isEmpty)
        XCTAssertEqual(recorder.dials, [true], "no dial result after the operator's disconnect")
        XCTAssertNil(sender.endReason, "the operator's own disconnect is not an end reason")
        XCTAssertFalse(sender.send(xml: "<event/>"))
    }

    func testDisconnectWhileTheDialIsInFlightReportsNothing() {
        // Hold the dial in flight for real: a TLS handshake to a server that
        // accepts the TCP connection and never answers stays in .preparing until
        // the connect timeout, which is set far away here.
        server.pingBehavior = .ignore
        connect(useTLS: true, connectTimeout: 60)
        waitUntil("the server to accept the TCP connection") { server.acceptedCount == 1 }
        XCTAssertFalse(sender.isConnected, "the handshake is still going: this dial is in flight")
        XCTAssertNotNil(sender.activeConnection)

        sender.disconnect()
        XCTAssertNil(sender.activeConnection)
        // The connection is cancelled, which the server sees ...
        waitUntil("the server to see the connection cancelled") { server.closedByClient(connection: 0) }
        // ... and the owner is told nothing: no state, no dial result.
        observe(for: 0.3)
        XCTAssertTrue(recorder.states.isEmpty)
        XCTAssertTrue(recorder.dials.isEmpty)
        XCTAssertNil(sender.endReason)
        XCTAssertFalse(sender.isConnected)
    }

    func testAnotherConnectOnTheSameSenderEndsTheFirstSessionQuietly() {
        // The legacy single connection reuses its sender.
        connect()
        waitForConnection()
        waitUntil("the dial to be reported") { recorder.dials == [true] }

        let rec = recorder!
        sender.connect(host: "127.0.0.1", port: server.port) { rec.recordDial($0) }
        waitUntil("a second connection to the server") { server.acceptedCount == 2 }
        waitUntil("the first connection to be closed") { server.closedByClientCount == 1 }
        waitUntil("the second dial to be reported") { recorder.dials == [true, true] }

        XCTAssertEqual(recorder.states, [true, true], "no down report for the session that was replaced")
        XCTAssertNil(sender.endReason)
        XCTAssertTrue(sender.isConnected)
    }

    // MARK: - A dial that does not come up

    func testADialToAServerThatIsNotListeningFailsAtOnceAndTellsTheOwnerOnce() {
        let port = server.port
        server.stop()
        // The connect timeout is far away: only the refusal itself can end this dial
        // inside the deadline below.
        connect(port: port, connectTimeout: 30)
        waitForEnd("the refused dial to end, long before the connect timeout", timeout: 5)

        XCTAssertEqual(sender.endReason, "Connection refused")
        XCTAssertFalse(sender.isConnected)
        XCTAssertEqual(recorder.dials, [false])
        XCTAssertEqual(recorder.states, [false], "down once, never up")
        observe(for: 0.3)
        XCTAssertEqual(recorder.states, [false])
        XCTAssertEqual(recorder.dials, [false])
    }

    func testATLSHandshakeThatNeverCompletesTimesOutAndUsesKeepalive() {
        // A server that accepts the TCP connection and says nothing never
        // answers the TLS hello.
        server.pingBehavior = .ignore
        connect(useTLS: true, connectTimeout: 0.8)

        let tcp = tcpOptions(of: sender.connectionParameters)
        XCTAssertEqual(tcp?.enableKeepalive, true, "TLS rides on TCP with keepalive")
        XCTAssertEqual(tcp?.keepaliveIdle, 30)
        XCTAssertEqual(tcp?.keepaliveInterval, 10)
        XCTAssertEqual(tcp?.keepaliveCount, 3)

        waitForEnd("the handshake to time out", timeout: 10)
        XCTAssertEqual(sender.endReason, "Connect timed out after 0.8s")
        XCTAssertEqual(recorder.dials, [false])
        XCTAssertEqual(recorder.states, [false])
    }

    // MARK: - Keepalive

    func testPlainTCPUsesKeepalive() {
        connect()
        waitForConnection()
        let tcp = tcpOptions(of: sender.connectionParameters)
        XCTAssertEqual(tcp?.enableKeepalive, true)
        XCTAssertEqual(tcp?.keepaliveIdle, 30)
        XCTAssertEqual(tcp?.keepaliveInterval, 10)
        XCTAssertEqual(tcp?.keepaliveCount, 3)
    }

    // MARK: - UDP

    func testAUDPDatagramIsNotTheEndOfTheConnectionAndUDPIsNeverPinged() throws {
        let udp = LoopbackUDPServer(repliesAfterFirstDatagram: ["ONE", "TWO"])
        try udp.start()
        defer { udp.stop() }

        connect(port: udp.port, protocolType: "udp")
        waitUntil("the UDP connection to be up") { sender.isConnected }
        XCTAssertTrue(sender.send(xml: LoopbackTAKServer.positionFrame(uid: "CLIENT")))

        waitUntil("both datagrams to be delivered") { recorder.messages.count == 2 }
        XCTAssertNil(sender.endReason, "a datagram is a complete message, not the end of the connection")
        XCTAssertTrue(sender.isConnected)
        XCTAssertEqual(recorder.states, [true])

        // No liveness on UDP: with a ping after 0.3 s idle, the server would have
        // seen a second datagram within this window.
        observe(for: 0.8)
        XCTAssertEqual(udp.datagrams, 1, "only the client's own datagram: UDP is never pinged")
        XCTAssertEqual(recorder.messages.count, 2)
        XCTAssertNil(sender.endReason)
    }

    func testAUDPPortThatIsNotListeningDoesNotEndTheConnection() throws {
        // A datagram to a closed UDP port comes back as an ICMP error. On main
        // an error on a UDP connection was only printed, and a UDP link must not
        // blink once per cycle because of it. Whether the platform reports that
        // error to the connection at all is up to it (it does not appear to on
        // loopback here), so this pins that nothing ends the session, and the
        // receive-error branch itself is not reached by a test.
        let udp = LoopbackUDPServer(repliesAfterFirstDatagram: [])
        try udp.start()
        let closedPort = udp.port
        udp.stop()

        connect(port: closedPort, protocolType: "udp")
        waitUntil("the UDP connection to be up") { sender.isConnected }
        for _ in 0..<5 {
            _ = sender.send(xml: LoopbackTAKServer.positionFrame(uid: "NOBODY-HOME"))
            observe(for: 0.1)
        }
        // Whatever error came back has been delivered by now.
        observe(for: 0.5)
        XCTAssertNil(sender.endReason, "an error on a UDP connection is logged, not a session end: \(sender.endReason ?? "")")
        XCTAssertTrue(sender.isConnected)
        XCTAssertEqual(recorder.states, [true])
    }

    func testAUDPConnectionThatIsCancelledFromOutsideEndsAndSaysSo() throws {
        // Only .failed and .cancelled end a UDP session. A cancel that did not come
        // from the sender is reported as the end of the session, once.
        let udp = LoopbackUDPServer(repliesAfterFirstDatagram: [])
        try udp.start()
        defer { udp.stop() }

        connect(port: udp.port, protocolType: "udp")
        waitUntil("the UDP connection to be up") { sender.isConnected }
        let live = try XCTUnwrap(sender.activeConnection)

        live.cancel()
        waitForEnd("the cancelled connection to be reported")
        XCTAssertEqual(sender.endReason, "Connection cancelled")
        XCTAssertEqual(recorder.states, [true, false])
    }

    func testAUDPSendErrorEndsNothing() throws {
        let udp = LoopbackUDPServer(repliesAfterFirstDatagram: [])
        try udp.start()
        defer { udp.stop() }

        connect(port: udp.port, protocolType: "udp")
        waitUntil("the UDP connection to be up") { sender.isConnected }

        // A datagram larger than UDP can carry: the write is accepted and then
        // fails. On main that was only logged. It must not end the connection, or a
        // UDP link would bounce on the first oversized message.
        XCTAssertTrue(sender.send(xml: String(repeating: "x", count: 70_000)))
        // A normal datagram right behind it still gets through.
        XCTAssertTrue(sender.send(xml: LoopbackTAKServer.positionFrame(uid: "AFTER")))
        waitUntil("the datagram after the failed one to reach the server") { udp.datagrams >= 1 }
        // The failed write's completion has run by now. (Only a window can show
        // that something did not happen.)
        observe(for: 0.3)

        XCTAssertNil(sender.endReason, "a UDP send error is logged, not a session end")
        XCTAssertTrue(sender.isConnected)
        XCTAssertEqual(recorder.states, [true])
        XCTAssertEqual(udp.datagrams, 1, "the oversized one never left")
    }
}

/// An in-process UDP listener on 127.0.0.1. It counts the datagrams it receives
/// and, after the first, sends back one datagram per entry in `replies`.
private final class LoopbackUDPServer {
    private let queue = DispatchQueue(label: "test.udp.server")
    private let lock = NSLock()
    private let replies: [String]
    private var peers: [NWConnection] = []
    private var count = 0
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(repliesAfterFirstDatagram replies: [String]) { self.replies = replies }

    var datagrams: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// Start listening on a free loopback port. A listener that fails or is not
    /// ready in time is replaced, up to three times. If none starts, the test is
    /// skipped and says so: the listener is this test's own stand-in server, not
    /// the code under test, and a busy CI machine has been seen to miss the
    /// deadline once.
    func start() throws {
        var lastState = "no state"
        for _ in 1...3 {
            let parameters = NWParameters.udp
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            let settled = DispatchSemaphore(value: 0)
            let stateLock = NSLock()
            var state: NWListener.State = .setup
            listener.stateUpdateHandler = { newState in
                stateLock.lock(); state = newState; stateLock.unlock()
                switch newState {
                case .ready, .failed: settled.signal()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                self.lock.lock(); self.peers.append(connection); self.lock.unlock()
                connection.start(queue: self.queue)
                self.receiveNext(on: connection)
            }
            listener.start(queue: queue)
            _ = settled.wait(timeout: .now() + 10)
            stateLock.lock(); let reached = state; stateLock.unlock()
            if case .ready = reached, let bound = listener.port?.rawValue {
                self.listener = listener
                port = bound
                return
            }
            lastState = "\(reached)"
            listener.cancel()
        }
        throw XCTSkip("The loopback UDP listener did not start (last state: \(lastState)).")
    }

    func stop() {
        listener?.cancel()
        lock.lock(); let all = peers; peers = []; lock.unlock()
        for peer in all { peer.cancel() }
    }

    private func receiveNext(on connection: NWConnection) {
        connection.receiveMessage { [weak self] _, _, _, error in
            guard let self = self, error == nil else { return }
            self.lock.lock(); self.count += 1; let first = self.count == 1; self.lock.unlock()
            if first {
                for uid in self.replies {
                    let frame = LoopbackTAKServer.positionFrame(uid: uid)
                    connection.send(content: frame.data(using: .utf8), completion: .contentProcessed { _ in })
                }
            }
            self.receiveNext(on: connection)
        }
    }
}
