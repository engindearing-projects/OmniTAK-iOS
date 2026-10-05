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
    @State private var newKeyText: String = ""
    @State private var newNoEncryption: Bool = false
    @State private var newReplacesPrimary: Bool = false

    // Join (scan/paste) state
    @State private var joinText: String = ""
    @State private var joinResult: String?

    // Device and Position controls (#148). They start at what the radio reports
    // and Apply writes only what the operator changed from it; the rules, and
    // their tests, are in MeshtasticSettingsControls.
    @State private var controls = MeshtasticSettingsControls()

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
                if !meshtastic.channelReports.isEmpty {
                    Section("Channel writes") {
                        ForEach(meshtastic.channelReports) { report in
                            Text(report.text).font(.footnote).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Mesh Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showingShare) {
                if let ch = shareChannel {
                    MeshChannelShareSheet(channel: ch, transport: shareTransportLabel)
                }
            }
            // Seeding only starts a control over when the radio's own value for
            // it has changed, so this does not undo the operator's choice when a
            // pushed picker pops back and the form appears again.
            .onAppear { controls.seed(from: meshtastic.radioSettings) }
            .onChange(of: meshtastic.radioSettings) { _ in controls.seed(from: meshtastic.radioSettings) }
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
        // The key rules, the free-slot choice and the two toggles are for a
        // Meshtastic radio. A MeshCore radio keeps the form it had.
        let meshtasticForm = activeTransport != .meshcore
        return Section {
            TextField(meshtasticForm ? "Name (11 bytes at most)" : "Name", text: $newName)
                .autocorrectionDisabled()
            TextField(meshtasticForm ? "Key (hex or base64)" : "PSK (hex, optional)", text: $newKeyText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if meshtasticForm {
                Toggle("No encryption (open channel)", isOn: $newNoEncryption)
                Toggle("Replace primary channel", isOn: $newReplacesPrimary)
            }
            Button("Create & Apply") { createAndApply() }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Create Channel")
        } footer: {
            if meshtasticForm {
                Text("A new channel goes into a free slot on the radio. Replacing the primary changes its name, "
                     + "and its key if you enter one; leave the key blank to keep the radio's key.")
            }
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
            Picker("Role", selection: $controls.role) {
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
            Picker("Rebroadcast Scope", selection: $controls.rebroadcast) {
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
                Text(notLoadedText(variant: MeshtasticAdminCodec.ConfigVariant.device))
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
                Text(controls.intervalLabel(radio: meshtastic.radioSettings))
                    .foregroundColor(.secondary)
            }
            Slider(value: $controls.intervalSeconds, in: 30...3600, step: 30)
                .disabled(!positionLoaded)
            Button("Apply Interval") {
                switch meshtastic.applyPositionBroadcastInterval(seconds: controls.intervalToWrite) {
                case .sent:
                    statusMessage = "Position interval sent. The radio restarts to apply it. Reconnect when it is back."
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
                Text(notLoadedText(variant: MeshtasticAdminCodec.ConfigVariant.position))
            }
        }
    }

    // MARK: - Actions

    private func createAndApply() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        switch activeTransport {
        case .meshtastic, .none:
            let outcome = meshtastic.createChannel(
                name: name, keyText: newKeyText,
                noEncryption: newNoEncryption, replacePrimary: newReplacesPrimary)
            switch outcome.result {
            case .sent:
                statusMessage = "Channel \"\(name)\" sent to slot \(outcome.slot ?? 0). Waiting for the radio to confirm."
                clearCreateForm()
            case .unchanged:
                statusMessage = "Slot \(outcome.slot ?? 0): \(MeshtasticWriteResult.nothingToChange)"
                clearCreateForm()
            case .refused(let reason):
                // What was typed stays, so that it can be corrected and sent again.
                statusMessage = "Not applied: \(reason)"
            }
        case .meshcore:
            // Not covered by #148: the MeshCore path keeps its own slot and key handling.
            if #available(iOS 13.0, *) {
                let ok = meshcore.applyChannel(index: 1, name: name, secretHex: newKeyText)
                statusMessage = ok ? "MeshCore channel \"\(name)\" applied." : "Apply failed."
            }
            clearCreateForm()
        }
    }

    private func clearCreateForm() {
        newName = ""; newKeyText = ""; newNoEncryption = false; newReplacesPrimary = false
    }

    private func joinFromLink() {
        let input = joinText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = MeshChannelShare.parse(input) else {
            joinResult = "Unrecognized link."
            return
        }
        switch parsed {
        case .meshtastic(let chans):
            joinResult = importSummary(meshtastic.importChannels(chans), total: chans.count)
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

    /// What an import did, counted from what was actually sent: how many went
    /// to which slots, how many the radio already had, and how many were left
    /// out and why.
    private func importSummary(_ outcome: MeshtasticManager.ImportOutcome, total: Int) -> String {
        if let refusal = outcome.refusal, outcome.sent.isEmpty {
            return "Imported \(total) channel(s). Not applied to the radio: \(refusal)"
        }
        var parts: [String] = []
        if !outcome.sent.isEmpty {
            let slots = outcome.sent.map(String.init).joined(separator: ", ")
            parts.append("Sent \(outcome.sent.count) of \(total) to slot \(slots). Waiting for the radio to confirm.")
        }
        if outcome.alreadyThere > 0 {
            parts.append("\(outcome.alreadyThere) already on the radio.")
        }
        if outcome.noRoom > 0 {
            parts.append("\(outcome.noRoom) not added: no free slot on the radio.")
        }
        parts.append(contentsOf: outcome.skipped)
        if let refusal = outcome.refusal {
            parts.append("Stopped: \(refusal)")
        }
        if parts.isEmpty { parts.append("Imported \(total) channel(s).") }
        return parts.joined(separator: " ")
    }

    private func applyDeviceConfig() {
        // Only what the operator changed from the radio's value is written. The
        // radio's role is not touched by changing the rebroadcast scope, and the
        // other way round.
        let edits = controls.deviceEdits(against: meshtastic.radioSettings)
        switch meshtastic.applyDeviceConfig(role: edits.role, rebroadcastMode: edits.rebroadcast) {
        case .sent:
            let changed = [edits.role?.displayName, edits.rebroadcast?.displayName].compactMap { $0 }
            statusMessage = "Device config sent (\(changed.joined(separator: ", "))). The radio restarts to apply it. Reconnect when it is back."
        case .unchanged:
            statusMessage = MeshtasticWriteResult.nothingToChange
        case .refused(let reason):
            statusMessage = "Apply failed: \(reason)"
        }
    }

    // MARK: - What the radio reports

    private var deviceLoaded: Bool { meshtastic.radioSettings.hasDeviceConfig }
    private var positionLoaded: Bool { meshtastic.radioSettings.hasPositionConfig }

    /// Why the controls of a sub-config are empty: the radio was sent a change
    /// and is restarting, or its settings have not arrived.
    private func notLoadedText(variant: Int) -> String {
        meshtastic.radioSettings.isAwaitingRestart(variant: variant)
            ? MeshtasticWriteResult.restarting
            : MeshtasticWriteResult.notLoaded
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
