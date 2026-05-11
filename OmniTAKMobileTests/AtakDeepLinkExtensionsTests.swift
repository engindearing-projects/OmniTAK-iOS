//
//  AtakDeepLinkExtensionsTests.swift
//  OmniTAKMobileTests
//
//  Locks down `tak://com.atakmap.app/import?url=…` and
//  `tak://com.atakmap.app/preference?keyN=…&typeN=…&valueN=…` parity
//  with the Android AtakUriParser. iOS already handles /enroll +
//  connect — these tests are the new-verb receipts.
//

import XCTest
@testable import OmniTAKMobile

final class AtakDeepLinkExtensionsTests: XCTestCase {

    // MARK: - /import

    func test_import_subpath_yields_importPackage_action() throws {
        let url = URL(string: "tak://com.atakmap.app/import?url=https%3A%2F%2Fdownload.osgeo.org%2Fgeotiff%2Fsamples%2Fmisc%2Ftjpeg.tif")!
        let action = AtakDeepLinkAction.parse(url: url)
        guard case .importPackage(let resolved) = action else {
            return XCTFail("expected .importPackage, got \(String(describing: action))")
        }
        XCTAssertEqual(resolved.absoluteString,
                       "https://download.osgeo.org/geotiff/samples/misc/tjpeg.tif")
    }

    func test_import_rejects_file_scheme_for_exfiltration_safety() {
        let url = URL(string: "tak://com.atakmap.app/import?url=file:///etc/passwd")!
        XCTAssertEqual(AtakDeepLinkAction.parse(url: url), .unknown)
    }

    func test_import_missing_url_yields_unknown() {
        let url = URL(string: "tak://com.atakmap.app/import")!
        XCTAssertEqual(AtakDeepLinkAction.parse(url: url), .unknown)
    }

    // MARK: - /preference

    func test_preference_indexed_groups_resolve_to_appstorage_keys() {
        let url = URL(string:
            "tak://com.atakmap.app/preference?" +
            "key1=callsign&type1=string&value1=ENGIE-1&" +
            "key2=mgrsGridEnabled&type2=boolean&value2=true"
        )!
        guard case .setPreferences(let resolved) = AtakDeepLinkAction.parse(url: url) else {
            return XCTFail("expected .setPreferences, got something else")
        }
        XCTAssertEqual(resolved["userCallsign"], "ENGIE-1")
        XCTAssertEqual(resolved["mgrsGridEnabled"], "true")
    }

    func test_preference_stops_walking_at_first_missing_index() {
        // Skip index 2 — applier must stop, not honour index 3.
        let url = URL(string:
            "tak://com.atakmap.app/preference?" +
            "key1=callsign&type1=string&value1=ENGIE-1&" +
            "key3=unitSystem&type3=string&value3=Metric"
        )!
        guard case .setPreferences(let resolved) = AtakDeepLinkAction.parse(url: url) else {
            return XCTFail("expected .setPreferences")
        }
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved["userCallsign"], "ENGIE-1")
    }

    func test_preference_atak_aliases_route_to_omnitak_appstorage() {
        let url = URL(string:
            "tak://com.atakmap.app/preference?" +
            "key1=locationCallsign&type1=string&value1=ATAK-7&" +
            "key2=coord_display_format&type2=string&value2=MGRS"
        )!
        guard case .setPreferences(let resolved) = AtakDeepLinkAction.parse(url: url) else {
            return XCTFail("expected .setPreferences")
        }
        XCTAssertEqual(resolved["userCallsign"], "ATAK-7")
        XCTAssertEqual(resolved["coordinateDisplayFormat"], "MGRS")
    }

    func test_preference_unknown_keys_are_dropped() {
        let url = URL(string:
            "tak://com.atakmap.app/preference?key1=displayRed&type1=boolean&value1=true"
        )!
        guard case .setPreferences(let resolved) = AtakDeepLinkAction.parse(url: url) else {
            return XCTFail("expected .setPreferences with empty resolved map")
        }
        XCTAssertTrue(resolved.isEmpty,
                      "ATAK-only keys must be ignored, got: \(resolved)")
    }

    // MARK: - routing

    func test_non_target_paths_fall_through_to_legacy_parser() {
        // `/enroll` is handled by the existing DeepLinkHandler / EnrollmentDeepLink.
        // AtakDeepLinkAction.parse returns nil for those so handleURL can fall through.
        let url = URL(string:
            "tak://com.atakmap.app/enroll?host=takserver.com&username=foo&token=t"
        )!
        XCTAssertNil(AtakDeepLinkAction.parse(url: url))
    }

    func test_partition_reports_applied_and_ignored_keys() {
        let entries = [
            PreferenceEntry(key: "callsign", type: "string", value: "ENGIE-1"),
            PreferenceEntry(key: "displayRed", type: "boolean", value: "true"),
        ]
        let result = PreferenceApplier.partition(entries)
        XCTAssertEqual(result.applied, ["callsign"])
        XCTAssertEqual(result.ignored, ["displayRed"])
    }
}
