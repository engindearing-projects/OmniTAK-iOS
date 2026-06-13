//
//  ConfigProfileTests.swift
//  OmniTAKMobileTests
//
//  Unit tests for:
//  - ConfigProfile Codable round-trip
//  - ProfileQRCodec encode/decode round-trip
//  - base64url helpers
//  - Error paths
//

import XCTest
@testable import OmniTAK

class ConfigProfileTests: XCTestCase {

    // MARK: - ConfigProfile Codable round-trip

    func testConfigProfileCodableRoundTrip() throws {
        let original = ConfigProfile(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "Alpha Team West",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            teamName: "Alpha Team",
            teamRole: "Team Lead",
            teamColor: "Blue",
            servers: [
                ProfileServer(from: TAKServer(
                    name: "HQ Server",
                    host: "tak.example.mil",
                    port: 8089,
                    protocolType: "ssl",
                    useTLS: true
                ))
            ],
            mapEngine: "cesium_3d",
            coordinateFormat: "MGRS",
            unitSystem: "Metric",
            mgrsGridEnabled: true,
            mgrsGridDensity: "1km",
            showMGRSLabels: true,
            breadcrumbTrailsEnabled: false,
            selfMarkerStyle: "milstd",
            remoteIdScanEnabled: true,
            gybDetectorEnabled: false,
            selectedMeshFramework: "meshtastic"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConfigProfile.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.teamName, original.teamName)
        XCTAssertEqual(decoded.teamRole, original.teamRole)
        XCTAssertEqual(decoded.teamColor, original.teamColor)
        XCTAssertEqual(decoded.mapEngine, original.mapEngine)
        XCTAssertEqual(decoded.coordinateFormat, original.coordinateFormat)
        XCTAssertEqual(decoded.unitSystem, original.unitSystem)
        XCTAssertEqual(decoded.mgrsGridEnabled, original.mgrsGridEnabled)
        XCTAssertEqual(decoded.mgrsGridDensity, original.mgrsGridDensity)
        XCTAssertEqual(decoded.showMGRSLabels, original.showMGRSLabels)
        XCTAssertEqual(decoded.breadcrumbTrailsEnabled, original.breadcrumbTrailsEnabled)
        XCTAssertEqual(decoded.selfMarkerStyle, original.selfMarkerStyle)
        XCTAssertEqual(decoded.remoteIdScanEnabled, original.remoteIdScanEnabled)
        XCTAssertEqual(decoded.gybDetectorEnabled, original.gybDetectorEnabled)
        XCTAssertEqual(decoded.selectedMeshFramework, original.selectedMeshFramework)
        XCTAssertEqual(decoded.schemaVersion, 1)
    }

    func testConfigProfileNilFieldsCodable() throws {
        // All optional fields nil — still round-trips cleanly
        let sparse = ConfigProfile(name: "Sparse")
        let data = try JSONEncoder().encode(sparse)
        let decoded = try JSONDecoder().decode(ConfigProfile.self, from: data)
        XCTAssertEqual(decoded.name, "Sparse")
        XCTAssertNil(decoded.teamName)
        XCTAssertNil(decoded.mapEngine)
        XCTAssertTrue(decoded.servers.isEmpty)
    }

    func testProfileServerStripsSecrets() {
        let serverWithSecrets = TAKServer(
            name: "Secure Server",
            host: "secure.tak.mil",
            port: 8089,
            protocolType: "ssl",
            useTLS: true,
            isDefault: false,
            enabled: true,
            certificateName: "my-cert",
            certificatePassword: "secret123",
            caCertificateName: "my-ca",
            caCertificatePassword: "casecret",
            allowLegacyTLS: false,
            allowUntrustedTLS: false,
            username: "operator",
            password: "password123",
            enrollmentPort: 8446
        )

        let snapshot = ProfileServer(from: serverWithSecrets)

        // Secrets must NOT be present
        XCTAssertEqual(snapshot.host, "secure.tak.mil")
        XCTAssertEqual(snapshot.port, 8089)
        XCTAssertEqual(snapshot.enrollmentPort, 8446)
        // enrollmentUsername is stored locally in the struct but excluded from
        // Codable / QR serialisation (fix #9 — PII not shared in QR).
        // The raw field still carries the value for local UX use.
        XCTAssertEqual(snapshot.enrollmentUsername, "operator",
            "enrollmentUsername is available locally before serialisation")

        // After a round-trip through JSON (as would happen in a QR code),
        // enrollmentUsername must be nil — it is excluded from CodingKeys.
        let data = try! JSONEncoder().encode(snapshot)
        let roundTripped = try! JSONDecoder().decode(ProfileServer.self, from: data)
        XCTAssertNil(roundTripped.enrollmentUsername,
            "enrollmentUsername must be nil after JSON round-trip (excluded from CodingKeys)")

        // When converted back, passwords are nil
        let restored = snapshot.toTAKServer()
        XCTAssertNil(restored.certificatePassword, "Certificate password must not survive snapshot")
        XCTAssertNil(restored.caCertificatePassword, "CA cert password must not survive snapshot")
        XCTAssertNil(restored.password, "User password must not survive snapshot")
        XCTAssertNil(restored.certificateName, "Certificate name must not survive snapshot (enrollment needed)")
    }

    // MARK: - ProfileQRCodec base64url helpers

    func testBase64URLEncodeDecodeRoundTrip() throws {
        let original = Data("Hello, OmniTAK! +/= special chars 🗺".utf8)
        let encoded = ProfileQRCodec.base64URLEncode(original)

        // Must not contain standard base64 special chars
        XCTAssertFalse(encoded.contains("+"), "base64url must not contain +")
        XCTAssertFalse(encoded.contains("/"), "base64url must not contain /")
        XCTAssertFalse(encoded.contains("="), "base64url must not contain = padding")

        let decoded = try ProfileQRCodec.base64URLDecode(encoded)
        XCTAssertEqual(decoded, original)
    }

    func testBase64URLDecodePaddingVariants() throws {
        // Verify we handle 0, 1, 2 missing padding chars (lengths mod 4: 0, 3, 2)
        let cases: [String] = [
            "YQ",     // "a" — needs 2 padding chars
            "YWI",    // "ab" — needs 1 padding char
            "YWJj",   // "abc" — no padding needed
        ]
        let expected = ["a", "ab", "abc"]
        for (input, exp) in zip(cases, expected) {
            let data = try ProfileQRCodec.base64URLDecode(input)
            XCTAssertEqual(String(data: data, encoding: .utf8), exp, "Failed for input: \(input)")
        }
    }

    // MARK: - QR URL encode / decode round-trip

    func testQREncodeDecodeRoundTrip() throws {
        let profile = ConfigProfile(
            name: "Bravo Squad",
            teamName: "Bravo",
            teamRole: "Team Member",
            servers: [
                ProfileServer(from: TAKServer(
                    name: "Field Server",
                    host: "field.tak.example.com",
                    port: 8088,
                    protocolType: "tcp",
                    useTLS: false
                ))
            ],
            mapEngine: "mapbox_2d",
            coordinateFormat: "DD",
            unitSystem: "Imperial"
        )

        let urlString = try ProfileQRCodec.encode(profile)

        // Check URL format
        XCTAssertTrue(urlString.hasPrefix("omnitak://profile?d="), "URL must start with omnitak://profile?d=")

        // Check payload size (must be < 2800 chars for reliable QR scanning)
        XCTAssertLessThanOrEqual(urlString.utf8.count, 2800, "Profile URL must fit in a scannable QR code")

        // Decode back
        let decoded = try ProfileQRCodec.decode(urlString: urlString)

        XCTAssertEqual(decoded.name, profile.name)
        XCTAssertEqual(decoded.teamName, profile.teamName)
        XCTAssertEqual(decoded.teamRole, profile.teamRole)
        XCTAssertEqual(decoded.mapEngine, profile.mapEngine)
        XCTAssertEqual(decoded.coordinateFormat, profile.coordinateFormat)
        XCTAssertEqual(decoded.unitSystem, profile.unitSystem)
        XCTAssertEqual(decoded.servers.count, 1)
        XCTAssertEqual(decoded.servers.first?.host, "field.tak.example.com")
        XCTAssertEqual(decoded.servers.first?.port, 8088)
    }

    func testQRDecodeFromURL() throws {
        let profile = ConfigProfile(name: "QR URL Test", coordinateFormat: "MGRS")
        let urlString = try ProfileQRCodec.encode(profile)
        let url = URL(string: urlString)!

        let decoded = try ProfileQRCodec.decode(url: url)
        XCTAssertEqual(decoded.name, "QR URL Test")
        XCTAssertEqual(decoded.coordinateFormat, "MGRS")
    }

    func testDecodeRejectsNonProfileURL() {
        let nonProfileURL = URL(string: "omnitak://enroll?host=server.com")!
        XCTAssertThrowsError(try ProfileQRCodec.decode(url: nonProfileURL)) { error in
            guard case ProfileQRError.notAProfileURL = error else {
                return XCTFail("Expected notAProfileURL, got: \(error)")
            }
        }
    }

    func testDecodeRejectsMissingPayload() {
        let noPayloadURL = URL(string: "omnitak://profile")!
        XCTAssertThrowsError(try ProfileQRCodec.decode(url: noPayloadURL)) { error in
            guard case ProfileQRError.missingPayload = error else {
                return XCTFail("Expected missingPayload, got: \(error)")
            }
        }
    }

    func testDecodeRejectsCorruptPayload() {
        let corruptURL = URL(string: "omnitak://profile?d=not-valid-base64url!!")!
        XCTAssertThrowsError(try ProfileQRCodec.decode(url: corruptURL))
    }

    func testLargeProfileStillFitsQR() throws {
        // Simulate a realistic captain profile: 3 servers, all toggles set
        var servers: [ProfileServer] = []
        for i in 0..<3 {
            servers.append(ProfileServer(from: TAKServer(
                name: "Server \(i)",
                host: "tak-server-\(i).example.mil",
                port: UInt16(8087 + i),
                protocolType: "ssl",
                useTLS: true
            )))
        }

        let profile = ConfigProfile(
            name: "Operations Center — Full Config",
            teamName: "Echo Team",
            teamRole: "Team Lead",
            teamColor: "Red",
            servers: servers,
            mapEngine: "cesium_3d",
            coordinateFormat: "MGRS",
            unitSystem: "Metric",
            mgrsGridEnabled: true,
            mgrsGridDensity: "1km",
            showMGRSLabels: true,
            breadcrumbTrailsEnabled: true,
            selfMarkerStyle: "milstd",
            remoteIdScanEnabled: true,
            gybDetectorEnabled: false,
            selectedMeshFramework: "meshtastic"
        )

        let urlString = try ProfileQRCodec.encode(profile)
        XCTAssertLessThanOrEqual(urlString.utf8.count, 2800,
            "Full realistic profile (\(urlString.utf8.count) bytes) exceeds QR size budget")

        // And verify it round-trips
        let decoded = try ProfileQRCodec.decode(urlString: urlString)
        XCTAssertEqual(decoded.servers.count, 3)
        XCTAssertEqual(decoded.name, profile.name)
    }

    // MARK: - DeepLink parsing

    func testDeepLinkParserRecognizesProfileURL() throws {
        let profile = ConfigProfile(name: "DeepLink Test", coordinateFormat: "DD")
        let urlString = try ProfileQRCodec.encode(profile)
        let url = URL(string: urlString)!

        let result = TAKDeepLink.parse(url: url)
        switch result {
        case .configProfile(let parsed):
            XCTAssertEqual(parsed.name, "DeepLink Test")
            XCTAssertEqual(parsed.coordinateFormat, "DD")
        default:
            XCTFail("Expected .configProfile, got: \(String(describing: result))")
        }
    }

    func testDeepLinkParserIgnoresOtherSchemes() {
        let url = URL(string: "https://example.com/profile")!
        let result = TAKDeepLink.parse(url: url)
        XCTAssertNil(result, "Non-omnitak:// URL should not parse as deep link")
    }

    // MARK: - ProfileStore (non-disk)

    func testProfileStoreSnapshotDoesNotIncludeCallsign() {
        // Snapshot should capture server config but NOT callsign
        let store = ProfileStore()
        let profile = store.snapshotCurrent(name: "Test Snapshot")
        // callsign is intentionally absent from ConfigProfile
        // — there is no `callsign` property on ConfigProfile
        XCTAssertNil(profile.teamName, "teamName is nil from a bare snapshot (caller fills it in)")
    }

    func testProfileStoreCRUD() {
        let store = ProfileStore()
        let profile = ConfigProfile(name: "Test Profile", coordinateFormat: "DMS")
        store.addProfile(profile)

        XCTAssertTrue(store.profiles.contains { $0.id == profile.id })

        store.renameProfile(id: profile.id, name: "Renamed Profile")
        XCTAssertEqual(store.profiles.first { $0.id == profile.id }?.name, "Renamed Profile")

        store.deleteProfile(id: profile.id)
        XCTAssertFalse(store.profiles.contains { $0.id == profile.id })
    }

    // MARK: - Fix #5: Decompression bomb guard

    func testDecompressionBombIsRejected() throws {
        // Craft a URL whose decompressed payload exceeds 65 536 bytes.
        // Strategy: create a large-but-compressible JSON blob, compress it,
        // base64url-encode it, stuff it into the URL, and verify decode throws.
        // We hand-craft the URL rather than going through encode() since encode()
        // enforces the 2800-byte compressed limit (correct behaviour).
        let bigString = String(repeating: "A", count: 100_000)
        let bigData   = bigString.data(using: .utf8)!
        let compressed: Data
        if #available(iOS 13.0, *) {
            compressed = (try? (bigData as NSData).compressed(using: .zlib) as Data) ?? bigData
        } else {
            // On pre-13 the fallback path returns uncompressed; skip on very old OS.
            return
        }
        let payload    = ProfileQRCodec.base64URLEncode(compressed)
        let urlString  = "omnitak://profile?d=\(payload)"

        XCTAssertThrowsError(try ProfileQRCodec.decode(urlString: urlString)) { error in
            guard case ProfileQRError.decompressedPayloadTooLarge = error else {
                return XCTFail("Expected .decompressedPayloadTooLarge, got: \(error)")
            }
        }
    }

    // MARK: - Fix #9 / Fix #11: enrollmentUsername excluded; no secrets in QR

    func testEnrollmentUsernameNotInQRPayload() throws {
        let server = TAKServer(
            name: "HQ",
            host: "tak.mil",
            port: 8089,
            protocolType: "ssl",
            useTLS: true,
            isDefault: false,
            enabled: true,
            certificateName: nil,
            certificatePassword: nil,
            caCertificateName: nil,
            caCertificatePassword: nil,
            allowLegacyTLS: false,
            allowUntrustedTLS: false,
            username: "jdoe",
            password: nil,
            enrollmentPort: 8446
        )
        let profile  = ConfigProfile(
            name: "No-PII Test",
            servers: [ProfileServer(from: server)]
        )
        let urlString = try ProfileQRCodec.encode(profile)

        // The QR URL must not contain the username / callsign in plain text
        XCTAssertFalse(urlString.contains("jdoe"),
            "QR URL must not contain the enrollmentUsername in plain text")

        // Decode and verify enrollmentUsername was stripped
        let decoded = try ProfileQRCodec.decode(urlString: urlString)
        XCTAssertNil(decoded.servers.first?.enrollmentUsername,
            "enrollmentUsername must be nil after QR round-trip")
    }

    // MARK: - Fix #11: No-secrets regression test

    func testSnapshotContainsNoPasswords() throws {
        // Build a profile that mimics a server with cert + CA passwords.
        let serverWithSecrets = TAKServer(
            name: "Secure HQ",
            host: "sec.tak.mil",
            port: 8089,
            protocolType: "ssl",
            useTLS: true,
            isDefault: false,
            enabled: true,
            certificateName: "my-cert",
            certificatePassword: "supersecret",
            caCertificateName: "my-ca",
            caCertificatePassword: "casecret",
            allowLegacyTLS: false,
            allowUntrustedTLS: false,
            username: "operator99",
            password: "hunter2",
            enrollmentPort: 8446
        )
        let profile = ConfigProfile(
            name: "Secrets Test",
            servers: [ProfileServer(from: serverWithSecrets)]
        )

        // 1. JSON serialisation must not contain any secret strings
        let json = try JSONEncoder().encode(profile)
        let jsonStr = String(data: json, encoding: .utf8) ?? ""
        for secret in ["supersecret", "casecret", "hunter2", "operator99"] {
            XCTAssertFalse(jsonStr.contains(secret),
                "Serialised profile must not contain secret: \(secret)")
        }

        // 2. QR URL must not contain any secret strings
        let urlString = try ProfileQRCodec.encode(profile)
        // Check in plain text (the payload is base64url-encoded; secrets would not appear
        // literally, but confirming the decoded form matches is the rigorous check).
        let decoded = try ProfileQRCodec.decode(urlString: urlString)
        XCTAssertNil(decoded.servers.first?.enrollmentUsername, "Username must be nil after QR round-trip")
        // Verify toTAKServer() produced no passwords
        let restored = decoded.servers.first!.toTAKServer()
        XCTAssertNil(restored.password)
        XCTAssertNil(restored.certificatePassword)
        XCTAssertNil(restored.caCertificatePassword)
    }
}
