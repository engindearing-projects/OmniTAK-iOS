//
//  MeshBroadcastTests.swift
//  OmniTAKMobileTests
//
//  Issue #46 Phase 1 — off-grid OmniTAK↔OmniTAK over Meshtastic.
//
//  These tests exercise the *pure* decision layer of the mesh off-grid path so
//  the routing/throttle/attribution logic is verified without a radio:
//
//    1. Outbound routing decision (MeshTAKRouting.decide) — which mesh payload
//       encoder fires for a given CoT type (PLI / GeoChat TAKPacket vs the
//       OmniTAK↔OmniTAK TAKMessage fallback).
//    2. CoT↔mesh-frame encoding + attribution — the bytes the routing decision
//       selects actually carry the callsign/team/message (round-trip through
//       TAKPacketCodec and ATAKPluginSerializer/Parser).
//    3. PPLI throttle decision (PositionBroadcastService.shouldSendMeshPPLI) —
//       the time-window gate that keeps low-bandwidth LoRa from being saturated.
//    4. Inbound mesh → contact/chat mapping (ATAKPluginParser.classify) — a
//       remote PLI becomes a map contact (.positionUpdate); a remote GeoChat
//       becomes a chat message (.chatMessage) attributed to its sender.
//
//  The end-to-end mesh link (BLE/TCP → LoRa → peer) is NOT exercised here — that
//  needs two Meshtastic radios and is covered by the on-hardware checklist in the
//  PR. Everything below is deterministic pure Swift against the linked module.
//

import XCTest
@testable import OmniTAK

final class MeshBroadcastTests: XCTestCase {

    // MARK: - Fixtures

    /// A self-SA PLI event (what PositionBroadcastService emits over the mesh).
    private func makePLIEvent() -> CoTEvent {
        CoTEvent(
            uid: "IOS-1234abcd",
            type: "a-f-G-U-C",
            time: Date(timeIntervalSince1970: 1_714_000_000),
            point: CoTPoint(lat: 47.6062, lon: -122.3321, hae: 56.0, ce: 5, le: 5),
            detail: CoTDetail(
                callsign: "ALPHA-1",
                team: "Cyan",
                teamRole: "Team Member",
                speed: 3.0,
                course: 270.0,
                remarks: nil,
                battery: 85,
                device: nil,
                platform: nil
            )
        )
    }

    /// A GeoChat event (what ChatManager mirrors over the mesh).
    private func makeGeoChatEvent(text: String = "Moving to OBJ Bravo") -> CoTEvent {
        CoTEvent(
            uid: "MSG-deadbeef",
            type: "b-t-f",
            time: Date(timeIntervalSince1970: 1_714_000_000),
            point: CoTPoint(lat: 0, lon: 0, hae: 0, ce: 9999, le: 9999),
            detail: CoTDetail(
                callsign: "BRAVO-2",
                team: nil,
                teamRole: nil,
                speed: nil,
                course: nil,
                remarks: text,
                battery: nil,
                device: nil,
                platform: nil
            )
        )
    }

    // MARK: - 1. Outbound routing decision

    func testRoutingPLIUsesTAKPacket() {
        let decision = MeshTAKRouting.decide(for: makePLIEvent())
        XCTAssertEqual(decision, .takPacket,
            "a-* (PLI) events must route to the compact TAKPacket encoder for ecosystem interop")
    }

    func testRoutingGeoChatUsesTAKPacket() {
        let decision = MeshTAKRouting.decide(for: makeGeoChatEvent())
        XCTAssertEqual(decision, .takPacket,
            "b-t-f (GeoChat) events must route to the compact TAKPacket GeoChat encoder")
    }

    func testRoutingOtherTypeUsesTAKMessageFallback() {
        // A waypoint (b-m-p-w) is neither a-* nor b-t-f — it must take the
        // OmniTAK↔OmniTAK TAKMessage{CoTEvent} fallback, not TAKPacket.
        let waypoint = CoTEvent(
            uid: "WPT-1",
            type: "b-m-p-w",
            time: Date(),
            point: CoTPoint(lat: 47.0, lon: -122.0, hae: 0, ce: 9999, le: 9999),
            detail: CoTDetail(callsign: "WPT", team: nil, teamRole: nil, speed: nil,
                              course: nil, remarks: "rally", battery: nil,
                              device: nil, platform: nil)
        )
        XCTAssertEqual(MeshTAKRouting.decide(for: waypoint), .takMessage,
            "non-PLI/non-chat events must fall back to the TAKMessage path")
    }

    // MARK: - 2. Encoding selected by the routing decision carries attribution

    func testEncodePayloadForPLIRoundTripsToContact() {
        let event = makePLIEvent()
        // Routing says TAKPacket — encode the payload the manager would send.
        XCTAssertEqual(MeshTAKRouting.decide(for: event), .takPacket)
        guard let payload = MeshTAKRouting.encodePayload(for: event) else {
            return XCTFail("encodePayload returned nil for a PLI event")
        }
        XCTAssertFalse(payload.isEmpty, "PLI payload must not be empty")

        // The wire bytes must decode back to the same position + team + callsign.
        guard let pkt = TAKPacketCodec.decode(payload) else {
            return XCTFail("TAKPacketCodec.decode failed on the PLI payload we encoded")
        }
        XCTAssertTrue(pkt.hasPLI, "encoded PLI must decode as a PLI")
        XCTAssertEqual(pkt.callsign, "ALPHA-1", "callsign attribution must survive encode")
        XCTAssertEqual(pkt.team, .cyan, "team attribution must survive encode")
        XCTAssertEqual(pkt.latitudeI, 476062000, "latitude_i must survive encode")
        XCTAssertEqual(pkt.longitudeI, -1223321000, "longitude_i must survive encode")
    }

    func testEncodePayloadForGeoChatRoundTripsToMessage() {
        let event = makeGeoChatEvent(text: "RTO actual, sitrep?")
        XCTAssertEqual(MeshTAKRouting.decide(for: event), .takPacket)
        guard let payload = MeshTAKRouting.encodePayload(for: event) else {
            return XCTFail("encodePayload returned nil for a GeoChat event")
        }

        guard let pkt = TAKPacketCodec.decode(payload) else {
            return XCTFail("TAKPacketCodec.decode failed on the GeoChat payload we encoded")
        }
        XCTAssertTrue(pkt.hasChat, "encoded GeoChat must decode as a chat")
        XCTAssertEqual(pkt.chatMessage, "RTO actual, sitrep?",
            "chat text attribution must survive encode (unishox2 round-trip)")
        XCTAssertEqual(pkt.callsign, "BRAVO-2", "sender callsign must survive encode")
    }

    func testEncodePayloadFallbackRoundTripsViaTAKMessage() {
        // For the fallback path, encodePayload yields a TAKMessage that the
        // inbound ATAKPluginParser must be able to read back.
        let event = CoTEvent(
            uid: "WPT-roundtrip",
            type: "b-m-p-w",
            time: Date(timeIntervalSince1970: 1_714_000_000),
            point: CoTPoint(lat: 47.5, lon: -122.5, hae: 12, ce: 9999, le: 9999),
            detail: CoTDetail(callsign: "WPT-CS", team: nil, teamRole: nil, speed: nil,
                              course: nil, remarks: nil, battery: nil,
                              device: nil, platform: nil)
        )
        XCTAssertEqual(MeshTAKRouting.decide(for: event), .takMessage)
        guard let payload = MeshTAKRouting.encodePayload(for: event) else {
            return XCTFail("encodePayload returned nil for the fallback path")
        }
        guard let parsed = ATAKPluginParser.parse(payload) else {
            return XCTFail("fallback TAKMessage payload should be readable by ATAKPluginParser")
        }
        XCTAssertEqual(parsed.uid, "WPT-roundtrip")
        XCTAssertEqual(parsed.type, "b-m-p-w")
        XCTAssertEqual(parsed.point.lat, 47.5, accuracy: 1e-6)
    }

    // MARK: - 3. PPLI throttle decision

    func testMeshPPLIFirstSendAlwaysAllowed() {
        // With no prior send, the first tick must be allowed regardless of interval.
        XCTAssertTrue(
            PositionBroadcastService.shouldSendMeshPPLI(lastSend: nil, now: Date(), interval: 30),
            "the first mesh PPLI (no prior send) must always be allowed")
    }

    func testMeshPPLIThrottleSuppressesWithinWindow() {
        let now = Date(timeIntervalSince1970: 1_714_000_000)
        let recent = now.addingTimeInterval(-5)   // 5 s ago, interval is 30 s
        XCTAssertFalse(
            PositionBroadcastService.shouldSendMeshPPLI(lastSend: recent, now: now, interval: 30),
            "a tick 5 s after the last send must be suppressed by the 30 s throttle")
    }

    func testMeshPPLIThrottleAllowsAfterWindow() {
        let now = Date(timeIntervalSince1970: 1_714_000_000)
        let old = now.addingTimeInterval(-35)      // 35 s ago, interval is 30 s
        XCTAssertTrue(
            PositionBroadcastService.shouldSendMeshPPLI(lastSend: old, now: now, interval: 30),
            "a tick 35 s after the last send must pass the 30 s throttle")
    }

    func testMeshPPLIThrottleBoundaryIsInclusive() {
        let now = Date(timeIntervalSince1970: 1_714_000_000)
        let exactly = now.addingTimeInterval(-30)  // exactly one interval ago
        XCTAssertTrue(
            PositionBroadcastService.shouldSendMeshPPLI(lastSend: exactly, now: now, interval: 30),
            "a tick exactly one interval after the last send must be allowed (>=)")
    }

    func testMeshPPLIDefaultIntervalWithinLoRaBudget() {
        // Domain constraint: the default must sit in the 30–60 s ATAK SA window
        // so we neither flood LoRa nor let peers go stale.
        let service = PositionBroadcastService.shared
        XCTAssertGreaterThanOrEqual(service.meshPPLIInterval, 30.0,
            "meshPPLIInterval must be >= 30 s (LoRa bandwidth budget)")
        XCTAssertLessThanOrEqual(service.meshPPLIInterval, 60.0,
            "meshPPLIInterval must be <= 60 s (reasonable SA cadence)")
    }

    // MARK: - 4. Inbound mesh → contact / chat mapping

    func testInboundPLIClassifiesAsPositionUpdate() {
        // A decoded remote PLI must land as a map contact, not a chat line.
        let event = makePLIEvent()
        switch ATAKPluginParser.classify(event) {
        case .positionUpdate(let e):
            XCTAssertEqual(e.detail.callsign, "ALPHA-1",
                "inbound PLI should surface the remote callsign as a contact")
        default:
            XCTFail("a-f-G-U-C (PLI) must classify as .positionUpdate for the map")
        }
    }

    func testInboundGeoChatClassifiesAsChatMessage() {
        let event = makeGeoChatEvent(text: "Hello from the mesh")
        switch ATAKPluginParser.classify(event) {
        case .chatMessage(let msg):
            XCTAssertEqual(msg.senderCallsign, "BRAVO-2",
                "inbound GeoChat must be attributed to its sender")
            XCTAssertEqual(msg.messageText, "Hello from the mesh")
            XCTAssertEqual(msg.conversationId, ChatRoom.allUsersId,
                "broadcast mesh chat lands in All Chat Users")
            XCTAssertFalse(msg.isFromSelf, "inbound mesh chat is from a peer, not self")
        default:
            XCTFail("b-t-f (GeoChat) must classify as .chatMessage for the chat pane")
        }
    }

    func testInboundGeoChatNilRemarksIsEmptyNotCrash() {
        let event = CoTEvent(
            uid: "MSG-empty",
            type: "b-t-f",
            time: Date(),
            point: CoTPoint(lat: 0, lon: 0, hae: 0, ce: 9999, le: 9999),
            detail: CoTDetail(callsign: "CHARLIE-3", team: nil, teamRole: nil, speed: nil,
                              course: nil, remarks: nil, battery: nil,
                              device: nil, platform: nil)
        )
        switch ATAKPluginParser.classify(event) {
        case .chatMessage(let msg):
            XCTAssertEqual(msg.messageText, "",
                "nil remarks must produce an empty message, not crash")
        default:
            XCTFail("b-t-f with nil remarks must still classify as .chatMessage")
        }
    }

    // MARK: - 5. Full outbound→inbound loop (encode then read back)

    func testGeoChatEncodeThenInboundClassifyLoop() {
        // Simulate: local device encodes a GeoChat for the mesh, a peer decodes
        // the same bytes and classifies them. End-to-end attribution must hold.
        let outbound = makeGeoChatEvent(text: "Off-grid loop test")
        guard let payload = MeshTAKRouting.encodePayload(for: outbound),
              let pkt = TAKPacketCodec.decode(payload),
              let inbound = TAKPacketCodec.toCoTEvent(pkt) else {
            return XCTFail("GeoChat encode → decode → toCoTEvent loop failed")
        }
        switch ATAKPluginParser.classify(inbound) {
        case .chatMessage(let msg):
            XCTAssertEqual(msg.messageText, "Off-grid loop test")
            XCTAssertEqual(msg.senderCallsign, "BRAVO-2")
        default:
            XCTFail("looped-back GeoChat must classify as .chatMessage on the peer")
        }
    }

    func testPLIEncodeThenInboundClassifyLoop() {
        let outbound = makePLIEvent()
        guard let payload = MeshTAKRouting.encodePayload(for: outbound),
              let pkt = TAKPacketCodec.decode(payload),
              let inbound = TAKPacketCodec.toCoTEvent(pkt) else {
            return XCTFail("PLI encode → decode → toCoTEvent loop failed")
        }
        switch ATAKPluginParser.classify(inbound) {
        case .positionUpdate(let e):
            XCTAssertEqual(e.point.lat, 47.6062, accuracy: 1e-4)
            XCTAssertEqual(e.point.lon, -122.3321, accuracy: 1e-4)
            XCTAssertEqual(e.detail.callsign, "ALPHA-1")
        default:
            XCTFail("looped-back PLI must classify as .positionUpdate on the peer")
        }
    }
}
