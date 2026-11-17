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
    var allowUntrustedTLS: Bool  // Accept ANY server certificate, even when a truststore is stored (explicit opt-in, MITM risk — #127)
    var username: String?  // Username for enrollment
    var password: String?  // Password for enrollment
    var enrollmentPort: UInt16?  // Enrollment API port (default 8446)
    var secureAPIPort: UInt16?  // Marti/Mission REST API port (default 8443) — #114

    init(id: UUID = UUID(), name: String, host: String, port: UInt16, protocolType: String = "tcp", useTLS: Bool = false, isDefault: Bool = false, enabled: Bool = true, certificateName: String? = nil, certificatePassword: String? = nil, caCertificateName: String? = nil, caCertificatePassword: String? = nil, allowLegacyTLS: Bool = false, allowUntrustedTLS: Bool = false, username: String? = nil, password: String? = nil, enrollmentPort: UInt16? = nil, secureAPIPort: UInt16? = nil) {
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
        self.allowUntrustedTLS = allowUntrustedTLS
        self.username = username
        self.password = password
        self.enrollmentPort = enrollmentPort
        self.secureAPIPort = secureAPIPort
    }

    /// Custom decoding so servers saved by builds that predate
    /// `allowUntrustedTLS` still decode — the missing key falls back to
    /// `false` (the secure default: system trust evaluation). Encoding
    /// stays compiler-synthesized.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = try c.decode(UInt16.self, forKey: .port)
        protocolType = try c.decode(String.self, forKey: .protocolType)
        useTLS = try c.decode(Bool.self, forKey: .useTLS)
        isDefault = try c.decode(Bool.self, forKey: .isDefault)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        certificateName = try c.decodeIfPresent(String.self, forKey: .certificateName)
        certificatePassword = try c.decodeIfPresent(String.self, forKey: .certificatePassword)
        caCertificateName = try c.decodeIfPresent(String.self, forKey: .caCertificateName)
        caCertificatePassword = try c.decodeIfPresent(String.self, forKey: .caCertificatePassword)
        allowLegacyTLS = try c.decodeIfPresent(Bool.self, forKey: .allowLegacyTLS) ?? false
        allowUntrustedTLS = try c.decodeIfPresent(Bool.self, forKey: .allowUntrustedTLS) ?? false
        username = try c.decodeIfPresent(String.self, forKey: .username)
        password = try c.decodeIfPresent(String.self, forKey: .password)
        enrollmentPort = try c.decodeIfPresent(UInt16.self, forKey: .enrollmentPort)
        secureAPIPort = try c.decodeIfPresent(UInt16.self, forKey: .secureAPIPort)
    }

    var displayName: String {
        return "\(name) (\(host):\(port))"
    }

    /// True when `self` and `other` point to the same TAK endpoint.
    /// Credentials and display name are intentionally excluded so
    /// re-importing the same server with updated certs is still a duplicate.
    ///
    /// "ssl" and "tls" name the same transport. Enrollment saves "ssl" and Edit Server
    /// saves "tls" (even when nothing was changed), so a server the operator has edited
    /// must still match the enrollment that comes after it (#156).
    func matchesEndpoint(of other: TAKServer) -> Bool {
        return host.caseInsensitiveCompare(other.host) == .orderedSame
            && port == other.port
            && TAKServer.transport(of: protocolType) == TAKServer.transport(of: other.protocolType)
    }

    private static func transport(of protocolType: String) -> String {
        let name = protocolType.lowercased()
        return name == "ssl" ? "tls" : name
    }

    /// This saved record after the operator enrolled with the same endpoint again (#156).
    ///
    /// A new enrollment is a new certificate for an address that is already saved, so the
    /// record takes what an enrollment decides (the client certificate and its password, the
    /// CA chain and its password, the protocol and `useTLS`) and the Marti API port when the
    /// link or the form gave one. A saved "tls" and an enrolled "ssl" are the same transport
    /// (see `matchesEndpoint`), so for them only the spelling of the protocol changes. Everything else stays as it is, because the operator may
    /// have set it: the id (the Servers list, the active server and the live link know the
    /// record by it), the name, whether it is switched on, `isDefault`, the TLS opt-ins,
    /// the enrollment account and port, and the Marti API port when none was given.
    func mergingEnrollment(_ enrolled: TAKServer, apiPort: UInt16? = nil) -> TAKServer {
        var merged = self
        merged.certificateName = enrolled.certificateName
        merged.certificatePassword = enrolled.certificatePassword
        merged.caCertificateName = enrolled.caCertificateName
        merged.caCertificatePassword = enrolled.caCertificatePassword
        merged.useTLS = enrolled.useTLS
        merged.protocolType = enrolled.protocolType
        if let apiPort { merged.secureAPIPort = apiPort }
        return merged
    }
}

// MARK: - Adopting an enrolled server (#156)

/// What a finished enrollment does to the saved list: the record to keep and whether it is
/// new. Plain values with no sockets and no storage, so the rule can be tested alone.
struct EnrolledServerAdoption: Equatable {
    /// The record to keep. For a new server, the enrolled record with the Marti API port the
    /// link or the form gave. For an endpoint that is already saved, that saved record with
    /// the enrollment merged into it (`TAKServer.mergingEnrollment`), under its own id.
    let server: TAKServer
    /// True when no saved record points at the enrolled endpoint (host, port and protocol).
    let isNew: Bool

    /// - Parameters:
    ///   - enrolled: the record an enrollment built. Its id is new every time, so it says
    ///     nothing about the saved record.
    ///   - apiPort: the Marti API port the link or the form gave, nil when it gave none.
    ///   - saved: the saved list.
    static func plan(enrolled: TAKServer, apiPort: UInt16?, saved: [TAKServer]) -> EnrolledServerAdoption {
        if let existing = saved.first(where: { $0.matchesEndpoint(of: enrolled) }) {
            return EnrolledServerAdoption(server: existing.mergingEnrollment(enrolled, apiPort: apiPort), isNew: false)
        }
        var fresh = enrolled
        if let apiPort { fresh.secureAPIPort = apiPort }
        return EnrolledServerAdoption(server: fresh, isNew: true)
    }
}

// MARK: - Server Manager

class ServerManager: ObservableObject {
    static let shared = ServerManager()

    @Published var servers: [TAKServer] = []
    @Published var activeServer: TAKServer?

    private let serversKey = "tak_servers"
    private let activeServerKey = "active_server_id"
    /// Where the list and the active server are saved. Tests give a manager a suite of its
    /// own, so they never touch the servers saved on the simulator.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadServers()
    }

    // MARK: - Persistence

    private func loadServers() {
        if let data = defaults.data(forKey: serversKey),
           let decoded = try? JSONDecoder().decode([TAKServer].self, from: data) {
            servers = decoded
        }

        // Load active server
        if let activeId = defaults.string(forKey: activeServerKey),
           let uuid = UUID(uuidString: activeId),
           let server = servers.first(where: { $0.id == uuid }) {
            activeServer = server
        } else if let first = servers.first {
            activeServer = first
        }
    }

    private func saveServers() {
        if let encoded = try? JSONEncoder().encode(servers) {
            defaults.set(encoded, forKey: serversKey)
        }
    }

    private func saveActiveServer() {
        if let id = activeServer?.id.uuidString {
            defaults.set(id, forKey: activeServerKey)
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

    /// For a server the operator has just asked for (Add Server, a connect link):
    /// add it, or find the record already saved for that address, and make sure that
    /// saved record is switched on and is the active one. A record that was switched
    /// off is switched on through `enableServer`, so it is saved. The record that
    /// comes back is the saved one (its id is the one the Servers list knows), and
    /// the caller dials it with `TAKService.connectToServer`.
    @discardableResult
    func addAndSwitchOn(_ server: TAKServer) -> TAKServer {
        var saved = addServer(server)
        if !saved.enabled {
            enableServer(saved)
            saved = servers.first { $0.id == saved.id } ?? saved
        }
        setActiveServer(saved)
        return saved
    }

    /// A server has just been enrolled with (the Enroll form, an enrollment link or QR): keep
    /// it in the saved list, make it the active server, and leave exactly one live link to it
    /// (#156). The one place that rule is written; `CSREnrollmentService.enrollWithCSR`
    /// calls it, so the form and both links share it. On the main thread: it changes
    /// published state and dials.
    ///
    /// - A new endpoint is saved, and `addServer` dials it. The `connectToServer` after that
    ///   leaves a link that is up or being dialed alone, so there is one connection and it
    ///   is the one `addServer` made. Dialing it again with the older `TAKService.connect`
    ///   made a second (#156).
    /// - An endpoint that is already saved keeps its record: the enrollment is merged into it
    ///   (`TAKServer.mergingEnrollment`) and saved under its id, it is switched on if it was
    ///   off (the operator has just asked for it), and it becomes the active server. The
    ///   link that is up was made with the previous certificate, so it is let go and the
    ///   saved record is dialed, with the new one. `addServer` alone would have returned the
    ///   old record and dialed nothing.
    ///
    /// - Parameters:
    ///   - enrolled: the record the enrollment built (`CSREnrollmentConfiguration.makeServer`).
    ///   - apiPort: the Marti API port the link or the form gave, nil when it gave none.
    /// - Returns: the record as it is saved now, and whether it is new.
    @MainActor
    @discardableResult
    func adoptEnrolledServer(_ enrolled: TAKServer, apiPort: UInt16? = nil) -> EnrolledServerAdoption {
        let plan = EnrolledServerAdoption.plan(enrolled: enrolled, apiPort: apiPort, saved: servers)

        var saved: TAKServer
        if plan.isNew {
            saved = addServer(plan.server)
        } else {
            updateServer(plan.server)
            saved = plan.server
        }
        if !saved.enabled {
            enableServer(saved)
            saved = servers.first { $0.id == saved.id } ?? saved
        }
        setActiveServer(saved)

        if !plan.isNew {
            TAKService.shared.disconnectFromServer(serverId: saved.id)
        }
        TAKService.shared.connectToServer(saved)

        #if DEBUG
        print("🔐 Enrolled \(saved.displayName): \(plan.isNew ? "new server, dialed once" : "saved record updated, link dialed again with the new certificate")")
        #endif
        return EnrolledServerAdoption(server: saved, isNew: plan.isNew)
    }

    func updateServer(_ server: TAKServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
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
