//
//  RangeRingTests.swift
//  OmniTAKMobileTests
//
//  Range rings could be placed from the map but removed only from a screen that
//  nothing in the app opens. Now:
//    - every placement is remembered as a set, so the banner's "Remove" takes
//      back exactly that set (MeasurementManager.removeRangeRings(of:))
//    - "Keep", or 8 seconds, hides the banner and leaves the rings
//    - "Clear Rings" is offered on the map menus only while rings exist
//    - both engines draw each visible ring as an outline, never a fill
//
//  Covers:
//    - placing twice gives two sets; removing the last set leaves the first,
//      also when both sets are at the same spot
//    - clear-all empties and persists; a fresh manager on the same store agrees
//    - the Measure tool's tap and the radial "Rings" item both raise the banner
//    - Keep and the time-out hide the banner and keep the rings; an older timer
//      cannot hide a newer banner
//    - the "Clear Rings" decision, the menus it is added to, the radial action
//    - the radial Rings and Clear Rings items do nothing without a measurement
//      manager, which is what the app did before the map handed it one
//    - the 2D ring lines: visible rings only, closed loops at the right radius,
//      a dark casing under each, unique ids
//    - the globe's ring entries: visible rings only, each marked outline-only
//
//  Uses an isolated UserDefaults suite per test; no map view, no network.
//

import XCTest
import CoreLocation
import MapKit
import MapboxMaps
@testable import OmniTAK

final class RangeRingManagerTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var timers: [(delay: TimeInterval, fire: () -> Void)] = []

    private let spokane = CLLocationCoordinate2D(latitude: 47.6588, longitude: -117.4260)
    private let washington = CLLocationCoordinate2D(latitude: 38.8977, longitude: -77.0365)

    override func setUp() {
        super.setUp()
        suiteName = "RangeRingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        timers = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    /// A manager whose banner time-out waits for the test to fire it.
    private func makeManager() -> MeasurementManager {
        MeasurementManager(defaults: defaults, scheduleAfter: { [unowned self] delay, fire in
            self.timers.append((delay, fire))
        })
    }

    /// A second manager reading the same store, as after a relaunch.
    private func relaunched() -> MeasurementManager {
        MeasurementManager(defaults: defaults, scheduleAfter: { _, _ in })
    }

    // MARK: - Sets

    func testPlacingTwiceGivesTwoSets() throws {
        let m = makeManager()
        let a = try XCTUnwrap(m.placeRangeRings(at: spokane))
        let b = try XCTUnwrap(m.placeRangeRings(at: washington))

        // default configuration: 100 m, 500 m, 1 km, 2 km, 5 km per set
        XCTAssertEqual(m.rangeRings.count, 10)
        XCTAssertEqual(a.ringIDs.count, 5)
        XCTAssertEqual(b.ringIDs.count, 5)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(Set(a.ringIDs).isDisjoint(with: b.ringIDs))
        XCTAssertEqual(Set(m.rangeRings.map(\.id)), Set(a.ringIDs + b.ringIDs))
        XCTAssertEqual(m.rangeRings.prefix(5).map(\.radiusMeters), [100, 500, 1_000, 2_000, 5_000])
    }

    func testRemovingTheLastPlacedSetLeavesTheFirst() throws {
        let m = makeManager()
        let a = try XCTUnwrap(m.placeRangeRings(at: spokane))
        let b = try XCTUnwrap(m.placeRangeRings(at: washington))

        m.removeRangeRings(of: b)

        XCTAssertEqual(m.rangeRings.map(\.id), a.ringIDs)
        XCTAssertTrue(m.rangeRings.allSatisfy {
            $0.center.latitude == spokane.latitude && $0.center.longitude == spokane.longitude
        })
    }

    func testRemovingASetPlacedAtTheSameSpotLeavesTheOtherSet() throws {
        let m = makeManager()
        let a = try XCTUnwrap(m.placeRangeRings(at: spokane))
        let b = try XCTUnwrap(m.placeRangeRings(at: spokane))

        m.removeRangeRings(of: a)

        XCTAssertEqual(m.rangeRings.map(\.id), b.ringIDs)
    }

    func testRemovingASetThatIsAlreadyGoneChangesNothing() throws {
        let m = makeManager()
        let a = try XCTUnwrap(m.placeRangeRings(at: spokane))
        let b = try XCTUnwrap(m.placeRangeRings(at: washington))
        m.removeRangeRings(of: a)
        m.removeRangeRings(of: a)
        XCTAssertEqual(m.rangeRings.map(\.id), b.ringIDs)
    }

    // MARK: - Persistence

    func testRemovalIsPersisted() throws {
        let m = makeManager()
        let a = try XCTUnwrap(m.placeRangeRings(at: spokane))
        let b = try XCTUnwrap(m.placeRangeRings(at: washington))
        XCTAssertEqual(relaunched().rangeRings.count, 10)

        m.removeRangeRings(of: b)

        XCTAssertEqual(relaunched().rangeRings.map(\.id), a.ringIDs)
    }

    func testClearAllEmptiesAndPersists() throws {
        let m = makeManager()
        _ = m.placeRangeRings(at: spokane)
        _ = m.placeRangeRings(at: washington)

        m.clearAllRangeRings()

        XCTAssertTrue(m.rangeRings.isEmpty)
        XCTAssertTrue(relaunched().rangeRings.isEmpty, "a fresh manager on the same store must see none")
    }

    // MARK: - The banner

    func testPlacingRaisesTheBannerForThatSet() throws {
        let m = makeManager()
        XCTAssertNil(m.lastRangeRingPlacement)
        let a = try XCTUnwrap(m.placeRangeRings(at: spokane))
        XCTAssertEqual(m.lastRangeRingPlacement, a)
        let b = try XCTUnwrap(m.placeRangeRings(at: washington))
        XCTAssertEqual(m.lastRangeRingPlacement, b, "a new set replaces the banner")
    }

    func testTheMeasureToolsTapRaisesTheBannerToo() {
        let m = makeManager()
        m.startMeasurement(type: .rangeRing)
        m.handleMapTap(at: spokane)

        XCTAssertEqual(m.rangeRings.count, 5)
        XCTAssertEqual(m.lastRangeRingPlacement?.ringIDs, m.rangeRings.map(\.id))
        XCTAssertFalse(m.isActive, "the tool is done once the rings are down")
    }

    func testKeepHidesTheBannerAndLeavesTheRings() throws {
        let m = makeManager()
        let a = try XCTUnwrap(m.placeRangeRings(at: spokane))

        m.acknowledgeRangeRingPlacement(a)

        XCTAssertNil(m.lastRangeRingPlacement)
        XCTAssertEqual(m.rangeRings.count, 5)
        XCTAssertEqual(relaunched().rangeRings.count, 5)
    }

    func testRemoveHidesTheBanner() throws {
        let m = makeManager()
        let a = try XCTUnwrap(m.placeRangeRings(at: spokane))
        m.removeRangeRings(of: a)
        XCTAssertNil(m.lastRangeRingPlacement)
    }

    func testTheBannerHidesItselfAfterEightSecondsAndKeepsTheRings() throws {
        let m = makeManager()
        _ = m.placeRangeRings(at: spokane)

        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers.first?.delay, 8)
        XCTAssertNotNil(m.lastRangeRingPlacement)

        try XCTUnwrap(timers.first).fire()

        XCTAssertNil(m.lastRangeRingPlacement)
        XCTAssertEqual(m.rangeRings.count, 5)
    }

    func testAnOlderTimerCannotHideANewerBanner() throws {
        let m = makeManager()
        _ = m.placeRangeRings(at: spokane)
        let b = try XCTUnwrap(m.placeRangeRings(at: washington))
        guard timers.count == 2 else { return XCTFail("each placement schedules its own time-out, got \(timers.count)") }

        timers[0].fire()
        XCTAssertEqual(m.lastRangeRingPlacement, b, "the first set's timer is stale")

        timers[1].fire()
        XCTAssertNil(m.lastRangeRingPlacement)
    }

    func testClearAllAlsoDropsThePendingBanner() throws {
        let m = makeManager()
        _ = m.placeRangeRings(at: spokane)
        m.clearAllRangeRings()
        XCTAssertNil(m.lastRangeRingPlacement)
    }
}

// MARK: - Menus

final class RangeRingMenuTests: XCTestCase {

    private let spokane = CLLocationCoordinate2D(latitude: 47.6588, longitude: -117.4260)

    private func isolatedManager() -> (MeasurementManager, UserDefaults, String) {
        let suite = "RangeRingMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (MeasurementManager(defaults: defaults, scheduleAfter: { _, _ in }), defaults, suite)
    }

    func testClearIsOfferedOnlyWhenRingsExist() {
        XCTAssertFalse(RangeRingMenu.offersClear(rangeRingCount: 0))
        XCTAssertTrue(RangeRingMenu.offersClear(rangeRingCount: 1))
        XCTAssertTrue(RangeRingMenu.offersClear(rangeRingCount: 15))
    }

    func testMapMenuGainsClearRingsOnlyWhenRingsExist() {
        let base = RadialMenuConfiguration.mapContextMenu(at: spokane)

        let none = base.offeringClearRings(rangeRingCount: 0)
        XCTAssertEqual(none.items.map(\.action), base.items.map(\.action))

        let some = base.offeringClearRings(rangeRingCount: 5)
        XCTAssertEqual(some.items.count, base.items.count + 1)
        let clear = some.items.last
        XCTAssertEqual(clear?.action, .clearRangeRings)
        XCTAssertEqual(clear?.label, "Clear Rings")
    }

    func testMenusThatOfferRingsKeepThemSoASecondSetCanBePlaced() {
        let marker = PointMarker(name: "WP-1", affiliation: .neutral, coordinate: spokane)
        let menus = [
            RadialMenuConfiguration.markerContextMenu(for: marker),
            RadialMenuConfiguration.unitContextMenu(for: MKPointAnnotation()),
            RadialMenuConfiguration.measurementContextMenu(),
        ]
        for menu in menus {
            XCTAssertTrue(menu.items.contains { $0.action == .setRangeRings }, "starts with Rings")
            let withClear = menu.offeringClearRings(rangeRingCount: 3)
            XCTAssertTrue(withClear.items.contains { $0.action == .setRangeRings }, "Rings must stay")
            XCTAssertTrue(withClear.items.contains { $0.action == .clearRangeRings })
            XCTAssertFalse(menu.offeringClearRings(rangeRingCount: 0).items.contains { $0.action == .clearRangeRings })
        }
    }

    func testClearRingsIsNeverAddedTwice() {
        let once = RadialMenuConfiguration.mapContextMenu(at: spokane).offeringClearRings(rangeRingCount: 2)
        let twice = once.offeringClearRings(rangeRingCount: 2)
        XCTAssertEqual(twice.items.filter { $0.action == .clearRangeRings }.count, 1)
    }

    func testRadialClearRingsRemovesEveryRing() throws {
        let (manager, defaults, suite) = isolatedManager()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = manager.placeRangeRings(at: spokane)
        _ = manager.placeRangeRings(at: spokane)
        let services = RadialMenuServices(measurementManager: manager)
        let context = RadialMenuContext.empty(at: .zero, coordinate: spokane)

        let done = RadialMenuActionExecutor.execute(action: .clearRangeRings, context: context, services: services)

        XCTAssertTrue(done)
        XCTAssertTrue(manager.rangeRings.isEmpty)
        XCTAssertTrue(MeasurementManager(defaults: defaults, scheduleAfter: { _, _ in }).rangeRings.isEmpty)
    }

    func testRadialRingsItemPlacesASetAndRaisesTheBanner() throws {
        let (manager, defaults, suite) = isolatedManager()
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = RadialMenuServices(measurementManager: manager)
        let context = RadialMenuContext.empty(at: .zero, coordinate: spokane)

        let done = RadialMenuActionExecutor.execute(action: .setRangeRings, context: context, services: services)

        XCTAssertTrue(done)
        XCTAssertEqual(manager.rangeRings.count, 5)
        XCTAssertNotNil(manager.lastRangeRingPlacement)
    }

    func testRadialRingsItemDoesNothingWithoutAMeasurementManager() {
        // This is what the app did: the map's radial menu was never handed its
        // MeasurementManager, so Rings was a silent dead tap.
        let context = RadialMenuContext.empty(at: .zero, coordinate: spokane)
        XCTAssertFalse(RadialMenuActionExecutor.execute(
            action: .setRangeRings, context: context, services: RadialMenuServices()))
        XCTAssertFalse(RadialMenuActionExecutor.execute(
            action: .clearRangeRings, context: context, services: RadialMenuServices()))
    }

    func testTheMapMenuOffersClearRingsFromTheManagerTheCoordinatorWasGiven() throws {
        let (manager, defaults, suite) = isolatedManager()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = RadialMenuMapCoordinator(services: RadialMenuServices(measurementManager: manager))
        let point = CGPoint(x: 200, y: 400)

        coordinator.showContextMenu(at: point, for: spokane, menuType: .mapContext)
        XCTAssertFalse(coordinator.menuConfiguration.items.contains { $0.action == .clearRangeRings },
                       "no rings, no Clear Rings")
        coordinator.dismissMenu()

        _ = manager.placeRangeRings(at: spokane)
        coordinator.showContextMenu(at: point, for: spokane, menuType: .mapContext)
        XCTAssertTrue(coordinator.menuConfiguration.items.contains { $0.action == .clearRangeRings })
    }

    func testThePointMarkerMenuOffersClearRingsToo() throws {
        let (manager, defaults, suite) = isolatedManager()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = RadialMenuMapCoordinator(services: RadialMenuServices(measurementManager: manager))
        let marker = PointMarker(name: "WP-1", affiliation: .neutral, coordinate: spokane)
        let point = CGPoint(x: 200, y: 400)

        coordinator.showPointMarkerMenu(at: point, coordinate: spokane, marker: marker)
        XCTAssertTrue(coordinator.menuConfiguration.items.contains { $0.action == .setRangeRings })
        XCTAssertFalse(coordinator.menuConfiguration.items.contains { $0.action == .clearRangeRings })
        coordinator.dismissMenu()

        _ = manager.placeRangeRings(at: spokane)
        coordinator.showPointMarkerMenu(at: point, coordinate: spokane, marker: marker)
        XCTAssertTrue(coordinator.menuConfiguration.items.contains { $0.action == .setRangeRings }, "Rings stays")
        XCTAssertTrue(coordinator.menuConfiguration.items.contains { $0.action == .clearRangeRings })
    }
}

// MARK: - 2D drawing

final class RangeRingDrawingTests: XCTestCase {

    private let spokane = CLLocationCoordinate2D(latitude: 47.6588, longitude: -117.4260)

    private func ring(radius: Double, visible: Bool = true, at center: CLLocationCoordinate2D? = nil) -> RangeRing {
        var r = RangeRing(center: center ?? spokane, radiusMeters: radius)
        r.isVisible = visible
        return r
    }

    private func lines(_ rings: [RangeRing]) -> [PolylineAnnotation] {
        TacticalMapView.Coordinator.rangeRingLines(for: rings)
    }

    /// The coloured line of a ring (not its casing).
    private func line(for ring: RangeRing, in all: [PolylineAnnotation]) -> PolylineAnnotation? {
        all.first { $0.id == "rangering-\(ring.id.uuidString)" }
    }

    func testNoRingsDrawsNothing() {
        XCTAssertTrue(lines([]).isEmpty)
    }

    func testOnlyVisibleRingsAreDrawn() {
        let shown1 = ring(radius: 100), hidden = ring(radius: 500, visible: false), shown2 = ring(radius: 1_000)
        let drawn = lines([shown1, hidden, shown2])

        XCTAssertNotNil(line(for: shown1, in: drawn))
        XCTAssertNotNil(line(for: shown2, in: drawn))
        XCTAssertNil(line(for: hidden, in: drawn))
        XCTAssertFalse(drawn.contains { $0.id.contains(hidden.id.uuidString) }, "no casing for a hidden ring either")
    }

    func testEachRingIsAClosedLoopAtItsRadius() throws {
        let r = ring(radius: 2_000)
        let coords = try XCTUnwrap(line(for: r, in: lines([r]))).lineString.coordinates
        XCTAssertGreaterThanOrEqual(coords.count, 32)
        XCTAssertEqual(coords.first?.latitude ?? .nan, coords.last?.latitude ?? 0, accuracy: 1e-9)
        XCTAssertEqual(coords.first?.longitude ?? .nan, coords.last?.longitude ?? 0, accuracy: 1e-9)

        let center = CLLocation(latitude: spokane.latitude, longitude: spokane.longitude)
        for c in coords {
            let d = center.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
            XCTAssertEqual(d, 2_000, accuracy: 2_000 * 0.01, "ring point at \(c)")
        }
    }

    func testRingsAreOutlinesOnly() {
        // Lines cannot be filled: every annotation drawn for a ring is a PolylineAnnotation,
        // so the old tint over the map is gone by construction.
        let drawn: [PolylineAnnotation] = lines([ring(radius: 100), ring(radius: 5_000)])
        XCTAssertEqual(drawn.count, 4, "one line and one casing per ring")
    }

    func testEachRingHasADarkerWiderCasingSoItReadsOnALightMap() throws {
        var r = ring(radius: 500)
        r.color = UIColor(red: 1, green: 0.988, blue: 0, alpha: 1)   // the default yellow
        let drawn = lines([r])
        let colored = try XCTUnwrap(line(for: r, in: drawn))
        let casing = try XCTUnwrap(drawn.first { $0.id == "rangering-casing-\(r.id.uuidString)" })

        XCTAssertEqual(colored.lineWidth, 2)
        XCTAssertNotNil(colored.lineColor)
        XCTAssertGreaterThan(casing.lineWidth ?? 0, colored.lineWidth ?? 0)
        XCTAssertEqual(casing.lineString.coordinates.count, colored.lineString.coordinates.count)
        // the casing is drawn first, so the coloured line sits on top of it
        let casingIndex = try XCTUnwrap(drawn.firstIndex { $0.id == casing.id })
        let coloredIndex = try XCTUnwrap(drawn.firstIndex { $0.id == colored.id })
        XCTAssertLessThan(casingIndex, coloredIndex)
    }

    func testTwoSetsAtTheSameSpotDoNotShareIds() {
        let drawn = lines([ring(radius: 100), ring(radius: 100)])   // same centre, same radius, distinct ids
        XCTAssertEqual(Set(drawn.map(\.id)).count, 4)
    }
}

// MARK: - 3D drawing

final class RangeRingGlobeTests: XCTestCase {

    private let spokane = CLLocationCoordinate2D(latitude: 47.6588, longitude: -117.4260)

    private func globe(rings: [RangeRing]) -> CesiumMainMap {
        CesiumMainMap(
            contacts: [],
            aircraft: [],
            lineDrawings: [],
            circleDrawings: [],
            polygonDrawings: [],
            markerDrawings: [],
            rangeRings: rings,
            pointMarkers: [],
            selfLocation: nil,
            selfCallsign: "ALPHA-1",
            measurements: [],
            breadcrumbTrailCoords: [],
            breadcrumbTrailColor: "#00FF00"
        )
    }

    private func ringEntries(_ rings: [RangeRing]) throws -> [[String: Any]] {
        let json = globe(rings: rings).buildDrawingJSON()
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        return list.filter { ($0["uid"] as? String)?.hasPrefix("rring-") == true }
    }

    func testTheGlobeDrawsEachVisibleRingAsAnOutlineCircle() throws {
        let ring = RangeRing(center: spokane, radiusMeters: 2_000)
        let entry = try XCTUnwrap(ringEntries([ring]).first)

        XCTAssertEqual(entry["uid"] as? String, "rring-\(ring.id.uuidString)")
        XCTAssertEqual(entry["kind"] as? String, "circle")
        // the scene turns filled:false into a closed line; without it a ground disc is filled
        XCTAssertEqual(entry["filled"] as? Bool, false)

        let coords = try XCTUnwrap(entry["coords"] as? [[Double]])
        XCTAssertEqual(coords.count, 2, "centre and an edge point")
        let center = CLLocation(latitude: coords[0][1], longitude: coords[0][0])
        let edge = CLLocation(latitude: coords[1][1], longitude: coords[1][0])
        XCTAssertEqual(center.distance(from: edge), 2_000, accuracy: 2_000 * 0.01)
    }

    func testTheGlobeLeavesHiddenRingsOut() throws {
        var hidden = RangeRing(center: spokane, radiusMeters: 500)
        hidden.isVisible = false
        let shown = RangeRing(center: spokane, radiusMeters: 1_000)

        let entries = try ringEntries([hidden, shown])

        XCTAssertEqual(entries.compactMap { $0["uid"] as? String }, ["rring-\(shown.id.uuidString)"])
    }
}
