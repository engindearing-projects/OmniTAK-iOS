//
//  SelfPositionEditSheet.swift
//  OmniTAKMobile
//
//  Issue #65 — Modal sheet that lets the operator manually override their
//  self-position (disabling GPS for CoT broadcast) or return to GPS tracking.
//

import SwiftUI
import CoreLocation

/// Sheet for manually repositioning the self-position marker.
///
/// When the operator enters a lat/lon and taps "Set Manual Position", the
/// `PositionBroadcastService` stops reading from GPS and uses the entered
/// coordinate for all subsequent CoT SA broadcasts (both auto-PPLI and user-
/// triggered PLI). Tapping "Return to GPS" clears the override.
struct SelfPositionEditSheet: View {
    let locationManager: LocationManager
    @Binding var isPresented: Bool

    @ObservedObject private var pbs = PositionBroadcastService.shared

    @State private var latText: String = ""
    @State private var lonText: String = ""
    @State private var validationError: String? = nil

    private var currentGPS: CLLocationCoordinate2D? {
        locationManager.location?.coordinate
    }

    var body: some View {
        NavigationView {
            Form {
                // Status banner
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: pbs.isManualPositionActive
                              ? "location.slash.fill"
                              : "location.fill")
                            .foregroundColor(pbs.isManualPositionActive ? .orange : .green)
                            .font(.title2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(pbs.isManualPositionActive
                                 ? "Manual Position Active"
                                 : "GPS Active")
                                .font(.headline)

                            if pbs.isManualPositionActive, let pos = pbs.manualPosition {
                                Text(String(format: "%.6f, %.6f",
                                            pos.latitude, pos.longitude))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            } else if let gps = currentGPS {
                                Text(String(format: "%.6f, %.6f",
                                            gps.latitude, gps.longitude))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Manual coordinate entry
                Section("SET MANUAL POSITION") {
                    HStack {
                        Text("Latitude")
                        Spacer()
                        TextField("e.g. 38.8951", text: $latText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Text("Longitude")
                        Spacer()
                        TextField("e.g. -77.0364", text: $lonText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }

                    if let error = validationError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Button(action: applyManualPosition) {
                        Label("Set Manual Position", systemImage: "mappin.and.ellipse")
                    }
                    .disabled(latText.trimmingCharacters(in: .whitespaces).isEmpty ||
                              lonText.trimmingCharacters(in: .whitespaces).isEmpty)

                    // Prefill from current GPS to make editing the position easy.
                    if let gps = currentGPS {
                        Button(action: {
                            latText = String(format: "%.6f", gps.latitude)
                            lonText = String(format: "%.6f", gps.longitude)
                        }) {
                            Label("Prefill from GPS", systemImage: "location.circle")
                        }
                        .foregroundColor(.blue)
                    }
                }

                // Return to GPS
                if pbs.isManualPositionActive {
                    Section {
                        Button(action: returnToGPS) {
                            Label("Return to GPS", systemImage: "location.fill")
                                .foregroundColor(.green)
                        }
                    }
                }

                // Info footer
                Section {
                    Text("When a manual position is set, all CoT SA broadcasts use the entered coordinate instead of GPS. The puck on the map still shows your actual GPS position.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Self Position")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }

    private func applyManualPosition() {
        validationError = nil
        let latStr = latText.trimmingCharacters(in: .whitespaces)
        let lonStr = lonText.trimmingCharacters(in: .whitespaces)

        guard let lat = Double(latStr), lat >= -90, lat <= 90 else {
            validationError = "Latitude must be a number between -90 and 90."
            return
        }
        guard let lon = Double(lonStr), lon >= -180, lon <= 180 else {
            validationError = "Longitude must be a number between -180 and 180."
            return
        }

        pbs.manualPosition = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        pbs.isManualPositionActive = true
        isPresented = false
    }

    private func returnToGPS() {
        pbs.isManualPositionActive = false
        isPresented = false
    }
}
