//
//  MissionSyncView.swift
//  OmniTAKMobile
//
//  Multi-server Mission Sync UI, bound to MissionSyncManager (no stubs).
//  Shows every enabled server's live status and an aggregated list of
//  missions + data packages across all of them. Replaces the single-server,
//  stubbed MissionPackageSyncView (iOS issue #10).
//

import SwiftUI
import UIKit

struct MissionSyncView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = MissionSyncManager.shared
    /// The offline server whose full diagnosis is open (#169).
    @State private var failureDetail: MissionSyncFailureDetail?

    private let accent = Color(hex: "#00BCD4")

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                content
            }
            .navigationTitle("Mission Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }.foregroundColor(accent)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await manager.refreshAll() }
                    } label: {
                        if manager.isRefreshing {
                            ProgressView().tint(accent)
                        } else {
                            Image(systemName: "arrow.clockwise").foregroundColor(accent)
                        }
                    }
                    .disabled(manager.isRefreshing)
                }
            }
        }
        .sheet(item: $failureDetail) { detail in
            MissionSyncFailureDetailView(detail: detail) {
                Task { await manager.refresh(serverId: detail.serverId) }
            }
        }
        .task { await manager.refreshAll() }
        // Surface a newly-created mission immediately, without the user
        // pulling-to-refresh. MissionCreationSheet posts this notification
        // on success (iOS issue #14 MVP).
        .onReceive(NotificationCenter.default.publisher(for: .missionCreated)) { _ in
            Task { await manager.refreshAll() }
        }
    }

    @ViewBuilder
    private var content: some View {
        // During the very first refresh (sessions empty + isRefreshing), show a
        // loading indicator instead of the "No servers enabled" empty-state.
        // This eliminates the blank-page flash on first open (iOS #10 sub-issue 2).
        if manager.isRefreshing && manager.enabledCount == 0 {
            initialLoadingView
        } else if manager.enabledCount == 0 {
            emptyState
        } else {
            List {
                serversSection
                if !manager.allMissions.isEmpty { missionsSection }
                if !manager.allDataPackages.isEmpty { packagesSection }
            }
            .listStyle(.insetGrouped)
            .refreshable { await manager.refreshAll() }
        }
    }

    private var initialLoadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(accent)
                .scaleEffect(1.4)
            Text("Checking servers…")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
        }
    }

    // MARK: Servers

    private var serversSection: some View {
        Section {
            ForEach(manager.sessions) { s in
                HStack(spacing: 12) {
                    statusDot(s.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.serverName).font(.system(size: 15, weight: .semibold)).foregroundColor(.primary)
                        Text(statusLine(s)).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(3)
                    }
                    Spacer()
                    if s.isOnline {
                        Text("\(s.missions.count)m · \(s.dataPackages.count)p")
                            .font(.system(size: 12, weight: .medium)).foregroundColor(accent)
                    } else if case .offline = s.status {
                        // Tap for the full diagnosis (system error, handshake facts).
                        Image(systemName: "info.circle").foregroundColor(accent).font(.system(size: 15))
                    }
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let detail = MissionSyncFailureDetail(session: s) {
                        failureDetail = detail
                    } else {
                        Task { await manager.refresh(serverId: s.serverId) }
                    }
                }
            }
        } header: {
            HStack {
                Text("SERVERS")
                Spacer()
                Text("\(manager.onlineCount)/\(manager.enabledCount) online")
            }
        }
    }

    private func statusDot(_ status: MissionServerStatus) -> some View {
        Group {
            switch status {
            case .checking: ProgressView().scaleEffect(0.7).frame(width: 12, height: 12)
            case .online:   Circle().fill(Color.green).frame(width: 10, height: 10)
            case .offline:  Circle().fill(Color.red).frame(width: 10, height: 10)
            }
        }
        .frame(width: 16)
    }

    private func statusLine(_ s: ServerSyncSession) -> String {
        switch s.status {
        case .checking: return "\(s.host) — checking…"
        case .online:   return s.authLabel.map { "\(s.host) · \($0)" } ?? s.host
        case .offline(let reason, _): return reason
        }
    }

    // MARK: Missions (aggregated across servers)

    private var missionsSection: some View {
        Section("MISSIONS (\(manager.allMissions.count))") {
            ForEach(manager.allMissions) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(item.mission.name).font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                        Spacer()
                        serverBadge(item.serverName)
                    }
                    if let desc = item.mission.description, !desc.isEmpty {
                        Text(desc).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(2)
                    }
                    if let n = item.mission.contents?.count, n > 0 {
                        Text("\(n) item\(n == 1 ? "" : "s")").font(.system(size: 11)).foregroundColor(accent)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: Data packages (aggregated)

    private var packagesSection: some View {
        Section("DATA PACKAGES (\(manager.allDataPackages.count))") {
            ForEach(manager.allDataPackages) { item in
                HStack {
                    Image(systemName: "shippingbox.fill").foregroundColor(accent).font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.package.name).font(.system(size: 14)).foregroundColor(.primary).lineLimit(1)
                        if item.package.size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: item.package.size, countStyle: .file))
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    serverBadge(item.serverName)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func serverBadge(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.black)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(accent.opacity(0.85))
            .clipShape(Capsule())
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 44)).foregroundColor(.secondary)
            Text("No servers enabled").font(.system(size: 18, weight: .semibold)).foregroundColor(.primary)
            Text("Enable a TLS TAK server with a client certificate or a username and password in Servers, then pull to refresh. Every enabled server syncs here at once.")
                .font(.system(size: 13)).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
    }
}

// MARK: - Offline server diagnosis (#169)

/// What an offline server row opens: the one-line reason plus the full
/// diagnosis from the transport layer, ready to copy into a bug report.
struct MissionSyncFailureDetail: Identifiable {
    let serverId: UUID
    let serverName: String
    let host: String
    let reason: String
    let detail: String?

    var id: UUID { serverId }

    /// Text for the clipboard and the share sheet.
    var shareText: String {
        var lines = ["OmniTAK Mission Sync: \(serverName) is offline"]
        if let detail { lines.append(detail) } else { lines.append("\(host): \(reason)") }
        lines.append("App version: \(Self.appVersion), iOS \(UIDevice.current.systemVersion)")
        return lines.joined(separator: "\n")
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    init?(session: ServerSyncSession) {
        guard case .offline(let reason, let detail) = session.status else { return nil }
        serverId = session.serverId
        serverName = session.serverName
        host = session.host
        self.reason = reason
        self.detail = detail
    }
}

struct MissionSyncFailureDetailView: View {
    let detail: MissionSyncFailureDetail
    let onRetry: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showShare = false
    @State private var copied = false

    private let accent = Color(hex: "#00BCD4")

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(detail.reason)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .fixedSize(horizontal: false, vertical: true)

                        if let text = detail.detail {
                            Text("Details")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text(text)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white.opacity(0.85))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(10)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(8)
                        }

                        HStack(spacing: 12) {
                            Button {
                                UIPasteboard.general.string = detail.shareText
                                copied = true
                            } label: {
                                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                            Button {
                                showShare = true
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Spacer()
                            Button {
                                onRetry()
                                dismiss()
                            } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(accent)
                    }
                    .padding(16)
                }
            }
            .navigationTitle(detail.serverName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }.foregroundColor(accent)
                }
            }
        }
        .sheet(isPresented: $showShare) {
            MissionSyncShareSheet(activityItems: [detail.shareText])
        }
    }
}

/// System share sheet for the diagnosis text (same pattern as the lasso and
/// data-package share flows).
struct MissionSyncShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
