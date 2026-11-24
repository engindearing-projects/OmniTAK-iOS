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
import AVFoundation

final class VoicePlugin: OmniTAKPlugin {
    let pluginId = "com.atakmap.android.xv.plugin"
    let displayName = "X Voice"
    let pluginVersion = "0.2.0"
    let pluginAuthor = "TX-TAK"
    let pluginDescription = "TAK-XVoice for OmniTAK: push-to-talk voice over your TAK server's Mumble voice server — dual channels, Bluetooth speaker-mics and PTT buttons"

    private(set) var controller: VoiceController?

    func activate(host: PluginHost) {
        let bridge = host as? VoiceHostBridge
        if bridge == nil { print("[VoicePlugin] host does not provide VoiceHostBridge — voice unavailable") }
        let c = VoiceController(bridge: bridge)
        controller = c
        host.registerMapOverlay { AnyView(VoicePTTOverlay(controller: c)) }
        host.registerSettingsRow(label: "X Voice", icon: "asset:XVoiceSpeakerMic")
        c.start()
    }

    func deactivate() {
        controller?.stop()
        controller = nil
    }

    func settingsContent() -> AnyView? {
        guard let c = controller else {
            return AnyView(Text("Enable the X Voice plugin to configure it.").padding())
        }
        return AnyView(VoicePluginSettingsView(controller: c))
    }
}

struct VoicePluginSettingsView: View {
    @ObservedObject var controller: VoiceController
    @AppStorage("voice.panelSide") private var panelSide = "right"
    @AppStorage(VoiceController.txTimeoutKey) private var txTimeout = VoiceController.defaultTxTimeout
    @AppStorage(VoiceController.statusTonesKey) private var statusTones = false
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
                Text("iOS plays its own push-to-talk start and end sounds and vibration; start talking after the start cue. Status tones are optional extra cues for channel join/leave and voice loss — iOS's push-to-talk UI already shows these. The transmit time limit warns 5 s before cutting off a held PTT.")
            }

            Section("On-screen controls") {
                Picker("Side", selection: $panelSide) {
                    Text("Right").tag("right")
                    Text("Left").tag("left")
                }
                .pickerStyle(.segmented)
            }

            Section {
                row(controller.blePTT.connectedKind?.deviceWord ?? "Device", controller.blePTT.connectedName ?? "None")
                if let kind = controller.blePTT.connectedKind {
                    row("Type", kind.displayName)
                    row("Buttons", kind.talksOn)
                }
                row("Status", controller.blePTT.status)
                Button(controller.blePTT.isScanning ? "Scanning…" : "Scan for speaker-mics and buttons") {
                    controller.blePTT.startScan()
                }
                .disabled(controller.blePTT.isScanning)
                ForEach(controller.blePTT.discovered) { d in
                    Button {
                        controller.blePTT.connectChosen(d)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name).foregroundColor(.primary)
                                Text("\(d.kind.deviceWord) · \(d.kind.displayName)").font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(d.rssi) dBm").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                if controller.blePTT.savedPeripheralId != nil {
                    Button("Forget this device", role: .destructive) { controller.blePTT.forget() }
                }
            } header: {
                Text("Bluetooth speaker-mic or PTT button")
            } footer: {
                Text("One device at a time: a speaker-mic (AINA APTT V1/V2, Inrico BT02) or a standalone PTT button (Pryme BT-PTT-Z).\n\nSpeaker-mic: pair its audio in iOS Settings → Bluetooth. X Voice then uses it for audio and connects its buttons automatically. The AINA's main PTT keys PTT 1 and its secondary PTT keys PTT 2; the Inrico's PTT keys PTT 1.\n\nStandalone button: don't pair it in iOS Settings. Tap Scan and pick it once; it reconnects by itself after that. It keys PTT 1 only — use the on-screen PTT 2 button for the second channel.\n\nA speaker-mic in use for audio takes priority over a standalone button.")
            }

            Section {
                Picker("Mic boost", selection: $micBoost) {
                    ForEach([0.0, 3, 6, 9, 12], id: \.self) { Text($0 == 0 ? "Off" : "+\(Int($0)) dB").tag($0) }
                }
                Picker("Receive boost", selection: $rxBoost) {
                    ForEach([0.0, 3, 6, 9, 12], id: \.self) { Text($0 == 0 ? "Off" : "+\(Int($0)) dB").tag($0) }
                }
                MicModeRow()
            } header: {
                Text("Audio levels")
            } footer: {
                Text("Applied with a soft limiter so loud speech isn't distorted. On the iPhone's own mic and speaker, iOS voice processing (echo cancellation, noise suppression, automatic gain) is also on; a Bluetooth speaker-mic handles echo itself, so it's off there. An Inrico BT02 gets an extra +5 dB on its mic automatically. While voice is active, the phone's volume buttons also set the speaker-mic / call volume.")
            }
            .onChange(of: micBoost) { _ in controller.reloadAudioLevels() }
            .onChange(of: rxBoost) { _ in controller.reloadAudioLevels() }

            Section("Audio route") {
                Text(controller.audioRoute.isEmpty ? "—" : controller.audioRoute)
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .navigationTitle("X Voice")
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}

/// iOS mic mode for X Voice's built-in-mic audio (Standard / Voice Isolation /
/// Wide Spectrum). Apps can read it and open the system picker, but only the
/// user can choose it; iOS remembers the choice per app. Voice Isolation is
/// recommended. Applies to the iPhone's own mic only (iOS voice processing is
/// off on Bluetooth speaker-mics).
struct MicModeRow: View {
    // preferredMicrophoneMode is the user's choice; activeMicrophoneMode only
    // reflects it while the mic is running.
    @State private var mode = AVCaptureDevice.preferredMicrophoneMode

    var body: some View {
        Group {
            HStack {
                Text("Mic mode (iPhone mic)")
                Spacer()
                Text(Self.name(mode)).foregroundColor(.secondary)
            }
            if mode != .voiceIsolation {
                Text("Recommended: Voice Isolation. It suppresses background noise on the iPhone's own mic. iOS lets only you choose it — it's remembered after that.")
                    .font(.footnote).foregroundColor(.orange)
            }
            Button(mode == .voiceIsolation ? "Change mic mode…" : "Set mic mode to Voice Isolation…") {
                AVCaptureDevice.showSystemUserInterface(.microphoneModes)
            }
        }
        .onAppear { mode = AVCaptureDevice.preferredMicrophoneMode }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            mode = AVCaptureDevice.preferredMicrophoneMode
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            let m = AVCaptureDevice.preferredMicrophoneMode
            if m != mode { mode = m }
        }
    }

    static func name(_ m: AVCaptureDevice.MicrophoneMode) -> String {
        switch m {
        case .standard: return "Standard"
        case .voiceIsolation: return "Voice Isolation"
        case .wideSpectrum: return "Wide Spectrum"
        @unknown default: return "Automatic"
        }
    }
}
