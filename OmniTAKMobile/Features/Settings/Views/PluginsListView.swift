//
//  PluginsListView.swift
//  OmniTAKMobile
//
//  Plugin management interface
//

import SwiftUI

struct PluginsListView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var pluginManager = PluginSettingsManager.shared

    // Registered OmniTAKPlugins from the SDK registry. ADS-B lives here now
    // (not in FEATURES) — listed exactly once.
    private var registeredPlugins: [OmniTAKPlugin] { PluginRegistry.shared.all() }

    var body: some View {
        NavigationView {
            List {
                Section("PLUGINS") {
                    ForEach(registeredPlugins, id: \.pluginId) { plugin in
                        RegisteredPluginRow(plugin: plugin, pluginManager: pluginManager)
                    }
                }

                Section("FEATURES") {
                    ForEach(PluginID.allCases, id: \.self) { plugin in
                        PluginRow(plugin: plugin, pluginManager: pluginManager)
                    }
                }

                Section {
                    Button(action: {
                        pluginManager.resetAll()
                    }) {
                        HStack {
                            Spacer()
                            Text("Enable All Features")
                                .foregroundColor(.blue)
                            Spacer()
                        }
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Text("OmniTAK v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0")")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Features")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Plugin Row

struct PluginRow: View {
    let plugin: PluginID
    @ObservedObject var pluginManager: PluginSettingsManager

    var body: some View {
        HStack {
            Image(systemName: plugin.icon)
                .font(.system(size: 24))
                .foregroundColor(pluginManager.isEnabled(plugin) ? .blue : .gray)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(plugin.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(pluginManager.isEnabled(plugin) ? .primary : .gray)
                    Text("v1.0.0")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                Text(plugin.description)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }

            Spacer()

            Toggle("", isOn: pluginManager.binding(for: plugin))
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Registered Plugin Row (SDK)

/// A row for a registered OmniTAKPlugin. Shows icon + name + version +
/// description with an enable Toggle. If the plugin ships a settingsContent(),
/// the row becomes a NavigationLink into that screen.
struct RegisteredPluginRow: View {
    let plugin: OmniTAKPlugin
    @ObservedObject var pluginManager: PluginSettingsManager

    private var isEnabled: Bool {
        pluginManager.isRegisteredPluginEnabled(plugin.pluginId)
    }

    var body: some View {
        if let settings = plugin.settingsContent() {
            NavigationLink {
                settings.navigationTitle(plugin.displayName)
            } label: {
                rowContent
            }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack {
            Image(systemName: iconName)
                .font(.system(size: 24))
                .foregroundColor(isEnabled ? .blue : .gray)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(plugin.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isEnabled ? .primary : .gray)
                    Text("v\(plugin.pluginVersion)")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                }
                Text(plugin.pluginDescription)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
            }

            Spacer()

            Toggle("", isOn: pluginManager.registeredBinding(for: plugin.pluginId))
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    /// Prefer a settings-row icon the plugin registered for itself; fall back
    /// to a generic puzzle-piece glyph.
    private var iconName: String {
        AppPluginHost.shared.settingsRows
            .first { $0.pluginId == plugin.pluginId }?.icon
            ?? "puzzlepiece.extension.fill"
    }
}
