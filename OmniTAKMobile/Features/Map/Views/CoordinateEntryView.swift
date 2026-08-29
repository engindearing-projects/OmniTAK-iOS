//
//  CoordinateEntryView.swift
//  OmniTAKMobile
//
//  "Go to Coordinate" — type a coordinate and jump the map there
//  (optionally dropping a marker). Supports TWD97/TM2 (Taiwan) with a
//  selectable digit-input mode (7+7 absolute vs 5+5 local grid), plus
//  MGRS and decimal Lat/Lon.
//
//  Engine-agnostic: it posts `.goToCoordinate`, which MapViewController
//  handles for both the 2D (MapLibre) and 3D (Cesium) engines.
//

import SwiftUI
import CoreLocation

struct CoordinateEntryView: View {
    @EnvironmentObject private var loc: LocalizationManager
    @Environment(\.dismiss) private var dismiss

    enum EntryFormat: String, CaseIterable, Identifiable {
        case twd97 = "TWD97"
        case mgrs = "MGRS"
        case latlon = "LAT/LON"
        var id: String { rawValue }
    }

    @State private var format: EntryFormat = .twd97
    @State private var digitMode: TWD97Converter.DigitMode = .full7

    // TWD97 fields
    @State private var easting: String = ""
    @State private var northing: String = ""
    // MGRS field
    @State private var mgrsText: String = ""
    // Lat/Lon fields
    @State private var latText: String = ""
    @State private var lonText: String = ""

    @State private var dropMarker: Bool = true

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker(loc.t("coordentry.format"), selection: $format) {
                        ForEach(EntryFormat.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)

                    if format == .twd97 {
                        Picker(loc.t("coordentry.digitmode"), selection: $digitMode) {
                            Text("7+7").tag(TWD97Converter.DigitMode.full7)
                            Text("5+5").tag(TWD97Converter.DigitMode.grid5)
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Section(header: Text(loc.t("coordentry.input"))) {
                    inputFields
                }

                Section(header: Text(loc.t("coordentry.preview"))) {
                    previewRows
                }

                Section {
                    Toggle(loc.t("coordentry.dropmarker"), isOn: $dropMarker)
                }
            }
            .navigationTitle(loc.t("coordentry.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(loc.t("common.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { submit() }) {
                        Text(loc.t("coordentry.go")).font(.body.weight(.semibold))
                    }
                    .disabled(parsedCoordinate == nil)
                }
            }
        }
    }

    // MARK: - Input fields per format

    @ViewBuilder
    private var inputFields: some View {
        switch format {
        case .twd97:
            let digits = digitMode.digits
            HStack {
                Text(loc.t("coordentry.easting"))
                    .frame(width: 90, alignment: .leading)
                    .foregroundColor(.secondary)
                TextField(String(repeating: "0", count: digits), text: $easting)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text(loc.t("coordentry.northing"))
                    .frame(width: 90, alignment: .leading)
                    .foregroundColor(.secondary)
                TextField(String(repeating: "0", count: digits), text: $northing)
                    .keyboardType(.numberPad)
                    .font(.system(.body, design: .monospaced))
            }
            if digitMode == .grid5 {
                Text(loc.t("coordentry.grid5.note"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .mgrs:
            TextField("11S MS 12345 67890", text: $mgrsText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .font(.system(.body, design: .monospaced))
        case .latlon:
            HStack {
                Text(loc.t("coordentry.lat"))
                    .frame(width: 90, alignment: .leading)
                    .foregroundColor(.secondary)
                TextField("25.0339", text: $latText)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text(loc.t("coordentry.lon"))
                    .frame(width: 90, alignment: .leading)
                    .foregroundColor(.secondary)
                TextField("121.5645", text: $lonText)
                    .keyboardType(.numbersAndPunctuation)
                    .font(.system(.body, design: .monospaced))
            }
        }
    }

    // MARK: - Live preview

    @ViewBuilder
    private var previewRows: some View {
        if let coord = parsedCoordinate {
            previewRow(loc.t("coordentry.lat"),
                       String(format: "%.6f", coord.latitude))
            previewRow(loc.t("coordentry.lon"),
                       String(format: "%.6f", coord.longitude))
            // Echo the TWD97 readback so Gavin can compare 7+7 vs 5+5.
            if TWD97Converter.isWithinBounds(coord) {
                previewRow("TWD97 7+7", TWD97Converter.formatTWD97(coord, mode: .full7), small: true)
                previewRow("TWD97 5+5", TWD97Converter.formatTWD97(coord, mode: .grid5), small: true)
            }
        } else if hasAnyInput {
            Text(loc.t("coordentry.invalid"))
                .font(.caption)
                .foregroundColor(.red)
        } else {
            Text(loc.t("coordentry.enterprompt"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// iOS 15-compatible label/value row (LabeledContent is iOS 16+).
    private func previewRow(_ label: String, _ value: String, small: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(small ? .caption : .body)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(small ? .caption : .body, design: .monospaced))
                .foregroundColor(small ? .secondary : .primary)
        }
    }

    private var hasAnyInput: Bool {
        switch format {
        case .twd97: return !easting.isEmpty || !northing.isEmpty
        case .mgrs: return !mgrsText.isEmpty
        case .latlon: return !latText.isEmpty || !lonText.isEmpty
        }
    }

    // MARK: - Parsing

    private var parsedCoordinate: CLLocationCoordinate2D? {
        switch format {
        case .twd97:
            guard !easting.isEmpty, !northing.isEmpty else { return nil }
            return TWD97Converter.parse(
                eastingText: easting,
                northingText: northing,
                mode: digitMode,
                reference: currentMapCenter
            )
        case .mgrs:
            guard !mgrsText.isEmpty else { return nil }
            return MGRSConverter.mgrsToLatLon(mgrsText)
        case .latlon:
            guard let lat = Double(latText.trimmingCharacters(in: .whitespaces)),
                  let lon = Double(lonText.trimmingCharacters(in: .whitespaces)),
                  lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }

    /// Best-known current map centre (used to recover the 100 km cell for
    /// 5+5 grid input). Falls back to central Taiwan.
    private var currentMapCenter: CLLocationCoordinate2D {
        if let c = MapCenterStore.shared.center, CLLocationCoordinate2DIsValid(c) {
            return c
        }
        return CLLocationCoordinate2D(latitude: 23.7, longitude: 121.0)
    }

    // MARK: - Submit

    private func submit() {
        guard let coord = parsedCoordinate else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        NotificationCenter.default.post(
            name: .goToCoordinate,
            object: nil,
            userInfo: [
                "lat": coord.latitude,
                "lon": coord.longitude,
                "drop": dropMarker
            ]
        )
        dismiss()
    }
}

extension Notification.Name {
    /// Center the map on a typed coordinate (both engines). userInfo:
    /// "lat": Double, "lon": Double, "drop": Bool (drop a marker too).
    static let goToCoordinate = Notification.Name("goToCoordinate")
}
