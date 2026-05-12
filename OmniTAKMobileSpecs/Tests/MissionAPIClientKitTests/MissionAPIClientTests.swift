//
//  MissionAPIClientTests.swift
//  OmniTAKMobileSpecs / MissionAPIClientKitTests
//
//  Covers the two-step create-and-publish flow added for issue #14
//  (SAR: Mission/data-sync creation flow from device).
//
//  We stub URLSession with a custom URLProtocol so the test never
//  touches the network. The captured requests are asserted against
//  the Marti Mission API wire format documented in
//  `docs/specs/mission-api-client.md`.
//

import XCTest
@testable import MissionAPIClientKit

final class MissionAPIClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubMissionAPIURLProtocol.reset()
    }

    override func tearDown() {
        StubMissionAPIURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - createMission

    /// Headline TDD check: creating a mission must PUT to the canonical
    /// Marti path with the required query params.
    func test_createMission_sendsPUTToCorrectMartiPath() async throws {
        StubMissionAPIURLProtocol.responder = { req in
            return StubResponse(status: 200, body: Data("{}".utf8))
        }
        let client = makeClient()

        _ = try await client.createMission(
            name: "SAR-Find-Lost-Hiker",
            creatorUid: "OMNI-EUD-123",
            description: "Lost hiker last seen at TH",
            tool: "public",
            groups: ["__ANON__"],
            defaultRole: "MISSION_OWNER",
            bbox: MissionBoundingBox(minLat: 47.6, minLon: -117.5, maxLat: 47.7, maxLon: -117.4)
        )

        let captured = try XCTUnwrap(StubMissionAPIURLProtocol.captured.last)
        XCTAssertEqual(captured.method, "PUT")
        XCTAssertEqual(captured.url.path, "/Marti/api/missions/SAR-Find-Lost-Hiker")

        // All required query params present.
        let items = URLComponents(url: captured.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "creatorUid" })?.value, "OMNI-EUD-123")
        XCTAssertEqual(items.first(where: { $0.name == "tool" })?.value, "public")
        XCTAssertEqual(items.first(where: { $0.name == "description" })?.value, "Lost hiker last seen at TH")
        XCTAssertEqual(items.first(where: { $0.name == "defaultRole" })?.value, "MISSION_OWNER")
        XCTAssertEqual(items.first(where: { $0.name == "group" })?.value, "__ANON__")
        XCTAssertEqual(items.first(where: { $0.name == "bbox" })?.value, "47.6,-117.5,47.7,-117.4")

        // Marti tolerates empty body but some CIV builds require valid JSON
        // — we ship `{}` rather than empty bytes.
        XCTAssertEqual(String(data: captured.body ?? Data(), encoding: .utf8), "{}")
    }

    func test_createMission_returnsSynthesisedMissionOnEmptyBody() async throws {
        StubMissionAPIURLProtocol.responder = { _ in
            StubResponse(status: 201, body: Data())  // some Marti builds return empty 201
        }
        let client = makeClient()

        let result = try await client.createMission(
            name: "EmptyBodyMission",
            creatorUid: "OMNI-EUD-42",
            description: nil,
            tool: "public",
            groups: [],
            defaultRole: nil,
            bbox: nil
        )
        XCTAssertEqual(result.name, "EmptyBodyMission")
        XCTAssertEqual(result.creatorUid, "OMNI-EUD-42")
        XCTAssertEqual(result.tool, "public")
    }

    func test_createMission_surfacesHTTPErrors() async throws {
        StubMissionAPIURLProtocol.responder = { _ in
            StubResponse(status: 400, body: Data("mission name already exists".utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.createMission(
                name: "DupeName",
                creatorUid: "u",
                description: nil,
                tool: "public",
                groups: [],
                defaultRole: nil,
                bbox: nil
            )
            XCTFail("Expected HTTP 400 to throw")
        } catch let MissionAPIError.http(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(body, "mission name already exists")
        }
    }

    // MARK: - addContentsToMission

    /// End-to-end TDD: the failing test the task spec asks for.
    /// `addContentsToMission` must (a) multipart-POST to /Marti/sync/missionupload,
    /// (b) parse the hash out of the plain-text response, and (c) PUT a
    /// JSON `{ "hashes": [...] }` payload to /Marti/api/missions/{name}/contents.
    func test_addContentsToMission_uploadsThenAttaches() async throws {
        let packageURL = try writeTempPackage(named: "test-mission.zip", bytes: "ZIPBYTES".data(using: .utf8)!)
        defer { try? FileManager.default.removeItem(at: packageURL) }

        StubMissionAPIURLProtocol.responder = { req in
            if req.url.path == "/Marti/sync/missionupload" {
                // Plain-text URL ending in ?hash={sha}
                let body = "https://tak.test:8443/Marti/sync/content?hash=DEADBEEFCAFE1234"
                return StubResponse(status: 200, body: Data(body.utf8))
            }
            if req.url.path.hasSuffix("/contents") {
                return StubResponse(status: 200, body: Data("{}".utf8))
            }
            return StubResponse(status: 500, body: Data())
        }

        let client = makeClient()
        let hash = try await client.addContentsToMission(
            missionName: "SAR-Find-Lost-Hiker",
            packageURL: packageURL,
            creatorUid: "OMNI-EUD-123"
        )

        XCTAssertEqual(hash, "DEADBEEFCAFE1234")

        // Two requests in order: upload then attach.
        XCTAssertEqual(StubMissionAPIURLProtocol.captured.count, 2)
        let upload = StubMissionAPIURLProtocol.captured[0]
        let attach = StubMissionAPIURLProtocol.captured[1]

        // Upload assertions
        XCTAssertEqual(upload.method, "POST")
        XCTAssertEqual(upload.url.path, "/Marti/sync/missionupload")
        let uploadQuery = URLComponents(url: upload.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(uploadQuery.first(where: { $0.name == "creatorUid" })?.value, "OMNI-EUD-123")
        XCTAssertNotNil(uploadQuery.first(where: { $0.name == "filename" }))
        let contentType = upload.headers["Content-Type"] ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="),
                     "Expected multipart/form-data, got: \(contentType)")
        let bodyString = String(data: upload.body ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyString.contains("name=\"assetfile\""))
        XCTAssertTrue(bodyString.contains("filename=\"test-mission.zip\""))
        XCTAssertTrue(bodyString.contains("ZIPBYTES"))

        // Attach assertions
        XCTAssertEqual(attach.method, "PUT")
        XCTAssertEqual(attach.url.path, "/Marti/api/missions/SAR-Find-Lost-Hiker/contents")
        XCTAssertEqual(attach.headers["Content-Type"], "application/json")
        let json = try JSONSerialization.jsonObject(with: attach.body ?? Data()) as? [String: [String]]
        XCTAssertEqual(json?["hashes"], ["DEADBEEFCAFE1234"])
    }

    func test_addContentsToMission_throwsWhenPackageMissing() async throws {
        let client = makeClient()
        do {
            _ = try await client.addContentsToMission(
                missionName: "M",
                packageURL: URL(fileURLWithPath: "/tmp/does-not-exist-omnitak.zip"),
                creatorUid: "u"
            )
            XCTFail("Expected packageMissing")
        } catch let MissionAPIError.packageMissing(url) {
            XCTAssertEqual(url.lastPathComponent, "does-not-exist-omnitak.zip")
        }
    }

    func test_addContentsToMission_throwsMissingHashIfServerOmits() async throws {
        let packageURL = try writeTempPackage(named: "p.zip", bytes: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: packageURL) }

        StubMissionAPIURLProtocol.responder = { _ in
            StubResponse(status: 200, body: Data("OK no hash here".utf8))
        }
        let client = makeClient()
        do {
            _ = try await client.addContentsToMission(
                missionName: "M",
                packageURL: packageURL,
                creatorUid: "u"
            )
            XCTFail("Expected missingHash")
        } catch MissionAPIError.missingHash {
            // ok
        }
    }

    // MARK: - hash parsing

    func test_extractHash_parsesQueryParamForm() {
        let body = "https://tak.test/Marti/sync/content?hash=ABC123&foo=bar"
        XCTAssertEqual(
            URLSessionMissionAPIClient.extractHash(fromMissionUploadResponse: body),
            "ABC123"
        )
    }

    func test_extractHash_parsesHeaderStyleForm() {
        let body = "Hash=XYZ789"
        XCTAssertEqual(
            URLSessionMissionAPIClient.extractHash(fromMissionUploadResponse: body),
            "XYZ789"
        )
    }

    func test_extractHash_returnsNilOnGarbage() {
        XCTAssertNil(URLSessionMissionAPIClient.extractHash(fromMissionUploadResponse: "boom"))
    }

    // MARK: - getMissions

    func test_getMissions_decodesArrayResponse() async throws {
        StubMissionAPIURLProtocol.responder = { _ in
            let body = """
            [
              {"name":"Alpha","tool":"public"},
              {"name":"Bravo","creatorUid":"u2","tool":"public"}
            ]
            """
            return StubResponse(status: 200, body: Data(body.utf8))
        }
        let client = makeClient()
        let missions = try await client.getMissions()
        XCTAssertEqual(missions.map { $0.name }, ["Alpha", "Bravo"])
    }

    func test_getMissions_decodesMartiEnvelopeResponse() async throws {
        StubMissionAPIURLProtocol.responder = { _ in
            let body = """
            { "version":"3", "type":"Mission",
              "data":[{"name":"Charlie","tool":"public"}] }
            """
            return StubResponse(status: 200, body: Data(body.utf8))
        }
        let client = makeClient()
        let missions = try await client.getMissions()
        XCTAssertEqual(missions.map { $0.name }, ["Charlie"])
    }

    // MARK: - helpers

    private func makeClient() -> URLSessionMissionAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubMissionAPIURLProtocol.self]
        let session = URLSession(configuration: config)

        let client = URLSessionMissionAPIClient()
        client.configure(baseURL: URL(string: "https://tak.test:8443")!, session: session)
        return client
    }

    private func writeTempPackage(named: String, bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(named)
        try? FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        return url
    }
}

// MARK: - URLProtocol stub

struct StubResponse {
    let status: Int
    let body: Data
    let headers: [String: String]

    init(status: Int, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

struct CapturedRequest {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?
}

final class StubMissionAPIURLProtocol: URLProtocol {
    static var responder: ((CapturedRequest) -> StubResponse)?
    static var captured: [CapturedRequest] = []
    static let queue = DispatchQueue(label: "StubMissionAPIURLProtocol")

    static func reset() {
        queue.sync {
            responder = nil
            captured = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession strips httpBody from URLRequest by the time it reaches
        // URLProtocol — pull it back out of the bodyStream if present.
        let body = Self.bodyData(from: request)
        let captured = CapturedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        Self.queue.sync { Self.captured.append(captured) }

        let stub = Self.responder?(captured) ?? StubResponse(status: 599, body: Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
