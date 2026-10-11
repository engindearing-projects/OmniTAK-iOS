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

    // MARK: - The port a saved server record stores (#156)

    func testTheAPIPortOfALinkIsWhatTheServerRecordStores() throws {
        let token = try XCTUnwrap(EnrollmentDeepLink.parse(url: XCTUnwrap(URL(string:
            "tak://com.atakmap.app/enroll?host=ots.example&username=u&token=t&apiport=9443"))))
        XCTAssertEqual(token.secureAPIPort, 9443)

        let password = try XCTUnwrap(PasswordEnrollmentDeepLink.parse(url: XCTUnwrap(URL(string:
            "tak://enroll?host=ots.example&username=u&password=p&apiport=8443"))))
        XCTAssertEqual(password.secureAPIPort, 8443)
    }

    func testALinkWithNoAPIPortGivesNone() throws {
        let token = try XCTUnwrap(EnrollmentDeepLink.parse(url: XCTUnwrap(URL(string:
            "tak://com.atakmap.app/enroll?host=ots.example&username=u&token=t"))))
        XCTAssertNil(token.secureAPIPort, "no port given: a saved server keeps the one it has")

        let password = try XCTUnwrap(PasswordEnrollmentDeepLink.parse(url: XCTUnwrap(URL(string:
            "tak://enroll?host=ots.example&username=u&password=p"))))
        XCTAssertNil(password.secureAPIPort)
    }

    func testAnAPIPortThatIsNotAPortIsIgnoredNotTrapped() throws {
        // UInt16(70000) traps. The enrollment had already succeeded when that ran.
        for value in ["70000", "65536", "-1"] {
            let token = try XCTUnwrap(EnrollmentDeepLink.parse(url: XCTUnwrap(URL(string:
                "tak://com.atakmap.app/enroll?host=ots.example&username=u&token=t&apiport=\(value)"))))
            XCTAssertNotNil(token.apiPort, "the number is parsed: \(value)")
            XCTAssertNil(token.secureAPIPort, "but it is not a port: \(value)")

            let password = try XCTUnwrap(PasswordEnrollmentDeepLink.parse(url: XCTUnwrap(URL(string:
                "tak://enroll?host=ots.example&username=u&password=p&apiport=\(value)"))))
            XCTAssertNil(password.secureAPIPort, "\(value)")
        }
        let top = try XCTUnwrap(PasswordEnrollmentDeepLink.parse(url: XCTUnwrap(URL(string:
            "tak://enroll?host=ots.example&username=u&password=p&apiport=65535"))))
        XCTAssertEqual(top.secureAPIPort, 65535)
    }
}
