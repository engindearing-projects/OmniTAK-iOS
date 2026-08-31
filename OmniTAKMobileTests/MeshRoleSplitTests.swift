//
//  MeshRoleSplitTests.swift
//  OmniTAKMobileTests
//
//  Android parity for #186 item 2 — the paired-radio visibility split.
//
//  Field report (PatoG, 5 clients + 6 TAK-profile radios): an operator
//  carrying a phone AND a paired Meshtastic radio showed up on everyone's map
//  as two dots that drifted apart. The radio reports its own GPS; the phone
//  reports the operator. Meshtastic already distinguishes the two — the radio
//  runs role TAK — but the iOS NodeInfo parser skipped `User.role` entirely.
//
//  Covers:
//    • MeshtasticTCPClient.parseUserSubmessage — decodes User.role (field 7,
//      varint) alongside long_name (2) and short_name (3), tolerates absent
//      and unknown fields. The BLE client carries a byte-identical decoder.
//    • MeshNode.isTakPaired — role TAK only, not TAK_TRACKER.
//    • MeshtasticManager.mapVisibleNodes — hides paired radios by default,
//      keeps standalone trackers, honours the opt-in.
//
//  Pure logic — no socket, no CoreBluetooth, no map.
//

import XCTest
@testable import OmniTAK

final class MeshRoleSplitTests: XCTestCase {

    // MARK: - Wire-format helpers (canonical Meshtastic User submessage)

    /// Length-delimited field: tag = (field << 3) | 2.
    private func lenField(_ field: Int, _ text: String) -> Data {
        let bytes = Array(text.utf8)
        var d = Data([UInt8((field << 3) | 2), UInt8(bytes.count)])
        d.append(contentsOf: bytes)
        return d
    }

    /// Varint field: tag = (field << 3) | 0. Values here are all < 128.
    private func varintField(_ field: Int, _ value: UInt8) -> Data {
        Data([UInt8((field << 3) | 0), value])
    }

    private func decode(_ user: Data) -> (short: String, long: String, role: Int?) {
        let client = MeshtasticTCPClient()
        return client.parseUserSubmessage(user, from: 0, end: user.count)
    }

    // MARK: - Decode

    func testDecodesRoleAlongsideNames() {
        var user = Data()
        user.append(lenField(2, "Pato Golf"))   // long_name
        user.append(lenField(3, "PATO"))        // short_name
        user.append(varintField(7, 7))          // role = TAK

        let out = decode(user)
        XCTAssertEqual(out.long, "Pato Golf")
        XCTAssertEqual(out.short, "PATO")
        XCTAssertEqual(out.role, MeshNode.roleTAK)
    }

    func testRoleAbsentDecodesAsNil() {
        var user = Data()
        user.append(lenField(2, "Old Firmware"))
        user.append(lenField(3, "OLD"))

        let out = decode(user)
        XCTAssertEqual(out.short, "OLD")
        XCTAssertNil(out.role, "A NodeInfo with no role field must not invent one")
    }

    func testUnknownFieldsAreSkippedWithoutLosingRole() {
        var user = Data()
        user.append(lenField(1, "!a1b2c3d4"))   // id (field 1) — we ignore it
        user.append(lenField(2, "Tracker One"))
        user.append(varintField(5, 9))          // hw_model — ignored varint
        user.append(varintField(6, 1))          // is_licensed — ignored varint
        user.append(lenField(3, "TRK1"))
        user.append(varintField(7, 10))         // role = TAK_TRACKER

        let out = decode(user)
        XCTAssertEqual(out.long, "Tracker One")
        XCTAssertEqual(out.short, "TRK1")
        XCTAssertEqual(out.role, MeshNode.roleTAKTracker)
    }

    // MARK: - Classification

    func testOnlyRoleTAKCountsAsPaired() {
        XCTAssertTrue(node(role: MeshNode.roleTAK).isTakPaired)
        XCTAssertFalse(node(role: MeshNode.roleTAKTracker).isTakPaired,
                       "A TAK_TRACKER is a standalone asset, not a doubled operator")
        XCTAssertFalse(node(role: 0).isTakPaired)     // CLIENT
        XCTAssertFalse(node(role: nil).isTakPaired)   // unknown firmware
    }

    // MARK: - Map split

    func testPairedRadiosAreHiddenByDefault() {
        let nodes = [node(id: 1, role: MeshNode.roleTAK),
                     node(id: 2, role: MeshNode.roleTAKTracker),
                     node(id: 3, role: nil)]

        let visible = MeshtasticManager.mapVisibleNodes(nodes, showPairedRadios: false)

        XCTAssertEqual(visible.map(\.id), [2, 3],
                       "The paired radio drops out; tracker and unknown-role nodes stay")
    }

    func testOptingInShowsPairedRadios() {
        let nodes = [node(id: 1, role: MeshNode.roleTAK),
                     node(id: 2, role: nil)]

        let visible = MeshtasticManager.mapVisibleNodes(nodes, showPairedRadios: true)

        XCTAssertEqual(visible.count, 2)
    }

    // MARK: - Fixture

    private func node(id: UInt32 = 1, role: Int?) -> MeshNode {
        MeshNode(id: id,
                 shortName: "N\(id)",
                 longName: "Node \(id)",
                 lastHeard: Date(),
                 role: role)
    }
}
