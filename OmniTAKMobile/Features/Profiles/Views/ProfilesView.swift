//
//  ProfilesView.swift
//  OmniTAKMobile
//
//  Configuration Profiles management sheet.
//  Launched from a "Configuration Profiles" row in SettingsView.
//

import SwiftUI
import CoreImage

// MARK: - Profiles View

struct ProfilesView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = ProfileStore.shared
    @EnvironmentObject private var loc: LocalizationManager

    @State private var showSnapshotSheet = false
    @State private var showScannerSheet = false
    @State private var selectedQRProfile: ConfigProfile?
    @State private var importPreviewProfile: ConfigProfile?
    @State private var showImportPreview = false
    @State private var renameTarget: ConfigProfile?
    @State private var renameText = ""
    @State private var showRenameAlert = false
    @State private var snapshotName = ""
    @State private var showDeleteConfirm = false
    @State private var deleteTarget: ConfigProfile?
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                if store.profiles.isEmpty {
                    emptyState
                } else {
                    profileList
                }
            }
            .navigationTitle("Configuration Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "#FFFC00"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            snapshotName = "Profile \(store.profiles.count + 1)"
                            showSnapshotSheet = true
                        } label: {
                            Label("Snapshot current config", systemImage: "camera.fill")
                        }
                        Button {
                            showScannerSheet = true
                        } label: {
                            Label("Scan to import", systemImage: "qrcode.viewfinder")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(Color(hex: "#FFFC00"))
                    }
                }
            }
            // Snapshot name sheet
            .sheet(isPresented: $showSnapshotSheet) {
                snapshotNameSheet
            }
            // QR display sheet
            .sheet(item: $selectedQRProfile) { profile in
                ProfileQRDisplayView(profile: profile)
            }
            // Scanner sheet
            .sheet(isPresented: $showScannerSheet) {
                ProfileScannerView { imported in
                    importPreviewProfile = imported
                    showImportPreview = true
                }
            }
            // Import preview sheet
            .sheet(isPresented: $showImportPreview) {
                if let profile = importPreviewProfile {
                    ProfileImportPreviewView(profile: profile) { confirmed in
                        if confirmed {
                            store.addProfile(profile)
                            store.apply(profile)
                        }
                        importPreviewProfile = nil
                    }
                }
            }
            .alert("Rename Profile", isPresented: $showRenameAlert) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let target = renameTarget, !renameText.isEmpty {
                        store.renameProfile(id: target.id, name: renameText)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Delete Profile?", isPresented: $showDeleteConfirm) {
                Button("Delete", role: .destructive) {
                    if let target = deleteTarget {
                        store.deleteProfile(id: target.id)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This cannot be undone.")
            }
            .alert("Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 60))
                .foregroundColor(Color(hex: "#FFFC00").opacity(0.4))

            Text("No Profiles")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)

            Text("Snapshot your current config to share with teammates via QR code.")
                .font(.system(size: 15))
                .foregroundColor(Color(hex: "#CCCCCC"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            VStack(spacing: 12) {
                Button {
                    snapshotName = "Profile 1"
                    showSnapshotSheet = true
                } label: {
                    Label("Snapshot current config", systemImage: "camera.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(hex: "#FFFC00"))
                        .cornerRadius(12)
                }

                Button {
                    showScannerSheet = true
                } label: {
                    Label("Scan to import", systemImage: "qrcode.viewfinder")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(hex: "#FFFC00"))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color(white: 0.12))
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: "#FFFC00").opacity(0.4), lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
        }
    }

    // MARK: - Profile List

    private var profileList: some View {
        List {
            ForEach(store.profiles) { profile in
                profileRow(profile)
                    .listRowBackground(Color(white: 0.08))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTarget = profile
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            renameTarget = profile
                            renameText = profile.name
                            showRenameAlert = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(.blue)
                    }
            }
        }
        .listStyle(.insetGrouped)
        .background(Color.black)
    }

    private func profileRow(_ profile: ConfigProfile) -> some View {
        Button {
            // Tap to show actions
        } label: {
            HStack(spacing: 14) {
                // Active indicator
                ZStack {
                    Circle()
                        .fill(store.activeProfileID == profile.id
                              ? Color(hex: "#FFFC00")
                              : Color(white: 0.2))
                        .frame(width: 10, height: 10)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text(profile.subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#AAAAAA"))
                }

                Spacer()

                // Action buttons
                HStack(spacing: 16) {
                    // Activate
                    Button {
                        store.apply(profile)
                        store.setActive(id: profile.id)
                    } label: {
                        Image(systemName: store.activeProfileID == profile.id
                              ? "checkmark.circle.fill"
                              : "circle")
                            .foregroundColor(store.activeProfileID == profile.id
                                             ? Color(hex: "#FFFC00")
                                             : Color(white: 0.4))
                            .font(.system(size: 20))
                    }
                    .buttonStyle(.plain)

                    // QR
                    Button {
                        selectedQRProfile = profile
                    } label: {
                        Image(systemName: "qrcode")
                            .foregroundColor(Color(hex: "#CCCCCC"))
                            .font(.system(size: 18))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Snapshot name sheet

    private var snapshotNameSheet: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 24) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 44))
                        .foregroundColor(Color(hex: "#FFFC00"))

                    Text("Name this profile")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(.white)

                    Text("Give your team config a descriptive name (e.g. \"Alpha Team West\").")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "#CCCCCC"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    TextField("Profile name", text: $snapshotName)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 32)

                    Button {
                        let profile = store.saveSnapshot(name: snapshotName.isEmpty ? "Snapshot" : snapshotName)
                        showSnapshotSheet = false
                        // Immediately show QR for the new profile
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            selectedQRProfile = profile
                        }
                    } label: {
                        Text("Snapshot & generate QR")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color(hex: "#FFFC00"))
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, 32)
                    .disabled(snapshotName.isEmpty)
                    .opacity(snapshotName.isEmpty ? 0.5 : 1.0)

                    Spacer()
                }
                .padding(.top, 40)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { showSnapshotSheet = false }
                        .foregroundColor(Color(hex: "#FFFC00"))
                }
            }
        }
    }
}

// MARK: - QR Display View

struct ProfileQRDisplayView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ConfigProfile

    @State private var qrImage: UIImage?
    @State private var urlString: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // Header
                        VStack(spacing: 8) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 48))
                                .foregroundColor(Color(hex: "#FFFC00"))

                            Text(profile.name)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)

                            Text("Teammates scan this to sync your team config")
                                .font(.system(size: 14))
                                .foregroundColor(Color(hex: "#CCCCCC"))
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 24)

                        // QR image
                        if let qrImage = qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 260, height: 260)
                                .background(Color.white)
                                .cornerRadius(12)
                                .padding(8)
                                .background(Color.white)
                                .cornerRadius(16)
                        } else if let errorMessage = errorMessage {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 32))
                                    .foregroundColor(.orange)
                                Text(errorMessage)
                                    .font(.system(size: 14))
                                    .foregroundColor(Color(hex: "#CCCCCC"))
                                    .multilineTextAlignment(.center)
                            }
                            .padding()
                        } else {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: Color(hex: "#FFFC00")))
                                .frame(width: 260, height: 260)
                        }

                        // Profile summary
                        VStack(alignment: .leading, spacing: 8) {
                            profileSummaryRow("Team", value: profile.teamName)
                            profileSummaryRow("Servers", value: profile.firstServerSummary)
                            profileSummaryRow("Map engine", value: profile.mapEngine.flatMap { MapEngine(rawValue: $0)?.displayName })
                            profileSummaryRow("Coordinates", value: profile.coordinateFormat)
                            profileSummaryRow("Units", value: profile.unitSystem)
                        }
                        .padding(16)
                        .background(Color(white: 0.10))
                        .cornerRadius(12)
                        .padding(.horizontal, 24)

                        // What's NOT in the QR
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "lock.fill")
                                    .foregroundColor(Color(hex: "#FFFC00"))
                                    .font(.system(size: 14))
                                Text("What's NOT included (stays on your device):")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            Text("• Client certificates and passphrases\n• Server passwords\n• Your callsign (each user sets their own)")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#AAAAAA"))
                        }
                        .padding(14)
                        .background(Color(hex: "#FFFC00").opacity(0.05))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#FFFC00").opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)

                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: "#FFFC00"))
                }
            }
            .onAppear { generateQR() }
        }
    }

    private func profileSummaryRow(_ label: String, value: String?) -> some View {
        Group {
            if let value = value {
                HStack {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#AAAAAA"))
                    Spacer()
                    Text(value)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
            } else {
                EmptyView()
            }
        }
    }

    private func generateQR() {
        do {
            let url = try ProfileQRCodec.encode(profile)
            urlString = url
            qrImage = ProfileQRCodec.generateQRImage(for: url, size: 260)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Import Preview View

struct ProfileImportPreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ConfigProfile
    var onConfirm: (Bool) -> Void

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(Color(hex: "#FFFC00"))
                            .padding(.top, 32)

                        Text("Import Profile?")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)

                        Text("\"\(profile.name)\"")
                            .font(.system(size: 16))
                            .foregroundColor(Color(hex: "#CCCCCC"))

                        // Summary
                        VStack(alignment: .leading, spacing: 10) {
                            importRow("Profile name", value: profile.name)
                            importRow("Team", value: profile.teamName)
                            importRow("Role template", value: profile.teamRole)

                            if !profile.servers.isEmpty {
                                Divider().background(Color(white: 0.2))
                                Text("Servers to add")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(hex: "#AAAAAA"))
                                ForEach(profile.servers, id: \.host) { s in
                                    HStack {
                                        Image(systemName: "antenna.radiowaves.left.and.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(.green)
                                        Text("\(s.name)  (\(s.host):\(s.port))")
                                            .font(.system(size: 13))
                                            .foregroundColor(.white)
                                    }
                                }
                            }

                            Divider().background(Color(white: 0.2))
                            importRow("Map engine", value: profile.mapEngine.flatMap { MapEngine(rawValue: $0)?.displayName })
                            importRow("Coordinates", value: profile.coordinateFormat)
                            importRow("Units", value: profile.unitSystem)
                        }
                        .padding(16)
                        .background(Color(white: 0.10))
                        .cornerRadius(12)
                        .padding(.horizontal, 24)

                        // Warning
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Your callsign will NOT be changed.", systemImage: "info.circle")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "#FFFC00"))
                            Text("You will need to enroll your own certificate after import.")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "#AAAAAA"))
                        }
                        .padding(12)
                        .background(Color(hex: "#FFFC00").opacity(0.05))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(hex: "#FFFC00").opacity(0.2), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)

                        // Buttons
                        VStack(spacing: 12) {
                            Button {
                                onConfirm(true)
                                dismiss()
                            } label: {
                                Text("Import & Apply")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color(hex: "#FFFC00"))
                                    .cornerRadius(12)
                            }

                            Button {
                                onConfirm(false)
                                dismiss()
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 17))
                                    .foregroundColor(Color(hex: "#FFFC00"))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(Color(white: 0.12))
                                    .cornerRadius(12)
                            }
                        }
                        .padding(.horizontal, 24)

                        Spacer(minLength: 32)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func importRow(_ label: String, value: String?) -> some View {
        Group {
            if let value = value {
                HStack {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#AAAAAA"))
                    Spacer()
                    Text(value)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                }
            } else {
                EmptyView()
            }
        }
    }
}

// MARK: - Profile Scanner View

struct ProfileScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var qrScanner = QRScannerViewModel()
    var onProfileScanned: (ConfigProfile) -> Void

    @State private var showError = false
    @State private var errorMessage = ""
    @State private var manualURLText = ""
    @State private var showManualEntry = false

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.system(size: 48))
                            .foregroundColor(Color(hex: "#FFFC00"))

                        Text("Scan Team Config QR")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.white)

                        Text("Ask your team captain to show the profile QR code")
                            .font(.system(size: 14))
                            .foregroundColor(Color(hex: "#CCCCCC"))
                    }
                    .padding(.vertical, 20)

                    if showManualEntry {
                        manualEntryView
                    } else {
                        cameraPreview
                    }

                    Spacer()

                    // Toggle
                    Button {
                        withAnimation { showManualEntry.toggle() }
                        if !showManualEntry {
                            qrScanner.checkPermissions()
                        } else {
                            qrScanner.stopScanning()
                        }
                    } label: {
                        HStack {
                            Image(systemName: showManualEntry ? "qrcode.viewfinder" : "keyboard")
                            Text(showManualEntry ? "Use Camera" : "Paste URL manually")
                        }
                        .foregroundColor(Color(hex: "#FFFC00"))
                        .padding(.vertical, 12)
                        .padding(.horizontal, 24)
                        .background(Color(white: 0.12))
                        .cornerRadius(8)
                    }
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        qrScanner.stopScanning()
                        dismiss()
                    }
                    .foregroundColor(Color(hex: "#FFFC00"))
                }
            }
            .alert("Invalid QR Code", isPresented: $showError) {
                Button("OK", role: .cancel) {
                    qrScanner.startScanning()
                }
            } message: {
                Text(errorMessage)
            }
            .onDisappear { qrScanner.stopScanning() }
        }
    }

    private var cameraPreview: some View {
        ZStack {
            if qrScanner.isAuthorized && !qrScanner.hasCameraError && !qrScanner.isInitializing {
                QRScannerPreview(session: qrScanner.captureSession)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color(hex: "#FFFC00"), lineWidth: 2)
                    )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 36))
                        .foregroundColor(Color(hex: "#CCCCCC"))
                    Text(qrScanner.statusMessage)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#CCCCCC"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .padding(.horizontal, 24)
        .onAppear {
            qrScanner.onQRCodeScanned = { code in
                handleScannedCode(code)
            }
            qrScanner.checkPermissions()
        }
    }

    private var manualEntryView: some View {
        VStack(spacing: 16) {
            Text("Paste the omnitak://profile?d=… URL")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#AAAAAA"))

            TextEditor(text: $manualURLText)
                .frame(height: 100)
                .padding(8)
                .background(Color(white: 0.12))
                .cornerRadius(8)
                .foregroundColor(.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(white: 0.25), lineWidth: 1)
                )

            Button {
                handleScannedCode(manualURLText.trimmingCharacters(in: .whitespacesAndNewlines))
            } label: {
                Text("Import")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(hex: "#FFFC00"))
                    .cornerRadius(10)
            }
            .disabled(manualURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(manualURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1.0)
        }
        .padding(.horizontal, 24)
    }

    private func handleScannedCode(_ code: String) {
        qrScanner.stopScanning()

        // Must be an omnitak://profile URL
        guard code.lowercased().hasPrefix("omnitak://profile") else {
            // Not a profile QR — ignore silently and restart scanner
            qrScanner.startScanning()
            return
        }

        do {
            let profile = try ProfileQRCodec.decode(urlString: code)
            DispatchQueue.main.async {
                onProfileScanned(profile)
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ProfilesView_Previews: PreviewProvider {
    static var previews: some View {
        ProfilesView()
            .environmentObject(LocalizationManager.shared)
            .preferredColorScheme(.dark)
    }
}
#endif
