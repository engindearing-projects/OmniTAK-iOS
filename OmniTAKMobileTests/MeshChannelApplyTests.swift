//
//  MeshChannelApplyTests.swift
//  OmniTAKMobileTests
//
//  Byte-layout tests for the channel-APPLY encoders (OmniTAK-iOS #101):
//    - Meshtastic AdminMessage.set_channel / set_config (clean-room protobuf)
//    - MeshCore CMD_SET_CHANNEL (flat companion frame)
//
//  Field numbers / enum values are facts from the published wire specs
//  (admin.proto, channel.proto, config.proto; MeshCore companion_protocol.md).
//  These tests assert the hand-rolled bytes match that wire layout.
//
//  The Meshtastic encoders no longer build a message from nothing (#148): they
//  change fields of what the radio last sent and write the rest back. The
//  layout tests below start from the smallest thing a radio sends, a channel
//  that is only its index or a sub-config with every field at its default, so
//  what they see is the layout of the fields the encoder writes. What happens to
//  the fields it does not write is in MeshtasticAdminCodecTests.
//

import XCTest
@testable import OmniTAK

final class MeshChannelApplyTests: XCTestCase {

    // MARK: - Helpers (manual varint reader mirroring the codecs)

    /// Read a protobuf tag (field, wire) at idx; advances idx.
    private func readTag(_ d: Data, _ idx: inout Int) -> (field: Int, wire: Int)? {
        guard let v = readVarint(d, &idx) else { return nil }
        return (Int(v >> 3), Int(v & 0x07))
    }

    private func readVarint(_ d: Data, _ idx: inout Int) -> UInt64? {
        var result: UInt64 = 0, shift: UInt64 = 0
        while idx < d.count {
            let byte = d[d.startIndex + idx]; idx += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private func readLen(_ d: Data, _ idx: inout Int) -> Data? {
        guard let len = readVarint(d, &idx) else { return nil }
        let end = idx + Int(len); guard end <= d.count else { return nil }
        let slice = d.subdata(in: (d.startIndex + idx)..<(d.startIndex + end))
        idx = end; return slice
    }

    // MARK: - Meshtastic set_channel

    func testEncodeSetChannelLayout() {
        let psk = Data([0x01, 0x02, 0x03, 0x04]) // arbitrary short psk
        // Slot 1 as the radio sends it while it is disabled: its index only.
        guard let write = MeshtasticAdminCodec.encodeSetChannel(
            current: Data([0x08, 0x01]), name: "OmniTAK", key: .set(psk), role: .secondary) else {
            return XCTFail("encodeSetChannel returned nil")
        }
        let admin = write.payload

        // AdminMessage { set_channel = 33 } -> tag (33<<3)|2 = 266 -> varint [0x8A,0x02]
        var idx = 0
        guard let tag = readTag(admin, &idx) else { return XCTFail("no admin tag") }
        XCTAssertEqual(tag.field, 33, "set_channel field number")
        XCTAssertEqual(tag.wire, 2, "submessage wire type")

        guard let channel = readLen(admin, &idx) else { return XCTFail("no Channel body") }

        // Channel { index=1 (varint), settings=2 (len), role=3 (varint) }
        var cIdx = 0
        var sawIndex = false, sawSettings = false, sawRole = false
        var settingsBody = Data()
        while cIdx < channel.count {
            guard let t = readTag(channel, &cIdx) else { break }
            switch (t.field, t.wire) {
            case (1, 0):
                XCTAssertEqual(readVarint(channel, &cIdx), 1, "channel index")
                sawIndex = true
            case (2, 2):
                settingsBody = readLen(channel, &cIdx) ?? Data()
                sawSettings = true
            case (3, 0):
                XCTAssertEqual(readVarint(channel, &cIdx), 2, "role SECONDARY = 2")
                sawRole = true
            default:
                XCTFail("unexpected Channel field \(t.field)/\(t.wire)")
                return
            }
        }
        XCTAssertTrue(sawIndex && sawSettings && sawRole, "all Channel fields present")

        // ChannelSettings { psk=2 (bytes), name=3 (string) }
        var sIdx = 0
        var sawPsk = false, sawName = false
        while sIdx < settingsBody.count {
            guard let t = readTag(settingsBody, &sIdx) else { break }
            switch (t.field, t.wire) {
            case (2, 2):
                XCTAssertEqual(readLen(settingsBody, &sIdx), psk, "psk bytes")
                sawPsk = true
            case (3, 2):
                let nameData = readLen(settingsBody, &sIdx) ?? Data()
                XCTAssertEqual(String(data: nameData, encoding: .utf8), "OmniTAK", "channel name")
                sawName = true
            default:
                XCTFail("unexpected ChannelSettings field \(t.field)")
                return
            }
        }
        XCTAssertTrue(sawPsk && sawName, "psk + name present")
    }

    func testEncodeSetChannelPrimaryOmitsRoleZeroIsDisabled() {
        // role PRIMARY = 1 must be emitted (non-zero). Slot 0 is index 0, a
        // default, so a radio sends it with no index at all.
        guard let write = MeshtasticAdminCodec.encodeSetChannel(
            current: Data(), name: "Primary", key: .keep, role: .primary) else {
            return XCTFail("encodeSetChannel returned nil")
        }
        let admin = write.payload
        var idx = 0
        _ = readTag(admin, &idx)             // set_channel tag
        guard let channel = readLen(admin, &idx) else { return XCTFail("no channel") }
        var cIdx = 0
        var roleValue: UInt64? = nil
        while cIdx < channel.count {
            guard let t = readTag(channel, &cIdx) else { break }
            if t.field == 3 && t.wire == 0 { roleValue = readVarint(channel, &cIdx) }
            else if t.wire == 2 { _ = readLen(channel, &cIdx) }
            else { _ = readVarint(channel, &cIdx) }
        }
        XCTAssertEqual(roleValue, 1, "PRIMARY role value 1 emitted")
    }

    // MARK: - Meshtastic set_config (device role + rebroadcast)

    func testEncodeSetDeviceConfigLayout() {
        // KNOWN_ONLY is the PatoG1899 "rebroadcast known channels only" ask.
        guard let write = MeshtasticAdminCodec.encodeSetDeviceConfig(
            current: Data(), role: .tak, rebroadcastMode: .knownOnly) else {
            return XCTFail("encodeSetDeviceConfig returned nil")
        }
        let admin = write.payload

        // AdminMessage { set_config = 34 }
        var idx = 0
        guard let tag = readTag(admin, &idx) else { return XCTFail("no admin tag") }
        XCTAssertEqual(tag.field, 34, "set_config field number")
        XCTAssertEqual(tag.wire, 2)

        guard let config = readLen(admin, &idx) else { return XCTFail("no Config body") }

        // Config { device = 1 }
        var cfgIdx = 0
        guard let dtag = readTag(config, &cfgIdx), dtag.field == 1, dtag.wire == 2 else {
            return XCTFail("Config.device field 1 missing")
        }
        guard let device = readLen(config, &cfgIdx) else { return XCTFail("no DeviceConfig") }

        // DeviceConfig { role=1, rebroadcast_mode=6 }
        var dIdx = 0
        var role: UInt64? = nil, rebroadcast: UInt64? = nil
        while dIdx < device.count {
            guard let t = readTag(device, &dIdx) else { break }
            switch (t.field, t.wire) {
            case (1, 0): role = readVarint(device, &dIdx)
            case (6, 0): rebroadcast = readVarint(device, &dIdx)
            default: _ = t.wire == 2 ? (readLen(device, &dIdx).map { _ in () }) : (readVarint(device, &dIdx).map { _ in () })
            }
        }
        XCTAssertEqual(role, 7, "DeviceConfig.Role TAK = 7")
        XCTAssertEqual(rebroadcast, 3, "RebroadcastMode KNOWN_ONLY = 3")
    }

    func testRebroadcastEnumValues() {
        XCTAssertEqual(MeshtasticAdminCodec.RebroadcastMode.all.rawValue, 0)
        XCTAssertEqual(MeshtasticAdminCodec.RebroadcastMode.localOnly.rawValue, 2)
        XCTAssertEqual(MeshtasticAdminCodec.RebroadcastMode.knownOnly.rawValue, 3)
        XCTAssertEqual(MeshtasticAdminCodec.RebroadcastMode.noRebroadcast.rawValue, 4)
    }

    func testDeviceRoleEnumValues() {
        XCTAssertEqual(MeshtasticAdminCodec.DeviceRole.client.rawValue, 0)
        XCTAssertEqual(MeshtasticAdminCodec.DeviceRole.router.rawValue, 2)
        XCTAssertEqual(MeshtasticAdminCodec.DeviceRole.tracker.rawValue, 5)
        XCTAssertEqual(MeshtasticAdminCodec.DeviceRole.tak.rawValue, 7)
        XCTAssertEqual(MeshtasticAdminCodec.DeviceRole.takTracker.rawValue, 10)
    }

    // MARK: - Meshtastic set_config (position interval)

    func testEncodeSetPositionIntervalLayout() {
        guard let write = MeshtasticAdminCodec.encodeSetPositionBroadcastInterval(
            current: Data(), seconds: 900) else {
            return XCTFail("encodeSetPositionBroadcastInterval returned nil")
        }
        let admin = write.payload
        var idx = 0
        guard let tag = readTag(admin, &idx), tag.field == 34, tag.wire == 2 else {
            return XCTFail("set_config tag")
        }
        guard let config = readLen(admin, &idx) else { return XCTFail("no Config") }

        // Config { position = 2 }
        var cfgIdx = 0
        guard let ptag = readTag(config, &cfgIdx), ptag.field == 2, ptag.wire == 2 else {
            return XCTFail("Config.position field 2 missing")
        }
        guard let position = readLen(config, &cfgIdx) else { return XCTFail("no PositionConfig") }

        // PositionConfig { position_broadcast_secs = 1 }
        var pIdx = 0
        guard let st = readTag(position, &pIdx), st.field == 1, st.wire == 0 else {
            return XCTFail("position_broadcast_secs field 1 missing")
        }
        XCTAssertEqual(readVarint(position, &pIdx), 900, "interval seconds")
    }

    // MARK: - MeshCore CMD_SET_CHANNEL

    func testMeshCoreSetChannelLayout() {
        let secret = Data((0..<16).map { UInt8($0) }) // 16-byte secret
        guard let frame = MeshCoreFrameCodec.encodeSetChannel(
            index: 1, name: "SMS", secret: secret) else {
            return XCTFail("encodeSetChannel returned nil")
        }
        // [0x20][index][name 32][secret 16] = 50 bytes
        XCTAssertEqual(frame.count, 50, "total length 50 bytes")
        XCTAssertEqual(frame[0], 0x20, "CMD_SET_CHANNEL")
        XCTAssertEqual(frame[1], 1, "channel index")

        // Name: "SMS" then null padding, bytes 2..33.
        XCTAssertEqual(Array(frame[2..<5]), Array("SMS".utf8))
        for i in 5..<34 { XCTAssertEqual(frame[i], 0x00, "name padding byte \(i)") }

        // Secret: bytes 34..49 verbatim.
        XCTAssertEqual(Array(frame[34..<50]), Array(secret))
    }

    func testMeshCoreSetChannelTruncatesLongName() {
        let longName = String(repeating: "A", count: 40)
        guard let frame = MeshCoreFrameCodec.encodeSetChannel(
            index: 2, name: longName, secret: Data()) else {
            return XCTFail("nil frame")
        }
        XCTAssertEqual(frame.count, 50)
        // name region (2..33) is all 'A' when truncated to 32 bytes.
        for i in 2..<34 { XCTAssertEqual(frame[i], UInt8(ascii: "A")) }
        // secret region all zero (public / empty secret).
        for i in 34..<50 { XCTAssertEqual(frame[i], 0x00) }
    }

    func testMeshCoreSetChannelRejectsBadIndex() {
        XCTAssertNil(MeshCoreFrameCodec.encodeSetChannel(index: 8, name: "x", secret: Data()))
        XCTAssertNil(MeshCoreFrameCodec.encodeSetChannel(index: -1, name: "x", secret: Data()))
    }

    // MARK: - Share round-trip (cross-transport dispatch)

    func testShareParseRoundTripMeshtastic() {
        let url = MeshChannelShare.shareURL(
            transport: .meshtastic,
            meshtastic: [MeshChannel(name: "Alpha", psk: Data([0xAA, 0xBB]))])
        XCTAssertNotNil(url)
        guard case .meshtastic(let chans)? = MeshChannelShare.parse(url!) else {
            return XCTFail("did not parse back as meshtastic")
        }
        XCTAssertEqual(chans.first?.name, "Alpha")
    }

    func testShareParseRoundTripMeshCore() {
        let secret = Data((0..<16).map { _ in UInt8(0x5A) })
        let url = MeshChannelShare.shareURL(
            transport: .meshcore,
            meshcore: MeshCoreChannel(name: "Bravo", secret: secret))
        XCTAssertNotNil(url)
        guard case .meshcore(let ch)? = MeshChannelShare.parse(url!) else {
            return XCTFail("did not parse back as meshcore")
        }
        XCTAssertEqual(ch.name, "Bravo")
        XCTAssertEqual(ch.secret, secret)
    }
}
