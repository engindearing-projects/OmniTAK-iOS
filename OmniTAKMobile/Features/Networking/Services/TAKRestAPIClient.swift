//
//  TAKRestAPIClient.swift
//  OmniTAKMobile
//
//  TAK Server REST API client for data sync, missions, and data packages
//  Based on TAKAware's DataSyncManager and DataPackageManager patterns
//

import Foundation
import Security
import os

// MARK: - TAK API Configuration

struct TAKAPIConfiguration {
    let serverURL: String
    let secureAPIPort: Int
    let certificateId: UUID?
    /// Keychain alias of the client cert (= TAKServer.certificateName). CSR-
    /// enrolled identities live in the keychain under this label and are NOT
    /// tracked by CertificateManager, so the REST mTLS path must resolve them
    /// by name — same as the streaming path (DirectTCPSender). certificateId
    /// remains as a fallback for imported .p12 certs CertificateManager owns.
    let certificateName: String?
    /// Server trust policy for the REST session. Shares one precedence rule
    /// with the streaming path (TAKTLSTrustMode.resolve): explicit untrusted
    /// opt-in first, then the CA truststore, then system roots.
    var trustMode: TAKTLSTrustMode = .acceptUntrusted
    var timeout: TimeInterval = 30
    /// Stored credentials and the enrollment port (8446 by convention): the
    /// second route to the Marti API when the certificate port refuses the
    /// handshake or the entry has no certificate (#169).
    var username: String?
    var password: String?
    var enrollmentPort: Int = 8446

    var baseURL: String {
        "https://\(serverURL):\(secureAPIPort)"
    }

    var hasCredentials: Bool {
        !(username ?? "").isEmpty && !(password ?? "").isEmpty
    }

    init(serverURL: String, secureAPIPort: Int = 8443, certificateId: UUID? = nil, certificateName: String? = nil) {
        self.serverURL = serverURL
        self.secureAPIPort = secureAPIPort
        self.certificateId = certificateId
        self.certificateName = certificateName
    }

    init(from server: TAKServer) {
        self.serverURL = server.host
        // #114: Marti/Mission REST port is per-server; nil means the
        // conventional 8443 (servers saved before the field existed).
        self.secureAPIPort = Int(server.secureAPIPort ?? 8443)
        self.certificateName = server.certificateName
        self.username = server.username
        self.password = server.password
        self.enrollmentPort = Int(server.enrollmentPort ?? 8446)
        if let certName = server.certificateName,
           let cert = CertificateManager.shared.certificates.first(where: { $0.name == certName }) {
            self.certificateId = cert.id
        } else {
            self.certificateId = nil
        }
        // Server trust: the same precedence rule as the streaming path
        // (explicit untrusted opt-in > enrolled CA anchors > system roots).
        let anchors = server.caCertificateName.flatMap { DirectTCPSender.loadCACertificates(name: $0) }
        let mode = TAKTLSTrustMode.resolve(allowUntrustedTLS: server.allowUntrustedTLS, anchors: anchors)
        self.trustMode = mode
        // Observable on-device (idevicesyslog / Console): which policy this
        // REST session will run with, and why (#127). Locals only: the log
        // interpolation is an escaping autoclosure and must not capture self.
        let host = server.host
        let port = Int(server.secureAPIPort ?? 8443)
        let truststore = server.caCertificateName ?? "none"
        let anchorCount = anchors?.count ?? 0
        let optIn = server.allowUntrustedTLS
        Logger.takNetwork.info("REST trust mode for \(host, privacy: .public):\(port, privacy: .public) = \(mode.label, privacy: .public) (truststore=\(truststore, privacy: .public), anchors=\(anchorCount, privacy: .public), allowUntrusted=\(optIn, privacy: .public))")
    }
}

// MARK: - API Response Models

struct TAKMissionInfo: Codable, Identifiable {
    let name: String
    let description: String?
    let creatorUid: String?
    let createTime: Date?
    let passwordProtected: Bool
    let groups: [String]?
    let keywords: [String]?
    let uids: [TAKMissionUID]?
    let contents: [TAKMissionContent]?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, description, creatorUid, createTime, passwordProtected, groups, keywords, uids, contents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        creatorUid = try container.decodeIfPresent(String.self, forKey: .creatorUid)
        passwordProtected = try container.decodeIfPresent(Bool.self, forKey: .passwordProtected) ?? false
        groups = try container.decodeIfPresent([String].self, forKey: .groups)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        uids = try container.decodeIfPresent([TAKMissionUID].self, forKey: .uids)
        contents = try container.decodeIfPresent([TAKMissionContent].self, forKey: .contents)

        // Handle date parsing
        if let timeString = try container.decodeIfPresent(String.self, forKey: .createTime) {
            createTime = CoTXMLBuilder.timestampFormatter.date(from: timeString) ?? CoTXMLBuilder.timestampFormatterNoFraction.date(from: timeString)
        } else if let timeDouble = try? container.decode(Double.self, forKey: .createTime) {
            createTime = Date(timeIntervalSince1970: timeDouble / 1000)
        } else {
            createTime = nil
        }
    }
}

struct TAKMissionUID: Codable, Identifiable {
    let data: String
    let timestamp: Date?
    let creatorUid: String?
    let details: TAKMissionUIDDetails?

    var id: String { data }

    enum CodingKeys: String, CodingKey {
        case data, timestamp, creatorUid, details
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(String.self, forKey: .data)
        creatorUid = try container.decodeIfPresent(String.self, forKey: .creatorUid)
        details = try container.decodeIfPresent(TAKMissionUIDDetails.self, forKey: .details)

        if let timeString = try container.decodeIfPresent(String.self, forKey: .timestamp) {
            timestamp = CoTXMLBuilder.timestampFormatter.date(from: timeString) ?? CoTXMLBuilder.timestampFormatterNoFraction.date(from: timeString)
        } else if let timeDouble = try? container.decode(Double.self, forKey: .timestamp) {
            timestamp = Date(timeIntervalSince1970: timeDouble / 1000)
        } else {
            timestamp = nil
        }
    }
}

struct TAKMissionUIDDetails: Codable {
    let type: String?
    let callsign: String?
    let iconsetPath: String?
    let color: Int?
    let location: TAKLocation?
}

struct TAKLocation: Codable {
    let lat: Double
    let lon: Double
    let hae: Double?
}

struct TAKMissionContent: Codable, Identifiable {
    let hash: String
    let name: String
    let mimeType: String?
    let size: Int64?
    let submitter: String?
    let submissionTime: Date?
    let keywords: [String]?

    var id: String { hash }

    enum CodingKeys: String, CodingKey {
        case hash, name, mimeType, size, submitter, submissionTime, keywords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        name = try container.decode(String.self, forKey: .name)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        size = try container.decodeIfPresent(Int64.self, forKey: .size)
        submitter = try container.decodeIfPresent(String.self, forKey: .submitter)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)

        if let timeString = try container.decodeIfPresent(String.self, forKey: .submissionTime) {
            submissionTime = CoTXMLBuilder.timestampFormatter.date(from: timeString) ?? CoTXMLBuilder.timestampFormatterNoFraction.date(from: timeString)
        } else if let timeDouble = try? container.decode(Double.self, forKey: .submissionTime) {
            submissionTime = Date(timeIntervalSince1970: timeDouble / 1000)
        } else {
            submissionTime = nil
        }
    }
}

struct TAKDataPackageInfo: Codable, Identifiable {
    let hash: String
    let name: String
    let mimeType: String
    let size: Int64
    let submitter: String?
    let submissionTime: Date?
    let creator: String?
    let expiration: Date?
    let groups: [String]?
    let keywords: [String]?

    var id: String { hash }

    enum CodingKeys: String, CodingKey {
        case hash, name, mimeType, size, submitter, submissionTime, creator, expiration, groups, keywords
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        name = try container.decode(String.self, forKey: .name)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType) ?? "application/octet-stream"
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        submitter = try container.decodeIfPresent(String.self, forKey: .submitter)
        creator = try container.decodeIfPresent(String.self, forKey: .creator)
        groups = try container.decodeIfPresent([String].self, forKey: .groups)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)

        if let timeString = try container.decodeIfPresent(String.self, forKey: .submissionTime) {
            submissionTime = CoTXMLBuilder.timestampFormatter.date(from: timeString) ?? CoTXMLBuilder.timestampFormatterNoFraction.date(from: timeString)
        } else if let timeDouble = try? container.decode(Double.self, forKey: .submissionTime) {
            submissionTime = Date(timeIntervalSince1970: timeDouble / 1000)
        } else {
            submissionTime = nil
        }

        if let timeString = try container.decodeIfPresent(String.self, forKey: .expiration) {
            expiration = CoTXMLBuilder.timestampFormatter.date(from: timeString) ?? CoTXMLBuilder.timestampFormatterNoFraction.date(from: timeString)
        } else if let timeDouble = try? container.decode(Double.self, forKey: .expiration) {
            expiration = Date(timeIntervalSince1970: timeDouble / 1000)
        } else {
            expiration = nil
        }
    }
}

// MARK: - API Errors

enum TAKAPIError: LocalizedError {
    case invalidConfiguration
    case certificateNotFound
    case connectionFailed(TAKConnectionFailure)
    case authenticationRequired
    case forbidden
    case notFound(String)
    case serverError(Int, String?)
    case invalidResponse(String)
    case decodingFailed(String)
    case downloadFailed(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Invalid API configuration"
        case .certificateNotFound:
            return "Client certificate not found"
        case .connectionFailed(let failure):
            return failure.summary
        case .authenticationRequired:
            return "Authentication required"
        case .forbidden:
            return "Access forbidden"
        case .notFound(let resource):
            return "Resource not found: \(resource)"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message ?? "Unknown")"
        case .invalidResponse(let message):
            return "Invalid response: \(message)"
        case .decodingFailed(let message):
            return "Failed to decode response: \(message)"
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .uploadFailed(let message):
            return "Upload failed: \(message)"
        }
    }
}

extension TAKAPIError {
    /// The diagnosed transport failure, when this error is one (#169).
    var connectionFailure: TAKConnectionFailure? {
        if case .connectionFailed(let failure) = self { return failure }
        return nil
    }
}

extension TAKServer {
    /// A username and password are stored for this server (enrollment keeps
    /// them). They are the second route to the Marti API (#169).
    var hasStoredCredentials: Bool {
        !(username ?? "").isEmpty && !(password ?? "").isEmpty
    }
}

// MARK: - Auth mode

/// How the REST session authenticates to the Marti API (#169).
enum TAKRestAuthMode: Equatable {
    /// Mutual TLS on the certificate port (8443 by convention).
    case clientCertificate
    /// OAuth2 password grant on the enrollment port; TAK Server 5.x serves
    /// the Marti API there with `Authorization: Bearer`.
    case bearerToken(port: Int)
    /// HTTP Basic on the enrollment port (OpenTAKServer, taky).
    case basic(port: Int)

    var label: String {
        switch self {
        case .clientCertificate: return "client certificate"
        case .bearerToken(let port), .basic(let port): return "username and password (\(port))"
        }
    }

    var usesCredentials: Bool { self != .clientCertificate }

    func authorizationHeader(username: String?, password: String?, token: String?) -> String? {
        switch self {
        case .clientCertificate:
            return nil
        case .bearerToken:
            return token.map { "Bearer \($0)" }
        case .basic:
            guard let username, let password else { return nil }
            return "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        }
    }
}

// MARK: - TAK REST API Client

@MainActor
class TAKRestAPIClient: ObservableObject {
    static let shared = TAKRestAPIClient()

    @Published var isConnected: Bool = false
    @Published var lastError: String?
    /// The last request that never got an HTTP answer, explained (#169).
    @Published var lastFailure: TAKConnectionFailure?
    /// Which route the session is on; `connect(to:)` may move it off the
    /// certificate port (#169).
    @Published private(set) var authMode: TAKRestAuthMode = .clientCertificate
    /// What the username/password route said the last time it was tried
    /// and did not work (#169).
    private(set) var lastFallbackNote: String?
    private var bearerToken: String?

    private var urlSession: URLSession?
    private var configuration: TAKAPIConfiguration?
    /// Kept so a failed request can read the handshake report.
    private var tlsDelegate: TAKTLSSessionDelegate?

    init() {}

    // MARK: - Configuration

    func configure(with config: TAKAPIConfiguration) {
        self.configuration = config

        // Create URL session with client certificate
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = config.timeout
        sessionConfig.timeoutIntervalForResource = config.timeout * 4

        let delegate = TAKTLSSessionDelegate(
            trustMode: config.trustMode,
            certificateId: config.certificateId,
            certificateName: config.certificateName
        )
        urlSession = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
        tlsDelegate = delegate
        authMode = .clientCertificate
        bearerToken = nil
        lastFallbackNote = nil

        isConnected = true
        lastError = nil
        lastFailure = nil
    }

    func configure(from server: TAKServer) {
        let config = TAKAPIConfiguration(from: server)
        configure(with: config)
    }

    func disconnect() {
        urlSession?.invalidateAndCancel()
        urlSession = nil
        tlsDelegate = nil
        configuration = nil
        authMode = .clientCertificate
        bearerToken = nil
        isConnected = false
    }

    // MARK: - Connecting, with the credential fallback (#169)

    /// Configure for `server` and prove the Marti API answers. The
    /// certificate port is tried first when the entry has a certificate.
    /// When that is refused for certificate or handshake reasons and the
    /// entry has a username and password, the enrollment port is tried with
    /// those: an OAuth password grant first (TAK Server 5.x), HTTP Basic
    /// second (OpenTAKServer). An entry with credentials and no certificate
    /// goes straight to them. Throws the certificate-port failure, annotated
    /// with what the fallback said, when nothing works.
    @discardableResult
    func connect(to server: TAKServer) async throws -> TAKRestAuthMode {
        configure(from: server)
        guard let config = configuration else { throw TAKAPIError.invalidConfiguration }

        var certificateFailure: TAKConnectionFailure?
        if server.certificateName != nil {
            do {
                try await checkReachability()
                return authMode
            } catch let error as TAKAPIError {
                guard let failure = error.connectionFailure,
                      failure.allowsCredentialFallback, config.hasCredentials else {
                    throw error
                }
                certificateFailure = failure
            }
        } else if !config.hasCredentials {
            throw TAKAPIError.certificateNotFound
        }

        if let mode = await fallBackToCredentials(config: config) {
            return mode
        }
        let note = lastFallbackNote ?? "username and password did not work"
        if var failure = certificateFailure {
            failure.fallbackNote = note
            lastFailure = failure
            lastError = failure.summary
            throw TAKAPIError.connectionFailed(failure)
        }
        let failure = TAKConnectionFailure.credentialsRejected(host: config.serverURL, port: config.enrollmentPort, note: note)
        lastFailure = failure
        lastError = failure.summary
        throw TAKAPIError.connectionFailed(failure)
    }

    /// The enrollment port with the stored credentials. Returns the mode
    /// that reached the API, or nil with `lastFallbackNote` explaining why
    /// not. Leaves the session on the certificate route on failure.
    private func fallBackToCredentials(config: TAKAPIConfiguration) async -> TAKRestAuthMode? {
        let port = config.enrollmentPort
        let endpoint = "\(config.serverURL):\(port)"
        lastFallbackNote = nil
        Logger.takNetwork.info("REST fallback: trying username/password on \(endpoint, privacy: .public)")
        var notes: [String] = []

        // 1. OAuth password grant (TAK Server 5.x).
        switch await requestBearerToken(config: config) {
        case .token(let token):
            bearerToken = token
            authMode = .bearerToken(port: port)
            if let why = await probeCurrentRoute() {
                notes.append("OAuth token from \(endpoint) accepted but the API answered: \(why)")
            } else {
                Logger.takNetwork.notice("REST fallback: \(endpoint, privacy: .public) reached with an OAuth token")
                return authMode
            }
        case .unavailable(let why):
            notes.append("no OAuth on \(endpoint) (\(why))")
        case .rejected(let why):
            // Wrong credentials; Basic would not do better.
            notes.append("\(endpoint) rejected the username and password (\(why))")
            return endFallback(notes)
        }

        // 2. HTTP Basic (OpenTAKServer, taky).
        bearerToken = nil
        authMode = .basic(port: port)
        if let why = await probeCurrentRoute() {
            notes.append("Basic auth on \(endpoint): \(why)")
            return endFallback(notes)
        }
        Logger.takNetwork.notice("REST fallback: \(endpoint, privacy: .public) reached with Basic auth")
        return authMode
    }

    private func endFallback(_ notes: [String]) -> TAKRestAuthMode? {
        authMode = .clientCertificate
        bearerToken = nil
        let note = notes.joined(separator: "; ")
        lastFallbackNote = note
        Logger.takNetwork.error("REST fallback failed: \(note, privacy: .public)")
        return nil
    }

    /// nil when the API answered 200 on the current route; otherwise why not.
    private func probeCurrentRoute() async -> String? {
        do {
            _ = try await checkReachability()
            return nil
        } catch let error as TAKAPIError {
            if let failure = error.connectionFailure { return failure.summary }
            return error.errorDescription ?? String(describing: error)
        } catch {
            return error.localizedDescription
        }
    }

    private enum TokenResult {
        case token(String)
        case unavailable(String)
        case rejected(String)
    }

    /// `POST /oauth/token?grant_type=password` on the enrollment port. TAK
    /// Server answers 200 with `access_token`; a server without OAuth
    /// answers 404 (OpenTAKServer); wrong credentials get 400/401/403.
    private func requestBearerToken(config: TAKAPIConfiguration) async -> TokenResult {
        guard let session = urlSession, let username = config.username, let password = config.password else {
            return .unavailable("no credentials")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = config.serverURL
        components.port = config.enrollmentPort
        components.path = "/oauth/token"
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "password"),
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        guard let url = components.url else { return .unavailable("could not build the token URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unavailable("no HTTP response") }
            switch http.statusCode {
            case 200:
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let token = json["access_token"] as? String, !token.isEmpty {
                    return .token(token)
                }
                return .unavailable("HTTP 200 without an access_token")
            case 400, 401, 403:
                return .rejected("HTTP \(http.statusCode)")
            default:
                return .unavailable("HTTP \(http.statusCode)")
            }
        } catch {
            let handshake = tlsDelegate?.report.snapshot() ?? TAKTLSHandshakeSnapshot(trustMode: config.trustMode.label)
            let failure = TAKConnectionFailure(error: error, host: config.serverURL, port: config.enrollmentPort, handshake: handshake)
            Logger.takNetwork.error("REST fallback: token request failed: \(failure.details, privacy: .public)")
            return .unavailable(failure.summary)
        }
    }

    /// Base URL for the current route: the certificate port, or the
    /// enrollment port once the session fell back to credentials.
    private func baseURL(_ config: TAKAPIConfiguration) -> String {
        "https://\(config.serverURL):\(currentPort(config))"
    }

    private func currentPort(_ config: TAKAPIConfiguration) -> Int {
        switch authMode {
        case .clientCertificate: return config.secureAPIPort
        case .bearerToken(let port), .basic(let port): return port
        }
    }

    private func apply(auth request: inout URLRequest) {
        guard let config = configuration,
              let header = authMode.authorizationHeader(username: config.username, password: config.password, token: bearerToken) else { return }
        request.setValue(header, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Missions API

    /// Retrieve list of available missions
    func getMissions() async throws -> [TAKMissionInfo] {
        let data = try await get(endpoint: "/Marti/api/missions")
        return try decodeMissionsResponse(data)
    }

    /// Get detailed mission info
    func getMission(name: String, password: String? = nil) async throws -> TAKMissionInfo {
        let endpoint = "/Marti/api/missions/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)"
        var headers: [String: String]? = nil
        if let password = password {
            headers = ["MissionPassword": password]
        }

        let data = try await get(endpoint: endpoint, headers: headers)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // TAK API wraps response in "data" array
        if let response = try? decoder.decode(TAKAPIResponse<[TAKMissionInfo]>.self, from: data),
           let mission = response.data?.first {
            return mission
        }

        // Try direct decode
        if let mission = try? decoder.decode(TAKMissionInfo.self, from: data) {
            return mission
        }

        throw TAKAPIError.decodingFailed("Cannot decode mission response")
    }

    /// Create a new mission on the server.
    ///
    /// Endpoint shape (verified across TAK Server 5.7 + OpenTAKServer):
    ///   `PUT /Marti/api/missions/{name}?creatorUid={uid}&description={desc}`
    /// The mission name is encoded into the path; `creatorUid` is required;
    /// `description` is optional. The server replies with the standard wrapped
    /// `{ data: [TAKMissionInfo] }` envelope on success.
    @discardableResult
    func createMission(name: String, description: String?, creatorUid: String) async throws -> TAKMissionInfo {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TAKAPIError.invalidConfiguration
        }

        let encodedName = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        var endpoint = "/Marti/api/missions/\(encodedName)?creatorUid=\(creatorUid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? creatorUid)"
        if let description = description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
            let encodedDesc = description.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? description
            endpoint += "&description=\(encodedDesc)"
        }

        let data = try await put(endpoint: endpoint, body: nil)

        // Server response is the standard wrapped envelope; fall back to a
        // direct decode, and finally synthesize a minimal row if the body is
        // empty (some dialects 200 with no payload on create).
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let wrapped = try? decoder.decode(TAKAPIResponse<[TAKMissionInfo]>.self, from: data),
           let mission = wrapped.data?.first {
            return mission
        }
        if let mission = try? decoder.decode(TAKMissionInfo.self, from: data) {
            return mission
        }
        // Empty body on success — re-fetch to confirm and return.
        return try await getMission(name: trimmed)
    }

    /// Subscribe to a mission
    func subscribeMission(name: String, uid: String, password: String? = nil) async throws {
        var endpoint = "/Marti/api/missions/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)/subscription"
        endpoint += "?uid=\(uid)"
        var headers: [String: String]? = nil
        if let password = password {
            headers = ["MissionPassword": password]
        }

        _ = try await put(endpoint: endpoint, body: nil, headers: headers)
    }

    /// Unsubscribe from a mission
    func unsubscribeMission(name: String, uid: String) async throws {
        let endpoint = "/Marti/api/missions/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)/subscription?uid=\(uid)"
        _ = try await delete(endpoint: endpoint)
    }

    /// Get mission CoT content
    func getMissionContent(name: String, password: String? = nil) async throws -> String {
        let endpoint = "/Marti/api/missions/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)/cot"
        var headers: [String: String]? = nil
        if let password = password {
            headers = ["MissionPassword": password]
        }

        let data = try await get(endpoint: endpoint, headers: headers)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Data Packages API

    /// Retrieve list of available data packages
    func getDataPackages() async throws -> [TAKDataPackageInfo] {
        let data = try await get(endpoint: "/Marti/api/sync/search")
        return try decodeDataPackagesResponse(data)
    }

    /// Download a data package by hash
    func downloadDataPackage(hash: String, progressHandler: ((Double) -> Void)? = nil) async throws -> URL {
        guard let config = configuration else {
            throw TAKAPIError.invalidConfiguration
        }

        let endpoint = "/Marti/sync/content?hash=\(hash)"
        let urlString = baseURL(config) + endpoint

        guard let url = URL(string: urlString) else {
            throw TAKAPIError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        guard let session = urlSession else {
            throw TAKAPIError.invalidConfiguration
        }

        apply(auth: &request)
        let download: (URL, URLResponse)
        do {
            download = try await session.download(for: request)
        } catch {
            throw transportFailure(error)
        }
        let (localURL, response) = download

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TAKAPIError.invalidResponse("Not an HTTP response")
        }

        try handleHTTPResponse(httpResponse)

        // Move to permanent location
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let packagesPath = documentsPath.appendingPathComponent("DataPackages")

        if !FileManager.default.fileExists(atPath: packagesPath.path) {
            try FileManager.default.createDirectory(at: packagesPath, withIntermediateDirectories: true)
        }

        let destinationURL = packagesPath.appendingPathComponent("\(hash).zip")

        // Remove existing file if present
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.moveItem(at: localURL, to: destinationURL)

        return destinationURL
    }

    /// Upload a data package
    func uploadDataPackage(fileURL: URL, name: String, creatorUid: String) async throws {
        guard let config = configuration else {
            throw TAKAPIError.invalidConfiguration
        }

        let endpoint = "/Marti/sync/missionupload?creatorUid=\(creatorUid)&name=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)"
        let urlString = baseURL(config) + endpoint

        guard let url = URL(string: urlString) else {
            throw TAKAPIError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        // Create multipart form data
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        var body = Data()

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"assetfile\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-zip-compressed\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        guard let session = urlSession else {
            throw TAKAPIError.invalidConfiguration
        }

        apply(auth: &request)
        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw transportFailure(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TAKAPIError.invalidResponse("Not an HTTP response")
        }

        try handleHTTPResponse(httpResponse)
    }

    /// Download content by hash (for mission attachments)
    func downloadContent(hash: String) async throws -> Data {
        return try await get(endpoint: "/Marti/sync/content?hash=\(hash)")
    }

    // MARK: - Server Info API

    /// Get server version info
    func getServerVersion() async throws -> String {
        let data = try await get(endpoint: "/Marti/api/version")
        return String(data: data, encoding: .utf8) ?? "Unknown"
    }

    /// Get server config
    func getServerConfig() async throws -> Data {
        return try await get(endpoint: "/Marti/api/config")
    }

    /// Lightweight reachability + auth probe used by MissionSyncManager.
    /// `/Marti/api/version/config` is the one endpoint that returns 200 across
    /// every dialect we test (TAK Server 5.7, OpenTAKServer, taky) — unlike
    /// `/Marti/api/version`, which OpenTAKServer 404s. mTLS failures, bad certs,
    /// or unreachable hosts surface as a thrown error here.
    @discardableResult
    func checkReachability() async throws -> Data {
        return try await get(endpoint: "/Marti/api/version/config")
    }

    // MARK: - HTTP Methods

    private func get(endpoint: String, headers: [String: String]? = nil) async throws -> Data {
        guard let config = configuration else {
            throw TAKAPIError.invalidConfiguration
        }

        let urlString = baseURL(config) + endpoint
        guard let url = URL(string: urlString) else {
            throw TAKAPIError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        apply(auth: &request)
        return try await performRequest(request)
    }

    private func put(endpoint: String, body: Data?, headers: [String: String]? = nil) async throws -> Data {
        guard let config = configuration else {
            throw TAKAPIError.invalidConfiguration
        }

        let urlString = baseURL(config) + endpoint
        guard let url = URL(string: urlString) else {
            throw TAKAPIError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        apply(auth: &request)
        return try await performRequest(request)
    }

    private func post(endpoint: String, body: Data?) async throws -> Data {
        guard let config = configuration else {
            throw TAKAPIError.invalidConfiguration
        }

        let urlString = baseURL(config) + endpoint
        guard let url = URL(string: urlString) else {
            throw TAKAPIError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        apply(auth: &request)
        return try await performRequest(request)
    }

    private func delete(endpoint: String) async throws -> Data {
        guard let config = configuration else {
            throw TAKAPIError.invalidConfiguration
        }

        let urlString = baseURL(config) + endpoint
        guard let url = URL(string: urlString) else {
            throw TAKAPIError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        apply(auth: &request)
        return try await performRequest(request)
    }

    private func performRequest(_ request: URLRequest) async throws -> Data {
        guard let session = urlSession else {
            throw TAKAPIError.invalidConfiguration
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw TAKAPIError.invalidResponse("Not an HTTP response")
            }

            try handleHTTPResponse(httpResponse)

            return data
        } catch let error as TAKAPIError {
            lastError = error.errorDescription
            throw error
        } catch {
            throw transportFailure(error)
        }
    }

    /// Turn a URLSession transport error into a diagnosable failure: which
    /// host and port, what the system reported, and what the TLS delegate
    /// saw during the handshake (server trust decision, whether the server
    /// asked for a client certificate, whether one was presented). Logged in
    /// full so a device log or the in-app diagnostics show the cause (#169).
    private func transportFailure(_ error: Error) -> TAKAPIError {
        let handshake = tlsDelegate?.report.snapshot()
            ?? TAKTLSHandshakeSnapshot(trustMode: configuration?.trustMode.label ?? "unknown")
        let failure = TAKConnectionFailure(
            error: error,
            host: configuration?.serverURL ?? "?",
            port: configuration.map(currentPort) ?? 0,
            handshake: handshake
        )
        lastError = failure.summary
        lastFailure = failure
        Logger.takNetwork.error("REST transport failure: \(failure.details, privacy: .public)")
        return .connectionFailed(failure)
    }

    private func handleHTTPResponse(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401:
            throw TAKAPIError.authenticationRequired
        case 403:
            throw TAKAPIError.forbidden
        case 404:
            throw TAKAPIError.notFound("Resource")
        default:
            throw TAKAPIError.serverError(response.statusCode, nil)
        }
    }

    // MARK: - Response Decoding

    private func decodeMissionsResponse(_ data: Data) throws -> [TAKMissionInfo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // TAK API wraps response
        if let response = try? decoder.decode(TAKAPIResponse<[TAKMissionInfo]>.self, from: data),
           let missions = response.data {
            return missions
        }

        // Try direct array decode
        if let missions = try? decoder.decode([TAKMissionInfo].self, from: data) {
            return missions
        }

        throw TAKAPIError.decodingFailed("Cannot decode missions response")
    }

    private func decodeDataPackagesResponse(_ data: Data) throws -> [TAKDataPackageInfo] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // TAK API wraps response
        if let response = try? decoder.decode(TAKAPIResponse<[TAKDataPackageInfo]>.self, from: data),
           let packages = response.data {
            return packages
        }

        // Try "results" key
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]] {
            let resultsData = try JSONSerialization.data(withJSONObject: results)
            return try decoder.decode([TAKDataPackageInfo].self, from: resultsData)
        }

        // Try direct array decode
        if let packages = try? decoder.decode([TAKDataPackageInfo].self, from: data) {
            return packages
        }

        throw TAKAPIError.decodingFailed("Cannot decode data packages response")
    }
}

// MARK: - API Response Wrapper

struct TAKAPIResponse<T: Codable>: Codable {
    let version: String?
    let type: String?
    let data: T?
    let messages: [String]?
    let nodeId: String?
}

// The URLSession TLS delegate lives in TAKTLSSessionDelegate.swift —
// one shared implementation for REST, CSR enrollment, and deep-link
// enrollment sessions.
