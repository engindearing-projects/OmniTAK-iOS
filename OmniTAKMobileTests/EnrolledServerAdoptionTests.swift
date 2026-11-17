//
//  EnrolledServerAdoptionTests.swift
//  OmniTAKMobileTests
//
//  #156: enrolling with a TAK server (the Enroll form, an enrollment link or QR) saves
//  the server once and dials it once. Enrolling again for an endpoint that is already
//  saved updates that saved record, under its own id, and dials it again with the new
//  certificate. Before, the enrollment paths dialed a new server twice (the second dial
//  was the older single connection), and a re-enrollment left the link made with the old
//  certificate up, pointed "active" at a record that was never saved, and opened another
//  connection.
//
//  The first two classes test the rules as plain values: how an enrollment is merged
//  into a saved record, and whether an enrollment is for a new endpoint or a saved one.
//  The third drives ServerManager.adoptEnrolledServer and the real TAKService against a
//  loopback server and counts the connections it accepts.
//

import XCTest
@testable import OmniTAK

// MARK: - Records

private enum EnrollmentRecords {

    /// What `CSREnrollmentConfiguration.makeServer` builds after an enrollment: a new id
    /// every time, a name made from the host, a certificate named for the host.
    static func enrolled(host: String = "tak.example.com", port: Int = 8089) -> TAKServer {
        CSREnrollmentConfiguration(
            serverHost: host, serverPort: port, enrollmentPort: 8446,
            username: "operator", password: "pw", useSSL: true, trustSelfSignedCerts: true
        ).makeServer()
    }

    /// The record the operator already has for that endpoint: a name they chose,
    /// switched off, the default server, a certificate that came from a data package, and
    /// settings an enrollment does not decide.
    static func saved(host: String = "tak.example.com", port: UInt16 = 8089) -> TAKServer {
        TAKServer(
            name: "Ops Center", host: host, port: port, protocolType: "ssl", useTLS: true,
            isDefault: true, enabled: false,
            certificateName: "imported-client", certificatePassword: "atakatak",
            caCertificateName: "imported-truststore", caCertificatePassword: "atakatak",
            allowLegacyTLS: true, allowUntrustedTLS: true,
            username: "operator", password: "secret", enrollmentPort: 9446, secureAPIPort: 9443
        )
    }
}

// MARK: - Merging an enrollment into a saved record

final class EnrolledServerMergeTests: XCTestCase {

    func testTheMergedRecordKeepsTheSavedRecordsIdentity() {
        let saved = EnrollmentRecords.saved()
        let enrolled = EnrollmentRecords.enrolled()
        let merged = saved.mergingEnrollment(enrolled)

        XCTAssertEqual(merged.id, saved.id, "the Servers list, the active server and the live link know the record by its id")
        XCTAssertNotEqual(merged.id, enrolled.id, "the id an enrollment makes is new every time and means nothing")
        XCTAssertEqual(merged.name, "Ops Center", "the name the operator chose")
        XCTAssertFalse(merged.enabled, "whether it is switched on is the operator's, until the adoption switches it on")
        XCTAssertTrue(merged.isDefault)
        XCTAssertEqual(merged.host, saved.host)
        XCTAssertEqual(merged.port, saved.port)
    }

    func testTheMergedRecordTakesTheCertificateFieldsOfTheEnrollment() {
        let saved = EnrollmentRecords.saved()
        let enrolled = EnrollmentRecords.enrolled()
        let merged = saved.mergingEnrollment(enrolled)

        XCTAssertEqual(merged.certificateName, "omnitak-cert-tak.example.com")
        XCTAssertEqual(merged.certificateName, enrolled.certificateName)
        XCTAssertEqual(merged.certificatePassword, enrolled.certificatePassword)
        XCTAssertEqual(merged.caCertificateName, "omnitak-cert-tak.example.com-ca")
        XCTAssertEqual(merged.caCertificateName, enrolled.caCertificateName)
        // The CA chain of an enrollment has no password. The saved one belonged to the
        // chain it replaces, so it goes with it.
        XCTAssertNil(enrolled.caCertificatePassword)
        XCTAssertNil(merged.caCertificatePassword)
        XCTAssertEqual(merged.useTLS, enrolled.useTLS)
        XCTAssertEqual(merged.protocolType, enrolled.protocolType)
    }

    func testTheMergedRecordKeepsWhatTheOperatorSetAndAnEnrollmentDoesNotDecide() {
        let saved = EnrollmentRecords.saved()
        let merged = saved.mergingEnrollment(EnrollmentRecords.enrolled())

        XCTAssertTrue(merged.allowLegacyTLS)
        XCTAssertTrue(merged.allowUntrustedTLS, "an explicit opt-in (#127) is not switched off by enrolling again")
        XCTAssertEqual(merged.username, "operator")
        XCTAssertEqual(merged.password, "secret")
        XCTAssertEqual(merged.enrollmentPort, 9446)
    }

    func testAnAPIPortThatWasGivenReplacesTheSavedOne() {
        let merged = EnrollmentRecords.saved().mergingEnrollment(EnrollmentRecords.enrolled(), apiPort: 8443)
        XCTAssertEqual(merged.secureAPIPort, 8443)
    }

    func testNoAPIPortKeepsTheSavedOne() {
        let merged = EnrollmentRecords.saved().mergingEnrollment(EnrollmentRecords.enrolled(), apiPort: nil)
        XCTAssertEqual(merged.secureAPIPort, 9443, "an enrollment link without apiport must not undo the port the operator set")
    }

    func testNoAPIPortAndNoSavedOneLeavesItUnset() {
        var saved = EnrollmentRecords.saved()
        saved.secureAPIPort = nil
        XCTAssertNil(saved.mergingEnrollment(EnrollmentRecords.enrolled()).secureAPIPort)
    }

    func testMergingTheSameEnrollmentAgainChangesNothing() {
        let saved = EnrollmentRecords.saved()
        let enrolled = EnrollmentRecords.enrolled()
        let once = saved.mergingEnrollment(enrolled, apiPort: 8443)
        XCTAssertEqual(once.mergingEnrollment(enrolled, apiPort: 8443), once)
    }
}

// MARK: - New endpoint or saved one

final class EnrolledServerAdoptionPlanTests: XCTestCase {

    func testAnEndpointThatIsNotSavedIsNew() {
        let enrolled = EnrollmentRecords.enrolled()
        let plan = EnrolledServerAdoption.plan(enrolled: enrolled, apiPort: nil, saved: [])

        XCTAssertTrue(plan.isNew)
        XCTAssertEqual(plan.server, enrolled, "a new server is saved exactly as enrolled")
        XCTAssertNil(plan.server.secureAPIPort)
    }

    func testTheAPIPortIsAppliedToANewServer() {
        let enrolled = EnrollmentRecords.enrolled()
        let plan = EnrolledServerAdoption.plan(enrolled: enrolled, apiPort: 9443, saved: [])

        XCTAssertTrue(plan.isNew)
        XCTAssertEqual(plan.server.secureAPIPort, 9443)
        XCTAssertEqual(plan.server.id, enrolled.id, "a new server keeps the id it was built with")
    }

    func testTheSameHostPortAndProtocolIsASavedEndpoint() {
        let saved = EnrollmentRecords.saved()
        let enrolled = EnrollmentRecords.enrolled()
        let plan = EnrolledServerAdoption.plan(enrolled: enrolled, apiPort: 8443, saved: [saved])

        XCTAssertFalse(plan.isNew)
        XCTAssertEqual(plan.server.id, saved.id, "the saved record is the one to keep, not the one the enrollment built")
        XCTAssertEqual(plan.server, saved.mergingEnrollment(enrolled, apiPort: 8443))
    }

    func testASwitchedOffRecordStillCountsAsSaved() {
        var saved = EnrollmentRecords.saved()
        saved.enabled = false
        let plan = EnrolledServerAdoption.plan(enrolled: EnrollmentRecords.enrolled(), apiPort: nil, saved: [saved])
        XCTAssertFalse(plan.isNew)
        XCTAssertFalse(plan.server.enabled, "the plan keeps the state; switching it on is the adoption's step")
    }

    func testTheHostIsMatchedWithoutRegardToCase() {
        let saved = EnrollmentRecords.saved(host: "tak.example.com")
        let enrolled = EnrollmentRecords.enrolled(host: "TAK.Example.COM")
        let plan = EnrolledServerAdoption.plan(enrolled: enrolled, apiPort: nil, saved: [saved])

        XCTAssertFalse(plan.isNew)
        XCTAssertEqual(plan.server.id, saved.id)
        XCTAssertEqual(plan.server.host, "tak.example.com", "the saved spelling of the host stays")
    }

    func testSSLAndTLSAreTheSameEndpoint() {
        // Enrollment saves "ssl". Edit Server saves "tls", even when nothing was changed. A
        // server the operator has edited is still the saved server for the next enrollment.
        var edited = EnrollmentRecords.saved()
        edited.protocolType = "tls"
        let plan = EnrolledServerAdoption.plan(enrolled: EnrollmentRecords.enrolled(), apiPort: nil, saved: [edited])
        XCTAssertFalse(plan.isNew, "an edited server must not be saved a second time")
        XCTAssertEqual(plan.server.id, edited.id)

        // And the other way round: an enrollment that says "tls" for a record saved as "ssl".
        var enrolledAsTLS = EnrollmentRecords.enrolled()
        enrolledAsTLS.protocolType = "tls"
        let other = EnrolledServerAdoption.plan(enrolled: enrolledAsTLS, apiPort: nil, saved: [EnrollmentRecords.saved()])
        XCTAssertFalse(other.isNew)
    }

    func testPlainTCPIsNotTheSameEndpointAsTLS() {
        var tcp = EnrollmentRecords.saved()
        tcp.protocolType = "tcp"
        tcp.useTLS = false
        XCTAssertTrue(EnrolledServerAdoption.plan(enrolled: EnrollmentRecords.enrolled(), apiPort: nil, saved: [tcp]).isNew)
    }

    func testAnotherPortAnotherProtocolOrAnotherHostIsNew() {
        let saved = EnrollmentRecords.saved()

        let otherPort = EnrollmentRecords.enrolled(port: 8090)
        XCTAssertTrue(EnrolledServerAdoption.plan(enrolled: otherPort, apiPort: nil, saved: [saved]).isNew)

        var otherProtocol = EnrollmentRecords.enrolled()
        otherProtocol.protocolType = "tcp"
        XCTAssertTrue(EnrolledServerAdoption.plan(enrolled: otherProtocol, apiPort: nil, saved: [saved]).isNew)

        let otherHost = EnrollmentRecords.enrolled(host: "tak2.example.com")
        XCTAssertTrue(EnrolledServerAdoption.plan(enrolled: otherHost, apiPort: nil, saved: [saved]).isNew)
    }

    func testOnlyTheRecordForTheEndpointIsMerged() {
        let elsewhere = EnrollmentRecords.saved(host: "other.example.com")
        let saved = EnrollmentRecords.saved()
        let plan = EnrolledServerAdoption.plan(enrolled: EnrollmentRecords.enrolled(), apiPort: nil, saved: [elsewhere, saved])
        XCTAssertFalse(plan.isNew)
        XCTAssertEqual(plan.server.id, saved.id)
    }

    func testTheFirstRecordWinsWhenTwoShareAnEndpoint() {
        // addServer takes the first match too, so a list that already holds a duplicate
        // is merged into the same record the Servers list shows first.
        let first = EnrollmentRecords.saved()
        let second = EnrollmentRecords.saved()
        let plan = EnrolledServerAdoption.plan(enrolled: EnrollmentRecords.enrolled(), apiPort: nil, saved: [first, second])
        XCTAssertEqual(plan.server.id, first.id)
    }
}

// MARK: - ServerManager and TAKService, against a loopback server

final class AdoptEnrolledServerTests: XCTestCase {

    private var tak: LoopbackTAKServer!
    private var manager: ServerManager!
    private var suite: String!
    private let service = TAKService.shared
    private var originalLookup: ((UUID) -> TAKServer?)!
    private var originalEnabled: (() -> [TAKServer])!

    override func setUpWithError() throws {
        try super.setUpWithError()
        service.disconnect()

        // A manager of its own, saved in a suite of its own, that the service reads its
        // saved list from: ServerManager.shared and the servers saved on the simulator
        // are never touched.
        suite = "AdoptEnrolledServerTests-\(UUID().uuidString)"
        let list = ServerManager(defaults: UserDefaults(suiteName: suite)!)
        manager = list
        originalLookup = service.serverLookup
        originalEnabled = service.enabledServers
        service.serverLookup = { id in list.servers.first { $0.id == id } }
        service.enabledServers = { list.getEnabledServers() }

        tak = LoopbackTAKServer()
        try tak.start()
    }

    override func tearDown() {
        service.disconnect()
        service.connectTimeout = 15
        service.serverLookup = originalLookup
        service.enabledServers = originalEnabled
        tak?.stop()
        tak = nil
        manager = nil
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// What an enrollment builds for the loopback server: plain TCP, so the test can
    /// accept it. The certificate names are what an enrollment saves; plain TCP never
    /// reads them. A new id every time, as `makeServer` makes.
    private func enrolled(certificate: String = "omnitak-cert-127.0.0.1") -> TAKServer {
        TAKServer(
            name: "TAK Server (127.0.0.1)", host: "127.0.0.1", port: tak.port,
            protocolType: "tcp", useTLS: false,
            certificateName: certificate, certificatePassword: "omnitak",
            caCertificateName: "\(certificate)-ca"
        )
    }

    private func waitUntilUp(_ id: UUID, _ what: String = "the link to come up") {
        waitUntil(what) { service.isConnectedTo(serverId: id) }
    }

    /// Connections the server accepted that the app has not closed.
    private var liveConnections: Int { tak.acceptedCount - tak.closedByClientCount }

    // MARK: - A new server

    @MainActor
    func testANewServerIsSavedActiveAndDialedOnce() {
        let adoption = manager.adoptEnrolledServer(enrolled(), apiPort: 8443)

        XCTAssertTrue(adoption.isNew)
        XCTAssertEqual(manager.servers, [adoption.server], "saved once")
        XCTAssertEqual(manager.activeServer?.id, adoption.server.id, "the saved record is the active server")
        XCTAssertEqual(adoption.server.secureAPIPort, 8443, "the Marti API port the link gave is saved with it")

        waitUntilUp(adoption.server.id)
        // A second dial would have reached the server by now: the older
        // TAKService.connect() made one right after the first (#156).
        observe(for: 0.5)
        XCTAssertEqual(tak.acceptedCount, 1)
        XCTAssertEqual(tak.closedByClientCount, 0)
    }

    @MainActor
    func testANewServerWithNoAPIPortIsSavedWithoutOne() {
        let adoption = manager.adoptEnrolledServer(enrolled(), apiPort: nil)
        XCTAssertNil(manager.servers.first?.secureAPIPort)
        waitUntilUp(adoption.server.id)
    }

    @MainActor
    func testANewServerBecomesTheActiveOneEvenWhenAnotherSwitchedOnServerIsActive() throws {
        let other = LoopbackTAKServer()
        try other.start()
        defer { other.stop() }
        let existing = TAKServer(name: "Other", host: "127.0.0.1", port: other.port, protocolType: "tcp", useTLS: false)
        manager.addServer(existing)    // switched on, so it is dialed, and active because nothing else was
        XCTAssertEqual(manager.activeServer?.id, existing.id)

        let adoption = manager.adoptEnrolledServer(enrolled())

        XCTAssertEqual(manager.activeServer?.id, adoption.server.id, "the server just enrolled is the active one")
        XCTAssertEqual(manager.servers.count, 2)
        waitUntilUp(adoption.server.id)
        waitUntilUp(existing.id, "the other server's link to stay up")
        waitUntil("both servers to have accepted their link") { tak.acceptedCount == 1 && other.acceptedCount == 1 }
        observe(for: 0.3)
        XCTAssertEqual(tak.acceptedCount, 1)
        XCTAssertEqual(other.acceptedCount, 1)
    }

    // MARK: - Enrolling again for a saved endpoint

    @MainActor
    func testEnrollingAgainDialsTheSavedRecordAgainOnce() {
        let first = manager.adoptEnrolledServer(enrolled())
        waitUntilUp(first.server.id)
        waitUntil("the server to have accepted the first link") { tak.acceptedCount == 1 }

        // A new enrollment: a new record id, and a certificate under another name.
        let second = manager.adoptEnrolledServer(enrolled(certificate: "omnitak-cert-renewed"), apiPort: 9443)

        XCTAssertFalse(second.isNew)
        XCTAssertEqual(second.server.id, first.server.id, "the saved record, not the one the enrollment built")
        XCTAssertEqual(manager.servers.count, 1, "no second entry for the same server")
        XCTAssertEqual(manager.servers.first?.certificateName, "omnitak-cert-renewed")
        XCTAssertEqual(manager.servers.first?.caCertificateName, "omnitak-cert-renewed-ca")
        XCTAssertEqual(manager.servers.first?.secureAPIPort, 9443)
        XCTAssertEqual(manager.activeServer?.id, first.server.id, "active points at the saved record")
        XCTAssertEqual(manager.activeServer?.certificateName, "omnitak-cert-renewed", "and at its new state")

        // The link made with the old certificate is let go, and one new link comes up.
        waitUntil("the app to close the link made with the old certificate") { tak.closedByClient(connection: 0) }
        waitUntil("the new link") { tak.acceptedCount == 2 && service.isConnectedTo(serverId: first.server.id) }
        observe(for: 0.5)
        XCTAssertEqual(tak.acceptedCount, 2, "one new connection, not two")
        XCTAssertFalse(tak.closedByClient(connection: 1), "the new link stays up")
        XCTAssertEqual(liveConnections, 1)
    }

    @MainActor
    func testEnrollingAgainRightAfterTheFirstEnrollmentLeavesOneLink() {
        // The second enrollment arrives while the first dial is still in flight.
        let first = manager.adoptEnrolledServer(enrolled())
        manager.adoptEnrolledServer(enrolled(certificate: "omnitak-cert-renewed"))

        waitUntilUp(first.server.id)
        observe(for: 0.5)
        waitUntil("every link but the last to be closed") { liveConnections == 1 }
        XCTAssertEqual(manager.servers.count, 1)
        XCTAssertTrue(service.isConnectedTo(serverId: first.server.id))
    }

    @MainActor
    func testEnrollingAgainKeepsTheNameAndWhatTheOperatorSet() {
        var mine = enrolled()
        mine.name = "Ops Center"
        mine.isDefault = true
        mine.allowUntrustedTLS = true
        mine.username = "operator"
        mine.enrollmentPort = 9446
        mine.secureAPIPort = 9443
        manager.addServer(mine)
        waitUntilUp(mine.id)

        let adoption = manager.adoptEnrolledServer(enrolled(certificate: "omnitak-cert-renewed"), apiPort: nil)
        let saved = manager.servers[0]

        XCTAssertEqual(adoption.server, saved, "what comes back is what is saved")
        XCTAssertEqual(saved.id, mine.id)
        XCTAssertEqual(saved.name, "Ops Center")
        XCTAssertTrue(saved.isDefault)
        XCTAssertTrue(saved.allowUntrustedTLS)
        XCTAssertEqual(saved.username, "operator")
        XCTAssertEqual(saved.enrollmentPort, 9446)
        XCTAssertEqual(saved.secureAPIPort, 9443, "no API port was given, so the saved one stays")
        XCTAssertEqual(saved.certificateName, "omnitak-cert-renewed")
        XCTAssertTrue(saved.enabled)
        waitUntilUp(mine.id)
    }

    @MainActor
    func testEnrollingAgainSwitchesASwitchedOffRecordOnAndDialsItOnce() {
        var off = enrolled()
        off.enabled = false
        manager.addServer(off)
        XCTAssertEqual(tak.acceptedCount, 0)
        XCTAssertNil(service.connectionPhase(of: off.id), "a switched-off server has no link")

        let adoption = manager.adoptEnrolledServer(enrolled(certificate: "omnitak-cert-renewed"))

        XCTAssertFalse(adoption.isNew)
        XCTAssertEqual(adoption.server.id, off.id)
        XCTAssertTrue(adoption.server.enabled, "the operator has just asked for this server")
        XCTAssertEqual(manager.servers.first?.enabled, true, "and it is saved switched on")
        XCTAssertEqual(manager.activeServer?.id, off.id)
        XCTAssertEqual(manager.activeServer?.enabled, true)

        waitUntilUp(off.id)
        observe(for: 0.5)
        XCTAssertEqual(tak.acceptedCount, 1)
    }

    @MainActor
    func testEnrollingAgainWhileTheLinkWaitsForItsNextDialDialsOnceAndCancelsTheWait() throws {
        // The server drops every connection, so the link ends up waiting for a scheduled dial.
        // The dials are not about the connect timeout, so it is short here (as in TAKServiceDialTests).
        tak.closeNewConnectionsAtOnce = true
        service.connectTimeout = 2
        let first = manager.adoptEnrolledServer(enrolled())
        waitUntil(20, "the link to be waiting for its third dial") {
            tak.acceptedCount >= 2 && service.connectionPhase(of: first.server.id) == .waiting
        }
        let scheduled = try XCTUnwrap(service.scheduledDial(of: first.server.id))
        let acceptedBefore = tak.acceptedCount

        // The server takes connections again, and the operator enrolls again.
        tak.closeNewConnectionsAtOnce = false
        let second = manager.adoptEnrolledServer(enrolled(certificate: "omnitak-cert-renewed"))

        XCTAssertFalse(second.isNew)
        XCTAssertTrue(scheduled.isCancelled, "the dial that was scheduled is cancelled, not left to dial a second time")
        waitUntilUp(first.server.id)
        observe(for: 0.5)
        XCTAssertEqual(tak.acceptedCount, acceptedBefore + 1, "one dial, made now")
        XCTAssertNil(service.scheduledDial(of: first.server.id))
    }

    func testAnEditedServerIsNotAddedASecondTimeByAnImportEither() {
        // addServer and the enrollment share one idea of "the same endpoint".
        var edited = TAKServer(name: "Edited", host: "tak.example.com", port: 8089, protocolType: "tls", useTLS: true, enabled: false)
        edited.certificateName = "imported-client"
        manager.addServer(edited)

        let again = TAKServer(name: "TAK Server (tak.example.com)", host: "tak.example.com", port: 8089,
                              protocolType: "ssl", useTLS: true, enabled: false)
        let kept = manager.addServer(again)

        XCTAssertEqual(kept.id, edited.id)
        XCTAssertEqual(manager.servers.count, 1)
    }

    @MainActor
    func testTheSavedListHoldsTheEnrollmentAfterARestart() {
        let first = manager.adoptEnrolledServer(enrolled())
        waitUntilUp(first.server.id)
        manager.adoptEnrolledServer(enrolled(certificate: "omnitak-cert-renewed"), apiPort: 9443)

        // A manager that reads the same suite, as the app does when it starts again.
        let restarted = ServerManager(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(restarted.servers.count, 1)
        XCTAssertEqual(restarted.servers.first?.id, first.server.id)
        XCTAssertEqual(restarted.servers.first?.certificateName, "omnitak-cert-renewed")
        XCTAssertEqual(restarted.servers.first?.secureAPIPort, 9443)
        XCTAssertEqual(restarted.activeServer?.id, first.server.id)
    }
}

// MARK: - The call sites

/// The enrollment paths must not dial the older single connection (`TAKService.connect(host:...)`)
/// after enrolling: `adoptEnrolledServer` has already left the one link there is to dial (#156). The
/// loopback tests above cannot see a call site, because those sites need a TAK server to run, so this
/// reads the three files that make up the enrollment paths. It skips where the source is not on
/// disk (a test run on a device).
final class EnrollmentCallSiteTests: XCTestCase {

    func testNoEnrollmentPathDialsTheOlderSingleConnection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sites = [
            "OmniTAKMobile/Features/Networking/Services/DeepLinkHandler.swift",
            "OmniTAKMobile/Features/Networking/Views/SimpleEnrollView.swift",
            "OmniTAKMobile/Features/Networking/Services/CSREnrollmentService.swift",
        ]
        let legacyDial = try NSRegularExpression(pattern: #"\.connect\(\s*host\s*:"#)
        for site in sites {
            let url = root.appendingPathComponent(site)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw XCTSkip("the source is not on disk here: \(url.path)")
            }
            let found = legacyDial.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source))
            XCTAssertEqual(found, 0, "\(site) dials the older single connection after enrolling (#156)")
        }
    }
}
