//
//  VoicePlugin.swift
//  OmniTAKMobile
//
//  Push-to-talk voice plugin (Track B). Built on the voice-only
//  `VoiceHostBridge` (Track A): connects to the TAK server's Mumble with the
//  enrolled client certificate, puts a hold-to-talk button on both map
//  engines, and supports Bluetooth LE PTT buttons and Bluetooth (HFP)
//  speaker-mics. Architecture and protocol follow TAK-XVoice (Android), which
//  stays the source of truth. Multicast voice is intentionally not ported.
//
//  pluginId matches the Android plugin's applicationId so enable-state and
//  settings keys line up across platforms (see docs/PLUGIN_AUTHORING.md).
//

import SwiftUI

final class VoicePlugin: OmniTAKPlugin {
    let pluginId = "com.atakmap.android.xv.plugin"
    let displayName = "Voice (PTT)"
    let pluginVersion = "0.2.0"
    let pluginAuthor = "TX-TAK"
    let pluginDescription = "Push-to-talk voice over the TAK server's Mumble (TAK-XVoice port)"

    private(set) var controller: VoiceController?

    func activate(host: PluginHost) {
        let bridge = host as? VoiceHostBridge
        if bridge == nil { print("[VoicePlugin] host does not provide VoiceHostBridge — voice unavailable") }
        let c = VoiceController(bridge: bridge)
        controller = c
        host.registerMapOverlay { AnyView(VoicePTTOverlay(controller: c)) }
        host.registerSettingsRow(label: "Voice (PTT)", icon: "mic.circle.fill")
        c.start()
    }

    func deactivate() {
        controller?.stop()
        controller = nil
    }

    func settingsContent() -> AnyView? {
        guard let c = controller else {
            return AnyView(Text("Enable the Voice (PTT) plugin to configure it.").padding())
        }
        return AnyView(VoicePluginSettingsView(controller: c))
    }
}

struct VoicePluginSettingsView: View {
    @ObservedObject var controller: VoiceController
    @AppStorage("voice.panelSide") private var panelSide = "right"
    @AppStorage(TalkPermitTone.settingsKey) private var tptTone = TalkPermitTone.default.rawValue
    @AppStorage(VoiceController.txTimeoutKey) private var txTimeout = VoiceController.defaultTxTimeout
    @AppStorage(VoiceController.statusTonesKey) private var statusTones = true
    @AppStorage(VoiceAudioEngine.micBoostKey) private var micBoost = VoiceAudioEngine.defaultMicBoostDb
    @AppStorage(VoiceAudioEngine.rxBoostKey) private var rxBoost = VoiceAudioEngine.defaultRxBoostDb

    var body: some View {
        Form {
            Section("Connection") {
                row("Slot 1 (VS1)", controller.slots[0].statusLine)
                row("Slot 2 (VS2)", controller.isSlot2Enabled ? controller.slots[1].statusLine : "Off — pick a second channel")
                row("Microphone", controller.micPermission)
                if let n = controller.notice {
                    Text(n).font(.footnote).foregroundColor(.orange)
                }
                HStack {
                    Button(controller.slots[0].state == .off ? "Connect" : "Reconnect") { controller.reconnect() }
                    Spacer()
                    if controller.slots[0].state != .off {
                        Button("Disconnect", role: .destructive) { controller.stop() }
                    }
                }
            }

            Section("Channels") {
                NavigationLink {
                    VoiceChannelPicker(controller: controller, slot: 1)
                } label: {
                    row("PTT 1", controller.slots[0].currentChannelName)
                }
                NavigationLink {
                    VoiceChannelPicker(controller: controller, slot: 2)
                } label: {
                    row("PTT 2", controller.isSlot2Enabled ? controller.slots[1].currentChannelName : "Off")
                }
                .disabled(controller.slots[0].channels.isEmpty)
            }

            Section {
                Picker("Talk permit tone", selection: $tptTone) {
                    ForEach(TalkPermitTone.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                Toggle("Status tones (join / leave / voice lost)", isOn: $statusTones)
                Picker("Transmit time limit", selection: $txTimeout) {
                    Text("Off").tag(0)
                    Text("30 s").tag(30)
                    Text("60 s").tag(60)
                    Text("2 min").tag(120)
                    Text("3 min").tag(180)
                }
            } header: {
                Text("Tones")
            } footer: {
                Text("Plays once you're cleared to talk; start speaking after it. The tone is never sent over the air. A double low tone means PTT was refused (voice not connected, or listen-only channel); a single low \"bonk\" means the microphone didn't respond.")
            }

            Section("On-screen controls") {
                Picker("Side", selection: $panelSide) {
                    Text("Right").tag("right")
                    Text("Left").tag("left")
                }
                .pickerStyle(.segmented)
            }

            Section {
                row("Button", controller.blePTT.connectedName ?? "None")
                row("Status", controller.blePTT.status)
                Button(controller.blePTT.isScanning ? "Scanning…" : "Scan for PTT buttons") {
                    controller.blePTT.startScan()
                }
                .disabled(controller.blePTT.isScanning)
                ForEach(controller.blePTT.discovered) { d in
                    Button {
                        controller.blePTT.connect(d)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name).foregroundColor(.primary)
                                Text(d.kind.displayName).font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(d.rssi) dBm").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                if controller.blePTT.savedPeripheralId != nil {
                    Button("Forget button", role: .destructive) { controller.blePTT.forget() }
                }
            } header: {
                Text("Bluetooth PTT button")
            } footer: {
                Text("Supported: AINA APTT V1 and V2, Pryme BT-PTT-Z, Inrico BT02 — connected automatically when the speaker-mic is in use. Pair a speaker-mic's audio in iOS Settings → Bluetooth; voice then uses it automatically.")
            }

            Section {
                Picker("Mic boost", selection: $micBoost) {
                    ForEach([0.0, 3, 6, 9, 12], id: \.self) { Text($0 == 0 ? "Off" : "+\(Int($0)) dB").tag($0) }
                }
                Picker("Receive boost", selection: $rxBoost) {
                    ForEach([0.0, 3, 6, 9, 12], id: \.self) { Text($0 == 0 ? "Off" : "+\(Int($0)) dB").tag($0) }
                }
            } header: {
                Text("Audio levels")
            } footer: {
                Text("Applied on top of iOS voice processing (echo cancellation, noise suppression, automatic gain), with a soft limiter so loud speech isn't distorted. An Inrico BT02 gets an extra +5 dB on its mic automatically. While voice is active, the phone's volume buttons also set the speaker-mic / call volume.")
            }
            .onChange(of: micBoost) { _ in controller.reloadAudioLevels() }
            .onChange(of: rxBoost) { _ in controller.reloadAudioLevels() }

            Section("Audio route") {
                Text(controller.audioRoute.isEmpty ? "—" : controller.audioRoute)
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .navigationTitle("Voice (PTT)")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
