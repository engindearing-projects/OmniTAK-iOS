//
//  QuickMarkServiceTests.swift
//  OmniTAKMobileTests
//
//  Locks down the UTC HHmm callsign formatter for the iOS Mark-My-
//  Position FAB so iOS + Android paired in the same minute produce the
//  same `MyPos-HHMM` label.
//

import XCTest
import CoreLocation
@testable import OmniTAKMobile

final class QuickMarkServiceTests: XCTestCase {

    func test_timestampedCallsign_formats_utc_hhmm() {
        // 2026-05-11 14:37:00 UTC
        let date = Date(timeIntervalSince1970: 1_778_336_220)
        XCTAssertEqual(QuickMarkService.timestampedCallsign(now: date), "MyPos-1437")
    }

    func test_timestampedCallsign_zero_pads_morning_hours() {
        // 2026-05-11 05:04:00 UTC
        let date = Date(timeIntervalSince1970: 1_778_302_440)
        XCTAssertEqual(QuickMarkService.timestampedCallsign(now: date), "MyPos-0504")
    }

    func test_timestampedCallsign_independent_of_local_timezone() {
        // 2026-05-11 23:59:00 UTC — regardless of the device locale or
        // tz, the callsign reports the UTC HHmm because that's what the
        // Android counterpart emits.
        let date = Date(timeIntervalSince1970: 1_778_370_540)
        XCTAssertEqual(QuickMarkService.timestampedCallsign(now: date), "MyPos-2359")
    }
}
