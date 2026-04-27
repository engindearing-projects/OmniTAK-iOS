//
//  ATAKPluginParserTests.swift
//  OmniTAKMobileTests
//
//  Round-trip and decoding coverage for the portnum-72 ATAK plugin parser
//  and serializer.
//
//  NOTE: at the time of writing the iOS test target is not wired into
//  OmniTAKMobile.xcodeproj (existing Tests/*.swift files aren't either), so
//  this file lives alongside its peers but isn't compiled by xcodebuild.
//  Add it to the test target when one is configured.
//

import XCTest
@testable import OmniTAKMobile

final class ATAKPluginParserTests: XCTestCase {

    // MARK: - Round trip

    func testRoundTripCoTEvent() {
        let original = CoTEvent(
            uid: "ANDROID-deadbeef",
            type: "a-f-G-U-C",
            time: Date(timeIntervalSince1970: 1714000000),
            point: CoTPoint(lat: 47.6097, lon: -122.3331, hae: 42.0, ce: 9.5, le: 12.0),
            detail: CoTDetail(
                callsign: "BRAVO-1",
                team: "Cyan",
                speed: 5.5,
                course: 270.0,
                remarks: "Test remark",
                battery: 87,
                device: "Pixel 7",
                platform: "ATAK-CIV"
            )
        )

        let bytes = ATAKPluginSerializer.serialize(
            original,
            sendTime: original.time,
            startTime: original.time,
            staleTime: original.time.addingTimeInterval(60)
        )
        XCTAssertFalse(bytes.isEmpty, "serializer should produce bytes")

        guard let parsed = ATAKPluginParser.parse(bytes) else {
            return XCTFail("parser returned nil for serialized payload")
        }

        XCTAssertEqual(parsed.uid, original.uid)
        XCTAssertEqual(parsed.type, original.type)
        XCTAssertEqual(parsed.point.lat, original.point.lat, accuracy: 1e-9)
        XCTAssertEqual(parsed.point.lon, original.point.lon, accuracy: 1e-9)
        XCTAssertEqual(parsed.point.hae, original.point.hae, accuracy: 1e-9)
        XCTAssertEqual(parsed.point.ce, original.point.ce, accuracy: 1e-9)
        XCTAssertEqual(parsed.point.le, original.point.le, accuracy: 1e-9)

        XCTAssertEqual(parsed.detail.callsign, "BRAVO-1")
        XCTAssertEqual(parsed.detail.team, "Cyan")
        XCTAssertEqual(parsed.detail.battery, 87)
        XCTAssertEqual(parsed.detail.device, "Pixel 7")
        XCTAssertEqual(parsed.detail.platform, "ATAK-CIV")
        XCTAssertEqual(parsed.detail.speed, 5.5)
        XCTAssertEqual(parsed.detail.course, 270.0)
        XCTAssertEqual(parsed.detail.remarks, "Test remark")
    }

    /// Round-trip every widened CoTDetail field — this is the test the Phase 4
    /// merges asked for: prove the proto serializer/parser pair preserves the
    /// full TAK Detail submessage without dropping anything.
    func testRoundTripAllWidenedFields() {
        var detail = CoTDetail(
            callsign: "CHARLIE-2",
            team: "Cyan",
            speed: 3.4,
            course: 180.0,
            remarks: nil, // verify xmlDetail wins when both could be set
            battery: 78,
            device: "iPhone 15 Pro",
            platform: "OmniTAK"
        )
        detail.groupRole = "Squad Lead"
        detail.contactEndpoint = "*:-1:stcp"
        detail.takvOs = "iOS"
        detail.takvVersion = "2.0.0"
        detail.precisionGeopointSrc = "GPS"
        detail.precisionAltSrc = "DTED0"
        detail.xmlDetail = "<remarks>Raw passthrough</remarks>"

        let original = CoTEvent(
            uid: "OPS-omega",
            type: "a-f-G-U-C",
            time: Date(timeIntervalSince1970: 1714111111),
            point: CoTPoint(lat: 47.0, lon: -122.0, hae: 50.0, ce: 5.0, le: 5.0),
            detail: detail
        )

        let bytes = ATAKPluginSerializer.serialize(
            original,
            sendTime: original.time,
            startTime: original.time,
            staleTime: original.time.addingTimeInterval(60)
        )

        guard let parsed = ATAKPluginParser.parse(bytes) else {
            return XCTFail("parser returned nil for widened-fields payload")
        }

        XCTAssertEqual(parsed.detail.callsign, "CHARLIE-2")
        XCTAssertEqual(parsed.detail.team, "Cyan")
        XCTAssertEqual(parsed.detail.groupRole, "Squad Lead")
        XCTAssertEqual(parsed.detail.contactEndpoint, "*:-1:stcp")
        XCTAssertEqual(parsed.detail.takvOs, "iOS")
        XCTAssertEqual(parsed.detail.takvVersion, "2.0.0")
        XCTAssertEqual(parsed.detail.device, "iPhone 15 Pro")
        XCTAssertEqual(parsed.detail.platform, "OmniTAK")
        XCTAssertEqual(parsed.detail.precisionGeopointSrc, "GPS")
        XCTAssertEqual(parsed.detail.precisionAltSrc, "DTED0")
        XCTAssertEqual(parsed.detail.battery, 78)
        XCTAssertEqual(parsed.detail.speed, 3.4)
        XCTAssertEqual(parsed.detail.course, 180.0)
        XCTAssertEqual(parsed.detail.xmlDetail, "<remarks>Raw passthrough</remarks>")
        // groupName mirrors team for spec parity.
        XCTAssertEqual(parsed.detail.groupName, "Cyan")
    }

    /// Hand-crafted TAKMessage with a populated Group submessage —
    /// asserts the parser pulls both `name` and `role` into the typed
    /// CoTDetail fields directly.
    func testParseHandCraftedGroupNameAndRole() {
        // Build Detail submessage (field 15 of CoTEvent) with Group (field 2
        // of Detail). Group has name=field 1 and role=field 2.
        var group = Data()
        appendString(&group, field: 1, value: "Cyan")
        appendString(&group, field: 2, value: "Team Lead")

        var detail = Data()
        appendTag(&detail, field: 2, wire: 2)
        appendVarint(&detail, UInt64(group.count))
        detail.append(group)

        var cotEvent = Data()
        appendString(&cotEvent, field: 1, value: "a-f-G-U-C")
        appendString(&cotEvent, field: 5, value: "GROUP-TEST")
        // Detail at field 15
        appendTag(&cotEvent, field: 15, wire: 2)
        appendVarint(&cotEvent, UInt64(detail.count))
        cotEvent.append(detail)

        var takMessage = Data()
        appendTag(&takMessage, field: 2, wire: 2)
        appendVarint(&takMessage, UInt64(cotEvent.count))
        takMessage.append(cotEvent)

        guard let parsed = ATAKPluginParser.parse(takMessage) else {
            return XCTFail("parser failed on hand-crafted Group bytes")
        }
        XCTAssertEqual(parsed.detail.team, "Cyan")
        XCTAssertEqual(parsed.detail.groupName, "Cyan")
        XCTAssertEqual(parsed.detail.groupRole, "Team Lead")
    }

    // MARK: - Hand-crafted protobuf bytes

    func testParseHandCraftedTAKMessage() {
        // Build a TAKMessage with field 2 (cotEvent) containing:
        //   1: type = "a-f-G-U-C"
        //   5: uid  = "FOXTROT-7"
        //  10: lat  = 12.5 (double / fixed64)
        //  11: lon  = -67.25
        var cotEvent = Data()

        // 1: type, wire 2
        appendString(&cotEvent, field: 1, value: "a-f-G-U-C")
        // 5: uid
        appendString(&cotEvent, field: 5, value: "FOXTROT-7")
        // 10: lat (fixed64 / wire 1)
        appendTag(&cotEvent, field: 10, wire: 1)
        appendFixed64(&cotEvent, value: Double(12.5).bitPattern)
        // 11: lon
        appendTag(&cotEvent, field: 11, wire: 1)
        appendFixed64(&cotEvent, value: Double(-67.25).bitPattern)

        var takMessage = Data()
        appendTag(&takMessage, field: 2, wire: 2)
        appendVarint(&takMessage, UInt64(cotEvent.count))
        takMessage.append(cotEvent)

        guard let parsed = ATAKPluginParser.parse(takMessage) else {
            return XCTFail("parser failed on hand-crafted bytes")
        }
        XCTAssertEqual(parsed.uid, "FOXTROT-7")
        XCTAssertEqual(parsed.type, "a-f-G-U-C")
        XCTAssertEqual(parsed.point.lat, 12.5, accuracy: 1e-9)
        XCTAssertEqual(parsed.point.lon, -67.25, accuracy: 1e-9)
    }

    // MARK: - XML fallback

    func testParseRawXMLPayload() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <event version="2.0" uid="OPS-1" type="a-f-G-U-C" time="2026-04-25T12:00:00.000Z" start="2026-04-25T12:00:00.000Z" stale="2026-04-25T12:05:00.000Z" how="m-g">
            <point lat="44.0" lon="-93.0" hae="100" ce="9999" le="9999"/>
            <detail>
                <contact callsign="OPS-1"/>
            </detail>
        </event>
        """
        let data = Data(xml.utf8)
        guard let event = ATAKPluginParser.parse(data) else {
            return XCTFail("XML fallback parse returned nil")
        }
        XCTAssertEqual(event.uid, "OPS-1")
        XCTAssertEqual(event.type, "a-f-G-U-C")
        XCTAssertEqual(event.point.lat, 44.0, accuracy: 1e-9)
        XCTAssertEqual(event.point.lon, -93.0, accuracy: 1e-9)
        XCTAssertEqual(event.detail.callsign, "OPS-1")
    }

    // MARK: - Garbage rejection

    func testRejectsRandomBytes() {
        let junk = Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB])
        XCTAssertNil(ATAKPluginParser.parse(junk))
    }

    func testRejectsEmpty() {
        XCTAssertNil(ATAKPluginParser.parse(Data()))
    }

    // MARK: - Classification

    func testClassifyRoutesAtomToPositionUpdate() {
        let event = CoTEvent(
            uid: "X",
            type: "a-f-G-U-C",
            time: Date(),
            point: CoTPoint(lat: 0, lon: 0, hae: 0, ce: 0, le: 0),
            detail: CoTDetail(callsign: "X", team: nil, speed: nil, course: nil, remarks: nil, battery: nil, device: nil, platform: nil)
        )
        switch ATAKPluginParser.classify(event) {
        case .positionUpdate: break
        default: XCTFail("expected .positionUpdate for a-* type")
        }
    }

    func testClassifyRoutesWaypoint() {
        let event = CoTEvent(
            uid: "WP",
            type: "b-m-p-w",
            time: Date(),
            point: CoTPoint(lat: 0, lon: 0, hae: 0, ce: 0, le: 0),
            detail: CoTDetail(callsign: "WP", team: nil, speed: nil, course: nil, remarks: nil, battery: nil, device: nil, platform: nil)
        )
        switch ATAKPluginParser.classify(event) {
        case .waypoint: break
        default: XCTFail("expected .waypoint for b-m-p-w")
        }
    }

    // MARK: - ToRadio framing

    func testBuildToRadioWrapsPayload() {
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let bytes = ATAKPluginSerializer.buildToRadio(atakPayload: payload, to: 0xFFFFFFFF)
        XCTAssertGreaterThan(bytes.count, payload.count, "ToRadio should add framing overhead")
        // First byte must be ToRadio.packet tag (field 1, wire 2) = 0x0A.
        XCTAssertEqual(bytes.first, 0x0A)
    }

    // MARK: - Wire helpers (mirrors of serializer internals)

    private func appendTag(_ data: inout Data, field: Int, wire: UInt8) {
        appendVarint(&data, UInt64(field) << 3 | UInt64(wire))
    }

    private func appendVarint(_ data: inout Data, _ value: UInt64) {
        var v = value
        while v > 0x7F {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
    }

    private func appendFixed64(_ data: inout Data, value: UInt64) {
        for i in 0..<8 {
            data.append(UInt8((value >> (8 * i)) & 0xFF))
        }
    }

    private func appendString(_ data: inout Data, field: Int, value: String) {
        let bytes = Data(value.utf8)
        appendTag(&data, field: field, wire: 2)
        appendVarint(&data, UInt64(bytes.count))
        data.append(bytes)
    }
}
