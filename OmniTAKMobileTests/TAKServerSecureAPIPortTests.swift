//
//  TAKServerSecureAPIPortTests.swift
//  OmniTAKMobileTests
//
//  #114 — the Marti/Mission REST API port (default 8443) must be configurable
//  per server, the same way enrollmentPort (default 8446) already is.
//  Servers saved by builds that predate the field must keep decoding, and
//  the REST client must fall back to 8443 when the field is unset.
//

import XCTest
@testable import OmniTAK

final class TAKServerSecureAPIPortTests: XCTestCase {

    // MARK: - Persistence compatibility

    /// A server persisted before #114 has no `secureAPIPort` key. It must
    /// still decode, with the port unset (nil), not fail or default to 0.
    func testLegacyServerJSONDecodesWithNilSecureAPIPort() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"HQ","host":"tak.example.mil",
         "port":8089,"protocolType":"ssl","useTLS":true,"isDefault":false,"enabled":true}
        """.data(using: .utf8)!

        let server = try JSONDecoder().decode(TAKServer.self, from: json)

        XCTAssertNil(server.secureAPIPort)
        XCTAssertEqual(server.port, 8089)
    }

    func testSecureAPIPortRoundTripsThroughCodable() throws {
        var server = TAKServer(name: "Remapped", host: "tak.example.mil", port: 8089,
                               protocolType: "ssl", useTLS: true)
        server.secureAPIPort = 9443

        let data = try JSONEncoder().encode(server)
        let decoded = try JSONDecoder().decode(TAKServer.self, from: data)

        XCTAssertEqual(decoded.secureAPIPort, 9443)
    }

    // MARK: - REST client configuration

    /// Unset port → the conventional 8443, exactly the pre-#114 behaviour.
    @MainActor
    func testRestConfigurationFallsBackTo8443WhenUnset() {
        let server = TAKServer(name: "HQ", host: "tak.example.mil", port: 8089,
                               protocolType: "ssl", useTLS: true)

        let config = TAKAPIConfiguration(from: server)

        XCTAssertEqual(config.secureAPIPort, 8443)
        XCTAssertEqual(config.baseURL, "https://tak.example.mil:8443")
    }

    /// The bug in #114: a server whose Marti API lives off 8443 was
    /// unreachable for Mission Sync / Data Sync. The per-server value must
    /// flow into every REST URL.
    @MainActor
    func testRestConfigurationUsesServerSecureAPIPort() {
        let server = TAKServer(name: "Remapped", host: "tak.example.mil", port: 8089,
                               protocolType: "ssl", useTLS: true, secureAPIPort: 9443)

        let config = TAKAPIConfiguration(from: server)

        XCTAssertEqual(config.secureAPIPort, 9443)
        XCTAssertEqual(config.baseURL, "https://tak.example.mil:9443")
    }

    // MARK: - Config profile (QR) snapshot

    /// A shared profile must carry the remapped port, or a teammate who
    /// imports it lands right back on the #114 failure.
    func testProfileServerCarriesSecureAPIPort() throws {
        let server = TAKServer(name: "Remapped", host: "tak.example.mil", port: 8089,
                               protocolType: "ssl", useTLS: true, secureAPIPort: 9443)

        let snapshot = ProfileServer(from: server)
        XCTAssertEqual(snapshot.secureAPIPort, 9443)

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProfileServer.self, from: data)
        XCTAssertEqual(decoded.secureAPIPort, 9443)
        XCTAssertEqual(decoded.toTAKServer().secureAPIPort, 9443)
    }

    /// Existing profiles must serialise byte-for-byte as before when the
    /// port is unset, so QR payloads for 8443 servers do not grow.
    func testProfileServerOmitsSecureAPIPortWhenUnset() throws {
        let server = TAKServer(name: "Plain", host: "tak.example.mil", port: 8089)

        let data = try JSONEncoder().encode(ProfileServer(from: server))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains("secureAPIPort"))
    }
}
