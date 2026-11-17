//
//  TAKRestCredentialFallbackTests.swift
//  OmniTAKMobileTests
//
//  #169 — when the certificate port refuses the handshake and the server
//  entry has a username and password, the REST client must reach the Marti
//  API through the enrollment port instead: OAuth password grant first (TAK
//  Server), HTTP Basic second (OpenTAKServer). Two loopback connectors play
//  the two ports.
//

import XCTest
import Security
@testable import OmniTAK

@MainActor
final class TAKRestCredentialFallbackTests: XCTestCase {

    private var servers: [LoopbackMartiServer] = []

    override func tearDown() {
        servers.forEach { $0.stop() }
        servers.removeAll()
        super.tearDown()
    }

    private func identity() throws -> SecIdentity {
        try TAKTLSClientCertificateRequiredTests.importServerIdentity()
    }

    private func start(_ auth: LoopbackMartiServer.Auth, oauth: Bool = true) throws -> (LoopbackMartiServer, UInt16) {
        let server = LoopbackMartiServer(identity: try identity(), auth: auth)
        server.oauthEnabled = oauth
        let port = try server.start()
        servers.append(server)
        return (server, port)
    }

    private func entry(apiPort: UInt16, enrollPort: UInt16, certificateName: String?, username: String?, password: String?) -> TAKServer {
        var server = TAKServer(name: "Loopback", host: "127.0.0.1", port: 8089, protocolType: "ssl", useTLS: true)
        server.certificateName = certificateName
        server.username = username
        server.password = password
        server.enrollmentPort = enrollPort
        server.secureAPIPort = apiPort
        server.allowUntrustedTLS = true
        return server
    }

    // MARK: Fallback paths

    /// The user report: the entry names a certificate the device no longer
    /// has (or the server will not take), the API port refuses, and the
    /// stored credentials get the API through the enrollment port.
    func testCertificatePortRefusedThenOAuthOnTheEnrollmentPort() async throws {
        let (_, apiPort) = try start(.clientCertificate)
        let (enroll, enrollPort) = try start(.bearer(token: "tok-1", username: "vaclav", password: "pw"))
        let server = entry(apiPort: apiPort, enrollPort: enrollPort,
                           certificateName: "omnitak-tests-missing-identity", username: "vaclav", password: "pw")

        let client = TAKRestAPIClient()
        let mode = try await client.connect(to: server)
        XCTAssertEqual(mode, .bearerToken(port: Int(enrollPort)))

        let missions = try await client.getMissions()
        XCTAssertEqual(missions.map(\.name), ["loopback-mission"])

        let apiCalls = enroll.requests.filter { $0.path.hasPrefix("/Marti/") }
        XCTAssertFalse(apiCalls.isEmpty)
        XCTAssertTrue(apiCalls.allSatisfy { $0.headers["authorization"] == "Bearer tok-1" }, "\(apiCalls)")
        XCTAssertEqual(client.lastFailure?.kind, .clientCertificateUnavailable, "the certificate-port failure stays visible")
    }

    /// No certificate at all: skip the certificate port, go straight to the credentials.
    func testNoCertificateGoesStraightToTheCredentials() async throws {
        let (api, apiPort) = try start(.clientCertificate)
        let (_, enrollPort) = try start(.bearer(token: "tok-2", username: "vaclav", password: "pw"))
        let server = entry(apiPort: apiPort, enrollPort: enrollPort, certificateName: nil, username: "vaclav", password: "pw")

        let client = TAKRestAPIClient()
        let mode = try await client.connect(to: server)
        XCTAssertEqual(mode, .bearerToken(port: Int(enrollPort)))
        XCTAssertTrue(api.requests.isEmpty, "no attempt on the certificate port without a certificate")
        XCTAssertNil(client.lastFailure)
    }

    /// OpenTAKServer has no OAuth endpoint; its enrollment port takes Basic.
    func testBasicAuthWhenTheServerHasNoOAuth() async throws {
        let (_, apiPort) = try start(.clientCertificate)
        let (enroll, enrollPort) = try start(.basic(username: "vaclav", password: "pw"), oauth: false)
        let server = entry(apiPort: apiPort, enrollPort: enrollPort, certificateName: nil, username: "vaclav", password: "pw")

        let client = TAKRestAPIClient()
        let mode = try await client.connect(to: server)
        XCTAssertEqual(mode, .basic(port: Int(enrollPort)))
        let expected = "Basic " + Data("vaclav:pw".utf8).base64EncodedString()
        XCTAssertTrue(enroll.requests.filter { $0.path.hasPrefix("/Marti/") }.allSatisfy { $0.headers["authorization"] == expected })
        _ = try await client.checkReachability()
    }

    // MARK: Failures stay explained

    func testWrongCredentialsKeepTheCertificateFailureAndNoteTheFallback() async throws {
        let (_, apiPort) = try start(.clientCertificate)
        let (_, enrollPort) = try start(.bearer(token: "tok-3", username: "vaclav", password: "right"))
        let server = entry(apiPort: apiPort, enrollPort: enrollPort,
                           certificateName: "omnitak-tests-missing-identity", username: "vaclav", password: "wrong")

        let client = TAKRestAPIClient()
        do {
            _ = try await client.connect(to: server)
            XCTFail("wrong credentials must not connect")
        } catch let error as TAKAPIError {
            let failure = try XCTUnwrap(error.connectionFailure, "\(error)")
            XCTAssertEqual(failure.kind, .clientCertificateUnavailable, failure.details)
            let note = try XCTUnwrap(failure.fallbackNote, failure.details)
            XCTAssertTrue(note.contains("127.0.0.1:\(enrollPort)"), note)
            XCTAssertTrue(failure.details.contains(note), failure.details)
            XCTAssertEqual(client.authMode, .clientCertificate)
        }
    }

    /// The enrollment port itself not answering is reported as that, not as
    /// rejected credentials.
    func testNoCertificateAndAnEnrollmentPortThatDoesNotAnswerNamesThatPort() async throws {
        let (_, apiPort) = try start(.clientCertificate)
        let (closed, closedPort) = try start(.open)
        closed.stop()
        let server = entry(apiPort: apiPort, enrollPort: closedPort, certificateName: nil, username: "vaclav", password: "pw")

        let client = TAKRestAPIClient()
        do {
            _ = try await client.connect(to: server)
            XCTFail("a closed enrollment port cannot connect")
        } catch let error as TAKAPIError {
            let failure = try XCTUnwrap(error.connectionFailure, "\(error)")
            XCTAssertEqual(failure.kind, .connectionRefused, failure.details)
            XCTAssertEqual(failure.port, Int(closedPort))
            XCTAssertFalse(failure.summary.contains("did not accept the stored username"), failure.summary)
        }
    }

    func testNoCredentialsMeansNoFallback() async throws {
        let (_, apiPort) = try start(.clientCertificate)
        let (enroll, enrollPort) = try start(.bearer(token: "tok-4", username: "vaclav", password: "pw"))
        let server = entry(apiPort: apiPort, enrollPort: enrollPort,
                           certificateName: "omnitak-tests-missing-identity", username: nil, password: nil)

        let client = TAKRestAPIClient()
        do {
            _ = try await client.connect(to: server)
            XCTFail("unreachable without a certificate or credentials")
        } catch let error as TAKAPIError {
            let failure = try XCTUnwrap(error.connectionFailure, "\(error)")
            XCTAssertEqual(failure.kind, .clientCertificateUnavailable)
            XCTAssertNil(failure.fallbackNote)
        }
        XCTAssertTrue(enroll.requests.isEmpty)
    }

    // MARK: Pure pieces

    func testAuthModeHeadersAndLabels() {
        XCTAssertNil(TAKRestAuthMode.clientCertificate.authorizationHeader(username: "u", password: "p", token: nil))
        XCTAssertEqual(TAKRestAuthMode.bearerToken(port: 8446).authorizationHeader(username: "u", password: "p", token: "t"), "Bearer t")
        XCTAssertEqual(TAKRestAuthMode.basic(port: 8446).authorizationHeader(username: "u", password: "p", token: nil),
                       "Basic " + Data("u:p".utf8).base64EncodedString())
        XCTAssertEqual(TAKRestAuthMode.clientCertificate.label, "client certificate")
        XCTAssertEqual(TAKRestAuthMode.bearerToken(port: 8446).label, "username and password (8446)")
        XCTAssertEqual(TAKRestAuthMode.basic(port: 8446).label, "username and password (8446)")
    }
}
