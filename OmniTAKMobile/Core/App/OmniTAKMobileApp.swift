import SwiftUI
import os

extension Logger {
    static let takNetwork = Logger(subsystem: "com.omnitak.mobile", category: "tak.network")
    static let takCoT = Logger(subsystem: "com.omnitak.mobile", category: "tak.cot")
    static let authEnrollment = Logger(subsystem: "com.omnitak.mobile", category: "auth.enrollment")
    static let map = Logger(subsystem: "com.omnitak.mobile", category: "map")
    static let adsb = Logger(subsystem: "com.omnitak.mobile", category: "adsb")
    static let military = Logger(subsystem: "com.omnitak.mobile", category: "military")
    static let meshtastic = Logger(subsystem: "com.omnitak.mobile", category: "meshtastic")
    static let ui = Logger(subsystem: "com.omnitak.mobile", category: "ui")
}

@main
struct OmniTAKMobileApp: App {
    @StateObject private var deepLinkHandler = DeepLinkHandler.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("remoteIdScanEnabled") private var remoteIdScanEnabled = false
    @AppStorage("gybDetectorEnabled") private var gybDetectorEnabled = false

    init() {
        // Eagerly initialize the Meshtastic manager so its COT bridge is wired
        // into TAKService at launch. Without this, mesh nodes would only
        // appear on the map after a Meshtastic view is opened.
        _ = MeshtasticManager.shared
        // MeshCore is the second mesh framework (companion BLE). Eagerly create
        // its manager too so its CoT bridge is wired regardless of which
        // framework the operator has selected; the active framework is chosen
        // via @AppStorage("selectedMeshFramework").
        if #available(iOS 13.0, *) { _ = MeshCoreManager.shared }
        Logger.meshtastic.info("Meshtastic + MeshCore managers initialized at launch")

        // Wire the FAA Remote ID scanner. The actual on/off state is
        // pulled from UserDefaults below via `.task` so the @AppStorage
        // value is the single source of truth — Settings toggle flips
        // the scanner without needing to talk to the bridge directly.
        _ = RemoteIdAppBridge.shared

        // Wire the external gyb_detect sensor bridge (BLE GATT WiFi-RID
        // stream). On/off mirrors @AppStorage("gybDetectorEnabled") below.
        _ = GybManager.shared

        // Plugin SDK — populate the COMPILE-TIME registry and activate the
        // plugins the user has enabled. There is NO dynamic / downloadable
        // code: bundled plugins are Swift types linked into the binary
        // (loadBundledPlugins) — App-Store compliant. Plugins run IN-PROCESS
        // with the host's full permissions; there is no sandbox.
        PluginRegistry.shared.loadBundledPlugins()
        PluginRegistry.shared.activateEnabled(host: AppPluginHost.shared)
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootTabView()
                    .onAppear {
                        RemoteIdAppBridge.shared.setEnabled(remoteIdScanEnabled)
                        GybManager.shared.setEnabled(gybDetectorEnabled)
                    }
                    .onChange(of: remoteIdScanEnabled) { newValue in
                        RemoteIdAppBridge.shared.setEnabled(newValue)
                    }
                    .onChange(of: gybDetectorEnabled) { newValue in
                        GybManager.shared.setEnabled(newValue)
                    }
                    #if DEBUG
                    .task {
                        // Auto-import any TAK data package staged in
                        // Documents/import/ — simulator / CI interop only.
                        await DataPackageBootstrap.runIfNeeded()
                        // Same for a staged KML/KMZ — lets us exercise the
                        // real on-device import + render path with large
                        // files in the sim/CI without the document picker.
                        if await KMLVectorOverlayStore.shared.overlays.isEmpty {
                            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            let importDir = docs.appendingPathComponent("import")
                            if let files = try? FileManager.default.contentsOfDirectory(at: importDir, includingPropertiesForKeys: nil),
                               let kml = files.first(where: { ["kml", "kmz"].contains($0.pathExtension.lowercased()) }) {
                                await KMLVectorOverlayStore.shared.importKML(from: kml)
                                if let last = await KMLVectorOverlayStore.shared.overlays.last {
                                    NotificationCenter.default.post(name: .kmlZoomToOverlay, object: nil, userInfo: ["id": last.id])
                                }
                            }
                        }
                    }
                    #endif

                // Enrollment overlay
                if deepLinkHandler.isProcessing {
                    DeepLinkEnrollmentOverlay(isProcessing: true, message: "Enrolling with server...")
                }

                if deepLinkHandler.showEnrollmentSuccess {
                    DeepLinkEnrollmentOverlay(
                        isProcessing: false,
                        message: "Connected to \(deepLinkHandler.enrolledServerName ?? "server")!",
                        isSuccess: true
                    )
                    .onAppear {
                        // Auto-dismiss after 3 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            deepLinkHandler.showEnrollmentSuccess = false
                        }
                    }
                }

                if let error = deepLinkHandler.lastError {
                    DeepLinkEnrollmentOverlay(isProcessing: false, message: error, isError: true)
                        .onTapGesture {
                            deepLinkHandler.lastError = nil
                        }
                }
            }
            // Deep-link config-profile confirmation: mirrors the scanner path so
            // the user reviews settings before they are applied.
            .sheet(item: $deepLinkHandler.pendingDeepLinkProfile) { profile in
                ProfileImportPreviewView(profile: profile) { confirmed in
                    deepLinkHandler.confirmPendingProfile(profile, confirmed: confirmed)
                }
                .environmentObject(LocalizationManager.shared)
            }
            .onOpenURL { url in
                // KML/KMZ opened from Files / Mail / AirDrop / "Open with
                // OmniTAK" → import through the robust vector overlay path.
                if url.isFileURL, ["kml", "kmz"].contains(url.pathExtension.lowercased()) {
                    importOpenedKML(url)
                } else {
                    // Handle tak:// deep links (QR code enrollment)
                    deepLinkHandler.handleURL(url)
                }
            }
            .fullScreenCover(isPresented: Binding(
                get: { !hasCompletedOnboarding },
                set: { newValue in if !newValue { hasCompletedOnboarding = true } }
            )) {
                FirstTimeOnboarding(onComplete: {
                    hasCompletedOnboarding = true
                })
                .environmentObject(LocalizationManager.shared)
            }
            // Inject the localization manager app-wide so any view can
            // observe it and re-render the instant the language changes.
            .environmentObject(LocalizationManager.shared)
        }
    }

    /// Copy an opened KML/KMZ to a temp file and import it through the robust
    /// vector overlay store (off-thread parse → GeoJSON → GPU render), then
    /// frame it on the map.
    private func importOpenedKML(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: tmp)
        do {
            try FileManager.default.copyItem(at: url, to: tmp)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        Task {
            await KMLVectorOverlayStore.shared.importKML(from: tmp)
            try? FileManager.default.removeItem(at: tmp)
            if let last = await KMLVectorOverlayStore.shared.overlays.last {
                NotificationCenter.default.post(name: .kmlZoomToOverlay, object: nil, userInfo: ["id": last.id])
            }
        }
    }
}

// MARK: - Deep Link Enrollment Overlay

struct DeepLinkEnrollmentOverlay: View {
    let isProcessing: Bool
    let message: String
    var isSuccess: Bool = false
    var isError: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            if isProcessing {
                ProgressView()
                    .scaleEffect(1.5)
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
            } else if isSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.green)
            } else if isError {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
            }

            Text(message)
                .font(.headline)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if isError {
                Text("Tap to dismiss")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.85))
        )
        .shadow(radius: 20)
    }
}
