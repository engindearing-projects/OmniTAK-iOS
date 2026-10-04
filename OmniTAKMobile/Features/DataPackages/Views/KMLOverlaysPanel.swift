//
//  KMLOverlaysPanel.swift
//  OmniTAKMobile
//
//  "Map Overlays" manager — full CRUD over imported KML/KMZ vector overlays.
//  Backed by KMLVectorOverlayStore (single GeoJSONSource per overlay), so even
//  a 50,000-feature import lists, edits, and renders without the per-feature
//  annotation crash.
//
//  Create: import KML/KMZ.   Read: list + per-overlay detail/metadata.
//  Update: rename, recolor, opacity, line width, visibility, zoom-to-fit.
//  Delete: per-overlay (with confirm) + delete-all.
//

import SwiftUI
import UniformTypeIdentifiers

struct KMLOverlaysPanel: View {
    @ObservedObject private var store = KMLVectorOverlayStore.shared
    @ObservedObject private var rasterStore = RasterOverlayStore.shared
    @ObservedObject private var mbtilesStore = MBTilesOverlayStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var showDeleteAll = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import KML / KMZ / GeoTIFF / GeoPDF / MBTiles / GPKG", systemImage: "square.and.arrow.down")
                    }
                    if store.isImporting {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(store.importStatus.isEmpty ? "Importing…" : store.importStatus)
                                .font(.footnote).foregroundColor(.secondary)
                        }
                    }
                    if let err = store.lastError {
                        Text(err).font(.footnote).foregroundColor(.red)
                    }
                    // MBTiles / GeoPackage import and registry errors live on
                    // their own store; without this they were never shown.
                    if let err = mbtilesStore.lastError {
                        Text(err).font(.footnote).foregroundColor(.red)
                    }
                } footer: {
                    Text("Imported overlays render as a single GPU vector layer — large files (tens of thousands of features) stay smooth. Tap an overlay to rename, recolor, or restyle it. Overlays show on the 2D map engine.")
                }

                if store.overlays.isEmpty && rasterStore.overlays.isEmpty && mbtilesStore.overlays.isEmpty {
                    Section {
                        Text("No overlays yet. Import a KML/KMZ (vector), a KMZ/GeoTIFF/GeoPDF (imagery), or an MBTiles tile set.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                } else {
                    if !store.overlays.isEmpty {
                        Section("Vector (KML)") {
                            ForEach(store.overlays) { overlay in
                                NavigationLink {
                                    KMLOverlayDetailView(overlayID: overlay.id, onRequestClose: { dismiss() })
                                } label: {
                                    row(overlay)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { store.remove(overlay.id) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button { store.setVisible(overlay.id, !overlay.visible) } label: {
                                        Label(overlay.visible ? "Hide" : "Show",
                                              systemImage: overlay.visible ? "eye.slash" : "eye")
                                    }.tint(.indigo)
                                }
                            }
                        }
                    }

                    if !rasterStore.overlays.isEmpty {
                        Section("Imagery") {
                            ForEach(rasterStore.overlays) { overlay in
                                NavigationLink {
                                    RasterOverlayDetailView(overlayID: overlay.id, onRequestClose: { dismiss() })
                                } label: {
                                    rasterRow(overlay)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { rasterStore.remove(overlay.id) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button { rasterStore.setVisible(overlay.id, !overlay.visible) } label: {
                                        Label(overlay.visible ? "Hide" : "Show", systemImage: overlay.visible ? "eye.slash" : "eye")
                                    }.tint(.indigo)
                                }
                            }
                        }
                    }

                    if !mbtilesStore.overlays.isEmpty {
                        Section("Tiles (MBTiles)") {
                            ForEach(mbtilesStore.overlays) { overlay in
                                NavigationLink {
                                    MBTilesOverlayDetailView(overlayID: overlay.id, onRequestClose: { dismiss() })
                                } label: {
                                    mbtilesRow(overlay)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { mbtilesStore.remove(overlay.id) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .leading) {
                                    Button { mbtilesStore.setVisible(overlay.id, !overlay.visible) } label: {
                                        Label(overlay.visible ? "Hide" : "Show", systemImage: overlay.visible ? "eye.slash" : "eye")
                                    }.tint(.indigo)
                                }
                            }
                        }
                    }

                    Section {
                        Button(role: .destructive) { showDeleteAll = true } label: {
                            Label("Delete All Overlays", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Map Overlays")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // A tile file can be deleted (or put back) from the Files app
            // while OmniTAK runs; re-check so the rows tell the truth.
            .onAppear { mbtilesStore.refreshFileState() }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: allowedTypes, allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { importPicked(url) }
            }
            .confirmationDialog("Delete all overlays?", isPresented: $showDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { store.removeAll(); rasterStore.removeAll(); mbtilesStore.removeAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every imported overlay (vector and imagery). It can't be undone.")
            }
        }
    }

    private var allowedTypes: [UTType] {
        var types: [UTType] = []
        for ext in ["kml", "kmz", "tif", "tiff", "pdf", "mbtiles", "gpkg"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types.isEmpty ? [.data] : types
    }

    private func importPicked(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let isTileSet = ext == "mbtiles" || ext == "gpkg"
        // A new import starts with a clean slate; each store only clears its
        // own error, so an old one from another store would otherwise stay up.
        store.lastError = nil
        mbtilesStore.lastError = nil
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            // Show the failure on the store the import belongs to. The reason
            // is included for tile sets: they are large, so "no space left on
            // device" is a likely one.
            if isTileSet {
                mbtilesStore.lastError = "Couldn't read the selected file: \(error.localizedDescription)"
            } else {
                store.lastError = "Couldn't read the selected file."
            }
            return
        }
        Task {
            func frame(_ id: String?) {
                if let id = id {
                    NotificationCenter.default.post(name: .kmlZoomToOverlay, object: nil, userInfo: ["id": id])
                }
            }
            if ext == "mbtiles" {
                // MBTiles raster tile pyramid.
                if await mbtilesStore.importMBTiles(from: tmp) { frame(mbtilesStore.overlays.last?.id) }
            } else if ext == "gpkg" {
                // GeoPackage raster tiles.
                if await mbtilesStore.importGPKG(from: tmp) { frame(mbtilesStore.overlays.last?.id) }
            } else if ext == "tif" || ext == "tiff" || ext == "gtiff" {
                // GeoTIFF imagery.
                if await rasterStore.importGeoTIFF(from: tmp) { frame(rasterStore.overlays.last?.id) }
            } else if ext == "pdf" {
                // GeoPDF imagery.
                if await rasterStore.importGeoPDF(from: tmp) { frame(rasterStore.overlays.last?.id) }
            } else if await rasterStore.importGroundOverlay(from: tmp) {
                // KMZ/KML GroundOverlay imagery.
                frame(rasterStore.overlays.last?.id)
            } else {
                // Vector KML/KMZ.
                await store.importKML(from: tmp)
                frame(store.overlays.last?.id)
            }
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    @ViewBuilder
    private func rasterRow(_ overlay: RasterOverlay) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle.angled")
                .foregroundColor(.teal)
                .opacity(overlay.visible ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 2) {
                Text(overlay.name).lineLimit(1)
                Text("Image overlay · \(Int(overlay.opacity * 100))%")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                rasterStore.setVisible(overlay.id, !overlay.visible)
            } label: {
                Image(systemName: overlay.visible ? "eye.fill" : "eye.slash")
                    .foregroundColor(overlay.visible ? .accentColor : .secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func mbtilesRow(_ overlay: MBTilesOverlay) -> some View {
        HStack(spacing: 12) {
            if overlay.fileMissing {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red)
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundColor(.orange)
                    .opacity(overlay.visible ? 1 : 0.35)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(overlay.name).lineLimit(1)
                if overlay.fileMissing {
                    Text("File missing - delete this entry, then import the file again")
                        .font(.caption).foregroundColor(.red)
                } else {
                    Text("Tiles z\(overlay.minZoom)–\(overlay.maxZoom) · \(Int(overlay.opacity * 100))%")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            Spacer()
            if overlay.fileMissing {
                // The entry has nothing left to show or hide; the one useful
                // action is getting rid of it. Borderless so it fires on its
                // own inside the NavigationLink row.
                Button {
                    mbtilesStore.remove(overlay.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete")
            } else {
                Button {
                    mbtilesStore.setVisible(overlay.id, !overlay.visible)
                } label: {
                    Image(systemName: overlay.visible ? "eye.fill" : "eye.slash")
                        .foregroundColor(overlay.visible ? .accentColor : .secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder
    private func row(_ overlay: KMLVectorOverlay) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(hex: overlay.colorHex))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(Color.white.opacity(0.4), lineWidth: 0.5))
                .opacity(overlay.visible ? 1 : 0.35)
            VStack(alignment: .leading, spacing: 2) {
                Text(overlay.name).lineLimit(1)
                Text("\(overlay.featureCount) features")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            // Tap to enable/disable the overlay without opening the editor.
            // Borderless so it's independently tappable inside the row's
            // NavigationLink (tapping the row still opens the editor).
            Button {
                store.setVisible(overlay.id, !overlay.visible)
            } label: {
                Image(systemName: overlay.visible ? "eye.fill" : "eye.slash")
                    .foregroundColor(overlay.visible ? .accentColor : .secondary)
                    .font(.body)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
    }
}

// MARK: - Per-overlay editor (full CRUD: rename / recolor / restyle / delete)

struct KMLOverlayDetailView: View {
    @ObservedObject private var store = KMLVectorOverlayStore.shared
    let overlayID: String
    /// Closes the entire Map Overlays sheet (not just this detail view) so the
    /// map is visible after a zoom-to. Provided by the parent panel.
    var onRequestClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var nameField = ""
    @State private var showDelete = false

    private static let palette = [
        "#A78BFA", "#5AC8FA", "#34C759", "#FF9F0A", "#FF375F",
        "#FFD60A", "#0A84FF", "#FF453A", "#30D158", "#FFFFFF",
    ]

    private var overlay: KMLVectorOverlay? { store.overlays.first { $0.id == overlayID } }

    var body: some View {
        Form {
            if let o = overlay {
                Section("Name") {
                    TextField("Overlay name", text: $nameField)
                        .onSubmit { store.rename(o.id, to: nameField) }
                        .submitLabel(.done)
                }

                Section("Appearance") {
                    Toggle("Visible", isOn: Binding(get: { o.visible }, set: { store.setVisible(o.id, $0) }))

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Color").font(.subheadline)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                            ForEach(Self.palette, id: \.self) { hex in
                                Circle()
                                    .fill(Color(hex: hex))
                                    .frame(width: 30, height: 30)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: o.colorHex.uppercased() == hex ? 3 : 0))
                                    .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 0.5))
                                    .onTapGesture { store.setColor(o.id, hex: hex) }
                            }
                        }
                        ColorPicker("Custom color", selection: Binding(
                            get: { Color(hex: o.colorHex) },
                            set: { store.setColor(o.id, hex: hexString(from: $0)) }
                        ))
                    }

                    VStack(alignment: .leading) {
                        Text("Opacity — \(Int(o.opacity * 100))%").font(.subheadline)
                        Slider(value: Binding(get: { o.opacity }, set: { store.setOpacity(o.id, $0) }), in: 0.05...1.0)
                    }

                    VStack(alignment: .leading) {
                        Text(String(format: "Line width — %.1f×", o.lineWidth)).font(.subheadline)
                        Slider(value: Binding(get: { o.lineWidth }, set: { store.setLineWidth(o.id, $0) }), in: 0.5...6.0)
                    }
                }

                Section("Info") {
                    infoRow("Features", "\(o.featureCount)")
                    infoRow("Imported", o.createdAt.formatted(date: .abbreviated, time: .shortened))
                    infoRow("Bounds", String(format: "%.3f, %.3f → %.3f, %.3f", o.minLat, o.minLon, o.maxLat, o.maxLon))
                    Button {
                        NotificationCenter.default.post(name: .kmlZoomToOverlay, object: nil, userInfo: ["id": o.id])
                        // Close the whole sheet (not just pop this view) so the
                        // map — now flying to the overlay — is actually visible.
                        onRequestClose()
                    } label: {
                        Label("Zoom to overlay", systemImage: "scope")
                    }
                }

                Section {
                    Button(role: .destructive) { showDelete = true } label: {
                        Label("Delete overlay", systemImage: "trash")
                    }
                }
            } else {
                Text("Overlay removed.").foregroundColor(.secondary)
            }
        }
        .navigationTitle(overlay?.name ?? "Overlay")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nameField = overlay?.name ?? "" }
        .onDisappear { if let o = overlay, nameField != o.name { store.rename(o.id, to: nameField) } }
        .confirmationDialog("Delete this overlay?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.remove(overlayID); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.footnote)
    }

    private func hexString(from color: Color) -> String {
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Imagery (raster image) editor

struct RasterOverlayDetailView: View {
    @ObservedObject private var store = RasterOverlayStore.shared
    let overlayID: String
    var onRequestClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var nameField = ""
    @State private var showDelete = false

    private var overlay: RasterOverlay? { store.overlays.first { $0.id == overlayID } }

    var body: some View {
        Form {
            if let o = overlay {
                Section("Name") {
                    TextField("Overlay name", text: $nameField).submitLabel(.done)
                        .onSubmit { store.rename(o.id, to: nameField) }
                }
                Section("Appearance") {
                    Toggle("Visible", isOn: Binding(get: { o.visible }, set: { store.setVisible(o.id, $0) }))
                    VStack(alignment: .leading) {
                        Text("Opacity — \(Int(o.opacity * 100))%").font(.subheadline)
                        Slider(value: Binding(get: { o.opacity }, set: { store.setOpacity(o.id, $0) }), in: 0.05...1.0)
                    }
                }
                Section("Info") {
                    infoRow("Imported", o.createdAt.formatted(date: .abbreviated, time: .shortened))
                    infoRow("Bounds", String(format: "%.3f, %.3f → %.3f, %.3f", o.south, o.west, o.north, o.east))
                    Button {
                        NotificationCenter.default.post(name: .kmlZoomToOverlay, object: nil, userInfo: ["id": o.id])
                        onRequestClose()
                    } label: { Label("Zoom to overlay", systemImage: "scope") }
                }
                Section {
                    Button(role: .destructive) { showDelete = true } label: { Label("Delete overlay", systemImage: "trash") }
                }
            } else { Text("Overlay removed.").foregroundColor(.secondary) }
        }
        .navigationTitle(overlay?.name ?? "Imagery")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nameField = overlay?.name ?? "" }
        .onDisappear { if let o = overlay, nameField != o.name { store.rename(o.id, to: nameField) } }
        .confirmationDialog("Delete this overlay?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.remove(overlayID); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private func infoRow(_ l: String, _ v: String) -> some View {
        HStack { Text(l).foregroundColor(.secondary); Spacer(); Text(v).multilineTextAlignment(.trailing) }.font(.footnote)
    }
}

// MARK: - MBTiles editor

struct MBTilesOverlayDetailView: View {
    @ObservedObject private var store = MBTilesOverlayStore.shared
    let overlayID: String
    var onRequestClose: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var nameField = ""
    @State private var showDelete = false

    private var overlay: MBTilesOverlay? { store.overlays.first { $0.id == overlayID } }

    var body: some View {
        Form {
            if let o = overlay {
                Section("Name") {
                    TextField("Tile set name", text: $nameField).submitLabel(.done)
                        .onSubmit { store.rename(o.id, to: nameField) }
                }
                if o.fileMissing {
                    Section("Status") {
                        Label("File missing", systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("The tile file for this entry is no longer on this device, so there is nothing to draw. Delete the entry, then import the file again.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                } else {
                    Section("Appearance") {
                        Toggle("Visible", isOn: Binding(get: { o.visible }, set: { store.setVisible(o.id, $0) }))
                        VStack(alignment: .leading) {
                            Text("Opacity — \(Int(o.opacity * 100))%").font(.subheadline)
                            Slider(value: Binding(get: { o.opacity }, set: { store.setOpacity(o.id, $0) }), in: 0.05...1.0)
                        }
                    }
                }
                Section("Info") {
                    infoRow("Zoom", "z\(o.minZoom)–\(o.maxZoom)")
                    if o.hasBounds && !o.fileMissing {
                        infoRow("Bounds", String(format: "%.3f, %.3f → %.3f, %.3f", o.south, o.west, o.north, o.east))
                        Button {
                            NotificationCenter.default.post(name: .kmlZoomToOverlay, object: nil, userInfo: ["id": o.id])
                            onRequestClose()
                        } label: { Label("Zoom to tiles", systemImage: "scope") }
                    }
                }
                Section {
                    Button(role: .destructive) { showDelete = true } label: { Label("Delete tile set", systemImage: "trash") }
                }
            } else { Text("Tile set removed.").foregroundColor(.secondary) }
        }
        .navigationTitle(overlay?.name ?? "MBTiles")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nameField = overlay?.name ?? "" }
        .onDisappear { if let o = overlay, nameField != o.name { store.rename(o.id, to: nameField) } }
        .confirmationDialog("Delete this tile set?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.remove(overlayID); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private func infoRow(_ l: String, _ v: String) -> some View {
        HStack { Text(l).foregroundColor(.secondary); Spacer(); Text(v).multilineTextAlignment(.trailing) }.font(.footnote)
    }
}

extension Notification.Name {
    /// Posted by KMLOverlaysPanel to ask the map to frame an overlay's
    /// bounds (and switch to the 2D engine, where overlays render).
    static let kmlZoomToOverlay = Notification.Name("kmlZoomToOverlay")
}
