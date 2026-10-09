//
//  TAKTLSHandshakeReportTests.swift
//  OmniTAKMobileTests
//
//  #169 — the TLS delegate must record what it saw in each handshake so a
//  failed request can be explained. Challenges are synthesized; the keychain
//  is only consulted for a name that does not exist.
//

import XCTest
@testable import OmniTAK

final class TAKTLSHandshakeReportTests: XCTestCase {

    /// URLAuthenticationChallenge needs a sender; the delegate answers through
    /// the completion handler, so this one does nothing.
    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func challenge(_ method: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "tak.example", port: 8443, protocol: "https",
                                       realm: nil, authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                                          previousFailureCount: 0, failureResponse: nil,
                                          error: nil, sender: Sender())
    }

    private func answer(_ delegate: TAKTLSSessionDelegate, _ method: String) -> URLSession.AuthChallengeDisposition? {
        let done = expectation(description: "challenge answered")
        var disposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared, didReceive: challenge(method)) { d, _ in
            disposition = d
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return disposition
    }

    func testFreshReportCarriesTheTrustModeOnly() {
        let delegate = TAKTLSSessionDelegate(trustMode: .acceptUntrusted)
        let s = delegate.report.snapshot()
        XCTAssertEqual(s.trustMode, "acceptUntrusted")
        XCTAssertEqual(s.serverTrust, .notChallenged)
        XCTAssertEqual(s.clientIdentity, .notRequested)
        XCTAssertEqual(s.handshakeAttempts, 0)
    }

    func testClientCertificateChallengeWithNoConfiguredCertificate() {
        let delegate = TAKTLSSessionDelegate(trustMode: .acceptUntrusted)
        XCTAssertEqual(answer(delegate, NSURLAuthenticationMethodClientCertificate), .performDefaultHandling)
        XCTAssertEqual(delegate.report.snapshot().clientIdentity, .noneConfigured)
    }

    func testClientCertificateChallengeWithACertificateThatIsNotOnTheDevice() {
        let delegate = TAKTLSSessionDelegate(trustMode: .acceptUntrusted,
                                             certificateName: "omnitak-tests-missing-identity")
        XCTAssertEqual(answer(delegate, NSURLAuthenticationMethodClientCertificate), .performDefaultHandling)
        XCTAssertEqual(delegate.report.snapshot().clientIdentity, .lookupFailed("omnitak-tests-missing-identity"))
    }

    /// A synthesized server-trust challenge carries no trust object, so the
    /// delegate defers to the system; the attempt is still counted and a new
    /// handshake clears the previous client-certificate outcome.
    func testServerTrustChallengeCountsAnAttemptAndResetsTheClientStory() {
        let delegate = TAKTLSSessionDelegate(trustMode: .system)
        _ = answer(delegate, NSURLAuthenticationMethodClientCertificate)
        XCTAssertEqual(delegate.report.snapshot().clientIdentity, .noneConfigured)

        XCTAssertEqual(answer(delegate, NSURLAuthenticationMethodServerTrust), .performDefaultHandling)
        let s = delegate.report.snapshot()
        XCTAssertEqual(s.serverTrust, .systemDefault)
        XCTAssertEqual(s.handshakeAttempts, 1)
        XCTAssertEqual(s.clientIdentity, .notRequested)
    }

    func testDescribedLinesReadLikeABugReport() {
        var s = TAKTLSHandshakeSnapshot(trustMode: "anchored(2)")
        s.serverTrust = .acceptedAnchored(2)
        s.clientIdentity = .presented("omnitak-cert-tak.example")
        s.acceptableIssuerCount = 1
        s.handshakeAttempts = 3
        let text = s.describedLines.joined(separator: "\n")
        XCTAssertTrue(text.contains("Trust policy: anchored(2)"), text)
        XCTAssertTrue(text.contains("validated against the enrolled truststore (2 anchors)"), text)
        XCTAssertTrue(text.contains("(1 acceptable issuer); presented \"omnitak-cert-tak.example\""), text)
        XCTAssertTrue(text.contains("Handshake attempts: 3"), text)
    }
}
