//
//  ChatView.swift
//  OmniTAKTest
//
//  Conversation list UI with unread counts.
//
//  GAP-115-ios: Chat screen now merges ChatManager.conversations with
//  ChatManager.participants so every EUD seen on the map (via PPLI/CoT) appears
//  as a contact, even if they have never sent a GeoChat message.
//  The broadcast "All Chat Users" row is always pinned at the top regardless
//  of whether any messages have been exchanged.
//
//  Port of Android PR #48 (GAP-115, v0.33.0).
//

import SwiftUI

// MARK: - ChatView

struct ChatView: View {
    @ObservedObject var chatManager: ChatManager
    @State private var showNewChat = false
    @Environment(\.dismiss) var dismiss

    // The broadcast / all-users conversation — always present after init.
    var allUsersConversation: Conversation? {
        chatManager.conversations.first { $0.id == ChatRoom.allUsersId }
    }

    // Real DM/group threads (excludes the broadcast row which is pinned separately).
    var sortedConversations: [Conversation] {
        chatManager.conversations
            .filter { $0.id != ChatRoom.allUsersId }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    // Participants that do NOT yet have a DM thread.  De-duped by UID; own
    // device excluded.  Mirrors Android's ContactStore → conversation stub
    // approach from GAP-115 / PR #48.
    var contactStubs: [ChatParticipant] {
        let existingUids = Set(
            chatManager.conversations
                .filter { !$0.isGroupChat }
                .compactMap { $0.participants.first?.id }
        )
        // Use chatableParticipants (excludes dropped markers and drone UIDs)
        // so static map annotations never appear as chat-able contacts.
        return chatManager.chatableParticipants
            .filter { $0.id != chatManager.currentUserId && !existingUids.contains($0.id) }
            .sorted { $0.callsign < $1.callsign }
    }

    var body: some View {
        NavigationView {
            List {
                // ── Broadcast row — always visible ──────────────────────────
                Section {
                    if let broadcast = allUsersConversation {
                        NavigationLink(destination: ConversationView(
                            chatManager: chatManager,
                            conversation: broadcast
                        )) {
                            ConversationRow(conversation: broadcast)
                        }
                    } else {
                        // setupDefaultConversations() is async; show a placeholder
                        // so the row is never invisible while it loads.
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.blue).frame(width: 50, height: 50)
                                Image(systemName: "person.3.fill").foregroundColor(.white).font(.system(size: 20))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ChatRoom.allUsersTitle)
                                    .font(.system(size: 16, weight: .semibold))
                                Text("No messages yet")
                                    .font(.system(size: 14)).foregroundColor(.gray).italic()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // ── Active DM / group threads ───────────────────────────────
                if !sortedConversations.isEmpty {
                    Section("DIRECT MESSAGES") {
                        ForEach(sortedConversations) { conversation in
                            NavigationLink(destination: ConversationView(
                                chatManager: chatManager,
                                conversation: conversation
                            )) {
                                ConversationRow(conversation: conversation)
                            }
                        }
                        .onDelete(perform: deleteConversations)
                    }
                }

                // ── Contact stubs (EUDs seen on map, no chat yet) ───────────
                if !contactStubs.isEmpty {
                    Section("KNOWN CONTACTS") {
                        ForEach(contactStubs) { participant in
                            Button(action: {
                                openOrCreateConversation(with: participant)
                            }) {
                                ContactStubRow(participant: participant)
                            }
                        }
                    }
                }

                // ── Empty hint if nothing at all is visible ─────────────────
                if sortedConversations.isEmpty && contactStubs.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                            Text("No contacts yet")
                                .font(.subheadline).foregroundColor(.gray)
                            Text("Contacts appear as units come online. Use \"All Chat Users\" to broadcast.")
                                .font(.caption).foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("All Chat Users")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showNewChat = true }) {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView(chatManager: chatManager)
            }
        }
    }

    // Tap on a contact stub → get-or-create conversation, then navigate
    // by injecting it into conversations so ConversationView can find it.
    private func openOrCreateConversation(with participant: ChatParticipant) {
        _ = chatManager.getOrCreateDirectConversation(with: participant)
        // The new conversation will appear in sortedConversations on next
        // render; dismiss the sheet so the user sees it in the list.
        showNewChat = false
    }

    private func deleteConversations(at offsets: IndexSet) {
        for index in offsets {
            let conversation = sortedConversations[index]
            if conversation.id != ChatRoom.allUsersId {
                chatManager.deleteConversation(conversation)
            }
        }
    }
}

// MARK: - ContactStubRow

/// Renders a known EUD (from PPLI) that has no conversation thread yet.
/// Visual design matches ConversationRow so the list looks uniform.
struct ContactStubRow: View {
    let participant: ChatParticipant

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(participant.isOnline ? Color.green : Color.gray)
                    .frame(width: 50, height: 50)
                Image(systemName: "person.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 20))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(participant.callsign)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    ChatServerBadge(serverId: participant.serverId)
                    Spacer()
                }

                Text("No messages yet")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
                    .italic()
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                Circle()
                    .fill(conversation.isGroupChat ? Color.blue : Color.green)
                    .frame(width: 50, height: 50)

                Image(systemName: conversation.isGroupChat ? "person.3.fill" : "person.fill")
                    .foregroundColor(.white)
                    .font(.system(size: 20))
            }

            // Conversation info
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)

                    // Which server this (per-server) DM thread belongs to.
                    ChatServerBadge(serverId: conversation.serverId)

                    Spacer()

                    if let lastMessage = conversation.lastMessage {
                        Text(formatTimestamp(lastMessage.timestamp))
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }

                HStack {
                    if let lastMessage = conversation.lastMessage {
                        HStack(spacing: 4) {
                            if lastMessage.hasImage {
                                Image(systemName: "photo")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                            }
                            Text(lastMessage.previewText)
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                                .lineLimit(2)
                        }
                    } else {
                        Text("No messages yet")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                            .italic()
                    }

                    Spacer()

                    if conversation.unreadCount > 0 {
                        ZStack {
                            Circle()
                                .fill(Color.blue)
                                .frame(width: 24, height: 24)
                            Text("\(conversation.unreadCount)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func formatTimestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd/yy"
            return formatter.string(from: date)
        }
    }
}

// MARK: - New Chat View

struct NewChatView: View {
    @ObservedObject var chatManager: ChatManager
    @Environment(\.dismiss) var dismiss
    @State private var selectedParticipant: ChatParticipant?

    var availableParticipants: [ChatParticipant] {
        // chatableParticipants filters out dropped markers and drone UIDs so
        // only real EUDs appear in the New Chat contact picker.
        chatManager.chatableParticipants.filter { $0.id != chatManager.currentUserId }
    }

    var body: some View {
        NavigationView {
            List {
                Section("GROUP CHATS") {
                    Button(action: {
                        selectAllChatUsers()
                    }) {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 40, height: 40)
                                Image(systemName: "person.3.fill")
                                    .foregroundColor(.white)
                            }
                            Text("All Chat Users")
                                .foregroundColor(.primary)
                        }
                    }
                }

                if !availableParticipants.isEmpty {
                    Section("PARTICIPANTS") {
                        ForEach(availableParticipants) { participant in
                            Button(action: {
                                startDirectChat(with: participant)
                            }) {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 40, height: 40)
                                        Image(systemName: "person.fill")
                                            .foregroundColor(.white)
                                    }

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(participant.callsign)
                                                .foregroundColor(.primary)
                                            ChatServerBadge(serverId: participant.serverId)
                                        }
                                        if participant.isOnline {
                                            Text("Online")
                                                .font(.caption)
                                                .foregroundColor(.green)
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.gray)
                                        .font(.system(size: 14))
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        VStack(spacing: 8) {
                            Image(systemName: "person.3.slash")
                                .font(.system(size: 40))
                                .foregroundColor(.gray)
                            Text("No participants available")
                                .font(.subheadline)
                                .foregroundColor(.gray)
                            Text("Participants will appear as they send position updates")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                }
            }
            .navigationTitle("New Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func selectAllChatUsers() {
        // Navigate to "All Chat Users" conversation
        if chatManager.conversations.first(where: { $0.id == ChatRoom.allUsersId }) != nil {
            // Dismiss this sheet - the user can select it from the list
            dismiss()
        }
    }

    private func startDirectChat(with participant: ChatParticipant) {
        _ = chatManager.getOrCreateDirectConversation(with: participant)
        dismiss()
        // The conversation will now appear in the list
    }
}
