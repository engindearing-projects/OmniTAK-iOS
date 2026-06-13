//
//  MeshCoreFrameCodecTests.swift
//  OmniTAKMobileTests
//
//  Round-trip + layout tests for the MeshCore companion frame codec. The byte
//  layouts mirror MeshCore-1.4.8 BtConnectionManager.java (command/response
//  codes, little-endian multibyte fields). Frames here are built to that spec;
//  on-radio validation against a live MeshCore companion node is a follow-up
//  (Fable / Heltec V3).
//

import XCTest
@testable import OmniTAK

final class MeshCoreFrameCodecTests: XCTestCase {

    // MARK: - Encoders

    func testEncodeAppStartLayout() {
        let frame = MeshCoreFrameCodec.encodeAppStart(appId: "meshcore-flutter")
        // [0x01][7 x 0x00][appId]
        XCTAssertEqual(frame.first, 0x01)
        XCTAssertEqual(frame.count, 8 + "meshcore-flutter".utf8.count)
        // bytes 1..7 reserved zero
        for i in 1..<8 { XCTAssertEqual(frame[i], 0x00, "reserved byte \(i) must be 0") }
        let appId = String(data: frame.subdata(in: 8..<frame.count), encoding: .utf8)
        XCTAssertEqual(appId, "meshcore-flutter")
    }

    func testEncodeDeviceQuery() {
        XCTAssertEqual(Array(MeshCoreFrameCodec.encodeDeviceQuery()), [0x16, 0x03])
    }

    func testEncodeSingleByteCommands() {
        XCTAssertEqual(Array(MeshCoreFrameCodec.encodeGetNextMessage()), [0x0A])
        XCTAssertEqual(Array(MeshCoreFrameCodec.encodeGetBattery()), [0x14])
        XCTAssertEqual(Array(MeshCoreFrameCodec.encodeSendSelfAdvert()), [0x07])
    }

    func testEncodeSetAdvertLatLonLayout() {
        // 47.6062, -122.3321 (Seattle) → E6 little-endian.
        guard let frame = MeshCoreFrameCodec.encodeSetAdvertLatLon(
            latitude: 47.6062, longitude: -122.3321, altitudeMeters: 0) else {
            return XCTFail("encodeSetAdvertLatLon returned nil for valid coords")
        }
        XCTAssertEqual(frame.count, 13)            // [0x0E] + 3 x int32
        XCTAssertEqual(frame.first, 0x0E)
        let latE6 = frame.int32LE(at: 1)
        let lonE6 = frame.int32LE(at: 5)
        let alt   = frame.int32LE(at: 9)
        XCTAssertEqual(latE6, Int32((47.6062 * 1_000_000).rounded()))
        XCTAssertEqual(lonE6, Int32((-122.3321 * 1_000_000).rounded()))
        XCTAssertEqual(alt, 0)
    }

    func testEncodeSetAdvertLatLonRejectsOutOfRange() {
        XCTAssertNil(MeshCoreFrameCodec.encodeSetAdvertLatLon(latitude: 91, longitude: 0))
        XCTAssertNil(MeshCoreFrameCodec.encodeSetAdvertLatLon(latitude: 0, longitude: 181))
        XCTAssertNil(MeshCoreFrameCodec.encodeSetAdvertLatLon(latitude: .nan, longitude: 0))
    }

    func testEncodeSendTextMessageLayout() {
        let pubKey = String(repeating: "ab", count: 32) // 64 hex chars
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        guard let frame = MeshCoreFrameCodec.encodeSendTextMessage(
            pubKeyHex: pubKey, text: "ping", timestamp: when) else {
            return XCTFail("encodeSendTextMessage returned nil")
        }
        // [0x02][txtType 0x00][attempt 0x00][ts u32 LE][prefix 6][msg]
        XCTAssertEqual(frame[0], 0x02)
        XCTAssertEqual(frame[1], 0x00)
        XCTAssertEqual(frame[2], 0x00)
        XCTAssertEqual(frame.uint32LE(at: 3), UInt32(1_700_000_000))
        // pubkey prefix = first 6 bytes (0xAB repeated)
        let prefix = Array(frame.subdata(in: 7..<13))
        XCTAssertEqual(prefix, [UInt8](repeating: 0xAB, count: 6))
        let msg = String(data: frame.subdata(in: 13..<frame.count), encoding: .utf8)
        XCTAssertEqual(msg, "ping")
    }

    func testEncodeSendTextMessageRejectsBadInput() {
        XCTAssertNil(MeshCoreFrameCodec.encodeSendTextMessage(pubKeyHex: "ab", text: "hi")) // too short
        XCTAssertNil(MeshCoreFrameCodec.encodeSendTextMessage(
            pubKeyHex: String(repeating: "ab", count: 32), text: "   ")) // empty text
    }

    func testEncodeSetAdvertNameTruncatesAndRejectsEmpty() {
        XCTAssertNil(MeshCoreFrameCodec.encodeSetAdvertName("   "))
        let long = String(repeating: "X", count: 40)
        guard let frame = MeshCoreFrameCodec.encodeSetAdvertName(long) else {
            return XCTFail("encodeSetAdvertName returned nil for valid name")
        }
        XCTAssertEqual(frame.first, 0x08)
        XCTAssertEqual(frame.count, 1 + 31) // truncated to 31 bytes
    }

    // MARK: - Decoders (frames built to the JC layout)

    func testDecodeBatteryRoundTrip() {
        // 3950 mV = 0x0F6E -> [0x0C][0x6E][0x0F]
        let frame = Data([0x0C, 0x6E, 0x0F])
        guard case let .battery(mv, pct)? = MeshCoreFrameCodec.decode(frame) else {
            return XCTFail("expected .battery")
        }
        XCTAssertEqual(mv, 3950)
        XCTAssertEqual(pct, MeshCoreFrameCodec.batteryPercent(fromMillivolts: 3950))
        XCTAssertTrue(pct > 0 && pct < 100)
    }

    func testBatteryPercentClamps() {
        XCTAssertEqual(MeshCoreFrameCodec.batteryPercent(fromMillivolts: 0), -1)
        XCTAssertEqual(MeshCoreFrameCodec.batteryPercent(fromMillivolts: 3000), 0)
        XCTAssertEqual(MeshCoreFrameCodec.batteryPercent(fromMillivolts: 4200), 100)
        XCTAssertEqual(MeshCoreFrameCodec.batteryPercent(fromMillivolts: 4500), 100)
    }

    func testDecodeNoMoreMessages() {
        guard case .noMoreMessages? = MeshCoreFrameCodec.decode(Data([0x0A])) else {
            return XCTFail("expected .noMoreMessages")
        }
    }

    func testDecodeMessagesWaiting() {
        guard case .messagesWaiting? = MeshCoreFrameCodec.decode(Data([0x83])) else {
            return XCTFail("expected .messagesWaiting")
        }
    }

    func testDecodeContactWithPosition() {
        // Build a 144-byte advert/contact frame per the JC layout:
        // [0x80][pubkey 32 @1][advType @33][name 32 @100][tsSec @132][latE6 @136][lonE6 @140]
        var frame = [UInt8](repeating: 0, count: 144)
        frame[0] = MeshCoreFrameCodec.pushCodeAdvert
        // pubkey: 0x11,0x22,0x33,0x44,... (only first 4 bytes matter for id)
        for i in 0..<32 { frame[1 + i] = UInt8((i + 1) & 0xFF) }
        frame[33] = 0x01 // chat node
        // name "NODE-A" at 100
        let name = Array("NODE-A".utf8)
        for (i, b) in name.enumerated() { frame[100 + i] = b }
        // tsSec = 1700000000 LE at 132
        putUInt32LE(&frame, 132, 1_700_000_000)
        // latE6 = 47_606_200 ; lonE6 = -122_332_100 LE
        putInt32LE(&frame, 136, 47_606_200)
        putInt32LE(&frame, 140, -122_332_100)

        guard case let .contact(contact)? = MeshCoreFrameCodec.decode(Data(frame)) else {
            return XCTFail("expected .contact")
        }
        XCTAssertEqual(contact.name, "NODE-A")
        XCTAssertEqual(contact.advertType, 1)
        XCTAssertFalse(contact.isRepeater)
        XCTAssertTrue(contact.hasValidPosition)
        XCTAssertEqual(contact.latitude, 47.6062, accuracy: 1e-6)
        XCTAssertEqual(contact.longitude, -122.3321, accuracy: 1e-6)
        XCTAssertEqual(contact.advertTimestampSec, 1_700_000_000)
        // pubkey hex begins 01020304…
        XCTAssertTrue(contact.pubKeyHex.hasPrefix("010203"))
        // node id derived from first 6 bytes — must be non-zero and stable.
        let nodeId = MeshCoreFrameCodec.nodeId(fromPubKeyHex: contact.pubKeyHex)
        XCTAssertNotEqual(nodeId, 0)
        XCTAssertEqual(nodeId, MeshCoreFrameCodec.nodeId(fromPubKeyHex: contact.pubKeyHex))
    }

    func testDecodeContactNullIslandHasNoValidPosition() {
        var frame = [UInt8](repeating: 0, count: 144)
        frame[0] = MeshCoreFrameCodec.pushCodeAdvert
        for i in 0..<32 { frame[1 + i] = UInt8((i + 1) & 0xFF) }
        frame[33] = 0x02 // repeater
        // lat/lon left 0,0 -> no position
        guard case let .contact(contact)? = MeshCoreFrameCodec.decode(Data(frame)) else {
            return XCTFail("expected .contact")
        }
        XCTAssertTrue(contact.isRepeater)
        XCTAssertFalse(contact.hasValidPosition)
    }

    func testDecodeSelfInfo() {
        // [0x05][advType @1][tx @2][maxTx @3][pubkey 32 @4][latE6 @36][lonE6 @40] … [name @58]
        var frame = [UInt8](repeating: 0, count: 70)
        frame[0] = MeshCoreFrameCodec.respSelfInfo
        for i in 0..<32 { frame[4 + i] = UInt8((i + 0xA0) & 0xFF) }
        putInt32LE(&frame, 36, 47_606_200)
        putInt32LE(&frame, 40, -122_332_100)
        let name = Array("MYNODE".utf8)
        for (i, b) in name.enumerated() { frame[58 + i] = b }

        guard case let .selfInfo(info)? = MeshCoreFrameCodec.decode(Data(frame)) else {
            return XCTFail("expected .selfInfo")
        }
        XCTAssertEqual(info.name, "MYNODE")
        XCTAssertTrue(info.hasPosition)
        XCTAssertEqual(info.latitude, 47.6062, accuracy: 1e-6)
        XCTAssertEqual(info.longitude, -122.3321, accuracy: 1e-6)
        XCTAssertTrue(info.pubKeyHex.hasPrefix("a0a1a2a3"))
    }

    func testDecodeContactMessageV1() {
        // [0x07][senderPrefix 6 @1][.. up to 8 ..][txtType @8 = 0][text @13]
        var frame = [UInt8](repeating: 0, count: 13)
        frame[0] = MeshCoreFrameCodec.respContactMsg
        for i in 0..<6 { frame[1 + i] = UInt8((i + 0xC0) & 0xFF) } // sender prefix
        frame[8] = 0x00 // txtType plain
        frame.append(contentsOf: Array("hello tak".utf8))

        guard case let .textMessage(msg)? = MeshCoreFrameCodec.decode(Data(frame)) else {
            return XCTFail("expected .textMessage")
        }
        XCTAssertEqual(msg.text, "hello tak")
        XCTAssertEqual(msg.senderPubKeyPrefixHex, "c0c1c2c3c4c5")
    }

    func testDecodeContactMessageV1SignedVariantSkipsExtraBytes() {
        // txtType==2 means 4 extra bytes before the text (offset 13 -> 17).
        var frame = [UInt8](repeating: 0, count: 17)
        frame[0] = MeshCoreFrameCodec.respContactMsg
        for i in 0..<6 { frame[1 + i] = UInt8((i + 0xC0) & 0xFF) }
        frame[8] = 0x02 // signed/timestamped
        frame.append(contentsOf: Array("signed".utf8))

        guard case let .textMessage(msg)? = MeshCoreFrameCodec.decode(Data(frame)) else {
            return XCTFail("expected .textMessage")
        }
        XCTAssertEqual(msg.text, "signed")
    }

    func testDecodeUnknownCodeIsOther() {
        guard case let .other(code)? = MeshCoreFrameCodec.decode(Data([0xEE, 0x01, 0x02])) else {
            return XCTFail("expected .other")
        }
        XCTAssertEqual(code, 0xEE)
    }

    // MARK: - Fix #1: RESP_DEVICE_INFO (0x0D) handler

    func testDecodeDeviceInfoMinimalFrame() {
        // Minimal 3-byte device info: [0x0D][hwModel][hwRevision]
        let frame = Data([0x0D, 0x05, 0x02])
        guard case let .deviceInfo(info)? = MeshCoreFrameCodec.decode(frame) else {
            return XCTFail("expected .deviceInfo for code 0x0D")
        }
        XCTAssertEqual(info.hwModel, 0x05)
        XCTAssertEqual(info.hwRevision, 0x02)
        XCTAssertEqual(info.firmwareVersion, "")
    }

    func testDecodeDeviceInfo82ByteFrame() {
        // Live radio sends 82 bytes: [0x0D][hw][rev][fw ascii null-terminated, padded]
        var frame = [UInt8](repeating: 0, count: 82)
        frame[0] = 0x0D
        frame[1] = 0x03  // hwModel
        frame[2] = 0x01  // hwRevision
        let fw = Array("1.4.8".utf8)
        for (i, b) in fw.enumerated() { frame[3 + i] = b }

        guard case let .deviceInfo(info)? = MeshCoreFrameCodec.decode(Data(frame)) else {
            return XCTFail("expected .deviceInfo for 82-byte frame")
        }
        XCTAssertEqual(info.hwModel, 0x03)
        XCTAssertEqual(info.hwRevision, 0x01)
        XCTAssertEqual(info.firmwareVersion, "1.4.8")
    }

    func testDecodeDeviceInfoTooShortIsOther() {
        // 2-byte frame is below the 3-byte minimum → .other
        let frame = Data([0x0D, 0x01])
        guard case let .other(code)? = MeshCoreFrameCodec.decode(frame) else {
            return XCTFail("expected .other for truncated 0x0D frame")
        }
        XCTAssertEqual(code, 0x0D)
    }

    func testDecodeEmptyFrameIsNil() {
        XCTAssertNil(MeshCoreFrameCodec.decode(Data()))
    }

    // MARK: - Identity helpers

    func testPubKeyPrefixBytes() {
        let prefix = MeshCoreFrameCodec.pubKeyPrefixBytes("0102030405060708", count: 4)
        XCTAssertEqual(Array(prefix ?? Data()), [0x01, 0x02, 0x03, 0x04])
        XCTAssertNil(MeshCoreFrameCodec.pubKeyPrefixBytes("01", count: 4))
        XCTAssertNil(MeshCoreFrameCodec.pubKeyPrefixBytes("zz020304", count: 4))
    }

    func testNodeIdDerivation() {
        // 6-byte prefix: "deadbeefcafe" — nodeId must be non-zero and deterministic.
        let id = MeshCoreFrameCodec.nodeId(fromPubKeyHex: "deadbeefcafe")
        XCTAssertNotEqual(id, 0)
        // Same input always yields the same id.
        XCTAssertEqual(id, MeshCoreFrameCodec.nodeId(fromPubKeyHex: "deadbeefcafe"))
        // Too-short pubkey → 0
        XCTAssertEqual(MeshCoreFrameCodec.nodeId(fromPubKeyHex: "deadbeef"), 0)
        XCTAssertEqual(MeshCoreFrameCodec.nodeId(fromPubKeyHex: ""), 0)
    }

    // MARK: - Fix #3: node-id widened 4→6 bytes; CoT UID uses 12 hex chars

    func testCoTUIDUses12HexChars() {
        // UID must be MESHCORE- + 12 uppercase hex chars (6 bytes).
        let uid = MeshCoreCoTConverter.uid(forPubKeyHex: "deadbeefcafebabe")
        XCTAssertEqual(uid, "MESHCORE-DEADBEEFCAFE")
        XCTAssertEqual(uid.count, "MESHCORE-".count + 12)
    }

    func testPubKeyPrefix12Helper() {
        XCTAssertEqual(MeshCoreFrameCodec.pubKeyPrefix12(fromPubKeyHex: "deadbeefcafebabe0011"), "deadbeefcafe")
        XCTAssertNil(MeshCoreFrameCodec.pubKeyPrefix12(fromPubKeyHex: "dead"))
    }

    // MARK: - CoT conversion

    func testCoTConverterUIDPrefix() {
        // Updated: 12 uppercase hex chars
        XCTAssertEqual(MeshCoreCoTConverter.uid(forPubKeyHex: "deadbeefcafebabe"), "MESHCORE-DEADBEEFCAFE")
    }

    func testCoTConverterProducesPLIForPositionedContact() {
        let contact = MeshCoreContact(
            pubKeyHex: "deadbeefcafebabe" + String(repeating: "0", count: 48),
            advertType: 1,
            name: "Recon-1",
            advertTimestampSec: 1_700_000_000,
            latitude: 47.6062,
            longitude: -122.3321,
            hasPosition: true
        )
        guard let event = MeshCoreCoTConverter.toCoTEvent(contact: contact) else {
            return XCTFail("expected a CoT event")
        }
        // UID now uses 12 uppercase hex chars (6-byte prefix)
        XCTAssertEqual(event.uid, "MESHCORE-DEADBEEFCAFE")
        XCTAssertEqual(event.type, "a-n-G-U-C")
        XCTAssertEqual(event.detail.callsign, "Recon-1")
        XCTAssertEqual(event.point.lat, 47.6062, accuracy: 1e-6)
        XCTAssertEqual(event.point.lon, -122.3321, accuracy: 1e-6)
    }

    func testCoTConverterReturnsNilWithoutPosition() {
        let contact = MeshCoreContact(
            pubKeyHex: String(repeating: "ab", count: 32),
            advertType: 2, name: "Repeater", advertTimestampSec: 0,
            latitude: 0, longitude: 0, hasPosition: false
        )
        XCTAssertNil(MeshCoreCoTConverter.toCoTEvent(contact: contact))
    }

    // MARK: - Little-endian write helpers (test-local)

    private func putUInt32LE(_ buf: inout [UInt8], _ off: Int, _ value: UInt32) {
        buf[off]     = UInt8(value & 0xFF)
        buf[off + 1] = UInt8((value >> 8) & 0xFF)
        buf[off + 2] = UInt8((value >> 16) & 0xFF)
        buf[off + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func putInt32LE(_ buf: inout [UInt8], _ off: Int, _ value: Int32) {
        putUInt32LE(&buf, off, UInt32(bitPattern: value))
    }
}
