//
//  MeshDeviceConfigTests.swift
//  OmniTAKMobileTests
//
//  Byte-layout tests for the Meshtastic device-config writes (OmniTAK-iOS #112,
//  Android parity #181): LoRa region, modem preset and device long/short name.
//
//  Region is a REGULATORY setting — the wire value decides which band the radio
//  keys up on. A transposed ordinal puts an operator on a frequency they are not
//  licensed for in that jurisdiction, and the radio will happily do it. So every
//  value below is pinned to the firmware `Config.LoRaConfig.RegionCode` literal
//  rather than round-tripped: a round-trip test passes just as happily against a
//  consistently wrong table.
//
//  Field numbers / enum values are facts from the published wire spec
//  (admin.proto, config.proto, mesh.proto).
//

import XCTest
@testable import OmniTAK

final class MeshDeviceConfigTests: XCTestCase {

    // MARK: - Helpers (manual varint reader mirroring the codec)

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

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    /// Unwrap `AdminMessage{ set_config=34 } -> Config{ lora=6 }` and hand back
    /// the raw LoRaConfig body.
    private func loraBody(_ admin: Data, file: StaticString = #filePath, line: UInt = #line) -> Data? {
        var idx = 0
        guard let tag = readTag(admin, &idx) else { XCTFail("no admin tag", file: file, line: line); return nil }
        XCTAssertEqual(tag.field, 34, "AdminMessage.set_config = 34", file: file, line: line)
        XCTAssertEqual(tag.wire, 2, file: file, line: line)
        guard let config = readLen(admin, &idx) else { XCTFail("no Config body", file: file, line: line); return nil }
        var cIdx = 0
        guard let ltag = readTag(config, &cIdx), ltag.field == 6, ltag.wire == 2 else {
            XCTFail("Config.lora field 6 missing", file: file, line: line); return nil
        }
        return readLen(config, &cIdx)
    }

    /// Collect every varint field in a submessage body as field -> value.
    private func varintFields(_ body: Data) -> [Int: UInt64] {
        var out: [Int: UInt64] = [:]
        var idx = 0
        while idx < body.count {
            guard let t = readTag(body, &idx) else { break }
            if t.wire == 0 {
                out[t.field] = readVarint(body, &idx) ?? 0
            } else if t.wire == 2 {
                _ = readLen(body, &idx)
            } else { break }
        }
        return out
    }

    // MARK: - RegionCode wire values (regulatory — pin every one)

    func testLoRaRegionWireValuesMatchFirmware() {
        typealias R = MeshtasticAdminCodec.LoRaRegion
        XCTAssertEqual(R.unset.rawValue, 0, "UNSET")
        XCTAssertEqual(R.us.rawValue, 1, "US")
        XCTAssertEqual(R.eu433.rawValue, 2, "EU_433")
        XCTAssertEqual(R.eu868.rawValue, 3, "EU_868")
        XCTAssertEqual(R.cn.rawValue, 4, "CN")
        XCTAssertEqual(R.jp.rawValue, 5, "JP")
        XCTAssertEqual(R.anz.rawValue, 6, "ANZ")
        XCTAssertEqual(R.kr.rawValue, 7, "KR")
        XCTAssertEqual(R.tw.rawValue, 8, "TW")
        XCTAssertEqual(R.ru.rawValue, 9, "RU")
        XCTAssertEqual(R.india.rawValue, 10, "IN")
        XCTAssertEqual(R.nz865.rawValue, 11, "NZ_865")
        XCTAssertEqual(R.th.rawValue, 12, "TH")
        XCTAssertEqual(R.lora24.rawValue, 13, "LORA_24")
        XCTAssertEqual(R.ua433.rawValue, 14, "UA_433")
        XCTAssertEqual(R.ua868.rawValue, 15, "UA_868")
        XCTAssertEqual(R.my433.rawValue, 16, "MY_433")
        XCTAssertEqual(R.my919.rawValue, 17, "MY_919")
        XCTAssertEqual(R.sg923.rawValue, 18, "SG_923")
        XCTAssertEqual(R.ph433.rawValue, 19, "PH_433")
        XCTAssertEqual(R.ph868.rawValue, 20, "PH_868")
        XCTAssertEqual(R.ph915.rawValue, 21, "PH_915")
        XCTAssertEqual(R.anz433.rawValue, 22, "ANZ_433")
        XCTAssertEqual(R.kz433.rawValue, 23, "KZ_433")
        XCTAssertEqual(R.kz863.rawValue, 24, "KZ_863")
        XCTAssertEqual(R.np865.rawValue, 25, "NP_865")
        XCTAssertEqual(R.br902.rawValue, 26, "BR_902")
    }

    /// A future insertion that shifts ordinals is the failure mode that puts a
    /// radio on the wrong band, so pin the shape of the table too.
    func testLoRaRegionTableIsContiguousAndComplete() {
        let values = MeshtasticAdminCodec.LoRaRegion.allCases.map { $0.rawValue }.sorted()
        XCTAssertEqual(values.count, 27, "RegionCode 0…26")
        XCTAssertEqual(values, Array(0...26), "no gaps, no duplicates")
        for region in MeshtasticAdminCodec.LoRaRegion.allCases {
            XCTAssertFalse(region.displayName.isEmpty, "\(region) needs an operator-facing label")
        }
    }

    // MARK: - ModemPreset wire values

    func testModemPresetWireValuesMatchFirmware() {
        typealias P = MeshtasticAdminCodec.ModemPreset
        XCTAssertEqual(P.longFast.rawValue, 0)
        XCTAssertEqual(P.longSlow.rawValue, 1)
        XCTAssertEqual(P.veryLongSlow.rawValue, 2)
        XCTAssertEqual(P.mediumSlow.rawValue, 3)
        XCTAssertEqual(P.mediumFast.rawValue, 4)
        XCTAssertEqual(P.shortSlow.rawValue, 5)
        XCTAssertEqual(P.shortFast.rawValue, 6)
        XCTAssertEqual(P.longModerate.rawValue, 7)
        XCTAssertEqual(P.shortTurbo.rawValue, 8)
    }

    /// LONG_MODERATE (7) sits between SHORT_FAST and SHORT_TURBO in the
    /// firmware enum. Any table built from UI declaration order lands
    /// SHORT_TURBO on 7 and silently runs the radio at the wrong bandwidth.
    func testShortTurboIsEightNotSeven() {
        XCTAssertEqual(MeshtasticAdminCodec.ModemPreset.shortTurbo.rawValue, 8)
        XCTAssertNotEqual(MeshtasticAdminCodec.ModemPreset.shortTurbo.rawValue,
                          MeshtasticAdminCodec.ModemPreset.longModerate.rawValue)
        for preset in MeshtasticAdminCodec.ModemPreset.allCases {
            XCTAssertFalse(preset.displayName.isEmpty, "\(preset) needs a label")
            XCTAssertFalse(preset.blurb.isEmpty, "\(preset) needs a range/throughput blurb")
        }
    }

    // MARK: - set_config { lora } byte layout

    func testEncodeSetLoRaConfigLayout() {
        guard let admin = MeshtasticAdminCodec.encodeSetLoRaConfig(
            region: .eu868, modemPreset: .mediumFast) else {
            return XCTFail("encoder refused a valid region")
        }
        guard let lora = loraBody(admin) else { return }

        // LoRaConfig { use_preset=1, modem_preset=2, region=7, hop_limit=8, tx_enabled=9 }
        let fields = varintFields(lora)
        XCTAssertEqual(fields[1], 1, "use_preset must be true — OmniTAK only exposes presets")
        XCTAssertEqual(fields[2], 4, "modem_preset MEDIUM_FAST = 4")
        XCTAssertEqual(fields[7], 3, "region EU_868 = 3")
        XCTAssertEqual(fields[8], 3, "hop_limit")
        XCTAssertEqual(fields[9], 1, "tx_enabled")
    }

    /// `AdminMessage.set_config` REPLACES the whole submessage on the radio —
    /// a LoRaConfig that omits tx_enabled leaves it at the proto3 default
    /// (false) and the radio stops keying up. Every write must carry it.
    func testEncodeSetLoRaConfigAlwaysEmitsTxEnabled() {
        for region in MeshtasticAdminCodec.LoRaRegion.allCases where region != .unset {
            for preset in MeshtasticAdminCodec.ModemPreset.allCases {
                guard let admin = MeshtasticAdminCodec.encodeSetLoRaConfig(
                    region: region, modemPreset: preset),
                      let lora = loraBody(admin) else {
                    XCTFail("no payload for \(region)/\(preset)")
                    continue
                }
                let fields = varintFields(lora)
                XCTAssertEqual(fields[9], 1, "tx_enabled missing for \(region)/\(preset)")
                XCTAssertEqual(fields[1], 1, "use_preset missing for \(region)/\(preset)")
                XCTAssertEqual(fields[7], region.rawValue, "region wire value for \(region)")
                XCTAssertEqual(fields[2], preset.rawValue, "modem_preset wire value for \(preset)")
                XCTAssertNotEqual(fields[8], 0, "hop_limit 0 would stop the mesh relaying")
            }
        }
    }

    /// Exact bytes for the ANZ 433 / Short Turbo write — the pair most likely to
    /// be transposed (region 22, preset 8).
    func testEncodeSetLoRaConfigExactBytes() {
        guard let admin = MeshtasticAdminCodec.encodeSetLoRaConfig(
            region: .anz433, modemPreset: .shortTurbo, hopLimit: 3) else {
            return XCTFail("nil payload")
        }
        // 92 02      AdminMessage field 34, wire 2
        // 0c         len 12
        //   32 0a    Config field 6, wire 2, len 10
        //     08 01  use_preset  = true
        //     10 08  modem_preset = SHORT_TURBO (8)
        //     38 16  region       = ANZ_433 (22)
        //     40 03  hop_limit    = 3
        //     48 01  tx_enabled   = true
        XCTAssertEqual(hex(admin), "92020c320a08011008381640034801")
    }

    /// Region UNSET is not a config, it is the absence of one. Writing it would
    /// clear the region on a radio that already had a legal one and mute it.
    func testEncodeSetLoRaConfigRefusesUnsetRegion() {
        XCTAssertNil(MeshtasticAdminCodec.encodeSetLoRaConfig(region: .unset, modemPreset: .longFast))
    }

    // MARK: - set_owner byte layout

    func testEncodeSetOwnerLayout() {
        guard let admin = MeshtasticAdminCodec.encodeSetOwner(longName: "Ranger 6", shortName: "RG6") else {
            return XCTFail("nil payload")
        }
        var idx = 0
        guard let tag = readTag(admin, &idx) else { return XCTFail("no admin tag") }
        XCTAssertEqual(tag.field, 32, "AdminMessage.set_owner = 32")
        XCTAssertEqual(tag.wire, 2)
        guard let user = readLen(admin, &idx) else { return XCTFail("no User body") }

        // User { long_name=2, short_name=3 }
        var uIdx = 0
        var long: String?, short: String?
        while uIdx < user.count {
            guard let t = readTag(user, &uIdx) else { break }
            switch (t.field, t.wire) {
            case (2, 2): long = String(data: readLen(user, &uIdx) ?? Data(), encoding: .utf8)
            case (3, 2): short = String(data: readLen(user, &uIdx) ?? Data(), encoding: .utf8)
            default:
                XCTFail("unexpected User field \(t.field)/\(t.wire) — id/hw_model/role must be left alone")
                return
            }
        }
        XCTAssertEqual(long, "Ranger 6")
        XCTAssertEqual(short, "RG6")
    }

    // MARK: - Name sanitising (operator-supplied text on a byte-budgeted field)

    /// nanopb sizes `User.long_name` at char[40] and `short_name` at char[5] —
    /// one byte of each is the NUL terminator, so 39 / 4 usable bytes.
    func testNameByteBudgetsMatchFirmware() {
        XCTAssertEqual(MeshtasticAdminCodec.longNameMaxBytes, 39)
        XCTAssertEqual(MeshtasticAdminCodec.shortNameMaxBytes, 4)
    }

    func testLongNameClampsToByteBudget() {
        let long = String(repeating: "A", count: 80)
        let clamped = MeshtasticAdminCodec.sanitizedName(long, maxBytes: MeshtasticAdminCodec.longNameMaxBytes)
        XCTAssertEqual(clamped.utf8.count, 39)
    }

    /// A multi-byte name must clamp on a character boundary — a name cut
    /// mid-scalar is invalid UTF-8 and nanopb rejects the whole AdminMessage,
    /// so the write silently does nothing.
    func testMultiByteNameClampsOnCharacterBoundary() {
        // 20 × 3-byte CJK = 60 bytes; 39-byte budget fits 13 characters (39 bytes).
        let cjk = String(repeating: "台", count: 20)
        let clamped = MeshtasticAdminCodec.sanitizedName(cjk, maxBytes: MeshtasticAdminCodec.longNameMaxBytes)
        XCTAssertEqual(clamped.utf8.count, 39)
        XCTAssertEqual(clamped.count, 13, "13 whole characters, not 39 bytes of half a character")
        XCTAssertEqual(String(data: Data(clamped.utf8), encoding: .utf8), clamped, "still valid UTF-8")
    }

    /// Short name budget is 4 bytes: two CJK characters are 6 bytes, so only
    /// one survives. Truncating to 4 bytes would split the second one.
    func testShortNameClampsMultiByteWithoutSplitting() {
        let clamped = MeshtasticAdminCodec.sanitizedName("台北", maxBytes: MeshtasticAdminCodec.shortNameMaxBytes)
        XCTAssertEqual(clamped, "台")
        XCTAssertEqual(clamped.utf8.count, 3)
    }

    /// An emoji that is a single grapheme but 4+ bytes either fits whole or is
    /// dropped — never half-emitted.
    func testGraphemeLongerThanBudgetIsDropped() {
        let clamped = MeshtasticAdminCodec.sanitizedName("👨‍👩‍👧", maxBytes: 4)
        XCTAssertTrue(clamped.isEmpty || clamped.utf8.count <= 4)
        XCTAssertEqual(String(data: Data(clamped.utf8), encoding: .utf8), clamped, "valid UTF-8")
    }

    /// Control and format characters can spoof a callsign in the node list (and
    /// a newline breaks any log line the name lands in). Strip, don't pass on.
    func testControlCharactersAreStripped() {
        let dirty = "Al\u{0000}pha\u{0007}\nBra\u{200B}vo\t"
        let clean = MeshtasticAdminCodec.sanitizedName(dirty, maxBytes: MeshtasticAdminCodec.longNameMaxBytes)
        XCTAssertFalse(clean.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertFalse(clean.contains("\n"))
        XCTAssertFalse(clean.contains("\t"))
        XCTAssertTrue(clean.hasPrefix("Al"))
    }

    func testSurroundingWhitespaceTrimmed() {
        XCTAssertEqual(MeshtasticAdminCodec.sanitizedName("  Bravo  ", maxBytes: 39), "Bravo")
    }

    func testEncodeSetOwnerSanitisesAndClamps() {
        let longRaw = String(repeating: "台", count: 30) // 90 bytes
        guard let admin = MeshtasticAdminCodec.encodeSetOwner(longName: longRaw, shortName: "AB\u{0000}CDEF") else {
            return XCTFail("nil payload")
        }
        var idx = 0
        _ = readTag(admin, &idx)
        guard let user = readLen(admin, &idx) else { return XCTFail("no User") }
        var uIdx = 0
        var long = Data(), short = Data()
        while uIdx < user.count {
            guard let t = readTag(user, &uIdx) else { break }
            if t.field == 2 { long = readLen(user, &uIdx) ?? Data() }
            else if t.field == 3 { short = readLen(user, &uIdx) ?? Data() }
            else { _ = readLen(user, &uIdx) }
        }
        XCTAssertLessThanOrEqual(long.count, MeshtasticAdminCodec.longNameMaxBytes)
        XCTAssertLessThanOrEqual(short.count, MeshtasticAdminCodec.shortNameMaxBytes)
        XCTAssertNotNil(String(data: long, encoding: .utf8), "long_name is valid UTF-8")
        XCTAssertEqual(String(data: short, encoding: .utf8), "ABCD", "NUL stripped, then clamped to 4")
    }

    /// Nothing usable left after sanitising is a refusal, not an empty write.
    func testEncodeSetOwnerRefusesWhenBothNamesEmpty() {
        XCTAssertNil(MeshtasticAdminCodec.encodeSetOwner(longName: "  ", shortName: "\u{0000}"))
    }

    /// `handleSetOwner` on the radio merges non-empty names, so one-sided
    /// writes are well-defined: omit the blank field rather than clearing it.
    func testEncodeSetOwnerOmitsBlankShortName() {
        guard let admin = MeshtasticAdminCodec.encodeSetOwner(longName: "Alpha", shortName: "") else {
            return XCTFail("nil payload")
        }
        var idx = 0
        _ = readTag(admin, &idx)
        guard let user = readLen(admin, &idx) else { return XCTFail("no User") }
        var uIdx = 0
        var seen: Set<Int> = []
        while uIdx < user.count {
            guard let t = readTag(user, &uIdx) else { break }
            seen.insert(t.field)
            _ = readLen(user, &uIdx)
        }
        XCTAssertEqual(seen, [2], "only long_name on the wire")
    }

    // MARK: - Admin destination

    /// Admin writes are unicast to our own node so the firmware applies them
    /// locally. Broadcasting one instead puts config (and, on the channel path,
    /// the PSK) on the air for every radio in range.
    func testAdminDestinationRequiresKnownNodeNum() {
        XCTAssertEqual(MeshtasticAdminCodec.adminDestination(myNodeNum: 0x11223344), 0x11223344)
        XCTAssertNil(MeshtasticAdminCodec.adminDestination(myNodeNum: 0),
                     "no node number yet — must not fall back to broadcast")
        XCTAssertNil(MeshtasticAdminCodec.adminDestination(myNodeNum: 0xFFFFFFFF),
                     "broadcast address is never a valid admin destination")
    }
}
