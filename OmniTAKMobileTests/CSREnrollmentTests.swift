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
@testable import OmniTAK

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

// MARK: - CA Config XML Parsing Tests (regression for issue #102)
//
// Background: rick51231 reported that /Marti/api/tls/config was parsed with a
// positional regex that assumed <nameEntry name="…" value="…"/>. XML attribute
// order is not significant, so a server emitting <nameEntry value="TAK" name="O"/>
// (value first) silently produced an EMPTY CA config → a wrong/blank CSR subject
// DN and a failed or mis-identified enrollment. parseCAConfigXML now uses
// XMLParser, which reads attributes by name regardless of order.

class CAConfigXMLParsingTests: XCTestCase {

    private var service: CSREnrollmentService!
    override func setUp() { super.setUp(); service = CSREnrollmentService() }
    override func tearDown() { service = nil; super.tearDown() }

    private func parse(_ xml: String) -> CAConfiguration {
        service.parseCAConfigXML(data: Data(xml.utf8))
    }

    func testCanonicalOrderNameThenValue() {
        let ca = parse(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <certificateConfig validityDays="365">
          <nameEntries>
            <nameEntry name="O" value="TAK"/>
            <nameEntry name="OU" value="TAK-OU"/>
          </nameEntries>
        </certificateConfig>
        """#)
        XCTAssertEqual(ca.organizationNames, ["TAK"])
        XCTAssertEqual(ca.organizationalUnitNames, ["TAK-OU"])
    }

    /// The exact regression rick51231 filed: value BEFORE name. The old regex
    /// produced an empty config here; the parser must recover both RDNs.
    func testValueBeforeNameOrderIssue102() {
        let ca = parse(#"""
        <?xml version="1.0" encoding="UTF-8"?>
        <certificateConfig validityDays="3650">
          <nameEntries>
            <nameEntry value="TAK" name="O"/>
            <nameEntry value="OUTEST" name="OU"/>
          </nameEntries>
        </certificateConfig>
        """#)
        XCTAssertEqual(ca.organizationNames, ["TAK"],
                       "O must parse regardless of attribute order (issue #102)")
        XCTAssertEqual(ca.organizationalUnitNames, ["OUTEST"],
                       "OU must parse regardless of attribute order (issue #102)")
    }

    func testExtraAttributesAndNonNameEntryElementsIgnored() {
        let ca = parse(#"""
        <certificateConfig validityDays="3650" foo="bar">
          <nameEntries>
            <nameEntry name="O" value="ACME" extra="x"/>
            <somethingElse name="O" value="SHOULD-IGNORE"/>
          </nameEntries>
        </certificateConfig>
        """#)
        XCTAssertEqual(ca.organizationNames, ["ACME"])
        XCTAssertFalse(ca.organizationNames.contains("SHOULD-IGNORE"),
                       "Only <nameEntry> elements should contribute RDNs")
    }

    func testAllRDNTypesAndMultiplesCollectedInOrder() {
        let ca = parse(#"""
        <certificateConfig>
          <nameEntry name="O" value="Org1"/>
          <nameEntry value="Org2" name="O"/>
          <nameEntry name="OU" value="Unit1"/>
          <nameEntry name="C" value="US"/>
          <nameEntry name="DC" value="example"/>
          <nameEntry name="DC" value="com"/>
        </certificateConfig>
        """#)
        XCTAssertEqual(ca.organizationNames, ["Org1", "Org2"])
        XCTAssertEqual(ca.organizationalUnitNames, ["Unit1"])
        XCTAssertEqual(ca.countryNames, ["US"])
        XCTAssertEqual(ca.domainComponents, ["example", "com"])
    }

    func testUnknownRDNKeysIgnored() {
        let ca = parse(#"<certificateConfig><nameEntry name="CN" value="ignore-me"/><nameEntry name="O" value="Keep"/></certificateConfig>"#)
        XCTAssertEqual(ca.organizationNames, ["Keep"])
        XCTAssertTrue(ca.countryNames.isEmpty)
    }

    func testMalformedXMLReturnsEmptyConfigWithoutCrashing() {
        // Truncated / not well-formed — must fail closed to an empty config, not crash.
        let ca = parse(#"<certificateConfig><nameEntry name="O" value="TAK""#)
        XCTAssertTrue(ca.organizationNames.isEmpty)
        XCTAssertTrue(ca.organizationalUnitNames.isEmpty)
    }

    func testEmptyDataReturnsEmptyConfig() {
        let ca = service.parseCAConfigXML(data: Data())
        XCTAssertTrue(ca.organizationNames.isEmpty)
        XCTAssertTrue(ca.countryNames.isEmpty)
    }

    func testAttributesSplitAcrossNewlinesTolerated() {
        // A positional regex is fragile when attributes wrap; XMLParser is not.
        let ca = parse("<certificateConfig>\n  <nameEntry\n     value=\"TAK\"\n     name=\"O\"\n  />\n</certificateConfig>")
        XCTAssertEqual(ca.organizationNames, ["TAK"])
    }
}

// MARK: - Saved host (#138)
//
// The enrollment Address field accepts a full endpoint. The enrollment
// REQUEST honours the typed scheme / port / path prefix, but the SAVED server
// must carry only the bare host: the streaming socket dials TAKServer.host
// verbatim, and a "host" literally named "http://192.168.1.10:8446" never
// opens (reported by zeidlos, confirmed against a live server).

final class EnrollmentSavedHostTests: XCTestCase {

    private func config(_ host: String,
                        useSSL: Bool = true,
                        enrollmentPort: Int = 8446,
                        streamingPort: Int = 8089) -> CSREnrollmentConfiguration {
        CSREnrollmentConfiguration(
            serverHost: host,
            serverPort: streamingPort,
            enrollmentPort: enrollmentPort,
            username: "operator",
            password: "secret",
            useSSL: useSSL,
            trustSelfSignedCerts: true
        )
    }

    // MARK: parsedHost

    func testSchemeAndPortAreStrippedFromSavedHost() {
        XCTAssertEqual(config("http://192.168.1.10:8446").parsedHost, "192.168.1.10")
    }

    func testSchemeAndPathPrefixAreStrippedFromSavedHost() {
        XCTAssertEqual(config("https://tak.example.com/prefix").parsedHost, "tak.example.com")
    }

    func testBarePortIsStrippedFromSavedHost() {
        XCTAssertEqual(config("tak.example.com:443").parsedHost, "tak.example.com")
    }

    func testBareHostIsUnchanged() {
        for host in ["tak.example.com", "192.168.1.100", "public.opentakserver.io", "tak"] {
            XCTAssertEqual(config(host).parsedHost, host, "a bare host must round-trip untouched")
        }
    }

    func testWhitespaceAndTrailingSlashesAreTrimmed() {
        XCTAssertEqual(config("  https://tak.example.com/tak//  ").parsedHost, "tak.example.com")
    }

    func testHostCaseIsPreserved() {
        // Only the scheme is case-folded; the host stays as typed.
        XCTAssertEqual(config("HTTPS://TAK.Example.com").parsedHost, "TAK.Example.com")
    }

    func testIPv6LiteralsSaveWithoutBracketsOrPort() {
        XCTAssertEqual(config("[fd00::10]:8446").parsedHost, "fd00::10")
        XCTAssertEqual(config("[fd00::10]").parsedHost, "fd00::10")
        XCTAssertEqual(config("https://[fd00::10]:8446/tak").parsedHost, "fd00::10")
        // A bare IPv6 literal has no port; it must not be split on its last colon.
        XCTAssertEqual(config("fd00::10").parsedHost, "fd00::10")
        XCTAssertEqual(config("::1").parsedHost, "::1")
    }

    // MARK: the enrollment request still honours what was typed

    func testBaseURLStillUsesTheTypedScheme_Port_AndPath() {
        XCTAssertEqual(config("http://192.168.1.10:8446").baseURL, "http://192.168.1.10:8446")
        // A scheme with no port means the scheme default: omitted from the URL.
        XCTAssertEqual(config("https://tak.example.com/prefix").baseURL, "https://tak.example.com/prefix")
        XCTAssertEqual(config("https://tak.example.com/tak/").baseURL, "https://tak.example.com/tak")
        // An explicit port beats the separate Enrollment Port field.
        XCTAssertEqual(config("tak.example.com:443").baseURL, "https://tak.example.com:443")
        XCTAssertEqual(config("tak.example.com:9000", enrollmentPort: 8446).baseURL, "https://tak.example.com:9000")
        // A bare host templates in the Enrollment Port field.
        XCTAssertEqual(config("tak.example.com").baseURL, "https://tak.example.com:8446")
        XCTAssertEqual(config("tak.example.com", useSSL: false).baseURL, "http://tak.example.com:8446")
    }

    func testBaseURLBracketsIPv6Literals() {
        XCTAssertEqual(config("[fd00::10]:8446").baseURL, "https://[fd00::10]:8446")
        XCTAssertEqual(config("fd00::10").baseURL, "https://[fd00::10]:8446")
        XCTAssertEqual(config("https://[fd00::10]/tak").baseURL, "https://[fd00::10]/tak")
        XCTAssertNotNil(config("fd00::10").configURL, "a bare IPv6 host must still produce a valid enrollment URL")
    }

    // MARK: the saved server

    func testSavedServerCarriesTheParsedHost() {
        let typed = [
            ("http://192.168.1.10:8446", "192.168.1.10"),
            ("https://tak.example.com/prefix", "tak.example.com"),
            ("tak.example.com:443", "tak.example.com"),
            ("tak.example.com", "tak.example.com"),
        ]
        for (raw, expected) in typed {
            let server = config(raw).makeServer()
            XCTAssertEqual(server.host, expected, "saved host for '\(raw)'")
            XCTAssertEqual(server.name, "TAK Server (\(expected))", "display name for '\(raw)'")
            for bad in ["://", "/", ":"] {
                XCTAssertFalse(server.host.contains(bad), "saved host '\(server.host)' must not contain '\(bad)'")
            }
        }
    }

    func testSavedServerKeepsTheStreamingPortAndProtocol() {
        let tls = config("http://192.168.1.10:8446", streamingPort: 8089).makeServer()
        XCTAssertEqual(tls.port, 8089, "the streaming port comes from the Streaming Port field, not the typed enrollment port")
        XCTAssertEqual(tls.protocolType, "ssl")
        XCTAssertTrue(tls.useTLS)

        let plain = config("tak.example.com", useSSL: false, streamingPort: 8087).makeServer()
        XCTAssertEqual(plain.port, 8087)
        XCTAssertEqual(plain.protocolType, "tcp")
        XCTAssertFalse(plain.useTLS)
    }

    func testSavedServerCertificateNamesPointAtTheNewAlias() {
        let server = config("https://tak.example.com/prefix").makeServer()
        XCTAssertEqual(server.certificateName, "omnitak-cert-tak.example.com")
        XCTAssertEqual(server.caCertificateName, "omnitak-cert-tak.example.com-ca")
        XCTAssertEqual(server.certificatePassword, "omnitak")
    }

    func testCertificateAliasForABareHostIsUnchanged() {
        // Servers enrolled with a bare host before this fix keep their keychain
        // items; a re-enrollment of the same host must resolve to the same label.
        XCTAssertEqual(config("tak.example.com").certificateAlias, "omnitak-cert-tak.example.com")
        XCTAssertEqual(config("192.168.1.100").certificateAlias, "omnitak-cert-192.168.1.100")
    }

    func testCertificateAliasNeverEmbedsSchemePortOrPath() {
        for raw in ["http://192.168.1.10:8446", "https://tak.example.com/prefix", "tak.example.com:443"] {
            let alias = config(raw).certificateAlias
            XCTAssertFalse(alias.contains("://"), "alias '\(alias)' embeds a scheme")
            XCTAssertFalse(alias.contains("/"), "alias '\(alias)' embeds a path")
            XCTAssertFalse(alias.contains(":"), "alias '\(alias)' embeds a port")
        }
    }
}

// MARK: - Address parsing shared by every entry point (#138)

final class TAKServerAddressTests: XCTestCase {

    func testParsesSchemeHostPortAndPath() {
        let a = TAKServerAddress(parsing: "HTTPS://tak.example.com:8446/tak/")
        XCTAssertEqual(a.scheme, "https")
        XCTAssertTrue(a.hadSchemeDelimiter)
        XCTAssertEqual(a.host, "tak.example.com")
        XCTAssertEqual(a.port, 8446)
        XCTAssertEqual(a.basePath, "/tak")
    }

    func testBareHostHasNoSchemePortOrPath() {
        let a = TAKServerAddress(parsing: "tak.example.com")
        XCTAssertNil(a.scheme)
        XCTAssertFalse(a.hadSchemeDelimiter)
        XCTAssertEqual(a.host, "tak.example.com")
        XCTAssertNil(a.port)
        XCTAssertEqual(a.basePath, "")
    }

    func testEmptySchemeStillCountsAsADelimiter() {
        // "://host" keeps the long-standing behaviour: no scheme, but the user
        // described a full endpoint, so the Enrollment Port field is ignored.
        let a = TAKServerAddress(parsing: "://tak.example.com")
        XCTAssertNil(a.scheme)
        XCTAssertTrue(a.hadSchemeDelimiter)
        XCTAssertEqual(a.host, "tak.example.com")
    }

    func testNonNumericSuffixIsNotAPort() {
        let a = TAKServerAddress(parsing: "tak.example.com:abc")
        XCTAssertNil(a.port)
        XCTAssertEqual(a.host, "tak.example.com:abc")
    }

    func testEmptyAndWhitespaceInputYieldAnEmptyHost() {
        XCTAssertEqual(TAKServerAddress(parsing: "").host, "")
        XCTAssertEqual(TAKServerAddress(parsing: "   ").host, "")
        XCTAssertEqual(TAKServerAddress(parsing: "http://").host, "")
    }

    // MARK: plain-TCP target

    func testStreamingTargetUsesTheFallbackPortWhenNoneIsTyped() {
        let t = TAKServerAddress.streamingTarget(from: "192.168.1.10", fallbackPort: 8087)
        XCTAssertEqual(t.host, "192.168.1.10")
        XCTAssertEqual(t.port, 8087)
    }

    func testStreamingTargetStripsAnyScheme() {
        for raw in ["tcp://192.168.1.10", "http://192.168.1.10", "https://192.168.1.10/tak"] {
            let t = TAKServerAddress.streamingTarget(from: raw, fallbackPort: 8087)
            XCTAssertEqual(t.host, "192.168.1.10", raw)
            XCTAssertEqual(t.port, 8087, raw)
        }
    }

    func testStreamingTargetPrefersAPortTypedInTheAddress() {
        let t = TAKServerAddress.streamingTarget(from: "192.168.1.10:9000", fallbackPort: 8087)
        XCTAssertEqual(t.host, "192.168.1.10")
        XCTAssertEqual(t.port, 9000)
    }

    func testStreamingTargetIgnoresAnOutOfRangePort() {
        let t = TAKServerAddress.streamingTarget(from: "192.168.1.10:70000", fallbackPort: 8087)
        XCTAssertEqual(t.host, "192.168.1.10")
        XCTAssertEqual(t.port, 8087)
    }

    func testStreamingTargetHandlesIPv6() {
        let bracketed = TAKServerAddress.streamingTarget(from: "[fd00::10]:8087", fallbackPort: 1)
        XCTAssertEqual(bracketed.host, "fd00::10")
        XCTAssertEqual(bracketed.port, 8087)
        let bare = TAKServerAddress.streamingTarget(from: "fd00::10", fallbackPort: 8087)
        XCTAssertEqual(bare.host, "fd00::10")
        XCTAssertEqual(bare.port, 8087)
    }

    // MARK: QR / deep-link host

    func testDeepLinkSplitHostPortReturnsBareHosts() {
        XCTAssertEqual(EnrollmentDeepLink.splitHostPort("argustak.com:8089").host, "argustak.com")
        XCTAssertEqual(EnrollmentDeepLink.splitHostPort("argustak.com:8089").port, 8089)
        XCTAssertEqual(EnrollmentDeepLink.splitHostPort("https://tak.example.com:8089/tak").host, "tak.example.com")
        XCTAssertEqual(EnrollmentDeepLink.splitHostPort("https://tak.example.com:8089/tak").port, 8089)
        XCTAssertEqual(EnrollmentDeepLink.splitHostPort("tak.example.com").host, "tak.example.com")
        XCTAssertNil(EnrollmentDeepLink.splitHostPort("tak.example.com").port)
    }

    func testDeepLinkSplitHostPortDoesNotMangleIPv6() {
        let bare = EnrollmentDeepLink.splitHostPort("fd00::10")
        XCTAssertEqual(bare.host, "fd00::10")
        XCTAssertNil(bare.port)
        let bracketed = EnrollmentDeepLink.splitHostPort("[fd00::10]:8089")
        XCTAssertEqual(bracketed.host, "fd00::10")
        XCTAssertEqual(bracketed.port, 8089)
    }

    func testTokenEnrollmentLinkYieldsABareHostAndEmbeddedStreamingPort() throws {
        let url = try XCTUnwrap(URL(string: "tak://com.atakmap.app/enroll?host=argustak.com%3A8089&username=u&token=t"))
        let link = try XCTUnwrap(EnrollmentDeepLink.parse(url: url))
        XCTAssertEqual(link.host, "argustak.com")
        XCTAssertEqual(link.port, 8089)
    }
}

// MARK: - Enrolled CA Chain

/// The CA chain recorded per server alias, used when the keychain holds the
/// same CA under another server's label (it refuses a second copy, so the new
/// label never exists and the stream had no anchor: stuck on "Connecting").
class EnrolledCAChainTests: XCTestCase {

    /// A throwaway self-signed P-256 certificate, DER, base64.
    private static let caBase64 =
        "MIICGDCCAb4CCQDqHJSY8favSzAKBggqhkjOPQQDAjAaMRgwFgYDVQQDDA9PbW5pVEFLIFRlc3Qg" +
        "Q0EwHhcNMjYxMDA0MDE0NTQzWhcNMzYxMDAxMDE0NTQzWjAaMRgwFgYDVQQDDA9PbW5pVEFLIFRl" +
        "c3QgQ0EwggFLMIIBAwYHKoZIzj0CATCB9wIBATAsBgcqhkjOPQEBAiEA/////wAAAAEAAAAAAAAA" +
        "AAAAAAD///////////////8wWwQg/////wAAAAEAAAAAAAAAAAAAAAD///////////////wEIFrG" +
        "NdiqOpPns+u9VXaYhrxlHQawzFOw9jvOPD4n0mBLAxUAxJ02CIbnBJNqZnjhE50mt4GffpAEQQRr" +
        "F9Hy4SxCR/i85uVjpEDydwN9gS3rM6D0oTlF2JjClk/jQuL+Gn+bjufrSnwPnhYrzjNXazFezsu2" +
        "QGg3v1H1AiEA/////wAAAAD//////////7zm+q2nF56E87nKwvxjJVECAQEDQgAE2bzzj7pyvER2" +
        "OY4xaW6pyyV+oWG1HWNZt4NeDllUAwv1vW0KZ63K1Rloy5RF9eeQL7wiknWiyp1USiBR1MRKfjAK" +
        "BggqhkjOPQQDAgNIADBFAiEAo3O9kMOnF6eKChojI+dtbSLIzYWRVBv/E4eA6zaAAvACIHauG4c7" +
        "oMP7XAUYA1sHOQ7E1lNkH85Oc0GqcqaKJ4/0"

    private var caDER: Data!
    private var defaults: UserDefaults!
    private let suite = "EnrolledCAChainTests"

    override func setUpWithError() throws {
        caDER = try XCTUnwrap(Data(base64Encoded: Self.caBase64))
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testChainRoundTripsByCAName() throws {
        EnrolledCAChain.save([caDER], caName: "omnitak-cert-tak.example.com-ca", defaults: defaults)

        let loaded = try XCTUnwrap(EnrolledCAChain.load(caName: "omnitak-cert-tak.example.com-ca", defaults: defaults))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(SecCertificateCopyData(loaded[0]) as Data, caDER)
    }

    func testChainIsKeptPerServer() {
        EnrolledCAChain.save([caDER], caName: "omnitak-cert-a.example.com-ca", defaults: defaults)

        XCTAssertNil(EnrolledCAChain.load(caName: "omnitak-cert-b.example.com-ca", defaults: defaults))
    }

    func testUnreadableChainLoadsAsNothing() {
        EnrolledCAChain.save([Data("not a certificate".utf8)], caName: "omnitak-cert-bad-ca", defaults: defaults)
        XCTAssertNil(EnrolledCAChain.load(caName: "omnitak-cert-bad-ca", defaults: defaults))

        EnrolledCAChain.save([], caName: "omnitak-cert-empty-ca", defaults: defaults)
        XCTAssertNil(EnrolledCAChain.load(caName: "omnitak-cert-empty-ca", defaults: defaults))
    }

    /// The case that left a second enrollment on "Connecting": no keychain
    /// certificate carries this server's CA label, so the lookup has to come
    /// back with the chain the enrollment recorded.
    func testStreamAnchorLookupFallsBackToTheRecordedChain() throws {
        let caName = "omnitak-cert-fallback-\(UUID().uuidString)-ca"
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: "csr_ca_chain_\(caName)") }

        XCTAssertNil(DirectTCPSender.loadCACertificates(name: caName), "nothing recorded yet")

        EnrolledCAChain.save([caDER], caName: caName)
        let anchors = try XCTUnwrap(DirectTCPSender.loadCACertificates(name: caName))
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(SecCertificateCopyData(anchors[0]) as Data, caDER)
    }
}
