//
//  TAKConnectionFailureTests.swift
//  OmniTAKMobileTests
//
//  #169 — a Marti REST request that never got an HTTP answer must be
//  explained from what the TLS delegate saw, not from the system's one-line
//  description. These tests drive the mapping with synthesized URLErrors and
//  handshake snapshots; no network.
//

import XCTest
@testable import OmniTAK

final class TAKConnectionFailureTests: XCTestCase {

    private let tlsText = "A TLS error caused the secure connection to fail."
    private let lostText = "The network connection was lost."

    private func urlError(_ code: Int, _ description: String, stream: (domain: Int, code: Int)? = nil) -> NSError {
        var info: [String: Any] = [NSLocalizedDescriptionKey: description]
        if let stream {
            info["_kCFStreamErrorDomainKey"] = stream.domain
            info["_kCFStreamErrorCodeKey"] = stream.code
        }
        return NSError(domain: NSURLErrorDomain, code: code, userInfo: info)
    }

    private func handshake(trust: TAKTLSHandshakeSnapshot.ServerTrust = .acceptedUntrusted,
                           client: TAKTLSHandshakeSnapshot.ClientIdentity = .notRequested,
                           issuers: Int = 0) -> TAKTLSHandshakeSnapshot {
        var snapshot = TAKTLSHandshakeSnapshot(trustMode: "acceptUntrusted")
        snapshot.serverTrust = trust
        snapshot.clientIdentity = client
        snapshot.acceptableIssuerCount = issuers
        snapshot.handshakeAttempts = 1
        return snapshot
    }

    private func failure(_ error: NSError, _ snapshot: TAKTLSHandshakeSnapshot) -> TAKConnectionFailure {
        TAKConnectionFailure(error: error, host: "tak.example", port: 8443, handshake: snapshot)
    }

    // MARK: Client certificate stories

    /// The user report: the server's REST port asks for a client certificate
    /// and the entry has none. The system says "TLS error"; we say what to do.
    func testServerRequiresCertificateAndNoneConfigured() {
        let f = failure(urlError(-1200, tlsText, stream: (3, -9824)),
                        handshake(client: .noneConfigured, issuers: 2))
        XCTAssertEqual(f.kind, .clientCertificateMissing)
        XCTAssertTrue(f.isClientCertificateProblem)
        XCTAssertFalse(f.isServerTrustProblem)
        XCTAssertTrue(f.summary.contains("tak.example:8443 requires a client certificate"), f.summary)
        XCTAssertTrue(f.summary.contains("Enroll"), f.summary)
    }

    /// A TAK Server's Tomcat closes the connection right after the handshake
    /// when the certificate is missing; iOS reports that as -1005. Still the
    /// certificate story when the server had asked for one.
    func testConnectionLostAfterCertificateRequestIsACertificateProblem() {
        let f = failure(urlError(-1005, lostText, stream: (4, -4)),
                        handshake(client: .noneConfigured, issuers: 1))
        XCTAssertEqual(f.kind, .clientCertificateMissing)
    }

    func testPresentedCertificateRejected() {
        let f = failure(urlError(-1200, tlsText),
                        handshake(client: .presented("omnitak-cert-tak.example"), issuers: 2))
        XCTAssertEqual(f.kind, .clientCertificateRejected)
        XCTAssertTrue(f.isClientCertificateProblem)
        XCTAssertTrue(f.summary.contains("omnitak-cert-tak.example"), f.summary)
        XCTAssertTrue(f.summary.contains("did not accept"), f.summary)
    }

    func testConfiguredCertificateMissingFromDevice() {
        let f = failure(urlError(-1200, tlsText),
                        handshake(client: .lookupFailed("omnitak-cert-old"), issuers: 1))
        XCTAssertEqual(f.kind, .clientCertificateUnavailable)
        XCTAssertTrue(f.summary.contains("\"omnitak-cert-old\" was not found"), f.summary)
    }

    /// The system's own verdict, when it gets to make one.
    func testSystemClientCertificateCodesWithoutAChallengeRecord() {
        XCTAssertEqual(failure(urlError(-1206, "client certificate required"), handshake()).kind, .clientCertificateMissing)
        XCTAssertEqual(failure(urlError(-1205, "client certificate rejected"), handshake()).kind, .clientCertificateRejected)
    }

    // MARK: Server certificate stories

    func testUntrustedServerCertificate() {
        let f = failure(urlError(-1202, "The certificate for this server is invalid."),
                        handshake(trust: .systemDefault))
        XCTAssertEqual(f.kind, .serverCertificateUntrusted)
        XCTAssertTrue(f.isServerTrustProblem)
        XCTAssertTrue(f.summary.contains("not trusted by iOS"), f.summary)
    }

    /// Our own anchor check cancels the challenge, which the system reports
    /// as a plain cancellation. The report knows better.
    func testAnchorRejectionIsATrustProblemNotACancellation() {
        let f = failure(urlError(-999, "cancelled"),
                        handshake(trust: .rejectedByAnchors("chain not trusted")))
        XCTAssertEqual(f.kind, .serverCertificateFailedAnchors)
        XCTAssertTrue(f.summary.contains("enrolled truststore"), f.summary)
    }

    func testPlainCancellationStaysACancellation() {
        XCTAssertEqual(failure(urlError(-999, "cancelled"), handshake()).kind, .cancelled)
    }

    // MARK: Everything else

    func testHandshakeFailureWithoutACertificateRequest() {
        let f = failure(urlError(-1200, tlsText, stream: (3, -9836)), handshake())
        XCTAssertEqual(f.kind, .tlsHandshakeFailed)
        XCTAssertTrue(f.summary.contains(tlsText), f.summary)
    }

    func testNetworkCodes() {
        XCTAssertEqual(failure(urlError(-1004, "refused"), handshake()).kind, .connectionRefused)
        XCTAssertEqual(failure(urlError(-1003, "not found"), handshake()).kind, .hostNotFound)
        XCTAssertEqual(failure(urlError(-1001, "timed out"), handshake()).kind, .timedOut)
        XCTAssertEqual(failure(urlError(-1009, "offline"), handshake()).kind, .offline)
        XCTAssertEqual(failure(urlError(-1005, lostText), handshake()).kind, .connectionLost)
        XCTAssertEqual(failure(urlError(-1011, "bad response"), handshake()).kind, .other)
    }

    func testConnectionRefusedNamesThePort() {
        let f = failure(urlError(-1004, "refused"), handshake(trust: .notChallenged))
        XCTAssertTrue(f.summary.contains("tak.example:8443 refused"), f.summary)
    }

    // MARK: Details

    func testDetailsCarryCodesAndHandshakeFacts() {
        let f = failure(urlError(-1200, tlsText, stream: (3, -9824)),
                        handshake(trust: .acceptedAnchored(2), client: .noneConfigured, issuers: 2))
        let d = f.details
        XCTAssertTrue(d.contains("Server: tak.example:8443"), d)
        XCTAssertTrue(d.contains("System error: NSURLErrorDomain -1200"), d)
        XCTAssertTrue(d.contains("stream domain 3 code -9824 (SecureTransport / TLS)"), d)
        XCTAssertTrue(d.contains("validated against the enrolled truststore (2 anchors)"), d)
        XCTAssertTrue(d.contains("2 acceptable issuers"), d)
        XCTAssertTrue(d.contains("this server entry has none"), d)
        XCTAssertTrue(d.contains("Handshake attempts: 1"), d)
    }

    /// CFNetwork sometimes attaches the stream codes to the underlying error
    /// rather than the top one.
    func testStreamCodesAreReadFromTheUnderlyingError() {
        let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: -1005,
                                 userInfo: ["_kCFStreamErrorDomainKey": 4, "_kCFStreamErrorCodeKey": -4])
        let top = NSError(domain: NSURLErrorDomain, code: -1005,
                          userInfo: [NSLocalizedDescriptionKey: lostText, NSUnderlyingErrorKey: underlying])
        let f = failure(top, handshake())
        XCTAssertEqual(f.streamErrorDomain, 4)
        XCTAssertEqual(f.streamErrorCode, -4)
        XCTAssertTrue(f.details.contains("stream domain 4 code -4 (HTTP)"), f.details)
    }

    func testAPIErrorExposesTheFailure() {
        let f = failure(urlError(-1200, tlsText), handshake(client: .noneConfigured, issuers: 1))
        let err = TAKAPIError.connectionFailed(f)
        XCTAssertEqual(err.connectionFailure, f)
        XCTAssertEqual(err.errorDescription, f.summary)
        XCTAssertNil(TAKAPIError.forbidden.connectionFailure)
    }
}
