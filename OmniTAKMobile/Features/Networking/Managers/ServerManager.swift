//
//  ServerManager.swift
//  OmniTAKTest
//
//  TAK Server configuration and management
//

import Foundation
import Combine

// MARK: - TAK Server Configuration

struct TAKServer: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16
    var protocolType: String
    var useTLS: Bool
    var isDefault: Bool
    var enabled: Bool  // Whether server is enabled for connection (like ATAK checkbox)
    var certificateName: String?  // Name of client certificate file (e.g., "omnitak-mobile")
    var certificatePassword: String?  // Password for .p12 certificate
    var caCertificateName: String?  // Name of CA/truststore certificate for server verification
    var caCertificatePassword: String?  // Password for CA .p12 certificate
    var allowLegacyTLS: Bool  // Allow TLS 1.0/1.1 for extremely old servers (security risk)
    var username: String?  // Username for enrollment
    var password: String?  // Password for enrollment
    var enrollmentPort: UInt16?  // Enrollment API port (default 8446)

    init(id: UUID = UUID(), name: String, host: String, port: UInt16, protocolType: String = "tcp", useTLS: Bool = false, isDefault: Bool = false, enabled: Bool = true, certificateName: String? = nil, certificatePassword: String? = nil, caCertificateName: String? = nil, caCertificatePassword: String? = nil, allowLegacyTLS: Bool = false, username: String? = nil, password: String? = nil, enrollmentPort: UInt16? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.protocolType = protocolType
        self.useTLS = useTLS
        self.isDefault = isDefault
        self.enabled = enabled
        self.certificateName = certificateName
        self.certificatePassword = certificatePassword
        self.caCertificateName = caCertificateName
        self.caCertificatePassword = caCertificatePassword
        self.allowLegacyTLS = allowLegacyTLS
        self.username = username
        self.password = password
        self.enrollmentPort = enrollmentPort
    }

    var displayName: String {
        return "\(name) (\(host):\(port))"
    }

    /// True when `self` and `other` point to the same TAK endpoint.
    /// Credentials and display name are intentionally excluded so
    /// re-importing the same server with updated certs is still a duplicate.
    func matchesEndpoint(of other: TAKServer) -> Bool {
        return host.caseInsensitiveCompare(other.host) == .orderedSame
            && port == other.port
            && protocolType == other.protocolType
    }
}

// MARK: - Server Manager

class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var servers: [TAKServer] = []
    @Published var activeServer: TAKServer?

    private let serversKey = "tak_servers"
    private let activeServerKey = "active_server_id"
    private let defaultServerSeededKey = "defaultServerSeeded"

    init() {
        loadServers()
        seedDefaultServerIfNeeded()
    }

    // MARK: - First-run Seeding

    /// Seed a single demo entry (public OpenTAKServer) the first time the app
    /// launches. Gated by `defaultServerSeeded` so deletes are sticky — the
    /// user can remove it and it won't reappear.
    private func seedDefaultServerIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultServerSeededKey) else { return }
        defaults.set(true, forKey: defaultServerSeededKey)

        // Don't seed if the user already has servers (e.g. upgraded from
        // an older build that pre-dated this flag).
        guard servers.isEmpty else { return }

        let demo = TAKServer(
            name: "Public OpenTAKServer (Demo)",
            host: "public.opentakserver.io",
            port: 8089,
            protocolType: "ssl",
            useTLS: true,
            enabled: false
        )
        servers.append(demo)
        saveServers()
    }

    // MARK: - Persistence

    private func loadServers() {
        if let data = UserDefaults.standard.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([TAKServer].self, from: data) {
            servers = decoded
        }

        // Load active server
        if let activeId = UserDefaults.standard.string(forKey: activeServerKey),
           let uuid = UUID(uuidString: activeId),
           let server = servers.first(where: { $0.id == uuid }) {
            activeServer = server
        } else if let first = servers.first {
            activeServer = first
        }
    }

    private func saveServers() {
        if let encoded = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(encoded, forKey: serversKey)
        }
    }

    private func saveActiveServer() {
        if let id = activeServer?.id.uuidString {
            UserDefaults.standard.set(id, forKey: activeServerKey)
        }
    }

    // MARK: - Server Management

    /// Adds a TAK server, or returns the existing entry if one already points
    /// at the same endpoint (host + port + protocolType). Idempotent on
    /// re-imports of the same data package.
    @discardableResult
    func addServer(_ server: TAKServer) -> TAKServer {
        if let existing = servers.first(where: { $0.matchesEndpoint(of: server) }) {
            #if DEBUG
            print("↩︎ Server already exists for \(server.host):\(server.port) — returning existing: \(existing.displayName)")
            #endif
            return existing
        }

        servers.append(server)
        saveServers()
        #if DEBUG
        print("✅ Added server: \(server.displayName)")
        #endif

        // Auto-connect if the server is enabled
        if server.enabled {
            // If no enabled active server exists, make this one active so
            // the UI (top-left header, etc.) reflects what we just connected to.
            if activeServer == nil || activeServer?.enabled != true {
                activeServer = server
                saveActiveServer()
            }
            TAKService.shared.connectToServer(server)
        }
        return server
    }

    func updateServer(_ server: TAKServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            let prior = servers[index]
            servers[index] = server

            // Update active server if it's the one being edited
            if activeServer?.id == server.id {
                activeServer = server
                saveActiveServer()
            }

            saveServers()
            #if DEBUG
            print("✅ Updated server: \(server.displayName)")
            #endif

            // Pair with Android `ServerManager.updateServer`: when the
            // operator edits host / port / protocol / cert, the existing
            // socket holds stale credentials and won't reflect the
            // change. Tear it down and re-open with the new params if
            // any wire-relevant field changed.
            let wireChanged =
                prior.host != server.host ||
                prior.port != server.port ||
                prior.protocolType != server.protocolType ||
                prior.useTLS != server.useTLS ||
                prior.certificateName != server.certificateName ||
                prior.certificatePassword != server.certificatePassword ||
                prior.username != server.username
            if wireChanged {
                TAKService.shared.disconnectFromServer(serverId: server.id)
                if server.enabled {
                    TAKService.shared.connectToServer(server)
                }
            }
        }
    }

    func deleteServer(_ server: TAKServer) {
        servers.removeAll { $0.id == server.id }

        // If active server was deleted, switch to first available
        if activeServer?.id == server.id {
            activeServer = servers.first
            saveActiveServer()
        }

        saveServers()
        #if DEBUG
        print("🗑️ Deleted server: \(server.displayName)")
        #endif
    }

    func setActiveServer(_ server: TAKServer) {
        activeServer = server
        saveActiveServer()
        print("🔄 Active server set to: \(server.displayName)")
    }

    func toggleServerEnabled(_ server: TAKServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index].enabled.toggle()

            if activeServer?.id == server.id {
                if servers[index].enabled {
                    activeServer = servers[index]
                } else {
                    // Active server just got disabled — hand off to the next
                    // enabled server so the header doesn't keep showing it.
                    activeServer = servers.first { $0.enabled }
                    saveActiveServer()
                }
            }

            saveServers()
            #if DEBUG
            print("🔀 Server \(server.name) enabled: \(servers[index].enabled)")
            #endif
        }
    }

    func getDefaultServer() -> TAKServer? {
        return servers.first { $0.isDefault } ?? servers.first
    }

    // MARK: - Multi-Server Support

    /// Get all enabled servers
    func getEnabledServers() -> [TAKServer] {
        return servers.filter { $0.enabled }
    }

    /// Enable a specific server
    func enableServer(_ server: TAKServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index].enabled = true
            saveServers()
            #if DEBUG
            print("✅ Server \(server.name) enabled")
            #endif
        }
    }

    /// Disable a specific server
    func disableServer(_ server: TAKServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index].enabled = false

            if activeServer?.id == server.id {
                activeServer = servers.first { $0.enabled }
                saveActiveServer()
            }

            saveServers()
            #if DEBUG
            print("❌ Server \(server.name) disabled")
            #endif
        }
    }

    /// Enable all servers
    func enableAllServers() {
        for index in servers.indices {
            servers[index].enabled = true
        }
        saveServers()
        #if DEBUG
        print("✅ All servers enabled")
        #endif
    }

    /// Disable all servers
    func disableAllServers() {
        for index in servers.indices {
            servers[index].enabled = false
        }
        saveServers()
        #if DEBUG
        print("❌ All servers disabled")
        #endif
    }

    /// Connect to all enabled servers
    func connectToEnabledServers() {
        let enabledServers = getEnabledServers()
        for server in enabledServers {
            TAKService.shared.connectToServer(server)
        }
        #if DEBUG
        print("🔌 Connecting to \(enabledServers.count) enabled server(s)")
        #endif
    }
}
