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
import SwiftUI
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

    // MARK: - What the globe writes for the next launch

    func testAViewThatIsSavedIsReadBackExactlyAtTheNextLaunch() {
        // the writer the camera events use and the reader the launch uses, with nothing written by hand between
        let suite = defaults([:])
        Self.spokanePose.save(to: suite)
        XCTAssertEqual(SavedGlobePose.load(from: suite), Self.spokanePose)
        XCTAssertTrue(FirstFixState(defaults: suite).hasSavedGlobeCamera, "a returning user is not flown in again")
    }

    func testASaveAlwaysCarriesThisVersionsMarkSoItCanNeverBeReadAsNoSavedView() {
        // without the mark every launch counts as a first launch: it flies in and no saved view is ever restored
        for stale in [nil, 0, SavedGlobePose.version - 1] as [Int?] {
            let suite = defaults([:])
            if let stale { suite.set(stale, forKey: SavedGlobePose.versionKey) }
            Self.spokanePose.save(to: suite)
            XCTAssertEqual(suite.integer(forKey: SavedGlobePose.versionKey), SavedGlobePose.version,
                           "stale mark \(String(describing: stale))")
            XCTAssertEqual(SavedGlobePose.load(from: suite), Self.spokanePose, "stale mark \(String(describing: stale))")
        }
    }

    func testASaveWritesTheFiveValuesUnderTheKeysTheLaunchReads() {
        let suite = defaults([:])
        SavedGlobePose(latitude: 1, longitude: 2, height: 3, heading: 4, pitch: -5).save(to: suite)
        XCTAssertEqual(suite.double(forKey: "cesium.lastLat"), 1)
        XCTAssertEqual(suite.double(forKey: "cesium.lastLon"), 2)
        XCTAssertEqual(suite.double(forKey: "cesium.lastHeight"), 3)
        XCTAssertEqual(suite.double(forKey: "cesium.lastHeading"), 4)
        XCTAssertEqual(suite.double(forKey: "cesium.lastPitch"), -5)
    }

    func testTheWholeWorldViewTheGlobeStartsAtIsStillNoSavedViewAfterASave() {
        let suite = defaults([:])
        SavedGlobePose(latitude: 0, longitude: 0, height: 20_000_000, heading: 0, pitch: -90).save(to: suite)
        XCTAssertNil(SavedGlobePose.load(from: suite), "a camera nobody chose is saved too, and is still no saved view")
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

    func testTrackingDoesNotStartWhileTheAppIsStillStarting() {
        // started from the plugin's activation in App.init it fetched around the phone's position, which
        // asked the location service before the first frame
        XCTAssertFalse(ADSBTrafficService.mayTrack(isEnabled: true, hasBecomeActive: false))
        XCTAssertTrue(ADSBTrafficService.mayTrack(isEnabled: true, hasBecomeActive: true))
        XCTAssertFalse(ADSBTrafficService.mayTrack(isEnabled: false, hasBecomeActive: true))
        XCTAssertFalse(ADSBTrafficService.mayTrack(isEnabled: false, hasBecomeActive: false))
    }

    // MARK: - The 2D map moves to the operator even while it is still settling

    private func makeTacticalMapView(region: Binding<MKCoordinateRegion>) -> TacticalMapView {
        let store = DrawingStore()
        return TacticalMapView(
            region: region, mapType: .constant(.standard), trackingMode: .constant(.none),
            markers: [], pointMarkers: [], aircraft: [], showsUserLocation: false,
            drawingStore: store, drawingManager: DrawingToolsManager(drawingStore: store),
            radialMenuCoordinator: RadialMenuMapCoordinator(), overlayCoordinator: MapOverlayCoordinator(),
            routeOverlayCoordinator: RouteOverlayCoordinator(), mapStateManager: MapStateManager(),
            measurementManager: MeasurementManager(), drawingMoveSession: DrawingMoveSession(),
            drawingVertexEditSession: DrawingVertexEditSession(), onMapTap: { _ in })
    }

    func testTheFirstFixReachesThe2DMapWhileItIsInteractingAndItsOwnCameraEventsDoNotUndoIt() {
        // With the location already allowed the first fix arrives within a second of launch, while the map is
        // handling its own first camera events (every one of them sets isUserInteracting, for 0.3 s) and its
        // style load re-applies the 60 degree tilt. Writing the region binding alone was skipped then and then
        // written over by the map's camera feedback: the map stayed over Washington.
        let washington = CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365)
        var region = MKCoordinateRegion(center: washington, span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05))
        let view = makeTacticalMapView(region: Binding(get: { region }, set: { region = $0 }))
        let coordinator = view.makeCoordinator()
        let mapView = MapView(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            mapInitOptions: MapInitOptions(cameraOptions: CameraOptions(center: washington, zoom: 11, bearing: 0, pitch: 0)))
        coordinator.mapView = mapView
        coordinator.installMoveCameraObserver(on: mapView)
        coordinator.isUserInteracting = true

        // what MapViewController posts for the first fix: the same function, not a notification made by hand
        FirstFixCamera.postMapMove(to: spokane)
        var state = mapView.mapboxMap.cameraState
        XCTAssertEqual(state.center.latitude, spokane.latitude, accuracy: 1e-6, "moved although the map was interacting")
        XCTAssertEqual(state.center.longitude, spokane.longitude, accuracy: 1e-6)
        XCTAssertEqual(state.zoom, FirstFixCamera.mapZoom, accuracy: 1e-6)
        XCTAssertFalse(coordinator.isProgrammaticUpdate)

        // the style load's tilt, and the map's feedback into the region binding
        mapView.mapboxMap.setCamera(to: CameraOptions(pitch: 60))
        coordinator.handleCameraChanged(mapView: mapView)
        let settled = expectation(description: "the region is written")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        state = mapView.mapboxMap.cameraState
        XCTAssertEqual(state.center.latitude, spokane.latitude, accuracy: 1e-6)
        XCTAssertEqual(state.pitch, 60, accuracy: 1e-6)
        XCTAssertEqual(region.center.latitude, spokane.latitude, accuracy: 1e-4, "the binding ends where the camera is")
        XCTAssertEqual(region.center.longitude, spokane.longitude, accuracy: 1e-4)
    }

    func testTheFirstFixPostCarriesWhatTheMapReads() {
        // the one function the map screen posts the first fix with: a private centre, so nothing else sees it
        let center = NotificationCenter()
        var info: [AnyHashable: Any]?
        var posts = 0
        let token = center.addObserver(forName: .mapboxMoveCamera, object: nil, queue: nil) { note in
            info = note.userInfo
            posts += 1
        }
        defer { center.removeObserver(token) }
        FirstFixCamera.postMapMove(to: spokane, center: center)
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(info?["lat"] as? Double, spokane.latitude)
        XCTAssertEqual(info?["lon"] as? Double, spokane.longitude)
        XCTAssertEqual(info?["zoom"] as? Double, FirstFixCamera.mapZoom)
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

    func testTheScaleIsPostedAgainOnlyWhenItHasMovedByMoreThanOnePercent() throws {
        // measured once a second, so a scale that was wrong when the terrain had not loaded is put right
        let html = CesiumMainMap.html
        let begin = try XCTUnwrap(html.range(of: "// SCALE-MOVED-BEGIN"), "marker missing from cesium_scene.html")
        let end = try XCTUnwrap(html.range(of: "// SCALE-MOVED-END"), "marker missing from cesium_scene.html")
        let start = try XCTUnwrap(html[begin.upperBound...].firstIndex(of: "\n"))
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(String(html[start..<end.lowerBound]))
        func moved(_ previous: Any, _ next: Any) throws -> Bool {
            try XCTUnwrap(context.objectForKeyedSubscript("_scaleMoved").call(withArguments: [previous, next])).toBool()
        }
        XCTAssertTrue(try moved(26.43, 80.81), "the 3 times too coarse value that stayed on screen")
        XCTAssertTrue(try moved(80.81, 25.5))
        XCTAssertFalse(try moved(25.5, 25.6), "a change of under one percent is not posted")
        XCTAssertTrue(try moved(25.5, 26.0))
        XCTAssertTrue(try moved(NSNull(), 25.5), "a scale appears")
        XCTAssertTrue(try moved(25.5, NSNull()), "a scale goes (the horizon)")
        XCTAssertFalse(try moved(NSNull(), NSNull()))
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

// MARK: - The page's wiring

/// The page's calls that only the page's own events reach: which listeners it installs on the canvas and the
/// camera, what it posts to the app and when. The pure rules above (`_scaleMoved`, `_centerRange`) were run in
/// JavaScriptCore; these run the functions that call them, against a stand-in for the few browser and Cesium
/// objects they touch, so a listener or a call that is dropped from the page fails a test.
final class CesiumPageWiringTests: XCTestCase {

    /// The text of the page between a pair of marker comments.
    private func block(_ name: String) throws -> String {
        let html = CesiumMainMap.html
        let begin = try XCTUnwrap(html.range(of: "// \(name)-BEGIN"), "marker \(name) missing from cesium_scene.html")
        let end = try XCTUnwrap(html.range(of: "// \(name)-END"), "marker \(name) missing from cesium_scene.html")
        let start = try XCTUnwrap(html[begin.upperBound...].firstIndex(of: "\n"))
        return String(html[start..<end.lowerBound])
    }

    private func context(_ standIn: String, blocks: [String], then script: String = "") throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in XCTFail("page script threw: \(String(describing: error))") }
        context.evaluateScript(standIn)
        for name in blocks { context.evaluateScript(try block(name)) }
        if !script.isEmpty { context.evaluateScript(script) }
        return context
    }

    private func int(_ c: JSContext, _ expression: String) -> Int { Int(c.evaluateScript(expression).toInt32()) }

    // MARK: - The listeners the page installs

    /// A canvas that records its listeners, a camera with two events, and the page's own functions the handlers call.
    private static let inputStandIn = #"""
    var Cesium = {
      ScreenSpaceEventHandler: function(canvas) { this.setInputAction = function() {}; },
      ScreenSpaceEventType: {}
    };
    var _state = {centerSeq: 0};
    var posted = [], cameraPosts = [], cancelled = 0;
    function _postMapEvent(e) { posted.push(e); }
    function _postCameraChanged(v, moving) { cameraPosts.push(moving === undefined ? 'at rest' : moving); }
    function _cancelCentering(v) { cancelled++; }
    function _cartoFor() { return null; }
    function _pickedUid() { return null; }
    function emitter() {
      var fns = [];
      return {addEventListener: function(fn) { fns.push(fn); },
              fire: function() { fns.forEach(function(fn) { fn(); }); }};
    }
    var listeners = {};
    var canvas = {addEventListener: function(type, fn, opts) { (listeners[type] = listeners[type] || []).push({fn: fn, opts: opts}); }};
    var viewer = {camera: {moveEnd: emitter(), changed: emitter()}, scene: {canvas: canvas}};
    function fire(type, e) { (listeners[type] || []).forEach(function(l) { l.fn(e || {}); }); }
    function userMoved() { return posted.filter(function(e) { return e.event === 'usermoved'; }).length; }
    """#

    private func inputContext() throws -> JSContext {
        try context(Self.inputStandIn, blocks: ["INPUT-HANDLERS"], then: "_installInputHandlers(viewer);")
    }

    func testAMouseWheelOrTrackpadScrollIsTheOperatorMovingTheMap() throws {
        // an iPad with a trackpad zooms the globe by scrolling: without this the first fix of a first launch
        // flew the camera in over the zoom the operator had just made
        let c = try inputContext()
        XCTAssertEqual(int(c, "(listeners.wheel || []).length"), 1, "the page listens for the wheel")
        XCTAssertTrue(c.evaluateScript("listeners.wheel.every(function(l) { return !!l.opts && l.opts.passive === true; })").toBool(),
                      "passive: it must never hold up the scroll")
        c.evaluateScript("fire('wheel', {deltaY: 120});")
        XCTAssertEqual(int(c, "userMoved()"), 1, "native is told the operator moved the map")
        XCTAssertEqual(int(c, "cancelled"), 1, "and any flight or centring native started stops")
        c.evaluateScript("fire('wheel', {deltaY: -40}); fire('wheel', {deltaY: 10});")
        XCTAssertEqual(int(c, "userMoved()"), 1, "native is told once")
        XCTAssertEqual(int(c, "cancelled"), 3, "every turn of the wheel stops a centring that started since")
    }

    func testOneFingerMovingMoreThanEightPixelsIsTheOperatorMovingTheMap() throws {
        let c = try inputContext()
        c.evaluateScript("fire('pointerdown', {pointerId: 1, clientX: 100, clientY: 100});")
        c.evaluateScript("fire('pointermove', {pointerId: 1, clientX: 104, clientY: 103});")
        XCTAssertEqual(int(c, "userMoved()"), 0, "5 px is a tap that wobbled")
        c.evaluateScript("fire('pointermove', {pointerId: 1, clientX: 112, clientY: 100});")
        XCTAssertEqual(int(c, "userMoved()"), 1)
        XCTAssertEqual(int(c, "cancelled"), 1)
    }

    func testTwoFingersAreTheOperatorMovingTheMapAtOnce() throws {
        let c = try inputContext()
        c.evaluateScript("fire('pointerdown', {pointerId: 1, clientX: 100, clientY: 100});")
        XCTAssertEqual(int(c, "userMoved()"), 0)
        c.evaluateScript("fire('pointerdown', {pointerId: 2, clientX: 200, clientY: 100});")
        XCTAssertEqual(int(c, "userMoved()"), 1)
    }

    func testAFingerThatHasLeftTheScreenIsForgotten() throws {
        let c = try inputContext()
        c.evaluateScript("fire('pointerdown', {pointerId: 1, clientX: 100, clientY: 100}); fire('pointerup', {pointerId: 1});")
        c.evaluateScript("fire('pointermove', {pointerId: 1, clientX: 300, clientY: 300});")
        XCTAssertEqual(int(c, "userMoved()"), 0)
        c.evaluateScript("fire('pointerdown', {pointerId: 3, clientX: 100, clientY: 100}); fire('pointercancel', {pointerId: 3});")
        c.evaluateScript("fire('pointermove', {pointerId: 3, clientX: 300, clientY: 300});")
        XCTAssertEqual(int(c, "userMoved()"), 0)
    }

    func testTheCameraPostsItselfWhenItStopsAndWhileItMoves() throws {
        let c = try inputContext()
        XCTAssertEqual(c.evaluateScript("viewer.camera.percentageChanged").toDouble(), 0.05,
                       "a camera event for every 5 percent of movement, so the bar tracks live")
        c.evaluateScript("viewer.camera.moveEnd.fire();")
        c.evaluateScript("viewer.camera.changed.fire();")
        XCTAssertEqual(c.evaluateScript("JSON.stringify(cameraPosts)").toString(), "[\"at rest\",true]",
                       "the end of a move is read at rest, a change on the way is read quickly")
    }

    // MARK: - What a camera post does

    private static let afterRenderStandIn = #"""
    var _state = {centerSeq: 0};
    var camPosts = [];
    function _postCameraChanged(v) { camPosts.push(v.name); }
    function emitter() {
      var fns = [];
      return {addEventListener: function(fn) { fns.push(fn); },
              removeEventListener: function(fn) { var i = fns.indexOf(fn); if (i >= 0) fns.splice(i, 1); },
              fire: function() { fns.slice().forEach(function(fn) { fn(); }); },
              count: function() { return fns.length; }};
    }
    var v = {name: 'v', renders: 0, flights: 0,
             scene: {postRender: emitter(), requestRender: function() { v.renders++; }},
             camera: {cancelFlight: function() { v.flights++; }}};
    """#

    func testTheCameraIsPostedOnceAfterTheNextFrameHasBeenRendered() throws {
        // a measurement taken between a camera jump and its render reads the previous frame's depth
        let c = try context(Self.afterRenderStandIn, blocks: ["POST-AFTER-RENDER"])
        c.evaluateScript("_postAfterRender(v);")
        XCTAssertEqual(int(c, "camPosts.length"), 0, "not before the frame")
        XCTAssertEqual(int(c, "v.renders"), 1, "a frame is asked for")
        XCTAssertEqual(int(c, "v.scene.postRender.count()"), 1)
        c.evaluateScript("v.scene.postRender.fire();")
        XCTAssertEqual(c.evaluateScript("JSON.stringify(camPosts)").toString(), "[\"v\"]")
        XCTAssertEqual(int(c, "v.scene.postRender.count()"), 0, "once")
        c.evaluateScript("v.scene.postRender.fire();")
        XCTAssertEqual(int(c, "camPosts.length"), 1)
    }

    func testStoppingACentringStopsTheFlightAndInvalidatesAnythingStillWaiting() throws {
        // a centring waits for the ground's height and checks its number when it gets it
        let c = try context(Self.afterRenderStandIn, blocks: ["POST-AFTER-RENDER"])
        c.evaluateScript("_cancelCentering(v); _cancelCentering(v);")
        XCTAssertEqual(int(c, "_state.centerSeq"), 2)
        XCTAssertEqual(int(c, "v.flights"), 2)
    }

    private static let postCameraStandIn = #"""
    var Cesium = {Math: {toDegrees: function(r) { return r * 180 / Math.PI; }},
                  Cartesian2: function(x, y) { this.x = x; this.y = y; }};
    var _state = {};
    var posted = [], measured = [];
    function _postMapEvent(e) { posted.push(e); }
    function _cartoFor(v, p) { return {lat: 47.6, lon: -117.4, hae: 0}; }
    function _zoomFromHeight(h, lat) { return 15; }
    function _scaleMpp(v, quick) { measured.push(quick); return 4.25; }
    var v = {camera: {positionCartographic: {latitude: 0.83, longitude: -2.05, height: 3218},
                      heading: 0, pitch: -Math.PI / 2, computeViewRectangle: function() { return null; }},
             scene: {canvas: {clientWidth: 402, clientHeight: 874}, globe: {ellipsoid: {}}}};
    """#

    func testTheScalePostedIsTheOneTheNextTickComparesAgainst() throws {
        // the once-a-second tick posts again only when the scale differs from the last one posted, by whatever
        // path it was posted: the event must record it
        let c = try context(Self.postCameraStandIn, blocks: ["POST-CAMERA"])
        c.evaluateScript("_postCameraChanged(v, false, 3.5);")
        XCTAssertEqual(c.evaluateScript("posted[0].mpp").toDouble(), 3.5, "the scale handed in is the one posted")
        XCTAssertEqual(c.evaluateScript("_state.scalePosted").toDouble(), 3.5)
        XCTAssertEqual(int(c, "measured.length"), 0, "and it is not measured twice")
        c.evaluateScript("_postCameraChanged(v);")
        XCTAssertEqual(c.evaluateScript("posted[1].mpp").toDouble(), 4.25)
        XCTAssertEqual(c.evaluateScript("_state.scalePosted").toDouble(), 4.25)
        XCTAssertEqual(c.evaluateScript("JSON.stringify(measured)").toString(), "[false]", "at rest: the full measurement")
        c.evaluateScript("_postCameraChanged(v, true);")
        XCTAssertEqual(c.evaluateScript("JSON.stringify(measured)").toString(), "[false,true]", "while moving: the quick one")
        c.evaluateScript("_postCameraChanged(v, false, null);")
        XCTAssertTrue(c.evaluateScript("posted[3].mpp === null").toBool(), "a scale that has gone is posted as gone")
        XCTAssertTrue(c.evaluateScript("_state.scalePosted === null").toBool(), "and remembered as gone")
    }

    func testACameraPostCarriesWhereTheCameraIs() throws {
        let c = try context(Self.postCameraStandIn, blocks: ["POST-CAMERA"])
        c.evaluateScript("_postCameraChanged(v, false, 3.5);")
        XCTAssertEqual(c.evaluateScript("posted[0].event").toString(), "camerachanged")
        XCTAssertEqual(c.evaluateScript("posted[0].height").toDouble(), 3218)
        XCTAssertEqual(c.evaluateScript("posted[0].zoom").toDouble(), 15)
        XCTAssertEqual(c.evaluateScript("posted[0].centerLat").toDouble(), 47.6)
        c.evaluateScript("v.camera.positionCartographic = undefined; _postCameraChanged(v, false, 3.5);")
        XCTAssertEqual(int(c, "posted.length"), 1, "no camera position, nothing to post")
    }

    // MARK: - Who stops a centring that is waiting

    func testEveryNativeCameraCommandStopsACentringThatIsStillWaiting() throws {
        // each command moves the camera itself, so a centring that was waiting for the ground's height must not
        // land afterwards and take the camera back
        let html = CesiumMainMap.html
        for command in ["flyTo", "lookDown", "setCamera", "centerOnSelf", "follow", "zoomBy"] {
            let start = try XCTUnwrap(html.range(of: "\n    \(command)(arg){"), "\(command) is not in the page")
            let rest = html[start.upperBound...]
            let end = rest.range(of: #"\n    [A-Za-z]+\(arg\)\{"#, options: .regularExpression)?.lowerBound ?? rest.endIndex
            let body = String(rest[..<end])
            XCTAssertTrue(body.contains("_cancelCentering(") || body.contains("_state.centerSeq=(_state.centerSeq||0)+1"),
                          "\(command) does not stop a centring that is waiting")
        }
    }
}

// MARK: - The call sites

/// The map screen and the app's start are SwiftUI and cannot be built in a test, so a rule that is tested can
/// still be left out of them. This reads the two files and checks that each rule is called, and the old way
/// of doing it is gone. It skips where the source is not on disk (a test run on a device).
final class MapScreenCallSiteTests: XCTestCase {

    private static let screen = "OmniTAKMobile/Features/Map/Controllers/MapViewController.swift"
    private static let app = "OmniTAKMobile/Core/App/OmniTAKMobileApp.swift"

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("the source is not on disk here: \(url.path)")
        }
        return text
    }

    private func count(_ pattern: String, in text: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    func testTheMapScreenCreatesThe2DMapOnlyThroughTheLatchedGate() throws {
        let text = try source(Self.screen)
        XCTAssertEqual(try count(#"@State private var mapboxGate\b"#, in: text), 1)
        XCTAssertEqual(try count(#"if\s+mapboxGate\.isOpen\s*\{\s*mainMapView"#, in: text), 1,
                       "the map is shown while the gate is open")
        XCTAssertEqual(try count(#"MapboxStart\.mayCreate\("#, in: text), 0,
                       "the live rule decides again on every render: a later report of 'not determined' replaces the live map with a black view")
        XCTAssertGreaterThanOrEqual(
            try count(#"mapboxGate\.update\(reported:\s*locationManager\.hasReportedAuthorization,\s*status:\s*locationManager\.authorizationStatus\)"#, in: text),
            2, "the gate is fed when the screen appears and when the system reports")
        XCTAssertEqual(try count(#"\.onChange\(of:\s*locationManager\.hasReportedAuthorization\)"#, in: text), 1)
    }

    func testTheMapScreenPutsTheQuestionAgainWhenTheStatusGoesBackToNotAsked() throws {
        let text = try source(Self.screen)
        XCTAssertEqual(try count(#"@State private var isMapScreenShowing\b"#, in: text), 1)
        XCTAssertEqual(try count(#"\.onChange\(of:\s*locationManager\.authorizationStatus\)"#, in: text), 1)
        XCTAssertEqual(try count(#"LocationPrompt\.shouldAskAgain\(status:\s*status,\s*mapScreenShowing:\s*isMapScreenShowing,"#, in: text), 1)
        XCTAssertEqual(try count(#"LocationManager\.shared\.ask\(at:\s*\.mapAppeared,\s*status:\s*status\)"#, in: text), 1,
                       "asked through the long-lived manager, with the status that was just reported")
    }

    func testTheFirstFixMovesThe2DMapThroughTheOneFunction() throws {
        let text = try source(Self.screen)
        XCTAssertEqual(try count(#"FirstFixCamera\.postMapMove\(to:\s*location\.coordinate\)"#, in: text), 1)
        XCTAssertEqual(try count(#"post\(\s*name:\s*\.mapboxMoveCamera"#, in: text), 0,
                       "a notification made by hand here is one the tests do not see")
    }

    func testTheCameraEventHandlerReadsTheLaunchViewThenSavesThroughTheOneWriter() throws {
        let text = try source(Self.screen)
        let start = try XCTUnwrap(text.range(of: "case .cameraChanged:"))
        let end = try XCTUnwrap(text.range(of: "case .longpress:", range: start.upperBound..<text.endIndex))
        let handler = String(text[start.upperBound..<end.lowerBound])
        let read = try XCTUnwrap(handler.range(of: "_ = FirstFixState.shared"),
                                 "the camera saved at launch must be read before the first event writes over it")
        let save = try XCTUnwrap(handler.range(of: ").save()"), "the view is saved through SavedGlobePose.save")
        XCTAssertLessThan(read.lowerBound, save.lowerBound)
        XCTAssertEqual(try count(#"cesiumPoseVersion|SavedGlobePose\.versionKey"#, in: text), 0,
                       "the version mark is written by SavedGlobePose.save and nowhere else")
    }

    func testTheAppReadsTheSavedCameraBeforeAnythingCanWriteOverIt() throws {
        let text = try source(Self.app)
        XCTAssertEqual(try count(#"init\(\)\s*\{[^}]*?_ = FirstFixState\.shared[^}]*?_ = MeshtasticManager\.shared"#, in: text), 1,
                       "first in App.init, before the managers that start the map and the location")
    }
}
