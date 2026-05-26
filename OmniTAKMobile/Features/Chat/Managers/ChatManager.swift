//
//  ChatManager.swift
//  OmniTAKTest
//
//  ObservableObject for chat state, sendMessage(), receiveMessage(), conversation management
//

import Foundation
import Combine
import CoreLocation
import UIKit

class ChatManager: ObservableObject {
    static let shared = ChatManager()

    @Published var conversations: [Conversation] = []
    @Published var messages: [ChatMessage] = []
    @Published var participants: [ChatParticipant] = []
    @Published var currentUserId: String = "SELF-\(UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString)"
    @Published var currentUserCallsign: String = "OmniTAK-iOS"

    private let persistence = ChatPersistence.shared
    private var takService: TAKService?
    private var locationManager: LocationManager?

    private init() {
        // Perform file I/O on a background queue so the first access to
        // ChatManager.shared (e.g. from ContactListView) doesn't block the
        // main thread for 6–26 seconds while JSON is decoded from disk.
        // @Published mutations are dispatched back to main via DispatchQueue.main.async.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let loadedConversations = self.persistence.loadConversations()
            let loadedMessages      = self.persistence.loadMessages()
            let loadedParticipants  = self.persistence.loadParticipants()
            DispatchQueue.main.async {
                self.conversations = loadedConversations
                self.messages      = loadedMessages
                self.participants  = loadedParticipants
                print("ChatManager loaded: \(loadedConversations.count) conversations, \(loadedMessages.count) messages, \(loadedParticipants.count) participants")
                self.setupDefaultConversations()
            }
        }
    }

    // MARK: - Setup

    func configure(takService: TAKService, locationManager: LocationManager) {
        self.takService = takService
        self.locationManager = locationManager
    }

    func setTAKService(_ takService: TAKService) {
        self.takService = takService
        #if DEBUG
        print("📡 ChatManager: TAKService set")
        #endif
    }

    private func setupDefaultConversations() {
        // Create "All Chat Users" group conversation if it doesn't exist
        if !conversations.contains(where: { $0.id == ChatRoom.allUsersId }) {
            let allUsersConversation = ChatRoom.createAllUsersConversation()
            conversations.append(allUsersConversation)
            saveConversations()
        }
    }

    // MARK: - Send Message

    func sendMessage(text: String, to conversationId: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("Cannot send empty message")
            return
        }

        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            print("Conversation not found: \(conversationId)")
            return
        }

        // Create message
        let message = ChatMessage(
            conversationId: conversationId,
            senderId: currentUserId,
            senderCallsign: currentUserCallsign,
            recipientId: conversation.isGroupChat ? nil : conversation.participants.first?.id,
            recipientCallsign: conversation.isGroupChat ? nil : conversation.participants.first?.callsign,
            messageText: text,
            timestamp: Date(),
            status: .sending,
            type: .geochat,
            isFromSelf: true,
            serverId: conversation.serverId
        )

        // Add to messages array
        messages.append(message)
        saveMessages()

        // Update conversation
        updateConversation(conversationId: conversationId, with: message)

        // Generate and send GeoChat XML
        let xml = ChatXMLGenerator.generateGeoChatXML(
            message: message,
            senderUid: currentUserId,
            senderCallsign: currentUserCallsign,
            location: locationManager?.location,
            isGroupChat: conversation.isGroupChat,
            groupName: conversation.isGroupChat ? conversation.title : nil
        )

        #if DEBUG
        print("📤 [CHAT DEBUG] ========== OUTGOING CHAT XML ==========")
        print(xml)
        print("📤 [CHAT DEBUG] ========== END OUTGOING XML ==========")
        #endif

        // Send via TAK service
        if let takService = takService {
            #if DEBUG
            print("📤 [CHAT DEBUG] TAKService available, attempting to send...")
            #endif
            let success = takService.sendCoT(xml: xml, toServerId: conversation.serverId)
            if success {
                // Update message status to sent
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index].status = .sent
                    saveMessages()
                }
                print("✅ [CHAT DEBUG] Sent chat message to \(conversation.displayTitle): \(text)")
            } else {
                // Update message status to failed
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index].status = .failed
                    saveMessages()
                }
                print("❌ [CHAT DEBUG] Failed to send chat message - sendCoT returned false")
            }
        } else {
            print("❌ [CHAT DEBUG] TAKService not configured - cannot send message")
        }
    }

    // MARK: - Send Message with Image

    func sendMessageWithImage(text: String, imageAttachment: ImageAttachment, to conversationId: String) {
        guard let conversation = conversations.first(where: { $0.id == conversationId }) else {
            print("Conversation not found: \(conversationId)")
            return
        }

        // Create message with image attachment
        let message = ChatMessage(
            id: imageAttachment.id, // Use same ID for message and attachment
            conversationId: conversationId,
            senderId: currentUserId,
            senderCallsign: currentUserCallsign,
            recipientId: conversation.isGroupChat ? nil : conversation.participants.first?.id,
            recipientCallsign: conversation.isGroupChat ? nil : conversation.participants.first?.callsign,
            messageText: text,
            timestamp: Date(),
            status: .sending,
            type: .geochat,
            isFromSelf: true,
            attachmentType: .image,
            imageAttachment: imageAttachment,
            serverId: conversation.serverId
        )

        // Add to messages array
        messages.append(message)
        saveMessages()

        // Update conversation
        updateConversation(conversationId: conversationId, with: message)

        // Generate and send GeoChat XML with attachment
        let xml = ChatXMLGenerator.generateGeoChatXML(
            message: message,
            senderUid: currentUserId,
            senderCallsign: currentUserCallsign,
            location: locationManager?.location,
            isGroupChat: conversation.isGroupChat,
            groupName: conversation.isGroupChat ? conversation.title : nil
        )

        // Send via TAK service
        if let takService = takService {
            let success = takService.sendCoT(xml: xml, toServerId: conversation.serverId)
            if success {
                // Update message status to sent
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index].status = .sent
                    saveMessages()
                }
                let sizeString = PhotoAttachmentService.shared.formatStorageSize(Int64(imageAttachment.fileSize))
                print("Sent image message to \(conversation.displayTitle) (\(sizeString))")
            } else {
                // Update message status to failed
                if let index = messages.firstIndex(where: { $0.id == message.id }) {
                    messages[index].status = .failed
                    saveMessages()
                }
                print("Failed to send image message")
            }
        } else {
            print("TAKService not configured")
        }
    }

    // MARK: - Receive Message

    func receiveMessage(_ message: ChatMessage, serverId: UUID? = nil) {
        // Check if message already exists
        guard !messages.contains(where: { $0.id == message.id }) else {
            print("Duplicate message ignored: \(message.id)")
            return
        }

        // Attribute to the source server, and re-scope DMs per server so the
        // same contact on two servers stays in separate threads. The merged
        // All Chat room keeps its id (messages carry a per-message server badge).
        var msg = message
        msg.serverId = serverId
        let isGroup = message.recipientId == nil
            || message.conversationId == ChatRoom.allUsersId
            || message.conversationId == ChatRoom.broadcastId
        if !isGroup, let sid = serverId {
            msg.conversationId = createDirectConversationId(uid1: currentUserId, uid2: message.senderId, serverId: sid)
        }

        // Add message
        messages.append(msg)
        saveMessages()

        // Update or create conversation
        if conversations.first(where: { $0.id == msg.conversationId }) != nil {
            updateConversation(conversationId: msg.conversationId, with: msg)
        } else {
            createConversation(from: msg)
        }

        print("Received chat message from \(msg.senderCallsign) on server \(serverId?.uuidString ?? "—"): \(msg.messageText)")
    }

    // MARK: - Conversation Management

    func getOrCreateDirectConversation(with participant: ChatParticipant, serverId: UUID? = nil) -> Conversation {
        // Scope the DM to the server the contact is on (multi-server).
        let sid = serverId ?? participant.serverId
        let conversationId = createDirectConversationId(
            uid1: currentUserId,
            uid2: participant.id,
            serverId: sid
        )

        // Check if conversation exists
        if let existing = conversations.first(where: { $0.id == conversationId }) {
            return existing
        }

        // Create new conversation
        var scopedParticipant = participant
        scopedParticipant.serverId = sid
        let conversation = Conversation(
            id: conversationId,
            title: participant.callsign,
            participants: [scopedParticipant],
            isGroupChat: false,
            serverId: sid
        )

        conversations.append(conversation)
        saveConversations()

        print("Created direct conversation with \(participant.callsign)")
        return conversation
    }

    private func createConversation(from message: ChatMessage) {
        // Create participant for sender, scoped to the source server.
        let sender = ChatParticipant(
            id: message.senderId,
            callsign: message.senderCallsign,
            serverId: message.serverId
        )

        // Add to participants if not already present
        if !participants.contains(where: { $0.id == sender.id }) {
            participants.append(sender)
            saveParticipants()
        }

        // Create conversation
        let conversation = Conversation(
            id: message.conversationId,
            title: message.senderCallsign,
            participants: [sender],
            lastMessage: message,
            unreadCount: 1,
            isGroupChat: message.recipientId == nil,
            lastActivity: message.timestamp,
            serverId: message.serverId
        )

        conversations.append(conversation)
        saveConversations()

        print("Created new conversation: \(conversation.displayTitle)")
    }

    private func updateConversation(conversationId: String, with message: ChatMessage) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }

        var conversation = conversations[index]
        conversation.lastMessage = message
        conversation.lastActivity = message.timestamp

        // Increment unread count if message is not from self
        if !message.isFromSelf {
            conversation.unreadCount += 1
        }

        conversations[index] = conversation
        saveConversations()
    }

    func markConversationAsRead(conversationId: String) {
        guard let index = conversations.firstIndex(where: { $0.id == conversationId }) else {
            return
        }

        conversations[index].unreadCount = 0
        saveConversations()
    }

    func getMessages(for conversationId: String) -> [ChatMessage] {
        return messages
            .filter { $0.conversationId == conversationId }
            .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Message History Management

    /// Get recent messages across all conversations, sorted by timestamp
    func getRecentMessages(limit: Int = 50) -> [ChatMessage] {
        return messages
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { $0 }
    }

    /// Get messages within a specific time range
    func getMessages(from startDate: Date, to endDate: Date) -> [ChatMessage] {
        return messages
            .filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Search messages by text content
    func searchMessages(query: String) -> [ChatMessage] {
        guard !query.isEmpty else { return [] }

        return messages
            .filter { $0.messageText.localizedCaseInsensitiveContains(query) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// Get conversation statistics
    func getConversationStats(for conversationId: String) -> ConversationStats {
        let conversationMessages = getMessages(for: conversationId)
        let sentMessages = conversationMessages.filter { $0.isFromSelf }
        let receivedMessages = conversationMessages.filter { !$0.isFromSelf }

        return ConversationStats(
            totalMessages: conversationMessages.count,
            sentMessages: sentMessages.count,
            receivedMessages: receivedMessages.count,
            firstMessageDate: conversationMessages.first?.timestamp,
            lastMessageDate: conversationMessages.last?.timestamp
        )
    }

    /// Delete old messages beyond a certain age (for memory management)
    func deleteOldMessages(olderThan days: Int) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let oldCount = messages.count

        // Delete attachments for old messages
        let oldMessages = messages.filter { $0.timestamp < cutoffDate }
        for message in oldMessages {
            if message.hasImage {
                PhotoAttachmentService.shared.deleteAttachment(for: message.id)
            }
        }

        messages.removeAll { $0.timestamp < cutoffDate }
        saveMessages()

        let deletedCount = oldCount - messages.count
        if deletedCount > 0 {
            print("Deleted \(deletedCount) old messages and their attachments")
        }

        // Also cleanup orphaned attachments
        PhotoAttachmentService.shared.cleanupOldAttachments(olderThan: days)
    }

    // MARK: - Participant Management

    func updateParticipant(_ participant: ChatParticipant) {
        if let index = participants.firstIndex(where: { $0.id == participant.id }) {
            participants[index] = participant
        } else {
            participants.append(participant)
        }
        saveParticipants()

        // Update "All Chat Users" conversation participants
        if let index = conversations.firstIndex(where: { $0.id == ChatRoom.allUsersId }) {
            conversations[index].participants = participants
            saveConversations()
        }
    }

    func getParticipant(byId id: String) -> ChatParticipant? {
        return participants.first { $0.id == id }
    }

    func getParticipant(byCallsign callsign: String) -> ChatParticipant? {
        return participants.first { $0.callsign == callsign }
    }

    // MARK: - Contact Status Management

    /// Update contact online status based on last seen time
    /// Contacts are considered offline if not seen for more than 5 minutes
    func updateContactStatuses() {
        let offlineThreshold: TimeInterval = 300 // 5 minutes
        let now = Date()
        var updated = false

        for index in participants.indices {
            let timeSinceLastSeen = now.timeIntervalSince(participants[index].lastSeen)
            let shouldBeOnline = timeSinceLastSeen < offlineThreshold

            if participants[index].isOnline != shouldBeOnline {
                participants[index].isOnline = shouldBeOnline
                updated = true
            }
        }

        if updated {
            saveParticipants()
        }
    }

    /// Update participant last seen timestamp
    func updateParticipantLastSeen(id: String) {
        if let index = participants.firstIndex(where: { $0.id == id }) {
            participants[index].lastSeen = Date()
            participants[index].isOnline = true
            saveParticipants()
        }
    }

    /// Get total message count for a specific contact
    func getMessageCount(forContactId contactId: String) -> Int {
        return messages.filter { message in
            message.senderId == contactId || message.recipientId == contactId
        }.count
    }

    /// Get unread message count across all conversations
    var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }

    // MARK: - Persistence

    private func saveConversations() {
        persistence.saveConversations(conversations)
    }

    private func saveMessages() {
        persistence.saveMessages(messages)
    }

    private func saveParticipants() {
        persistence.saveParticipants(participants)
    }

    // MARK: - Helpers

    private func createDirectConversationId(uid1: String, uid2: String, serverId: UUID? = nil) -> String {
        let sorted = [uid1, uid2].sorted()
        // Scope DM threads per server so the same callsign/UID on two servers
        // are distinct conversations (multi-server). Legacy (nil) keeps old id.
        if let sid = serverId {
            return "DM-\(sid.uuidString)-\(sorted[0])-\(sorted[1])"
        }
        return "DM-\(sorted[0])-\(sorted[1])"
    }

    // MARK: - Delete Conversation

    func deleteConversation(_ conversation: Conversation) {
        // Remove conversation
        conversations.removeAll { $0.id == conversation.id }
        saveConversations()

        // Delete attachments for messages in this conversation
        let conversationMessages = messages.filter { $0.conversationId == conversation.id }
        for message in conversationMessages {
            if message.hasImage {
                PhotoAttachmentService.shared.deleteAttachment(for: message.id)
            }
        }

        // Remove associated messages
        messages.removeAll { $0.conversationId == conversation.id }
        saveMessages()

        print("Deleted conversation: \(conversation.displayTitle) and associated attachments")
    }

    // MARK: - Clear All Data

    func clearAllData() {
        // Delete all attachments
        for message in messages {
            if message.hasImage {
                PhotoAttachmentService.shared.deleteAttachment(for: message.id)
            }
        }

        conversations.removeAll()
        messages.removeAll()
        participants.removeAll()

        persistence.clearAllData()
        setupDefaultConversations()

        print("Cleared all chat data and attachments")
    }

    // MARK: - Storage Statistics

    /// Get total attachment storage used
    func getAttachmentStorageUsed() -> Int64 {
        return PhotoAttachmentService.shared.getStorageUsed()
    }

    /// Get formatted storage usage string
    func getFormattedStorageUsed() -> String {
        let bytes = getAttachmentStorageUsed()
        return PhotoAttachmentService.shared.formatStorageSize(bytes)
    }

    /// Get count of messages with attachments
    func getAttachmentCount() -> Int {
        return messages.filter { $0.hasImage }.count
    }
}

