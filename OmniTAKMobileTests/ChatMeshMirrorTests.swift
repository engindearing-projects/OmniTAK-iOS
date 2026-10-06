//
//  ChatMeshMirrorTests.swift
//  OmniTAKMobileTests
//
//  Which conversations are copied onto the mesh radio when a message is sent.
//
//  The mesh copy goes to everyone on the radio channel (Meshtastic) or to every
//  known contact (MeshCore). Only the broadcast room may get one. A direct
//  message used to get it as well, and so did every message while "Broadcast
//  over mesh" was switched off.
//

import XCTest
@testable import OmniTAK

final class ChatMeshMirrorTests: XCTestCase {

    private func direct(serverId: UUID? = nil) -> Conversation {
        Conversation(
            id: "DM-\(UUID().uuidString)",
            title: "BRAVO-2",
            participants: [ChatParticipant(id: "ANDROID-them", callsign: "BRAVO-2")],
            isGroupChat: false,
            serverId: serverId
        )
    }

    func testTheBroadcastRoomIsMirroredToTheMesh() {
        XCTAssertTrue(ChatRoom.createAllUsersConversation().mirrorsToMesh)
        XCTAssertTrue(ChatManager.mirrorsToMesh(ChatRoom.createAllUsersConversation(), meshBroadcastEnabled: true))
    }

    func testADirectMessageIsNeverMirroredToTheMesh() {
        XCTAssertFalse(direct().mirrorsToMesh)
        XCTAssertFalse(ChatManager.mirrorsToMesh(direct(), meshBroadcastEnabled: true))
    }

    func testADirectMessageOnOneServerIsNeverMirroredToTheMesh() {
        XCTAssertFalse(ChatManager.mirrorsToMesh(direct(serverId: UUID()), meshBroadcastEnabled: true))
    }

    func testAContactNamedLikeTheBroadcastRoomDoesNotMakeItsDirectMessageABroadcast() {
        // The id decides, not the title or a callsign that happens to match.
        let conversation = Conversation(
            id: "DM-\(UUID().uuidString)",
            title: ChatRoom.allUsersTitle,
            participants: [ChatParticipant(id: ChatRoom.allUsersId, callsign: ChatRoom.allUsersTitle)],
            isGroupChat: false
        )
        XCTAssertFalse(conversation.mirrorsToMesh)
    }

    func testBeingAGroupIsNotEnough() {
        // Any other room would be widened to the whole channel in the same way.
        XCTAssertFalse(Conversation(id: "Team Red", title: "Team Red", isGroupChat: true).mirrorsToMesh)
        XCTAssertFalse(Conversation(id: ChatRoom.atakChatroomName, title: "x", isGroupChat: true).mirrorsToMesh)
        XCTAssertFalse(ChatRoom.createBroadcastConversation().mirrorsToMesh)
    }

    func testNothingIsMirroredWhileBroadcastOverMeshIsOff() {
        XCTAssertFalse(ChatManager.mirrorsToMesh(ChatRoom.createAllUsersConversation(), meshBroadcastEnabled: false))
        XCTAssertFalse(ChatManager.mirrorsToMesh(direct(), meshBroadcastEnabled: false))
    }
}
