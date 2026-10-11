//
//  SelfMarkerVisibilityTests.swift
//  OmniTAKMobileTests
//
//  Issue #134: hide my own marker on the map. UI only.
//
//  Covers:
//    - the 2D rule: the Mapbox puck is installed only when location display is
//      on AND the marker is visible (SelfMarkerVisibility.showsPuck and
//      TacticalMapView.puckType, which makeUIView/updateUIView both use)
//    - the 3D rule: CesiumMainMap leaves the `__self__` entity out of the list
//      it sends to the globe when hidden, and keeps every other entity
//    - profiles: ConfigProfile carries selfMarkerVisible through JSON and the
//      QR codec, a profile saved before the key existed still decodes, and
//      ProfileStore snapshots / applies the key
//
//  Pure logic: no map view, no network.
//

import XCTest
import CoreLocation
import MapboxMaps
@testable import OmniTAK

final class SelfMarkerVisibilityTests: XCTestCase {

    // MARK: - Stored preference

    func testPreferenceKeyAndDefault() {
        // The key is persisted, shared by SettingsView / MapViewController and
        // carried by profiles; the default must keep the marker on.
        XCTAssertEqual(SelfMarkerVisibility.defaultsKey, "selfMarkerVisible")
        XCTAssertTrue(SelfMarkerVisibility.defaultVisible)
    }

    // MARK: - 2D puck rule

    func testPuckShownOnlyWhenLocationIsOnAndMarkerIsVisible() {
        XCTAssertTrue(SelfMarkerVisibility.showsPuck(showsUserLocation: true, selfMarkerVisible: true))
        XCTAssertFalse(SelfMarkerVisibility.showsPuck(showsUserLocation: true, selfMarkerVisible: false))
        XCTAssertFalse(SelfMarkerVisibility.showsPuck(showsUserLocation: false, selfMarkerVisible: true))
        XCTAssertFalse(SelfMarkerVisibility.showsPuck(showsUserLocation: false, selfMarkerVisible: false))
    }

    func testHiddenMarkerInstallsNoPuck() {
        // nil puck type = Mapbox draws nothing, accuracy ring included.
        XCTAssertNil(TacticalMapView.puckType(showsUserLocation: true, selfMarkerVisible: false))
    }

    func testVisibleMarkerInstallsTheStyledPuck() {
        guard case .puck2D? = TacticalMapView.puckType(showsUserLocation: true, selfMarkerVisible: true) else {
            return XCTFail("a visible marker should install the 2D self puck")
        }
    }

    func testLocationDisplayOffStillInstallsNoPuck() {
        // Existing behaviour, kept: showsUserLocation == false means no puck
        // whatever the marker preference says.
        XCTAssertNil(TacticalMapView.puckType(showsUserLocation: false, selfMarkerVisible: true))
    }

    // MARK: - 3D globe: the `__self__` entity

    private func globe(selfMarkerVisible: Bool,
                       hasFix: Bool = true,
                       contacts: [CoTMarker] = []) -> CesiumMainMap {
        CesiumMainMap(
            contacts: contacts,
            aircraft: [],
            lineDrawings: [],
            circleDrawings: [],
            polygonDrawings: [],
            markerDrawings: [],
            rangeRings: [],
            pointMarkers: [],
            selfLocation: hasFix ? CLLocation(latitude: 47.6588, longitude: -117.4260) : nil,
            selfCallsign: "ALPHA-1",
            selfMarkerVisible: selfMarkerVisible,
            measurements: [],
            breadcrumbTrailCoords: [],
            breadcrumbTrailColor: "#00FF00"
        )
    }

    private func uids(in entityJSON: String, file: StaticString = #filePath, line: UInt = #line) -> [String] {
        guard let data = entityJSON.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("entity JSON did not parse: \(entityJSON)", file: file, line: line)
            return []
        }
        return list.compactMap { $0["uid"] as? String }
    }

    private func contact(uid: String = "uid-bravo") -> CoTMarker {
        CoTMarker(
            uid: uid,
            coordinate: CLLocationCoordinate2D(latitude: 47.66, longitude: -117.43),
            type: "a-f-G-U-C",
            callsign: "BRAVO-2",
            team: "Cyan"
        )
    }

    func testGlobeSendsTheSelfEntityWhenTheMarkerIsVisible() {
        let ids = uids(in: globe(selfMarkerVisible: true).buildEntityJSON())
        XCTAssertEqual(ids, ["__self__"])
    }

    func testGlobeLeavesTheSelfEntityOutWhenTheMarkerIsHidden() {
        // setEntities drops any uid missing from the list, so leaving it out
        // is what removes a pip that is already on the globe.
        let ids = uids(in: globe(selfMarkerVisible: false).buildEntityJSON())
        XCTAssertFalse(ids.contains("__self__"))
    }

    func testGlobeKeepsOtherEntitiesWhenTheSelfMarkerIsHidden() {
        let ids = uids(in: globe(selfMarkerVisible: false, contacts: [contact()]).buildEntityJSON())
        XCTAssertEqual(ids, ["uid-bravo"])
    }

    func testGlobeSelfEntityComesBackWhenShownAgain() {
        let hidden = uids(in: globe(selfMarkerVisible: false, contacts: [contact()]).buildEntityJSON())
        let shown = uids(in: globe(selfMarkerVisible: true, contacts: [contact()]).buildEntityJSON())
        XCTAssertFalse(hidden.contains("__self__"))
        XCTAssertEqual(Set(shown), ["__self__", "uid-bravo"])
    }

    func testGlobeHasNoSelfEntityWithoutAFixWhateverThePreference() {
        XCTAssertTrue(uids(in: globe(selfMarkerVisible: true, hasFix: false).buildEntityJSON()).isEmpty)
        XCTAssertTrue(uids(in: globe(selfMarkerVisible: false, hasFix: false).buildEntityJSON()).isEmpty)
    }

    // MARK: - Profiles

    func testProfileRoundTripKeepsSelfMarkerVisible() throws {
        for visible in [true, false] {
            let original = ConfigProfile(name: "Marker \(visible)", selfMarkerStyle: "arrow", selfMarkerVisible: visible)
            let decoded = try JSONDecoder().decode(ConfigProfile.self, from: JSONEncoder().encode(original))
            XCTAssertEqual(decoded.selfMarkerVisible, visible)
            XCTAssertEqual(decoded.selfMarkerStyle, "arrow", "the style rides along unchanged")
        }
    }

    func testProfileWithoutTheKeyLeavesItNil() throws {
        // A profile that never set it does not write the key at all, so QR
        // payloads for existing profiles do not grow.
        let data = try JSONEncoder().encode(ConfigProfile(name: "Plain", selfMarkerStyle: "milstd"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("selfMarkerVisible"))
        XCTAssertNil(try JSONDecoder().decode(ConfigProfile.self, from: data).selfMarkerVisible)
    }

    func testProfileSavedBeforeTheKeyExistedStillDecodes() throws {
        // What an older build wrote: the same payload with no selfMarkerVisible.
        let data = try JSONEncoder().encode(
            ConfigProfile(name: "Old", selfMarkerStyle: "bullseye", selfMarkerVisible: false))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "selfMarkerVisible"))

        let old = try JSONDecoder().decode(
            ConfigProfile.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.name, "Old")
        XCTAssertEqual(old.selfMarkerStyle, "bullseye")
        XCTAssertNil(old.selfMarkerVisible)
    }

    func testProfileQRCodecCarriesSelfMarkerVisible() throws {
        let profile = ConfigProfile(name: "Quiet team", selfMarkerVisible: false)
        let decoded = try ProfileQRCodec.decode(urlString: try ProfileQRCodec.encode(profile))
        XCTAssertEqual(decoded.selfMarkerVisible, false)
    }

    // The two ProfileStore tests write the real preference, so they put back
    // whatever was there (the test host is the app itself).
    private func restoreSelfMarkerPreferenceAfterTest() {
        let ud = UserDefaults.standard
        let key = SelfMarkerVisibility.defaultsKey
        let original = ud.object(forKey: key)
        addTeardownBlock {
            if let original { ud.set(original, forKey: key) } else { ud.removeObject(forKey: key) }
        }
    }

    func testApplyingAProfileWritesThePreference() {
        restoreSelfMarkerPreferenceAfterTest()
        let ud = UserDefaults.standard
        let key = SelfMarkerVisibility.defaultsKey
        let store = ProfileStore()

        store.apply(ConfigProfile(name: "Hide", selfMarkerVisible: false))
        XCTAssertEqual(ud.object(forKey: key) as? Bool, false)

        store.apply(ConfigProfile(name: "Show", selfMarkerVisible: true))
        XCTAssertEqual(ud.object(forKey: key) as? Bool, true)

        // A profile that does not carry the key leaves the operator's choice alone.
        ud.set(false, forKey: key)
        store.apply(ConfigProfile(name: "Silent"))
        XCTAssertEqual(ud.object(forKey: key) as? Bool, false)
    }

    func testSnapshotCarriesThePreferenceOnlyWhenItWasSet() {
        restoreSelfMarkerPreferenceAfterTest()
        let ud = UserDefaults.standard
        let key = SelfMarkerVisibility.defaultsKey
        let store = ProfileStore()

        ud.removeObject(forKey: key)
        XCTAssertNil(store.snapshotCurrent(name: "Unset").selfMarkerVisible)

        ud.set(false, forKey: key)
        XCTAssertEqual(store.snapshotCurrent(name: "Hidden").selfMarkerVisible, false)

        ud.set(true, forKey: key)
        XCTAssertEqual(store.snapshotCurrent(name: "Shown").selfMarkerVisible, true)
    }
}
