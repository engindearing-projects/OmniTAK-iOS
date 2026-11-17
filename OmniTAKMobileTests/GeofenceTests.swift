//
//  GeofenceTests.swift
//  OmniTAKMobileTests
//
//  Geofences that work. The Geofence tool used to open a form that put every circle in
//  Washington DC, watch nothing, draw nothing and alert on nothing. These tests pin the parts
//  that decide what happens, each as a pure function of its inputs:
//    - the monitor's rules: the first sighting is a baseline and raises nothing; entry, exit and
//      dwell once per stay; a zone that is off or deleted forgets; a subject that goes forgets
//    - the time is passed in, so dwell is tested without waiting
//    - circle and polygon containment at the edges (a polygon across the antimeridian is out of scope)
//    - geofences written by older versions still decode, and the placeholder ones are removed once
//    - who counts as a teammate, the words of an alert, and the order banners are shown in
//    - what both map engines are told to draw, and the small rules of the new-geofence form
//

import XCTest
import CoreLocation
import JavaScriptCore
@testable import OmniTAK

final class GeofenceTests: XCTestCase {

    // MARK: - Fixtures

    private let spokane = CLLocationCoordinate2D(latitude: 47.6588, longitude: -117.4260)
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// A point `meters` north of Spokane (flat maths, good to well under 1 % here).
    private func north(_ meters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: spokane.latitude + meters / 111_200, longitude: spokane.longitude)
    }

    private var inside: CLLocationCoordinate2D { spokane }
    private var outside: CLLocationCoordinate2D { north(1_000) }

    private func zone(name: String = "North gate",
                      radius: Double = 200,
                      entry: Bool = true,
                      exit: Bool = true,
                      dwell: TimeInterval = 0,
                      active: Bool = true,
                      watchSelf: Bool = true,
                      watchContacts: Bool = true,
                      id: UUID = UUID()) -> Geofence {
        Geofence(id: id, name: name, type: .circle, color: .red, isActive: active,
                 alertOnEntry: entry, alertOnExit: exit, dwellTimeThreshold: dwell,
                 watchSelf: watchSelf, watchContacts: watchContacts,
                 center: spokane, radius: radius)
    }

    private func square(halfSide: Double = 0.001) -> Geofence {
        let c = spokane
        return Geofence(name: "Yard", type: .polygon, color: .blue,
                        polygonCoordinates: [
                            CLLocationCoordinate2D(latitude: c.latitude - halfSide, longitude: c.longitude - halfSide),
                            CLLocationCoordinate2D(latitude: c.latitude - halfSide, longitude: c.longitude + halfSide),
                            CLLocationCoordinate2D(latitude: c.latitude + halfSide, longitude: c.longitude + halfSide),
                            CLLocationCoordinate2D(latitude: c.latitude + halfSide, longitude: c.longitude - halfSide),
                        ])
    }

    @discardableResult
    private func see(_ monitor: inout GeofenceMonitor,
                     _ coordinate: CLLocationCoordinate2D,
                     _ seconds: TimeInterval,
                     _ zones: [Geofence],
                     as subject: String = "me",
                     called name: String = "ALPHA-1",
                     isOperator: Bool = true) -> [GeofenceTransition] {
        monitor.update(subject: subject, name: name, coordinate: coordinate, now: at(seconds),
                       zones: zones, isOperator: isOperator)
    }

    // MARK: - The first sighting is a baseline

    func testFirstSightingInsideRaisesNothing() {
        var monitor = GeofenceMonitor()
        XCTAssertTrue(see(&monitor, inside, 0, [zone()]).isEmpty,
                      "making a zone around yourself must not announce that you entered it")
    }

    func testFirstSightingOutsideRaisesNothing() {
        var monitor = GeofenceMonitor()
        XCTAssertTrue(see(&monitor, outside, 0, [zone()]).isEmpty)
    }

    func testTheBaselineIsPerSubjectAndPerZone() {
        var monitor = GeofenceMonitor()
        let a = zone(name: "A"), b = zone(name: "B")
        // the operator is baselined against both; a teammate seen later gets his own baseline
        XCTAssertTrue(see(&monitor, inside, 0, [a, b], as: "me").isEmpty)
        XCTAssertTrue(see(&monitor, inside, 1, [a, b], as: "bravo", called: "BRAVO", isOperator: false).isEmpty)
        // a zone added afterwards baselines both of them again, quietly
        let c = zone(name: "C")
        XCTAssertTrue(see(&monitor, inside, 2, [a, b, c], as: "me").isEmpty)
    }

    // MARK: - Entry and exit

    func testEntryWhenOutsideThenInside() throws {
        var monitor = GeofenceMonitor()
        let z = zone()
        _ = see(&monitor, outside, 0, [z])
        let result = see(&monitor, inside, 10, [z])
        let entry = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(entry.type, .entry)
        XCTAssertEqual(entry.geofenceID, z.id)
        XCTAssertEqual(entry.geofenceName, "North gate")
        XCTAssertEqual(entry.subjectID, "me")
        XCTAssertEqual(entry.subjectName, "ALPHA-1")
        XCTAssertTrue(entry.isOperator)
        XCTAssertEqual(entry.time, at(10))
        XCTAssertEqual(entry.coordinate.latitude, inside.latitude)
        XCTAssertNil(entry.stay)
    }

    func testExitWhenInsideThenOutsideAndItSaysHowLongTheStayWas() throws {
        var monitor = GeofenceMonitor()
        let z = zone()
        _ = see(&monitor, inside, 0, [z])
        let result = see(&monitor, outside, 90, [z])
        let exit = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(exit.type, .exit)
        XCTAssertEqual(try XCTUnwrap(exit.stay), 90, accuracy: 1e-9)
    }

    func testNothingWhileStayingInsideOrOutside() {
        var monitor = GeofenceMonitor()
        let z = zone()
        _ = see(&monitor, inside, 0, [z])
        XCTAssertTrue(see(&monitor, inside, 5, [z]).isEmpty)
        XCTAssertTrue(see(&monitor, north(50), 6, [z]).isEmpty)
        _ = see(&monitor, outside, 20, [z])
        XCTAssertTrue(see(&monitor, north(2_000), 30, [z]).isEmpty)
    }

    func testReentryRaisesEntryAgain() {
        var monitor = GeofenceMonitor()
        let z = zone()
        _ = see(&monitor, inside, 0, [z])
        XCTAssertEqual(see(&monitor, outside, 10, [z]).map(\.type), [.exit])
        XCTAssertEqual(see(&monitor, inside, 20, [z]).map(\.type), [.entry])
    }

    func testSubjectsAreTrackedIndependently() {
        var monitor = GeofenceMonitor()
        let z = zone()
        _ = see(&monitor, outside, 0, [z], as: "me")
        _ = see(&monitor, outside, 0, [z], as: "bravo", called: "BRAVO", isOperator: false)
        XCTAssertEqual(see(&monitor, inside, 10, [z], as: "bravo", called: "BRAVO", isOperator: false).map(\.type), [.entry])
        // the operator has not moved: nothing for him
        XCTAssertTrue(see(&monitor, outside, 11, [z], as: "me").isEmpty)
        XCTAssertEqual(see(&monitor, inside, 12, [z], as: "me").map(\.type), [.entry])
    }

    func testOnlyTheZoneThatWasCrossedReports() {
        var monitor = GeofenceMonitor()
        let a = zone(name: "A")
        var far = zone(name: "B")
        far.center = CLLocationCoordinate2D(latitude: 10, longitude: 10)
        _ = see(&monitor, outside, 0, [a, far])
        let result = see(&monitor, inside, 5, [a, far])
        XCTAssertEqual(result.map(\.geofenceName), ["A"])
    }

    // MARK: - Dwell, with time passed in

    func testDwellFiresOnceAtTheThresholdAndAgainOnTheNextStay() {
        var monitor = GeofenceMonitor()
        let z = zone(dwell: 300)
        _ = see(&monitor, inside, 0, [z])                                // baseline: the stay is counted from here
        XCTAssertTrue(see(&monitor, inside, 299, [z]).isEmpty)
        let dwell = see(&monitor, inside, 300, [z])
        XCTAssertEqual(dwell.map(\.type), [.dwell])
        XCTAssertEqual(dwell.first?.stay ?? 0, 300, accuracy: 1e-9)
        XCTAssertTrue(see(&monitor, inside, 600, [z]).isEmpty, "once per stay")
        XCTAssertEqual(see(&monitor, outside, 700, [z]).map(\.type), [.exit])
        XCTAssertEqual(see(&monitor, inside, 800, [z]).map(\.type), [.entry])
        XCTAssertTrue(see(&monitor, inside, 1_099, [z]).isEmpty)
        XCTAssertEqual(see(&monitor, inside, 1_100, [z]).map(\.type), [.dwell], "a new stay can dwell again")
    }

    func testNoDwellWhenTheThresholdIsZero() {
        var monitor = GeofenceMonitor()
        let z = zone(dwell: 0)
        _ = see(&monitor, inside, 0, [z])
        XCTAssertTrue(see(&monitor, inside, 86_400, [z]).isEmpty)
    }

    func testDwellIsCountedFromEntryNotFromTheFirstSightingWhenTheSubjectEntered() {
        var monitor = GeofenceMonitor()
        let z = zone(dwell: 300)
        _ = see(&monitor, outside, 0, [z])
        XCTAssertEqual(see(&monitor, inside, 100, [z]).map(\.type), [.entry])
        XCTAssertTrue(see(&monitor, inside, 399, [z]).isEmpty)
        XCTAssertEqual(see(&monitor, inside, 400, [z]).map(\.type), [.dwell])
    }

    // MARK: - The zone's own wishes

    func testAnEntryAlertSwitchedOffStillTracksSoTheExitKnowsTheStay() throws {
        var monitor = GeofenceMonitor()
        let z = zone(entry: false)
        _ = see(&monitor, outside, 0, [z])
        XCTAssertTrue(see(&monitor, inside, 10, [z]).isEmpty, "no entry alert was asked for")
        let exit = try XCTUnwrap(see(&monitor, outside, 70, [z]).first)
        XCTAssertEqual(exit.type, .exit)
        XCTAssertEqual(try XCTUnwrap(exit.stay), 60, accuracy: 1e-9)
    }

    func testAnExitAlertSwitchedOffRaisesNoExit() {
        var monitor = GeofenceMonitor()
        let z = zone(exit: false)
        _ = see(&monitor, inside, 0, [z])
        XCTAssertTrue(see(&monitor, outside, 10, [z]).isEmpty)
        XCTAssertEqual(see(&monitor, inside, 20, [z]).map(\.type), [.entry])
    }

    func testAZoneWithoutAUsableShapeWatchesNothing() {
        var monitor = GeofenceMonitor()
        let flat = zone(radius: 0)
        _ = see(&monitor, outside, 0, [flat])
        XCTAssertTrue(see(&monitor, inside, 1, [flat]).isEmpty)
        XCTAssertEqual(monitor.occupancy(of: flat.id), GeofenceOccupancy())
    }

    // MARK: - Switched off, deleted, no longer watching

    func testASwitchedOffZoneForgetsItsSubjectsAndSwitchingItBackOnStartsFromANewBaseline() {
        var monitor = GeofenceMonitor()
        var z = zone()
        _ = see(&monitor, outside, 0, [z])                    // was outside
        z.isActive = false
        XCTAssertTrue(see(&monitor, inside, 10, [z]).isEmpty) // off: nothing, and it forgets
        z.isActive = true
        XCTAssertTrue(see(&monitor, inside, 20, [z]).isEmpty,
                      "a new baseline: the old 'outside' must not turn this into an entry")
        XCTAssertEqual(see(&monitor, outside, 30, [z]).map(\.type), [.exit])
    }

    func testADeletedZoneForgetsItsSubjects() {
        var monitor = GeofenceMonitor()
        let z = zone()
        _ = see(&monitor, outside, 0, [z])
        _ = see(&monitor, inside, 10, [])                     // the zone is gone
        XCTAssertTrue(see(&monitor, inside, 20, [z]).isEmpty, "the same zone id coming back is a new baseline")
    }

    func testRetainForgetsWithoutAnyUpdate() {
        var monitor = GeofenceMonitor()
        var z = zone()
        _ = see(&monitor, inside, 0, [z])
        XCTAssertTrue(monitor.occupancy(of: z.id).operatorInside)
        z.isActive = false
        monitor.retain(zones: [z])
        XCTAssertEqual(monitor.occupancy(of: z.id), GeofenceOccupancy())
    }

    func testAZoneNotWatchingTheOperatorIgnoresHimAndForgetsHim() {
        var monitor = GeofenceMonitor()
        var z = zone()
        _ = see(&monitor, outside, 0, [z])
        z.watchSelf = false
        XCTAssertTrue(see(&monitor, inside, 10, [z]).isEmpty)
        XCTAssertEqual(monitor.occupancy(of: z.id), GeofenceOccupancy(), "he is not tracked at all")
        z.watchSelf = true
        XCTAssertTrue(see(&monitor, inside, 20, [z]).isEmpty, "watching him again starts from a new baseline")
    }

    func testAZoneNotWatchingTeammatesIgnoresThemButStillWatchesTheOperator() {
        var monitor = GeofenceMonitor()
        let z = zone(watchContacts: false)
        _ = see(&monitor, outside, 0, [z], as: "me")
        _ = see(&monitor, outside, 0, [z], as: "bravo", called: "BRAVO", isOperator: false)
        XCTAssertTrue(see(&monitor, inside, 10, [z], as: "bravo", called: "BRAVO", isOperator: false).isEmpty)
        XCTAssertEqual(see(&monitor, inside, 11, [z], as: "me").map(\.type), [.entry])
    }

    func testAZoneThatOnlyWatchesTeammatesDoesNotTrackTheOperator() {
        var monitor = GeofenceMonitor()
        let z = zone(watchSelf: false)
        _ = see(&monitor, outside, 0, [z], as: "me")
        XCTAssertTrue(see(&monitor, inside, 5, [z], as: "me").isEmpty)
        _ = see(&monitor, outside, 6, [z], as: "bravo", called: "BRAVO", isOperator: false)
        XCTAssertEqual(see(&monitor, inside, 7, [z], as: "bravo", called: "BRAVO", isOperator: false).map(\.type), [.entry])
    }

    // MARK: - A subject that goes

    func testForgettingASubjectRaisesNothingAndItsNextSightingIsABaseline() {
        var monitor = GeofenceMonitor()
        let z = zone()
        _ = see(&monitor, inside, 0, [z], as: "bravo", called: "BRAVO", isOperator: false)
        monitor.forget(subject: "bravo")
        XCTAssertEqual(monitor.occupancy(of: z.id), GeofenceOccupancy())
        // it comes back outside: it was inside when last seen, but that is forgotten, so no exit
        XCTAssertTrue(see(&monitor, outside, 600, [z], as: "bravo", called: "BRAVO", isOperator: false).isEmpty)
    }

    func testForgettingOneSubjectLeavesTheOthers() {
        var monitor = GeofenceMonitor()
        let z = zone()
        _ = see(&monitor, inside, 0, [z], as: "me")
        _ = see(&monitor, inside, 0, [z], as: "bravo", called: "BRAVO", isOperator: false)
        monitor.forget(subject: "bravo")
        XCTAssertEqual(see(&monitor, outside, 5, [z], as: "me").map(\.type), [.exit])
    }

    // MARK: - Who is inside

    func testOccupancyCountsTheOperatorAndTheTeammatesInside() {
        var monitor = GeofenceMonitor()
        let z = zone()
        _ = see(&monitor, inside, 0, [z], as: "me")
        _ = see(&monitor, inside, 0, [z], as: "bravo", called: "BRAVO", isOperator: false)
        _ = see(&monitor, inside, 0, [z], as: "charlie", called: "CHARLIE", isOperator: false)
        _ = see(&monitor, outside, 0, [z], as: "delta", called: "DELTA", isOperator: false)
        XCTAssertEqual(monitor.occupancy(of: z.id), GeofenceOccupancy(operatorInside: true, teammates: 2))
        _ = see(&monitor, outside, 5, [z], as: "bravo", called: "BRAVO", isOperator: false)
        _ = see(&monitor, outside, 5, [z], as: "me")
        XCTAssertEqual(monitor.occupancy(of: z.id), GeofenceOccupancy(operatorInside: false, teammates: 1))
    }

    // MARK: - Time goes only where it is told to

    func testTimeGoingBackwardsNeverFiresDwellAndNeverGivesANegativeStay() throws {
        var monitor = GeofenceMonitor()
        let z = zone(dwell: 60)
        _ = see(&monitor, inside, 100, [z])
        XCTAssertTrue(see(&monitor, inside, 50, [z]).isEmpty)
        let exit = try XCTUnwrap(see(&monitor, outside, 40, [z]).first)
        XCTAssertEqual(try XCTUnwrap(exit.stay), 0, accuracy: 1e-9)
    }

    // MARK: - Containment

    func testCircleContainsItsCenterAndNotAFarPoint() {
        let z = zone(radius: 200)
        XCTAssertTrue(z.containsPoint(spokane))
        XCTAssertTrue(z.containsPoint(north(150)))
        XCTAssertFalse(z.containsPoint(north(250)))
        XCTAssertFalse(z.containsPoint(CLLocationCoordinate2D(latitude: 38.9, longitude: -77.0)))
    }

    func testAPointExactlyOnTheRadiusIsInside() {
        let edge = north(150)
        let measured = CLLocation(latitude: spokane.latitude, longitude: spokane.longitude)
            .distance(from: CLLocation(latitude: edge.latitude, longitude: edge.longitude))
        XCTAssertTrue(zone(radius: measured).containsPoint(edge), "on the radius counts as inside")
        XCTAssertFalse(zone(radius: measured - 0.01).containsPoint(edge), "a hair inside the radius does not")
    }

    func testPolygonContainsItsInsideAndNotItsOutside() {
        let yard = square()
        XCTAssertTrue(yard.containsPoint(spokane))
        XCTAssertFalse(yard.containsPoint(CLLocationCoordinate2D(latitude: spokane.latitude + 0.005, longitude: spokane.longitude)))
        XCTAssertFalse(yard.containsPoint(CLLocationCoordinate2D(latitude: spokane.latitude, longitude: spokane.longitude + 0.005)))
    }

    func testPolygonEdgesJustInsideAndJustOutside() {
        let yard = square(halfSide: 0.001)
        let e = 1e-7
        XCTAssertTrue(yard.containsPoint(CLLocationCoordinate2D(latitude: spokane.latitude + 0.001 - e, longitude: spokane.longitude)))
        XCTAssertFalse(yard.containsPoint(CLLocationCoordinate2D(latitude: spokane.latitude + 0.001 + e, longitude: spokane.longitude)))
        XCTAssertTrue(yard.containsPoint(CLLocationCoordinate2D(latitude: spokane.latitude, longitude: spokane.longitude - 0.001 + e)))
        XCTAssertFalse(yard.containsPoint(CLLocationCoordinate2D(latitude: spokane.latitude, longitude: spokane.longitude - 0.001 - e)))
    }

    func testPolygonWithFewerThanThreeCornersContainsNothing() {
        let two = Geofence(name: "Line", type: .polygon,
                           polygonCoordinates: [spokane, north(100)])
        XCTAssertFalse(two.containsPoint(spokane))
        XCTAssertFalse(two.hasUsableShape)
        let none = Geofence(name: "Nothing", type: .polygon)
        XCTAssertFalse(none.hasUsableShape)
        XCTAssertNil(none.centerCoordinate)
    }

    func testAMonitorWatchesAPolygon() {
        var monitor = GeofenceMonitor()
        let yard = square()
        _ = see(&monitor, north(500), 0, [yard])
        XCTAssertEqual(see(&monitor, spokane, 5, [yard]).map(\.type), [.entry])
        XCTAssertEqual(see(&monitor, north(500), 10, [yard]).map(\.type), [.exit])
    }

    // MARK: - Geofences written by older versions

    private func olderJSON(extra: String = "") -> Data {
        // exactly what 2.44.0 wrote: a circle with the phone-only tracking fields, no watch keys
        Data("""
        {"id":"6E1E6B1B-3C6B-4B3A-9D6C-0B8D2D0C2F11","name":"Old circle","type":"Circle","color":"Yellow",
         "isActive":true,"alertOnEntry":true,"alertOnExit":false,"dwellTimeThreshold":300,
         "createdAt":780000000,"centerLatitude":47.6588,"centerLongitude":-117.426,"radius":250,
         "userInsideGeofence":true,"entryTime":780000100,"totalDwellTime":42\(extra)}
        """.utf8)
    }

    func testJSONWrittenBeforeTheWatchKeysStillDecodesWithBothOn() throws {
        let geofence = try JSONDecoder().decode(Geofence.self, from: olderJSON())
        XCTAssertEqual(geofence.name, "Old circle")
        XCTAssertTrue(geofence.watchSelf)
        XCTAssertTrue(geofence.watchContacts)
        XCTAssertEqual(geofence.radius, 250)
        XCTAssertEqual(geofence.center?.latitude, 47.6588)
        XCTAssertFalse(geofence.alertOnExit)
        XCTAssertEqual(geofence.dwellTimeThreshold, 300)
    }

    func testTheWatchKeysRoundTrip() throws {
        var g = zone()
        g.watchSelf = false
        g.watchContacts = true
        let back = try JSONDecoder().decode(Geofence.self, from: try JSONEncoder().encode(g))
        XCTAssertFalse(back.watchSelf)
        XCTAssertTrue(back.watchContacts)
        XCTAssertEqual(back.radius, 200)
        XCTAssertEqual(back.center?.longitude, spokane.longitude)
    }

    func testAnEventStoredBeforeItNamedItsSubjectStillDecodesAndReadsAsSomeone() throws {
        let json = Data("""
        {"id":"7E1E6B1B-3C6B-4B3A-9D6C-0B8D2D0C2F11","geofenceId":"6E1E6B1B-3C6B-4B3A-9D6C-0B8D2D0C2F11",
         "geofenceName":"North gate","eventType":"Entry","timestamp":780000000,
         "latitude":47.6,"longitude":-117.4,"userId":"x"}
        """.utf8)
        let event = try JSONDecoder().decode(GeofenceEvent.self, from: json)
        XCTAssertNil(event.userName)
        XCTAssertFalse(event.byOperator)
        XCTAssertEqual(GeofenceAlertText.sentence(for: event, localize: english), "Someone entered North gate")
    }

    // MARK: - The one-time clean-up

    private let storageKey = "com.omnitak.geofences.all"

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "geofence-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func store(_ geofences: [Geofence], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(geofences), forKey: storageKey)
    }

    private func placeholderCircle() -> Geofence {
        Geofence(name: "Circle 1", type: .circle, center: GeofenceManager.placeholderCenter, radius: 100)
    }

    func testPlaceholderCirclesAreRemovedOnTheFirstLoad() throws {
        let defaults = try isolatedDefaults()
        let real = zone(name: "Real")
        try store([placeholderCircle(), real], in: defaults)
        let manager = GeofenceManager(defaults: defaults)
        XCTAssertEqual(manager.geofences.map(\.name), ["Real"])
    }

    func testPolygonsWithFewerThanThreeCornersAreRemovedOnTheFirstLoad() throws {
        let defaults = try isolatedDefaults()
        let none = Geofence(name: "Polygon 1", type: .polygon)
        let two = Geofence(name: "Polygon 2", type: .polygon, polygonCoordinates: [spokane, north(100)])
        try store([none, two, square()], in: defaults)
        let manager = GeofenceManager(defaults: defaults)
        XCTAssertEqual(manager.geofences.map(\.name), ["Yard"])
    }

    func testRealGeofencesSurviveAndThePlaceholderRuleIsExact() throws {
        let defaults = try isolatedDefaults()
        var nearby = placeholderCircle()
        nearby.name = "Near the old point"
        nearby.center = CLLocationCoordinate2D(latitude: 38.8978, longitude: -77.0365)
        try store([nearby, zone(name: "Real")], in: defaults)
        XCTAssertEqual(GeofenceManager(defaults: defaults).geofences.map(\.name), ["Near the old point", "Real"])
    }

    func testTheCleanUpRunsOnceAndALaterGeofenceAtThatPointIsKept() throws {
        let defaults = try isolatedDefaults()
        try store([placeholderCircle()], in: defaults)
        let first = GeofenceManager(defaults: defaults)
        XCTAssertTrue(first.geofences.isEmpty)
        // the 2D map opens centered on that very point: a geofence made there now is real
        first.addGeofence(placeholderCircle())
        let second = GeofenceManager(defaults: defaults)
        XCTAssertEqual(second.geofences.count, 1, "the clean-up does not run twice")
    }

    func testTheCleanUpFlagIsSetEvenWhenThereWasNothingToRemove() throws {
        let defaults = try isolatedDefaults()
        XCTAssertFalse(defaults.bool(forKey: GeofenceManager.placeholderCleanupKey))
        _ = GeofenceManager(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: GeofenceManager.placeholderCleanupKey))
    }

    func testTheManagerKeepsItsGeofencesInTheStoreItWasGiven() throws {
        let defaults = try isolatedDefaults()
        let manager = GeofenceManager(defaults: defaults)
        manager.addGeofence(zone(name: "Kept"))
        var toggled = zone(name: "Toggled")
        manager.addGeofence(toggled)
        toggled = manager.geofences[1]
        manager.toggleGeofence(toggled)
        let again = GeofenceManager(defaults: defaults)
        XCTAssertEqual(again.geofences.map(\.name), ["Kept", "Toggled"])
        XCTAssertFalse(again.geofences[1].isActive)
        manager.deleteGeofence(again.geofences[0])
        XCTAssertEqual(GeofenceManager(defaults: defaults).geofences.map(\.name), ["Toggled"])
    }

    // MARK: - Who counts as a teammate

    func testTeammateRule() {
        func rule(_ uid: String, _ type: String, _ how: String? = "m-g", _ me: String? = "me-uid") -> Bool {
            GeofenceSubjectRule.isTeammate(uid: uid, type: type, how: how, selfUID: me)
        }
        XCTAssertTrue(rule("ANDROID-1a2b", "a-f-G-U-C"), "a teammate's phone")
        XCTAssertTrue(rule("MESHTASTIC-7f3a", "a-n-G-U-C"), "a node heard over a mesh radio")
        // exactly what MeshtasticCoTConverter writes for a node: a mesh uid, a neutral ground unit, reported by a machine
        XCTAssertTrue(rule("mesh-1a2b3c4d", "a-n-G-U-C"), "a Meshtastic node on the map")
        XCTAssertTrue(rule("abc", "a-u-G", nil), "no 'how' at all is left in")
        XCTAssertFalse(rule("me-uid", "a-f-G-U-C"), "the operator's own echo")
        XCTAssertFalse(rule("marker-1234", "a-f-G"), "a dropped marker")
        XCTAssertFalse(rule("RID-9f", "a-u-A"), "a drone detection")
        XCTAssertFalse(rule("RID-OP-9f", "a-f-G"))
        XCTAssertFalse(rule("x", "a-h-G"), "hostile")
        XCTAssertFalse(rule("x", "a-s-G"), "suspect")
        XCTAssertFalse(rule("x", "a-j-G"), "joker")
        XCTAssertFalse(rule("x", "b-m-p-w"), "a waypoint, not a unit")
        XCTAssertFalse(rule("x", "a-f-G", "h-g-i-g-o"), "placed by hand, not reported by a device")
    }

    // MARK: - The words of an alert

    private lazy var english: GeofenceAlertText.Localize = {
        let path = Bundle.main.path(forResource: "en", ofType: "lproj")!
        let bundle = Bundle(path: path)!
        return { bundle.localizedString(forKey: $0, value: nil, table: nil) }
    }()

    private func sentence(_ type: GeofenceEventType, operator isOperator: Bool, stay: TimeInterval? = nil) -> String {
        GeofenceAlertText.sentence(type: type, geofenceName: "North gate", subjectName: "ALPHA-2",
                                   byOperator: isOperator, stay: stay, localize: english)
    }

    func testSentencesForTheOperator() {
        XCTAssertEqual(sentence(.entry, operator: true), "You entered North gate")
        XCTAssertEqual(sentence(.exit, operator: true), "You left North gate")
        XCTAssertEqual(sentence(.dwell, operator: true, stay: 300), "You have been in North gate for 5 min")
    }

    func testSentencesForATeammateUseHisName() {
        XCTAssertEqual(sentence(.entry, operator: false), "ALPHA-2 entered North gate")
        XCTAssertEqual(sentence(.exit, operator: false), "ALPHA-2 left North gate")
        XCTAssertEqual(sentence(.dwell, operator: false, stay: 300), "ALPHA-2 has been in North gate for 5 min")
    }

    func testSentenceFromATransition() {
        let t = GeofenceTransition(geofenceID: UUID(), geofenceName: "Yard", subjectID: "x", subjectName: "BRAVO",
                                   isOperator: false, type: .entry, coordinate: spokane, time: t0, stay: nil)
        XCTAssertEqual(GeofenceAlertText.sentence(for: t, localize: english), "BRAVO entered Yard")
    }

    func testDurations() {
        func d(_ s: TimeInterval) -> String { GeofenceAlertText.duration(s, localize: english) }
        XCTAssertEqual(d(-5), "0 s")
        XCTAssertEqual(d(0), "0 s")
        XCTAssertEqual(d(45), "45 s")
        XCTAssertEqual(d(60), "1 min")
        XCTAssertEqual(d(299), "4 min")
        XCTAssertEqual(d(300), "5 min")
        XCTAssertEqual(d(3_599), "59 min")
        XCTAssertEqual(d(3_600), "1 h")
        XCTAssertEqual(d(3_900), "1 h 5 min")
        XCTAssertEqual(d(7_261), "2 h 1 min")
    }

    func testTheStateLineOnACard() {
        func line(_ active: Bool, _ you: Bool, _ mates: Int) -> String {
            GeofenceAlertText.stateLine(isActive: active, occupancy: GeofenceOccupancy(operatorInside: you, teammates: mates),
                                        localize: english)
        }
        XCTAssertEqual(line(false, true, 3), "Switched off")
        XCTAssertEqual(line(true, false, 0), "Nobody inside")
        XCTAssertEqual(line(true, true, 0), "You are inside")
        XCTAssertEqual(line(true, false, 1), "1 teammate inside")
        XCTAssertEqual(line(true, false, 2), "2 teammates inside")
        XCTAssertEqual(line(true, true, 1), "You and 1 teammate are inside")
        XCTAssertEqual(line(true, true, 3), "You and 3 teammates are inside")
    }

    func testEveryTableHasEveryGeofenceKeyTheCodeUses() throws {
        let keys = ["geofence.title", "geofence.alert.you.entered", "geofence.alert.other.dwell",
                    "geofence.state.you.teammates", "geofence.form.source.map", "geofence.duration.hoursMinutes",
                    "geofence.notification.title"]
        for language in ["en", "uk", "pl", "de", "fr", "es", "zh-Hant"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "\u{0}missing", table: nil)
                XCTAssertNotEqual(value, "\u{0}missing", "\(language) lacks \(key)")
            }
        }
    }

    func testTheAgeOfAnEventInTheListReadsNowForAFreshOneAndNeverInZeroSeconds() {
        let en = Locale(identifier: "en_US")
        func age(_ seconds: TimeInterval) -> String {
            GeofenceAlertText.age(of: at(-seconds), now: at(0), locale: en)
        }
        XCTAssertEqual(age(0), "now")
        XCTAssertEqual(age(0.4), "now")
        XCTAssertEqual(age(49), "49 seconds ago")
        XCTAssertEqual(age(300), "5 minutes ago")
        // a clock that moved back a little reads as now, not as an event in the future
        XCTAssertEqual(GeofenceAlertText.age(of: at(3), now: at(0), locale: en), "now")
    }

    // MARK: - Banners, one at a time

    private func banner(_ text: String) -> GeofenceBanner {
        GeofenceBanner(sentence: text, type: .entry, geofenceID: UUID())
    }

    func testBannersAreShownOneAtATimeForFiveSecondsEach() {
        var queue = GeofenceBannerQueue()
        let a = banner("A"), b = banner("B"), c = banner("C")
        queue.add(a, now: at(0))
        queue.add(b, now: at(1))
        queue.add(c, now: at(2))
        XCTAssertEqual(queue.current, a)
        XCTAssertEqual(queue.showUntil, at(5))
        queue.tick(now: at(4.9))
        XCTAssertEqual(queue.current, a)
        queue.tick(now: at(5))
        XCTAssertEqual(queue.current, b)
        XCTAssertEqual(queue.showUntil, at(10), "the next one gets its own five seconds")
        queue.tick(now: at(9.99))
        XCTAssertEqual(queue.current, b)
        queue.tick(now: at(10))
        XCTAssertEqual(queue.current, c)
        queue.tick(now: at(15))
        XCTAssertNil(queue.current)
        XCTAssertNil(queue.showUntil)
    }

    func testDismissingABannerShowsTheNext() {
        var queue = GeofenceBannerQueue()
        let a = banner("A"), b = banner("B")
        queue.add(a, now: at(0))
        queue.add(b, now: at(0))
        queue.dismissCurrent(now: at(1))
        XCTAssertEqual(queue.current, b)
        XCTAssertEqual(queue.showUntil, at(6))
        queue.dismissCurrent(now: at(2))
        XCTAssertNil(queue.current)
        queue.dismissCurrent(now: at(3))   // nothing showing: nothing to do
        XCTAssertNil(queue.current)
    }

    func testABannerAddedToAnEmptyQueueShowsAtOnce() {
        var queue = GeofenceBannerQueue()
        let a = banner("A")
        queue.tick(now: at(100))
        queue.add(a, now: at(100))
        XCTAssertEqual(queue.current, a)
    }

    func testTooManyWaitingBannersDropTheOldest() {
        var queue = GeofenceBannerQueue()
        for i in 0..<30 { queue.add(banner("\(i)"), now: at(0)) }
        XCTAssertEqual(queue.current?.sentence, "0")
        XCTAssertEqual(queue.waiting.count, GeofenceBannerQueue.mostWaiting)
        XCTAssertEqual(queue.waiting.last?.sentence, "29", "the newest are kept")
    }

    // MARK: - What the maps draw

    func testOnlyGeofencesThatAreOnAndHaveAShapeAreDrawn() {
        let on = zone(name: "On")
        let off = zone(name: "Off", active: false)
        let flat = zone(name: "Flat", radius: 0)
        let yard = square()
        let shapes = GeofenceMapShape.shapes(from: [on, off, flat, yard])
        XCTAssertEqual(shapes.map(\.name), ["On", "Yard"])
    }

    func testShapeIdsCannotCollideWithDrawings() {
        let g = zone()
        let shape = GeofenceMapShape.shapes(from: [g])[0]
        XCTAssertEqual(shape.id, "geofence-" + g.id.uuidString)
        for drawingPrefix in ["line-", "poly-", "circ-", "dmark-", "rring-", "dl-", "dp-", "dc-", "lbl-"] {
            XCTAssertFalse(shape.id.hasPrefix(drawingPrefix))
        }
        XCTAssertEqual(GeofenceMapShape.idPrefix, "geofence-")
    }

    func testTheFillIsLight() {
        XCTAssertEqual(GeofenceMapShape.fillAlpha, 0.12, accuracy: 1e-9)
    }

    func testACircleRingIsClosedAndEveryPointIsOnTheRadius() throws {
        let shape = GeofenceMapShape.shapes(from: [zone(radius: 500)])[0]
        let ring = shape.ring(circleSegments: 64)
        XCTAssertEqual(ring.count, 65)
        XCTAssertEqual(ring.first?.latitude, ring.last?.latitude)
        XCTAssertEqual(ring.first?.longitude, ring.last?.longitude)
        let center = CLLocation(latitude: spokane.latitude, longitude: spokane.longitude)
        for point in ring {
            let d = center.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            XCTAssertEqual(d, 500, accuracy: 500 * 0.01)
        }
    }

    func testAPolygonRingIsItsCornersClosed() {
        let shape = GeofenceMapShape.shapes(from: [square()])[0]
        let ring = shape.ring()
        XCTAssertEqual(ring.count, 5)
        XCTAssertEqual(ring.first?.latitude, ring.last?.latitude)
    }

    func testACirclesNameIsWrittenOnItsNorthEdgeAndAPolygonsAtTheMeanOfItsCorners() throws {
        // On the north edge, so the operator's own marker (a geofence is often made around
        // him, at the middle) never covers the name.
        let circle = GeofenceMapShape.shapes(from: [zone(radius: 500)])[0]
        XCTAssertEqual(circle.labelCoordinate.longitude, spokane.longitude, accuracy: 1e-9)
        XCTAssertGreaterThan(circle.labelCoordinate.latitude, spokane.latitude)
        let distance = CLLocation(latitude: spokane.latitude, longitude: spokane.longitude)
            .distance(from: CLLocation(latitude: circle.labelCoordinate.latitude,
                                       longitude: circle.labelCoordinate.longitude))
        XCTAssertEqual(distance, 500, accuracy: 5)
        let polygon = GeofenceMapShape.shapes(from: [square()])[0]
        XCTAssertEqual(polygon.labelCoordinate.latitude, spokane.latitude, accuracy: 1e-9)
        XCTAssertEqual(polygon.labelCoordinate.longitude, spokane.longitude, accuracy: 1e-9)
    }

    func testAGeofencesCenterIsTheMiddleOfACircleAndTheMeanOfAPolygonsCorners() throws {
        XCTAssertEqual(try XCTUnwrap(zone().centerCoordinate).latitude, spokane.latitude)
        let yard = try XCTUnwrap(square().centerCoordinate)
        XCTAssertEqual(yard.latitude, spokane.latitude, accuracy: 1e-9)
        XCTAssertEqual(yard.longitude, spokane.longitude, accuracy: 1e-9)
    }

    // MARK: - Show on map

    func testAGeofencesExtentIsItsRadiusOrItsFarthestCorner() throws {
        XCTAssertEqual(try XCTUnwrap(zone(radius: 321).extent), 321, accuracy: 1e-9)
        // a corner of the square is 0.001 degrees of latitude (111 m) and of longitude (75 m) from its middle
        XCTAssertEqual(try XCTUnwrap(square(halfSide: 0.001).extent), 134, accuracy: 2)
        XCTAssertNil(Geofence(name: "Empty", type: .polygon).extent)
        XCTAssertNil(zone(radius: 0).extent)
    }

    func testShowOnMapFramesTheWholeShapeWithRoomAroundIt() {
        XCTAssertEqual(GeofenceFraming.viewWidth(forExtent: 200), 1_200, accuracy: 1e-9)
        XCTAssertEqual(GeofenceFraming.viewWidth(forExtent: 50), 600, accuracy: 1e-9, "never closer than 600 m across")
        XCTAssertEqual(GeofenceFraming.viewWidth(forExtent: 5_000), 30_000, accuracy: 1e-9)
    }

    func testTheFlatMapIsGivenTheLongitudeSpanThatMakesThatWidth() {
        // 1,200 m across a phone held upright, on a map whose world tile is 512 points wide, at Spokane
        XCTAssertEqual(GeofenceFraming.longitudeSpan(viewWidth: 1_200, latitude: 47.6588, screenWidth: 402),
                       0.0204, accuracy: 0.0005)
        // on its side the screen is wider, so the same width of ground is spread over more points:
        // the map is zoomed in, and the span of its 512 point tile is smaller
        XCTAssertEqual(GeofenceFraming.longitudeSpan(viewWidth: 1_200, latitude: 47.6588, screenWidth: 874),
                       0.0204 * 402 / 874, accuracy: 0.0005)
        XCTAssertGreaterThan(GeofenceFraming.longitudeSpan(viewWidth: 1_200, latitude: 60, screenWidth: 402),
                             GeofenceFraming.longitudeSpan(viewWidth: 1_200, latitude: 0, screenWidth: 402),
                             "a degree of longitude is shorter the farther from the equator")
    }

    func testTheGlobeLooksStraightDownFromHighEnoughToShowThatWidth() throws {
        // The page works the height out from its own camera, so it is right on a phone held either
        // way up; this runs that function as it is written in the bundled scene.
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try globeLookDownFunction())
        func height(width: Double, aspect: Double, fovy: Double) throws -> Double {
            try XCTUnwrap(context.objectForKeyedSubscript("_lookDownAgl")
                .call(withArguments: [width, aspect, fovy])).toDouble()
        }
        // held upright, the page's 60 degree field of view is the vertical one
        let portrait = 402.0 / 874.0
        XCTAssertEqual(try height(width: 1_200, aspect: portrait, fovy: .pi / 3), 2_260, accuracy: 5)
        // held on its side the 60 degrees is the horizontal one and the vertical one is narrower,
        // so the same width is seen from lower down
        let landscape = 874.0 / 402.0
        XCTAssertEqual(try height(width: 1_200, aspect: landscape, fovy: 2 * atan(tan(.pi / 6) / landscape)),
                       1_039, accuracy: 5)
        // no width, or a screen with no width: nothing to look at
        let none = try XCTUnwrap(context.objectForKeyedSubscript("_lookDownAgl")
            .call(withArguments: [0, portrait, Double.pi / 3]))
        XCTAssertTrue(none.isNull)
    }

    func testTheGlobeFliesToARealGroundHeightAndNeverToJunk() throws {
        // After a 3D, 2D, 3D round trip the globe's own answer for the height of the ground at Spokane,
        // with the camera still over New York, was -39,874 m: "Show on map" sent the camera 37 km under the
        // ground, where it ends up on the ground itself. A height that no ground has is taken as sea level.
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try globeLookDownFunction())
        func ground(_ value: Any) throws -> Double {
            try XCTUnwrap(context.objectForKeyedSubscript("_lookDownGround")
                .call(withArguments: [value])).toDouble()
        }
        XCTAssertEqual(try ground(553.27), 553.27, accuracy: 1e-9)
        XCTAssertEqual(try ground(-39_874.087), 0)
        XCTAssertEqual(try ground(-430.0), -430.0, accuracy: 1e-9, "the Dead Sea shore is real ground")
        XCTAssertEqual(try ground(8_849.0), 8_849.0, accuracy: 1e-9, "so is the top of Everest")
        XCTAssertEqual(try ground(12_000.0), 0)
        XCTAssertEqual(try ground(Double.nan), 0)
        XCTAssertEqual(try ground(Double.infinity), 0)
        XCTAssertEqual(try ground(NSNull()), 0, "no answer is sea level")
        XCTAssertEqual(try ground(JSValue(undefinedIn: context) as Any), 0)
    }

    /// The page's `_lookDownAgl`, cut out of the bundled scene between its two marker comments.
    private func globeLookDownFunction() throws -> String {
        let html = CesiumMainMap.html
        let begin = try XCTUnwrap(html.range(of: "// LOOKDOWN-BEGIN"), "marker missing from cesium_scene.html")
        let end = try XCTUnwrap(html.range(of: "// LOOKDOWN-END"), "marker missing from cesium_scene.html")
        let start = try XCTUnwrap(html[begin.upperBound...].firstIndex(of: "\n"))
        return String(html[start..<end.lowerBound])
    }

    func testTheColorIsTheSameTintTheDrawingsUse() {
        XCTAssertEqual(GeofenceColor.red.tintHex, "#FF3B30")
        XCTAssertEqual(GeofenceColor.cyan.tintHex, "#5AC8FA")
        XCTAssertEqual(Set(GeofenceColor.allCases.map(\.tintHex)).count, GeofenceColor.allCases.count)
    }

    // MARK: - The new-geofence form

    func testTheOfferedNameIsTheLowestFreeNumber() {
        func name(_ existing: [String]) -> String { GeofenceForm.defaultName(existing: existing, template: "Geofence %d") }
        XCTAssertEqual(name([]), "Geofence 1")
        XCTAssertEqual(name(["Geofence 1"]), "Geofence 2")
        XCTAssertEqual(name(["Geofence 1", "Geofence 3"]), "Geofence 2")
        XCTAssertEqual(name(["North gate", "Yard"]), "Geofence 1")
    }

    func testRadiusChoicesRunFromFiftyMetersToFiveKilometers() {
        XCTAssertEqual(GeofenceForm.radiusChoices.first, 50)
        XCTAssertEqual(GeofenceForm.radiusChoices.last, 5_000)
        XCTAssertEqual(GeofenceForm.radiusChoices, GeofenceForm.radiusChoices.sorted())
        XCTAssertTrue(GeofenceForm.radiusChoices.contains(GeofenceForm.defaultRadius))
        XCTAssertEqual(GeofenceForm.nearestRadius(to: 10), 50)
        XCTAssertEqual(GeofenceForm.nearestRadius(to: 210), 200)
        XCTAssertEqual(GeofenceForm.nearestRadius(to: 99_999), 5_000)
    }

    func testRadiusInTheOperatorsUnits() {
        XCTAssertEqual(GeofenceForm.radiusLabel(meters: 50, unitSystem: .metric), "50 m")
        XCTAssertEqual(GeofenceForm.radiusLabel(meters: 200, unitSystem: .metric), "200 m")
        XCTAssertEqual(GeofenceForm.radiusLabel(meters: 1_000, unitSystem: .metric), "1 km")
        XCTAssertEqual(GeofenceForm.radiusLabel(meters: 1_500, unitSystem: .metric), "1.5 km")
        XCTAssertEqual(GeofenceForm.radiusLabel(meters: 5_000, unitSystem: .metric), "5 km")
        XCTAssertEqual(GeofenceForm.radiusLabel(meters: 200, unitSystem: .imperial), "660 ft")
        XCTAssertEqual(GeofenceForm.radiusLabel(meters: 1_000, unitSystem: .imperial), "0.62 mi")
        XCTAssertEqual(GeofenceForm.radiusLabel(meters: 5_000, unitSystem: .imperial), "3.11 mi")
    }

    func testAGeofenceFromADrawingCopiesItsShape() throws {
        let circle = CircleDrawing(name: "Circle 1", color: .red, center: spokane, radius: 321)
        var polygon = PolygonDrawing(name: "Polygon 1", color: .blue,
                                     coordinates: [spokane, north(100), CLLocationCoordinate2D(latitude: spokane.latitude, longitude: spokane.longitude + 0.001)])
        let fromCircle = GeofenceDrawingSource.fromCircle(circle).makeGeofence(
            name: "From circle", color: .green, alertOnEntry: true, alertOnExit: false,
            dwellTimeThreshold: 120, watchSelf: false, watchContacts: true)
        XCTAssertEqual(fromCircle.type, .circle)
        XCTAssertEqual(fromCircle.center?.latitude, spokane.latitude)
        XCTAssertEqual(fromCircle.radius, 321)
        XCTAssertFalse(fromCircle.watchSelf)
        XCTAssertFalse(fromCircle.alertOnExit)
        XCTAssertEqual(fromCircle.dwellTimeThreshold, 120)

        let fromPolygon = GeofenceDrawingSource.fromPolygon(polygon).makeGeofence(
            name: "From polygon", color: .green, alertOnEntry: true, alertOnExit: true,
            dwellTimeThreshold: 0, watchSelf: true, watchContacts: true)
        XCTAssertEqual(fromPolygon.type, .polygon)
        XCTAssertEqual(fromPolygon.polygonCoordinates?.count, 3)
        // editing the drawing afterwards does not move the geofence
        polygon.coordinates[0] = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        XCTAssertEqual(fromPolygon.polygonCoordinates?[0].latitude, spokane.latitude)
        XCTAssertTrue(fromPolygon.hasUsableShape)
    }

    func testWatchesHelper() {
        let both = zone()
        XCTAssertTrue(both.watches(operator: true))
        XCTAssertTrue(both.watches(operator: false))
        XCTAssertFalse(zone(watchSelf: false).watches(operator: true))
        XCTAssertFalse(zone(watchContacts: false).watches(operator: false))
    }
}

// MARK: - The service starts and stops what it listens to

/// The service watches nothing until a geofence needs it, and lets go of everything when the
/// last one is switched off or deleted. Each test gives it a manager and a store of its own.
final class GeofenceServiceTests: XCTestCase {

    private let spokane = CLLocationCoordinate2D(latitude: 47.6588, longitude: -117.4260)

    private func zone(active: Bool = true, radius: Double = 200,
                      watchSelf: Bool = true, watchContacts: Bool = true) -> Geofence {
        Geofence(name: "North gate", type: .circle, isActive: active,
                 watchSelf: watchSelf, watchContacts: watchContacts,
                 center: spokane, radius: radius)
    }

    private func makeService() throws -> (GeofenceService, GeofenceManager) {
        let name = "geofence-service-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let manager = GeofenceManager(defaults: defaults)
        let service = GeofenceService(manager: manager, defaults: defaults)
        service.start()
        return (service, manager)
    }

    func testNothingIsListenedToAndNothingTicksWithoutAGeofenceThatIsOn() throws {
        let (service, manager) = try makeService()
        XCTAssertEqual(service.activity, .idle, "starting is free when there are no geofences")
        manager.addGeofence(zone(active: false))
        XCTAssertEqual(service.activity, .idle, "a switched-off geofence needs nothing")
        manager.addGeofence(zone(radius: 0))
        XCTAssertEqual(service.activity, .idle, "nor does one with no shape")
    }

    func testAGeofenceThatIsOnStartsTheListeningAndTheTick() throws {
        let (service, manager) = try makeService()
        manager.addGeofence(zone())
        XCTAssertEqual(service.activity, GeofenceService.Activity(listensToOperator: true, listensToContacts: true, ticks: true))
    }

    func testSwitchingTheLastOneOffOrDeletingItStopsEverything() throws {
        let (service, manager) = try makeService()
        manager.addGeofence(zone())
        manager.addGeofence(zone())
        manager.toggleGeofence(manager.geofences[0])
        XCTAssertTrue(service.activity.ticks, "one is still on")
        manager.toggleGeofence(manager.geofences[1])
        XCTAssertEqual(service.activity, .idle, "the last one was switched off")
        manager.toggleGeofence(manager.geofences[1])
        XCTAssertTrue(service.activity.ticks, "switched back on")
        manager.deleteGeofence(manager.geofences[1])
        XCTAssertEqual(service.activity, .idle, "the one that was on is deleted")
    }

    func testItListensOnlyToWhoeverTheGeofencesWatch() throws {
        let (service, manager) = try makeService()
        manager.addGeofence(zone(watchSelf: true, watchContacts: false))
        XCTAssertEqual(service.activity, GeofenceService.Activity(listensToOperator: true, listensToContacts: false, ticks: true))
        manager.addGeofence(zone(watchSelf: false, watchContacts: true))
        XCTAssertEqual(service.activity, GeofenceService.Activity(listensToOperator: true, listensToContacts: true, ticks: true))
        manager.deleteGeofence(manager.geofences[0])
        XCTAssertEqual(service.activity, GeofenceService.Activity(listensToOperator: false, listensToContacts: true, ticks: true))
    }
}
