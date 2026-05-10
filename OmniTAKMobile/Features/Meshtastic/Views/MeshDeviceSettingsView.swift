//
//  MeshDeviceSettingsView.swift
//  OmniTAK Mobile
//
//  GAP-109 / GAP-109a — operator-facing Meshtastic device settings.
//  Mirrors Android `MeshDeviceSettingsScreen.kt`.
//

import SwiftUI

struct MeshDeviceSettingsView: View {
    @ObservedObject private var store = MeshDeviceConfigStore.shared
    @ObservedObject private var manager = MeshtasticManager.shared

    @State private var pushStatus: String?
    @State private var isPushing = false
    @State private var isReading = false

    private let pliQuickPicks: [Int] = [15, 30, 60, 120, 300]

    var body: some View {
        Form {
            ownerSection
            roleSection
            pliSection
            channelSection
            presetSection
            actionSection
            if let status = pushStatus {
                Section {
                    Text(status).font(.footnote).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Device Settings")
    }

    // MARK: - Sections

    private var ownerSection: some View {
        Section(header: Text("Owner")) {
            HStack {
                Text("Long name")
                Spacer()
                TextField("OmniTAK", text: Binding(
                    get: { store.config.longName },
                    set: { v in store.update { $0.longName = v } }
                ))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled(true)
            }
            HStack {
                Text("Short name")
                Spacer()
                TextField("OTK", text: Binding(
                    get: { store.config.shortName },
                    set: { v in store.update { $0.shortName = String(v.prefix(4)) } }
                ))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled(true)
            }
            Text("Long name shows in the node list. Short name is the 4-character callsign on the radio screen.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var roleSection: some View {
        Section(header: Text("Role")) {
            Picker("Role", selection: Binding(
                get: { store.config.role },
                set: { v in store.update { $0.role = v } }
            )) {
                ForEach(MeshRole.allCases, id: \.self) { role in
                    Text(role.label).tag(role)
                }
            }
            .pickerStyle(.menu)
            Text(store.config.role.blurb)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var pliSection: some View {
        Section(header: Text("Position broadcast")) {
            Stepper(value: Binding(
                get: { store.config.positionBroadcastSecs },
                set: { v in store.update { $0.positionBroadcastSecs = v } }
            ), in: 0...3600, step: 5) {
                Text("\(store.config.positionBroadcastSecs) s")
            }
            HStack(spacing: 8) {
                ForEach(pliQuickPicks, id: \.self) { secs in
                    Button("\(secs)s") {
                        store.update { $0.positionBroadcastSecs = secs }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Text("0 disables. Lower values use more battery and airtime.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var channelSection: some View {
        Section(header: Text("Primary channel (CH0)")) {
            HStack {
                Text("Name")
                Spacer()
                TextField("OmniTAK", text: Binding(
                    get: { store.config.channelName },
                    set: { v in store.update { $0.channelName = v } }
                ))
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled(true)
            }
        }
    }

    private var presetSection: some View {
        Section(header: Text("LoRa preset")) {
            Picker("Preset", selection: Binding(
                get: { store.config.channelPreset },
                set: { v in store.update { $0.channelPreset = v } }
            )) {
                ForEach(MeshChannelPreset.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.menu)
            Text(store.config.channelPreset.blurb)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var actionSection: some View {
        Section {
            if manager.isConnected {
                Button(action: pushToDevice) {
                    HStack {
                        if isPushing { ProgressView().padding(.trailing, 4) }
                        Text(isPushing ? "Pushing..." : "Push to device")
                    }
                }
                .disabled(isPushing)

                Button(action: readFromDevice) {
                    HStack {
                        if isReading { ProgressView().padding(.trailing, 4) }
                        Text(isReading ? "Reading..." : "Read from device")
                    }
                }
                .disabled(isReading)
            } else {
                Text("Connect to a radio to push these settings.")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func pushToDevice() {
        isPushing = true
        pushStatus = nil
        Task {
            let sent = await manager.pushDeviceConfig(store.config)
            await MainActor.run {
                isPushing = false
                pushStatus = "\(sent) of 5 settings pushed."
            }
        }
    }

    private func readFromDevice() {
        isReading = true
        pushStatus = nil
        Task {
            let sent = await manager.requestDeviceConfig()
            await MainActor.run {
                isReading = false
                pushStatus = "\(sent) read requests sent. Responses fold in as they arrive."
            }
        }
    }
}

#if DEBUG
struct MeshDeviceSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            MeshDeviceSettingsView()
        }
    }
}
#endif
