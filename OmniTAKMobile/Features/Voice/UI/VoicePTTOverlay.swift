//
//  VoicePTTOverlay.swift
//  OmniTAKMobile
//
//  The on-screen push-to-talk panel, mounted on BOTH map engines through the
//  plugin SDK's `registerMapOverlay` hook. A vertical stack near the middle of
//  the screen edge (right by default; left via Voice settings):
//
//    PTT 1  — always present while the plugin is on; hold to transmit (VS1)
//    PTT 2  — only once a second channel is chosen; hold to transmit (VS2)
//
//  Buttons only, to save map space. Channels and settings open from the
//  "Voice" item in the bottom toolbar (posts `.openVoicePanel`), which shows
//  the plugin settings as a sheet over the map.
//  Only the buttons take touches; empty space lets touches reach the map.
//

import SwiftUI

enum VoicePanelSide: String { case right, left }

struct VoicePTTOverlay: View {
    @ObservedObject var controller: VoiceController
    @AppStorage("voice.panelSide") private var sideRaw = VoicePanelSide.right.rawValue
    @State private var showPanel = false

    private var side: VoicePanelSide { VoicePanelSide(rawValue: sideRaw) ?? .right }

    var body: some View {
        HStack(spacing: 0) {
            if side == .right { Spacer(minLength: 0) }
            panel
                .padding(side == .right ? .trailing : .leading, 10)
            if side == .left { Spacer(minLength: 0) }
        }
        .frame(maxHeight: .infinity, alignment: .center)
        .offset(y: 40)   // a touch below centre, clear of the top toolbars
        .onReceive(NotificationCenter.default.publisher(for: .openVoicePanel)) { _ in
            showPanel = true
        }
        .sheet(isPresented: $showPanel) {
            NavigationView {
                VoicePluginSettingsView(controller: controller)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showPanel = false }
                        }
                    }
            }
        }
    }

    private var panel: some View {
        VStack(alignment: side == .right ? .trailing : .leading, spacing: 10) {
            ForEach(controller.activeSpeakers.prefix(2), id: \.self) { speaker in
                Label(speaker, systemImage: "waveform")
                    .font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.85)))
                    .foregroundColor(.black)
                    .allowsHitTesting(false)
            }
            PTTSlotRow(controller: controller, slot: 1)
            PTTSlotRow(controller: controller, slot: 2)
        }
    }
}

private struct PTTSlotRow: View {
    @ObservedObject var controller: VoiceController
    let slot: Int
    @GestureState private var pressing = false

    var body: some View {
        // PTT 2 only appears once a second channel is picked (gear → Channels).
        if slot == 1 || controller.isSlot2Enabled {
            pttButton
        }
    }

    private var status: VoiceController.SlotStatus { controller.slots[slot - 1] }

    private var pttButton: some View {
        // Slot 2 is "ready" only when connected in its own channel (otherwise
        // PTT 2 falls back to slot 1 and lights button 1).
        let shared = slot == 2 && status.currentChannelId != nil
            && status.currentChannelId == controller.slots[0].currentChannelId
        let ready = status.state == .connected && controller.slots[0].state == .connected && !shared
        let listenOnly = status.suppressed
        let tx = controller.transmittingSlot == slot
        let busy = controller.transmittingSlot != nil && !tx   // the other slot owns the mic
        return ZStack {
            Circle()
                .fill(tx ? Color.red : (ready ? (slot == 1 ? Color.yellow : Color.cyan) : Color.gray))
                .frame(width: 72, height: 72)
                .shadow(radius: tx ? 10 : 4)
            VStack(spacing: 1) {
                Image(systemName: tx ? "mic.fill" : "mic")
                    .font(.system(size: 20, weight: .bold))
                Text(tx ? "TX \(slot)" : (listenOnly ? "LISTEN" : "PTT \(slot)")).font(.caption2.bold())
            }
            .foregroundColor(.black)
        }
        .opacity(ready && !busy && !listenOnly ? 1 : 0.55)
        .contentShape(Circle())
        // @GestureState resets when the gesture ends OR is cancelled (sheet,
        // system gesture, view removed) — onEnded alone misses cancellation and
        // could leave the mic keyed.
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressing) { _, state, _ in state = true }
        )
        .onChange(of: pressing) { down in
            if down { controller.pttDown(slot: slot, source: .onScreen) }
            else { controller.pttUp(slot: slot, source: .onScreen) }
        }
        .onDisappear { controller.pttUp(slot: slot, source: .onScreen) }
        .accessibilityLabel("Push to talk, slot \(slot)")
        .accessibilityHint("Press and hold to transmit on \(status.currentChannelName)")
    }
}
