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

    // Settings state. These start at what the radio reports (#148), so Apply
    // only changes what the operator changed. A value the radio leaves out of
    // its message is its default (no role is CLIENT, no rebroadcast mode is
    // ALL), so a radio at factory settings starts at CLIENT and ALL. The two
    // pickers are nil until the radio's device config is known, and when it
    // holds a value this screen has no entry for (the picker then shows that
    // number, and Apply leaves it alone unless the operator picks another).
    @State private var selectedRole: MeshtasticAdminCodec.DeviceRole?
    @State private var selectedRebroadcast: MeshtasticAdminCodec.RebroadcastMode?
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
            .onAppear {
                loadRoleFromRadio()
                loadRebroadcastFromRadio()
                loadIntervalFromRadio()
            }
            .onChange(of: meshtastic.radioSettings.deviceRole) { _ in loadRoleFromRadio() }
            .onChange(of: meshtastic.radioSettings.rebroadcastMode) { _ in loadRebroadcastFromRadio() }
            .onChange(of: meshtastic.radioSettings.positionBroadcastSeconds) { _ in loadIntervalFromRadio() }
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
        Section {
            Picker("Role", selection: $selectedRole) {
                // The radio's own role when this screen has no name for it, or a
                // placeholder until the radio has said. Neither is ever written.
                if !deviceLoaded {
                    Text("Not loaded").tag(MeshtasticAdminCodec.DeviceRole?.none)
                } else if let raw = meshtastic.radioSettings.unlistedDeviceRole {
                    Text("Role \(raw)").tag(MeshtasticAdminCodec.DeviceRole?.none)
                }
                ForEach(MeshtasticAdminCodec.DeviceRole.allCases, id: \.rawValue) { role in
                    Text(role.displayName).tag(Optional(role))
                }
            }
            .disabled(!deviceLoaded)
            Picker("Rebroadcast Scope", selection: $selectedRebroadcast) {
                if !deviceLoaded {
                    Text("Not loaded").tag(MeshtasticAdminCodec.RebroadcastMode?.none)
                } else if let raw = meshtastic.radioSettings.unlistedRebroadcastMode {
                    Text("Mode \(raw)").tag(MeshtasticAdminCodec.RebroadcastMode?.none)
                }
                ForEach(MeshtasticAdminCodec.RebroadcastMode.allCases, id: \.rawValue) { mode in
                    Text(mode.displayName).tag(Optional(mode))
                }
            }
            .disabled(!deviceLoaded)
            Button("Apply Device Config") { applyDeviceConfig() }
                .disabled(activeTransport != .meshtastic || !deviceLoaded)
        } header: {
            Text("Device")
        } footer: {
            if !deviceLoaded {
                Text(MeshtasticWriteResult.notLoaded)
            } else if let note = unlistedDeviceValuesNote {
                Text(note)
            }
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
        Section {
            HStack {
                Text("Interval")
                Spacer()
                Text(intervalLabel)
                    .foregroundColor(.secondary)
            }
            Slider(value: $positionIntervalSecs, in: 30...3600, step: 30)
                .disabled(!positionLoaded)
            Button("Apply Interval") {
                switch meshtastic.applyPositionBroadcastInterval(seconds: UInt32(positionIntervalSecs)) {
                case .sent:
                    statusMessage = "Position interval sent."
                case .unchanged:
                    statusMessage = MeshtasticWriteResult.nothingToChange
                case .refused(let reason):
                    statusMessage = "Apply failed: \(reason)"
                }
            }
            .disabled(activeTransport != .meshtastic || !positionLoaded)
        } header: {
            Text("Position Broadcast")
        } footer: {
            if !positionLoaded {
                Text(MeshtasticWriteResult.notLoaded)
            }
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
            switch meshtastic.applyChannel(ch) {
            case .sent:
                statusMessage = "Channel \"\(name)\" applied at index \(index)."
            case .unchanged:
                statusMessage = "Channel \"\(name)\" at index \(index): \(MeshtasticWriteResult.nothingToChange)"
            case .refused(let reason):
                statusMessage = "Saved \"\(name)\". Not applied to the radio: \(reason)"
            }
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
            let outcome = meshtastic.applyImportedChannels(chans)
            let already = outcome.unchanged > 0 ? " \(outcome.unchanged) already on the radio." : ""
            if let refusal = outcome.refusal {
                joinResult = outcome.applied > 0
                    ? "Applied \(outcome.applied) of \(chans.count) Meshtastic channel(s).\(already) Not applied: \(refusal)"
                    : "Imported \(chans.count) channel(s).\(already) Not applied to the radio: \(refusal)"
            } else if outcome.applied > 0 {
                joinResult = "Applied \(outcome.applied) Meshtastic channel(s).\(already)"
            } else if outcome.unchanged > 0 {
                joinResult = "Imported \(chans.count) channel(s). \(MeshtasticWriteResult.nothingToChange)"
            } else {
                joinResult = "Imported \(chans.count) channel(s)."
            }
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
        // Only what the operator changed from the radio's value is written. The
        // radio's role is not touched by changing the rebroadcast scope, and the
        // other way round.
        let radio = meshtastic.radioSettings
        let role = selectedRole.flatMap { $0 != radio.namedDeviceRole ? $0 : nil }
        let mode = selectedRebroadcast.flatMap { $0 != radio.namedRebroadcastMode ? $0 : nil }
        switch meshtastic.applyDeviceConfig(role: role, rebroadcastMode: mode) {
        case .sent:
            let changed = [role?.displayName, mode?.displayName].compactMap { $0 }
            statusMessage = "Device config sent (\(changed.joined(separator: ", ")))."
        case .unchanged:
            statusMessage = MeshtasticWriteResult.nothingToChange
        case .refused(let reason):
            statusMessage = "Apply failed: \(reason)"
        }
    }

    // MARK: - What the radio reports

    private var deviceLoaded: Bool { meshtastic.radioSettings.hasDeviceConfig }
    private var positionLoaded: Bool { meshtastic.radioSettings.hasPositionConfig }

    private func loadRoleFromRadio() {
        selectedRole = meshtastic.radioSettings.namedDeviceRole
    }

    private func loadRebroadcastFromRadio() {
        selectedRebroadcast = meshtastic.radioSettings.namedRebroadcastMode
    }

    /// "Not loaded" until the position config is known. 0 is how the radio says
    /// "use my default".
    private var intervalLabel: String {
        guard positionLoaded else { return "Not loaded" }
        return positionIntervalSecs == 0 ? "radio default" : "\(Int(positionIntervalSecs))s"
    }

    private func loadIntervalFromRadio() {
        if let seconds = meshtastic.radioSettings.positionBroadcastSeconds {
            positionIntervalSecs = Double(seconds)
        }
    }

    /// Set when the radio holds a role or rebroadcast mode this screen has no
    /// entry for. The picker is then empty, and Apply leaves that setting alone
    /// unless the operator picks another.
    private var unlistedDeviceValuesNote: String? {
        var unlisted: [String] = []
        if let raw = meshtastic.radioSettings.unlistedDeviceRole {
            unlisted.append("role \(raw)")
        }
        if let raw = meshtastic.radioSettings.unlistedRebroadcastMode {
            unlisted.append("rebroadcast mode \(raw)")
        }
        guard !unlisted.isEmpty else { return nil }
        return "This radio uses \(unlisted.joined(separator: " and ")), which is not in the list. "
            + "Apply leaves it as it is unless you pick another."
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
