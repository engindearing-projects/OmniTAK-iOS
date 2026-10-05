//
//  MeshtasticProtoDecoderTests.swift
//  OmniTAKMobileTests
//
//  #146: the Meshtastic BLE and TCP clients decoded NodeInfo with field numbers
//  that are not the ones in mesh.proto. The two copies of the decoder agreed
//  with each other, so nothing caught it. They now share MeshtasticProtoDecoder,
//  and these tests build every frame from the numbers and wire types in
//  mesh.proto and telemetry.proto (named in the enums below). A decoder that
//  reads a different number fails here.
//
//  Node ids, names, coordinates and times are made up.
//

import XCTest
@testable import OmniTAK

// MARK: - Field numbers (mesh.proto, telemetry.proto)

private enum FromRadioField {
    static let id = 1
    static let packet = 2
    static let myInfo = 3
    static let nodeInfo = 4
    static let config = 5
    static let configCompleteId = 7
    static let rebooted = 8
    static let channel = 10
    static let metadata = 13
    static let clientNotification = 16
    static let deviceUIConfig = 17
}

private enum MyNodeInfoField {
    static let myNodeNum = 1
    static let rebootCount = 8
}

private enum NodeInfoField {
    static let num = 1
    static let user = 2
    static let position = 3
    static let snr = 4
    static let lastHeard = 5
    static let deviceMetrics = 6
    static let channel = 7
    static let viaMqtt = 8
    static let hopsAway = 9
    static let isFavorite = 10
    static let isIgnored = 11
}

private enum UserField {
    static let id = 1
    static let longName = 2
    static let shortName = 3
    static let hwModel = 5
    static let isLicensed = 6
    static let role = 7
    static let publicKey = 8
}

private enum PositionField {
    static let latitudeI = 1
    static let longitudeI = 2
    static let altitude = 3
    static let time = 4
    static let locationSource = 5
    static let groundTrack = 16
    static let satsInView = 19
    static let precisionBits = 23
}

private enum DeviceMetricsField {
    static let batteryLevel = 1
    static let voltage = 2
    static let channelUtilization = 3
    static let airUtilTx = 4
    static let uptimeSeconds = 5
}

private enum MeshPacketField {
    static let from = 1
    static let to = 2
    static let channel = 3
    static let decoded = 4
    static let encrypted = 5
    static let id = 6
    static let rxTime = 7
    static let rxSnr = 8
    static let hopLimit = 9
    static let wantAck = 10
    static let priority = 11
    static let rxRssi = 12
    static let viaMqtt = 14
    static let hopStart = 15
    static let publicKey = 16
}

private enum DataField {
    static let portnum = 1
    static let payload = 2
    static let wantResponse = 3
}

// MARK: - Wire builder

/// Builds a protobuf message from field numbers and wire types. Tags are
/// varints, so a field number above 15 is written as two bytes, the same as a
/// radio does it.
private struct WireMessage {
    private(set) var data = Data()

    private static func varintBytes(_ value: UInt64) -> [UInt8] {
        var out: [UInt8] = []
        var v = value
        while v > 0x7F {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    private func appending(_ field: Int, wire: UInt64, _ body: [UInt8]) -> WireMessage {
        var copy = self
        copy.data.append(contentsOf: WireMessage.varintBytes(UInt64(field) << 3 | wire))
        copy.data.append(contentsOf: body)
        return copy
    }

    func varint(_ field: Int, _ value: UInt64) -> WireMessage {
        appending(field, wire: 0, WireMessage.varintBytes(value))
    }

    /// int32: a negative value is sign-extended to 64 bits, a 10-byte varint.
    func int32(_ field: Int, _ value: Int32) -> WireMessage {
        varint(field, UInt64(bitPattern: Int64(value)))
    }

    func bool(_ field: Int, _ value: Bool) -> WireMessage {
        varint(field, value ? 1 : 0)
    }

    func fixed32(_ field: Int, _ value: UInt32) -> WireMessage {
        appending(field, wire: 5, (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) })
    }

    func sfixed32(_ field: Int, _ value: Int32) -> WireMessage {
        fixed32(field, UInt32(bitPattern: value))
    }

    func float(_ field: Int, _ value: Float) -> WireMessage {
        fixed32(field, value.bitPattern)
    }

    func bytes(_ field: Int, _ value: Data) -> WireMessage {
        appending(field, wire: 2, WireMessage.varintBytes(UInt64(value.count)) + [UInt8](value))
    }

    func string(_ field: Int, _ value: String) -> WireMessage {
        bytes(field, Data(value.utf8))
    }

    func message(_ field: Int, _ value: WireMessage) -> WireMessage {
        bytes(field, value.data)
    }

    /// A length-delimited field whose length bytes are given as they are, for
    /// frames that claim more than they carry.
    func lengthDelimited(_ field: Int, lengthBytes: [UInt8], body: [UInt8] = []) -> WireMessage {
        appending(field, wire: 2, lengthBytes + body)
    }
}

/// Length varints that do not fit what is left of any buffer. The first is
/// UInt64.max; the second is Int.max, which overflows when added to an offset.
private let lengthAboveIntMax: [UInt8] = Array(repeating: 0xFF, count: 9) + [0x01]
private let lengthEqualToIntMax: [UInt8] = Array(repeating: 0xFF, count: 8) + [0x7F]

// MARK: - NodeInfo

final class MeshtasticNodeInfoDecodingTests: XCTestCase {

    private let nodeNum: UInt32 = 0x0A0B0C0D
    private let heardAt: UInt32 = 1_790_000_000

    private func nodeInfo(_ build: (WireMessage) -> WireMessage = { $0 }) -> WireMessage {
        build(WireMessage().varint(NodeInfoField.num, UInt64(nodeNum)))
    }

    private func decodeNode(_ build: (WireMessage) -> WireMessage = { $0 }) throws -> MeshNode {
        try XCTUnwrap(MeshtasticProtoDecoder.decodeNodeInfo(nodeInfo(build).data))
    }

    // MARK: One field per test

    func testNumIsField1() throws {
        XCTAssertEqual(try decodeNode().id, nodeNum)
    }

    func testUserIsTheMessageInField2() throws {
        let node = try decodeNode {
            $0.message(NodeInfoField.user,
                       WireMessage()
                        .string(UserField.longName, "Test Node Alpha")
                        .string(UserField.shortName, "TNA")
                        .varint(UserField.role, UInt64(MeshNode.roleTAK)))
        }
        XCTAssertEqual(node.longName, "Test Node Alpha")
        XCTAssertEqual(node.shortName, "TNA")
        XCTAssertEqual(node.role, MeshNode.roleTAK)
    }

    func testALengthDelimitedField4IsNotAUser() throws {
        // Field 4 is snr, a float. A message-shaped value there is not the User,
        // so the names fall back to the ones built from the node number.
        let node = try decodeNode {
            $0.message(NodeInfoField.snr,
                       WireMessage()
                        .string(UserField.longName, "Wrong Place")
                        .string(UserField.shortName, "WP"))
        }
        XCTAssertEqual(node.longName, "Node 0A0B0C0D")
        XCTAssertEqual(node.shortName, "0C0D")
    }

    func testPositionIsTheMessageInField3() throws {
        let node = try decodeNode {
            $0.message(NodeInfoField.position,
                       WireMessage()
                        .sfixed32(PositionField.latitudeI, 12_345_678)
                        .sfixed32(PositionField.longitudeI, -23_456_789)
                        .int32(PositionField.altitude, 15)
                        .fixed32(PositionField.time, 1_790_000_000))
        }
        let position = try XCTUnwrap(node.position, "a NodeInfo position has to be read")
        XCTAssertEqual(position.latitude, 1.2345678, accuracy: 1e-9)
        XCTAssertEqual(position.longitude, -2.3456789, accuracy: 1e-9)
        XCTAssertEqual(position.altitude, 15)
    }

    func testSnrIsTheFloatInField4() throws {
        let node = try decodeNode { $0.float(NodeInfoField.snr, -6.5) }
        XCTAssertEqual(try XCTUnwrap(node.snr), -6.5, accuracy: 1e-6)
        XCTAssertNil(node.lastHeard, "snr must not leak into last heard")
    }

    func testLastHeardIsTheFixed32InField5() throws {
        let node = try decodeNode { $0.fixed32(NodeInfoField.lastHeard, heardAt) }
        XCTAssertEqual(node.lastHeard, Date(timeIntervalSince1970: TimeInterval(heardAt)))
        XCTAssertNil(node.snr, "last_heard must not be read as an snr")
    }

    func testBatteryIsBatteryLevelInsideDeviceMetricsField6() throws {
        let node = try decodeNode {
            $0.message(NodeInfoField.deviceMetrics,
                       WireMessage()
                        .varint(DeviceMetricsField.batteryLevel, 87)
                        .float(DeviceMetricsField.voltage, 4.05)
                        .float(DeviceMetricsField.channelUtilization, 12.5))
        }
        XCTAssertEqual(node.batteryLevel, 87)
    }

    func testHopsAwayIsTheVarintInField9() throws {
        let node = try decodeNode { $0.varint(NodeInfoField.hopsAway, 3) }
        XCTAssertEqual(node.hopDistance, 3)
        XCTAssertNil(node.lastHeard, "hops_away must not be read as a date in 1970")
    }

    func testZeroHopsAwayIsADirectNeighbourNotUnknown() throws {
        XCTAssertEqual(try decodeNode { $0.varint(NodeInfoField.hopsAway, 0) }.hopDistance, 0)
    }

    func testMissingHopsAwayStaysUnknown() throws {
        XCTAssertNil(try decodeNode().hopDistance)
    }

    // MARK: Fields that must not be mistaken for anything

    func testIsIgnoredInField11IsNotHopsAway() throws {
        XCTAssertNil(try decodeNode { $0.bool(NodeInfoField.isIgnored, true) }.hopDistance)
    }

    func testIsFavoriteInField10IsNotDeviceMetrics() throws {
        XCTAssertNil(try decodeNode { $0.bool(NodeInfoField.isFavorite, true) }.batteryLevel)
    }

    func testChannelViaMqttIsFavoriteAndIsIgnoredAreNotMistakenForAnything() throws {
        let node = try decodeNode {
            $0.varint(NodeInfoField.channel, 2)
                .bool(NodeInfoField.viaMqtt, true)
                .bool(NodeInfoField.isFavorite, true)
                .bool(NodeInfoField.isIgnored, true)
        }
        XCTAssertNil(node.snr)
        XCTAssertNil(node.lastHeard)
        XCTAssertNil(node.hopDistance)
        XCTAssertNil(node.batteryLevel)
        XCTAssertNil(node.position)
        XCTAssertNil(node.role)
        XCTAssertEqual(node.longName, "Node 0A0B0C0D")
    }

    // MARK: Last heard is a real state

    func testMissingLastHeardStaysUnknownAndIsNeverNow() throws {
        XCTAssertNil(try decodeNode().lastHeard)
    }

    func testZeroLastHeardStaysUnknown() throws {
        // The firmware sends 0 for a node it has no time for.
        XCTAssertNil(try decodeNode { $0.fixed32(NodeInfoField.lastHeard, 0) }.lastHeard)
    }

    // MARK: Whole message

    func testAFullNodeInfoDecodesEachFieldOnItsOwnNumber() throws {
        let node = try decodeNode {
            $0.message(NodeInfoField.user,
                       WireMessage()
                        .string(UserField.id, "!0a0b0c0d")
                        .string(UserField.longName, "Test Node Alpha")
                        .string(UserField.shortName, "TNA")
                        .varint(UserField.hwModel, 43)
                        .bool(UserField.isLicensed, false)
                        .varint(UserField.role, 10)
                        .bytes(UserField.publicKey, Data(repeating: 0x7F, count: 32)))
                .message(NodeInfoField.position,
                         WireMessage()
                            .sfixed32(PositionField.latitudeI, 12_345_678)
                            .sfixed32(PositionField.longitudeI, -23_456_789)
                            .int32(PositionField.altitude, 15))
                .float(NodeInfoField.snr, 5.5)
                .fixed32(NodeInfoField.lastHeard, heardAt)
                .message(NodeInfoField.deviceMetrics,
                         WireMessage()
                            .varint(DeviceMetricsField.batteryLevel, 64)
                            .varint(DeviceMetricsField.uptimeSeconds, 3600))
                .varint(NodeInfoField.channel, 1)
                .bool(NodeInfoField.viaMqtt, false)
                .varint(NodeInfoField.hopsAway, 2)
                .bool(NodeInfoField.isFavorite, true)
                .bool(NodeInfoField.isIgnored, false)
        }

        XCTAssertEqual(node.id, nodeNum)
        XCTAssertEqual(node.longName, "Test Node Alpha")
        XCTAssertEqual(node.shortName, "TNA")
        XCTAssertEqual(node.role, MeshNode.roleTAKTracker)
        XCTAssertEqual(node.position?.latitude ?? 0, 1.2345678, accuracy: 1e-9)
        XCTAssertEqual(node.position?.longitude ?? 0, -2.3456789, accuracy: 1e-9)
        XCTAssertEqual(node.position?.altitude, 15)
        XCTAssertEqual(try XCTUnwrap(node.snr), 5.5, accuracy: 1e-6)
        XCTAssertEqual(node.lastHeard, Date(timeIntervalSince1970: TimeInterval(heardAt)))
        XCTAssertEqual(node.batteryLevel, 64)
        XCTAssertEqual(node.hopDistance, 2)
    }

    func testANodeInfoWithoutANumIsRejected() {
        let body = WireMessage().float(NodeInfoField.snr, 1.0).data
        XCTAssertNil(MeshtasticProtoDecoder.decodeNodeInfo(body))
    }

    func testFieldsAboveFifteenAreSkippedWithoutLosingPlace() throws {
        // A field number above 15 takes a two-byte tag. Newer firmware adds
        // fields past the ones used here, so the reader has to step over them.
        let node = try decodeNode {
            $0.varint(17, 5)
                .string(18, "ignored")
                .float(NodeInfoField.snr, -3.25)
                .fixed32(NodeInfoField.lastHeard, heardAt)
                .varint(NodeInfoField.hopsAway, 1)
        }
        XCTAssertEqual(try XCTUnwrap(node.snr), -3.25, accuracy: 1e-6)
        XCTAssertEqual(node.lastHeard, Date(timeIntervalSince1970: TimeInterval(heardAt)))
        XCTAssertEqual(node.hopDistance, 1)
    }

    func testAKnownFieldWithTheWrongWireTypeIsSkippedNotReinterpreted() throws {
        // last_heard is fixed32 (wire type 5). A varint on field 5 is not it.
        let node = try decodeNode { $0.varint(NodeInfoField.lastHeard, UInt64(heardAt)) }
        XCTAssertNil(node.lastHeard)
        XCTAssertNil(node.snr)
    }
}

// MARK: - Position, User, DeviceMetrics

final class MeshtasticPositionDecodingTests: XCTestCase {

    private func position(_ build: (WireMessage) -> WireMessage) -> MeshPosition? {
        MeshtasticProtoDecoder.decodePosition(build(WireMessage()).data)
    }

    func testCoordinatesAreSfixed32InFields1And2() throws {
        let decoded = try XCTUnwrap(position {
            $0.sfixed32(PositionField.latitudeI, -123_456_789)
                .sfixed32(PositionField.longitudeI, 987_654_321)
                .int32(PositionField.altitude, 120)
        })
        XCTAssertEqual(decoded.latitude, -12.3456789, accuracy: 1e-9)
        XCTAssertEqual(decoded.longitude, 98.7654321, accuracy: 1e-9)
        XCTAssertEqual(decoded.altitude, 120)
    }

    func testANegativeAltitudeIsASignExtendedInt32() throws {
        // int32 -430 is a 10-byte varint. Converting that to UInt32 trapped.
        let decoded = try XCTUnwrap(position {
            $0.sfixed32(PositionField.latitudeI, 12_345_678)
                .sfixed32(PositionField.longitudeI, 23_456_789)
                .int32(PositionField.altitude, -430)
        })
        XCTAssertEqual(decoded.altitude, -430)
    }

    func testFieldsAboveFifteenDoNotCorruptTheCoordinates() throws {
        // A live position carries ground_track (16), sats_in_view (19) and
        // precision_bits (23) after the coordinates. Each has a two-byte tag,
        // and a reader that took the first byte as the whole tag lost its place
        // and read the leftovers as a new latitude.
        let decoded = try XCTUnwrap(position {
            $0.sfixed32(PositionField.latitudeI, 12_345_678)
                .sfixed32(PositionField.longitudeI, -23_456_789)
                .int32(PositionField.altitude, 15)
                .fixed32(PositionField.time, 1_790_000_000)
                .varint(PositionField.locationSource, 1)
                .varint(PositionField.groundTrack, 27_000_000)
                .varint(PositionField.satsInView, 8)
                .varint(PositionField.precisionBits, 13)
        })
        XCTAssertEqual(decoded.latitude, 1.2345678, accuracy: 1e-9)
        XCTAssertEqual(decoded.longitude, -2.3456789, accuracy: 1e-9)
        XCTAssertEqual(decoded.altitude, 15)
    }

    func testTimeInField4IsNotTheAltitude() throws {
        let decoded = try XCTUnwrap(position {
            $0.sfixed32(PositionField.latitudeI, 12_345_678)
                .sfixed32(PositionField.longitudeI, -23_456_789)
                .fixed32(PositionField.time, 1_790_000_000)
        })
        XCTAssertNil(decoded.altitude)
    }

    func testAPositionWithOnlyALatitudeIsNotAPosition() {
        XCTAssertNil(position { $0.sfixed32(PositionField.latitudeI, 12_345_678) })
    }

    func testAPositionAtZeroZeroIsNotAPosition() {
        XCTAssertNil(position {
            $0.sfixed32(PositionField.latitudeI, 0).sfixed32(PositionField.longitudeI, 0)
        })
    }

    func testACoordinateWithTheWrongWireTypeIsSkipped() {
        // latitude_i is sfixed32. A varint on field 1 is not a latitude.
        XCTAssertNil(position {
            $0.varint(PositionField.latitudeI, 24_691_356)
                .sfixed32(PositionField.longitudeI, -23_456_789)
        })
    }
}

final class MeshtasticUserAndMetricsDecodingTests: XCTestCase {

    func testUserDecodesNamesAndRoleAndSkipsTheRest() {
        let user = WireMessage()
            .string(UserField.id, "!0a0b0c0d")
            .string(UserField.longName, "Test Node Alpha")
            .string(UserField.shortName, "TNA")
            .varint(UserField.hwModel, 43)
            .bool(UserField.isLicensed, true)
            .varint(UserField.role, UInt64(MeshNode.roleTAK))
            .bytes(UserField.publicKey, Data(repeating: 0x42, count: 32))
            .data
        let decoded = MeshtasticProtoDecoder.decodeUser(user)
        XCTAssertEqual(decoded.long, "Test Node Alpha")
        XCTAssertEqual(decoded.short, "TNA")
        XCTAssertEqual(decoded.role, MeshNode.roleTAK)
    }

    func testDeviceMetricsBatteryIsFieldOneAndNotTheOtherMetrics() {
        let metrics = WireMessage()
            .float(DeviceMetricsField.voltage, 4.1)
            .float(DeviceMetricsField.channelUtilization, 12.5)
            .float(DeviceMetricsField.airUtilTx, 1.25)
            .varint(DeviceMetricsField.uptimeSeconds, 7200)
            .data
        XCTAssertNil(MeshtasticProtoDecoder.decodeDeviceMetricsBattery(metrics))

        let withBattery = WireMessage()
            .varint(DeviceMetricsField.batteryLevel, 42)
            .float(DeviceMetricsField.voltage, 3.8)
            .data
        XCTAssertEqual(MeshtasticProtoDecoder.decodeDeviceMetricsBattery(withBattery), 42)
    }

    func testAPoweredNodeReportsAboveOneHundred() {
        // telemetry.proto: above 100 means the node is on external power.
        let metrics = WireMessage().varint(DeviceMetricsField.batteryLevel, 101).data
        XCTAssertEqual(MeshtasticProtoDecoder.decodeDeviceMetricsBattery(metrics), 101)
    }
}

// MARK: - MeshPacket and Data

final class MeshtasticMeshPacketDecodingTests: XCTestCase {

    private let sender: UInt32 = 0x01020304

    private func packet(_ build: (WireMessage) -> WireMessage = { $0 }) -> MeshtasticProtoDecoder.MeshPacketFrame {
        let body = build(WireMessage()
            .fixed32(MeshPacketField.from, sender)
            .fixed32(MeshPacketField.to, 0xFFFF_FFFF))
        return MeshtasticProtoDecoder.decodeMeshPacket(body.data)
    }

    func testFromAndToAreFixed32() {
        let decoded = packet()
        XCTAssertEqual(decoded.from, sender)
        XCTAssertEqual(decoded.to, 0xFFFF_FFFF)
    }

    func testRxTimeIsTheFixed32InField7() {
        let decoded = packet { $0.fixed32(MeshPacketField.rxTime, 1_790_000_123) }
        XCTAssertEqual(decoded.rxTime, Date(timeIntervalSince1970: 1_790_000_123))
        XCTAssertNil(decoded.rxSnr, "rx_time must not be read as an snr")
    }

    func testRxSnrIsTheFloatInField8AndNotAnRxTime() {
        let decoded = packet { $0.float(MeshPacketField.rxSnr, -7.25) }
        XCTAssertEqual(decoded.rxSnr, -7.25)
        XCTAssertNil(decoded.rxTime, "the bits of an snr are not an epoch")
    }

    func testHopLimitIsField9() {
        XCTAssertEqual(packet { $0.varint(MeshPacketField.hopLimit, 3) }.hopLimit, 3)
    }

    func testWantAckInField10IsNotTheHopLimit() {
        XCTAssertNil(packet { $0.bool(MeshPacketField.wantAck, true) }.hopLimit)
    }

    func testRxRssiIsASignedInt32InField12() {
        // A negative int32 is a 10-byte sign-extended varint.
        XCTAssertEqual(packet { $0.int32(MeshPacketField.rxRssi, -92) }.rxRssi, -92)
    }

    func testPublicKeyInField16IsNotAnRssi() {
        let decoded = packet { $0.bytes(MeshPacketField.publicKey, Data((0..<32).map { UInt8($0) })) }
        XCTAssertNil(decoded.rxRssi)
    }

    func testIdPriorityViaMqttAndHopStartAreNotMistakenForAnything() {
        let decoded = packet {
            $0.fixed32(MeshPacketField.id, 0x1122_3344)
                .varint(MeshPacketField.priority, 64)
                .bool(MeshPacketField.viaMqtt, true)
                .varint(MeshPacketField.hopStart, 5)
        }
        XCTAssertNil(decoded.rxTime)
        XCTAssertNil(decoded.rxSnr)
        XCTAssertNil(decoded.hopLimit)
        XCTAssertNil(decoded.rxRssi)
        XCTAssertEqual(decoded.channel, 0)
        XCTAssertEqual(decoded.portNum, 0)
    }

    func testARadioWithNoClockSendsAZeroRxTimeAndItIsUnknown() {
        XCTAssertNil(packet { $0.fixed32(MeshPacketField.rxTime, 0) }.rxTime)
    }

    func testDecodedDataGivesThePortnumAndPayload() {
        let payload = Data([0x01, 0x02, 0x03])
        let decoded = packet {
            $0.message(MeshPacketField.decoded,
                       WireMessage()
                        .varint(DataField.portnum, 72)
                        .bytes(DataField.payload, payload)
                        .bool(DataField.wantResponse, true))
        }
        XCTAssertEqual(decoded.portNum, 72)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testAnEncryptedPacketKeepsItsMetadataAndHasNoPayload() {
        let decoded = packet {
            $0.bytes(MeshPacketField.encrypted, Data(repeating: 0x55, count: 16))
                .fixed32(MeshPacketField.rxTime, 1_790_000_123)
                .float(MeshPacketField.rxSnr, 4.0)
        }
        XCTAssertEqual(decoded.rxTime, Date(timeIntervalSince1970: 1_790_000_123))
        XCTAssertEqual(decoded.rxSnr, 4.0)
        XCTAssertEqual(decoded.portNum, 0)
        XCTAssertTrue(decoded.payload.isEmpty)
    }

    func testAFullLivePacketDecodesEachFieldOnItsOwnNumber() {
        let payload = Data([0xAA, 0xBB])
        let decoded = packet {
            $0.varint(MeshPacketField.channel, 2)
                .message(MeshPacketField.decoded,
                         WireMessage().varint(DataField.portnum, 3).bytes(DataField.payload, payload))
                .fixed32(MeshPacketField.id, 0x1122_3344)
                .fixed32(MeshPacketField.rxTime, 1_790_000_123)
                .float(MeshPacketField.rxSnr, 5.5)
                .varint(MeshPacketField.hopLimit, 2)
                .bool(MeshPacketField.wantAck, true)
                .varint(MeshPacketField.priority, 64)
                .int32(MeshPacketField.rxRssi, -101)
                .bool(MeshPacketField.viaMqtt, false)
                .varint(MeshPacketField.hopStart, 3)
                .bytes(MeshPacketField.publicKey, Data(repeating: 0x7F, count: 32))
        }
        XCTAssertEqual(decoded.from, sender)
        XCTAssertEqual(decoded.to, 0xFFFF_FFFF)
        XCTAssertEqual(decoded.channel, 2)
        XCTAssertEqual(decoded.portNum, 3)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertEqual(decoded.rxTime, Date(timeIntervalSince1970: 1_790_000_123))
        XCTAssertEqual(decoded.rxSnr, 5.5)
        XCTAssertEqual(decoded.hopLimit, 2)
        XCTAssertEqual(decoded.rxRssi, -101)
    }
}

// MARK: - FromRadio

final class MeshtasticFromRadioDecodingTests: XCTestCase {

    private let nodeNum: UInt32 = 0x0A0B0C0D

    private func nodeInfoBody() -> WireMessage {
        WireMessage()
            .varint(NodeInfoField.num, UInt64(nodeNum))
            .fixed32(NodeInfoField.lastHeard, 1_790_000_000)
            .varint(NodeInfoField.hopsAway, 1)
    }

    func testNodeInfoIsFromRadioField4() throws {
        let frame = WireMessage().varint(FromRadioField.id, 7).message(FromRadioField.nodeInfo, nodeInfoBody()).data
        guard case .nodeInfo(let node)? = MeshtasticProtoDecoder.decodeFromRadio(frame) else {
            return XCTFail("expected a node_info payload")
        }
        XCTAssertEqual(node.id, nodeNum)
        XCTAssertEqual(node.hopDistance, 1)
    }

    func testPacketIsFromRadioField2() {
        let packet = WireMessage()
            .fixed32(MeshPacketField.from, 0x01020304)
            .message(MeshPacketField.decoded, WireMessage().varint(DataField.portnum, 1).string(DataField.payload, "hi"))
        let frame = WireMessage().message(FromRadioField.packet, packet).data
        guard case .packet(let decoded)? = MeshtasticProtoDecoder.decodeFromRadio(frame) else {
            return XCTFail("expected a packet payload")
        }
        XCTAssertEqual(decoded.from, 0x01020304)
        XCTAssertEqual(decoded.portNum, 1)
        XCTAssertEqual(String(data: decoded.payload, encoding: .utf8), "hi")
    }

    func testMyInfoIsFromRadioField3AndCarriesTheNodeNumberOnly() {
        let myInfo = WireMessage()
            .varint(MyNodeInfoField.myNodeNum, UInt64(nodeNum))
            .varint(MyNodeInfoField.rebootCount, 4)
        let frame = WireMessage().message(FromRadioField.myInfo, myInfo).data
        XCTAssertEqual(MeshtasticProtoDecoder.decodeFromRadio(frame), .myInfo(nodeNum: nodeNum))
    }

    func testConfigCompleteIdIsFromRadioField7() {
        let frame = WireMessage().varint(FromRadioField.configCompleteId, 123_456).data
        XCTAssertEqual(MeshtasticProtoDecoder.decodeFromRadio(frame), .configComplete(id: 123_456))
    }

    func testRebootedIsFromRadioField8() {
        let frame = WireMessage().bool(FromRadioField.rebooted, true).data
        XCTAssertEqual(MeshtasticProtoDecoder.decodeFromRadio(frame), .rebooted)
    }

    func testAFrameWithOnlyAnIdHasNoPayload() {
        XCTAssertNil(MeshtasticProtoDecoder.decodeFromRadio(WireMessage().varint(FromRadioField.id, 9).data))
    }

    func testVariantsTheAppDoesNotUseAreReportedAsOther() {
        // A config whose variant is not a message is not a config. A config or
        // channel that is well formed is reported with its bytes (#148, see
        // MeshtasticSettingsFrameDecodingTests).
        let config = WireMessage().message(FromRadioField.config, WireMessage().varint(1, 1)).data
        XCTAssertEqual(MeshtasticProtoDecoder.decodeFromRadio(config), .other(field: FromRadioField.config))

        let metadata = WireMessage().message(FromRadioField.metadata, WireMessage().string(1, "2.7.0")).data
        XCTAssertEqual(MeshtasticProtoDecoder.decodeFromRadio(metadata), .other(field: FromRadioField.metadata))
    }

    func testAVariantWithATwoByteTagDoesNotMakeAPhantomNode() {
        // device UI config is field 17 and client notification is field 16:
        // two-byte tags. Their bodies are free-form, so make one whose bytes
        // look like a node_info. A reader that took the first tag byte as the
        // whole tag skipped the wrong number of bytes and then read the body as
        // top-level fields, which put a node in the list.
        let lookalike = WireMessage().message(FromRadioField.nodeInfo, nodeInfoBody())
        for field in [FromRadioField.clientNotification, FromRadioField.deviceUIConfig] {
            let frame = WireMessage()
                .varint(FromRadioField.id, 3)
                .message(field, lookalike)
                .data
            XCTAssertEqual(MeshtasticProtoDecoder.decodeFromRadio(frame), .other(field: field),
                           "field \(field) must be skipped whole")
        }
    }

    func testANodeInfoThatCannotBeDecodedIsReportedAsOther() {
        // No num: not a node.
        let frame = WireMessage().message(FromRadioField.nodeInfo, WireMessage().float(NodeInfoField.snr, 1)).data
        XCTAssertEqual(MeshtasticProtoDecoder.decodeFromRadio(frame), .other(field: FromRadioField.nodeInfo))
    }

    func testAnEmptyFrameHasNoPayload() {
        XCTAssertNil(MeshtasticProtoDecoder.decodeFromRadio(Data()))
    }

    func testASliceOfALargerBufferDecodesTheSame() {
        // Data slices keep the parent's indices. The decoder has to read from
        // the start of the slice, not from 0 of the parent.
        let frame = WireMessage().message(FromRadioField.nodeInfo, nodeInfoBody()).data
        var padded = Data([0xDE, 0xAD, 0xBE, 0xEF])
        padded.append(frame)
        let slice = padded.dropFirst(4)
        XCTAssertEqual(MeshtasticProtoDecoder.decodeFromRadio(slice), MeshtasticProtoDecoder.decodeFromRadio(frame))
    }
}

// MARK: - Malformed input

/// Lengths that do not fit what is left must end the message, not trap. The
/// payload codecs read bytes off the air, and a pasted channel link is
/// untrusted too.
final class MeshtasticMalformedInputTests: XCTestCase {

    private let lengths: [(name: String, bytes: [UInt8])] = [
        ("above Int.max", lengthAboveIntMax),
        ("equal to Int.max", lengthEqualToIntMax),
    ]

    func testTheRadioDecoderStopsOnALengthThatDoesNotFit() {
        for length in lengths {
            let frame = WireMessage().lengthDelimited(FromRadioField.nodeInfo, lengthBytes: length.bytes).data
            XCTAssertNil(MeshtasticProtoDecoder.decodeFromRadio(frame), "length \(length.name)")

            let nodeInfo = WireMessage()
                .varint(NodeInfoField.num, 5)
                .lengthDelimited(NodeInfoField.user, lengthBytes: length.bytes)
                .data
            XCTAssertEqual(MeshtasticProtoDecoder.decodeNodeInfo(nodeInfo)?.id, 5,
                           "what was decoded before the bad length is kept (\(length.name))")
        }
    }

    func testTheATAKPluginParserDoesNotTrapOnALengthThatDoesNotFit() {
        for length in lengths {
            // TAKMessage.takControl (1), TAKMessage.cotEvent (2)
            for field in [1, 2] {
                let payload = WireMessage().lengthDelimited(field, lengthBytes: length.bytes).data
                XCTAssertNil(ATAKPluginParser.parse(payload), "field \(field), length \(length.name)")
            }
            // CoTEvent.detail (15) inside a CoTEvent that is otherwise complete.
            let cotEvent = WireMessage()
                .string(1, "a-f-G")
                .string(5, "TEST-UID-1")
                .lengthDelimited(15, lengthBytes: length.bytes)
            let wrapped = WireMessage().message(2, cotEvent).data
            XCTAssertEqual(ATAKPluginParser.parse(wrapped)?.uid, "TEST-UID-1", "detail, length \(length.name)")
        }
    }

    func testTAKPacketCodecDoesNotTrapOnALengthThatDoesNotFit() {
        for length in lengths {
            // TAKPacket.contact (2), and an unknown field that has to be skipped.
            for field in [2, 9] {
                let payload = WireMessage().lengthDelimited(field, lengthBytes: length.bytes).data
                XCTAssertNil(TAKPacketCodec.decode(payload), "field \(field), length \(length.name)")
            }
        }
    }

    func testTAKPacketV2CodecDoesNotTrapOnALengthThatDoesNotFit() {
        for length in lengths {
            for field in [3, 99] {
                var payload = Data([TAKPacketV2Codec.flagUncompressed])
                payload.append(WireMessage().lengthDelimited(field, lengthBytes: length.bytes).data)
                XCTAssertNil(TAKPacketV2Codec.decode(payload), "field \(field), length \(length.name)")
            }
        }
    }

    func testTheChannelLinkDecoderDoesNotTrapOnALengthThatDoesNotFit() {
        for length in lengths {
            for field in [1, 9] {
                let body = WireMessage().lengthDelimited(field, lengthBytes: length.bytes).data
                let link = MeshtasticChannelCodec.base64url(body)
                XCTAssertNil(MeshtasticChannelCodec.decodeURL(MeshtasticChannelCodec.urlPrefix + link),
                             "field \(field), length \(length.name)")
            }
        }
    }
}
