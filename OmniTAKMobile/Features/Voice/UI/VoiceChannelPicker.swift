//
//  VoiceChannelPicker.swift
//  OmniTAKMobile
//
//  Searchable channel list for one PTT slot. Used from the map panel (tap a
//  slot's channel label) and from the plugin settings (tap the collapsed
//  channel row). Enforces the slot rule in the UI: a channel occupied by the
//  other slot is shown but can't be picked. Slot 2 also offers "Off".
//

import SwiftUI

struct VoiceChannelPicker: View {
    @ObservedObject var controller: VoiceController
    let slot: Int
    var onPicked: () -> Void = {}

    @State private var query = ""

    private var otherSlot: Int { slot == 1 ? 2 : 1 }

    /// Slot 2 uses slot 1's channel directory (same server) until it connects.
    private var directory: [VoiceController.Channel] {
        let own = controller.slots[slot - 1].channels
        return own.isEmpty && slot == 2 ? controller.slots[0].channels : own
    }

    private var filtered: [VoiceController.Channel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return directory }
        return directory.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private var currentId: UInt32? {
        slot == 2 && !controller.isSlot2Enabled ? nil : controller.slots[slot - 1].currentChannelId
    }

    var body: some View {
        List {
            if let n = controller.notice {
                Text(n).font(.footnote).foregroundColor(.orange)
            }
            if slot == 2 {
                Section {
                    Button {
                        controller.setSecondChannel(nil)
                        onPicked()
                    } label: {
                        row(name: "Off", detail: "PTT 2 disabled", selected: !controller.isSlot2Enabled, blocked: false)
                    }
                }
            }
            Section(header: Text("\(filtered.count) of \(directory.count) channels")) {
                if directory.isEmpty {
                    Text(controller.slots[0].statusLine).foregroundColor(.secondary)
                }
                ForEach(filtered) { ch in
                    let blocked = isOccupiedByOtherSlot(ch)
                    Button {
                        controller.join(slot: slot, channelId: ch.id)
                        if controller.notice == nil { onPicked() }
                    } label: {
                        row(name: ch.name,
                            detail: blocked ? "In use by PTT \(otherSlot)" : nil,
                            selected: ch.id == currentId,
                            blocked: blocked)
                    }
                    .disabled(blocked)
                }
            }
        }
        .searchable(text: $query, prompt: "Search channels")
        .navigationTitle("PTT \(slot) channel")
    }

    /// Live (where the other slot is) or configured (where it is set to go).
    private func isOccupiedByOtherSlot(_ ch: VoiceController.Channel) -> Bool {
        if otherSlot == 2 && !controller.isSlot2Enabled { return false }
        return controller.slots[otherSlot - 1].currentChannelId == ch.id
            || controller.isConfiguredForOtherSlot(ch, slot: slot)
    }

    private func row(name: String, detail: String?, selected: Bool, blocked: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).foregroundColor(blocked ? .secondary : .primary)
                if let d = detail { Text(d).font(.caption).foregroundColor(.secondary) }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundColor(.accentColor) }
        }
    }
}
