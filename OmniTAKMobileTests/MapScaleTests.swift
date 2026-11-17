//
//  MapScaleTests.swift
//  OmniTAKMobileTests
//
//  The bottom-left scale readout used to print a rounded-up number that was not
//  the length of anything on screen. `MapScale.bar` now picks a 1, 2 or 5 x 10^n
//  distance that fits in the bar and returns the width that distance really
//  covers, so the line on screen IS the distance printed next to it.
//
//  Covers:
//    - no bar without a usable scale (nil / zero / negative / NaN / infinite)
//    - metric metres and kilometres, imperial feet and miles, the unit switches
//    - one decimal under 1 m / 1 ft, and no bar where one decimal cannot say it
//    - the bar never exceeds its room and never fills less than 40 % of it
//    - the bar is hidden when it would stand for more than 2,000 km
//    - ground truth: zoom 15 on the equator, 512 pt tiles
//    - the width times the scale is exactly the labelled distance
//    - the Mapbox engine's metres per point is the 512 pt tile formula
//    - the globe's camera event carries `mpp`, and a missing or null `mpp` is nil
//
//  Pure logic: no map view, no network.
//

import XCTest
import CoreGraphics
import CoreLocation
import JavaScriptCore
import MapboxMaps
@testable import OmniTAK

final class MapScaleTests: XCTestCase {

    private let room: CGFloat = 110
    private let mile = 1_609.344
    private let foot = 0.3048

    private func bar(_ mpp: Double?, _ unit: UnitSystem = .metric, room: CGFloat? = nil)
        -> (width: CGFloat, label: String)? {
        MapScale.bar(metersPerPoint: mpp, maxWidth: room ?? self.room, unitSystem: unit)
    }

    /// "500 m" / "2 km" / "500 ft" / "2 mi" / "0.5 m" back to metres.
    private func meters(fromLabel label: String) -> Double {
        let parts = label.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else {
            XCTFail("unreadable label \(label)")
            return .nan
        }
        switch parts[1] {
        case "m": return value
        case "km": return value * 1_000
        case "ft": return value * foot
        case "mi": return value * mile
        default:
            XCTFail("unknown unit in \(label)")
            return .nan
        }
    }

    // MARK: - No usable scale

    func testNoBarWithoutAUsableScale() {
        XCTAssertNil(bar(nil))
        XCTAssertNil(bar(0))
        XCTAssertNil(bar(-3, .imperial))
        XCTAssertNil(bar(.nan))
        XCTAssertNil(bar(.infinity))
        XCTAssertNil(bar(-.infinity, .imperial))
    }

    func testNoBarWithoutRoomToDrawIt() {
        XCTAssertNil(bar(5, room: 0))
        XCTAssertNil(bar(5, room: -20))
    }

    // MARK: - Metric

    func testMetricMetres() throws {
        // 1 m per point, 110 pt of room: 110 m fits, so a 100 m bar, 100 pt wide
        var b = try XCTUnwrap(bar(1))
        XCTAssertEqual(b.label, "100 m")
        XCTAssertEqual(Double(b.width), 100, accuracy: 0.0001)

        // 4 m per point: 440 m fits, 500 m does not, so 200 m, 50 pt
        b = try XCTUnwrap(bar(4))
        XCTAssertEqual(b.label, "200 m")
        XCTAssertEqual(Double(b.width), 50, accuracy: 0.0001)

        // 7 m per point: 770 m fits, so 500 m, 500 / 7 pt
        b = try XCTUnwrap(bar(7))
        XCTAssertEqual(b.label, "500 m")
        XCTAssertEqual(Double(b.width), 500.0 / 7.0, accuracy: 0.0001)
    }

    func testMetricKilometres() throws {
        // 30 m per point: 3.3 km fits, so 2 km
        var b = try XCTUnwrap(bar(30))
        XCTAssertEqual(b.label, "2 km")
        XCTAssertEqual(Double(b.width), 2_000.0 / 30.0, accuracy: 0.0001)

        // 60 m per point: 6.6 km fits, so 5 km
        b = try XCTUnwrap(bar(60))
        XCTAssertEqual(b.label, "5 km")
        XCTAssertEqual(Double(b.width), 5_000.0 / 60.0, accuracy: 0.0001)

        // 100 m per point: 11 km fits, so 10 km, 100 pt
        b = try XCTUnwrap(bar(100))
        XCTAssertEqual(b.label, "10 km")
        XCTAssertEqual(Double(b.width), 100, accuracy: 0.0001)
    }

    func testMetricSwitchesFromMetresToKilometresAtOneThousandMetres() throws {
        // 999 m of room is still metres: 500 m
        var b = try XCTUnwrap(bar(9.99, room: 100))
        XCTAssertEqual(b.label, "500 m")
        // 1,000 m of room is the first kilometre: 1 km fills it
        b = try XCTUnwrap(bar(10, room: 100))
        XCTAssertEqual(b.label, "1 km")
        XCTAssertEqual(Double(b.width), 100, accuracy: 0.0001)
    }

    // MARK: - Imperial

    func testImperialFeet() throws {
        // 650 ft of room: 500 ft
        let mpp = 6.5 * foot
        let b = try XCTUnwrap(bar(mpp, .imperial, room: 100))
        XCTAssertEqual(b.label, "500 ft")
        XCTAssertEqual(Double(b.width), 500 * foot / mpp, accuracy: 0.0001)
    }

    func testImperialMiles() throws {
        // 3 mi of room: 2 mi
        var mpp = 3 * mile / 100
        var b = try XCTUnwrap(bar(mpp, .imperial, room: 100))
        XCTAssertEqual(b.label, "2 mi")
        XCTAssertEqual(Double(b.width), 2 * mile / mpp, accuracy: 0.0001)

        // 1.2 mi of room: 1 mi
        mpp = 1.2 * mile / 100
        b = try XCTUnwrap(bar(mpp, .imperial, room: 100))
        XCTAssertEqual(b.label, "1 mi")
    }

    func testImperialSwitchesFromFeetToMilesAtOneMile() throws {
        // 0.99 mi of room is still feet: 5,000 ft
        var b = try XCTUnwrap(bar(0.99 * mile / 100, .imperial, room: 100))
        XCTAssertEqual(b.label, "5000 ft")
        // 1 mi of room is the first mile
        b = try XCTUnwrap(bar(mile / 100, .imperial, room: 100))
        XCTAssertEqual(b.label, "1 mi")
        XCTAssertEqual(Double(b.width), 100, accuracy: 0.0001)
    }

    // MARK: - Under one metre or one foot

    func testUnderOneMetreUsesOneDecimal() throws {
        // 0.7 m of room: 0.5 m
        var b = try XCTUnwrap(bar(0.007, room: 100))
        XCTAssertEqual(b.label, "0.5 m")
        XCTAssertEqual(Double(b.width), 0.5 / 0.007, accuracy: 0.0001)
        // 0.25 m of room: 0.2 m
        b = try XCTUnwrap(bar(0.0025, room: 100))
        XCTAssertEqual(b.label, "0.2 m")
    }

    func testNoBarWhereOneDecimalCannotSayTheDistance() {
        // 0.09 m of room would need a 0.05 m bar: "0.1" would be a lie, so no bar
        XCTAssertNil(bar(0.0009, room: 100))
        XCTAssertNil(bar(0.0001, .imperial, room: 100))
    }

    // MARK: - The bar always fits, and always fills at least 40 % of its room

    func testBarNeverExceedsItsRoomAndNeverFillsLessThanFortyPercent() {
        var checked = 0
        for unit in UnitSystem.allCases {
            for room in [60, 80, 110, 140] as [CGFloat] {
                var mpp = 0.01
                while mpp <= 20_000 {
                    guard let b = bar(mpp, unit, room: room) else {
                        return XCTFail("no bar at \(mpp) m/pt, room \(room), \(unit)")
                    }
                    XCTAssertLessThanOrEqual(b.width, room, "\(b.label) at \(mpp) m/pt, room \(room), \(unit)")
                    XCTAssertGreaterThanOrEqual(b.width, room * 0.4 - 1e-9,
                                                "\(b.label) at \(mpp) m/pt, room \(room), \(unit)")
                    checked += 1
                    mpp *= 1.013
                }
            }
        }
        XCTAssertGreaterThan(checked, 5_000, "the sweep must actually have run")
    }

    // MARK: - Too wide to mean anything

    func testHiddenWhenTheBarWouldStandForMoreThan2000Kilometres() throws {
        // 20,000 m/pt x 110 pt = 2,200 km of room: a 2,000 km bar is the limit and is shown
        let edge = try XCTUnwrap(bar(20_000))
        XCTAssertEqual(edge.label, "2000 km")
        // 50,000 m/pt x 110 pt = 5,500 km of room: a 5,000 km bar is too wide
        XCTAssertNil(bar(50_000))
        XCTAssertNil(bar(50_000, .imperial))
    }

    // MARK: - Ground truth

    func testGroundTruthZoom15OnTheEquatorWith512PointTiles() throws {
        let mpp = 40_075_016.686 / (512 * pow(2.0, 15))   // about 2.389 m per point
        let b = try XCTUnwrap(bar(mpp, .metric, room: 110))
        XCTAssertEqual(b.label, "200 m")
        // 200 m at 2.389 m per point is about 83.7 pt on screen
        let expectedWidth = 200 / mpp
        XCTAssertEqual(Double(b.width), expectedWidth, accuracy: 0.001)
        XCTAssertEqual(Double(b.width), 83.7, accuracy: 0.05)
    }

    func testWidthTimesScaleIsExactlyTheLabelledDistance() throws {
        for unit in UnitSystem.allCases {
            for mpp in [0.02, 0.9, 2.389, 8.46, 25.7, 310, 4_700, 19_000] {
                let b = try XCTUnwrap(bar(mpp, unit), "\(mpp) m/pt \(unit)")
                XCTAssertEqual(Double(b.width) * mpp, meters(fromLabel: b.label),
                               accuracy: meters(fromLabel: b.label) * 1e-6,
                               "\(b.label) at \(mpp) m/pt \(unit)")
            }
        }
    }

    // MARK: - Where the engines get their scale

    func testMapboxMetersPerPointIsThe512PointTileFormula() {
        // TacticalMapView feeds the bar Projection.metersPerPoint at the camera centre.
        // That is cos(lat) * circumference / (512 * 2^zoom): 512 pt tiles, so a wrong
        // tile size (a factor of 2) or zoom convention fails here. The SDK takes the
        // circumference from the mean Earth radius, which is 0.11 % under the
        // equatorial one the formula uses, hence the 0.2 % tolerance.
        for (lat, zoom) in [(0.0, 15.0), (38.9, 12.8), (47.66, 10.0), (-33.9, 17.5)] {
            let sdk = Projection.metersPerPoint(for: lat, zoom: CGFloat(zoom))
            let formula = cos(lat * .pi / 180) * 40_075_016.686 / (512 * pow(2.0, zoom))
            XCTAssertEqual(sdk, formula, accuracy: formula * 0.002, "lat \(lat) zoom \(zoom)")
        }
    }

    private func decodeCamera(_ json: String) throws -> CesiumMainMap.Coordinator.MapEventPayload {
        try JSONDecoder().decode(CesiumMainMap.Coordinator.MapEventPayload.self, from: Data(json.utf8))
    }

    func testGlobeCameraEventCarriesMetersPerPoint() throws {
        let p = try decodeCamera(#"""
        {"event":"camerachanged","lat":47.6,"lon":-117.4,"height":20000,"heading":0,"pitch":-90,
         "zoom":11.5,"centerLat":47.6,"centerLon":-117.4,"mpp":25.7}
        """#)
        XCTAssertEqual(p.mpp, 25.7)
    }

    func testGlobeCameraEventWithNullOrMissingMetersPerPointIsNil() throws {
        // null = a sample point missed the globe (horizon, space); the bar is then hidden
        let null = try decodeCamera(#"""
        {"event":"camerachanged","lat":47.6,"lon":-117.4,"height":20000,"heading":0,"pitch":-90,
         "zoom":11.5,"mpp":null}
        """#)
        XCTAssertNil(null.mpp)
        let missing = try decodeCamera(#"""
        {"event":"camerachanged","lat":47.6,"lon":-117.4,"height":20000,"heading":0,"pitch":-90,"zoom":11.5}
        """#)
        XCTAssertNil(missing.mpp)
    }

    // MARK: - Where the bar is measured: its own row, not the screen center
    //
    // The bar sits in the bottom-left corner. On a tilted view the ground there is
    // nearer the camera than the ground at the center, so a scale taken at the
    // center makes the bar read long for the ground it lies on. The rule: the
    // ground distance between the two screen points 50 pt either side of the
    // scale anchor (the middle of the bar's maximum width, on the bar line's row),
    // divided by the real distance between those points.

    private let phone = CGSize(width: 402, height: 874)

    func testSamplePointsAreFiftyPointsEitherSideOfTheAnchorOnItsRow() throws {
        let s = try XCTUnwrap(MapScale.sample(anchor: CGPoint(x: 74, y: 614), mapSize: phone))
        XCTAssertEqual(s.left, CGPoint(x: 24, y: 614))
        XCTAssertEqual(s.right, CGPoint(x: 124, y: 614))
        XCTAssertEqual(s.span, 100)
    }

    func testWithoutAnAnchorTheSamplesAreAtTheScreenCenter() throws {
        let s = try XCTUnwrap(MapScale.sample(anchor: nil, mapSize: phone))
        XCTAssertEqual(s.left, CGPoint(x: 151, y: 437))
        XCTAssertEqual(s.right, CGPoint(x: 251, y: 437))
        XCTAssertEqual(s.span, 100)
    }

    func testAnchorNearTheLeftEdgeKeepsBothPointsOnScreenAndTheRealSpan() throws {
        // x - 50 would be -30: the left point stops at the edge, the span is what is left
        let s = try XCTUnwrap(MapScale.sample(anchor: CGPoint(x: 20, y: 700), mapSize: phone))
        XCTAssertEqual(s.left, CGPoint(x: 0, y: 700))
        XCTAssertEqual(s.right, CGPoint(x: 70, y: 700))
        XCTAssertEqual(s.span, 70)
    }

    func testAnchorNearTheRightEdgeKeepsBothPointsOnScreenAndTheRealSpan() throws {
        let s = try XCTUnwrap(MapScale.sample(anchor: CGPoint(x: 390, y: 700), mapSize: phone))
        XCTAssertEqual(s.left, CGPoint(x: 340, y: 700))
        XCTAssertEqual(s.right, CGPoint(x: 402, y: 700))
        XCTAssertEqual(s.span, 62)
    }

    func testAnchorOutsideTheMapIsPulledOntoIt() throws {
        // a bar that has moved while the map has not resized yet (rotation): never a point off the map
        let s = try XCTUnwrap(MapScale.sample(anchor: CGPoint(x: -30, y: 900), mapSize: phone))
        XCTAssertEqual(s.left, CGPoint(x: 0, y: 874))
        XCTAssertEqual(s.right, CGPoint(x: 50, y: 874))
        XCTAssertEqual(s.span, 50)
    }

    func testEverySamplePointStaysOnTheMapWhateverTheAnchor() throws {
        for size in [phone, CGSize(width: 874, height: 402), CGSize(width: 1032, height: 1376)] {
            for x in stride(from: CGFloat(-80), through: size.width + 80, by: 17) {
                for y in stride(from: CGFloat(-80), through: size.height + 80, by: 53) {
                    let s = try XCTUnwrap(MapScale.sample(anchor: CGPoint(x: x, y: y), mapSize: size))
                    XCTAssertTrue(s.left.x >= 0 && s.right.x <= size.width, "x \(x) y \(y) in \(size)")
                    XCTAssertTrue(s.left.y >= 0 && s.left.y <= size.height, "x \(x) y \(y) in \(size)")
                    XCTAssertEqual(s.left.y, s.right.y, "both points are on one row")
                    XCTAssertGreaterThan(s.span, 0)
                    XCTAssertLessThanOrEqual(s.span, 100)
                }
            }
        }
    }

    func testNoSampleOnAnEmptyMap() {
        XCTAssertNil(MapScale.sample(anchor: CGPoint(x: 74, y: 614), mapSize: .zero))
        XCTAssertNil(MapScale.sample(anchor: nil, mapSize: CGSize(width: 0, height: 874)))
        XCTAssertNil(MapScale.sample(anchor: nil, mapSize: CGSize(width: 402, height: 0)))
    }

    func testNoSampleFromAnAnchorThatIsNotANumber() {
        XCTAssertNil(MapScale.sample(anchor: CGPoint(x: CGFloat.nan, y: 614), mapSize: phone))
        XCTAssertNil(MapScale.sample(anchor: CGPoint(x: 74, y: CGFloat.infinity), mapSize: phone))
    }

    func testMetersPerPointDividesByTheRealSpanNotByOneHundred() throws {
        let full = try XCTUnwrap(MapScale.sample(anchor: CGPoint(x: 74, y: 614), mapSize: phone))
        XCTAssertEqual(try XCTUnwrap(MapScale.metersPerPoint(groundDistance: 250, over: full)), 2.5, accuracy: 1e-12)
        // the same ground at the left edge covers 70 pt: 250 m over 70 pt, not over 100
        let clamped = try XCTUnwrap(MapScale.sample(anchor: CGPoint(x: 20, y: 614), mapSize: phone))
        XCTAssertEqual(try XCTUnwrap(MapScale.metersPerPoint(groundDistance: 250, over: clamped)), 250.0 / 70.0, accuracy: 1e-12)
    }

    func testNoScaleWithoutAnHonestGroundDistance() throws {
        let s = try XCTUnwrap(MapScale.sample(anchor: nil, mapSize: phone))
        XCTAssertNil(MapScale.metersPerPoint(groundDistance: nil, over: s))
        XCTAssertNil(MapScale.metersPerPoint(groundDistance: 0, over: s))
        XCTAssertNil(MapScale.metersPerPoint(groundDistance: -4, over: s))
        XCTAssertNil(MapScale.metersPerPoint(groundDistance: .nan, over: s))
        XCTAssertNil(MapScale.metersPerPoint(groundDistance: .infinity, over: s))
    }

    /// A made-up tilted camera: the nearer the bottom of the screen, the fewer metres each point covers.
    /// 4 m per point at the top of a 874 pt map, 1 m per point at the bottom, linear in between.
    private func tiltedGround(_ a: CGPoint, _ b: CGPoint) -> Double? {
        guard a.y == b.y else { return nil }
        let metresPerPoint = 4.0 - 3.0 * Double(a.y) / 874.0
        return metresPerPoint * Double(b.x - a.x)
    }

    func testOnATiltedViewTheBarsRowAndTheScreenCenterGiveDifferentScales() throws {
        let atBar = try XCTUnwrap(MapScale.metersPerPoint(
            anchor: CGPoint(x: 74, y: 614), mapSize: phone, fallback: { nil }, groundDistance: tiltedGround))
        let atCenter = try XCTUnwrap(MapScale.metersPerPoint(
            anchor: CGPoint(x: 201, y: 437), mapSize: phone, fallback: { nil }, groundDistance: tiltedGround))
        XCTAssertEqual(atBar, 4.0 - 3.0 * 614.0 / 874.0, accuracy: 1e-9)
        XCTAssertEqual(atCenter, 2.5, accuracy: 1e-9)
        // By design: a line measured across the middle of a tilted screen does NOT match the bar,
        // because the bar is true for the ground it is drawn over. Do not "fix" this back to the center.
        XCTAssertGreaterThan(abs(atBar - atCenter) / atBar, 0.2)
    }

    func testUntilAnAnchorIsKnownTheFallbackScaleIsUsedAndNothingIsMeasured() throws {
        var measured = false
        let value = MapScale.metersPerPoint(anchor: nil, mapSize: phone, fallback: { 3.25 }, groundDistance: { _, _ in
            measured = true
            return 1
        })
        XCTAssertEqual(value, 3.25)
        XCTAssertFalse(measured)
    }

    func testOnceAnAnchorIsKnownTheFallbackIsNeverUsed() throws {
        let value = MapScale.metersPerPoint(anchor: CGPoint(x: 74, y: 614), mapSize: phone,
                                            fallback: { 99 }, groundDistance: { a, b in Double(b.x - a.x) * 2 })
        XCTAssertEqual(try XCTUnwrap(value), 2, accuracy: 1e-12)
    }

    func testNoScaleWhenEitherPointIsNotOnTheGround() {
        // above the horizon, off the globe: the engine has no distance, the bar is hidden (not the fallback)
        XCTAssertNil(MapScale.metersPerPoint(anchor: CGPoint(x: 74, y: 614), mapSize: phone,
                                             fallback: { 99 }, groundDistance: { _, _ in nil }))
    }

    func testNoScaleWhenTheMapHasNoSizeYetEvenWithAnAnchor() {
        XCTAssertNil(MapScale.metersPerPoint(anchor: CGPoint(x: 74, y: 614), mapSize: .zero,
                                             fallback: { 99 }, groundDistance: { a, b in Double(b.x - a.x) }))
    }

    func testTheMeasuredPointsAreTheClampedOnesAndTheDivisorTheirRealDistance() throws {
        var seen: (CGPoint, CGPoint)?
        let value = MapScale.metersPerPoint(anchor: CGPoint(x: 20, y: 700), mapSize: phone,
                                            fallback: { nil }, groundDistance: { a, b in
            seen = (a, b)
            return 140   // metres between them
        })
        XCTAssertEqual(seen?.0, CGPoint(x: 0, y: 700))
        XCTAssertEqual(seen?.1, CGPoint(x: 70, y: 700))
        XCTAssertEqual(try XCTUnwrap(value), 2, accuracy: 1e-12)   // 140 m over 70 pt
    }

    // MARK: - The anchor comes from the bar's own frame

    func testAnchorIsTheMiddleOfTheBarRowOnTheBarLine() {
        // the bar row: 116 pt wide (110 + two 3 pt ticks), 9 pt tall, line drawn 1 pt up from the bottom
        let row = CGRect(x: 16, y: 600, width: 116, height: 9)
        let map = CGRect(x: 0, y: 0, width: 402, height: 874)
        XCTAssertEqual(MapScale.anchor(barRow: row, in: map, baselineInset: 1), CGPoint(x: 74, y: 608))
    }

    func testAnchorIsInTheMapsOwnSpaceWhateverWhereTheMapIs() {
        // both frames are measured in one space; the map need not start at its origin
        let row = CGRect(x: 26, y: 620, width: 116, height: 9)
        let map = CGRect(x: 10, y: 20, width: 874, height: 402)
        // 26 + 58 - 10 across, 620 + 9 - 1 - 20 down
        XCTAssertEqual(MapScale.anchor(barRow: row, in: map, baselineInset: 1), CGPoint(x: 74, y: 608))
    }

    // MARK: - Mapbox measures the 2D map where the bar is

    func testOnAnUnpitchedMapTheMeasuredScaleIsTheTileFormula() throws {
        let lat = 47.66
        let mapView = MapView(
            frame: CGRect(origin: .zero, size: phone),
            mapInitOptions: MapInitOptions(
                cameraOptions: CameraOptions(center: CLLocationCoordinate2D(latitude: lat, longitude: -117.43),
                                             zoom: 14, bearing: 0, pitch: 0)))
        let measured = try XCTUnwrap(MapScale.metersPerPoint(
            anchor: CGPoint(x: 74, y: 614), mapSize: mapView.bounds.size,
            fallback: { nil }, groundDistance: TacticalMapView.groundDistance(on: mapView.mapboxMap)))
        let formula = Projection.metersPerPoint(for: lat, zoom: 14)
        // flat map: the row 177 pt below the center is 0.4 % off the center's Mercator scale at most
        XCTAssertEqual(measured, formula, accuracy: formula * 0.005)
    }

    // MARK: - The globe uses the same rule

    func testGlobeSamplePointsFollowTheSameRuleAsTheNativeOnes() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(try globeSampleFunction())
        let cases: [(CGPoint?, CGSize)] = [
            (CGPoint(x: 74, y: 614), phone),
            (nil, phone),
            (CGPoint(x: 20, y: 700), phone),
            (CGPoint(x: 390, y: 700), phone),
            (CGPoint(x: -30, y: 900), phone),
            (CGPoint(x: 74, y: 300), CGSize(width: 874, height: 402)),
            (CGPoint(x: 5, y: 5), CGSize(width: 30, height: 30)),
        ]
        for (anchor, size) in cases {
            let jsAnchor: Any = anchor.map { ["x": Double($0.x), "y": Double($0.y)] } ?? NSNull()
            let result = try XCTUnwrap(
                context.objectForKeyedSubscript("_scaleSample")
                    .call(withArguments: [jsAnchor, size.width, size.height]),
                "\(String(describing: anchor)) in \(size)")
            let native = try XCTUnwrap(MapScale.sample(anchor: anchor, mapSize: size))
            XCTAssertEqual(result.forProperty("x0").toDouble(), Double(native.left.x), "\(String(describing: anchor)) in \(size)")
            XCTAssertEqual(result.forProperty("x1").toDouble(), Double(native.right.x), "\(String(describing: anchor)) in \(size)")
            XCTAssertEqual(result.forProperty("y").toDouble(), Double(native.left.y), "\(String(describing: anchor)) in \(size)")
        }
        let empty = try XCTUnwrap(context.objectForKeyedSubscript("_scaleSample")
            .call(withArguments: [NSNull(), 0, 874]))
        XCTAssertTrue(empty.isNull, "no sample on a canvas with no width")
    }

    /// The page's `_scaleSample`, cut out of the bundled scene between its two marker comments.
    private func globeSampleFunction() throws -> String {
        let html = CesiumMainMap.html
        let begin = try XCTUnwrap(html.range(of: "// SCALE-SAMPLE-BEGIN"), "marker missing from cesium_scene.html")
        let end = try XCTUnwrap(html.range(of: "// SCALE-SAMPLE-END"), "marker missing from cesium_scene.html")
        // the function starts on the line after the BEGIN comment
        let start = try XCTUnwrap(html[begin.upperBound...].firstIndex(of: "\n"))
        return String(html[start..<end.lowerBound])
    }

    func testTheBridgeCallThatSetsTheAnchor() {
        XCTAssertEqual(CesiumMainMap.scaleAnchorJS(CGPoint(x: 74, y: 614)),
                       "window.OmniBridge.setScaleAnchor(74.0,614.0);")
        XCTAssertEqual(CesiumMainMap.scaleAnchorJS(CGPoint(x: 74.26, y: 613.54)),
                       "window.OmniBridge.setScaleAnchor(74.3,613.5);")
        XCTAssertEqual(CesiumMainMap.scaleAnchorJS(nil),
                       "window.OmniBridge.setScaleAnchor(null,null);")
    }

    // MARK: - On flat ground a row has one scale, the bar's, in portrait and in landscape

    func testOnAPitchedFlatMapEveryPointOnTheBarsRowHasTheBarsScaleAndTheCenterDoesNot() throws {
        // The app's 2D map opens pitched at 60 degrees. The bar sits low on the screen, so on a
        // map with no hills the scale along its row is one number (the bar's), and the scale
        // at the middle of the screen, where the old bar was measured, is a quite different one.
        // With terrain a row's scale also follows the hills under it, which a unit test has none of.
        let portrait = CGSize(width: 402, height: 874)
        let landscape = CGSize(width: 874, height: 402)
        for (size, anchor) in [(portrait, CGPoint(x: 74, y: 648)), (landscape, CGPoint(x: 136, y: 291))] {
            let mapView = MapView(
                frame: CGRect(origin: .zero, size: size),
                mapInitOptions: MapInitOptions(
                    cameraOptions: CameraOptions(center: CLLocationCoordinate2D(latitude: 38.9, longitude: -77.0365),
                                                 zoom: 12.8, bearing: 0, pitch: 60)))
            let ground = TacticalMapView.groundDistance(on: mapView.mapboxMap)
            let bar = try XCTUnwrap(MapScale.metersPerPoint(
                anchor: anchor, mapSize: size, fallback: { nil }, groundDistance: ground), "\(size)")

            // a line drawn anywhere along the bar's row measures the bar's scale
            for (x0, x1) in [(12.0, 68.0), (118.0, 148.0), (Double(size.width) - 120, Double(size.width) - 20)] {
                let meters = try XCTUnwrap(ground(CGPoint(x: x0, y: anchor.y), CGPoint(x: x1, y: anchor.y)))
                XCTAssertEqual(meters / (x1 - x0), bar, accuracy: bar * 0.01, "x \(x0) to \(x1) in \(size)")
            }

            // across the middle of the screen the ground is farther away: that scale is not the bar's
            let center = try XCTUnwrap(MapScale.metersPerPoint(
                anchor: CGPoint(x: size.width / 2, y: size.height / 2), mapSize: size,
                fallback: { nil }, groundDistance: ground))
            XCTAssertGreaterThan(center / bar, 1.15, "the old bar would have read this much long in \(size)")
        }
    }
}
