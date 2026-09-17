//
//  DittoMeshSettingsView.swift
//  OmniTAK Mobile
//
//  Operator controls for the Ditto peer-to-peer mesh. Intentionally short:
//  the mesh is meant to work with nobody touching it, so this screen exists to
//  explain what is happening and to expose the two decisions that genuinely
//  belong to the operator — which channel to ride, and whether this device
//  backhauls other people's traffic to a TAK server.
//

import SwiftUI

struct DittoMeshSettingsView: View {

    @ObservedObject private var mesh = DittoMeshService.shared

    @State private var enabled = DittoMeshService.shared.isEnabled
    @State private var gateway = DittoMeshService.shared.isGatewayEnabled
    @State private var channel = DittoMeshService.shared.channel
    @FocusState private var channelFocused: Bool

    var body: some View {
        Form {
            if !mesh.isConfigured {
                Section {
                    Label("Not available in this build", systemImage: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("This copy of OmniTAK was built without peer-to-peer mesh credentials. Everything else — TAK servers, Meshtastic, MeshCore — works normally.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                statusSection
                settingsSection
                gatewaySection
            }
            explainerSection
        }
        .navigationTitle("Peer Mesh")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text("State")
                Spacer()
                Circle()
                    .fill(mesh.state == .syncing ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(mesh.state.label)
                    .foregroundColor(mesh.state == .syncing ? .primary : .secondary)
            }
            row("Peers in range", "\(mesh.peerCount)")
            row("Sent", "\(mesh.published)")
            row("Received", "\(mesh.received)")
            if mesh.isGatewayEnabled {
                row("Relayed to servers", "\(mesh.relayed)")
            }
            if let last = mesh.lastInboundAt {
                row("Last contact", Self.clock.string(from: last))
            }
        }
    }

    private var settingsSection: some View {
        Section {
            Toggle("Peer mesh", isOn: $enabled)
                .onChange(of: enabled) { on in mesh.isEnabled = on }

            HStack {
                Text("Channel")
                Spacer()
                TextField("omnitak", text: $channel)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($channelFocused)
                    .frame(maxWidth: 180)
                    .onSubmit(applyChannel)
            }
            .onChange(of: channelFocused) { focused in
                if !focused { applyChannel() }
            }
        } footer: {
            Text("Only devices on the same channel share tracks. Leave it alone unless you want a private group — everyone must type it identically.")
        }
    }

    private var gatewaySection: some View {
        Section {
            Toggle("Relay mesh to TAK servers", isOn: $gateway)
                .onChange(of: gateway) { on in mesh.isGatewayEnabled = on }
        } header: {
            Text("Gateway")
        } footer: {
            Text("When this device is connected to a TAK server, forward everything it hears on the mesh to that server. One connected phone puts the whole local group on the server's map, even for teammates with no signal.\n\nOff by default: it publishes other people's positions to a server they may not be enrolled on.")
        }
    }

    private var explainerSection: some View {
        Section("How it works") {
            Text("OmniTAK devices near each other connect directly over Bluetooth and Wi-Fi and share position, markers and chat — no TAK server, no data package, no internet, nothing to pair.\n\nWhen any device does have a connection, the same picture syncs onward, so people out of radio range still see it.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Actions

    private func applyChannel() {
        let trimmed = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? DittoMeshService.defaultChannel : trimmed
        channel = next
        guard next != mesh.channel else { return }
        UserDefaults.standard.set(next, forKey: DittoMeshService.Keys.channel)
        // The subscription and observer bind the channel at registration, so a
        // change only takes effect on a rebuild of both.
        mesh.restart()
    }

    // MARK: - Helpers

    /// Stand-in for `LabeledContent`, which needs iOS 16.
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .medium
        f.dateStyle = .none
        return f
    }()
}
