//
//  OpenDroneIdParserTests.swift
//  OmniTAKMobileTests
//
//  XCTest mirror of the Android `OpenDroneIdParserTest`. Same
//  synthetic byte vectors, same assertions — both clients must
//  decode the wire format identically.
//

import XCTest
@testable import OmniTAK

final class OpenDroneIdParserTests: XCTestCase {

    // MARK: - Frame builders

    private func basicIdFrame(
        version: Int = 1,
        idType: Int = OpenDroneIdMessage.IdType.serialNumber.rawValue,
        uaType: Int = OpenDroneIdMessage.UaType.helicopterOrMultirotor.rawValue,
        uasId: String = "DJI-MAVIC3-12345678X"
    ) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: OpenDroneIdMessage.messageTotalBytes)
        buf[0] = UInt8((OpenDroneIdMessage.MessageType.basicId.rawValue << 4) | (version & 0xF))
        buf[1] = UInt8(((idType & 0xF) << 4) | (uaType & 0xF))
        let idBytes = Array(uasId.utf8).prefix(20)
        for (i, b) in idBytes.enumerated() {
            buf[2 + i] = b
        }
        return buf
    }

    private func locationFrame(
        version: Int = 1,
        latitude: Double = 47.6588,
        longitude: Double = -117.4260,
        geodeticAltM: Double? = 700.0,
        trackDeg: Int = 90,
        groundSpeedMs: Double = 10.0,
        operationalStatus: Int = OpenDroneIdMessage.OperationalStatus.airborne.rawValue
    ) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: OpenDroneIdMessage.messageTotalBytes)
        buf[0] = UInt8((OpenDroneIdMessage.MessageType.location.rawValue << 4) | (version & 0xF))

        let ewSegment = trackDeg >= 180 ? 1 : 0
        let sm = 0
        buf[1] = UInt8(((operationalStatus & 0xF) << 4) | (ewSegment << 1) | sm)

        buf[2] = UInt8(trackDeg >= 180 ? trackDeg - 180 : trackDeg)
        // SM=0 → byte = speed / 0.25
        buf[3] = UInt8(Int(groundSpeedMs / 0.25))
        buf[4] = 0 // vertical speed

        let latRaw = Int32(latitude * 1e7)
        writeInt32LE(&buf, offset: 5, value: latRaw)
        let lonRaw = Int32(longitude * 1e7)
        writeInt32LE(&buf, offset: 9, value: lonRaw)

        if let alt = geodeticAltM {
            let rawAlt = Int((alt + 1000.0) / 0.5)
            writeUInt16LE(&buf, offset: 15, value: rawAlt)
        }

        // Timestamp sentinel
        buf[22] = 0xFF
        buf[23] = 0xFF
        return buf
    }

    private func writeInt32LE(_ buf: inout [UInt8], offset: Int, value: Int32) {
        let u = UInt32(bitPattern: value)
        buf[offset]     = UInt8(u         & 0xFF)
        buf[offset + 1] = UInt8((u >> 8)  & 0xFF)
        buf[offset + 2] = UInt8((u >> 16) & 0xFF)
        buf[offset + 3] = UInt8((u >> 24) & 0xFF)
    }

    private func writeUInt16LE(_ buf: inout [UInt8], offset: Int, value: Int) {
        buf[offset]     = UInt8(value & 0xFF)
        buf[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private func messagePack(_ messages: [[UInt8]]) -> [UInt8] {
        let single = OpenDroneIdMessage.messageTotalBytes
        var buf = [UInt8](repeating: 0, count: 3 + messages.count * single)
        buf[0] = UInt8((OpenDroneIdMessage.MessageType.messagePack.rawValue << 4) | 1)
        buf[1] = UInt8(single)
        buf[2] = UInt8(messages.count)
        for (i, msg) in messages.enumerated() {
            for (j, b) in msg.enumerated() {
                buf[3 + i * single + j] = b
            }
        }
        return buf
    }

    /// Prepend the OpenDroneID app code (0x0D) + counter (0x00) to
    /// a message payload to simulate `ScanRecord.getServiceData(…)`.
    private func serviceData(_ payload: [UInt8]) -> [UInt8] {
        [0x0D, 0x00] + payload
    }

    // MARK: - Basic ID

    func testBasicIdDecodesUasIdAndUaType() throws {
        let frame = basicIdFrame(uasId: "DJI-MAVIC3-12345")
        let msg = OpenDroneIdParser.parseMessage(frame)
        guard case let .basicId(_, idType, uaType, uasId) = msg else {
            return XCTFail("expected basicId, got \(String(describing: msg))")
        }
        XCTAssertEqual("DJI-MAVIC3-12345", uasId)
        XCTAssertEqual(.serialNumber, idType)
        XCTAssertEqual(.helicopterOrMultirotor, uaType)
    }

    func testBasicIdTrimsNullPaddingFromShortIds() throws {
        let frame = basicIdFrame(uasId: "ABC123")
        let msg = OpenDroneIdParser.parseMessage(frame)
        guard case let .basicId(_, _, _, uasId) = msg else {
            return XCTFail("expected basicId")
        }
        XCTAssertEqual("ABC123", uasId)
    }

    func testBasicIdMapsFixedWingUaType() throws {
        let frame = basicIdFrame(uaType: OpenDroneIdMessage.UaType.aeroplane.rawValue)
        guard case let .basicId(_, _, uaType, _) = OpenDroneIdParser.parseMessage(frame) else {
            return XCTFail()
        }
        XCTAssertEqual(.aeroplane, uaType)
    }

    // MARK: - Location

    func testLocationDecodesLatLonToSevenDecimals() throws {
        let frame = locationFrame(latitude: 47.6588, longitude: -117.4260)
        guard case let .location(loc) = OpenDroneIdParser.parseMessage(frame) else {
            return XCTFail()
        }
        XCTAssertEqual(47.6588, loc.latitude, accuracy: 0.0000001)
        XCTAssertEqual(-117.4260, loc.longitude, accuracy: 0.0000001)
        XCTAssertTrue(loc.hasValidPosition)
    }

    func testLocationDecodesTrackDirectionInUpperHalfByAdding180() throws {
        let frame = locationFrame(trackDeg: 270)
        guard case let .location(loc) = OpenDroneIdParser.parseMessage(frame) else {
            return XCTFail()
        }
        XCTAssertEqual(270, loc.trackDirectionDeg)
    }

    func testLocationDecodesGroundSpeedAtQuarterMpsMultiplier() throws {
        let frame = locationFrame(groundSpeedMs: 10.0)
        guard case let .location(loc) = OpenDroneIdParser.parseMessage(frame) else {
            return XCTFail()
        }
        XCTAssertEqual(10.0, loc.groundSpeedMs, accuracy: 0.001)
    }

    func testLocationDecodesGeodeticAltitudeWithOffsetAndHalfMetreScaling() throws {
        let frame = locationFrame(geodeticAltM: 700.0)
        guard case let .location(loc) = OpenDroneIdParser.parseMessage(frame) else {
            return XCTFail()
        }
        XCTAssertEqual(700.0, loc.geodeticAltitudeM ?? -999, accuracy: 0.5)
    }

    func testLocationFlagsInvalidPositionWhenBothCoordsZero() throws {
        let frame = locationFrame(latitude: 0.0, longitude: 0.0)
        guard case let .location(loc) = OpenDroneIdParser.parseMessage(frame) else {
            return XCTFail()
        }
        XCTAssertFalse(loc.hasValidPosition)
    }

    func testLocationReturnsNilAltitudeWhenRawBytesZero() throws {
        let frame = locationFrame(geodeticAltM: nil)
        guard case let .location(loc) = OpenDroneIdParser.parseMessage(frame) else {
            return XCTFail()
        }
        XCTAssertNil(loc.geodeticAltitudeM)
    }

    // MARK: - Unknown / malformed

    func testUnrecognisedMessageTypeReturnsUnknown() throws {
        var buf = [UInt8](repeating: 0, count: OpenDroneIdMessage.messageTotalBytes)
        buf[0] = 0x71 // type 0x7, version 0x1
        guard case let .unknown(messageType, protocolVersion) = OpenDroneIdParser.parseMessage(buf) else {
            return XCTFail()
        }
        XCTAssertEqual(0x7, messageType)
        XCTAssertEqual(0x1, protocolVersion)
    }

    func testShortBufferReturnsNil() throws {
        XCTAssertNil(OpenDroneIdParser.parseMessage([UInt8](repeating: 0, count: 10)))
        XCTAssertNil(OpenDroneIdParser.parseMessage([]))
    }

    func testNegativeOffsetReturnsNil() throws {
        XCTAssertNil(OpenDroneIdParser.parseMessage([UInt8](repeating: 0, count: 50), offset: -1))
    }

    // MARK: - Message Pack

    func testMessagePackWithBasicIdAndLocationYieldsBothDecoded() throws {
        let pack = messagePack([
            basicIdFrame(uasId: "PACK-TEST-001"),
            locationFrame(latitude: 47.6588, longitude: -117.4260),
        ])
        let msgs = OpenDroneIdParser.parseMessagePack(pack)
        XCTAssertEqual(2, msgs.count)
        if case let .basicId(_, _, _, uasId) = msgs[0] {
            XCTAssertEqual("PACK-TEST-001", uasId)
        } else { XCTFail("expected basicId first") }
        if case .location = msgs[1] {} else { XCTFail("expected location second") }
    }

    func testMessagePackWithWrongSingleMessageSizeYieldsEmpty() throws {
        var buf = [UInt8](repeating: 0, count: 3 + 25)
        buf[0] = UInt8((OpenDroneIdMessage.MessageType.messagePack.rawValue << 4) | 1)
        buf[1] = 30 // wrong
        buf[2] = 1
        XCTAssertTrue(OpenDroneIdParser.parseMessagePack(buf).isEmpty)
    }

    func testMessagePackWithTruncatedPayloadYieldsEmpty() throws {
        var buf = [UInt8](repeating: 0, count: 3 + 25)
        buf[0] = UInt8((OpenDroneIdMessage.MessageType.messagePack.rawValue << 4) | 1)
        buf[1] = 25
        buf[2] = 3 // claims 3 but only carries 1
        XCTAssertTrue(OpenDroneIdParser.parseMessagePack(buf).isEmpty)
    }

    // MARK: - Service Data wrapper

    func testServiceDataWrapsSingleBasicId() throws {
        let svc = serviceData(basicIdFrame(uasId: "SVCDATA-001"))
        let msgs = OpenDroneIdParser.parseServiceData(svc)
        XCTAssertEqual(1, msgs.count)
        if case let .basicId(_, _, _, uasId) = msgs[0] {
            XCTAssertEqual("SVCDATA-001", uasId)
        } else { XCTFail() }
    }

    func testServiceDataWithWrongAppCodeYieldsEmpty() throws {
        var svc = serviceData(basicIdFrame())
        svc[0] = 0x99 // not OpenDroneID
        XCTAssertTrue(OpenDroneIdParser.parseServiceData(svc).isEmpty)
    }

    func testServiceDataWrapsMessagePack() throws {
        let svc = serviceData(messagePack([
            basicIdFrame(uasId: "MULTI-001"),
            locationFrame(),
        ]))
        let msgs = OpenDroneIdParser.parseServiceData(svc)
        XCTAssertEqual(2, msgs.count)
        if case .basicId = msgs[0] {} else { XCTFail() }
        if case .location = msgs[1] {} else { XCTFail() }
    }

    func testServiceDataAcceptsFoundationData() throws {
        let svcBytes = serviceData(basicIdFrame(uasId: "DATA-001"))
        let data = Data(svcBytes)
        let msgs = OpenDroneIdParser.parseServiceData(data)
        XCTAssertEqual(1, msgs.count)
    }
}
