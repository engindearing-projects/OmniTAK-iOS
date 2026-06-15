//
//  MarkerLifecycleTests.swift
//  OmniTAKMobileTests
//
//  TDD regression tests for two field-reported marker lifecycle bugs
//  (Patrick Coyle, 2026-06-12):
//
//    Bug A — Dropped point-markers wrongly appear as contacts in the Chat menu
//             (Android #118 parity)
//    Bug B — Locally-dropped markers persist across app restart but marker-
//             tainted participants from old sessions must be scrubbed at load
//             (Android #119 parity)
//
//  Classification used throughout:
//    • locally-dropped marker — UID starts with "marker-" (set by PointMarker.init)
//    • real EUD (chat-able)   — any other UID (server PPLI, mesh node, etc.)
//    • RID drone              — UID starts with "RID-" (already filtered pre-fix)
//

import XCTest
@testable import OmniTAK

// MARK: - Bug A: Chat contact filter

final class MarkerChatFilterTests: XCTestCase {

    // Helper — build a minimal CoT event with the given uid and type.
    private func makeEvent(uid: String, type: String, callsign: String = "TEST") -> CoTEvent {
        CoTEvent(
            uid: uid,
            type: type,
            time: Date(),
            point: CoTPoint(lat: 47.0, lon: -122.0, hae: 0, ce: 9999, le: 9999),
            detail: CoTDetail(
                callsign: callsign,
                team: nil, teamRole: nil, speed: nil, course: nil,
                remarks: nil, battery: nil, device: nil, platform: nil
            )
        )
    }

    // MARK: A-1: isDroppedPointMarker returns true for marker- UIDs

    func testDroppedMarkerUIDIsDetected() {
        let markerUID = "marker-550E8400-E29B-41D4-A716-446655440000"
        XCTAssertTrue(
            markerUID.isDroppedPointMarkerUID,
            "UID starting with 'marker-' must be classified as a dropped point marker"
        )
    }

    // MARK: A-2: Normal EUD UID is NOT classified as a dropped marker

    func testRealEUDUIDIsNotDroppedMarker() {
        let euds = [
            "ANDROID-abc123",
            "IOS-xyz456",
            "ATAK-1234",
            "marker",          // exact string "marker" without dash is not a marker UID
        ]
        for uid in euds {
            XCTAssertFalse(
                uid.isDroppedPointMarkerUID,
                "'\(uid)' should NOT be classified as a dropped point marker"
            )
        }
    }

    // MARK: A-3: RID drone UID is not a dropped marker (separate exclusion path)

    func testRIDUIDIsNotDroppedMarker() {
        XCTAssertFalse(
            "RID-DJI-ABC123".isDroppedPointMarkerUID,
            "RID- UIDs are drone detections, not dropped markers — separate filter path"
        )
    }

    // MARK: A-4: chatManager.participants excludes locally-dropped marker UIDs

    func testChatParticipantsExcludeDroppedMarkers() {
        let manager = ChatManager.shared

        // Record initial state so we can restore it.
        let originalParticipants = manager.participants
        defer { manager.participants = originalParticipants }

        // Inject a mix of real contacts and a marker-prefixed entry.
        let realContact = ChatParticipant(id: "ANDROID-real-01", callsign: "ALPHA-1")
        let markerContact = ChatParticipant(id: "marker-DEADBEEF-0000-0000-0000-000000000001", callsign: "HOS-1-1234")

        manager.participants = [realContact, markerContact]

        // The chat-visible participant list must exclude marker- UIDs.
        let chatVisible = manager.chatableParticipants
        XCTAssertTrue(
            chatVisible.contains(where: { $0.id == realContact.id }),
            "Real EUD '\(realContact.callsign)' must appear in chatableParticipants"
        )
        XCTAssertFalse(
            chatVisible.contains(where: { $0.id == markerContact.id }),
            "Dropped marker '\(markerContact.callsign)' must NOT appear in chatableParticipants"
        )
    }

    // MARK: A-5: CoTEventHandler does NOT add a dropped marker as a participant

    func testEventHandlerSkipsDroppedMarkerForParticipantFeed() {
        // Simulate what CoTEventHandler.handlePositionUpdate does for a
        // marker-prefixed UID.  The check lives inside the handler, so we
        // test the predicate that gates the updateParticipant call.
        let markerUID = "marker-550E8400-E29B-41D4-A716-446655440001"
        let shouldFeedAsParticipant = !markerUID.isDroppedPointMarkerUID && !markerUID.hasPrefix("RID-")
        XCTAssertFalse(
            shouldFeedAsParticipant,
            "CoTEventHandler must not feed marker- UIDs into the participant store"
        )
    }

    // MARK: A-6: Broadcast-echoed marker UID is still excluded

    func testBroadcastedMarkerEchoExcluded() {
        // A marker that was broadcast to the server gets echoed back as a
        // positionUpdate CoT event.  Its UID is unchanged ("marker-<uuid>"),
        // so it must still be excluded from the participant feed.
        let broadcastedMarkerUID = "marker-AABBCCDD-1111-2222-3333-444455556666"
        let shouldFeed = !broadcastedMarkerUID.isDroppedPointMarkerUID && !broadcastedMarkerUID.hasPrefix("RID-")
        XCTAssertFalse(
            shouldFeed,
            "A server-echoed dropped marker must remain excluded from chat participants"
        )
    }
}

// MARK: - Bug B: Marker-tainted participants scrubbed at load

final class MarkerParticipantPersistenceTests: XCTestCase {

    // MARK: B-1: loadParticipants strips marker- UIDs

    func testLoadParticipantsScrubsMarkerUIDs() {
        // Build a raw participants list that contains both valid contacts and
        // stale marker entries (as would appear in participants.json from a
        // build that predates this fix).
        let valid1   = ChatParticipant(id: "IOS-unit-01", callsign: "BRAVO-1")
        let valid2   = ChatParticipant(id: "ANDROID-unit-02", callsign: "CHARLIE-2")
        let stale1   = ChatParticipant(id: "marker-00000000-0000-0000-0000-000000000001", callsign: "HOS-1-0800")
        let stale2   = ChatParticipant(id: "marker-FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", callsign: "FRD-2-1200")

        let raw = [valid1, stale1, valid2, stale2]

        // scrubMarkerParticipants is the new helper we added to ChatPersistence.
        let scrubbed = ChatPersistence.scrubMarkerParticipants(raw)

        XCTAssertEqual(scrubbed.count, 2,
            "scrubMarkerParticipants must remove both stale marker entries")
        XCTAssertTrue(scrubbed.contains(where: { $0.id == valid1.id }),
            "Valid participant '\(valid1.callsign)' must survive scrubbing")
        XCTAssertTrue(scrubbed.contains(where: { $0.id == valid2.id }),
            "Valid participant '\(valid2.callsign)' must survive scrubbing")
        XCTAssertFalse(scrubbed.contains(where: { $0.id == stale1.id }),
            "Stale marker participant '\(stale1.callsign)' must be removed")
        XCTAssertFalse(scrubbed.contains(where: { $0.id == stale2.id }),
            "Stale marker participant '\(stale2.callsign)' must be removed")
    }

    // MARK: B-2: scrubMarkerParticipants is a no-op on clean data

    func testScrubIsNoOpOnCleanData() {
        let contacts = [
            ChatParticipant(id: "IOS-unit-03", callsign: "DELTA-3"),
            ChatParticipant(id: "MESH-abc123", callsign: "ECHO-4"),
        ]
        let result = ChatPersistence.scrubMarkerParticipants(contacts)
        XCTAssertEqual(result.count, contacts.count,
            "scrubMarkerParticipants must not remove valid participants")
    }

    // MARK: B-3: PointMarker round-trips through PointMarkerPersistence

    func testPointMarkerPersistsAndLoads() {
        let persistence = PointMarkerPersistence()
        let marker = PointMarker(
            name: "TEST-HOS-1",
            affiliation: .hostile,
            coordinate: .init(latitude: 47.0, longitude: -122.0),
            remarks: "test persist"
        )

        // Save and immediately reload.
        persistence.saveMarkers([marker])
        let loaded = persistence.loadMarkers()

        XCTAssertEqual(loaded.count, 1,
            "Exactly one marker must survive a save/load cycle")
        guard let reloaded = loaded.first else {
            return XCTFail("No markers returned from loadMarkers()")
        }
        XCTAssertEqual(reloaded.id, marker.id,
            "Marker UUID must survive round-trip")
        XCTAssertEqual(reloaded.name, marker.name,
            "Marker name must survive round-trip")
        XCTAssertEqual(reloaded.affiliation, marker.affiliation,
            "Marker affiliation must survive round-trip")
        XCTAssertEqual(reloaded.uid, marker.uid,
            "Marker UID ('marker-<uuid>') must survive round-trip")
        XCTAssertTrue(
            reloaded.uid.hasPrefix("marker-"),
            "Reloaded marker UID must still carry the 'marker-' prefix"
        )

        // Cleanup — restore empty set so the test is hermetic.
        persistence.saveMarkers([])
    }

    // MARK: B-4: Marker UID prefix is stable across encode/decode

    func testMarkerUIDPrefixSurvivesCodec() throws {
        let marker = PointMarker(
            name: "CODEC-CHECK",
            affiliation: .friendly,
            coordinate: .init(latitude: 0, longitude: 0)
        )
        XCTAssertTrue(marker.uid.hasPrefix("marker-"),
            "Fresh PointMarker must have uid starting with 'marker-'")

        let data = try JSONEncoder().encode(marker)
        let decoded = try JSONDecoder().decode(PointMarker.self, from: data)

        XCTAssertEqual(decoded.uid, marker.uid,
            "UID must be unchanged after JSON encode → decode")
        XCTAssertTrue(decoded.uid.hasPrefix("marker-"),
            "Decoded PointMarker uid must still start with 'marker-'")
    }
}
