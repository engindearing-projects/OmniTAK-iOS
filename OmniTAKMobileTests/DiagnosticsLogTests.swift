//
//  DiagnosticsLogTests.swift
//  OmniTAKMobileTests
//
//  #169 — the in-app log export: which lines it keeps, how it renders them,
//  and that the header never carries a password.
//

import XCTest
@testable import OmniTAK

final class DiagnosticsLogTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_791_500_000) // 2026-10-08 22:13:20 UTC

    private func relevant(_ subsystem: String, _ category: String, _ message: String, system: Bool = true) -> Bool {
        DiagnosticsLog.isRelevant(subsystem: subsystem, category: category, message: message, includeSystemNetworking: system)
    }

    func testKeepsTheAppsOwnLinesAlways() {
        XCTAssertTrue(relevant("com.omnitak.mobile", "tak.network", "anything", system: false))
        XCTAssertTrue(relevant("com.omnitak.mobile", "mission.sync", "anything"))
    }

    /// The lines that name a TLS alert are kept; the per-tile task chatter is not.
    func testSystemNetworkingLinesAreFilteredToWhatExplainsAFailure() {
        XCTAssertTrue(relevant("com.apple.network", "boringssl", "boringssl_session_handshake_error_print(47) TLSV1_ALERT_CERTIFICATE_REQUIRED"))
        XCTAssertTrue(relevant("com.apple.network", "connection", "nw_read_request_report [C14] Receive failed with error \"certificate required\""))
        XCTAssertTrue(relevant("com.apple.CFNetwork", "Default", "Task <1>.<4> HTTP load failed, 0/0 bytes (error code: -1005)"))
        XCTAssertFalse(relevant("com.apple.network", "connection", "nw_protocol_socket_notify [C1] nw_protocol_notification_type_connection_idle is true"))
        XCTAssertFalse(relevant("com.apple.CFNetwork", "Summary", "Task <1>.<4> summary for task success {transaction_duration_ms=463}"))
        XCTAssertFalse(relevant("com.apple.UIKit", "layout", "error in layout"))
    }

    func testSystemNetworkingLinesOnlyWhenAsked() {
        XCTAssertFalse(relevant("com.apple.network", "boringssl", "received fatal alert", system: false))
        XCTAssertFalse(relevant("com.apple.network", "connection", "Receive failed with error", system: false))
    }

    func testRenderedLineHasTimeLevelScopeAndMessage() {
        let line = DiagnosticsLogLine(date: t0, level: "error", subsystem: "com.omnitak.mobile",
                                      category: "tak.network", message: "REST transport failure: x")
        let text = DiagnosticsLog.render(line: line)
        XCTAssertTrue(text.hasSuffix("ERROR  [tak.network] REST transport failure: x"), text)
        // Local time, the way Console.app shows it; the formatter decides the zone.
        XCTAssertTrue(text.hasPrefix(DiagnosticsLog.timestamp.string(from: t0) + " ERROR "), text)
    }

    func testSystemLinesShowTheirSubsystem() {
        let line = DiagnosticsLogLine(date: t0, level: "info", subsystem: "com.apple.network",
                                      category: "boringssl", message: "received fatal alert: certificate_required")
        XCTAssertTrue(DiagnosticsLog.render(line: line).contains("[com.apple.network/boringssl]"))
    }

    func testFullRenderStartsWithTheHeaderAndCountsLines() {
        let lines = [
            DiagnosticsLogLine(date: t0, level: "info", subsystem: "com.omnitak.mobile", category: "a", message: "one"),
            DiagnosticsLogLine(date: t0.addingTimeInterval(1), level: "error", subsystem: "com.omnitak.mobile", category: "b", message: "two")
        ]
        let text = DiagnosticsLog.render(header: "HEADER", lines: lines)
        XCTAssertTrue(text.hasPrefix("HEADER\n\nLog (2 lines)\n"), text)
        XCTAssertTrue(text.hasSuffix("[b] two"), text)
    }

    func testServerLineCarriesTrustFactsButNoSecrets() {
        var server = TAKServer(name: "ARDOS", host: "tak.example", port: 8089, protocolType: "ssl", useTLS: true)
        server.certificateName = "omnitak-cert-tak.example"
        server.caCertificateName = "omnitak-cert-tak.example-ca"
        server.username = "vaclav"
        server.password = "hunter2"
        server.certificatePassword = "p12secret"
        server.secureAPIPort = 8443
        let line = DiagnosticsLog.describe(server: server)
        XCTAssertTrue(line.contains("tak.example:8089 ssl tls"), line)
        XCTAssertTrue(line.contains("api 8443"), line)
        XCTAssertTrue(line.contains("cert omnitak-cert-tak.example"), line)
        XCTAssertTrue(line.contains("credentials stored"), line)
        XCTAssertFalse(line.contains("hunter2"), line)
        XCTAssertFalse(line.contains("p12secret"), line)
        XCTAssertFalse(line.contains("vaclav"), line)
    }

    func testHeaderListsEveryServer() {
        let a = TAKServer(name: "A", host: "a.example", port: 8089, protocolType: "ssl", useTLS: true)
        let b = TAKServer(name: "B", host: "b.example", port: 8087, protocolType: "tcp", useTLS: false)
        let header = DiagnosticsLog.header(servers: [a, b], now: t0)
        XCTAssertTrue(header.hasPrefix("OmniTAK diagnostics\n"), header)
        XCTAssertTrue(header.contains("Servers: 2"), header)
        XCTAssertTrue(header.contains("- A: a.example:8089 ssl tls"), header)
        XCTAssertTrue(header.contains("- B: b.example:8087 tcp,"), header)
    }

    func testExportFileIsWrittenAsText() throws {
        let url = try DiagnosticsLog.exportFile("hello", now: t0)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("OmniTAK-diagnostics-"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
    }
}
