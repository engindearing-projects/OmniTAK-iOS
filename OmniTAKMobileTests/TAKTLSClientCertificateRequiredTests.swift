//
//  TAKTLSClientCertificateRequiredTests.swift
//  OmniTAKMobileTests
//
//  #169 — the reproducer. A loopback TLS listener that requires a client
//  certificate, the way a TAK Server's Marti REST connector (8443) does.
//  Without a certificate the handshake is refused; the REST client has to
//  say so instead of "A TLS error caused the secure connection to fail".
//

import XCTest
import Network
import Security
@testable import OmniTAK

@MainActor
final class TAKTLSClientCertificateRequiredTests: XCTestCase {

    /// Self-signed RSA server identity (CN=127.0.0.1, valid to 2036).
    private static let serverP12Base64 = "MIIJogIBAzCCCWgGCSqGSIb3DQEHAaCCCVkEgglVMIIJUTCCA88GCSqGSIb3DQEHBqCCA8AwggO8AgEAMIIDtQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQYwDgQI0NfoodfVgOMCAggAgIIDiOcQXQxtZ12OQxA1iovguzKcCo5BThP983oPBNgG1SPYL2P/skUX+8kuhGfGDkTVHGJ4W8C08zbHMcoLWZRdqtFlQR7cNrFnrYZ1rro6wYlpD+AO+xpwR6GcLaEao/EE7FKL7aCrxxAOfZNxm2IdhhIpbLMefrWdO3OdK2wRVq1XDpUSxh/XFIKtpYRqG2qJ0sv9m5vHcIO83q201K0b9fI4KJ7HNUAjKIcax4DFiNTxmo824kpjjObOpStwOzeJxCGT+/mNAPK3DJxLGh0PP9M98oY1flrsM653nUVHEom8liP9ojpscSvasFXUbOK4F+AELiqUrsUFCoGJAwLgawCoR0AXVibKoA56kW4Wk+TqigvFjWOurkvB4i9vyXrCRuT31+jd79nVOo93H5o7ILGuWd8hU1uK2EE2duJqnlbk9nBptd4UOos6jIWjqBsCr9x0pjgKXB7mhTbsUsH0HXnPCRsk82BhOEAGMzYMQoCosDH53G2rvcohgcduucr53nRpM5jZs6n+DRWE8XIzAc7v+dseKNLzDh+f3hlKQmrzxQS64dyF1NLJzkTuSUUv76lNcq8IwVlmmDAiLnHZhKLWwkr6v4959ZxRyzcjxTHToPxLrgEMBPMJMk4tH15ru5psnY5RGaSOmTXR5h0V4oJfONA98+kK4HkZCOvSSufzCCQ9kUCk3v1NHZN3waP2wvP2QjTa17tYP2WEJrHXRYxwDyz3YJTgmP82/JYIkuuZCCJ0+lyZ2g6N0yn6e7vhPzFLyDw21edPB3D3pGhdApkvNJqP6zaDDSvVvmh63IWqtwFTH2qTL5HCocnfZGaoRwXfBAfc9DuJEm5ayXc2XHMw/Y/FatgB9dgKyzvZRljEGSAZABnO/WZcIbBFW8/5pNGQ7j3nRykNFywXxjSP0E1i7ZBmahvqwpVk0gPAMAizeAM6i27VRoXrvN5DwpCd525GHQmYdr9paVWOh7UIXd0+kw/BnSOWo907cO8RLMoYwueTLBRbGyWG6YlJeoCJOnQ4E7gBxC1Ge7aFjndMF8IMC72Rx+nyyy+fO9iYJTOdb1WFoWlvuX6Nu0iz0kgDYdNz4O8320Hw64IReQl1DURBvlA556sK+nl1WZlAIm2kNZuav3ZT83NtzWIp/enauuqZtHsyrLt8iCrWJog825/pXywaL+rE02vUMpcJcim02leIwF0yKK4wggV6BgkqhkiG9w0BBwGgggVrBIIFZzCCBWMwggVfBgsqhkiG9w0BDAoBAqCCBO4wggTqMBwGCiqGSIb3DQEMAQMwDgQIgu8edbL1PqICAggABIIEyH2LddsTwA3zYHDtI1X3CDpV7+MPDNPv04iIwNelAPQu75BGCgk6fj14jJCnt80MNtsE4pcPLwAj/IPRkP725qqHxxvYWSgFi3eBnivhYNMuQHWpkR+P4pN6and5sQORaUkGSixB59bA05KO0rdnOB5rSEj6IDpLS2GJy9AUCXSrJVdSj5Kwv1uFJPIabvmwf+dX2BF0RXURIiNzrLzWCZsBc+oOy5Uxa0jvC5UsVnvAgyKqWKiREEHxORD1Va3I0xA3aTRYfSIl83qoJDKQr8Qyc0tce84MDM87PgtvhJSO88c3An627l4S2L1iwURtZwcqFMMVnUx14d7C0aousJpS30jH+R1ZnWhV/cEzRS7ejUcCtvtWacHNpY00TjhEMdVBJMspN+tQs1wYs8h3mm3rIw3GeYOdODkjV1QuSjGuXC7g4o2155g57ENIk4eneLUVv/jts01jFpiadBma50MQb8fWk4IN+olxChdwPAXJ/Lm0L9AeSjYr3EtCFCO1LeyLP42yZyLxc9r4Iee8+7D8Viv26o+fUICAzwyGKKid+5Kh8H2Wp/tXKWyfXMcQebwI68rAGx0s+DMIQTXLeBf7+7Q+nGsAJxdXYngu+nWTxy6J+kQa07YynCg7xeczSlECT7Tdy6m/DQB7K9aBKcWZFIrbYZ9T3oPnC29mSo9FFuavgVCCZgqBl7KekqRTfSIKAkOoBH2Pl6IMF3klMfKpuo92FEAAVdtI4ywOiLpNZj0+HX1QLjeCuUkpgXkKAJEpmIhKZj8hZiyU0ccFYo+edmqMMdg3IakM0eRuKbV176GeV72AA731PS1nNIalFXhn0S37GVk2YbwgPdGKsUCC3zfycq2TZqHoVP6evca0EihQOKySNkFe+DfcwcVo8+F0gOm1Ss18IG3L7NnQY9oeAl3zr2DGhEvCA1nunErChUXjpQmEK4bGk5cqJAIRvkAj3oqDKJqdHdOAsuGvuV/gC7IG2ItVwCOu8NfwLUbTc5EtFe6uAeMxR8I8ATy/A9if/ck3OZzsWvcgs85UVUeD+gRv2CiE2W/osyf6isChs2kHQzRzwmh19GgF7Z1pzRuiCvGCgFd5Mwu4CgBcaqiGHLIjxr1TDz9rd8pZM+95LkelIiQdGSpsGASqykD+6FL8BNyX06RSoDaNWtbVe5socI6LXRRjuUjp9gJUeiXAHgQbsNt5/uj4+Ssl8oR1+p6X++dWtKXk9gvE3kO5a7sgkEqwBFALUkQQHDNn0RsP5/6klYZ8G/jXX1TRcPqfZjpXUp5GS7dr4jrMfXqxKmrV9gF4ycaL2cfqEvXiLkMaN2QDXlKZIHuLpqK1RiaPeGVGmRmdn3dY1lbvenxF1xHHLLZa1m5ER26fmAuIKF9K/zKQJ71L0tr8LvcDpCdf7XdOYlYlAcyeTVU8L6AXva0R96Rbho4/wAzanFsq/DXj+H3u1d/60ekAGoEM+WCXbAc/eMFziOq7pGdOMTfvhdCLCjBQ8J06BLB0nwNFz9xNgH6HSBscfwI5plxSA0wYVJMwaRN4NHP1gTco9lrgLZujibLWhNf/x/oQ48HWq3fwF+t7+njIrZe/EvE+k4h4o2Qeh+tIskSZsEFmEzKVL7G0KO0qFqdntzFeMCMGCSqGSIb3DQEJFTEWBBRIr+Sjektfc4Vo1L6vtoldphY+hjA3BgkqhkiG9w0BCRQxKh4oAG8AbQBuAGkAdABhAGsALQB0AGUAcwB0AHMALQBzAGUAcgB2AGUAcjAxMCEwCQYFKw4DAhoFAAQUlMUnNZcBnvu/bk/jYY2AZtQ6gXsECAE2iMBQQ5tYAgIIAA=="
    private static let serverP12Password = "omnitak-tests"

    /// Keeps accepted connections alive for the listener's lifetime.
    private final class Peers {
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        func keep(_ c: NWConnection) { lock.lock(); connections.append(c); lock.unlock() }
        func cancelAll() { lock.lock(); connections.forEach { $0.cancel() }; connections.removeAll(); lock.unlock() }
    }

    private func serverIdentity() throws -> SecIdentity {
        let data = try XCTUnwrap(Data(base64Encoded: Self.serverP12Base64))
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: Self.serverP12Password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        XCTAssertEqual(status, errSecSuccess, "p12 import status \(status)")
        let first = try XCTUnwrap((items as? [[String: Any]])?.first)
        let identity = try XCTUnwrap(first[kSecImportItemIdentity as String])
        return identity as! SecIdentity
    }

    /// Starts a TLS listener on loopback that demands a client certificate.
    /// `acceptClient` decides what the server does with one that arrives.
    private func startListener(acceptClient: Bool, peers: Peers) async throws -> NWListener {
        let identity = try serverIdentity()
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_local_identity(options, try XCTUnwrap(sec_identity_create(identity)))
        sec_protocol_options_set_peer_authentication_required(options, true)
        sec_protocol_options_set_verify_block(options, { _, _, complete in
            complete(acceptClient)
        }, DispatchQueue(label: "tests.tls.verify"))

        let listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
        let queue = DispatchQueue(label: "tests.tls.listener")
        listener.newConnectionHandler = { connection in
            peers.keep(connection)
            connection.stateUpdateHandler = { _ in }
            connection.start(queue: queue)
            // Read so the handshake runs; nothing is ever answered.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in }
        }

        let ready = expectation(description: "listener ready")
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        listener.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        return listener
    }

    private func client(port: UInt16) -> TAKRestAPIClient {
        let client = TAKRestAPIClient()
        var config = TAKAPIConfiguration(serverURL: "127.0.0.1", secureAPIPort: Int(port))
        config.trustMode = .acceptUntrusted
        config.timeout = 10
        client.configure(with: config)
        return client
    }

    /// The user report: Mission Sync against a REST port that requires a
    /// certificate, from a server entry that has none.
    func testServerThatRequiresAClientCertificateIsDiagnosedWhenNoneIsConfigured() async throws {
        let peers = Peers()
        let listener = try await startListener(acceptClient: true, peers: peers)
        defer { listener.cancel(); peers.cancelAll() }
        let port = try XCTUnwrap(listener.port?.rawValue)
        let client = client(port: port)

        do {
            _ = try await client.checkReachability()
            XCTFail("a server that requires a client certificate must not be reachable without one")
        } catch let error as TAKAPIError {
            let failure = try XCTUnwrap(error.connectionFailure, "\(error)")
            print("[#169] iOS reported: \(failure.details)")
            XCTAssertEqual(failure.kind, .clientCertificateMissing, failure.details)
            XCTAssertEqual(failure.handshake.clientIdentity, .noneConfigured, failure.details)
            XCTAssertGreaterThanOrEqual(failure.handshake.handshakeAttempts, 1)
            XCTAssertTrue(failure.summary.contains("127.0.0.1:\(port) requires a client certificate"), failure.summary)
            XCTAssertEqual(client.lastFailure?.kind, .clientCertificateMissing)
            XCTAssertEqual(client.lastError, failure.summary)
        }
    }

    /// The entry names a certificate the device does not have.
    func testServerThatRequiresAClientCertificateIsDiagnosedWhenTheNamedOneIsMissing() async throws {
        let peers = Peers()
        let listener = try await startListener(acceptClient: true, peers: peers)
        defer { listener.cancel(); peers.cancelAll() }
        let port = try XCTUnwrap(listener.port?.rawValue)

        let client = TAKRestAPIClient()
        var config = TAKAPIConfiguration(serverURL: "127.0.0.1", secureAPIPort: Int(port),
                                         certificateName: "omnitak-tests-missing-identity")
        config.trustMode = .acceptUntrusted
        config.timeout = 10
        client.configure(with: config)

        do {
            _ = try await client.checkReachability()
            XCTFail("unreachable without the certificate")
        } catch let error as TAKAPIError {
            let failure = try XCTUnwrap(error.connectionFailure, "\(error)")
            XCTAssertEqual(failure.kind, .clientCertificateUnavailable, failure.details)
            XCTAssertEqual(failure.handshake.clientIdentity, .lookupFailed("omnitak-tests-missing-identity"))
            XCTAssertTrue(failure.summary.contains("\"omnitak-tests-missing-identity\" was not found"), failure.summary)
        }
    }
}
