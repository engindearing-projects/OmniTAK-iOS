//
//  PluginsListView.swift
//  OmniTAKMobile
//
//  Plugin management interface — driven by PluginRegistry.
//

import SwiftUI

struct PluginsListView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var legacyManager = PluginSettingsManager.shared

    var body: some View {
        NavigationView {
            List {
                if !registry.plugins.isEmpty {
                    Section("PLUGINS") {
                        ForEach(registry.plugins) { plugin in
                            NavigationLink(destination: PluginDetailView(plugin: plugin)) {
                                PluginRegistryRow(plugin: plugin, registry: registry)
                            }
                        }
                    }
                }

                Section("FEATURES") {
                    ForEach(PluginID.allCases, id: \.self) { plugin in
                        PluginRow(plugin: plugin, pluginManager: legacyManager)
                    }
                }

                Section {
                    Button(action: {
                        legacyManager.resetAll()
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
                        Text("OmniTAK Mobile v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0")")
                            .font(.system(size: 11))
                            .foregroundColor(.gray)
                        Spacer()
                    }
                }
            }
            .navigationTitle("Plugins")
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

// MARK: - Registry-backed Row

struct PluginRegistryRow: View {
    let plugin: RegisteredPlugin
    @ObservedObject var registry: PluginRegistry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 22))
                .foregroundColor(registry.isEnabled(plugin.id) ? .blue : .gray)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plugin.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(registry.isEnabled(plugin.id) ? .primary : .gray)
                    Text("v\(plugin.version)")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    if plugin.isExample {
                        Text("EXAMPLE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .cornerRadius(4)
                    }
                }
                Text(plugin.description)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
                Text("by \(plugin.author)  •  \(plugin.id)")
                    .font(.system(size: 10))
                    .foregroundColor(.gray.opacity(0.7))
            }

            Spacer()

            Toggle("", isOn: registry.binding(for: plugin.id))
                .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail view (renders the plugin's own settingsView())

struct PluginDetailView: View {
    let plugin: RegisteredPlugin

    var body: some View {
        Group {
            if let view = plugin.instance.settingsView() {
                view
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(plugin.displayName)
                            .font(.title2.bold())
                        Text("v\(plugin.version)  •  \(plugin.author)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(plugin.description)
                            .font(.body)
                        Text(plugin.id)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                    .padding()
                }
            }
        }
        .navigationTitle(plugin.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Legacy feature row (toggleable feature flags)

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
