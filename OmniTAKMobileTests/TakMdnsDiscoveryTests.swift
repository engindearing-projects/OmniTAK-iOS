//
//  TakMdnsDiscoveryTests.swift
//  OmniTAKMobileTests
//
//  Unit tests for Bonjour/mDNS LAN TAK server discovery (issue #111).
//
//  mDNS is unauthenticated — anything on the LAN can advertise `_tak._tcp`
//  with whatever name, host, port and TXT records it likes. Everything a
//  responder hands us is hostile input until it has been through
//  `TakMdns.make`, and a survivor may only prefill a form the operator
//  confirms. These tests pin that contract, plus the busy-LAN behaviour
//  (dedupe/debounce/cap) and the iOS 14+ local-network denial state.
//
//  All tests are pure logic — no NWBrowser, no LAN responder, no network.
//  `TakDiscoveryStore` takes an injected browser and an injected clock so
//  the browse-result handling is driven synchronously.
//

import XCTest
import Network
@testable import OmniTAK

// MARK: - Test double

/// Stands in for `BonjourTakBrowser`. Records the lifecycle calls so the
/// tests can prove the browser is actually torn down (radio + battery).
private final class MockTakBrowser: TakServiceBrowsing {
    var onUpdate: (([RawTakService]) -> Void)?
    var onFailure: ((TakDiscoveryFailure) -> Void)?

    private(set) var startCount = 0
    private(set) var cancelCount = 0

    func start() { startCount += 1 }
    func cancel() { cancelCount += 1 }
}

final class TakMdnsDiscoveryTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func svc(
        _ name: String = "Team Server",
        host: String = "192.168.1.50",
        port: Int = 8089,
        txt: [String: String] = [:]
    ) -> DiscoveredTakService {
        guard let s = TakMdns.make(serviceName: name, host: host, port: port, txt: txt) else {
            XCTFail("expected \(host):\(port) to survive validation")
            return DiscoveredTakService(serviceName: "", host: "", port: 0, txt: [:])
        }
        return s
    }

    // MARK: - Service type parity

    // Android's TakMdns.SERVICE_TYPE and iOS' NSBonjourServices entry have to
    // agree exactly or the two apps can't see the same servers.
    func testServiceTypeMatchesAndroid() {
        XCTAssertEqual(TakMdns.serviceType, "_tak._tcp")
    }

    // MARK: - Hostile input: hosts

    func testRejectsEmptyHost() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "", port: 8089, txt: [:]))
    }

    func testRejectsWhitespaceOnlyHost() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "   ", port: 8089, txt: [:]))
    }

    // A Bonjour host is never a URL. A scheme in that field is an attempt to
    // smuggle something through whatever builds a URL downstream — drop it,
    // don't try to salvage a host core out of it.
    func testRejectsHostWithScheme() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "https://evil.example.com", port: 8089, txt: [:]))
    }

    func testRejectsHostWithPath() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "tak.local/../admin", port: 8089, txt: [:]))
    }

    func testRejectsHostWithSpaces() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "tak local", port: 8089, txt: [:]))
    }

    func testRejectsHostWithCredentials() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "user@tak.local", port: 8089, txt: [:]))
    }

    func testRejectsHostWithQueryOrFragment() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "tak.local?a=b", port: 8089, txt: [:]))
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "tak.local#frag", port: 8089, txt: [:]))
    }

    func testRejectsOverlongHost() {
        let host = String(repeating: "a", count: 300) + ".local"
        XCTAssertNil(TakMdns.make(serviceName: "x", host: host, port: 8089, txt: [:]))
    }

    // mDNS resolves to the fully-qualified form with a trailing root dot.
    func testStripsTrailingDotFromMdnsHost() {
        XCTAssertEqual(svc(host: "takserver.local.").host, "takserver.local")
    }

    func testAcceptsIPv4Host() {
        XCTAssertEqual(svc(host: "10.0.0.7").host, "10.0.0.7")
    }

    func testUnwrapsBracketedIPv6() {
        XCTAssertEqual(svc(host: "[fd00::1]").host, "fd00::1")
    }

    // Link-local IPv6 is unusable without its scope zone, so the zone has to
    // survive validation rather than be scrubbed off into a dead address.
    func testAcceptsIPv6HostWithScopeZone() {
        XCTAssertEqual(svc(host: "fe80::1%en0").host, "fe80::1%en0")
    }

    func testRejectsGarbageHost() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "not_a_host!!", port: 8089, txt: [:]))
    }

    // MARK: - Hostile input: ports

    func testRejectsPortZero() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "10.0.0.7", port: 0, txt: [:]))
    }

    func testRejectsNegativePort() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "10.0.0.7", port: -1, txt: [:]))
    }

    func testRejectsPortAbove65535() {
        XCTAssertNil(TakMdns.make(serviceName: "x", host: "10.0.0.7", port: 65_536, txt: [:]))
    }

    func testAcceptsHighestValidPort() {
        XCTAssertEqual(svc(host: "10.0.0.7", port: 65_535).port, 65_535)
    }

    // MARK: - Hostile input: service names

    func testStripsControlCharactersFromServiceName() {
        let s = svc("Team\u{0007}\nServer\u{001B}[31m")
        XCTAssertFalse(s.serviceName.contains("\n"))
        XCTAssertFalse(s.serviceName.contains("\u{0007}"))
        XCTAssertFalse(s.serviceName.contains("\u{001B}"))
        XCTAssertTrue(s.serviceName.contains("Team"))
    }

    func testClampsOverlongServiceName() {
        let s = svc(String(repeating: "N", count: 500))
        XCTAssertLessThanOrEqual(s.serviceName.count, TakMdns.maxNameLength)
        XCTAssertFalse(s.serviceName.isEmpty)
    }

    func testBlankServiceNameFallsBackToHost() {
        XCTAssertEqual(svc("   ", host: "10.0.0.9").serviceName, "10.0.0.9")
    }

    // MARK: - Hostile input: TXT records

    func testTxtKeysAreLowercased() {
        let s = svc(txt: ["TLS": "true", "Protocol": "ssl"])
        XCTAssertEqual(s.txt["tls"], "true")
        XCTAssertEqual(s.txt["protocol"], "ssl")
    }

    func testTxtValuesAreClamped() {
        let s = svc(txt: ["note": String(repeating: "z", count: 4_000)])
        XCTAssertLessThanOrEqual(s.txt["note"]?.count ?? 0, TakMdns.maxTxtValueLength)
    }

    func testTxtRecordCountIsCapped() {
        var big: [String: String] = [:]
        for i in 0..<200 { big["k\(i)"] = "v" }
        XCTAssertLessThanOrEqual(svc(txt: big).txt.count, TakMdns.maxTxtEntries)
    }

    // MARK: - TLS inference (Android parity)

    func testTlsTxtRecordWins() {
        XCTAssertTrue(TakMdns.isTLS(svc(port: 8087, txt: ["tls": "true"])))
        XCTAssertTrue(TakMdns.isTLS(svc(port: 8087, txt: ["tls": "1"])))
    }

    func testTlsFalseTxtOverridesPortConvention() {
        XCTAssertFalse(TakMdns.isTLS(svc(port: 8089, txt: ["tls": "false"])))
    }

    func testProtocolTxtSslImpliesTls() {
        XCTAssertTrue(TakMdns.isTLS(svc(port: 8087, txt: ["protocol": "ssl"])))
    }

    func testProtocolTxtTcpDisablesTls() {
        XCTAssertFalse(TakMdns.isTLS(svc(port: 8089, txt: ["protocol": "tcp"])))
    }

    func testPortConventionImpliesTls() {
        for p in [8089, 8443, 8446, 443] {
            XCTAssertTrue(TakMdns.isTLS(svc(port: p)), "port \(p) should imply TLS")
        }
    }

    func testPlainPortIsNotTls() {
        XCTAssertFalse(TakMdns.isTLS(svc(port: 8087)))
    }

    // MARK: - Prefill: a discovery may only fill in a form

    func testPrefillCarriesHostPortAndProtocol() {
        let p = TakMdns.prefill(for: svc("Bravo", host: "192.168.1.50", port: 8089))
        XCTAssertEqual(p.host, "192.168.1.50")
        XCTAssertEqual(p.portText, "8089")
        XCTAssertEqual(p.protocolValue, "ssl")
        XCTAssertTrue(p.useTLS)
        XCTAssertEqual(p.name, "Bravo")
    }

    func testPrefillProtocolIsTcpWhenNotTls() {
        let p = TakMdns.prefill(for: svc(host: "192.168.1.50", port: 8087))
        XCTAssertEqual(p.protocolValue, "tcp")
        XCTAssertFalse(p.useTLS)
    }

    // MARK: - Never silently overwrite a saved server

    func testAlreadySavedServerIsFlagged() {
        let saved = TAKServer(name: "Mine", host: "192.168.1.50", port: 8089)
        XCTAssertTrue(TakMdns.isAlreadySaved(svc(host: "192.168.1.50", port: 8089), in: [saved]))
    }

    func testAlreadySavedIsCaseInsensitiveOnHost() {
        let saved = TAKServer(name: "Mine", host: "TakServer.local", port: 8089)
        XCTAssertTrue(TakMdns.isAlreadySaved(svc(host: "takserver.local", port: 8089), in: [saved]))
    }

    func testDifferentPortIsNotAlreadySaved() {
        let saved = TAKServer(name: "Mine", host: "192.168.1.50", port: 8089)
        XCTAssertFalse(TakMdns.isAlreadySaved(svc(host: "192.168.1.50", port: 8087), in: [saved]))
    }

    // MARK: - Store: dedupe, cap, sort

    @MainActor
    func testDedupesByHostAndPort() {
        let store = TakDiscoveryStore(browser: MockTakBrowser())
        store.ingest([
            RawTakService(serviceName: "Alpha", host: "192.168.1.50", port: 8089, txt: [:]),
            RawTakService(serviceName: "Alpha (2)", host: "192.168.1.50", port: 8089, txt: [:])
        ], now: t0)
        XCTAssertEqual(store.services.count, 1)
    }

    @MainActor
    func testDedupeIsCaseInsensitiveOnHost() {
        let store = TakDiscoveryStore(browser: MockTakBrowser())
        store.ingest([
            RawTakService(serviceName: "Alpha", host: "TakServer.local", port: 8089, txt: [:]),
            RawTakService(serviceName: "Alpha", host: "takserver.local", port: 8089, txt: [:])
        ], now: t0)
        XCTAssertEqual(store.services.count, 1)
    }

    @MainActor
    func testSameHostDifferentPortsAreDistinct() {
        let store = TakDiscoveryStore(browser: MockTakBrowser())
        store.ingest([
            RawTakService(serviceName: "Alpha", host: "192.168.1.50", port: 8089, txt: [:]),
            RawTakService(serviceName: "Alpha", host: "192.168.1.50", port: 8087, txt: [:])
        ], now: t0)
        XCTAssertEqual(store.services.count, 2)
    }

    // A hostile or just-busy LAN can advertise hundreds of services; the list
    // is an operator picker, not an inventory.
    @MainActor
    func testCapsResultList() {
        let store = TakDiscoveryStore(browser: MockTakBrowser(), maxResults: 8)
        let flood = (0..<400).map {
            RawTakService(serviceName: "S\($0)", host: "10.0.0.\($0 % 250 + 1)", port: 8000 + $0, txt: [:])
        }
        store.ingest(flood, now: t0)
        XCTAssertEqual(store.services.count, 8)
    }

    @MainActor
    func testDropsInvalidServices() {
        let store = TakDiscoveryStore(browser: MockTakBrowser())
        store.ingest([
            RawTakService(serviceName: "Good", host: "10.0.0.7", port: 8089, txt: [:]),
            RawTakService(serviceName: "Bad port", host: "10.0.0.8", port: 0, txt: [:]),
            RawTakService(serviceName: "Bad host", host: "https://evil.example.com", port: 8089, txt: [:])
        ], now: t0)
        XCTAssertEqual(store.services.count, 1)
        XCTAssertEqual(store.services.first?.host, "10.0.0.7")
    }

    // A flapping responder reordering its answers must not reshuffle the rows
    // under the operator's thumb.
    @MainActor
    func testResultsAreStablySorted() {
        let store = TakDiscoveryStore(browser: MockTakBrowser())
        let a = RawTakService(serviceName: "Alpha", host: "10.0.0.1", port: 8089, txt: [:])
        let b = RawTakService(serviceName: "Bravo", host: "10.0.0.2", port: 8089, txt: [:])
        let c = RawTakService(serviceName: "Charlie", host: "10.0.0.3", port: 8089, txt: [:])
        store.ingest([c, a, b], now: t0)
        XCTAssertEqual(store.services.map(\.serviceName), ["Alpha", "Bravo", "Charlie"])

        store.ingest([b, c, a], now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.services.map(\.serviceName), ["Alpha", "Bravo", "Charlie"])
    }

    @MainActor
    func testLostServiceIsRemoved() {
        let store = TakDiscoveryStore(browser: MockTakBrowser())
        let a = RawTakService(serviceName: "Alpha", host: "10.0.0.1", port: 8089, txt: [:])
        let b = RawTakService(serviceName: "Bravo", host: "10.0.0.2", port: 8089, txt: [:])
        store.ingest([a, b], now: t0)
        XCTAssertEqual(store.services.count, 2)

        store.ingest([a], now: t0.addingTimeInterval(10))
        XCTAssertEqual(store.services.map(\.serviceName), ["Alpha"])
    }

    // MARK: - Store: debounce

    @MainActor
    func testFirstIngestPublishesImmediately() {
        let store = TakDiscoveryStore(browser: MockTakBrowser(), minPublishInterval: 0.5)
        XCTAssertTrue(store.ingest([RawTakService(serviceName: "A", host: "10.0.0.1", port: 8089, txt: [:])], now: t0))
        XCTAssertEqual(store.services.count, 1)
    }

    @MainActor
    func testRapidSecondIngestIsCoalesced() {
        let store = TakDiscoveryStore(browser: MockTakBrowser(), minPublishInterval: 0.5)
        store.ingest([RawTakService(serviceName: "A", host: "10.0.0.1", port: 8089, txt: [:])], now: t0)

        let published = store.ingest([
            RawTakService(serviceName: "A", host: "10.0.0.1", port: 8089, txt: [:]),
            RawTakService(serviceName: "B", host: "10.0.0.2", port: 8089, txt: [:])
        ], now: t0.addingTimeInterval(0.05))

        XCTAssertFalse(published, "an update inside the debounce window must not republish")
        XCTAssertEqual(store.services.count, 1)
        XCTAssertTrue(store.hasPendingUpdate)
    }

    // Coalescing must never lose the update — the last snapshot still lands.
    @MainActor
    func testPendingUpdateFlushesAfterInterval() {
        let store = TakDiscoveryStore(browser: MockTakBrowser(), minPublishInterval: 0.5)
        store.ingest([RawTakService(serviceName: "A", host: "10.0.0.1", port: 8089, txt: [:])], now: t0)
        store.ingest([
            RawTakService(serviceName: "A", host: "10.0.0.1", port: 8089, txt: [:]),
            RawTakService(serviceName: "B", host: "10.0.0.2", port: 8089, txt: [:])
        ], now: t0.addingTimeInterval(0.05))

        XCTAssertTrue(store.flushPending(now: t0.addingTimeInterval(0.6)))
        XCTAssertEqual(store.services.count, 2)
        XCTAssertFalse(store.hasPendingUpdate)
    }

    @MainActor
    func testIdenticalSnapshotDoesNotRepublish() {
        let store = TakDiscoveryStore(browser: MockTakBrowser(), minPublishInterval: 0.5)
        let raw = [RawTakService(serviceName: "A", host: "10.0.0.1", port: 8089, txt: [:])]
        store.ingest(raw, now: t0)
        XCTAssertFalse(store.ingest(raw, now: t0.addingTimeInterval(10)),
                       "an unchanged snapshot must not churn the view")
        XCTAssertFalse(store.hasPendingUpdate)
    }

    // MARK: - Store: lifecycle

    @MainActor
    func testStartBrowses() {
        let browser = MockTakBrowser()
        let store = TakDiscoveryStore(browser: browser)
        store.start()
        XCTAssertEqual(browser.startCount, 1)
        XCTAssertEqual(store.state, .browsing)
        XCTAssertTrue(store.state.isSearching)
    }

    @MainActor
    func testStartIsIdempotent() {
        let browser = MockTakBrowser()
        let store = TakDiscoveryStore(browser: browser)
        store.start()
        store.start()
        XCTAssertEqual(browser.startCount, 1)
    }

    // The browse has to stop with the view — an mDNS browse left running keeps
    // the Wi-Fi radio awake.
    @MainActor
    func testStopCancelsBrowserAndClearsResults() {
        let browser = MockTakBrowser()
        let store = TakDiscoveryStore(browser: browser)
        store.start()
        store.ingest([RawTakService(serviceName: "A", host: "10.0.0.1", port: 8089, txt: [:])], now: t0)
        store.stop()

        XCTAssertEqual(browser.cancelCount, 1)
        XCTAssertEqual(store.state, .stopped)
        XCTAssertTrue(store.services.isEmpty)
        XCTAssertFalse(store.state.isSearching)
    }

    @MainActor
    func testStopWithoutStartDoesNotCancel() {
        let browser = MockTakBrowser()
        let store = TakDiscoveryStore(browser: browser)
        store.stop()
        XCTAssertEqual(browser.cancelCount, 0)
    }

    // MARK: - Store: local-network permission denial

    // kDNSServiceErr_PolicyDenied — what mDNSResponder returns once the user
    // taps Don't Allow on the iOS 14+ local-network prompt.
    func testPolicyDeniedDNSErrorClassifiesAsPermissionDenied() {
        XCTAssertEqual(TakMdns.classify(NWError.dns(-65_570)), .permissionDenied)
    }

    func testOtherDNSErrorIsNotPermissionDenied() {
        XCTAssertNotEqual(TakMdns.classify(NWError.dns(-65_540)), .permissionDenied)
    }

    @MainActor
    func testPermissionDeniedDegradesToManualEntry() {
        let browser = MockTakBrowser()
        let store = TakDiscoveryStore(browser: browser)
        store.start()
        store.fail(.permissionDenied)

        XCTAssertEqual(store.state, .permissionDenied)
        XCTAssertFalse(store.state.isSearching, "a denial must not leave a spinner running")
        let message = store.state.operatorMessage
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.lowercased().contains("settings") ?? false,
                      "the denial message should tell the operator where to re-enable it")
        XCTAssertEqual(browser.cancelCount, 1, "a denied browse must be torn down, not left spinning")
    }

    @MainActor
    func testUnavailableFailureCarriesAReason() {
        let store = TakDiscoveryStore(browser: MockTakBrowser())
        store.start()
        store.fail(.unavailable("Wi-Fi is off"))
        XCTAssertEqual(store.state, .unavailable("Wi-Fi is off"))
        XCTAssertFalse(store.state.isSearching)
        XCTAssertEqual(store.state.operatorMessage, "Wi-Fi is off")
    }

    // MARK: - Discovery is inert

    // A discovered entry may only prefill a form. Nothing in the browse path
    // is allowed to reach ServerManager — no save, no connect, no enrol.
    @MainActor
    func testDiscoveryNeverTouchesSavedServers() {
        let before = ServerManager.shared.servers.count
        let store = TakDiscoveryStore(browser: MockTakBrowser())
        store.start()
        store.ingest([
            RawTakService(serviceName: "Rogue", host: "10.0.0.66", port: 8089, txt: ["tls": "true"])
        ], now: t0)

        XCTAssertEqual(store.services.count, 1, "the ingest has to have actually happened")
        XCTAssertEqual(ServerManager.shared.servers.count, before,
                       "discovery must never save or overwrite a server on its own")
    }
}
