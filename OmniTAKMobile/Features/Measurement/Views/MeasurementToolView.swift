//
//  MeasurementToolView.swift
//  OmniTAKMobile
//
//  ATAK-style compact measurement overlay that doesn't block map interaction
//

import SwiftUI
import CoreLocation

// MARK: - Compact Measurement Overlay

struct CompactMeasurementOverlay: View {
    @ObservedObject var manager: MeasurementManager
    @Binding var isPresented: Bool
    @State private var showToolPicker = false
    @State private var showResults = true
    @State private var showRangeRingConfig = false

    var body: some View {
        ZStack {
            // Tool Picker (shown at start)
            if showToolPicker && !manager.isActive {
                toolPickerOverlay
            }

            // Active measurement toolbar (top of screen)
            if manager.isActive {
                VStack {
                    activeToolbar
                    Spacer()
                }
            }

            // Live results (compact, top-right)
            if manager.isActive && showResults && hasResults {
                VStack {
                    HStack {
                        Spacer()
                        liveResultsPanel
                            .padding(.trailing, 16)
                    }
                    Spacer()
                }
                .padding(.top, 80) // Below toolbar
            }
        }
        .onAppear {
            showToolPicker = !manager.isActive
        }
        .onChange(of: manager.isActive) { active in
            if active {
                showToolPicker = false
            }
        }
        .sheet(isPresented: $showRangeRingConfig) {
            RangeRingConfigView(manager: manager)
        }
    }

    // MARK: - Tool Picker Overlay

    private var toolPickerOverlay: some View {
        VStack {
            HStack {
                Spacer()

                VStack(spacing: 12) {
                    // Header
                    HStack {
                        Image(systemName: "ruler")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "#FFFC00"))

                        Text("Select Tool")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)

                        Spacer()

                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }

                    Divider()
                        .background(Color.white.opacity(0.2))

                    // Tool buttons
                    ForEach(MeasurementType.allCases, id: \.self) { type in
                        Button(action: {
                            manager.startMeasurement(type: type)
                            showToolPicker = false
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: type.icon)
                                    .font(.system(size: 18))
                                    .foregroundColor(Color(hex: "#FFFC00"))
                                    .frame(width: 30)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(type.displayName)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)

                                    Text(type.description)
                                        .font(.system(size: 11))
                                        .foregroundColor(.white.opacity(0.7))
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 12)
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(16)
                .frame(width: 280)
                .background(Color.black.opacity(0.9))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.5), radius: 12)
                .padding(.trailing, 16)
            }
            .padding(.top, 80)

            Spacer()
        }
    }

    // MARK: - Active Toolbar

    private var activeToolbar: some View {
        HStack(spacing: 12) {
            // Tool indicator
            HStack(spacing: 8) {
                Image(systemName: manager.currentMeasurementType?.icon ?? "ruler")
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "#FFFC00"))

                Text(manager.currentMeasurementType?.displayName ?? "Measure")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.8))
            .cornerRadius(8)

            Spacer()

            // Control buttons
            HStack(spacing: 8) {
                // Undo button
                if !manager.temporaryPoints.isEmpty {
                    Button(action: { manager.undoLastPoint() }) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color(hex: "#444444"))
                            .cornerRadius(8)
                    }
                }

                // Complete button
                if manager.canComplete() {
                    Button(action: { manager.completeMeasurement() }) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(Color(hex: "#1E1E1E"))
                            .frame(width: 36, height: 36)
                            .background(Color(hex: "#FFFC00"))
                            .cornerRadius(8)
                    }
                }

                // Range ring config (if applicable)
                if manager.currentMeasurementType == .rangeRing {
                    Button(action: { showRangeRingConfig = true }) {
                        Image(systemName: "gear")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "#FFFC00"))
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(8)
                    }
                }

                // Cancel button
                Button(action: {
                    manager.cancelMeasurement()
                    isPresented = false
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(Color(hex: "#FF4444"))
                        .cornerRadius(8)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color.black.opacity(0.7)
                .ignoresSafeArea(edges: .top)
        )
    }

    // MARK: - Live Results Panel

    private var liveResultsPanel: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Minimize/expand button
            HStack {
                Text(manager.currentMeasurementType?.displayName.uppercased() ?? "")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))

                Spacer()

                Button(action: { showResults.toggle() }) {
                    Image(systemName: showResults ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            if showResults {
                Divider()
                    .background(Color.white.opacity(0.2))

                // Results based on type
                if let type = manager.currentMeasurementType {
                    switch type {
                    case .distance:
                        compactDistanceResults
                    case .bearing:
                        compactBearingResults
                    case .area:
                        compactAreaResults
                    case .rangeRing:
                        compactRangeRingResults
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 180, maxWidth: 220)
        .background(Color.black.opacity(0.85))
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.4), radius: 8)
    }

    // MARK: - Compact Results

    private var compactDistanceResults: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let meters = manager.liveResult.distanceMeters {
                Text(UnitFormatter.distance(meters))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#FFFC00"))

                // Show alternate unit
                if UnitPreferences.shared.unitSystem == .metric {
                    Text(String(format: "%.2f mi", manager.liveResult.distanceMiles ?? 0))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                } else {
                    Text(String(format: "%.2f km", manager.liveResult.distanceKilometers ?? 0))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
    }

    private var compactBearingResults: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let degrees = manager.liveResult.bearingDegrees {
                Text(MeasurementCalculator.formatBearing(degrees))
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#FFFC00"))

                if let meters = manager.liveResult.distanceMeters {
                    Text(UnitFormatter.distance(meters))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
    }

    private var compactAreaResults: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let sqMeters = manager.liveResult.areaSquareMeters {
                Text(UnitFormatter.area(sqMeters))
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#FFFC00"))

                // Show alternate unit
                if UnitPreferences.shared.unitSystem == .metric {
                    Text(String(format: "%.2f ac", manager.liveResult.areaAcres ?? 0))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                } else {
                    Text(String(format: "%.2f ha", manager.liveResult.areaHectares ?? 0))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
    }

    private var compactRangeRingResults: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text("\(manager.rangeRingConfiguration.distances.count) Rings")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(hex: "#FFFC00"))

            ForEach(manager.rangeRingConfiguration.distances.prefix(3), id: \.self) { distance in
                Text(UnitFormatter.distance(distance))
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }

    // MARK: - Helper Properties

    private var hasResults: Bool {
        switch manager.currentMeasurementType {
        case .distance:
            return manager.liveResult.distanceMeters != nil
        case .bearing:
            return manager.liveResult.bearingDegrees != nil
        case .area:
            return manager.liveResult.areaSquareMeters != nil
        case .rangeRing:
            return !manager.temporaryPoints.isEmpty
        case .none:
            return false
        }
    }
}

// MARK: - Measurement Type Extension

extension MeasurementType {
    var description: String {
        switch self {
        case .distance:
            return "Tap points to measure distance"
        case .bearing:
            return "Two points for bearing & distance"
        case .area:
            return "Tap points to outline area"
        case .rangeRing:
            return "Create concentric range circles"
        }
    }
}
