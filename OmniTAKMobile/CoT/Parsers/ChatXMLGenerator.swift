//
//  ChatXMLGenerator.swift
//  OmniTAKTest
//
//  Generate TAK GeoChat XML (b-t-f format) for group and direct messages
//

import Foundation
import CoreLocation

class ChatXMLGenerator {

    // Generate GeoChat XML for a chat message
    static func generateGeoChatXML(
        message: ChatMessage,
        senderUid: String,
        senderCallsign: String,
        location: CLLocation?,
        isGroupChat: Bool = false,
        groupName: String? = nil
    ) -> String {
        let messageId = message.id
        let now = Date()
        let nowStr = CoTXMLBuilder.timestamp(now)

        // Use current location or default
        let lat = location?.coordinate.latitude ?? 0.0
        let lon = location?.coordinate.longitude ?? 0.0
        let hae = location?.altitude ?? 0.0
        let ce = location?.horizontalAccuracy ?? 999999.0
        let le = location?.verticalAccuracy ?? 999999.0

        // Determine the room name, the conversation id and the routing.
        //
        // ATAK files a 1:1 chat by the *recipient UID*: `__chat id`, the
        // `chatgrp id`/`uid1`, `remarks to` and the event uid all carry it,
        // while `chatroom` and `<marti><dest>` carry the human-readable
        // callsign. Sending the callsign as the id made ATAK open a "group"
        // named after itself instead of a thread with us (#125).
        let chatroom: String        // display name of the room
        let conversationId: String  // what the receiver keys the thread on
        let martiElement: String

        if isGroupChat {
            // Group chat - use ATAK's expected chatroom name for interoperability
            // No marti destination for broadcast - server routes to all
            chatroom = ChatRoom.atakChatroomName
            conversationId = chatroom
            martiElement = ""
        } else if let recipientCallsign = message.recipientCallsign {
            // Direct message - need marti destination for routing
            chatroom = recipientCallsign
            conversationId = message.recipientId ?? recipientCallsign
            martiElement = """

                    <marti>
                        <dest callsign="\(recipientCallsign.xmlEscaped)"/>
                    </marti>
            """
        } else {
            // Default to group chat
            chatroom = ChatRoom.atakChatroomName
            conversationId = chatroom
            martiElement = ""
        }

        // Build fileshare element if image attachment present
        let fileshareElement = generateFileshareElement(for: message)

        let detail = """
                <__chat id="\(conversationId.xmlEscaped)" chatroom="\(chatroom.xmlEscaped)" senderCallsign="\(senderCallsign.xmlEscaped)" groupOwner="false" messageId="\(messageId.xmlEscaped)">
                    <chatgrp uid0="\(senderUid.xmlEscaped)" uid1="\(conversationId.xmlEscaped)" id="\(conversationId.xmlEscaped)"/>
                </__chat>
                <link uid="\(senderUid.xmlEscaped)" production_time="\(nowStr)" type="a-f-G-U-C" parent_callsign="\(senderCallsign.xmlEscaped)" relation="p-p"/>
                <remarks source="BAO.F.ATAK.\(senderUid.xmlEscaped)" to="\(conversationId.xmlEscaped)" time="\(nowStr)">\(message.messageText.xmlEscaped)</remarks>\(fileshareElement)\(martiElement)
        """

        return CoTXMLBuilder.buildEvent(
            uid: "GeoChat.\(senderUid).\(conversationId).\(messageId)",
            type: "b-t-f",
            how: "h-g-i-g-o",
            time: now,
            staleAfter: 3600, // 1 hour
            lat: lat,
            lon: lon,
            hae: hae,
            ce: ce,
            le: le,
            detail: detail
        )
    }

    // Generate fileshare element for image attachments
    static func generateFileshareElement(for message: ChatMessage) -> String {
        guard message.hasImage,
              let attachment = message.imageAttachment else {
            return ""
        }

        // Build senderUrl - prefer base64 for inline, otherwise use remote URL
        let senderUrl: String
        if let base64Data = attachment.base64Data {
            senderUrl = "base64:\(base64Data)"
        } else if let remoteURL = attachment.remoteURL {
            senderUrl = remoteURL
        } else {
            // Fallback to local path reference
            senderUrl = "local:\(attachment.localPath ?? attachment.filename)"
        }

        let fileshareXML = """

                <fileshare filename="\(attachment.filename.xmlEscaped)" senderUrl="\(senderUrl)" size="\(attachment.fileSize)" sha256="" senderUid="\(message.senderId)" senderCallsign="\(message.senderCallsign.xmlEscaped)" name="\(attachment.filename.xmlEscaped)" mimeType="\(attachment.mimeType)"/>
        """

        return fileshareXML
    }
}
