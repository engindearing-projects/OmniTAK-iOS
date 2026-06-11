//
//  CertificateHandlingTests.swift
//  OmniTAKMobileTests
//
//  Regression tests for certificate handling functionality.
//  Ensures certificate import/export doesn't break with future changes.
//
//  These tests cover:
//  - Certificate format conversion
//  - CSR generation configuration
//  - Certificate manager state
//  - Keychain operations (mocked)
//

import XCTest
import Security
@testable import OmniTAK

// MARK: - CSR Generator Tests

class CSRGeneratorTests: XCTestCase {

    var generator: CSRGenerator!

    override func setUp() {
        super.setUp()
        generator = CSRGenerator()
    }

    override func tearDown() {
        generator = nil
        super.tearDown()
    }

    func testGeneratorInitialization() {
        XCTAssertNotNil(generator)
    }

    // Note: Actual CSR generation tests would require keychain access
    // which may not be available in unit test environment
}

// MARK: - Certificate Format Converter Tests
//
// (The original tests here exercised static isPEMFormat/stripPEMHeaders/
// isValidBase64 helpers that no longer exist — the converter's real API is
// instance `detectFormat(_:password:)`. Rewritten against that.)

class CertificateFormatConverterTests: XCTestCase {

    let converter = CertificateFormatConverter()

    func testDetectFormat_GarbageDataIsNotPKCS12() {
        // 'T' != 0x30, so this fails the ASN.1 SEQUENCE check.
        let info = converter.detectFormat(Data("This is not a certificate".utf8))
        XCTAssertEqual(info.issueDescription, "Not a valid PKCS#12 file")
        XCTAssertFalse(info.needsConversion)
        XCTAssertFalse(info.isLegacyFormat)
    }

    func testDetectFormat_EmptyData() {
        let info = converter.detectFormat(Data())
        XCTAssertEqual(info.issueDescription, "Not a valid PKCS#12 file")
        XCTAssertFalse(info.needsConversion)
    }

    func testDetectFormat_RC2LegacyOIDDetected() {
        // ASN.1 SEQUENCE header + the RC2-40-CBC OID (2a 86 48 86 f7 0d
        // 01 05 06) the converter scans for — the classic legacy-OpenSSL
        // p12 that SecPKCS12Import rejects on iOS.
        var data = Data([0x30, 0x82, 0x01, 0x00])
        data.append(Data([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x06]))
        data.append(Data(repeating: 0x00, count: 32))
        let info = converter.detectFormat(data)
        XCTAssertTrue(info.isLegacyFormat, "RC2-40-CBC must be flagged legacy")
        XCTAssertEqual(info.encryptionAlgorithm, "RC2-40-CBC")
    }

    func testDetectFormat_UnknownAlgorithmAssumesModern() {
        // Valid SEQUENCE header but no known OID → modern assumption,
        // conversion only attempted if direct import fails.
        var data = Data([0x30, 0x82, 0x01, 0x00])
        data.append(Data(repeating: 0x00, count: 64))
        let info = converter.detectFormat(data)
        XCTAssertFalse(info.isLegacyFormat)
    }
}

// MARK: - Certificate Manager Tests

class CertificateManagerTests: XCTestCase {

    var manager: CertificateManager!

    override func setUp() {
        super.setUp()
        manager = CertificateManager.shared
    }

    func testManagerSingleton() {
        let manager1 = CertificateManager.shared
        let manager2 = CertificateManager.shared
        XCTAssertTrue(manager1 === manager2)
    }

    func testCertificatesArrayExists() {
        // Should have a certificates array (may be empty)
        XCTAssertNotNil(manager.certificates)
    }

    // MARK: - Certificate Model Tests
    //
    // (Originally written against a StoredCertificate model that doesn't
    // exist — the real model is TAKCertificate.)

    func testTAKCertificateCreation() {
        let cert = TAKCertificate(
            id: UUID(),
            name: "Test Certificate",
            serverURL: "tak.example.com",
            username: "testuser",
            createdDate: Date(),
            expiryDate: Date().addingTimeInterval(365 * 24 * 60 * 60),
            issuer: "CN=TestCA",
            isValid: true
        )

        XCTAssertEqual(cert.name, "Test Certificate")
        XCTAssertEqual(cert.username, "testuser")
        XCTAssertTrue(cert.isValid)
        XCTAssertEqual(cert.displayName, "Test Certificate (testuser)")
    }

    func testTAKCertificateExpiry() {
        let expired = TAKCertificate(
            id: UUID(),
            name: "Expired",
            serverURL: "tak.example.com",
            username: "user",
            createdDate: Date().addingTimeInterval(-2 * 365 * 24 * 60 * 60),
            expiryDate: Date().addingTimeInterval(-24 * 60 * 60),
            issuer: nil,
            isValid: true
        )
        XCTAssertTrue(expired.isExpired)
    }

    func testTAKCertificateNoExpiryNeverExpires() {
        let cert = TAKCertificate(
            id: UUID(),
            name: "No Expiry",
            serverURL: "tak.example.com",
            username: "user",
            createdDate: Date(),
            expiryDate: nil,
            issuer: nil,
            isValid: true
        )
        XCTAssertFalse(cert.isExpired)
    }
}

// MARK: - Certificate Import Pipeline Tests

class CertificateImportPipelineTests: XCTestCase {

    func testPipelineInitialization() {
        // The pipeline is plain-init (no singleton).
        let pipeline = CertificateImportPipeline()
        XCTAssertNotNil(pipeline)
    }

    func testDefaultP12PasswordResolvesWithoutCrashing() {
        // Sourced from the host app's Info.plist (DEFAULT_P12_PASSWORD via
        // xcconfig); empty string when unset. Don't assert the value — it's
        // configuration, not code.
        _ = CertificateImportPipeline.defaultP12Password
    }

    // Note: Actual import tests would require test certificate files
}

// MARK: - TLS Configuration Tests

class TLSConfigurationTests: XCTestCase {

    func testTLSVersionConstants() {
        // Verify TLS version constants are accessible
        // TLS 1.2 = 0x0303, TLS 1.3 = 0x0304
        XCTAssertEqual(tls_protocol_version_t.TLSv12.rawValue, 0x0303)
        XCTAssertEqual(tls_protocol_version_t.TLSv13.rawValue, 0x0304)
    }

    func testLegacyTLSVersion() {
        // TLS 1.0 = 0x0301 (769 in decimal)
        let tls10 = tls_protocol_version_t(rawValue: 769)
        XCTAssertNotNil(tls10)
    }
}

// (CertificateSourceTests deleted — there is no CertificateSource enum in
// the app; certificate provenance is not modeled on TAKCertificate.)

// MARK: - Direct TCP Sender Tests

class DirectTCPSenderTests: XCTestCase {

    func testSenderInitialization() {
        let sender = DirectTCPSender()
        XCTAssertNotNil(sender)
        XCTAssertFalse(sender.isConnected)
    }

    func testSenderStatisticsInitialState() {
        let sender = DirectTCPSender()
        XCTAssertEqual(sender.bytesReceived, 0)
        XCTAssertEqual(sender.messagesReceived, 0)
    }

    func testSenderStatisticsReset() {
        let sender = DirectTCPSender()
        sender.resetStatistics()

        XCTAssertEqual(sender.bytesReceived, 0)
        XCTAssertEqual(sender.messagesReceived, 0)
    }

    func testSenderBufferOperations() {
        let sender = DirectTCPSender()

        let initialSize = sender.getReceiveBufferSize()
        XCTAssertEqual(initialSize, 0)

        sender.clearReceiveBuffer()
        let clearedSize = sender.getReceiveBufferSize()
        XCTAssertEqual(clearedSize, 0)
    }

    func testSendWithoutConnection() {
        let sender = DirectTCPSender()
        let result = sender.send(xml: "<test/>")

        XCTAssertFalse(result, "Send should fail when not connected")
    }
}

// MARK: - Connection Protocol Tests

class ConnectionProtocolTests: XCTestCase {

    func testTCPProtocol() {
        let proto = ConnectionProtocol.tcp
        XCTAssertNotNil(proto)
    }

    func testUDPProtocol() {
        let proto = ConnectionProtocol.udp
        XCTAssertNotNil(proto)
    }

    func testTLSProtocol() {
        let proto = ConnectionProtocol.tls
        XCTAssertNotNil(proto)
    }

    func testProtocolsAreDifferent() {
        XCTAssertNotEqual(ConnectionProtocol.tcp, ConnectionProtocol.udp)
        XCTAssertNotEqual(ConnectionProtocol.tcp, ConnectionProtocol.tls)
        XCTAssertNotEqual(ConnectionProtocol.udp, ConnectionProtocol.tls)
    }
}
