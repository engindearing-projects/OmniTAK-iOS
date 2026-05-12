//
//  DrawingCoTTests.swift
//  OmniTAKMobileTests
//
//  Cross-platform parity tests for DrawingCoT. The expected wire
//  format here is byte-compatible with what Android
//  `app/src/test/.../DrawingCoTTest.kt` asserts, so a drawing
//  serialised by either platform round-trips through the other.
//

import XCTest
import CoreLocation
@testable import OmniTAKMobile

final class DrawingCoTTests: XCTestCase {

    let seattle = CLLocationCoordinate2D(latitude: 47.6062, longitude: -122.3321)
    // ~1000 m due north of Seattle (1 minute of latitude ≈ 1.85 km, so
    // 0.009° is in the right ballpark for a ~1 km separation).
    let edge = CLLocationCoordinate2D(latitude: 47.6152, longitude: -122.3321)
    let fixedDate = Date(timeIntervalSince1970: 1_778_516_000)

    // MARK: - Line / polygon

    func testLineEnvelopeIncludesRequiredAttrs() {
        let xml = DrawingCoT.buildLine(
            uid: "draw-1",
            callsign: "Engie",
            points: [
                seattle,
                CLLocationCoordinate2D(latitude: 47.61, longitude: -122.30),
                CLLocationCoordinate2D(latitude: 47.60, longitude: -122.28),
            ],
            closed: false,
            colorHex: "#FF8800",
            now: fixedDate
        )
        XCTAssertTrue(xml.contains("<event "))
        XCTAssertTrue(xml.contains("type=\"u-d-f\""))
        XCTAssertTrue(xml.contains("uid=\"draw-1\""))
        XCTAssertTrue(xml.contains("callsign=\"Engie\""))
        XCTAssertTrue(xml.contains("uid=\"draw-1-v0\""))
        XCTAssertTrue(xml.contains("uid=\"draw-1-v2\""))
        XCTAssertFalse(xml.contains("closed_polygon=\"1\""))
    }

    func testPolygonClosesRingAndSetsClosedFlag() {
        let xml = DrawingCoT.buildLine(
            uid: "poly-1",
            callsign: "Engie",
            points: [
                seattle,
                CLLocationCoordinate2D(latitude: 47.61, longitude: -122.30),
                CLLocationCoordinate2D(latitude: 47.60, longitude: -122.28),
            ],
            closed: true,
            now: fixedDate
        )
        XCTAssertTrue(xml.contains("closed_polygon=\"1\""))
        XCTAssertTrue(xml.contains("uid=\"poly-1-v3\""))
        XCTAssertTrue(xml.contains("point=\"47.6062,-122.3321,0.0\""))
    }

    // MARK: - Circle

    func testCircleEmitsExpectedEnvelope() {
        let xml = DrawingCoT.buildCircle(
            uid: "circ-1",
            callsign: "Engie",
            center: seattle,
            radiusM: 500,
            now: fixedDate
        )
        XCTAssertTrue(xml.contains("type=\"u-d-c-c\""))
        XCTAssertTrue(xml.contains("<ellipse minor="))
        XCTAssertTrue(xml.contains("radius=500"))
    }

    // MARK: - Bullseye

    func testBullseyeEmitsOneEventPerDefaultRing() {
        let xmls = DrawingCoT.buildBullseye(
            baseUid: "bull-1",
            callsign: "Engie",
            center: seattle,
            now: fixedDate
        )
        XCTAssertEqual(xmls.count, 3, "default bullseye = 100 / 500 / 1000 m")
        xmls.forEach { XCTAssertTrue($0.contains("group=\"bull-1\"")) }
        XCTAssertTrue(xmls[0].contains("uid=\"bull-1-ring1\""))
        XCTAssertTrue(xmls[2].contains("uid=\"bull-1-ring3\""))
        XCTAssertTrue(xmls[0].contains("radius=100"))
        XCTAssertTrue(xmls[2].contains("radius=1000"))
    }

    func testBullseyeHonoursCustomRadii() {
        let xmls = DrawingCoT.buildBullseye(
            baseUid: "bull-2",
            callsign: "Engie",
            center: seattle,
            radiiM: [250, 2_000],
            now: fixedDate
        )
        XCTAssertEqual(xmls.count, 2)
        XCTAssertTrue(xmls[0].contains("radius=250"))
        XCTAssertTrue(xmls[1].contains("radius=2000"))
    }

    func testBullseyeWithEmptyRadiiYieldsNoEvents() {
        let xmls = DrawingCoT.buildBullseye(
            baseUid: "x",
            callsign: "Engie",
            center: seattle,
            radiiM: [0, -1],
            now: fixedDate
        )
        XCTAssertTrue(xmls.isEmpty)
    }

    // MARK: - Round-trip parsing

    func testRoundTripLine() {
        let points = [
            seattle,
            CLLocationCoordinate2D(latitude: 47.6100, longitude: -122.3300),
            CLLocationCoordinate2D(latitude: 47.6200, longitude: -122.3200),
        ]
        let xml = DrawingCoT.buildLine(
            uid: "draw-2",
            callsign: "Engie",
            points: points,
            closed: false,
            colorHex: "#FF8800",
            now: fixedDate
        )
        guard let parsed = DrawingCoT.parse(xml) else {
            XCTFail("parse returned nil"); return
        }
        XCTAssertEqual(parsed.kind, .line)
        XCTAssertEqual(parsed.points.count, points.count)
        for (a, b) in zip(points, parsed.points) {
            XCTAssertEqual(a.latitude, b.latitude, accuracy: 1e-6)
            XCTAssertEqual(a.longitude, b.longitude, accuracy: 1e-6)
        }
    }

    func testRoundTripPolygonDropsClosingDuplicate() {
        let points = [
            seattle,
            CLLocationCoordinate2D(latitude: 47.6100, longitude: -122.3300),
            CLLocationCoordinate2D(latitude: 47.6200, longitude: -122.3200),
        ]
        let xml = DrawingCoT.buildLine(
            uid: "poly-2",
            callsign: "Engie",
            points: points,
            closed: true,
            now: fixedDate
        )
        guard let parsed = DrawingCoT.parse(xml) else {
            XCTFail("parse returned nil"); return
        }
        XCTAssertEqual(parsed.kind, .polygon)
        XCTAssertEqual(parsed.points.count, points.count,
                       "closing duplicate stripped")
    }

    func testRoundTripCircleRecoversRadiusWithin1m() {
        let xml = DrawingCoT.buildCircle(
            uid: "circ-2",
            callsign: "Engie",
            center: seattle,
            radiusM: 1_000.0,
            now: fixedDate
        )
        guard let parsed = DrawingCoT.parse(xml) else {
            XCTFail("parse returned nil"); return
        }
        XCTAssertEqual(parsed.kind, .circle)
        guard let r = parsed.radiusM else { XCTFail("missing radius"); return }
        XCTAssertEqual(r, 1_000.0, accuracy: 1.0)
        XCTAssertEqual(parsed.points.first?.latitude ?? 0, seattle.latitude, accuracy: 1e-6)
    }

    func testParseReturnsNilForNonDrawingEvent() {
        let markerXml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <event version="2.0" uid="m-1" type="a-f-G-U-C" time="now" start="now" stale="later" how="h-g">
          <point lat="47.6062" lon="-122.3321" hae="0" ce="9999999.0" le="9999999.0"/>
          <detail><contact callsign="MyPos-1432"/></detail>
        </event>
        """
        XCTAssertNil(DrawingCoT.parse(markerXml))
        XCTAssertFalse(DrawingCoT.isDrawingCoT(markerXml))
    }

    // MARK: - Colour conversion

    func testHexARGBRoundTrip() {
        let argb = DrawingCoT.hexToARGB("#FF8800")
        let hex = DrawingCoT.argbToHex(argb)
        XCTAssertEqual(hex, "#FFFF8800")
    }
}
