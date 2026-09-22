//
//  TAKTLSTrustModeTests.swift
//  OmniTAKMobileTests
//
//  #127 — "Trust untrusted certificates" must be honoured by the Marti REST
//  session even when the server carries a truststore from enrollment (every
//  app-enrolled server does), and the selected mode must be observable.
//

import XCTest
import Security
@testable import OmniTAK

final class TAKTLSTrustModeTests: XCTestCase {

    /// Tiny self-signed EC certificate (CN=OmniTAK Test CA). Only used as an
    /// opaque anchor object; nothing is validated against it.
    private static let anchorDERBase64 = "MIICGDCCAb4CCQCzg6uhuIpzvTAKBggqhkjOPQQDAjAaMRgwFgYDVQQDDA9PbW5pVEFLIFRlc3QgQ0EwHhcNMjYwOTIxMjMzNDIxWhcNMzYwOTE4MjMzNDIxWjAaMRgwFgYDVQQDDA9PbW5pVEFLIFRlc3QgQ0EwggFLMIIBAwYHKoZIzj0CATCB9wIBATAsBgcqhkjOPQEBAiEA/////wAAAAEAAAAAAAAAAAAAAAD///////////////8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrGNdiqOpPns+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAEQQRrF9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2QGg3v1H1AiEA/////wAAAAD//////////7zm+q2nF56E87nKwvxjJVECAQEDQgAEBa+z5j/yu/Jxy/q4+EzI0GCv3/8nVb9HtO0EyTwK2tj8BnOuXkop1u3Ka62fWMQqLjd3jO4lzHWabxEn4ozjYTAKBggqhkjOPQQDAgNIADBFAiA3v2AmA/fZll8WtJnid2CZrMZyrBR2+NszaO+gnEEcsAIhAN0Bjd//clxzzWsd5GYTZSg8V5OKTc56JASa+H0TeiGP"

    private func anchor() throws -> SecCertificate {
        let data = try XCTUnwrap(Data(base64Encoded: Self.anchorDERBase64))
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }

    // MARK: - Precedence

    /// The explicit opt-in wins even when anchors exist. This is the #127
    /// case: an app-enrolled server always has anchors, so anchors-first
    /// made the toggle a no-op.
    func testExplicitOptInWinsOverAnchors() throws {
        let mode = TAKTLSTrustMode.resolve(allowUntrustedTLS: true, anchors: [try anchor()])
        XCTAssertEqual(mode.label, "acceptUntrusted")
    }

    func testAnchorsUsedWhenNoOptIn() throws {
        let mode = TAKTLSTrustMode.resolve(allowUntrustedTLS: false, anchors: [try anchor()])
        XCTAssertEqual(mode.label, "anchored(1)")
    }

    func testSystemWhenNoAnchorsAndNoOptIn() {
        XCTAssertEqual(TAKTLSTrustMode.resolve(allowUntrustedTLS: false, anchors: nil).label, "system")
        XCTAssertEqual(TAKTLSTrustMode.resolve(allowUntrustedTLS: false, anchors: []).label, "system")
    }

    func testOptInWithoutAnchorsIsAcceptUntrusted() {
        XCTAssertEqual(TAKTLSTrustMode.resolve(allowUntrustedTLS: true, anchors: nil).label, "acceptUntrusted")
    }

    // MARK: - Through TAKAPIConfiguration

    /// A server that names a truststore, with the toggle on, must produce an
    /// accept-untrusted REST session regardless of what the truststore holds.
    func testConfigurationHonoursToggleDespiteTruststoreName() {
        var server = TAKServer(name: "OTS", host: "ots.example", port: 8089,
                               protocolType: "ssl", useTLS: true)
        server.caCertificateName = "omnitak-tests-nonexistent-ca"
        server.allowUntrustedTLS = true
        XCTAssertEqual(TAKAPIConfiguration(from: server).trustMode.label, "acceptUntrusted")
    }

    func testConfigurationDefaultsToSystemWithoutToggleOrTruststore() {
        let server = TAKServer(name: "Public", host: "tak.example", port: 8089,
                               protocolType: "ssl", useTLS: true)
        XCTAssertEqual(TAKAPIConfiguration(from: server).trustMode.label, "system")
    }
}
