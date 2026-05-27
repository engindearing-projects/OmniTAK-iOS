//
//  SettingsView.swift
//  OmniTAKMobile
//
//  App settings and preferences
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject private var loc: LocalizationManager
    @AppStorage("userCallsign") private var userCallsign = "ALPHA-1"
    @AppStorage("userName") private var userName = "Operator"
    @AppStorage("unitSystem") private var unitSystemString = "Metric"
    @State private var cacheSizeText: String = "—"
    @State private var showCacheCleared = false

    // Map Overlay Settings
    @AppStorage("mgrsGridEnabled") private var mgrsGridEnabled = false
    @AppStorage("mgrsGridDensity") private var mgrsGridDensityString = "1km"
    @AppStorage("showMGRSLabels") private var showMGRSLabels = true
    @AppStorage("coordinateDisplayFormat") private var coordinateFormatString = "MGRS"
    @AppStorage("breadcrumbTrailsEnabled") private var breadcrumbTrailsEnabled = true
    @AppStorage("trailMaxLength") private var trailMaxLength = 100
    @AppStorage("trailColorName") private var trailColorName = "cyan"
    // Self-position marker style — "milstd" = friendly-combat MIL-STD-2525
    // frame (default), "bullseye" = legacy tactical bullseye. Read by
    // MapViewController.Coordinator's MKUserLocation handler.
    @AppStorage("selfMarkerStyle") private var selfMarkerStyle = "milstd"
    // Phase 2 of the gy6 plan — toggles the CoreBluetooth FAA Remote ID
    // scanner. Default off because BLE scanning has a battery cost.
    @AppStorage("remoteIdScanEnabled") private var remoteIdScanEnabled = false

    @State private var showServersSheet = false
    @State private var showMissionCreationSheet = false

    var body: some View {
        NavigationView {
            List {
                // User Profile
                Section(loc.t("settings.section.userProfile")) {
                    HStack {
                        Text(loc.t("settings.callsign"))
                        Spacer()
                        TextField(loc.t("settings.callsign"), text: $userCallsign)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.blue)
                            .onChange(of: userCallsign) { newValue in
                                // Sync callsign to all services that send CoT
                                PositionBroadcastService.shared.userCallsign = newValue
                                ChatManager.shared.currentUserCallsign = newValue
                            }
                    }

                    HStack {
                        Text(loc.t("settings.name"))
                        Spacer()
                        TextField(loc.t("settings.name"), text: $userName)
                            .multilineTextAlignment(.trailing)
                            .foregroundColor(.blue)
                    }
                }

                // Servers (Streamlined)
                Section(loc.t("settings.section.servers")) {
                    Button(action: { showServersSheet = true }) {
                        HStack {
                            // Status indicator
                            Circle()
                                .fill(TAKService.shared.isConnected ? Color(hex: "#00FF00") : Color(hex: "#FF4444"))
                                .frame(width: 10, height: 10)

                            Text(loc.t("settings.manageServers"))
                                .foregroundColor(.primary)

                            Spacer()

                            // Server count/status
                            Text(TAKService.shared.isConnected ? "Connected" : "\(ServerManager.shared.servers.count) servers")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)

                            Image(systemName: "chevron.right")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                    }
                }

                // Navigation Settings
                Section(loc.t("settings.section.navigation")) {
                    NavigationLink(destination: NavigationSettingsView()) {
                        HStack {
                            Image(systemName: "location.north.line.fill")
                                .foregroundColor(Color(hex: "#FFFC00"))
                                .frame(width: 24)
                            Text(loc.t("settings.routeNavigation"))
                            Spacer()
                            Text(loc.t("settings.atakStyle"))
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                        }
                    }
                }

                // Customizable bottom toolbar
                Section("Toolbar") {
                    Button {
                        dismiss()
                        NotificationCenter.default.post(name: .enterToolbarEditMode, object: nil)
                    } label: {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(Color(hex: "#FFCC00"))
                                .frame(width: 24)
                            Text("Customize Toolbar")
                                .foregroundColor(.primary)
                            Spacer()
                            Text("Build your own")
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.gray.opacity(0.5))
                        }
                    }
                }


                // Map Overlay Settings
                Section(loc.t("settings.section.mapOverlays")) {
                    // MGRS Grid Settings
                    Toggle(loc.t("settings.mgrsGridOverlay"), isOn: $mgrsGridEnabled)

                    if mgrsGridEnabled {
                        Picker(loc.t("settings.gridDensity"), selection: $mgrsGridDensityString) {
                            Text("100km").tag("100km")
                            Text("10km").tag("10km")
                            Text("1km").tag("1km")
                        }

                        Toggle(loc.t("settings.showGridLabels"), isOn: $showMGRSLabels)
                    }

                    // Coordinate Display Format
                    Picker(loc.t("settings.coordinateFormat"), selection: $coordinateFormatString) {
                        Text(loc.t("settings.coord.dd")).tag("DD")
                        Text(loc.t("settings.coord.dm")).tag("DM")
                        Text(loc.t("settings.coord.dms")).tag("DMS")
                        // MGRS / UTM are bare acronyms — no descriptive
                        // text to translate, left as-is intentionally.
                        Text("MGRS").tag("MGRS")
                        Text("UTM").tag("UTM")
                        Text(loc.t("settings.coord.bng")).tag("BNG")
                    }

                    // Help text for coordinate formats
                    if coordinateFormatString == "BNG" {
                        Text(loc.t("settings.coord.bngHelp"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }

                    // Self-position marker style — default is the
                    // MIL-STD friendly-combat frame so the operator's
                    // own pip shares iconography with friendly contact
                    // markers. Picking "Bullseye" reverts to the legacy
                    // tactical green disc.
                    Picker(loc.t("settings.selfPositionMarker"), selection: $selfMarkerStyle) {
                        Text(loc.t("settings.marker.milstd")).tag("milstd")
                        Text(loc.t("settings.marker.bullseye")).tag("bullseye")
                    }
                }

                Section(loc.t("settings.section.droneDetection")) {
                    Toggle(loc.t("settings.faaRemoteIdScanner"), isOn: $remoteIdScanEnabled)

                    Text(loc.t("settings.droneDetection.desc"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)

                    if remoteIdScanEnabled {
                        Text(loc.t("settings.droneDetection.permHint"))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Language — switches the app UI language live, no
                // restart. Bound straight to LocalizationManager so
                // every observing view re-renders the instant the
                // picker changes.
                Section(loc.t("settings.section.language")) {
                    Picker(
                        loc.t("settings.appLanguage"),
                        selection: Binding(
                            get: { loc.current },
                            set: { loc.setLanguage($0) }
                        )
                    ) {
                        ForEach(LocalizationManager.Language.allCases) { lang in
                            Text("\(lang.flag)  \(lang.displayName)").tag(lang)
                        }
                    }
                }

                // Trail Settings
                Section(loc.t("settings.section.breadcrumbTrails")) {
                    Toggle(loc.t("settings.enableTrails"), isOn: $breadcrumbTrailsEnabled)

                    if breadcrumbTrailsEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(loc.t("settings.maxTrailLength"))
                                Spacer()
                                Text(loc.t("settings.trailPoints", trailMaxLength))
                                    .foregroundColor(.gray)
                            }
                            Slider(value: Binding(
                                get: { Double(trailMaxLength) },
                                set: { trailMaxLength = Int($0) }
                            ), in: 10...500, step: 10)
                        }

                        Picker(loc.t("settings.trailColor"), selection: $trailColorName) {
                            Text(loc.t("settings.color.cyan")).tag("cyan")
                            Text(loc.t("settings.color.green")).tag("green")
                            Text(loc.t("settings.color.orange")).tag("orange")
                            Text(loc.t("settings.color.red")).tag("red")
                            Text(loc.t("settings.color.blue")).tag("blue")
                        }
                    }
                }

                // Display Settings
                Section(loc.t("settings.section.display")) {
                    // Unit System Picker
                    Picker(loc.t("settings.unitSystem"), selection: $unitSystemString) {
                        Text(loc.t("settings.unit.metric")).tag("Metric")
                        Text(loc.t("settings.unit.imperial")).tag("Imperial")
                    }
                }

                // Performance
                Section(loc.t("settings.section.performance")) {
                    HStack {
                        Text(loc.t("settings.cacheSize"))
                        Spacer()
                        Text(cacheSizeText)
                            .foregroundColor(.gray)
                    }

                    Button(loc.t("settings.clearCache")) {
                        clearCache()
                    }
                    .foregroundColor(.red)
                }

                // Mission — entry point for issue #14 MVP. Sits above Data
                // Management because creating a mission is the prerequisite
                // for the data-package flows that live there.
                Section("MISSION") {
                    Button(action: { showMissionCreationSheet = true }) {
                        HStack {
                            Image(systemName: "flag.checkered")
                                .foregroundColor(Color(hex: "#00BCD4"))
                                .frame(width: 24)
                            Text("Create new mission")
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14))
                                .foregroundColor(.gray)
                        }
                    }
                }

                // Data Management
                Section(loc.t("settings.section.dataManagement")) {
                    NavigationLink(destination: DataPackageImportView()) {
                        Text(loc.t("settings.importDataPackage"))
                    }

                    Button(loc.t("settings.resetToDefaults")) {
                        userCallsign = "ALPHA-1"
                        userName = "Operator"
                        unitSystemString = "Metric"
                        // Map overlay defaults
                        mgrsGridEnabled = false
                        mgrsGridDensityString = "1km"
                        showMGRSLabels = true
                        coordinateFormatString = "MGRS"
                        breadcrumbTrailsEnabled = true
                        trailMaxLength = 100
                        trailColorName = "cyan"
                    }
                    .foregroundColor(.orange)
                }

                // Danger Zone
                Section(loc.t("settings.section.dangerZone")) {
                    Button(loc.t("settings.clearAllTeamData")) {
                        TeamService.shared.clearAllTeamData()
                    }
                    .foregroundColor(.red)
                }
            }
            .navigationTitle(loc.t("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(loc.t("settings.done")) {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showServersSheet) {
                ServersView()
            }
            .sheet(isPresented: $showMissionCreationSheet) {
                MissionCreationSheet()
            }
            .alert(loc.t("settings.cacheCleared.title"), isPresented: $showCacheCleared) {
                Button(loc.t("settings.ok"), role: .cancel) {}
            }
            .onAppear { refreshCacheSize() }
        }
    }

    private func refreshCacheSize() {
        let urlBytes = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        let tileBytes = tileCacheSizeBytes()
        let total = Int64(urlBytes) + tileBytes
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        cacheSizeText = formatter.string(fromByteCount: total)
    }

    private func tileCacheSizeBytes() -> Int64 {
        guard let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return 0
        }
        let tileDir = cachesDir.appendingPathComponent("tiles", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: tileDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    private func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        if let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let tileDir = cachesDir.appendingPathComponent("tiles", isDirectory: true)
            try? FileManager.default.removeItem(at: tileDir)
        }
        refreshCacheSize()
        showCacheCleared = true
    }
}
