//
//  MeshtasticSettingsView.swift
//  OmniTAK Mobile
//
//  Mesh SETTINGS + CHANNEL SHARE screen (OmniTAK-iOS #101).
//
//  Lets an operator, without leaving OmniTAK:
//    - create a channel and SHARE it (URL + QR) for the active transport
//    - SCAN / PASTE a shared link to JOIN, applying it to the connected radio
//    - set device role, position broadcast interval, and rebroadcast scope
//      (the PatoG1899 "rebroadcast only the known/current channel" ask)
//
//  Transport is chosen from the active connection: Meshtastic if its manager is
//  connected, otherwise MeshCore. Channel apply / config write goes out over
//  the matching clean-room encoder (AdminMessage / CMD_SET_CHANNEL).
//

import SwiftUI

struct MeshtasticSettingsView: View {
    @ObservedObject private var meshtastic = MeshtasticManager.shared

    /// MeshCore is only available on iOS 13+ and is a separate singleton.
    @available(iOS 13.0, *)
    private var meshcore: MeshCoreManager { MeshCoreManager.shared }

    // Active transport, derived from which manager is connected.
    private enum ActiveTransport { case meshtastic, meshcore, none }

    private var activeTransport: ActiveTransport {
        if meshtastic.isConnected { return .meshtastic }
        if #available(iOS 13.0, *), MeshCoreManager.shared.isConnected { return .meshcore }
        return .none
    }

    // Create-channel form state
    @State private var newName: String = ""
    @State private var newPSKHex: String = ""
    @State private var newIsPrimary: Bool = false

    // Join (scan/paste) state
    @State private var joinText: String = ""
    @State private var joinResult: String?

    // Settings state
    @State private var selectedRole: MeshtasticAdminCodec.DeviceRole = .tak
    @State private var selectedRebroadcast: MeshtasticAdminCodec.RebroadcastMode = .all
    @State private var positionIntervalSecs: Double = 900

    // Share sheet
    @State private var shareChannel: MeshtasticManager.StoredChannel?
    @State private var showingShare = false

    // Status banner
    @State private var statusMessage: String?

    /// Paired radios (role TAK) are hidden on the map by default — they double
    /// an operator who is already reporting from their phone.
    @AppStorage(MeshtasticManager.showPairedRadiosKey) private var showPairedRadios = false

    var body: some View {
        NavigationView {
            Form {
                transportSection
                channelsSection
                createChannelSection
                joinSection
                if activeTransport == .meshtastic {
                    deviceConfigSection
                    positionSection
                    mapDisplaySection
                }
                if let status = statusMessage {
                    Section { Text(status).font(.footnote).foregroundColor(.secondary) }
                }
            }
            .navigationTitle("Mesh Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingShare) {
                if let ch = shareChannel {
                    MeshChannelShareSheet(channel: ch, transport: shareTransportLabel)
                }
            }
        }
    }

    // MARK: - Sections

    private var transportSection: some View {
        Section("Active Transport") {
            HStack {
                Image(systemName: transportIcon)
                Text(transportLabel)
                Spacer()
                Text(activeTransport == .none ? "Not connected" : "Connected")
                    .foregroundColor(activeTransport == .none ? .secondary : .green)
                    .font(.caption)
            }
        }
    }

    private var channelsSection: some View {
        Section("Channels") {
            let channels = meshtastic.appChannels
            if channels.isEmpty {
                Text("No channels yet. Create one below or join from a shared link.")
                    .font(.footnote).foregroundColor(.secondary)
            } else {
                ForEach(channels) { ch in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(ch.name.isEmpty ? "(default)" : ch.name)
                            Text("index \(ch.index)\(ch.isPrimary ? " · primary" : "")\(ch.pskHex.isEmpty ? " · open" : " · encrypted")")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button {
                            shareChannel = ch
                            showingShare = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .onDelete { idxSet in
                    for i in idxSet { meshtastic.removeAppChannel(index: channels[i].index) }
                }
            }
        }
    }

    private var createChannelSection: some View {
        Section("Create Channel") {
            TextField("Name", text: $newName)
                .autocorrectionDisabled()
            TextField("PSK (hex, optional)", text: $newPSKHex)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Toggle("Primary channel", isOn: $newIsPrimary)
            Button("Create & Apply") { createAndApply() }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var joinSection: some View {
        Section("Join from Shared Link") {
            TextField("Paste meshtastic.org/e/# or meshcore:// link", text: $joinText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Join & Apply") { joinFromLink() }
                .disabled(joinText.trimmingCharacters(in: .whitespaces).isEmpty)
            if let r = joinResult {
                Text(r).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private var deviceConfigSection: some View {
        Section("Device") {
            Picker("Role", selection: $selectedRole) {
                ForEach(MeshtasticAdminCodec.DeviceRole.allCases, id: \.rawValue) { role in
                    Text(role.displayName).tag(role)
                }
            }
            Picker("Rebroadcast Scope", selection: $selectedRebroadcast) {
                ForEach(MeshtasticAdminCodec.RebroadcastMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            Button("Apply Device Config") { applyDeviceConfig() }
                .disabled(activeTransport != .meshtastic)
        }
    }

    private var mapDisplaySection: some View {
        Section {
            Toggle("Show paired radios", isOn: $showPairedRadios)
                .onChange(of: showPairedRadios) { _ in
                    meshtastic.publishMeshNodesToMap()
                }
        } header: {
            Text("Map Display")
        } footer: {
            Text("A radio in role TAK is paired to a phone that already reports "
                 + "that operator's position, so it stays off the map by default. "
                 + "Standalone trackers and sensors are always shown.")
        }
    }

    private var positionSection: some View {
        Section("Position Broadcast") {
            HStack {
                Text("Interval")
                Spacer()
                Text("\(Int(positionIntervalSecs))s")
                    .foregroundColor(.secondary)
            }
            Slider(value: $positionIntervalSecs, in: 30...3600, step: 30)
            Button("Apply Interval") {
                let ok = meshtastic.applyPositionBroadcastInterval(seconds: UInt32(positionIntervalSecs))
                statusMessage = ok ? "Position interval sent." : "Apply failed: \(meshtastic.lastError ?? "not connected")"
            }
            .disabled(activeTransport != .meshtastic)
        }
    }

    // MARK: - Actions

    private func createAndApply() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        switch activeTransport {
        case .meshtastic, .none:
            // Default new channels to the first free private index (or 0 if primary).
            let index = newIsPrimary ? 0 : nextFreeMeshtasticIndex()
            let ch = MeshtasticManager.StoredChannel(
                index: index, name: name, pskHex: newPSKHex.trimmingCharacters(in: .whitespaces),
                isPrimary: newIsPrimary
            )
            let ok = meshtastic.applyChannel(ch)
            statusMessage = ok
                ? "Channel \"\(name)\" applied at index \(index)."
                : "Saved \"\(name)\" (apply needs a connected radio)."
        case .meshcore:
            if #available(iOS 13.0, *) {
                let ok = meshcore.applyChannel(index: 1, name: name, secretHex: newPSKHex)
                statusMessage = ok ? "MeshCore channel \"\(name)\" applied." : "Apply failed."
            }
        }
        newName = ""; newPSKHex = ""; newIsPrimary = false
    }

    private func joinFromLink() {
        let input = joinText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = MeshChannelShare.parse(input) else {
            joinResult = "Unrecognized link."
            return
        }
        switch parsed {
        case .meshtastic(let chans):
            let applied = meshtastic.applyImportedChannels(chans)
            joinResult = applied > 0
                ? "Applied \(applied) Meshtastic channel(s)."
                : "Imported \(chans.count) channel(s) (connect a radio to apply)."
        case .meshcore(let ch):
            if #available(iOS 13.0, *) {
                let ok = meshcore.applyImportedChannel(ch)
                joinResult = ok ? "Applied MeshCore channel \"\(ch.name)\"." : "Connect a MeshCore radio to apply."
            } else {
                joinResult = "MeshCore needs iOS 13+."
            }
        }
        joinText = ""
    }

    private func applyDeviceConfig() {
        let ok = meshtastic.applyDeviceConfig(role: selectedRole, rebroadcastMode: selectedRebroadcast)
        statusMessage = ok
            ? "Device config sent (\(selectedRole.displayName), \(selectedRebroadcast.displayName))."
            : "Apply failed: \(meshtastic.lastError ?? "not connected")"
    }

    // MARK: - Helpers

    private func nextFreeMeshtasticIndex() -> Int {
        let used = Set(meshtastic.appChannels.map { $0.index })
        for i in 1...7 where !used.contains(i) { return i }
        return 1
    }

    private var transportLabel: String {
        switch activeTransport {
        case .meshtastic: return "Meshtastic"
        case .meshcore:   return "MeshCore"
        case .none:       return "None"
        }
    }

    private var shareTransportLabel: MeshShareTransport {
        activeTransport == .meshcore ? .meshcore : .meshtastic
    }

    private var transportIcon: String {
        switch activeTransport {
        case .meshtastic: return "antenna.radiowaves.left.and.right"
        case .meshcore:   return "dot.radiowaves.left.and.right"
        case .none:       return "wifi.slash"
        }
    }
}

// MARK: - Share Sheet (URL + QR)

struct MeshChannelShareSheet: View {
    let channel: MeshtasticManager.StoredChannel
    let transport: MeshShareTransport

    @Environment(\.presentationMode) private var presentationMode
    @State private var qrImage: UIImage?

    private var shareURL: String? {
        switch transport {
        case .meshtastic:
            return MeshtasticManager.shared.channelShareURL(only: channel)
        case .meshcore:
            if #available(iOS 13.0, *) {
                return MeshCoreManager.shared.channelShareURL(name: channel.name, secretHex: channel.pskHex)
            }
            return nil
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text(channel.name.isEmpty ? "(default channel)" : channel.name)
                    .font(.headline)

                if let img = qrImage {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                } else {
                    ProgressView().frame(width: 240, height: 240)
                }

                if let url = shareURL {
                    Text(url)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .textSelection(.enabled)

                    if #available(iOS 16.0, *) {
                        ShareLink(item: url) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                    }
                } else {
                    Text("No share URL for this channel.")
                        .font(.footnote).foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Share Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { presentationMode.wrappedValue.dismiss() }
                }
            }
            .onAppear {
                if let url = shareURL {
                    qrImage = ProfileQRCodec.generateQRImage(for: url, size: 480)
                }
            }
        }
    }
}

struct MeshtasticSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        MeshtasticSettingsView()
    }
}
