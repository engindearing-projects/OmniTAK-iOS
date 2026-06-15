//
//  PointMarkerEditView.swift
//  OmniTAKMobile
//
//  Edit form for PointMarker — invoked from the radial menu Edit action.
//

import SwiftUI
import CoreLocation

struct PointMarkerEditView: View {
    @ObservedObject var pointDropperService: PointDropperService
    let markerID: UUID
    @Binding var isPresented: Bool

    @State private var editedName: String = ""
    @State private var editedAffiliation: MarkerAffiliation = .hostile
    @State private var editedRemarks: String = ""
    @State private var editedAltitude: String = ""
    @State private var editedHeading: String = ""
    @State private var editedBroadcast: Bool = false

    // Issue #67 — icon pack override fields, mirroring PointMarker.
    @State private var editedTakIcon: TAKSpotIcon? = nil
    @State private var editedMarkersIcon: TAKMarkersIcon? = nil
    @State private var editedGoogleIcon: TAKGoogleIcon? = nil
    @State private var editedFemaIcon: FemaIcon? = nil
    @State private var showIconPicker: Bool = false

    var body: some View {
        NavigationView {
            Form {
                Section("MARKER") {
                    HStack {
                        Text("Name")
                        Spacer()
                        TextField("Marker Name", text: $editedName)
                            .multilineTextAlignment(.trailing)
                    }

                    Picker("Affiliation", selection: $editedAffiliation) {
                        ForEach(MarkerAffiliation.allCases, id: \.self) { affiliation in
                            Label(affiliation.displayName, systemImage: affiliation.iconName)
                                .tag(affiliation)
                        }
                    }
                }

                // Issue #67 — icon picker row
                Section("ICON") {
                    Button(action: { showIconPicker = true }) {
                        HStack {
                            Text("Icon")
                                .foregroundColor(.primary)
                            Spacer()
                            if let takIcon = editedTakIcon {
                                Circle()
                                    .fill(takIcon.color)
                                    .frame(width: 18, height: 18)
                                Text(takIcon.displayName)
                                    .foregroundColor(.secondary)
                            } else if let markersIcon = editedMarkersIcon {
                                Text(markersIcon.displayName)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            } else if let googleIcon = editedGoogleIcon {
                                Text(googleIcon.token)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            } else if let femaIcon = editedFemaIcon {
                                Image(systemName: femaIcon.sfSymbolName)
                                    .foregroundColor(femaIcon.tintColor)
                            } else {
                                Image(systemName: editedAffiliation.iconName)
                                    .foregroundColor(editedAffiliation.color)
                                Text("Affiliation default")
                                    .foregroundColor(.secondary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13))
                                .foregroundColor(.gray)
                        }
                    }
                }

                Section("DETAILS") {
                    HStack {
                        Text("Altitude (m)")
                        Spacer()
                        TextField("Optional", text: $editedAltitude)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }

                    // Issue #68 — heading field
                    HStack {
                        Text("Heading (°)")
                        Spacer()
                        TextField("0–360", text: $editedHeading)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Remarks")
                        TextEditor(text: $editedRemarks)
                            .frame(minHeight: 80)
                    }
                }

                Section("SHARING") {
                    Toggle("Broadcast to TAK Server", isOn: $editedBroadcast)
                }

                if let marker = currentMarker {
                    Section("LOCATION") {
                        HStack {
                            Text("Coordinates")
                            Spacer()
                            Text(String(format: "%.6f, %.6f",
                                        marker.coordinate.latitude,
                                        marker.coordinate.longitude))
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Edit Marker")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                        isPresented = false
                    }
                    .disabled(editedName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
            // Issue #67 — icon picker sheet
            .sheet(isPresented: $showIconPicker) {
                MarkerIconPickerSheet(
                    affiliation: editedAffiliation,
                    selectedTakIcon: $editedTakIcon,
                    selectedMarkersIcon: $editedMarkersIcon,
                    selectedGoogleIcon: $editedGoogleIcon,
                    selectedFemaIcon: $editedFemaIcon
                )
            }
        }
    }

    private var currentMarker: PointMarker? {
        pointDropperService.markers.first(where: { $0.id == markerID })
    }

    private func load() {
        guard let marker = currentMarker else { return }
        editedName = marker.name
        editedAffiliation = marker.affiliation
        editedRemarks = marker.remarks ?? ""
        editedAltitude = marker.altitude.map { String(format: "%.1f", $0) } ?? ""
        editedHeading = marker.heading.map { String(format: "%.1f", $0) } ?? ""
        editedBroadcast = marker.isBroadcast
        // Load icon pack override state
        editedTakIcon = marker.takIcon
        editedMarkersIcon = marker.markersIcon
        editedGoogleIcon = marker.googleIcon
        editedFemaIcon = marker.femaIcon
    }

    private func save() {
        guard var marker = currentMarker else { return }
        marker.name = editedName.trimmingCharacters(in: .whitespaces)
        marker.affiliation = editedAffiliation
        marker.remarks = editedRemarks.isEmpty ? nil : editedRemarks
        marker.altitude = Double(editedAltitude.trimmingCharacters(in: .whitespaces))
        marker.isBroadcast = editedBroadcast

        // Issue #68 — persist heading (nil when field is empty or invalid)
        let headingStr = editedHeading.trimmingCharacters(in: .whitespaces)
        if let h = Double(headingStr), h >= 0, h <= 360 {
            marker.heading = h
        } else {
            marker.heading = nil
        }

        // Issue #67 — apply icon pack override with same precedence as init().
        marker.takIcon = editedTakIcon
        marker.markersIcon = editedMarkersIcon
        marker.googleIcon = editedGoogleIcon
        marker.femaIcon = editedFemaIcon
        // Recalculate cotType + iconName to mirror PointMarker.init precedence.
        marker.cotType = editedTakIcon.map { _ in TAKSpotIcon.cotType }
            ?? editedMarkersIcon?.cotType
            ?? editedGoogleIcon?.cotType
            ?? editedFemaIcon?.cotType
            ?? editedAffiliation.cotType
        marker.iconName = editedFemaIcon?.sfSymbolName
            ?? editedGoogleIcon?.symbolName
            ?? editedAffiliation.iconName

        pointDropperService.updateMarker(marker)
    }
}

// MARK: - Icon Picker Sheet (Issue #67)

/// Modal sheet that lets the user pick a new icon pack for an existing marker.
/// Mirrors the icon selection UI in PointDropperView but presented as a sheet
/// so the full-screen map is never compressed.
private struct MarkerIconPickerSheet: View {
    let affiliation: MarkerAffiliation
    @Binding var selectedTakIcon: TAKSpotIcon?
    @Binding var selectedMarkersIcon: TAKMarkersIcon?
    @Binding var selectedGoogleIcon: TAKGoogleIcon?
    @Binding var selectedFemaIcon: FemaIcon?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: IconPackTab = .spot

    enum IconPackTab: String, CaseIterable, Identifiable {
        case spot = "Spot"
        case markers = "Markers"
        case google = "Google"
        case fema = "FEMA"
        case affiliation = "Default"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("Icon Pack", selection: $selectedTab) {
                    ForEach(IconPackTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                ScrollView {
                    switch selectedTab {
                    case .spot:
                        spotGrid
                    case .markers:
                        markersGrid
                    case .google:
                        googleGrid
                    case .fema:
                        femaGrid
                    case .affiliation:
                        affiliationDefault
                    }
                }
            }
            .navigationTitle("Choose Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Spot Map grid

    private var spotGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 16) {
            ForEach(TAKSpotIcon.allCases, id: \.self) { icon in
                Button(action: {
                    selectedTakIcon = icon
                    selectedMarkersIcon = nil
                    selectedGoogleIcon = nil
                    selectedFemaIcon = nil
                }) {
                    VStack(spacing: 6) {
                        Circle()
                            .fill(icon.color)
                            .frame(width: 36, height: 36)
                            .overlay(
                                selectedTakIcon == icon
                                    ? Circle().stroke(Color.accentColor, lineWidth: 2)
                                    : nil
                            )
                        Text(icon.displayName)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    // MARK: TAK Markers (2525C) grid

    private var markersGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 16) {
            ForEach(TAKMarkersIcon.allCases, id: \.self) { icon in
                Button(action: {
                    selectedMarkersIcon = icon
                    selectedTakIcon = nil
                    selectedGoogleIcon = nil
                    selectedFemaIcon = nil
                }) {
                    VStack(spacing: 6) {
                        // TAKMarkersIcon wraps a 2525C CoT type — no SF symbol.
                        // Show a shield badge with the short code as a stand-in.
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedMarkersIcon == icon
                                      ? Color.accentColor.opacity(0.2)
                                      : Color.secondary.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Text(icon.shortName)
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(affiliation.color)
                        }
                        Text(icon.displayName)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(width: 80)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    // MARK: Google Place icon grid

    private var googleGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 16) {
            ForEach(TAKGoogleIcon.allCases, id: \.self) { icon in
                Button(action: {
                    selectedGoogleIcon = icon
                    selectedTakIcon = nil
                    selectedMarkersIcon = nil
                    selectedFemaIcon = nil
                }) {
                    VStack(spacing: 6) {
                        Image(systemName: icon.symbolName)
                            .font(.title2)
                            .foregroundColor(affiliation.color)
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedGoogleIcon == icon
                                          ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                        Text(icon.token)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(width: 80)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    // MARK: FEMA icon grid

    private var femaGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 16) {
            ForEach(FemaIcon.allCases, id: \.self) { icon in
                Button(action: {
                    selectedFemaIcon = icon
                    selectedTakIcon = nil
                    selectedMarkersIcon = nil
                    selectedGoogleIcon = nil
                }) {
                    VStack(spacing: 6) {
                        Image(systemName: icon.sfSymbolName)
                            .font(.title2)
                            .foregroundColor(icon.tintColor)
                            .frame(width: 36, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedFemaIcon == icon
                                          ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                        Text(icon.displayName)
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                    }
                    .frame(width: 80)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
    }

    // MARK: Affiliation default (clear all overrides)

    private var affiliationDefault: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 20)
            Image(systemName: affiliation.iconName)
                .font(.system(size: 48))
                .foregroundColor(affiliation.color)
            Text("Affiliation Default")
                .font(.headline)
            Text("The marker will use the standard \(affiliation.displayName) icon.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button(action: {
                selectedTakIcon = nil
                selectedMarkersIcon = nil
                selectedGoogleIcon = nil
                selectedFemaIcon = nil
                dismiss()
            }) {
                Label("Use Default", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
