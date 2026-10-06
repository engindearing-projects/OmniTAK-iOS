//
//  LoopbackTAKServer.swift
//  OmniTAKMobileTests
//
//  A TAK server stand-in for tests: an in-process NWListener on loopback. It
//  reads CoT frames, records what it sees, and answers pings the way real
//  servers do, or does not. Used by the sender and service tests (#149, #154).
//
//  Everything it exposes is safe to read from the test thread while its own
//  queue is writing.
//

import XCTest
import Network
@testable import OmniTAK

final class LoopbackTAKServer {

    /// How the server treats a ping (CoT type t-x-c-t).
    enum PingBehavior {
        /// A pong with double-quoted attributes.
        case answerDoubleQuoted
        /// A pong written the way a TAK Server writes it: single quotes.
        case answerSingleQuoted
        /// The ping itself, sent back (OpenTAKServer).
        case echo
        /// Nothing. A plain CoT listener, or a server whose path has died.
        case ignore
    }

    struct Frame {
        let raw: String
        var type: String? { TAKPing.eventType(of: raw) }
        var uid: String? { TAKPing.eventUID(of: raw) }
    }

    private final class Peer {
        let connection: NWConnection
        var buffer = ""
        var frames: [Frame] = []
        var closedByClient = false
        var closedByServer = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "test.loopback.tak")
    private let lock = NSLock()
    private var listener: NWListener?
    private var peers: [Peer] = []
    private var behavior: PingBehavior
    private var closeAtOnce = false
    private(set) var port: UInt16 = 0

    init(pingBehavior: PingBehavior = .answerDoubleQuoted) {
        self.behavior = pingBehavior
    }

    deinit { stop() }

    // MARK: - Control

    /// Start listening on an ephemeral port on 127.0.0.1 only. Returns when it
    /// is ready.
    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            listener.cancel()
            throw NSError(domain: "LoopbackTAKServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener did not start"])
        }
        self.listener = listener
        self.port = bound
    }

    /// Stop listening and close every connection.
    func stop() {
        lock.lock()
        let l = listener
        listener = nil
        let all = peers
        for peer in all { peer.closedByServer = true }
        lock.unlock()
        l?.cancel()
        for peer in all { peer.connection.cancel() }
    }

    var pingBehavior: PingBehavior {
        get { lock.lock(); defer { lock.unlock() }; return behavior }
        set { lock.lock(); behavior = newValue; lock.unlock() }
    }

    /// Accept each new connection and close it at once.
    var closeNewConnectionsAtOnce: Bool {
        get { lock.lock(); defer { lock.unlock() }; return closeAtOnce }
        set { lock.lock(); closeAtOnce = newValue; lock.unlock() }
    }

    // MARK: - What it saw

    var acceptedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return peers.count
    }

    /// Pings received, over all connections.
    var pingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return peers.reduce(0) { $0 + $1.frames.filter { $0.type == TAKPing.pingType }.count }
    }

    /// Frames that are not pings, over all connections.
    var eventCount: Int {
        lock.lock(); defer { lock.unlock() }
        return peers.reduce(0) { $0 + $1.frames.filter { $0.type != TAKPing.pingType }.count }
    }

    /// Every frame received, over all connections, in arrival order per connection.
    var allFrames: [Frame] {
        lock.lock(); defer { lock.unlock() }
        return peers.flatMap { $0.frames }
    }

    /// Connections the client closed (end of stream or reset seen), not counting
    /// the ones this server closed itself.
    var closedByClientCount: Int {
        lock.lock(); defer { lock.unlock() }
        return peers.filter { $0.closedByClient }.count
    }

    /// True when the client closed connection `index` (end of stream or reset
    /// seen), not counting a close this server did itself.
    func closedByClient(connection index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return index < peers.count && peers[index].closedByClient
    }

    // MARK: - Talking to the client

    /// Send raw text on connection `index` (in accept order).
    func send(_ raw: String, connection index: Int = 0) {
        lock.lock()
        let peer = index < peers.count ? peers[index] : nil
        lock.unlock()
        peer?.connection.send(content: raw.data(using: .utf8), completion: .contentProcessed { _ in })
    }

    /// Close connection `index` from the server side.
    func close(connection index: Int = 0) {
        lock.lock()
        let peer = index < peers.count ? peers[index] : nil
        peer?.closedByServer = true
        lock.unlock()
        peer?.connection.cancel()
    }

    // MARK: - Frames to send

    /// A CoT event the client should receive as data.
    static func positionFrame(uid: String) -> String {
        "<event version=\"2.0\" uid=\"\(uid)\" type=\"a-f-G-U-C\" how=\"m-g\" "
            + "time=\"2026-01-01T00:00:00Z\" start=\"2026-01-01T00:00:00Z\" stale=\"2026-01-01T00:03:00Z\">"
            + "<point lat=\"38.8895\" lon=\"-77.0353\" hae=\"0\" ce=\"10\" le=\"10\"/>"
            + "<detail><contact callsign=\"\(uid)\"/></detail></event>"
    }

    /// A pong. `quote` is the attribute quote character: a TAK Server writes
    /// single quotes.
    static func pongFrame(quote: Character) -> String {
        let q = String(quote)
        return "<event version=\(q)2.0\(q) uid=\(q)takPong\(q) type=\(q)t-x-c-t-r\(q) how=\(q)h-g-i-g-o\(q) "
            + "time=\(q)2026-01-01T00:00:00Z\(q) start=\(q)2026-01-01T00:00:00Z\(q) stale=\(q)2026-01-01T00:00:20Z\(q)>"
            + "<point lat=\(q)0.0\(q) lon=\(q)0.0\(q) hae=\(q)0.0\(q) ce=\(q)9999999.0\(q) le=\(q)9999999.0\(q)/></event>"
    }

    /// A ping from some other client, as a server that answers none would relay it.
    static func foreignPingFrame(uid: String = "SOMEONE-ELSE-ping") -> String {
        TAKPing.xml(uid: uid, now: Date())
    }

    // MARK: - Internals

    private func accept(_ connection: NWConnection) {
        let peer = Peer(connection)
        lock.lock()
        peers.append(peer)
        let shouldClose = closeAtOnce
        if shouldClose { peer.closedByServer = true }
        lock.unlock()

        connection.start(queue: queue)
        if shouldClose {
            connection.cancel()
            return
        }
        receive(on: peer)
    }

    private func receive(on peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak peer] data, _, isComplete, error in
            guard let self = self, let peer = peer else { return }
            if let data = data, !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                self.consume(text, from: peer)
            }
            if isComplete || error != nil {
                self.lock.lock()
                if !peer.closedByServer { peer.closedByClient = true }
                self.lock.unlock()
                return
            }
            self.receive(on: peer)
        }
    }

    private func consume(_ text: String, from peer: Peer) {
        var replies: [String] = []
        lock.lock()
        peer.buffer += text
        while let end = peer.buffer.range(of: "</event>") {
            let frame = String(peer.buffer[..<end.upperBound])
            peer.buffer = String(peer.buffer[end.upperBound...])
            peer.frames.append(Frame(raw: frame))
            if TAKPing.eventType(of: frame) == TAKPing.pingType {
                switch behavior {
                case .answerDoubleQuoted: replies.append(Self.pongFrame(quote: "\""))
                case .answerSingleQuoted: replies.append(Self.pongFrame(quote: "'"))
                case .echo: replies.append(frame)
                case .ignore: break
                }
            }
        }
        lock.unlock()
        for reply in replies {
            peer.connection.send(content: reply.data(using: .utf8), completion: .contentProcessed { _ in })
        }
    }
}

// MARK: - Waiting for a condition

extension XCTestCase {
    /// Spin the run loop until `condition` holds or `timeout` seconds pass.
    /// The assertion is the condition, never a fixed sleep: the wait ends as
    /// soon as it holds, and the deadline only bounds a failure.
    @discardableResult
    func waitUntil(
        _ timeout: TimeInterval,
        _ what: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if condition() { return true }
        XCTFail("Timed out after \(timeout) s waiting for \(what())", file: file, line: line)
        return false
    }

    /// The same with the default deadline of eight seconds.
    @discardableResult
    func waitUntil(
        _ what: @autoclosure () -> String,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        waitUntil(8, what(), file: file, line: line, condition)
    }

    /// Let `seconds` pass with the run loop running. Only for a claim that
    /// something does NOT happen: the window is the evidence, so say how long
    /// and why at the call site.
    func observe(for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}

// MARK: - What a sender reported

/// Records every callback of a DirectTCPSender, from whatever thread.
final class SenderRecorder {
    private let lock = NSLock()
    private var stateReports: [Bool] = []
    private var delivered: [String] = []
    private var dialResults: [Bool] = []
    private var connectedWhenDown: [Bool] = []

    func attach(to sender: DirectTCPSender) {
        sender.onConnectionStateChanged = { [weak self, weak sender] connected in
            self?.lock.lock()
            self?.stateReports.append(connected)
            if !connected { self?.connectedWhenDown.append(sender?.isConnected ?? true) }
            self?.lock.unlock()
        }
        sender.onMessageReceived = { [weak self] xml in
            self?.lock.lock()
            self?.delivered.append(xml)
            self?.lock.unlock()
        }
    }

    func recordDial(_ success: Bool) {
        lock.lock(); dialResults.append(success); lock.unlock()
    }

    /// true for up, false for down, in the order reported.
    var states: [Bool] { lock.lock(); defer { lock.unlock() }; return stateReports }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return delivered }
    var dials: [Bool] { lock.lock(); defer { lock.unlock() }; return dialResults }
    /// What `isConnected` read inside each down report.
    var isConnectedInsideDownReport: [Bool] { lock.lock(); defer { lock.unlock() }; return connectedWhenDown }
    var downCount: Int { states.filter { !$0 }.count }
}
