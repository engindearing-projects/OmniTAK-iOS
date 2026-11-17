//
//  FirstFixCameraTests.swift
//  OmniTAKMobileTests
//
//  A new install opened the 3D globe over New York and the 2D map over Washington although the
//  phone knew where it was a second later; and after 3D, 2D, 3D the globe opened over New York
//  again. These pin the rules that fix both: when the first fix moves the camera, what the globe
//  opens on, and what the two engines hand each other.
//

import XCTest
import MapKit
import CoreLocation
import JavaScriptCore
import MapboxMaps
@testable import OmniTAK

final class FirstFixCameraTests: XCTestCase {

    private let spokane = CLLocationCoordinate2D(latitude: 47.6588, longitude: -117.4260)
    private static let spokanePose = SavedGlobePose(latitude: 47.6588, longitude: -117.426, height: 3_000,
                                                     heading: 0, pitch: -60)

    // MARK: - Whether the first fix moves the camera

    func testTheFirstFixMovesTheCameraOnlyWhenNothingStandsInTheWay() {
        // all sixteen rows: it moves for exactly one of them
        for saved in [false, true] {
            for moved in [false, true] {
                for already in [false, true] {
                    for usable in [false, true] {
                        let expected = !saved && !moved && !already && usable
                        XCTAssertEqual(
                            FirstFixCamera.shouldMove(hasSavedCamera: saved, userMovedMap: moved,
                                                      alreadyMoved: already, fixIsUsable: usable),
                            expected,
                            "saved \(saved), moved \(moved), already \(already), usable \(usable)")
                    }
                }
            }
        }
    }

    // MARK: - Which fixes count

    func testAFixIsUsableWhenItIsRealAndRecent() {
        XCTAssertTrue(FirstFixCamera.isUsable(latitude: 47.6588, longitude: -117.4260, horizontalAccuracy: 5, age: 2))
        XCTAssertTrue(FirstFixCamera.isUsable(latitude: 47.6588, longitude: -117.4260, horizontalAccuracy: 1_400, age: 59))
        XCTAssertTrue(FirstFixCamera.isUsable(latitude: -33.9, longitude: 151.2, horizontalAccuracy: 20, age: -1),
                      "a timestamp a second ahead of this clock is still now")
    }

    func testACachedFixFromMinutesAgoIsNotTheOperatorsPosition() {
        XCTAssertFalse(FirstFixCamera.isUsable(latitude: 47.6588, longitude: -117.4260, horizontalAccuracy: 5, age: 61))
        XCTAssertFalse(FirstFixCamera.isUsable(latitude: 47.6588, longitude: -117.4260, horizontalAccuracy: 5, age: 3_600))
    }

    func testAFixWithNoAccuracyOrNoRealCoordinateIsNotUsable() {
        // a negative accuracy is how CoreLocation says "invalid"
        XCTAssertFalse(FirstFixCamera.isUsable(latitude: 47.6588, longitude: -117.4260, horizontalAccuracy: -1, age: 1))
        XCTAssertFalse(FirstFixCamera.isUsable(latitude: .nan, longitude: -117.4260, horizontalAccuracy: 5, age: 1))
        XCTAssertFalse(FirstFixCamera.isUsable(latitude: 91, longitude: 0, horizontalAccuracy: 5, age: 1))
        XCTAssertFalse(FirstFixCamera.isUsable(latitude: 0, longitude: 181, horizontalAccuracy: 5, age: 1))
        XCTAssertFalse(FirstFixCamera.isUsable(latitude: 0, longitude: 0, horizontalAccuracy: 5, age: 1),
                       "null island is what an unset position looks like")
    }

    func testALocationObjectIsJudgedByItsOwnTimestamp() {
        let now = Date()
        let fresh = CLLocation(coordinate: spokane, altitude: 550, horizontalAccuracy: 5, verticalAccuracy: 5,
                               timestamp: now.addingTimeInterval(-3))
        let old = CLLocation(coordinate: spokane, altitude: 550, horizontalAccuracy: 5, verticalAccuracy: 5,
                             timestamp: now.addingTimeInterval(-300))
        XCTAssertTrue(FirstFixCamera.isUsable(fresh, now: now))
        XCTAssertFalse(FirstFixCamera.isUsable(old, now: now))
    }

    // MARK: - The scale it moves to

    func testTheMapOpensOnTheOperatorAtAStreetScale() {
        let region = FirstFixCamera.mapRegion(centre: spokane)
        XCTAssertEqual(region.center.latitude, spokane.latitude, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, spokane.longitude, accuracy: 1e-9)
        XCTAssertEqual(TacticalMapView.zoom(forSpan: region.span, mapHeight: 800), 14, accuracy: 1e-6)
    }

    // MARK: - What has happened in this run

    func testAFreshInstallMovesOnTheFirstUsableFixAndNeverAgain() {
        let state = FirstFixState(savedGlobePose: nil)
        XCTAssertTrue(state.claimMove(engineIsGlobe: true, fixIsUsable: true))
        XCTAssertFalse(state.claimMove(engineIsGlobe: true, fixIsUsable: true), "once per run")
        XCTAssertFalse(state.claimMove(engineIsGlobe: false, fixIsUsable: true), "on either engine")
    }

    func testAnUnusableFixDoesNotUseUpTheMove() {
        // the phone's cached fix from minutes ago arrives first, then the real one
        let state = FirstFixState(savedGlobePose: nil)
        XCTAssertFalse(state.claimMove(engineIsGlobe: true, fixIsUsable: false))
        XCTAssertTrue(state.claimMove(engineIsGlobe: true, fixIsUsable: true))
    }

    func testAMapTheOperatorHasMovedIsLeftAlone() {
        let state = FirstFixState(savedGlobePose: nil)
        state.operatorMovedMap()
        XCTAssertTrue(state.userMovedMap)
        XCTAssertFalse(state.claimMove(engineIsGlobe: true, fixIsUsable: true))
        XCTAssertFalse(state.claimMove(engineIsGlobe: false, fixIsUsable: true))
    }

    func testAReturningUsersSavedGlobeViewIsNotMoved() {
        let state = FirstFixState(savedGlobePose: Self.spokanePose)
        XCTAssertFalse(state.claimMove(engineIsGlobe: true, fixIsUsable: true))
    }

    func testTheSavedGlobeViewSaysNothingAboutThe2DMap() {
        // the 2D map keeps no camera between launches, so it has nothing to protect
        let state = FirstFixState(savedGlobePose: Self.spokanePose)
        XCTAssertTrue(state.claimMove(engineIsGlobe: false, fixIsUsable: true))
    }

    func testSendingTheMapSomewhereOnPurposeCountsAsMovingIt() {
        for name in [Notification.Name.cesiumCenterOn, .kmlZoomToOverlay] {
            let state = FirstFixState(savedGlobePose: nil)
            XCTAssertFalse(state.userMovedMap)
            NotificationCenter.default.post(name: name, object: nil)
            let moved = expectation(description: "\(name.rawValue) is seen")
            DispatchQueue.main.async { moved.fulfill() }
            wait(for: [moved], timeout: 2)
            XCTAssertTrue(state.userMovedMap, name.rawValue)
            XCTAssertFalse(state.claimMove(engineIsGlobe: true, fixIsUsable: true))
        }
    }

    func testTheSavedViewIsReadOnceAtLaunchAndKeptWhateverTheDefaultsDoLater() {
        // the page's own camera events rewrite the saved one within seconds of launch
        let suite = defaults(["cesium.lastLat": 47.6588, "cesium.lastLon": -117.426, "cesium.lastHeight": 3_000,
                              "cesium.lastHeading": 0, "cesium.lastPitch": -60])
        let state = FirstFixState(defaults: suite)
        XCTAssertEqual(state.launchGlobePose, Self.spokanePose)
        XCTAssertTrue(state.hasSavedGlobeCamera)
        suite.set(0.0, forKey: "cesium.lastLat")
        suite.set(20_000_000.0, forKey: "cesium.lastHeight")
        suite.set(0.0, forKey: "cesium.lastLon")
        XCTAssertEqual(state.launchGlobePose, Self.spokanePose, "the launch snapshot does not follow the defaults")
        XCTAssertNil(SavedGlobePose.load(from: suite), "while a fresh read of them now finds the start pose")
        XCTAssertFalse(FirstFixState(defaults: defaults([:])).hasSavedGlobeCamera)
    }

    // MARK: - What the globe opens on

    func testTheGlobeOpensOnTheOtherEnginesViewThenItsSavedViewThenTheWholeWorld() {
        XCTAssertEqual(GlobeStart.plan(hasSeed: true, hasSavedPose: true), .seed)
        XCTAssertEqual(GlobeStart.plan(hasSeed: true, hasSavedPose: false), .seed)
        XCTAssertEqual(GlobeStart.plan(hasSeed: false, hasSavedPose: true), .savedPose,
                       "the saved view used to lose to the aircraft feed's search centre, which was always set")
        XCTAssertEqual(GlobeStart.plan(hasSeed: false, hasSavedPose: false), .startPose)
    }

    func testAReloadedPageGoesBackToWhereTheCameraLastWasWhateverElseIsKnown() {
        // the web view's process was killed: a seed from the other engine and the view saved at launch are
        // both older than the camera the operator was using
        for seed in [false, true] {
            for saved in [false, true] {
                XCTAssertEqual(GlobeStart.plan(isReload: true, hasSeed: seed, hasSavedPose: saved), .currentPose)
            }
        }
    }

    // MARK: - The saved globe view

    /// A throwaway defaults domain holding `values`, marked as saved by this version unless `marked` is false.
    private func defaults(_ values: [String: Double], marked: Bool = true) -> UserDefaults {
        let name = "FirstFixCameraTests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        addTeardownBlock { suite.removePersistentDomain(forName: name) }
        for (key, value) in values { suite.set(value, forKey: key) }
        if marked && !values.isEmpty { suite.set(SavedGlobePose.version, forKey: SavedGlobePose.versionKey) }
        return suite
    }

    func testNothingSavedIsNoSavedView() {
        XCTAssertNil(SavedGlobePose.load(from: defaults([:])))
        XCTAssertNil(SavedGlobePose.load(from: defaults(["cesium.lastLat": 47.6]))) // half a pose is none
    }

    func testAViewTheOperatorLeftTheGlobeOnIsRestoredExactly() {
        let saved = SavedGlobePose.load(from: defaults([
            "cesium.lastLat": 47.6588, "cesium.lastLon": -117.426, "cesium.lastHeight": 3_000,
            "cesium.lastHeading": 20, "cesium.lastPitch": -45,
        ]))
        XCTAssertEqual(saved, SavedGlobePose(latitude: 47.6588, longitude: -117.426, height: 3_000, heading: 20, pitch: -45))
    }

    func testACameraAnEarlierVersionSavedIsNoSavedView() {
        // Earlier versions saved where their own start-up flight put the camera: New York at 50 km, or the
        // phone's position (or New York again with no fix) at 20 km. None of those is a view anyone chose,
        // so without this version's mark every upgrader would have counted as a returning user and
        // reopened on it, and a phone that never had a fix would reopen over New York for good.
        let spokane = ["cesium.lastLat": 47.6588, "cesium.lastLon": -117.426, "cesium.lastHeight": 20_000,
                       "cesium.lastHeading": 0, "cesium.lastPitch": -60]
        let newYorkAtFiftyKm = ["cesium.lastLat": 40.6413, "cesium.lastLon": -73.7781, "cesium.lastHeight": 50_000,
                                "cesium.lastHeading": 0, "cesium.lastPitch": -60]
        let newYorkAtTwentyKm = ["cesium.lastLat": 40.6413, "cesium.lastLon": -73.7781, "cesium.lastHeight": 20_000,
                                 "cesium.lastHeading": 0, "cesium.lastPitch": -60]
        for saved in [spokane, newYorkAtFiftyKm, newYorkAtTwentyKm] {
            XCTAssertNil(SavedGlobePose.load(from: defaults(saved, marked: false)))
            XCTAssertNotNil(SavedGlobePose.load(from: defaults(saved, marked: true)),
                            "the same camera saved by this version is a view the operator left it on")
        }
    }

    func testTheWholeWorldViewTheGlobeStartsAtNowIsNotASavedViewEither() {
        XCTAssertNil(SavedGlobePose.load(from: defaults([
            "cesium.lastLat": 0, "cesium.lastLon": 0, "cesium.lastHeight": 20_000_000,
            "cesium.lastHeading": 0, "cesium.lastPitch": -90,
        ])))
        // someone who really was looking at New York from 50 km, a little to one side, is not that start
        XCTAssertNotNil(SavedGlobePose.load(from: defaults([
            "cesium.lastLat": 40.70, "cesium.lastLon": -73.9, "cesium.lastHeight": 50_000,
            "cesium.lastHeading": 0, "cesium.lastPitch": -60,
        ])))
    }

    // MARK: - The hand-over between the engines

    func testTheGlobeCameraBecomesA2DViewCentredOnTheGroundUnderTheMiddleOfTheScreen() {
        let region = CesiumCameraMath.region(centre: spokane, cameraHeight: 3_000)
        XCTAssertEqual(region.center.latitude, spokane.latitude, accuracy: 1e-9)
        XCTAssertEqual(region.center.longitude, spokane.longitude, accuracy: 1e-9)
        XCTAssertEqual(region.span.latitudeDelta, 1.15 * 3_000 / 111_320, accuracy: 1e-9)
        // a degree of longitude is shorter away from the equator, so the span is wider in degrees
        XCTAssertEqual(region.span.longitudeDelta, region.span.latitudeDelta / cos(spokane.latitude * .pi / 180),
                       accuracy: 1e-9)
    }

    func testAGlobeViewHandedToThe2DMapAndBackKeepsItsPlaceAndItsScale() {
        // 3D to 2D: the new map's view. 2D to 3D: the globe is seeded from it. Same place, same height.
        for height in [200.0, 3_000, 45_000, 2_000_000] {
            let region = CesiumCameraMath.region(centre: spokane, cameraHeight: height)
            let seeded = CesiumCameraMath.heightForRegion(region)
            XCTAssertEqual(seeded, height, accuracy: height * 1e-6, "height \(height)")
            XCTAssertTrue(CesiumCameraMath.seedJS(for: region, bearing: 0).contains("lat:47.6588"))
        }
    }

    func testTheGlobeIsPutBackOnItsSavedViewExactly() {
        let js = CesiumCameraMath.poseJS(for: SavedGlobePose(latitude: 47.6588, longitude: -117.426, height: 3_000,
                                                               heading: 20, pitch: -45))
        XCTAssertEqual(js, "window.OmniBridge.setCamera({lat:47.6588,lon:-117.426,height:3000.0,heading:20.0,pitch:-45.0});")
    }

    func testTheFirstFixFliesTheGlobeToTheOperatorFromAboutThreeKilometres() {
        let js = CesiumCameraMath.firstFixJS(for: spokane)
        XCTAssertEqual(js, "window.OmniBridge.centerOnSelf({lat:47.6588,lon:-117.426,height:3000.0,heading:0,pitch:-60.0,fly:true});")
    }

    // MARK: - A new user is not shown New York's aircraft

    func testTheAircraftFeedHasNoCentreUntilThePhoneHasAFix() {
        var settings = ADSBTrafficSettings()
        settings.useCurrentLocation = true
        XCTAssertNil(ADSBTrafficService.searchCenter(for: settings, fix: nil), "it used to search around New York")
        let found = ADSBTrafficService.searchCenter(for: settings, fix: spokane)
        XCTAssertEqual(found?.latitude, spokane.latitude)
        XCTAssertEqual(found?.longitude, spokane.longitude)
    }

    func testAFeedSetToATypedPositionNeverUsesTheFix() {
        var settings = ADSBTrafficSettings()
        settings.useCurrentLocation = false
        XCTAssertNil(ADSBTrafficService.searchCenter(for: settings, fix: spokane), "no position typed in yet")
        settings.customLatitude = 51.5
        settings.customLongitude = -0.12
        let typed = ADSBTrafficService.searchCenter(for: settings, fix: spokane)
        XCTAssertEqual(typed?.latitude, 51.5)
        XCTAssertEqual(typed?.longitude, -0.12)
    }

    // MARK: - The 2D map moves to the operator

    func testTheFirstFixMovesThe2DCameraAndKeepsItsTiltAndBearing() {
        let washington = CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365)
        let mapView = MapView(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            mapInitOptions: MapInitOptions(cameraOptions: CameraOptions(center: washington, zoom: 11, bearing: 20, pitch: 45)))
        TacticalMapView.moveCamera(of: mapView, to: spokane, zoom: FirstFixCamera.mapZoom)
        let state = mapView.mapboxMap.cameraState
        XCTAssertEqual(state.center.latitude, spokane.latitude, accuracy: 1e-6)
        XCTAssertEqual(state.center.longitude, spokane.longitude, accuracy: 1e-6)
        XCTAssertEqual(state.zoom, FirstFixCamera.mapZoom, accuracy: 1e-6)
        XCTAssertEqual(state.bearing, 20, accuracy: 1e-6)
        XCTAssertEqual(state.pitch, 45, accuracy: 1e-6)
    }

    // MARK: - The globe page's centring

    func testTheGlobeCentresOnTheOperatorAtTheHeightAskedForWhateverItsTilt() throws {
        // runs the page's own function, cut out of the bundled scene between its two marker comments
        let html = CesiumMainMap.html
        let begin = try XCTUnwrap(html.range(of: "// CENTER-RANGE-BEGIN"), "marker missing from cesium_scene.html")
        let end = try XCTUnwrap(html.range(of: "// CENTER-RANGE-END"), "marker missing from cesium_scene.html")
        let start = try XCTUnwrap(html[begin.upperBound...].firstIndex(of: "\n"))
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(String(html[start..<end.lowerBound]))
        func range(_ range: Double, _ height: Any, _ pitchDegrees: Double) throws -> Double {
            try XCTUnwrap(context.objectForKeyedSubscript("_centerRange")
                .call(withArguments: [range, height, pitchDegrees * .pi / 180])).toDouble()
        }
        // looking straight down the range is the height; at 60 degrees below the horizon it is longer
        XCTAssertEqual(try range(9_999, 3_000, -90), 3_000, accuracy: 1e-6)
        XCTAssertEqual(try range(9_999, 3_000, -60), 3_000 / sin(60 * .pi / 180), accuracy: 1e-6)
        // a flat view is capped at ten times the height
        XCTAssertEqual(try range(9_999, 3_000, -1), 30_000, accuracy: 1e-6)
        // no usable height: the camera keeps the range it had
        XCTAssertEqual(try range(1_234, NSNull(), -60), 1_234)
        XCTAssertEqual(try range(1_234, 0, -60), 1_234)
        XCTAssertEqual(try range(1_234, -5, -60), 1_234)
        XCTAssertEqual(try range(1_234, Double.nan, -60), 1_234)
    }

    // MARK: - The onboarding page that asks

    func testEveryLanguageHasTheLocationPageInItsOwnTable() throws {
        let keys = ["title", "desc", "feature1", "feature2", "feature3"].map { "onboarding.location.\($0)" }
        let english = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        for language in LocalizationManager.Language.allCases {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
                                     "no table for \(language.rawValue)")
            let table = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = table.localizedString(forKey: key, value: "MISSING", table: nil)
                XCTAssertNotEqual(value, "MISSING", "\(key) is missing from \(language.rawValue)")
                XCTAssertFalse(value.isEmpty, "\(key) is empty in \(language.rawValue)")
                if language != .english {
                    XCTAssertNotEqual(value, english.localizedString(forKey: key, value: "", table: nil),
                                      "\(key) in \(language.rawValue) is still the English text")
                }
            }
        }
    }

    func testTheOnboardingAsksForLocationOnTheOneNewPageAndNowhereElse() {
        let pages = OnboardingPage.all
        XCTAssertEqual(pages.filter(\.asksForLocation).count, 1)
        // right after the Welcome page, so the question comes with its explanation
        XCTAssertEqual(pages[0].titleKey, "onboarding.page1.title")
        XCTAssertTrue(pages[1].asksForLocation)
        XCTAssertEqual(pages[1].titleKey, "onboarding.location.title")
    }

    func testAGlobeCameraNearTheGroundStaysAtLeastFiftyMetresWide() {
        let region = CesiumCameraMath.region(centre: spokane, cameraHeight: 5)
        XCTAssertEqual(region.span.latitudeDelta, 50.0 / 111_320, accuracy: 1e-9)
    }

    func testTheWholeEarthIsNotWiderThanTheEarth() {
        let region = CesiumCameraMath.region(centre: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                                             cameraHeight: 20_000_000)
        XCTAssertLessThanOrEqual(region.span.latitudeDelta, 90)
        XCTAssertLessThanOrEqual(region.span.longitudeDelta, 180)
    }
}
