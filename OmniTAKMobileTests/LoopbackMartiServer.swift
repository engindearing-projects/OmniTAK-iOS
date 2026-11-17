//
//  LoopbackMartiServer.swift
//  OmniTAKMobileTests
//
//  A TAK Server stand-in for the Marti REST client: an in-process TLS
//  listener on loopback that speaks just enough HTTP/1.1 to answer the
//  endpoints the client probes. One instance plays one connector: the
//  certificate port (8443, client certificate required at the handshake)
//  or the enrollment port (8446, OAuth password grant or HTTP Basic).
//
//  Everything it exposes is safe to read from the test thread while its own
//  queue is writing.
//

import Foundation
import Network
import Security
import XCTest

final class LoopbackMartiServer {

    /// How this connector authenticates callers.
    enum Auth {
        /// Anything goes (a connector with no authentication at all).
        case open
        /// The TLS handshake must carry a client certificate; any one is accepted.
        case clientCertificate
        /// `POST /oauth/token` with these credentials issues `token`; the API
        /// then wants `Authorization: Bearer <token>` (TAK Server 5.x).
        case bearer(token: String, username: String, password: String)
        /// The API wants `Authorization: Basic` with these credentials
        /// (OpenTAKServer, taky).
        case basic(username: String, password: String)
    }

    struct Request: Equatable {
        let method: String
        let path: String          // without the query
        let query: [String: String]
        let headers: [String: String]  // lowercased names
    }

    let auth: Auth
    /// Whether `/oauth/token` exists at all (OpenTAKServer has no OAuth).
    var oauthEnabled = true

    private let identity: SecIdentity
    private let queue = DispatchQueue(label: "tests.loopback.marti")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var seen: [Request] = []

    init(identity: SecIdentity, auth: Auth) {
        self.identity = identity
        self.auth = auth
    }

    var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    /// Starts listening and returns the port.
    func start() throws -> UInt16 {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(options, try XCTUnwrap(sec_identity_create(identity)))
        if case .clientCertificate = auth {
            sec_protocol_options_set_peer_authentication_required(options, true)
            sec_protocol_options_set_verify_block(options, { _, _, complete in complete(true) }, queue)
        }
        let listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw NSError(domain: "LoopbackMartiServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener did not become ready"])
        }
        self.listener = listener
        return port
    }

    func stop() {
        listener?.cancel()
        lock.lock()
        connections.forEach { $0.cancel() }
        connections.removeAll()
        lock.unlock()
    }

    // MARK: HTTP

    private func accept(_ connection: NWConnection) {
        lock.lock(); connections.append(connection); lock.unlock()
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.lock(); self.seen.append(request); self.lock.unlock()
                let (status, body) = self.respond(to: request)
                let reason = status == 200 ? "OK" : status == 401 ? "Unauthorized" : status == 403 ? "Forbidden" : status == 404 ? "Not Found" : "Error"
                let head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.read(connection, buffer: buffer)
        }
    }

    /// A complete request (head plus any Content-Length body), or nil to keep reading.
    static func parse(_ buffer: Data) -> Request? {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.count - headEnd.upperBound >= contentLength else { return nil }
        let target = String(requestLine[1])
        let pathAndQuery = target.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count == 2 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        return Request(method: String(requestLine[0]), path: String(pathAndQuery[0]), query: query, headers: headers)
    }

    private func respond(to request: Request) -> (Int, String) {
        switch (request.method, request.path) {
        case ("POST", "/oauth/token"):
            guard oauthEnabled, case .bearer(let token, let username, let password) = auth else { return (404, "") }
            guard request.query["grant_type"] == "password",
                  request.query["username"] == username, request.query["password"] == password else {
                return (401, "{\"error\":\"invalid_grant\"}")
            }
            return (200, "{\"access_token\":\"\(token)\",\"token_type\":\"bearer\",\"expires_in\":7200}")

        case ("GET", "/Marti/api/version/config"):
            guard authorized(request) else { return (403, "") }
            return (200, "{\"version\":\"3\",\"type\":\"ServerConfig\",\"data\":{\"version\":\"loopback\",\"api\":\"3\",\"hostname\":\"127.0.0.1\"}}")

        case ("GET", "/Marti/api/missions"):
            guard authorized(request) else { return (403, "") }
            return (200, "{\"version\":\"3\",\"type\":\"Mission\",\"data\":[{\"name\":\"loopback-mission\",\"description\":\"from the test server\",\"passwordProtected\":false}]}")

        case ("GET", "/Marti/api/sync/search"):
            guard authorized(request) else { return (403, "") }
            return (200, "{\"version\":\"3\",\"type\":\"Metadata\",\"data\":[]}")

        default:
            return (404, "")
        }
    }

    private func authorized(_ request: Request) -> Bool {
        switch auth {
        case .open, .clientCertificate:
            return true
        case .bearer(let token, _, _):
            return request.headers["authorization"] == "Bearer \(token)"
        case .basic(let username, let password):
            let expected = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
            return request.headers["authorization"] == expected
        }
    }
}
