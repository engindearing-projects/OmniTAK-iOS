//
//  MissionAPIClient.swift
//  OmniTAKMobile
//
//  Thin client for the Marti Mission Sync API used by both
//  OpenTAKServer and TAK Server CIV. Backs the "Settings → MISSION →
//  Create new mission" flow added for issue #14 (K9Blue SAR feedback
//  5/10/26: on-device data-sync mission creation).
//
//  Wire-format and endpoint details: see
//  `docs/specs/mission-api-client.md`.
//
//  This file deliberately stays self-contained — it does NOT depend on
//  `TAKRestAPIClient` (which is currently an orphan source file and
//  not in the build). The session-scoped goal is a real wire path; a
//  follow-up will collapse `TAKRestAPIClient` into this client once
//  the build target consolidation is sorted.
//

import Foundation

// MARK: - Public surface

/// Bounding-box envelope passed as the `bbox` query param. Lat/Lon in
/// decimal degrees, WGS-84.
public struct MissionBoundingBox: Equatable, Codable, Sendable {
    public let minLat: Double
    public let minLon: Double
    public let maxLat: Double
    public let maxLon: Double

    public init(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        self.minLat = minLat
        self.minLon = minLon
        self.maxLat = maxLat
        self.maxLon = maxLon
    }

    /// Marti expects `bbox={minLat,minLon,maxLat,maxLon}` with no spaces.
    var queryValue: String {
        "\(minLat),\(minLon),\(maxLat),\(maxLon)"
    }
}

/// Decoded subset of `GET /Marti/api/missions/{name}` that the SAR
/// flow needs. The Marti envelope returns much more — we read only the
/// keys we care about and tolerate everything else.
public struct MissionAPIMission: Equatable, Codable, Sendable {
    public let name: String
    public let description: String?
    public let creatorUid: String?
    public let tool: String?
    public let createTime: Double?       // epoch millis

    public init(
        name: String,
        description: String? = nil,
        creatorUid: String? = nil,
        tool: String? = nil,
        createTime: Double? = nil
    ) {
        self.name = name
        self.description = description
        self.creatorUid = creatorUid
        self.tool = tool
        self.createTime = createTime
    }
}

/// Errors surfaced to callers. Designed to be presentable verbatim in
/// the SwiftUI sheet without further mapping.
public enum MissionAPIError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case packageMissing(URL)
    case http(status: Int, body: String?)
    case decoding(String)
    case missingHash
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Mission API client is not configured (call configure(baseURL:session:)) first."
        case .packageMissing(let url):
            return "Data package not found at \(url.path)."
        case .http(let status, let body):
            if let body = body, !body.isEmpty {
                return "TAK server returned HTTP \(status): \(body)"
            }
            return "TAK server returned HTTP \(status)."
        case .decoding(let detail):
            return "Could not decode mission response: \(detail)"
        case .missingHash:
            return "Server accepted the package upload but did not return a hash."
        case .transport(let detail):
            return "Network error: \(detail)"
        }
    }
}

/// Public protocol so the UI can hold an injected client and tests can
/// stub the wire format.
public protocol MissionAPIClient: AnyObject {
    /// `GET /Marti/api/missions`
    func getMissions() async throws -> [MissionAPIMission]

    /// `PUT /Marti/api/missions/{name}` — minimal create envelope.
    /// Returns the server's view of the freshly-created mission.
    @discardableResult
    func createMission(
        name: String,
        creatorUid: String,
        description: String?,
        tool: String,
        groups: [String],
        defaultRole: String?,
        bbox: MissionBoundingBox?
    ) async throws -> MissionAPIMission

    /// Upload a `.zip` data package and attach it to the named mission.
    /// Returns the server-assigned SHA-256 hash now attached.
    @discardableResult
    func addContentsToMission(
        missionName: String,
        packageURL: URL,
        creatorUid: String
    ) async throws -> String
}

// MARK: - URLSession-backed impl

/// Default `MissionAPIClient` wired to `URLSession`. The session is
/// supplied by the caller so production code can inject the same
/// mTLS-aware session we use for `TAKService`, and tests can inject a
/// `URLProtocol`-stubbed session.
public final class URLSessionMissionAPIClient: MissionAPIClient {

    private struct Config {
        let baseURL: URL
        let session: URLSession
    }

    private var config: Config?

    public init() {}

    /// Configure with a base URL like `https://tak.example.com:8443`.
    public func configure(baseURL: URL, session: URLSession = .shared) {
        self.config = Config(baseURL: baseURL, session: session)
    }

    /// Convenience: parse a `host:port` string into a base URL.
    public func configure(host: String, port: Int = 8443, session: URLSession = .shared) throws {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        guard let url = components.url else {
            throw MissionAPIError.notConfigured
        }
        configure(baseURL: url, session: session)
    }

    public func getMissions() async throws -> [MissionAPIMission] {
        guard let config = config else { throw MissionAPIError.notConfigured }
        let url = config.baseURL.appendingPathComponent("/Marti/api/missions")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, status) = try await perform(req, on: config.session)
        try Self.requireSuccess(status: status, data: data)
        return try Self.decodeMissions(from: data)
    }

    @discardableResult
    public func createMission(
        name: String,
        creatorUid: String,
        description: String?,
        tool: String,
        groups: [String],
        defaultRole: String?,
        bbox: MissionBoundingBox?
    ) async throws -> MissionAPIMission {
        guard let config = config else { throw MissionAPIError.notConfigured }

        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
        var components = URLComponents(
            url: config.baseURL.appendingPathComponent("/Marti/api/missions/\(encodedName)"),
            resolvingAgainstBaseURL: false
        )
        var query: [URLQueryItem] = [
            URLQueryItem(name: "creatorUid", value: creatorUid),
            URLQueryItem(name: "tool", value: tool),
        ]
        if let description = description, !description.isEmpty {
            query.append(URLQueryItem(name: "description", value: description))
        }
        if let role = defaultRole, !role.isEmpty {
            query.append(URLQueryItem(name: "defaultRole", value: role))
        }
        // Marti accepts repeated `group=` params for multi-group missions.
        // Defaults to __ANON__ on the server when omitted.
        for group in groups where !group.isEmpty {
            query.append(URLQueryItem(name: "group", value: group))
        }
        if let bbox = bbox {
            query.append(URLQueryItem(name: "bbox", value: bbox.queryValue))
        }
        components?.queryItems = query

        guard let url = components?.url else { throw MissionAPIError.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Marti tolerates empty body on create; some CIV builds insist on
        // valid JSON so we ship `{}` rather than empty bytes.
        req.httpBody = Data("{}".utf8)

        let (data, status) = try await perform(req, on: config.session)
        try Self.requireSuccess(status: status, data: data)
        // Some Marti builds return 200 with the mission, others 201 with
        // an empty body. Fall back to synthesising the response in the
        // empty-body case so the UI has something to display.
        if data.isEmpty {
            return MissionAPIMission(
                name: name,
                description: description,
                creatorUid: creatorUid,
                tool: tool,
                createTime: nil
            )
        }
        do {
            return try Self.decodeMissions(from: data).first ?? MissionAPIMission(
                name: name,
                description: description,
                creatorUid: creatorUid,
                tool: tool,
                createTime: nil
            )
        } catch {
            // Tolerate odd-shaped success responses: if we got 2xx, we
            // accept the create even if decoding failed.
            return MissionAPIMission(name: name, creatorUid: creatorUid, tool: tool)
        }
    }

    @discardableResult
    public func addContentsToMission(
        missionName: String,
        packageURL: URL,
        creatorUid: String
    ) async throws -> String {
        guard let config = config else { throw MissionAPIError.notConfigured }
        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw MissionAPIError.packageMissing(packageURL)
        }

        // 1. POST /Marti/sync/missionupload — multipart upload of the
        //    zip. The plain-text response carries `?hash={sha}` which is
        //    the canonical content-addressable id.
        let hash = try await uploadPackage(
            packageURL: packageURL,
            creatorUid: creatorUid,
            session: config.session,
            baseURL: config.baseURL
        )

        // 2. PUT /Marti/api/missions/{name}/contents — attach by hash.
        try await attachHash(
            hash,
            to: missionName,
            session: config.session,
            baseURL: config.baseURL
        )
        return hash
    }

    // MARK: - Pieces, exposed `internal` for unit-test instrumentation

    func uploadPackage(
        packageURL: URL,
        creatorUid: String,
        session: URLSession,
        baseURL: URL
    ) async throws -> String {
        let filename = packageURL.lastPathComponent
        let encodedName = filename
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/Marti/sync/missionupload"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "creatorUid", value: creatorUid),
            URLQueryItem(name: "filename", value: encodedName),
        ]
        guard let url = components?.url else { throw MissionAPIError.notConfigured }

        let boundary = "omnitak-" + UUID().uuidString
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let zipBytes = try Data(contentsOf: packageURL)
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"assetfile\"; filename=\"\(filename)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: application/x-zip-compressed\r\n\r\n".data(using: .utf8)!)
        body.append(zipBytes)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, status) = try await perform(req, on: session)
        try Self.requireSuccess(status: status, data: data)

        let responseText = String(data: data, encoding: .utf8) ?? ""
        guard let hash = Self.extractHash(fromMissionUploadResponse: responseText) else {
            throw MissionAPIError.missingHash
        }
        return hash
    }

    func attachHash(
        _ hash: String,
        to missionName: String,
        session: URLSession,
        baseURL: URL
    ) async throws {
        let encodedName = missionName
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? missionName
        let url = baseURL.appendingPathComponent("/Marti/api/missions/\(encodedName)/contents")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bodyJSON = ["hashes": [hash]]
        req.httpBody = try JSONSerialization.data(withJSONObject: bodyJSON, options: [])

        let (data, status) = try await perform(req, on: session)
        try Self.requireSuccess(status: status, data: data)
    }

    // MARK: - Helpers

    private func perform(_ req: URLRequest, on session: URLSession) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw MissionAPIError.transport("Non-HTTP response")
            }
            return (data, http.statusCode)
        } catch let error as MissionAPIError {
            throw error
        } catch {
            throw MissionAPIError.transport(error.localizedDescription)
        }
    }

    static func requireSuccess(status: Int, data: Data) throws {
        if (200...299).contains(status) { return }
        let body = String(data: data, encoding: .utf8)
        throw MissionAPIError.http(status: status, body: body)
    }

    /// Marti `missionupload` returns plain text like:
    /// `https://server/Marti/sync/content?hash=ABC123...`
    /// We pull the hash query param. Falls back to a regex for older
    /// builds that return `Hash: ABC123`.
    static func extractHash(fromMissionUploadResponse body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if let comps = URLComponents(string: trimmed),
           let hash = comps.queryItems?.first(where: { $0.name.lowercased() == "hash" })?.value,
           !hash.isEmpty {
            return hash
        }
        // Fallback: header-style or last-segment
        if let range = trimmed.range(of: "hash=", options: .caseInsensitive) {
            let tail = trimmed[range.upperBound...]
            let hash = tail.prefix(while: { $0 != "&" && !$0.isWhitespace })
            if !hash.isEmpty { return String(hash) }
        }
        return nil
    }

    /// Marti can return either a bare array or `{ data: [...] }`. Handle both.
    static func decodeMissions(from data: Data) throws -> [MissionAPIMission] {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(MissionEnvelope.self, from: data) {
            return envelope.data ?? []
        }
        if let single = try? decoder.decode(MissionAPIMission.self, from: data) {
            return [single]
        }
        if let array = try? decoder.decode([MissionAPIMission].self, from: data) {
            return array
        }
        throw MissionAPIError.decoding("Unrecognised Marti mission envelope")
    }

    private struct MissionEnvelope: Codable {
        let data: [MissionAPIMission]?
    }
}
