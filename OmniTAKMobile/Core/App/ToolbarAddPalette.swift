//
//  ToolbarAddPalette.swift
//  OmniTAKMobile
//
//  The "add a shortcut" palette opened from the bar's ＋ tile (or while
//  editing). Lists every catalog shortcut not already in the bar, grouped
//  by section. Tapping adds it; the bar updates live behind the sheet.
//

import SwiftUI
import UIKit

struct ToolbarAddPalette: View {
    @ObservedObject private var store = ToolbarConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if store.isFull {
                    Section {
                        Label("Toolbar is full (\(ToolbarConfigStore.maxItems) max). Remove a shortcut to add another.",
                              systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                section(title: "Screens", items: available(BarItem.destinations))
                section(title: "Map Tools", items: available(BarItem.mapCommands))
                section(title: "More Tools", items: available(BarItem.toolShortcuts))

                Section {
                    Button(role: .destructive) {
                        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                        withAnimation { store.resetToDefault() }
                    } label: {
                        Label("Reset to Default Toolbar", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Add Shortcut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func available(_ group: [BarItem]) -> [BarItem] {
        group.filter { item in !store.itemIDs.contains(item.id) }
    }

    @ViewBuilder
    private func section(title: String, items: [BarItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    Button {
                        guard !store.isFull else { return }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            store.add(item.id)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            IconImage(name: item.icon, size: 18)
                                .foregroundColor(item.tint)
                                .frame(width: 30)
                            // Reuse the bar's per-id label keys so the
                            // palette matches the localized bottom bar. L()
                            // is fine here — the sheet is rebuilt on each open
                            // so it resolves to the current language.
                            Text(L("bar." + item.id))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: store.isFull ? "circle.slash" : "plus.circle.fill")
                                .foregroundColor(store.isFull ? .secondary : item.tint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isFull)
                }
            }
        }
    }
}
