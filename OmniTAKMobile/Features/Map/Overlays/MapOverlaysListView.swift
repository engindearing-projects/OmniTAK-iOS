//
//  MapOverlaysListView.swift
//  OmniTAKMobile
//
//  Modal sheet for managing user-imported map overlays (Issue #17).
//
//  This is intentionally a sheet, NOT a side panel. Full-screen map is sacred
//  on this codebase (see feedback_omnitak_fullscreen_map).
//

import SwiftUI
import UniformTypeIdentifiers

struct MapOverlaysListView: View {

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = UserMapOverlayManager.shared

    @State private var showImporter: Bool = false
    @State private var importErrorMessage: String?
    @State private var renamingDescriptor: UserMapOverlay?
    @State private var renameDraft: String = ""

    var body: some View {
        NavigationView {
            List {
                // Add Section ---------------------------------------------
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Add KML / KMZ Overlay",
                              systemImage: "doc.badge.plus")
                    }

                    HStack {
                        Label("Add GeoPDF Overlay",
                              systemImage: "doc.richtext")
                        Spacer()
                        Text("Coming soon")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .opacity(0.55)
                } header: {
                    Text("Add Overlay")
                } footer: {
                    Text("Overlays render above the basemap and below tactical markers. GeoPDF support is in progress — see Issue #17.")
                }

                // Active Overlays Section ---------------------------------
                Section {
                    if manager.overlays.isEmpty {
                        ContentUnavailableLabel
                    } else {
                        ForEach(manager.overlays) { descriptor in
                            MapOverlayRow(
                                descriptor: descriptor,
                                onToggleVisible: { isOn in
                                    manager.setVisible(isOn, for: descriptor.id)
                                },
                                onOpacityChanged: { value in
                                    manager.setOpacity(value, for: descriptor.id)
                                },
                                onRename: {
                                    renamingDescriptor = descriptor
                                    renameDraft = descriptor.name
                                },
                                onDelete: {
                                    manager.delete(descriptor.id)
                                }
                            )
                        }
                    }
                } header: {
                    Text("Active Overlays")
                }
            }
            .navigationTitle("Map Overlays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: Self.allowedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert("Import failed",
                   isPresented: Binding(
                       get: { importErrorMessage != nil },
                       set: { if !$0 { importErrorMessage = nil } }
                   )
            ) {
                Button("OK", role: .cancel) { importErrorMessage = nil }
            } message: {
                Text(importErrorMessage ?? "")
            }
            .alert("Rename Overlay",
                   isPresented: Binding(
                       get: { renamingDescriptor != nil },
                       set: { if !$0 { renamingDescriptor = nil } }
                   )
            ) {
                TextField("Name", text: $renameDraft)
                Button("Save") {
                    if let id = renamingDescriptor?.id {
                        manager.rename(id, to: renameDraft)
                    }
                    renamingDescriptor = nil
                }
                Button("Cancel", role: .cancel) {
                    renamingDescriptor = nil
                }
            }
        }
    }

    private var ContentUnavailableLabel: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No overlays imported")
                .font(.subheadline)
            Text("KML and KMZ files appear here.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// Allowed file types for the .fileImporter. We list KML/KMZ today;
    /// GeoPDF intentionally excluded — its row in the UI is "Coming soon"
    /// and shouldn't even surface in the picker.
    private static var allowedContentTypes: [UTType] {
        var types: [UTType] = []
        if let kml = UTType(filenameExtension: "kml") { types.append(kml) }
        if let kmz = UTType(filenameExtension: "kmz") { types.append(kmz) }
        // Fallback: allow generic XML so misnamed CalTopo exports still work.
        types.append(.xml)
        return types
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    try await manager.importFile(from: url)
                } catch {
                    await MainActor.run {
                        importErrorMessage = error.localizedDescription
                    }
                }
            }
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }
}

// MARK: - MapOverlayRow

private struct MapOverlayRow: View {

    let descriptor: UserMapOverlay
    let onToggleVisible: (Bool) -> Void
    let onOpacityChanged: (Double) -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var localOpacity: Double
    @State private var localVisible: Bool

    init(descriptor: UserMapOverlay,
         onToggleVisible: @escaping (Bool) -> Void,
         onOpacityChanged: @escaping (Double) -> Void,
         onRename: @escaping () -> Void,
         onDelete: @escaping () -> Void) {
        self.descriptor = descriptor
        self.onToggleVisible = onToggleVisible
        self.onOpacityChanged = onOpacityChanged
        self.onRename = onRename
        self.onDelete = onDelete
        _localOpacity = State(initialValue: descriptor.opacity)
        _localVisible = State(initialValue: descriptor.isVisible)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: descriptor.kind.systemImage)
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading) {
                    Text(descriptor.name)
                        .font(.body)
                    Text(descriptor.kind.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $localVisible)
                    .labelsHidden()
                    .onChange(of: localVisible) { newValue in
                        onToggleVisible(newValue)
                    }
            }

            HStack {
                Image(systemName: "circle.lefthalf.filled")
                    .foregroundColor(.secondary)
                Slider(value: $localOpacity, in: 0.0 ... 1.0) { editing in
                    if !editing { onOpacityChanged(localOpacity) }
                }
                Text("\(Int(localOpacity * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
            .opacity(localVisible ? 1.0 : 0.4)
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            Button(action: onRename) {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
    }
}

#Preview {
    MapOverlaysListView()
}
