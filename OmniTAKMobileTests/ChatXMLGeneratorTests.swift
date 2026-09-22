//
//  ChatXMLGeneratorTests.swift
//  OmniTAKMobileTests
//
//  #125 — a direct message must be keyed by the recipient's UID the way ATAK
//  keys 1:1 chats (`__chat id`, `chatgrp id`/`uid1`, `remarks to`, event uid),
//  with the callsign only naming the room. Sending the callsign as the id made
//  ATAK open a "group" named after itself instead of a thread with us.
//

import XCTest
@testable import OmniTAK

final class ChatXMLGeneratorTests: XCTestCase {

    private func directMessage(recipientId: String? = "ANDROID-UID-9") -> ChatMessage {
        ChatMessage(id: "MSG-1",
                    conversationId: "DM-test",
                    senderId: "IOS-UID-1",
                    senderCallsign: "ALPHA-1",
                    recipientId: recipientId,
                    recipientCallsign: "BRAVO-2",
                    messageText: "sitrep?",
                    isFromSelf: true)
    }

    private func generate(_ message: ChatMessage, group: Bool = false) -> String {
        ChatXMLGenerator.generateGeoChatXML(message: message,
                                            senderUid: "IOS-UID-1",
                                            senderCallsign: "ALPHA-1",
                                            location: nil,
                                            isGroupChat: group)
    }

    func testDirectMessageIsKeyedByRecipientUID() {
        let xml = generate(directMessage())
        XCTAssertTrue(xml.contains(#"<__chat id="ANDROID-UID-9" chatroom="BRAVO-2" senderCallsign="ALPHA-1""#), xml)
        XCTAssertTrue(xml.contains(#"<chatgrp uid0="IOS-UID-1" uid1="ANDROID-UID-9" id="ANDROID-UID-9"/>"#), xml)
        XCTAssertTrue(xml.contains(#"to="ANDROID-UID-9""#), xml)
        XCTAssertTrue(xml.contains(#"uid="GeoChat.IOS-UID-1.ANDROID-UID-9.MSG-1""#), xml)
        XCTAssertTrue(xml.contains(#"<dest callsign="BRAVO-2"/>"#), xml)
        XCTAssertFalse(xml.contains(#"id="BRAVO-2""#), "the recipient callsign must never be used as a conversation id")
    }

    func testDirectMessageCarriesMessageIdForDeduplication() {
        XCTAssertTrue(generate(directMessage()).contains(#"messageId="MSG-1""#))
    }

    /// Contacts discovered without a UID (rare) still get a stable id.
    func testDirectMessageWithoutRecipientUIDFallsBackToCallsign() {
        let xml = generate(directMessage(recipientId: nil))
        XCTAssertTrue(xml.contains(#"<__chat id="BRAVO-2" chatroom="BRAVO-2""#), xml)
        XCTAssertTrue(xml.contains(#"uid1="BRAVO-2" id="BRAVO-2"/>"#), xml)
    }

    func testGroupChatStillUsesAllChatRooms() {
        let message = ChatMessage(id: "MSG-2", conversationId: ChatRoom.allUsersId,
                                  senderId: "IOS-UID-1", senderCallsign: "ALPHA-1",
                                  messageText: "all call", isFromSelf: true)
        let xml = generate(message, group: true)
        let room = ChatRoom.atakChatroomName
        XCTAssertTrue(xml.contains(#"<__chat id="\#(room)" chatroom="\#(room)""#), xml)
        XCTAssertTrue(xml.contains(#"uid1="\#(room)" id="\#(room)"/>"#), xml)
        XCTAssertFalse(xml.contains("<marti>"), "broadcast has no marti destination")
    }

    /// What we send for a DM must parse back on a receiving OmniTAK as a
    /// message from the sender, addressed to the recipient UID.
    func testDirectMessageRoundTripsThroughParser() throws {
        let parsed = try XCTUnwrap(ChatXMLParser.parseGeoChatMessage(xml: generate(directMessage())))
        XCTAssertEqual(parsed.senderCallsign, "ALPHA-1")
        XCTAssertEqual(parsed.senderId, "IOS-UID-1")
        XCTAssertEqual(parsed.recipientId, "ANDROID-UID-9")
        XCTAssertEqual(parsed.recipientCallsign, "BRAVO-2")
        XCTAssertEqual(parsed.messageText, "sitrep?")
    }
}
