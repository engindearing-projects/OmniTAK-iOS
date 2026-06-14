//
//  DeepLinkHandler.swift
//  OmniTAKMobile
//
//  Handles TAK deep links for enrollment (QR code scanning / ATAK links)
//  URL format: tak://com.atakmap.app/enroll?host=server.io&username=user&token=JWT
//

import Foundation
import Combine

// MARK: - Deep Link Types

enum TAKDeepLink {
    case enrollment(EnrollmentDeepLink)
    case passwordEnrollment(PasswordEnrollmentDeepLink)
    case connect(ConnectDeepLink)
    case configProfile(ConfigProfile)
    case unknown(URL)

    static func parse(url: URL) -> TAKDeepLink? {
        // Accept tak:// (our scheme), plus atak:// / omnitak:// so a single
        // QR/link onboards both iOS and Android (Android registers atak/omnitak).
        guard let scheme = url.scheme?.lowercased(),
              scheme == "tak" || scheme == "atak" || scheme == "omnitak" else { return nil }

        // omnitak://profile?d=<payload> — config profile QR
        if scheme == "omnitak", url.host?.lowercased() == "profile" {
            if let profile = try? ProfileQRCodec.decode(url: url) {
                return .configProfile(profile)
            }
            return .unknown(url)
        }

        let path = url.path.lowercased()
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hasToken = queryItems.contains { $0.name.lowercased() == "token" && $0.value != nil }
        let hasPassword = queryItems.contains {
            ($0.name.lowercased() == "password" || $0.name.lowercased() == "pw") && !($0.value ?? "").isEmpty
        }

        // Path contains "enroll" AND has a token → the standard ATAK / TAK
        // Server / ArgusTAK enrollment deep link:
        //   tak://com.atakmap.app/enroll?host=&username=&token=
        // (also covers OpenTAKServer's token form). Driven via CSREnrollment.
        if path.contains("enroll") && hasToken {
            if let enrollment = EnrollmentDeepLink.parse(url: url) {
                return .enrollment(enrollment)
            }
        }

        // Username + password → CSR auto-enroll (standard TAK Server quick connect).
        // This is the "easy connect" path for username/password servers: scan a QR
        // and the app enrolls a client cert, then connects — no manual form.
        if hasPassword {
            if let pwEnroll = PasswordEnrollmentDeepLink.parse(url: url) {
                return .passwordEnrollment(pwEnroll)
            }
        }

        // Otherwise try simple connect (host + optional port/protocol)
        if let connect = ConnectDeepLink.parse(url: url) {
            return .connect(connect)
        }

        return .unknown(url)
    }
}

// MARK: - Simple Connect Deep Link (TCP/UDP without auth)

struct ConnectDeepLink {
    let host: String
    let port: Int
    let protocolType: String  // tcp, udp, ssl
    let name: String?

    static func parse(url: URL) -> ConnectDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        var params: [String: String] = [:]

        for item in queryItems {
            if let value = item.value {
                params[item.name.lowercased()] = value
            }
        }

        // Host is required
        guard let host = params["host"] else {
            print("[DeepLink] Connect: Missing required 'host' parameter")
            return nil
        }

        // Port defaults to 8087 for TCP (common TAK default)
        let port = params["port"].flatMap { Int($0) } ?? 8087

        // Protocol defaults to TCP
        let protocolType = params["protocol"]?.lowercased() ?? "tcp"

        // Optional friendly name
        let name = params["name"]

        return ConnectDeepLink(
            host: host,
            port: port,
            protocolType: protocolType,
            name: name
        )
    }
}

// MARK: - Enrollment Deep Link
//
// The standard ATAK enrollment deep link / QR:
//   tak://com.atakmap.app/enroll?host=<host>[:port]&username=<u>&token=<t>
// The host is frequently URL-encoded, e.g. host=argustak.com%3A8089 (the
// %3A is a ':' separating host:port). URLComponents percent-decodes query
// values for us, so we split any embedded ":port" off the host here and
// surface a bare `host` plus the embedded `port`. The one-time `token` is
// the CSR-enrollment credential — TAK servers (and ATAK itself) Basic-auth
// the signClient call with username + this token, so downstream it is used
// as the password to the standard CSREnrollmentService flow.

struct EnrollmentDeepLink {
    let host: String          // bare hostname (any embedded :port stripped)
    let username: String
    let token: String
    let port: Int?            // streaming port — from host:port or &port=
    let enrollmentPort: Int?  // CSR enrollment port — from &enrollmentport=

    static func parse(url: URL) -> EnrollmentDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let queryItems = components.queryItems ?? []
        var params: [String: String] = [:]

        for item in queryItems {
            if let value = item.value {
                params[item.name.lowercased()] = value
            }
        }

        // Required parameters
        guard let rawHost = params["host"],
              let username = params["username"],
              let token = params["token"],
              !rawHost.isEmpty, !username.isEmpty, !token.isEmpty else {
            print("[DeepLink] Missing required parameters: host, username, or token")
            return nil
        }

        // Split host:port (host may arrive URL-encoded as "host%3Aport",
        // already decoded to "host:port" by URLComponents).
        let (bareHost, embeddedPort) = splitHostPort(rawHost)

        // Explicit &port= wins over a port embedded in the host string.
        let port = params["port"].flatMap { Int($0) } ?? embeddedPort
        let enrollmentPort = (params["enrollmentport"] ?? params["enrollport"]).flatMap { Int($0) }

        return EnrollmentDeepLink(
            host: bareHost,
            username: username,
            token: token,
            port: port,
            enrollmentPort: enrollmentPort
        )
    }

    /// Split a "host" or "host:port" string into its components. Tolerates a
    /// stray scheme prefix and a trailing path. Returns the bare host and the
    /// parsed port (nil when none / unparseable).
    static func splitHostPort(_ raw: String) -> (host: String, port: Int?) {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let schemeRange = s.range(of: "://") {
            s = String(s[schemeRange.upperBound...])
        }
        if let slash = s.firstIndex(of: "/") {
            s = String(s[..<slash])
        }
        guard let colon = s.lastIndex(of: ":"),
              let p = Int(s[s.index(after: colon)...]) else {
            return (s, nil)
        }
        return (String(s[..<colon]), p)
    }
}

// MARK: - Password Enrollment Deep Link (standard TAK CSR auto-enroll)

struct PasswordEnrollmentDeepLink {
    let host: String
    let username: String
    let password: String
    let port: Int?            // streaming port, default 8089
    let enrollmentPort: Int?  // CSR enrollment port, default 8446
    let trustSelfSigned: Bool // default true (accepts any cert during enrollment)
    let name: String?

    static func parse(url: URL) -> PasswordEnrollmentDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        var params: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value {
                params[item.name.lowercased()] = value
            }
        }

        guard let host = params["host"],
              let username = params["username"] ?? params["user"],
              let password = params["password"] ?? params["pw"],
              !host.isEmpty, !username.isEmpty, !password.isEmpty else {
            print("[DeepLink] Password enroll: missing host, username, or password")
            return nil
        }

        let port = (params["port"]).flatMap { Int($0) }
        let enrollmentPort = (params["enrollmentport"] ?? params["enrollport"]).flatMap { Int($0) }
        // Default to trust-all during enrollment so it works for both
        // self-signed and publicly-trusted (Let's Encrypt) endpoints.
        // Override with trust=ca / trustselfsigned=false for strict CA validation.
        let trustRaw = (params["trustselfsigned"] ?? params["trust"])?.lowercased()
        let trustSelfSigned: Bool
        switch trustRaw {
        case "false", "ca", "system", "0", "no": trustSelfSigned = false
        default: trustSelfSigned = true
        }

        return PasswordEnrollmentDeepLink(
            host: host,
            username: username,
            password: password,
            port: port,
            enrollmentPort: enrollmentPort,
            trustSelfSigned: trustSelfSigned,
            name: params["name"]
        )
    }
}

// MARK: - Deep Link Handler

class DeepLinkHandler: ObservableObject {
    static let shared = DeepLinkHandler()

    @Published var isProcessing = false
    @Published var lastError: String?
    @Published var showEnrollmentSuccess = false
    @Published var enrolledServerName: String?

    /// Non-nil while a config-profile deep link is awaiting user confirmation
    /// (mirroring the scanner path: show ProfileImportPreviewView, apply only
    /// on confirm). Set by processConfigProfile; cleared by confirmPendingProfile.
    @Published var pendingDeepLinkProfile: ConfigProfile?

    // CSREnrollmentService owns its own (untrusted-bootstrapping) URLSession,
    // so both the token-enroll and password-enroll deep-link paths reuse it.
    private let csrEnrollmentService = CSREnrollmentService()

    // MARK: - Handle Incoming URL

    func handleURL(_ url: URL) {
        print("[DeepLink] Received URL: \(url.absoluteString)")

        guard let deepLink = TAKDeepLink.parse(url: url) else {
            print("[DeepLink] Could not parse URL")
            lastError = "Invalid TAK URL"
            return
        }

        switch deepLink {
        case .enrollment(let enrollmentLink):
            Task {
                await processEnrollment(enrollmentLink)
            }
        case .passwordEnrollment(let pwLink):
            Task {
                await processPasswordEnrollment(pwLink)
            }
        case .connect(let connectLink):
            processSimpleConnect(connectLink)
        case .configProfile(let profile):
            processConfigProfile(profile)
        case .unknown(let unknownURL):
            print("[DeepLink] Unknown deep link type: \(unknownURL)")
            lastError = "Unknown link type"
        }
    }

    // MARK: - Password CSR Enrollment (standard TAK quick connect)

    private func processPasswordEnrollment(_ link: PasswordEnrollmentDeepLink) async {
        await MainActor.run {
            isProcessing = true
            lastError = nil
        }

        print("[DeepLink] Starting password CSR enrollment for \(link.username)@\(link.host)")

        let config = CSREnrollmentConfiguration(
            serverHost: link.host,
            serverPort: link.port ?? 8089,
            enrollmentPort: link.enrollmentPort ?? 8446,
            username: link.username,
            password: link.password,
            useSSL: true,
            trustSelfSignedCerts: link.trustSelfSigned
        )

        do {
            // enrollWithCSR performs the full CSR flow and registers the
            // server with ServerManager. We then connect using the stored cert.
            let server = try await csrEnrollmentService.enrollWithCSR(config: config)

            await MainActor.run {
                ServerManager.shared.setActiveServer(server)
                TAKService.shared.connect(
                    host: server.host,
                    port: server.port,
                    protocolType: server.protocolType,
                    useTLS: server.useTLS,
                    certificateName: server.certificateName,
                    certificatePassword: server.certificatePassword,
                    // Pin the stream to the CA chain enrolled above so the
                    // server certificate is validated, not blindly accepted.
                    caCertificateName: server.caCertificateName,
                    caCertificatePassword: server.caCertificatePassword,
                    allowUntrustedTLS: server.allowUntrustedTLS
                )
                isProcessing = false
                enrolledServerName = server.name
                showEnrollmentSuccess = true
                print("[DeepLink] ✅ Password enrollment successful: \(server.name)")
            }
        } catch {
            await MainActor.run {
                isProcessing = false
                lastError = error.localizedDescription
                print("[DeepLink] ❌ Password enrollment failed: \(error)")
            }
        }
    }

    // MARK: - Config Profile Import

    /// Stage the profile for user confirmation — identical to the scanner path.
    /// The app's root view observes `pendingDeepLinkProfile` and presents
    /// ProfileImportPreviewView; call `confirmPendingProfile(_:confirmed:)`
    /// from the preview's onConfirm callback.
    private func processConfigProfile(_ profile: ConfigProfile) {
        print("[DeepLink] Staging config profile for confirmation: \(profile.name)")
        pendingDeepLinkProfile = profile
    }

    /// Called by the confirmation UI (ProfileImportPreviewView's onConfirm).
    /// If confirmed, stores and applies the profile; either way clears the pending state.
    func confirmPendingProfile(_ profile: ConfigProfile, confirmed: Bool) {
        pendingDeepLinkProfile = nil
        guard confirmed else { return }
        ProfileStore.shared.addProfile(profile)
        ProfileStore.shared.apply(profile)
        enrolledServerName = profile.name
        showEnrollmentSuccess = true
        print("[DeepLink] ✅ Config profile '\(profile.name)' imported and applied")
    }

    // MARK: - Simple TCP/UDP Connect (No Auth)

    private func processSimpleConnect(_ connect: ConnectDeepLink) {
        print("[DeepLink] Simple connect: \(connect.host):\(connect.port) via \(connect.protocolType)")

        isProcessing = true
        lastError = nil

        // Create server config
        let serverName = connect.name ?? "\(connect.host):\(connect.port)"
        let useTLS = connect.protocolType == "ssl" || connect.protocolType == "tls"

        let server = TAKServer(
            id: UUID(),
            name: serverName,
            host: connect.host,
            port: UInt16(connect.port),
            protocolType: connect.protocolType,
            useTLS: useTLS,
            isDefault: false,
            enabled: true,
            certificateName: nil,  // No cert for simple TCP
            certificatePassword: nil
        )

        // Add and connect
        ServerManager.shared.addServer(server)
        ServerManager.shared.setActiveServer(server)

        // Connect immediately
        TAKService.shared.connect(
            host: server.host,
            port: server.port,
            protocolType: server.protocolType,
            useTLS: server.useTLS,
            certificateName: nil,
            certificatePassword: nil
        )

        isProcessing = false
        enrolledServerName = serverName
        showEnrollmentSuccess = true

        print("[DeepLink] ✅ Connected to \(serverName) via \(connect.protocolType.uppercased())")
    }

    // MARK: - Token-Based Enrollment (standard ATAK enrollment QR)
    //
    // tak://com.atakmap.app/enroll?host=&username=&token= → drive the SAME
    // CSREnrollmentService used by the manual "Quick Connect" form, then add
    // the server and connect exactly like SimpleEnrollView does on success.
    // The one-time `token` is supplied as the Basic-auth password to the
    // signClient endpoint (this is how ATAK / TAK Server enroll).

    private func processEnrollment(_ enrollment: EnrollmentDeepLink) async {
        await MainActor.run {
            isProcessing = true
            lastError = nil
        }

        // Streaming (CoT) port: explicit value or the TAK SSL default 8089.
        // Enrollment (CSR signClient) port: explicit value or the TAK
        // default 8446 — distinct from the streaming port. NOTE: ArgusTAK
        // and other reverse-proxied deployments sometimes terminate the
        // enrollment API on the same 8089 host:port; if 8446 fails on device,
        // an &enrollmentport= override (or a future host probe) is the lever.
        let streamingPort = enrollment.port ?? 8089
        let enrollPort = enrollment.enrollmentPort ?? 8446

        print("[DeepLink] CSR enrollment for \(enrollment.username)@\(enrollment.host) " +
              "(stream \(streamingPort), enroll \(enrollPort))")

        let config = CSREnrollmentConfiguration(
            serverHost: enrollment.host,
            serverPort: streamingPort,
            enrollmentPort: enrollPort,
            username: enrollment.username,
            password: enrollment.token,
            useSSL: true,
            // Bootstrap trust from the server during enrollment so both
            // self-signed and publicly-trusted (Let's Encrypt) endpoints work;
            // the resulting stream is still pinned to the enrolled CA chain.
            trustSelfSignedCerts: true
        )

        do {
            // enrollWithCSR runs the full CSR flow and registers the server
            // with ServerManager. We then connect using the stored cert,
            // validating against the CA chain it enrolled.
            let server = try await csrEnrollmentService.enrollWithCSR(config: config)

            await MainActor.run {
                ServerManager.shared.setActiveServer(server)
                TAKService.shared.connect(
                    host: server.host,
                    port: server.port,
                    protocolType: server.protocolType,
                    useTLS: server.useTLS,
                    certificateName: server.certificateName,
                    certificatePassword: server.certificatePassword,
                    caCertificateName: server.caCertificateName,
                    caCertificatePassword: server.caCertificatePassword,
                    allowUntrustedTLS: server.allowUntrustedTLS
                )
                isProcessing = false
                enrolledServerName = server.name
                showEnrollmentSuccess = true
                print("[DeepLink] ✅ Enrollment successful: \(server.name)")
            }

        } catch {
            await MainActor.run {
                isProcessing = false
                lastError = error.localizedDescription
                print("[DeepLink] ❌ Enrollment failed: \(error)")
            }
        }
    }
}

