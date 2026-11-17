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
}
