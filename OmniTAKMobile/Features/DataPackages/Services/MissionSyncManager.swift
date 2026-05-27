//
//  MissionSyncManager.swift
//  OmniTAKMobile
//
//  Multi-server mission / data-package sync, driven entirely by the real
//  TAK Marti REST API (TAKRestAPIClient) — no simulated handshakes.
//
//  Design (replaces the single-server, stubbed MissionPackageSyncService):
//   - One shared manager so connection state survives screen navigation
//     (the old per-view @StateObject reset to "Disconnected" every time —
//     see iOS issue #10).
//   - Servers come from ServerManager (single source of truth). Every
//     ENABLED TLS server with a client cert participates at once — there is
//     no separate "mission sync server" list to drift out of sync, and the
//     "Test Connection dance" is gone: status is derived from a real probe
//     on refresh, not a one-shot flag.
//   - Per-server sessions sync in parallel; the screen aggregates across all.
//
//  Verified against the 4-server matrix: TAK Server 5.7 (×2), OpenTAKServer
//  1.7.x, and taky 0.10 — including their Marti API dialect differences
//  (taky has no /missions endpoint and a different sync envelope, both
//  tolerated below).
//

import Foundation
import Combine
import os

// MARK: - Per-server status

enum MissionServerStatus: Equatable {
    case checking
    case online
    case offline(String)   // associated value = short reason

    var isOnline: Bool { if case .online = self { return true } else { return false } }
}

// MARK: - Per-server sync session

struct ServerSyncSession: Identifiable {
    let serverId: UUID
    let serverName: String
    let host: String
    var status: MissionServerStatus
    var missions: [TAKMissionInfo]
    var dataPackages: [TAKDataPackageInfo]
    var lastChecked: Date?

    var id: UUID { serverId }
    var isOnline: Bool { status.isOnline }
    var itemCount: Int { missions.count + dataPackages.count }
}

// MARK: - Aggregated rows (across all servers)

struct AggregatedMission: Identifiable {
    let serverId: UUID
    let serverName: String
    let mission: TAKMissionInfo
    var id: String { "\(serverId.uuidString):\(mission.name)" }
}

struct AggregatedPackage: Identifiable {
    let serverId: UUID
    let serverName: String
    let package: TAKDataPackageInfo
    var id: String { "\(serverId.uuidString):\(package.hash)" }
}

// MARK: - Manager

@MainActor
final class MissionSyncManager: ObservableObject {
    static let shared = MissionSyncManager()

    /// One session per enabled server, sorted by name.
    @Published private(set) var sessions: [ServerSyncSession] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?

    private static let log = Logger(subsystem: "com.omnitak.mobile", category: "mission.sync")

    private init() {}

    // MARK: Aggregates (what the UI binds to)

    var onlineCount: Int { sessions.filter(\.isOnline).count }
    var enabledCount: Int { sessions.count }

    var allMissions: [AggregatedMission] {
        sessions.flatMap { s in
            s.missions.map { AggregatedMission(serverId: s.serverId, serverName: s.serverName, mission: $0) }
        }
    }

    var allDataPackages: [AggregatedPackage] {
        sessions.flatMap { s in
            s.dataPackages.map { AggregatedPackage(serverId: s.serverId, serverName: s.serverName, package: $0) }
        }
    }

    /// Enrolled, enabled, TLS servers from the single source of truth.
    /// (A server with no client cert can't do mutual-TLS mission sync.)
    /// Public so the mission-creation flow (and any future writer) can reuse
    /// the same filter rather than re-deriving it from ServerManager.
    func enabledServers() -> [TAKServer] {
        ServerManager.shared.servers.filter { $0.enabled && $0.useTLS && $0.certificateName != nil }
    }

    // MARK: Refresh

    /// Refresh every enabled server in parallel. Existing data is preserved
    /// and rows flip to `.checking` while in flight, so the UI never blanks.
    func refreshAll() async {
        let servers = enabledServers()
        guard !servers.isEmpty else {
            sessions = []
            return
        }

        isRefreshing = true
        // Seed/refresh the session list, keeping prior missions/packages visible.
        sessions = servers.map { sv in
            if var existing = sessions.first(where: { $0.serverId == sv.id }) {
                existing.status = .checking
                return existing
            }
            return ServerSyncSession(serverId: sv.id, serverName: sv.name, host: sv.host,
                                     status: .checking, missions: [], dataPackages: [], lastChecked: nil)
        }

        let results = await withTaskGroup(of: ServerSyncSession.self) { group -> [ServerSyncSession] in
            for sv in servers {
                group.addTask { await MissionSyncManager.sync(server: sv) }
            }
            var out: [ServerSyncSession] = []
            for await session in group { out.append(session) }
            return out
        }

        sessions = results.sorted { $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending }
        isRefreshing = false
        lastRefresh = Date()
    }

    /// Refresh a single server (e.g. after toggling it on, or pull-to-refresh on its row).
    func refresh(serverId: UUID) async {
        guard let sv = enabledServers().first(where: { $0.id == serverId }) else { return }
        if let idx = sessions.firstIndex(where: { $0.serverId == serverId }) {
            sessions[idx].status = .checking
        }
        let updated = await MissionSyncManager.sync(server: sv)
        if let idx = sessions.firstIndex(where: { $0.serverId == serverId }) {
            sessions[idx] = updated
        } else {
            sessions.append(updated)
            sessions.sort { $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending }
        }
    }

    // MARK: Per-server sync (real Marti API)

    /// Probe + fetch one server. Connection status is derived from a live
    /// reachability check, not persisted — so it always reflects reality.
    /// Missions and data packages are fetched independently and tolerated
    /// per-endpoint: taky, for example, has no `/Marti/api/missions` route,
    /// so missions come back empty while its data packages still load.
    private static func sync(server: TAKServer) async -> ServerSyncSession {
        let client = TAKRestAPIClient()
        client.configure(from: server)

        var session = ServerSyncSession(
            serverId: server.id, serverName: server.name, host: server.host,
            status: .checking, missions: [], dataPackages: [], lastChecked: Date()
        )

        do {
            try await client.checkReachability()
            session.status = .online
        } catch {
            session.status = .offline(shortReason(error))
            session.lastChecked = Date()
            log.info("mission sync: \(server.name, privacy: .public) offline — \(shortReason(error), privacy: .public)")
            return session
        }

        // Independent fetches — a missing endpoint on one dialect must not
        // wipe out what the other returns.
        session.missions = (try? await client.getMissions()) ?? []
        session.dataPackages = (try? await client.getDataPackages()) ?? []
        session.lastChecked = Date()
        log.info("mission sync: \(server.name, privacy: .public) online — \(session.missions.count) missions, \(session.dataPackages.count) packages")
        return session
    }

    private static func shortReason(_ error: Error) -> String {
        if let apiErr = error as? TAKAPIError, let desc = apiErr.errorDescription {
            return desc
        }
        return (error as NSError).localizedDescription
    }
}
