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
        waitUntil(10, "the sender to give up on the silent server") { sender.endReason != nil }

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

    func testWhatIsKnownAboutTheServerCarriesToANewSender() {
        // The owner sets this from the previous sender for the same server.
        server.pingBehavior = .ignore
        connect(serverAnswersPings: true)
        waitUntil(10, "the sender to give up on a server it knew answers pings") { sender.endReason != nil }
        XCTAssertEqual(sender.endReason, "No response from server")
        XCTAssertTrue(sender.serverAnswersPings, "still readable after the session ended")
    }

    // MARK: - A closed stream

    func testTheServerClosingTheStreamEndsTheSession() {
        connect()
        waitForConnection()
        XCTAssertNil(sender.endReason)

        server.close(connection: 0)
        waitUntil("the session to end") { sender.endReason != nil }

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
        connect()
        waitForConnection()
        server.close(connection: 0)
        waitUntil("the session to end") { sender.endReason != nil }
        XCTAssertNil(sender.connectionParameters, "the connection is let go, not left half open")
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
        waitUntil(10, "the sender to give up on the silent server") { sender.endReason != nil }
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
        waitUntil(10, "the silent server to be given up on once monitoring is back") { sender.endReason != nil }
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
        connect()
        sender.disconnect()
        // The dial would have completed within milliseconds on loopback.
        observe(for: 0.5)
        XCTAssertTrue(recorder.states.isEmpty)
        XCTAssertTrue(recorder.dials.isEmpty)
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

    func testADialToAServerThatIsNotListeningEndsOnceAndTellsTheOwner() {
        let port = server.port
        server.stop()
        connect(port: port, connectTimeout: 0.7)
        waitUntil(10, "the dial to end") { sender.endReason != nil }

        let reason = sender.endReason ?? ""
        XCTAssertTrue(reason.hasPrefix("Connection failed") || reason.hasPrefix("Connect timed out"), reason)
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

        waitUntil(10, "the handshake to time out") { sender.endReason != nil }
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
        let queue = DispatchQueue(label: "test.udp.server")
        let lock = NSLock()
        var peers: [NWConnection] = []
        var datagrams = 0
        let listener = try NWListener(using: .udp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { connection in
            lock.lock(); peers.append(connection); lock.unlock()
            connection.start(queue: queue)
            func receiveNext() {
                connection.receiveMessage { data, _, _, error in
                    guard error == nil else { return }
                    lock.lock(); datagrams += 1; let first = datagrams == 1; lock.unlock()
                    // Once the client has sent its first datagram, answer with two.
                    if first {
                        for uid in ["ONE", "TWO"] {
                            let frame = LoopbackTAKServer.positionFrame(uid: uid)
                            connection.send(content: frame.data(using: .utf8), completion: .contentProcessed { _ in })
                        }
                    }
                    receiveNext()
                }
            }
            receiveNext()
        }
        listener.start(queue: queue)
        defer { listener.cancel() }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        let port = try XCTUnwrap(listener.port?.rawValue)

        connect(port: port, protocolType: "udp")
        waitUntil("the UDP connection to be up") { sender.isConnected }
        XCTAssertTrue(sender.send(xml: LoopbackTAKServer.positionFrame(uid: "CLIENT")))

        waitUntil("both datagrams to be delivered") { recorder.messages.count == 2 }
        XCTAssertNil(sender.endReason, "a datagram is a complete message, not the end of the connection")
        XCTAssertTrue(sender.isConnected)
        XCTAssertEqual(recorder.states, [true])

        // No liveness on UDP: with a ping after 0.3 s idle, the server would have
        // seen a second datagram within this window.
        observe(for: 0.8)
        lock.lock(); let seen = datagrams; lock.unlock()
        XCTAssertEqual(seen, 1, "only the client's own datagram: UDP is never pinged")
        XCTAssertEqual(recorder.messages.count, 2)
        XCTAssertNil(sender.endReason)
    }
}
