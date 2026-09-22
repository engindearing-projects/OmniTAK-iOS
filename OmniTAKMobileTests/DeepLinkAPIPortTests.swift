//
//  DeepLinkAPIPortTests.swift
//  OmniTAKMobileTests
//
//  #126 — the Marti/Mission REST port is part of setup. Both enrollment deep
//  links (ATAK-standard token QR and the OmniTAK password QR) accept an
//  &apiport= (alias &martiport=) override next to &enrollmentport=.
//

import XCTest
@testable import OmniTAK

final class DeepLinkAPIPortTests: XCTestCase {

    func testTokenEnrollmentLinkParsesAPIPort() throws {
        let url = try XCTUnwrap(URL(string: "tak://com.atakmap.app/enroll?host=ots.example&username=u&token=t&apiport=9443"))
        let link = try XCTUnwrap(EnrollmentDeepLink.parse(url: url))
        XCTAssertEqual(link.apiPort, 9443)
        XCTAssertNil(link.enrollmentPort, "apiport must not be mistaken for the enrollment port")
    }

    func testTokenEnrollmentLinkAPIPortIsOptional() throws {
        let url = try XCTUnwrap(URL(string: "tak://com.atakmap.app/enroll?host=ots.example&username=u&token=t"))
        let link = try XCTUnwrap(EnrollmentDeepLink.parse(url: url))
        XCTAssertNil(link.apiPort)
    }

    func testPasswordEnrollmentLinkAcceptsMartiPortAlias() throws {
        let url = try XCTUnwrap(URL(string: "tak://enroll?host=ots.example&username=u&password=p&martiport=9443&enrollmentport=8446"))
        let link = try XCTUnwrap(PasswordEnrollmentDeepLink.parse(url: url))
        XCTAssertEqual(link.apiPort, 9443)
        XCTAssertEqual(link.enrollmentPort, 8446)
    }

    func testNonNumericAPIPortIsIgnored() throws {
        let url = try XCTUnwrap(URL(string: "tak://enroll?host=ots.example&username=u&password=p&apiport=abc"))
        let link = try XCTUnwrap(PasswordEnrollmentDeepLink.parse(url: url))
        XCTAssertNil(link.apiPort)
    }
}
