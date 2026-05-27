//
//  MissionCreationSheet.swift
//  OmniTAKMobile
//
//  MVP mission-creation flow (issue #14): name + optional description + server
//  picker. Calls `TAKRestAPIClient.createMission` against the chosen enabled
//  TAK server and posts `.missionCreated` so MissionSyncView re-fetches.
//
//  TODO(#14): bounding-area picker (no UI yet — TAK servers accept the mission
//             without a bbox, so MVP omits it).
//  TODO(#14): member-from-contacts picker (ContactListView reuse).
//  TODO(#14): auto-bundle current map state into the mission's first
//             data package via LassoExporters.
//

import SwiftUI

extension Notification.Name {
    /// Posted after a mission is successfully created on a server, so any
    /// listening MissionSyncView can re-fetch and show it without waiting
    /// for a manual refresh.
    static let missionCreated = Notification.Name("missionCreated")
}

struct MissionCreationSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var descriptionText: String = ""
    @State private var selectedServerId: UUID?
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    private let accent = Color(hex: "#00BCD4")

    private var servers: [TAKServer] { MissionSyncManager.shared.enabledServers() }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedName.isEmpty && selectedServerId != nil && !isSubmitting }

    var body: some View {
        NavigationView {
            Form {
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                }

                Section("MISSION") {
                    TextField("Name (required)", text: $name)
                        .autocapitalization(.words)
                        .disableAutocorrection(true)
                    TextField("Description (optional)", text: $descriptionText)
                        .autocapitalization(.sentences)
                }

                Section("SERVER") {
                    if servers.isEmpty {
                        Text("No TLS-enabled servers with a client certificate are available. Enable one in Servers.")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Target server", selection: Binding(
                            get: { selectedServerId ?? servers.first?.id },
                            set: { selectedServerId = $0 }
                        )) {
                            ForEach(servers) { sv in
                                Text("\(sv.name) — \(sv.host)").tag(Optional(sv.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }

                Section {
                    Button(action: submit) {
                        HStack {
                            if isSubmitting { ProgressView().tint(accent) }
                            Text(isSubmitting ? "Creating…" : "Create Mission")
                                .foregroundColor(canSubmit ? accent : .secondary)
                            Spacer()
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .navigationTitle("New Mission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if selectedServerId == nil { selectedServerId = servers.first?.id }
            }
        }
    }

    private func submit() {
        guard let serverId = selectedServerId,
              let server = servers.first(where: { $0.id == serverId }) else {
            errorMessage = "Pick a server first."
            return
        }
        let missionName = trimmedName
        let desc = descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let creatorUid = PositionBroadcastService.shared.userUID

        isSubmitting = true
        errorMessage = nil

        Task { @MainActor in
            let client = TAKRestAPIClient()
            client.configure(from: server)
            do {
                _ = try await client.createMission(
                    name: missionName,
                    description: desc.isEmpty ? nil : desc,
                    creatorUid: creatorUid
                )
                NotificationCenter.default.post(name: .missionCreated, object: nil)
                isSubmitting = false
                dismiss()
            } catch {
                isSubmitting = false
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
