//
//  DataPackageBuilderView.swift
//  OmniTAKMobile
//
//  Modal "Build data package" sheet. Lets the user pick a subset of
//  the current map state (markers / drawings / tracks), preview the
//  size estimate, and save the resulting `.zip` to Files, share via
//  the system share-sheet, or (stub) publish to a TAK server (#14).
//
//  Sheet, not a side panel — the full-screen map is sacred (per the
//  team's omnitak_fullscreen_map convention).
//
//  Closes K9Blue's SAR feedback (5/10/26): "Data packages" — today
//  the only way to seed a package is the demo-bundle deeplink.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DataPackageBuilderView: View {
    @Environment(\.dismiss) private var dismiss

    // Snapshot of map state. Same trick `SettingsView.exportMissionAsKML`
    // uses — Settings is presented over the map sheet so we pull fresh
    // state from the persistence layers rather than wiring this view
    // into the live @StateObjects.
    @StateObject private var drawingStore = DrawingStore()
    @StateObject private var trackService = TrackRecordingService()
    @StateObject private var pointDropper = PointDropperService.shared

    // Selection state
    @State private var packageName: String = DataPackageBuilderView.defaultName()
    @State private var packageDescription: String = ""
    @State private var selectedMarkerIDs: Set<String> = []
    @State private var selectedDrawingIDs: Set<String> = []
    @State private var selectedTrackIDs: Set<String> = []

    // Build output
    @State private var buildResultURL: URL?
    @State private var buildError: String?
    @State private var showShareSheet = false
    @State private var showSavedAlert = false
    @State private var isBuilding = false

    private let builder = DataPackageBuilder()

    // MARK: - Computed inputs

    /// All available markers (PointDropperService + drawing markers).
    /// We surface both kinds because both render as point features on
    /// the map and the user thinks of them as the same thing.
    private var allMarkers: [PackageMarker] {
        var out: [PackageMarker] = pointDropper.markers.map { m in
            PackageMarker(
                id: "pm-\(m.id.uuidString)",
                name: m.name,
                latitude: m.coordinate.latitude,
                longitude: m.coordinate.longitude,
                altitude: m.altitude,
                cotType: m.cotType,
                remarks: m.remarks
            )
        }
        out.append(contentsOf: drawingStore.markers.map { m in
            PackageMarker(
                id: "dm-\(m.id.uuidString)",
                name: m.name,
                latitude: m.coordinate.latitude,
                longitude: m.coordinate.longitude,
                altitude: nil,
                cotType: "a-f-G",
                remarks: nil
            )
        })
        return out
    }

    private var allDrawings: [PackageDrawing] {
        var out: [PackageDrawing] = []
        for line in drawingStore.lines {
            out.append(PackageDrawing(
                id: "line-\(line.id.uuidString)",
                name: line.name,
                kind: .line,
                color: line.color.rawValue,
                coordinates: line.coordinates.map { PackageCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            ))
        }
        for poly in drawingStore.polygons {
            out.append(PackageDrawing(
                id: "poly-\(poly.id.uuidString)",
                name: poly.name,
                kind: .polygon,
                color: poly.color.rawValue,
                coordinates: poly.coordinates.map { PackageCoordinate(latitude: $0.latitude, longitude: $0.longitude) }
            ))
        }
        for c in drawingStore.circles {
            out.append(PackageDrawing(
                id: "circle-\(c.id.uuidString)",
                name: c.name,
                kind: .circle,
                color: c.color.rawValue,
                coordinates: c.coordinates.map { PackageCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
                radius: nil
            ))
        }
        return out
    }

    private var allTracks: [PackageTrack] {
        trackService.savedTracks.map { t in
            PackageTrack(
                id: "trk-\(t.id.uuidString)",
                name: t.name,
                color: t.color,
                points: t.points.map { p in
                    PackageTrackPoint(
                        latitude: p.latitude,
                        longitude: p.longitude,
                        altitude: p.altitude,
                        timestamp: p.timestamp
                    )
                }
            )
        }
    }

    private var currentSelection: PackageSelection {
        PackageSelection(
            name: packageName.isEmpty ? DataPackageBuilderView.defaultName() : packageName,
            packageDescription: packageDescription.isEmpty ? nil : packageDescription,
            author: UserDefaults.standard.string(forKey: "userCallsign"),
            markerIDs: selectedMarkerIDs,
            drawingIDs: selectedDrawingIDs,
            trackIDs: selectedTrackIDs
        )
    }

    private var estimatedBytes: Int {
        builder.estimatedSize(
            selection: currentSelection,
            markers: allMarkers,
            drawings: allDrawings,
            tracks: allTracks
        )
    }

    // MARK: - Body

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                List {
                    Section("PACKAGE") {
                        TextField("Name", text: $packageName)
                            .autocapitalization(.words)
                        TextField("Description (optional)", text: $packageDescription)
                    }

                    markersSection
                    drawingsSection
                    tracksSection

                    Section("PREVIEW") {
                        HStack {
                            Text("Items selected")
                            Spacer()
                            Text("\(currentSelection.totalCount)")
                                .foregroundColor(.gray)
                        }
                        HStack {
                            Text("Estimated size")
                            Spacer()
                            Text(formattedBytes(estimatedBytes))
                                .foregroundColor(.gray)
                        }
                    }

                    Section {
                        Button {
                            buildAndShare()
                        } label: {
                            Label("Save to Files / Share", systemImage: "square.and.arrow.up")
                        }
                        .disabled(currentSelection.isEmpty || isBuilding)

                        Button {
                            // #14 Mission API client lands the publish
                            // endpoint. Until then we stub the action
                            // and keep the slot visible so users
                            // discover it.
                            buildError = "Publishing to TAK server lands with #14 (Mission API client). Save or share for now."
                        } label: {
                            Label("Publish to TAK server…", systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.gray)
                        }
                        .disabled(true)
                    }
                }
                .background(Color.black)
            }
            .navigationTitle("Build data package")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isBuilding {
                        ProgressView().tint(.white)
                    }
                }
            }
            .sheet(isPresented: $showShareSheet, onDismiss: cleanupBuildResult) {
                if let url = buildResultURL {
                    DataPackageShareSheet(activityItems: [url])
                }
            }
            .alert("Saved", isPresented: $showSavedAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(buildResultURL?.lastPathComponent ?? "")
            }
            .alert("Build failed", isPresented: Binding(
                get: { buildError != nil },
                set: { if !$0 { buildError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(buildError ?? "Unknown error")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var markersSection: some View {
        let markers = allMarkers
        Section {
            if markers.isEmpty {
                Text("No markers on map")
                    .foregroundColor(.gray)
                    .italic()
            } else {
                Button(action: { toggleAll(\.selectedMarkerIDs, ids: markers.map { $0.id }) }) {
                    Text(allSelected(markers.map { $0.id }, selected: selectedMarkerIDs) ? "Deselect all" : "Select all")
                        .font(.caption)
                        .foregroundColor(Color(hex: "#00C8FF"))
                }
                ForEach(markers, id: \.id) { m in
                    selectionRow(
                        title: m.name,
                        subtitle: String(format: "%.4f, %.4f", m.latitude, m.longitude),
                        isSelected: selectedMarkerIDs.contains(m.id),
                        toggle: { toggle(&selectedMarkerIDs, m.id) }
                    )
                }
            }
        } header: {
            Text("MARKERS (\(markers.count))")
        }
    }

    @ViewBuilder
    private var drawingsSection: some View {
        let drawings = allDrawings
        Section {
            if drawings.isEmpty {
                Text("No drawings on map")
                    .foregroundColor(.gray)
                    .italic()
            } else {
                Button(action: { toggleAll(\.selectedDrawingIDs, ids: drawings.map { $0.id }) }) {
                    Text(allSelected(drawings.map { $0.id }, selected: selectedDrawingIDs) ? "Deselect all" : "Select all")
                        .font(.caption)
                        .foregroundColor(Color(hex: "#00C8FF"))
                }
                ForEach(drawings, id: \.id) { d in
                    selectionRow(
                        title: d.name,
                        subtitle: "\(d.kind.rawValue.capitalized) — \(d.coordinates.count) pts",
                        isSelected: selectedDrawingIDs.contains(d.id),
                        toggle: { toggle(&selectedDrawingIDs, d.id) }
                    )
                }
            }
        } header: {
            Text("DRAWINGS (\(drawings.count))")
        }
    }

    @ViewBuilder
    private var tracksSection: some View {
        let tracks = allTracks
        Section {
            if tracks.isEmpty {
                Text("No saved tracks")
                    .foregroundColor(.gray)
                    .italic()
            } else {
                Button(action: { toggleAll(\.selectedTrackIDs, ids: tracks.map { $0.id }) }) {
                    Text(allSelected(tracks.map { $0.id }, selected: selectedTrackIDs) ? "Deselect all" : "Select all")
                        .font(.caption)
                        .foregroundColor(Color(hex: "#00C8FF"))
                }
                ForEach(tracks, id: \.id) { t in
                    selectionRow(
                        title: t.name,
                        subtitle: "\(t.points.count) points",
                        isSelected: selectedTrackIDs.contains(t.id),
                        toggle: { toggle(&selectedTrackIDs, t.id) }
                    )
                }
            }
        } header: {
            Text("TRACKS (\(tracks.count))")
        }
    }

    @ViewBuilder
    private func selectionRow(title: String, subtitle: String, isSelected: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? Color(hex: "#00C8FF") : .gray)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                Spacer()
            }
        }
    }

    // MARK: - Actions

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
    }

    private func toggleAll(_ keyPath: WritableKeyPath<DataPackageBuilderView, Set<String>>, ids: [String]) {
        // SwiftUI quirk: can't mutate self via key-path in a struct
        // view directly — branch on equality instead.
        let idSet = Set(ids)
        if keyPath == \DataPackageBuilderView.selectedMarkerIDs {
            if idSet.isSubset(of: selectedMarkerIDs) {
                selectedMarkerIDs.subtract(idSet)
            } else {
                selectedMarkerIDs.formUnion(idSet)
            }
        } else if keyPath == \DataPackageBuilderView.selectedDrawingIDs {
            if idSet.isSubset(of: selectedDrawingIDs) {
                selectedDrawingIDs.subtract(idSet)
            } else {
                selectedDrawingIDs.formUnion(idSet)
            }
        } else if keyPath == \DataPackageBuilderView.selectedTrackIDs {
            if idSet.isSubset(of: selectedTrackIDs) {
                selectedTrackIDs.subtract(idSet)
            } else {
                selectedTrackIDs.formUnion(idSet)
            }
        }
    }

    private func allSelected(_ ids: [String], selected: Set<String>) -> Bool {
        guard !ids.isEmpty else { return false }
        return Set(ids).isSubset(of: selected)
    }

    private func buildAndShare() {
        isBuilding = true
        let selection = currentSelection
        let markers = allMarkers
        let drawings = allDrawings
        let tracks = allTracks
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let safeName = selection.name
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: " ", with: "_")
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(safeName).zip")
                _ = try builder.writePackage(
                    to: url,
                    selection: selection,
                    markers: markers,
                    drawings: drawings,
                    tracks: tracks
                )
                DispatchQueue.main.async {
                    self.buildResultURL = url
                    self.isBuilding = false
                    self.showShareSheet = true
                }
            } catch {
                DispatchQueue.main.async {
                    self.buildError = error.localizedDescription
                    self.isBuilding = false
                }
            }
        }
    }

    private func cleanupBuildResult() {
        if let url = buildResultURL {
            try? FileManager.default.removeItem(at: url)
            buildResultURL = nil
        }
    }

    // MARK: - Helpers

    private func formattedBytes(_ count: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB]
        return f.string(fromByteCount: Int64(count))
    }

    private static func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return "OmniTAK_Package_\(f.string(from: Date()))"
    }
}

// MARK: - Share-sheet wrapper

private struct DataPackageShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
