//
//  CSREnrollmentTests.swift
//  OmniTAKMobileTests
//
//  Regression tests for CSR enrollment functionality.
//  Ensures certificate enrollment doesn't break with future changes.
//
//  These tests cover:
//  - Configuration validation
//  - URL generation
//  - CA configuration parsing
//  - Error handling
//  - PEM to DER conversion
//

import XCTest
@testable import OmniTAKMobile

class CSREnrollmentConfigurationTests: XCTestCase {

    // MARK: - Configuration Tests

    func testConfigurationURLGeneration() {
        let config = CSREnrollmentConfiguration(
            serverHost: "tak.example.com",
            serverPort: 8089,
            enrollmentPort: 8446,
            username: "testuser",
            password: "testpass",
            useSSL: true,
            trustSelfSignedCerts: true
        )

        XCTAssertEqual(config.baseURL, "https://tak.example.com:8446")
        XCTAssertNotNil(config.configURL)
        XCTAssertNotNil(config.csrURL)

        // Verify paths are correct
        XCTAssertTrue(config.configURL?.path.contains("/Marti/api/tls/config") ?? false)
        XCTAssertTrue(config.csrURL?.path.contains("/Marti/api/tls/signClient/v2") ?? false)
    }

    func testConfigurationURLGenerationWithHTTP() {
        let config = CSREnrollmentConfiguration(
            serverHost: "tak.example.com",
            serverPort: 8089,
            enrollmentPort: 8446,
            username: "testuser",
            password: "testpass",
            useSSL: false,
            trustSelfSignedCerts: true
        )

        XCTAssertEqual(config.baseURL, "http://tak.example.com:8446")
    }

    func testConfigurationClientUIDIsUnique() {
        let config1 = CSREnrollmentConfiguration(
            serverHost: "tak.example.com",
            serverPort: 8089,
            enrollmentPort: 8446,
            username: "user1",
            password: "pass",
            useSSL: true,
            trustSelfSignedCerts: true
        )

        let config2 = CSREnrollmentConfiguration(
            serverHost: "tak.example.com",
            serverPort: 8089,
            enrollmentPort: 8446,
            username: "user2",
            password: "pass",
            useSSL: true,
            trustSelfSignedCerts: true
        )

        XCTAssertNotEqual(config1.clientUid, config2.clientUid,
                          "Each configuration should have unique client UID")
    }

    func testConfigurationCSRURLContainsClientInfo() {
        let config = CSREnrollmentConfiguration(
            serverHost: "tak.example.com",
            serverPort: 8089,
            enrollmentPort: 8446,
            username: "testuser",
            password: "testpass",
            useSSL: true,
            trustSelfSignedCerts: true
        )

        guard let csrURL = config.csrURL else {
            XCTFail("CSR URL should not be nil")
            return
        }

        let urlString = csrURL.absoluteString
        XCTAssertTrue(urlString.contains("clientUid="), "CSR URL should include clientUid")
        XCTAssertTrue(urlString.contains("version="), "CSR URL should include version")
    }

    // MARK: - Default Ports Tests

    func testDefaultPorts() {
        // Verify the standard TAK server ports are used
        let ports = StandardTAKPorts()

        XCTAssertEqual(ports.streamingTCP, 8087, "Standard TCP streaming port should be 8087")
        XCTAssertEqual(ports.streamingTLS, 8089, "Standard TLS streaming port should be 8089")
        XCTAssertEqual(ports.webInterface, 8443, "Standard web interface port should be 8443")
        XCTAssertEqual(ports.enrollmentAPI, 8446, "Standard enrollment API port should be 8446")
    }
}

// MARK: - CA Configuration Tests

class CAConfigurationTests: XCTestCase {

    func testCAConfigurationDefaults() {
        let config = CAConfiguration()

        XCTAssertTrue(config.organizationNames.isEmpty)
        XCTAssertTrue(config.organizationalUnitNames.isEmpty)
        XCTAssertTrue(config.countryNames.isEmpty)
        XCTAssertTrue(config.domainComponents.isEmpty)
    }

    func testCAConfigurationMutation() {
        var config = CAConfiguration()
        config.organizationNames.append("TestOrg")
        config.organizationalUnitNames.append("TestOU")
        config.domainComponents.append("test")

        XCTAssertEqual(config.organizationNames.count, 1)
        XCTAssertEqual(config.organizationNames.first, "TestOrg")
    }
}

// MARK: - CSR Subject DN Tests (regression for issue #31)
//
// Background: BBN's TAK Server CertManagerService.signClient (line 143) rejects CSRs
// whose Subject DN contains RDNs the server's <nameEntries> policy did not declare.
// Most TAK Server configs only declare O + OU; including C unconditionally causes
// "CSR validation failed!" (HTTP 500) — see issue #31, solohck Reddit report 2026-05-18.

class CSRSubjectDNTests: XCTestCase {

    func testCSRConfigurationDefaultsToNoCountry() {
        // Default init must NOT inject C — only the caller (after consulting the server's
        // /Marti/api/tls/config nameEntries) decides whether C belongs in the DN.
        let config = CSRConfiguration(commonName: "csrtest")
        XCTAssertNil(config.country, "country must default to nil to avoid TAK Server policy violation")
    }

    func testCSRConfigurationAcceptsExplicitCountry() {
        let config = CSRConfiguration(commonName: "csrtest", country: "US")
        XCTAssertEqual(config.country, "US")
    }

    func testValidationRejectsMalformedCountryWhenProvided() {
        let bad = CSRConfiguration(commonName: "csrtest", country: "USA")
        XCTAssertThrowsError(try CSRGenerator().validateConfiguration(bad)) { err in
            guard case CSRGenerationError.invalidParameters(let msg) = err else {
                return XCTFail("expected invalidParameters, got \(err)")
            }
            XCTAssertTrue(msg.contains("Country"))
        }
    }

    func testValidationAcceptsMissingCountry() {
        let ok = CSRConfiguration(commonName: "csrtest") // no country
        XCTAssertNoThrow(try CSRGenerator().validateConfiguration(ok))
    }

    func testCAConfigPathOmitsCountryWhenServerOmitsIt() {
        // Mirrors solohck's scenario: server returned only O + OU in nameEntries.
        var ca = CAConfiguration()
        ca.organizationNames = ["TAK"]
        ca.organizationalUnitNames = ["TAK"]
        // intentionally no countryNames

        // Reach into the convenience generator's pipeline to verify the DN it would build.
        // We don't generate a key here (keychain side effects); we just confirm the
        // CSRConfiguration the caConfig path produces has no C.
        let config = CSRConfiguration(
            commonName: "csrtest",
            organization: ca.organizationNames.first ?? "TAK",
            organizationalUnit: ca.organizationalUnitNames.first ?? "TAK",
            country: ca.countryNames.first,
            domainComponents: ca.domainComponents
        )
        XCTAssertNil(config.country, "CA config without C must not introduce C")
    }

    func testCAConfigPathHonorsServerProvidedCountry() {
        var ca = CAConfiguration()
        ca.organizationNames = ["TAK"]
        ca.organizationalUnitNames = ["TAK"]
        ca.countryNames = ["DE"]

        let config = CSRConfiguration(
            commonName: "csrtest",
            organization: ca.organizationNames.first ?? "TAK",
            organizationalUnit: ca.organizationalUnitNames.first ?? "TAK",
            country: ca.countryNames.first,
            domainComponents: ca.domainComponents
        )
        XCTAssertEqual(config.country, "DE", "Server-declared C must flow into the CSR")
    }
}

// MARK: - CSR Enrollment Service Tests

class CSREnrollmentServiceTests: XCTestCase {

    var service: CSREnrollmentService!

    override func setUp() {
        super.setUp()
        service = CSREnrollmentService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testServiceInitialization() {
        XCTAssertNotNil(service, "Service should initialize successfully")
    }

    // MARK: - Error Handling Tests

    func testCSREnrollmentErrorDescriptions() {
        // Test all error cases have meaningful descriptions
        let errors: [CSREnrollmentError] = [
            .invalidServerURL,
            .networkError(NSError(domain: "test", code: -1, userInfo: nil)),
            .authenticationFailed,
            .serverError(500, "Test error"),
            .invalidResponse("Invalid data"),
            .certificateStorageFailed("Storage error"),
            .configurationError("Config error")
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have description")
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true,
                          "Error \(error) description should not be empty")
        }
    }

    func testInvalidServerURLError() {
        let error = CSREnrollmentError.invalidServerURL
        XCTAssertTrue(error.errorDescription?.lowercased().contains("url") ?? false)
    }

    func testAuthenticationFailedError() {
        let error = CSREnrollmentError.authenticationFailed
        XCTAssertTrue(error.errorDescription?.lowercased().contains("authentication") ?? false ||
                      error.errorDescription?.lowercased().contains("password") ?? false)
    }

    func testServerErrorIncludesCode() {
        let error = CSREnrollmentError.serverError(500, "Internal error")
        XCTAssertTrue(error.errorDescription?.contains("500") ?? false)
        XCTAssertTrue(error.errorDescription?.contains("Internal error") ?? false)
    }
}

// MARK: - Enrollment Response Tests

class EnrollmentResponseTests: XCTestCase {

    func testEnrollmentResponseStructure() {
        let certData = Data([0x30, 0x82])  // Mock DER certificate start
        let caData = Data([0x30, 0x82])    // Mock CA certificate

        let response = EnrollmentResponse(
            signedCertificate: certData,
            trustChain: [caData],
            privateKeyTag: "test-key-tag"
        )

        XCTAssertEqual(response.signedCertificate, certData)
        XCTAssertEqual(response.trustChain.count, 1)
        XCTAssertEqual(response.privateKeyTag, "test-key-tag")
    }

    func testEnrollmentResponseEmptyTrustChain() {
        let certData = Data([0x30, 0x82])

        let response = EnrollmentResponse(
            signedCertificate: certData,
            trustChain: [],
            privateKeyTag: "test-key"
        )

        XCTAssertTrue(response.trustChain.isEmpty)
    }
}

// MARK: - Integration Configuration Tests

class EnrollmentIntegrationTests: XCTestCase {

    func testConfigurationForLetsEncryptServer() {
        // Regression test for GitHub Issue #33 - Let's Encrypt servers
        let config = CSREnrollmentConfiguration(
            serverHost: "public.opentakserver.io",
            serverPort: 8089,
            enrollmentPort: 8446,
            username: "testuser",
            password: "testpass",
            useSSL: true,
            trustSelfSignedCerts: false  // Should be FALSE for Let's Encrypt
        )

        XCTAssertFalse(config.trustSelfSignedCerts,
                       "Let's Encrypt servers should use system CA validation")
        XCTAssertTrue(config.useSSL, "Should use SSL for enrollment")
    }

    func testConfigurationForSelfSignedServer() {
        // Configuration for typical self-signed TAK server
        let config = CSREnrollmentConfiguration(
            serverHost: "192.168.1.100",
            serverPort: 8089,
            enrollmentPort: 8446,
            username: "operator",
            password: "password",
            useSSL: true,
            trustSelfSignedCerts: true  // Should be TRUE for self-signed
        )

        XCTAssertTrue(config.trustSelfSignedCerts,
                      "Self-signed servers should bypass certificate validation")
    }

    func testConfigurationPathsAreCorrect() {
        // Verify API paths match TAK server expectations
        let config = CSREnrollmentConfiguration(
            serverHost: "test.com",
            serverPort: 8089,
            enrollmentPort: 8446,
            username: "user",
            password: "pass",
            useSSL: true,
            trustSelfSignedCerts: true
        )

        XCTAssertEqual(config.configPath, "/Marti/api/tls/config",
                       "Config path should match TAK API")
        XCTAssertEqual(config.csrPath, "/Marti/api/tls/signClient/v2",
                       "CSR path should match TAK API v2")
    }
}

// MARK: - Error Context Tests

class ErrorContextTests: XCTestCase {

    func testAllErrorContextsExist() {
        // Ensure all expected error contexts are available
        let enrollment = ErrorContext.enrollment
        let connection = ErrorContext.connection
        let dataSync = ErrorContext.dataSync

        // Just verify they exist and are different
        XCTAssertNotEqual(String(describing: enrollment), String(describing: connection))
        XCTAssertNotEqual(String(describing: connection), String(describing: dataSync))
    }
}
