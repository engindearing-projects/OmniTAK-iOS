//
//  MBTilesRenderTests.swift
//  OmniTAKMobileTests
//
//  Regression tests for issue #131: an imported MBTiles file reported success
//  and then never drew. The causes that were real:
//
//    1. The tile server ignored its listener's .failed / .cancelled states and
//       start() did nothing while a listener object existed, so a listener the
//       OS took away was never restarted and sources already on the map kept a
//       dead URL.
//    2. A file with no `bounds` row imported "successfully" but the app only
//       switched to the 2D engine (the only one that draws tile sets) when the
//       file had bounds.
//    3. Vector (pbf) tile sets imported fine and were then served as image/png.
//    4. `port` was written on the server queue and read on main without the
//       lock, and the listener was bound to every interface.
//
//  The framing test also covers a fifth cause found while checking this: the
//  camera was framed from further out than the file's first tile level, where
//  a raster source draws nothing.
//

import XCTest
import Combine
import MapKit
import Network
import SQLite3
@testable import OmniTAK

// MARK: - Helpers

/// A tile database holding a few fixed tiles in memory.
private final class StubTileDB: RasterTileDB {
    let minZoom = 0
    let maxZoom = 5
    let bounds: (n: Double, s: Double, e: Double, w: Double)? = nil
    let format: String
    private let tiles: [String: Data]

    init(format: String = "png", tiles: [String: Data]) {
        self.format = format
        self.tiles = tiles
    }

    func tile(z: Int, x: Int, y: Int) -> Data? { tiles["\(z)/\(x)/\(y)"] }
}

private struct HTTPResult {
    let status: Int
    let contentType: String?
    let body: Data
}

private func httpGET(_ urlString: String) async throws -> HTTPResult {
    let config = URLSessionConfiguration.ephemeral
    config.connectionProxyDictionary = [:] // never let a system proxy see loopback traffic
    config.timeoutIntervalForRequest = 10
    let session = URLSession(configuration: config)
    defer { session.finishTasksAndInvalidate() }
    let (data, response) = try await session.data(from: try XCTUnwrap(URL(string: urlString)))
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    return HTTPResult(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type"), body: data)
}

private func fill(_ template: String, z: Int, x: Int, y: Int) -> String {
    template
        .replacingOccurrences(of: "{z}", with: String(z))
        .replacingOccurrences(of: "{x}", with: String(x))
        .replacingOccurrences(of: "{y}", with: String(y))
}

/// Tile bytes that start the way each format does. The server never decodes
/// them, and neither does the validation: it only looks at the first bytes.
private enum SampleTile {
    static let png = MBTilesTestFixture.pngTile
    static let jpg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
    static let webp = Data("RIFF".utf8) + Data([0x24, 0x00, 0x00, 0x00]) + Data("WEBP".utf8) + Data("VP8 ".utf8)
    /// What a vector tile looks like on disk: gzip-compressed protobuf.
    static let gzippedVector = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x01, 0x02])
    static let notAnImage = Data("not an image at all".utf8)
}

extension XCTestCase {
    /// Runs `action`, then waits for the tile server to report it is listening.
    fileprivate func waitForReady(_ server: MBTilesTileServer, timeout: TimeInterval = 10,
                                  _ action: () -> Void) async {
        let ready = expectation(description: "tile server ready")
        ready.assertForOverFulfill = false
        server.onReady = { _ in ready.fulfill() }
        action()
        await fulfillment(of: [ready], timeout: timeout)
    }
}

// MARK: - Tile server

final class MBTilesTileServerTests: XCTestCase {

    private var server: MBTilesTileServer!
    private let png = SampleTile.png

    override func setUp() {
        super.setUp()
        server = MBTilesTileServer()
    }

    override func tearDown() {
        server.stop()
        server = nil
        super.tearDown()
    }

    func testServerBecomesReadyAndServesATile() async throws {
        XCTAssertFalse(server.isReady)
        XCTAssertEqual(server.port, 0)

        await waitForReady(server) { server.register(StubTileDB(tiles: ["1/0/0": png]), id: "stub") }

        XCTAssertTrue(server.isReady)
        XCTAssertNotEqual(server.port, 0)
        let template = try XCTUnwrap(server.tileURLTemplate(for: "stub"))
        XCTAssertEqual(template, "http://127.0.0.1:\(server.port)/stub/{z}/{x}/{y}")

        let hit = try await httpGET(fill(template, z: 1, x: 0, y: 0))
        XCTAssertEqual(hit.status, 200)
        XCTAssertEqual(hit.contentType, "image/png")
        XCTAssertEqual(hit.body, png)

        let miss = try await httpGET(fill(template, z: 1, x: 1, y: 1))
        XCTAssertEqual(miss.status, 404, "a tile the file doesn't have is a 404")
    }

    func testNoTemplateForAnIdThatIsNotRegisteredOrAfterStop() async throws {
        XCTAssertNil(server.tileURLTemplate(for: "stub"), "nothing registered, nothing listening")

        await waitForReady(server) { server.register(StubTileDB(tiles: ["1/0/0": png]), id: "stub") }
        XCTAssertNotNil(server.tileURLTemplate(for: "stub"))
        XCTAssertNil(server.tileURLTemplate(for: "other"), "an id with nothing behind it must not get a URL")

        server.unregister("stub")
        XCTAssertNil(server.tileURLTemplate(for: "stub"))

        server.register(StubTileDB(tiles: [:]), id: "stub")
        server.stop()
        XCTAssertEqual(server.port, 0)
        XCTAssertNil(server.tileURLTemplate(for: "stub"))
    }

    /// Cause 1: the OS can take a listener away while the app is in the
    /// background. Cancelling it is the same state arriving here.
    func testListenerTakenAwayBySystemIsRestartedAndServesAgain() async throws {
        await waitForReady(server) { server.register(StubTileDB(tiles: ["1/0/0": png]), id: "stub") }
        let firstPort = server.port
        XCTAssertNotEqual(firstPort, 0)

        await waitForReady(server) { server.listenerForTesting?.cancel() }

        XCTAssertTrue(server.isReady, "the server must come back by itself")
        let template = try XCTUnwrap(server.tileURLTemplate(for: "stub"))
        let result = try await httpGET(fill(template, z: 1, x: 0, y: 0))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.body, png)
        XCTAssertEqual(server.port, firstPort,
                       "the restart should reuse the port so URLs the map already holds stay valid")
    }

    func testRestartsRepeatedly() async throws {
        await waitForReady(server) { server.register(StubTileDB(tiles: ["1/0/0": png]), id: "stub") }
        for _ in 0..<3 {
            await waitForReady(server) { server.listenerForTesting?.cancel() }
            XCTAssertTrue(server.isReady)
        }
        let template = try XCTUnwrap(server.tileURLTemplate(for: "stub"))
        let result = try await httpGET(fill(template, z: 1, x: 0, y: 0))
        XCTAssertEqual(result.status, 200)
    }

    func testStopStaysStopped() async throws {
        await waitForReady(server) { server.register(StubTileDB(tiles: [:]), id: "stub") }
        server.stop()
        try await Task.sleep(nanoseconds: 700_000_000) // longer than the first restart delay
        XCTAssertFalse(server.isReady)
        XCTAssertEqual(server.port, 0)
    }

    /// Cause 4: the listener was bound to every interface, so anything on the
    /// network could read the operator's tile files. It must take loopback
    /// connections only.
    func testListenerAcceptsLoopbackConnectionsOnly() async throws {
        await waitForReady(server) { server.register(StubTileDB(tiles: [:]), id: "stub") }
        let port = server.port

        guard let otherAddress = Self.firstNonLoopbackIPv4() else {
            throw XCTSkip("this machine has no non-loopback IPv4 address to test with")
        }
        XCTAssertTrue(Self.canConnect(to: "127.0.0.1", port: port), "loopback must work")
        XCTAssertFalse(Self.canConnect(to: otherAddress, port: port),
                       "the tile server must not be reachable on \(otherAddress)")
    }

    /// Cause 4: `port` is read from main and from the network queue while the
    /// listener restarts. This can't prove the absence of a race (that needs
    /// Thread Sanitizer) but it does exercise reads during restarts and would
    /// catch a deadlock in the locking.
    func testReadsFromManyThreadsDuringRestartsDoNotDeadlock() async throws {
        await waitForReady(server) { server.register(StubTileDB(tiles: ["1/0/0": png]), id: "stub") }

        let keepReading = LockedFlag(true)
        let readers = DispatchGroup()
        for _ in 0..<6 {
            DispatchQueue.global().async(group: readers) { [server] in
                while keepReading.value {
                    _ = server?.port
                    _ = server?.isReady
                    _ = server?.tileURLTemplate(for: "stub")
                    // Let go of the CPU between rounds. Six readers spinning
                    // on the server's lock without a pause kept the listener's
                    // own state handler from ever getting it on a three-core
                    // CI runner, and the restart then looked like a hang.
                    usleep(200)
                }
            }
        }
        for _ in 0..<3 {
            await waitForReady(server, timeout: 30) { server.listenerForTesting?.cancel() }
        }
        keepReading.value = false

        XCTAssertEqual(readers.wait(timeout: .now() + 5), .success, "a reader is stuck")
        XCTAssertTrue(server.isReady)
    }

    // MARK: Request handling

    func testResponseCarriesTheTileAndTheRightContentType() {
        server.register(StubTileDB(format: "png", tiles: ["2/1/1": SampleTile.png]), id: "p")
        server.register(StubTileDB(format: "jpg", tiles: ["2/1/1": SampleTile.jpg]), id: "j")
        server.register(StubTileDB(format: "webp", tiles: ["2/1/1": SampleTile.webp]), id: "w")

        for (id, type, tile) in [("p", "image/png", SampleTile.png),
                                 ("j", "image/jpeg", SampleTile.jpg),
                                 ("w", "image/webp", SampleTile.webp)] {
            let parts = Self.split(server.response(forRequestLine: "GET /\(id)/2/1/1 HTTP/1.1"))
            XCTAssertTrue(parts.head.hasPrefix("HTTP/1.1 200 OK"), parts.head)
            XCTAssertTrue(parts.head.contains("Content-Type: \(type)"), parts.head)
            XCTAssertTrue(parts.head.contains("Content-Length: \(tile.count)"), parts.head)
            XCTAssertEqual(parts.body, tile)
        }
    }

    func testResponseAcceptsAFileExtensionOnTheRow() {
        server.register(StubTileDB(tiles: ["2/1/1": SampleTile.png]), id: "p")
        let parts = Self.split(server.response(forRequestLine: "GET /p/2/1/1.png HTTP/1.1"))
        XCTAssertTrue(parts.head.hasPrefix("HTTP/1.1 200 OK"), parts.head)
    }

    func testResponseIs404ForUnknownIdMissingTileAndGarbage() {
        server.register(StubTileDB(tiles: ["2/1/1": SampleTile.png]), id: "p")
        for line in ["GET /nope/2/1/1 HTTP/1.1", "GET /p/2/1/2 HTTP/1.1", "GET /p/x/y/z HTTP/1.1",
                     "GET / HTTP/1.1", "", "garbage"] {
            let parts = Self.split(server.response(forRequestLine: line))
            XCTAssertTrue(parts.head.hasPrefix("HTTP/1.1 404 Not Found"), "\(line) -> \(parts.head)")
            XCTAssertTrue(parts.body.isEmpty)
        }
    }

    // MARK: Socket helpers

    private final class LockedFlag {
        private let lock = NSLock()
        private var stored: Bool
        init(_ value: Bool) { stored = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private static func split(_ response: Data) -> (head: String, body: Data) {
        let marker = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: marker) else { return (String(decoding: response, as: UTF8.self), Data()) }
        return (String(decoding: response[..<range.lowerBound], as: UTF8.self), Data(response[range.upperBound...]))
    }

    /// The first up, non-loopback IPv4 address of this machine, if any.
    private static func firstNonLoopbackIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let rc = getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
            if rc == 0 { return String(cString: host) }
        }
        return nil
    }

    private static func canConnect(to host: String, port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return rc == 0
    }
}

// MARK: - Raster validation and bounds (cause 3 and the framing half of cause 2)

final class MBTilesFileValidationTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MBTilesFileValidationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFile(_ name: String = "tiles", format: String? = "png",
                          bounds: String? = "-122.5,47.5,-122.0,47.8",
                          minZoom: Int = 0, maxZoom: Int = 4,
                          tiles: [(z: Int, x: Int, y: Int)] = [(1, 0, 0)],
                          tileData: Data = SampleTile.png) throws -> String {
        try MBTilesTestFixture.makeMBTiles(at: dir.appendingPathComponent("\(name).mbtiles"),
                                           format: format, bounds: bounds, minZoom: minZoom, maxZoom: maxZoom,
                                           tiles: tiles, tileData: tileData).path
    }

    private func assertRejected(_ path: String, as expected: TileSetError,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MBTilesDB(path: path), file: file, line: line) { error in
            XCTAssertEqual(error as? TileSetError, expected, file: file, line: line)
        }
    }

    // MARK: Raster accepted

    func testRasterFormatsAreAcceptedAndReadFromTheTileBytes() throws {
        for (format, data, expected) in [("png", SampleTile.png, "png"),
                                         ("jpg", SampleTile.jpg, "jpg"),
                                         ("jpeg", SampleTile.jpg, "jpg"),
                                         ("webp", SampleTile.webp, "webp")] {
            let db = try MBTilesDB(path: try makeFile("r-\(format)", format: format, tileData: data))
            XCTAssertEqual(db.format, expected, "declared \(format)")
        }
    }

    func testFileWithNoFormatRowIsReadFromItsTiles() throws {
        let db = try MBTilesDB(path: try makeFile(format: nil, tileData: SampleTile.jpg))
        XCTAssertEqual(db.format, "jpg")
    }

    /// The metadata is optional and not always right; the tile bytes decide.
    func testTileBytesWinOverWrongMetadata() throws {
        // Says pbf, holds PNGs: Mapbox can draw these.
        let db = try MBTilesDB(path: try makeFile("lies-raster", format: "pbf", tileData: SampleTile.png))
        XCTAssertEqual(db.format, "png")
        // Says png, holds gzipped vector tiles: it can't.
        assertRejected(try makeFile("lies-vector", format: "png", tileData: SampleTile.gzippedVector),
                       as: .vectorTiles)
    }

    // MARK: Rejected

    func testVectorTilesAreRejected() throws {
        assertRejected(try makeFile("vec", format: "pbf", tileData: SampleTile.gzippedVector), as: .vectorTiles)
        // Uncompressed protobuf: not gzip, but declared pbf.
        assertRejected(try makeFile("vec-raw", format: "pbf", tileData: Data([0x1A, 0x0A, 0x05, 0x6C])),
                       as: .vectorTiles)
        assertRejected(try makeFile("mvt", format: "mvt", tileData: Data([0x1A, 0x0A, 0x05, 0x6C])),
                       as: .vectorTiles)
    }

    func testTilesThatAreNotImagesAreRejected() throws {
        assertRejected(try makeFile(format: "png", tileData: SampleTile.notAnImage), as: .unsupportedFormat("png"))
        assertRejected(try makeFile(format: nil, tileData: SampleTile.notAnImage), as: .unsupportedFormat("unknown"))
    }

    func testFileThatIsNotADatabaseIsRejected() throws {
        let path = dir.appendingPathComponent("notes.mbtiles")
        try Data("this is a text file, not a SQLite database".utf8).write(to: path)
        assertRejected(path.path, as: .unreadable(kind: "MBTiles"))

        let empty = dir.appendingPathComponent("empty.mbtiles")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        assertRejected(empty.path, as: .unreadable(kind: "MBTiles"))
    }

    func testDatabaseWithoutATilesTableIsRejected() throws {
        let path = dir.appendingPathComponent("no-tiles-table.mbtiles").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE metadata (name TEXT, value TEXT)", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        assertRejected(path, as: .unreadable(kind: "MBTiles"))
    }

    func testEmptyTilesTableIsRejected() throws {
        assertRejected(try makeFile(tiles: []), as: .noTiles)
    }

    func testErrorMessagesAreCompleteSentences() {
        for error in [TileSetError.vectorTiles, .noTiles, .unreadable(kind: "MBTiles"), .unsupportedFormat("png")] {
            let text = error.errorDescription ?? ""
            XCTAssertTrue(text.hasSuffix("."), text)
            XCTAssertFalse(text.contains("—"), "plain punctuation only: \(text)")
        }
        XCTAssertTrue(TileSetError.vectorTiles.errorDescription?.contains("vector tiles") == true)
    }

    // MARK: Bounds

    func testBoundsComeFromTheFileWhenItDeclaresThem() throws {
        let db = try MBTilesDB(path: try makeFile(bounds: "-122.5,47.5,-122.0,47.8"))
        let b = try XCTUnwrap(db.bounds)
        XCTAssertEqual(b.w, -122.5, accuracy: 1e-9)
        XCTAssertEqual(b.s, 47.5, accuracy: 1e-9)
        XCTAssertEqual(b.e, -122.0, accuracy: 1e-9)
        XCTAssertEqual(b.n, 47.8, accuracy: 1e-9)
    }

    /// Cause 2: no `bounds` row. The tiles themselves say where the file is.
    func testBoundsAreWorkedOutFromTheTilesWhenTheFileHasNone() throws {
        // z1 column 0, XYZ row 0 is the north-west quarter of the web-mercator world.
        let db = try MBTilesDB(path: try makeFile(bounds: nil, tiles: [(1, 0, 0)]))
        let b = try XCTUnwrap(db.bounds)
        XCTAssertEqual(b.w, -180, accuracy: 1e-6)
        XCTAssertEqual(b.e, 0, accuracy: 1e-6)
        XCTAssertEqual(b.s, 0, accuracy: 1e-6)
        XCTAssertEqual(b.n, 85.0511, accuracy: 1e-3)
    }

    func testDerivedBoundsUseTheLowestZoomLevelThatHasTiles() throws {
        // z2 columns 1...2 on XYZ row 1, plus a z3 tile that must be ignored.
        let db = try MBTilesDB(path: try makeFile(bounds: nil, tiles: [(2, 1, 1), (2, 2, 1), (3, 5, 5)]))
        let b = try XCTUnwrap(db.bounds)
        XCTAssertEqual(b.w, -90, accuracy: 1e-6)
        XCTAssertEqual(b.e, 90, accuracy: 1e-6)
        XCTAssertEqual(b.s, 0, accuracy: 1e-6)
        XCTAssertEqual(b.n, 66.5133, accuracy: 1e-3)
    }

    func testDerivedBoundsLandOnTheRightPlaceOnTheGlobe() throws {
        // The z14 tile over Riverfront Park, Spokane (47.6616, -117.4181).
        let db = try MBTilesDB(path: try makeFile(bounds: nil, minZoom: 14, tiles: [(14, 2848, 5718)]))
        let b = try XCTUnwrap(db.bounds)
        XCTAssertTrue((b.w...b.e).contains(-117.4181), "\(b)")
        XCTAssertTrue((b.s...b.n).contains(47.6616), "\(b)")
        XCTAssertEqual(b.e - b.w, 360.0 / 16384.0, accuracy: 1e-9, "one z14 tile wide")
    }

    func testUnusableDeclaredBoundsFallBackToTheTiles() throws {
        for junk in ["0,0,0,0", "-200,0,200,90", "10,20,5,30", "1,2,3", "not,a,box,at all"] {
            let db = try MBTilesDB(path: try makeFile("junk", bounds: junk, tiles: [(1, 0, 0)]))
            let b = try XCTUnwrap(db.bounds, "declared \"\(junk)\"")
            XCTAssertEqual(b.w, -180, accuracy: 1e-6, "declared \"\(junk)\" should have been ignored")
        }
    }

    // MARK: Framing (the camera has to be where the tiles are drawn)

    func testWidestLongitudeSpanKeepsTheFirstTileLevelOnScreen() {
        for level in 0...18 {
            let span = MBTilesOverlay.widestLongitudeSpan(minZoom: level)
            let zoom = TacticalMapView.zoom(
                forSpan: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span), mapHeight: 400)
            // 256 px tiles: level z first draws at map zoom z - 1.
            XCTAssertGreaterThanOrEqual(zoom, Double(level) - 1, "level \(level)")
            XCTAssertEqual(zoom, max(Double(level) - 0.75, 0), accuracy: 1e-6, "level \(level)")
        }
        // A small z14 tile set (a few tiles wide) must not be framed at zoom ~12.
        XCTAssertEqual(MBTilesOverlay.widestLongitudeSpan(minZoom: 14), 0.03696, accuracy: 1e-4)
    }
}

// MARK: - Store + server together

final class MBTilesStoreServerTests: XCTestCase {

    private var root: URL!
    private var storeDir: URL!
    private var sourceDir: URL!
    private var server: MBTilesTileServer!
    private var bag = Set<AnyCancellable>()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MBTilesStoreServerTests-\(UUID().uuidString)", isDirectory: true)
        storeDir = root.appendingPathComponent("store", isDirectory: true)
        sourceDir = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        server = MBTilesTileServer()
    }

    override func tearDownWithError() throws {
        bag.removeAll()
        server.stop()
        server = nil
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    private func makeStore() -> MBTilesOverlayStore {
        MBTilesOverlayStore(directory: storeDir, tileServer: server)
    }

    /// Fulfilled the next time the store says the tile server (re)started.
    @MainActor
    private func nextGenerationBump(of store: MBTilesOverlayStore) -> XCTestExpectation {
        let bump = expectation(description: "store republished after the tile server came up")
        bump.assertForOverFulfill = false
        let start = store.tileServerGeneration
        store.$tileServerGeneration
            .filter { $0 > start }
            .sink { _ in bump.fulfill() }
            .store(in: &bag)
        return bump
    }

    @MainActor
    private func importRaster(_ name: String, into store: MBTilesOverlayStore,
                              bounds: String? = "-122.5,47.5,-122.0,47.8",
                              tiles: [(z: Int, x: Int, y: Int)] = [(1, 0, 0)]) async throws -> MBTilesOverlay {
        let file = try MBTilesTestFixture.makeMBTiles(
            at: sourceDir.appendingPathComponent("\(name).mbtiles"), bounds: bounds, tiles: tiles)
        let ok = await store.importMBTiles(from: file)
        XCTAssertTrue(ok, "import should succeed; error: \(store.lastError ?? "none")")
        return try XCTUnwrap(store.overlays.last)
    }

    // MARK: The race from the issue, closed

    /// The listener comes up after the import returns, so right after an import
    /// there is no template yet. The store must say when there is one, because
    /// that is what makes the map re-run its overlay refresh.
    @MainActor
    func testStoreRepublishesWhenTheServerComesUpAndTheTileSetIsServed() async throws {
        let store = makeStore()
        let bump = nextGenerationBump(of: store)

        let overlay = try await importRaster("lake", into: store)
        await fulfillment(of: [bump], timeout: 10)

        let template = try XCTUnwrap(store.tileURLTemplate(overlay))
        let result = try await httpGET(fill(template, z: 1, x: 0, y: 0))
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.body, SampleTile.png)
    }

    /// Cause 1, store side: when the OS takes the listener away and the server
    /// restarts, the store republishes so the map re-checks its sources.
    @MainActor
    func testStoreRepublishesWhenTheServerRestarts() async throws {
        let store = makeStore()
        let first = nextGenerationBump(of: store)
        let overlay = try await importRaster("lake", into: store)
        await fulfillment(of: [first], timeout: 10)

        let second = nextGenerationBump(of: store)
        server.listenerForTesting?.cancel()
        await fulfillment(of: [second], timeout: 10)

        let template = try XCTUnwrap(store.tileURLTemplate(overlay))
        let result = try await httpGET(fill(template, z: 1, x: 0, y: 0))
        XCTAssertEqual(result.status, 200, "the restarted server must serve the tile set again")
    }

    // MARK: Import

    /// Cause 3: a vector tile set used to import fine and was then served as png.
    @MainActor
    func testVectorTileSetIsRejectedAtImportWithAVisibleError() async throws {
        let store = makeStore()
        let file = try MBTilesTestFixture.makeMBTiles(
            at: sourceDir.appendingPathComponent("roads.mbtiles"), format: "pbf",
            tileData: SampleTile.gzippedVector)

        let ok = await store.importMBTiles(from: file)

        XCTAssertFalse(ok)
        XCTAssertTrue(store.overlays.isEmpty, "a rejected file must not become an entry")
        XCTAssertEqual(store.lastError, TileSetError.vectorTiles.errorDescription)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: storeDir.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasSuffix(".mbtiles") }, "the copy of a rejected file must be removed: \(left)")
        XCTAssertFalse(server.isReady, "nothing was registered, so nothing should be listening")
    }

    @MainActor
    func testFileThatIsNotATileDatabaseIsRejectedAtImport() async throws {
        let store = makeStore()
        let file = sourceDir.appendingPathComponent("photo.mbtiles")
        try Data("definitely not sqlite".utf8).write(to: file)

        let ok = await store.importMBTiles(from: file)

        XCTAssertFalse(ok)
        XCTAssertEqual(store.lastError, TileSetError.unreadable(kind: "MBTiles").errorDescription)
        XCTAssertTrue(store.overlays.isEmpty)
    }

    /// Cause 2, data side: with no `bounds` row the entry used to get the
    /// placeholder world box and `hasBounds == false`, so nothing framed it.
    @MainActor
    func testImportWithoutBoundsRecordsTheBoundsOfTheTiles() async throws {
        let store = makeStore()
        let overlay = try await importRaster("nobounds", into: store, bounds: nil, tiles: [(2, 1, 1), (2, 2, 1)])

        XCTAssertTrue(overlay.hasBounds, "bounds worked out from the tiles count as bounds")
        XCTAssertEqual(overlay.west, -90, accuracy: 1e-6)
        XCTAssertEqual(overlay.east, 90, accuracy: 1e-6)
        XCTAssertEqual(overlay.south, 0, accuracy: 1e-6)
        XCTAssertEqual(overlay.north, 66.5133, accuracy: 1e-3)
    }

    // MARK: Entries from an older build

    /// An older build let vector tile sets in. They are still on disk, so they
    /// must show up as unusable (with the reason) instead of as a tile set that
    /// silently draws nothing.
    @MainActor
    func testVectorFileAlreadyInTheStoreIsFlaggedNotRegistered() async throws {
        let store = makeStore()
        let imported = try await importRaster("old", into: store)
        // Swap its file for a vector one, as a pre-fix import would have left it.
        let path = store.fileURL(imported)
        try FileManager.default.removeItem(at: path)
        try MBTilesTestFixture.makeMBTiles(at: path, format: "pbf", tileData: SampleTile.gzippedVector)

        let relaunched = makeStore()

        let entry = try XCTUnwrap(relaunched.overlays.first)
        XCTAssertFalse(entry.fileMissing)
        XCTAssertFalse(entry.isDrawable)
        XCTAssertEqual(entry.unsupportedReason, TileSetError.vectorTiles.errorDescription)
        XCTAssertNil(relaunched.tileURLTemplate(entry), "an unusable entry must never get a source on the map")

        relaunched.remove(entry.id)
        XCTAssertTrue(relaunched.overlays.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    @MainActor
    func testUnsupportedReasonIsRuntimeStateNotPersisted() async throws {
        let store = makeStore()
        let imported = try await importRaster("old", into: store)
        let path = store.fileURL(imported)
        try FileManager.default.removeItem(at: path)
        try MBTilesTestFixture.makeMBTiles(at: path, format: "pbf", tileData: SampleTile.gzippedVector)
        let relaunched = makeStore()
        relaunched.setOpacity(imported.id, 0.5) // forces a save with the flagged entry in the list

        let data = try Data(contentsOf: storeDir.appendingPathComponent("mbtiles.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertNil(json.first?["unsupportedReason"])
        XCTAssertNil(json.first?["fileMissing"])
    }
}
