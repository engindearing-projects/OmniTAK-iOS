//
//  MBTilesOverlay.swift
//  OmniTAKMobile
//
//  MBTiles raster basemap/imagery overlays — the offline tile-pyramid format
//  ATAK uses. An .mbtiles file is a SQLite DB of raster tiles; Mapbox can't
//  read it directly, so we serve tiles from a tiny in-process HTTP server and
//  point a RasterSource + RasterLayer at http://127.0.0.1:port/<id>/{z}/{x}/{y}.
//  MBTiles store tiles in TMS row order; the server flips Y to XYZ.
//

import Foundation
import Network
import SQLite3
import os

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Tile set validation

/// Why a tile file can't be used. `errorDescription` is a complete sentence
/// that is shown to the user as-is.
enum TileSetError: LocalizedError, Equatable {
    /// Not a database, or it has no tile table.
    case unreadable(kind: String)
    case noTiles
    /// Vector (pbf / mvt) tiles: Mapbox would be handed them as images.
    case vectorTiles
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let kind):
            return "This isn't a valid \(kind) file: it has no tile table."
        case .noTiles:
            return "This MBTiles file has no tiles in it."
        case .vectorTiles:
            return "This MBTiles file holds vector tiles (pbf), which OmniTAK can't draw. Import a raster MBTiles file with png, jpg or webp tiles."
        case .unsupportedFormat(let format):
            return "This MBTiles file uses the \"\(format)\" tile format, which OmniTAK can't draw. Import a raster MBTiles file with png, jpg or webp tiles."
        }
    }
}

/// The raster image formats a Mapbox raster source can draw, recognised by the
/// first bytes of a tile (the `format` metadata row is optional and not always
/// right).
enum TileImageFormat: String {
    case png, jpg, webp

    init?(sniffing data: Data) {
        let b = [UInt8](data.prefix(12))
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            self = .png
        } else if b.starts(with: [0xFF, 0xD8, 0xFF]) {
            self = .jpg
        } else if b.count >= 12, b[0..<4].elementsEqual("RIFF".utf8), b[8..<12].elementsEqual("WEBP".utf8) {
            self = .webp
        } else {
            return nil
        }
    }

    /// Vector tiles are stored as gzip-compressed protobuf.
    static func looksGzipped(_ data: Data) -> Bool { data.starts(with: [0x1F, 0x8B]) }

    static func contentType(forFormat format: String?) -> String {
        switch format?.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return "image/png"
        }
    }
}

// MARK: - SQLite reader

/// A read-only raster tile pyramid served over the local HTTP tile server.
/// Implemented by both MBTiles and GeoPackage (GPKG) readers.
protocol RasterTileDB: AnyObject {
    var minZoom: Int { get }
    var maxZoom: Int { get }
    var bounds: (n: Double, s: Double, e: Double, w: Double)? { get }
    var format: String { get } // tile image format: "png" / "jpg" / "webp"
    func tile(z: Int, x: Int, y: Int) -> Data?
}

final class MBTilesDB: RasterTileDB {
    private var db: OpaquePointer?
    // The HTTP tile server handles requests on a concurrent queue and Mapbox
    // fetches many tiles at once — serialize access to this one SQLite handle.
    private let lock = NSLock()
    let minZoom: Int
    let maxZoom: Int
    /// north, south, east, west (WGS84). From the file's `bounds` row when it
    /// has a usable one, otherwise worked out from the tiles it actually holds.
    let bounds: (n: Double, s: Double, e: Double, w: Double)?
    /// Tile image format as found in the tile bytes: "png" / "jpg" / "webp".
    let format: String

    /// Opens the file and checks it holds raster tiles. Throws `TileSetError`
    /// for a file that isn't a tile database, is empty, or holds vector tiles.
    /// (`sqlite3_open_v2` succeeds on any file, so the checks read the tiles.)
    init(path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if handle != nil { sqlite3_close(handle) }
            throw TileSetError.unreadable(kind: "MBTiles")
        }
        do {
            let meta = Self.readMetadata(handle)
            let sample = try Self.firstTile(handle)

            // Judge by the tile bytes, not the metadata.
            let declared = meta["format"]?.lowercased()
            if let image = TileImageFormat(sniffing: sample) {
                format = image.rawValue
            } else if TileImageFormat.looksGzipped(sample) || declared == "pbf" || declared == "mvt" {
                throw TileSetError.vectorTiles
            } else {
                throw TileSetError.unsupportedFormat(declared ?? "unknown")
            }

            minZoom = Int(meta["minzoom"] ?? "") ?? 0
            maxZoom = Int(meta["maxzoom"] ?? "") ?? 19
            bounds = Self.declaredBounds(meta["bounds"]) ?? Self.coverageBounds(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        db = handle
    }

    private static func readMetadata(_ handle: OpaquePointer?) -> [String: String] {
        var meta: [String: String] = [:]
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, "SELECT name, value FROM metadata", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) {
                    meta[String(cString: k)] = String(cString: v)
                }
            }
        }
        sqlite3_finalize(stmt)
        return meta
    }

    /// The first non-empty tile, used to tell what the file really contains.
    private static func firstTile(_ handle: OpaquePointer?) throws -> Data {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(handle, "SELECT tile_data FROM tiles WHERE length(tile_data) > 0 LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            throw TileSetError.unreadable(kind: "MBTiles")
        }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            guard let blob = sqlite3_column_blob(stmt, 0) else { throw TileSetError.noTiles }
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
        case SQLITE_DONE:
            throw TileSetError.noTiles
        default:
            throw TileSetError.unreadable(kind: "MBTiles")
        }
    }

    /// MBTiles `bounds` = "west,south,east,north"; ignored when it isn't a usable box.
    private static func declaredBounds(_ value: String?) -> (n: Double, s: Double, e: Double, w: Double)? {
        guard let parts = value?.split(separator: ",").compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
              parts.count == 4 else { return nil }
        let (w, s, e, n) = (parts[0], parts[1], parts[2], parts[3])
        guard abs(s) <= 90, abs(n) <= 90, abs(w) <= 180, abs(e) <= 180, s < n, w < e else { return nil }
        return (n: n, s: s, e: e, w: w)
    }

    /// The area the tiles cover (WGS84), taken from the lowest zoom level that
    /// has tiles, where there are few. For files that declare no `bounds`.
    private static func coverageBounds(_ handle: OpaquePointer?) -> (n: Double, s: Double, e: Double, w: Double)? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT zoom_level, MIN(tile_column), MAX(tile_column), MIN(tile_row), MAX(tile_row) FROM tiles WHERE zoom_level = (SELECT MIN(zoom_level) FROM tiles)"
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
        let z = Int(sqlite3_column_int(stmt, 0))
        guard (0...30).contains(z) else { return nil }
        let n = Double(1 << z)
        let westCol = Double(sqlite3_column_int(stmt, 1)), eastCol = Double(sqlite3_column_int(stmt, 2))
        // MBTiles rows count up from the south; web-mercator tile rows count down from the north.
        let northRow = n - 1 - Double(sqlite3_column_int(stmt, 4))
        let southRow = n - 1 - Double(sqlite3_column_int(stmt, 3))
        func lon(_ col: Double) -> Double { col / n * 360.0 - 180.0 }
        func lat(_ row: Double) -> Double { atan(sinh(Double.pi * (1.0 - 2.0 * row / n))) * 180.0 / Double.pi }
        let box = (n: lat(northRow), s: lat(southRow + 1), e: lon(eastCol + 1), w: lon(westCol))
        guard box.n.isFinite, box.s.isFinite, box.n > box.s, box.e > box.w else { return nil }
        return box
    }

    func tile(z: Int, x: Int, y: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return nil }
        let tmsY = (1 << z) - 1 - y // XYZ → TMS row
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(z))
        sqlite3_bind_int(stmt, 2, Int32(x))
        sqlite3_bind_int(stmt, 3, Int32(tmsY))
        guard sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    deinit { if db != nil { sqlite3_close(db) } }
}

// MARK: - GeoPackage (GPKG) raster reader

/// Reads raster tiles from a GeoPackage. Supports the common standard case:
/// a `tiles` data table whose grid matches the slippy-map (XYZ) scheme in
/// EPSG:3857 or 4326. GPKG tile_row is top-origin (= XYZ y, no TMS flip).
final class GPKGDb: RasterTileDB {
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let tableName: String
    let minZoom: Int
    let maxZoom: Int
    let bounds: (n: Double, s: Double, e: Double, w: Double)?
    let format: String = "png"

    init?(path: String) {
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        // Find the first tiles table + its bounds/SRS from gpkg_contents.
        var table: String?
        var minX = 0.0, minY = 0.0, maxX = 0.0, maxY = 0.0, srs = 4326
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT table_name, min_x, min_y, max_x, max_y, srs_id FROM gpkg_contents WHERE data_type='tiles' LIMIT 1", -1, &stmt, nil) == SQLITE_OK,
           sqlite3_step(stmt) == SQLITE_ROW, let t = sqlite3_column_text(stmt, 0) {
            table = String(cString: t)
            minX = sqlite3_column_double(stmt, 1); minY = sqlite3_column_double(stmt, 2)
            maxX = sqlite3_column_double(stmt, 3); maxY = sqlite3_column_double(stmt, 4)
            srs = Int(sqlite3_column_int(stmt, 5))
        }
        sqlite3_finalize(stmt)
        guard let tbl = table else { sqlite3_close(db); return nil }
        tableName = tbl

        // Zoom range from the tile matrix (fall back to the tile table).
        var lo = 0, hi = 19
        var zstmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT min(zoom_level), max(zoom_level) FROM gpkg_tile_matrix WHERE table_name=?", -1, &zstmt, nil) == SQLITE_OK {
            sqlite3_bind_text(zstmt, 1, tbl, -1, SQLITE_TRANSIENT)
            if sqlite3_step(zstmt) == SQLITE_ROW, sqlite3_column_type(zstmt, 0) != SQLITE_NULL {
                lo = Int(sqlite3_column_int(zstmt, 0)); hi = Int(sqlite3_column_int(zstmt, 1))
            }
        }
        sqlite3_finalize(zstmt)
        minZoom = lo; maxZoom = hi

        func toLonLat(_ x: Double, _ y: Double) -> (Double, Double) {
            if srs == 3857 || srs == 900913 {
                let lon = x / 6378137.0 * 180.0 / .pi
                let lat = (2.0 * atan(exp(y / 6378137.0)) - .pi / 2.0) * 180.0 / .pi
                return (lon, lat)
            }
            return (x, y)
        }
        let (w, s) = toLonLat(minX, minY)
        let (e, n) = toLonLat(maxX, maxY)
        bounds = (abs(n) <= 90 && abs(s) <= 90 && abs(e) <= 180 && abs(w) <= 180 && n > s) ? (n, s, e, w) : nil
    }

    func tile(z: Int, x: Int, y: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        // GPKG tile_row is top-origin → same as XYZ y (no flip).
        guard sqlite3_prepare_v2(db, "SELECT tile_data FROM \"\(tableName)\" WHERE zoom_level=? AND tile_column=? AND tile_row=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(z)); sqlite3_bind_int(stmt, 2, Int32(x)); sqlite3_bind_int(stmt, 3, Int32(y))
        guard sqlite3_step(stmt) == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 0)))
    }

    deinit { if db != nil { sqlite3_close(db) } }
}

// MARK: - Local tile HTTP server

/// Serves registered tile databases over HTTP on the loopback interface, so
/// Mapbox can load them as an ordinary raster source.
///
/// A Network.framework listener doesn't survive everything iOS does to an app
/// (a suspended app, a reset network stack). When the listener fails or is
/// cancelled the server brings up a new one, on the same port when it can so
/// the URLs the map already holds stay valid, and reports it through `onReady`
/// so the map can re-add any source still pointing at a dead port.
///
/// All state is guarded by `lock`, so `port` is safe to read from any thread.
final class MBTilesTileServer {
    static let shared = MBTilesTileServer()

    private let lock = NSLock()
    private var listener: NWListener?
    private var currentPort: UInt16 = 0
    /// Port to try first when (re)starting: the last one that worked.
    private var preferredPort: UInt16 = 0
    private var restartAttempts = 0
    private var stopped = false
    private var readyHandler: ((UInt16) -> Void)?
    private var dbs: [String: RasterTileDB] = [:]
    private let queue = DispatchQueue(label: "mbtiles.server", attributes: .concurrent)

    deinit { listener?.cancel() }

    /// Called on the main queue every time a listener comes up, with its port.
    var onReady: ((UInt16) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return readyHandler }
        set { lock.lock(); readyHandler = newValue; lock.unlock() }
    }

    /// The port the listener is bound to, or 0 while it isn't listening.
    var port: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return currentPort
    }

    var isReady: Bool { port != 0 }

    /// The live listener, so tests can take it away the way the OS can.
    var listenerForTesting: NWListener? {
        lock.lock(); defer { lock.unlock() }
        return listener
    }

    func register(_ db: RasterTileDB, id: String) {
        lock.lock()
        dbs[id] = db
        stopped = false
        if listener == nil { startListenerLocked() }
        lock.unlock()
    }

    func unregister(_ id: String) {
        lock.lock(); dbs[id] = nil; lock.unlock()
    }

    /// Stop listening and stay down until the next `register`.
    func stop() {
        lock.lock()
        stopped = true
        let old = listener
        listener = nil
        currentPort = 0
        lock.unlock()
        old?.cancel()
    }

    /// Tile URL template for a registered id, or nil while the listener is
    /// down or the id isn't registered (nothing to serve).
    func tileURLTemplate(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard currentPort != 0, dbs[id] != nil else { return nil }
        return "http://127.0.0.1:\(currentPort)/\(id)/{z}/{x}/{y}"
    }

    // MARK: Listener lifecycle (the `…Locked` functions are called with `lock` held)

    private func startListenerLocked() {
        let params = NWParameters.tcp
        // Bind to 127.0.0.1 itself. (requiredInterfaceType = .loopback is not
        // enough: a connection to this machine's own LAN address also arrives
        // on the loopback interface, so it would still be accepted.)
        let port = NWEndpoint.Port(rawValue: preferredPort) ?? .any
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        params.allowLocalEndpointReuse = true
        let l: NWListener
        do {
            l = try NWListener(using: params)
        } catch {
            Logger.map.error("MBTiles tile server: couldn't create a listener: \(error.localizedDescription, privacy: .public)")
            preferredPort = 0
            scheduleRestartLocked()
            return
        }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self = self, let l = l else { return }
            self.listenerStateChanged(state, of: l)
        }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener = l
        l.start(queue: queue)
    }

    private func listenerStateChanged(_ state: NWListener.State, of l: NWListener) {
        lock.lock()
        guard listener === l else { lock.unlock(); return } // a listener we already replaced
        switch state {
        case .ready:
            let p = l.port?.rawValue ?? 0
            currentPort = p
            if p != 0 { preferredPort = p }
            restartAttempts = 0
            let handler = readyHandler
            lock.unlock()
            Logger.map.info("MBTiles tile server listening on 127.0.0.1:\(p, privacy: .public)")
            if p != 0, let handler = handler { DispatchQueue.main.async { handler(p) } }
        case .failed(let error):
            Logger.map.error("MBTiles tile server listener failed: \(error.localizedDescription, privacy: .public)")
            dropListenerLocked()
            lock.unlock()
            l.cancel()
        case .cancelled:
            // Cancelled by the system. (Our own cancel() calls clear `listener`
            // first, so they take the early return above.)
            dropListenerLocked()
            lock.unlock()
        case .waiting(let error):
            // Waiting on the port we asked for (still in use) never resolves
            // on its own: give it up and take any port. Otherwise it is just
            // waiting for the network path, which is not our case on loopback.
            if currentPort == 0, preferredPort != 0 {
                Logger.map.error("MBTiles tile server waiting on port \(self.preferredPort, privacy: .public): \(error.localizedDescription, privacy: .public)")
                dropListenerLocked()
                lock.unlock()
                l.cancel()
            } else {
                lock.unlock()
            }
        default:
            lock.unlock()
        }
    }

    /// The listener is gone. Forget it, give up a port that never came up, and
    /// schedule a replacement.
    private func dropListenerLocked() {
        let hadBeenReady = currentPort != 0
        currentPort = 0
        listener = nil
        if !hadBeenReady { preferredPort = 0 }
        scheduleRestartLocked()
    }

    private func scheduleRestartLocked() {
        guard !stopped, !dbs.isEmpty else { return } // nothing to serve; register() starts it again
        restartAttempts += 1
        // 0.25 s, 0.5 s, 1 s, 2 s, 4 s, then every 8 s.
        let delay = min(0.25 * pow(2.0, Double(restartAttempts - 1)), 8.0)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.restartIfNeeded() }
    }

    private func restartIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, listener == nil, !dbs.isEmpty else { return }
        startListenerLocked()
    }

    // MARK: Requests

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self = self, let data = data,
                  let req = String(data: data, encoding: .utf8),
                  let line = req.split(separator: "\r\n").first else { conn.cancel(); return }
            conn.send(content: self.response(forRequestLine: String(line)),
                      completion: .contentProcessed { _ in conn.cancel() })
        }
    }

    /// The full HTTP response for a request line such as
    /// "GET /<id>/<z>/<x>/<y>[.ext] HTTP/1.1": 200 with the tile, or 404.
    func response(forRequestLine line: String) -> Data {
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let comps = path.split(separator: "/").map(String.init)
        var body: Data?
        var contentType = "image/png"
        if comps.count >= 4,
           let z = Int(comps[1]), let x = Int(comps[2]),
           let y = Int(comps[3].split(separator: ".").first.map(String.init) ?? comps[3]) {
            lock.lock(); let db = dbs[comps[0]]; lock.unlock()
            body = db?.tile(z: z, x: x, y: y)
            contentType = TileImageFormat.contentType(forFormat: db?.format)
        }
        guard let body = body else {
            return "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".data(using: .utf8)!
        }
        var head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".data(using: .utf8)!
        head.append(body)
        return head
    }
}

// MARK: - Overlay record

struct MBTilesOverlay: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var fileName: String   // the .mbtiles file (relative to the store dir)
    var minZoom: Int
    var maxZoom: Int
    var north: Double
    var south: Double
    var east: Double
    var west: Double
    var hasBounds: Bool
    var opacity: Double
    var visible: Bool
    var createdAt: Date
    /// Container format used to reopen the right reader: "mbtiles" or "gpkg".
    var container: String
    /// True when the tile file this entry points at is not on disk. Runtime
    /// state only (never written to the registry): the store works it out on
    /// launch and when the panel opens, so a file that comes back un-flags.
    var fileMissing: Bool = false
    /// Runtime only, never persisted: why a file that IS on disk can't be
    /// drawn (vector tiles, not a tile database). Set when the store opens it.
    var unsupportedReason: String?

    /// False when there is nothing to draw: the file is gone, or it can't be
    /// read as raster tiles.
    var isDrawable: Bool { !fileMissing && unsupportedReason == nil }

    /// `fileMissing` and `unsupportedReason` are deliberately absent: they are
    /// derived from the file, not persisted.
    private enum CodingKeys: String, CodingKey {
        case id, name, fileName, minZoom, maxZoom, north, south, east, west
        case hasBounds, opacity, visible, createdAt, container
    }

    /// The widest longitude span (degrees) a camera can frame and still draw a
    /// raster source whose first tile level is `minZoom`. A Mapbox raster
    /// source draws nothing below its minzoom, and with 256 px tiles level z
    /// first shows at map zoom z - 1; the extra 0.25 is headroom so the camera
    /// settling a hair low doesn't lose the tiles. Framing a small tile set
    /// from further out than this makes an imported overlay look missing.
    static func widestLongitudeSpan(minZoom: Int) -> Double {
        360.0 / pow(2.0, Double(max(minZoom, 0)) - 1.0 + 0.25)
    }

    init(id: String, name: String, fileName: String, minZoom: Int, maxZoom: Int,
         north: Double, south: Double, east: Double, west: Double, hasBounds: Bool,
         opacity: Double = 1.0, visible: Bool = true, createdAt: Date = Date(),
         container: String = "mbtiles") {
        self.id = id; self.name = name; self.fileName = fileName
        self.minZoom = minZoom; self.maxZoom = maxZoom
        self.north = north; self.south = south; self.east = east; self.west = west
        self.hasBounds = hasBounds; self.opacity = opacity; self.visible = visible
        self.createdAt = createdAt; self.container = container
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        fileName = try c.decode(String.self, forKey: .fileName)
        minZoom = try c.decodeIfPresent(Int.self, forKey: .minZoom) ?? 0
        maxZoom = try c.decodeIfPresent(Int.self, forKey: .maxZoom) ?? 19
        north = try c.decodeIfPresent(Double.self, forKey: .north) ?? 0
        south = try c.decodeIfPresent(Double.self, forKey: .south) ?? 0
        east = try c.decodeIfPresent(Double.self, forKey: .east) ?? 0
        west = try c.decodeIfPresent(Double.self, forKey: .west) ?? 0
        hasBounds = try c.decodeIfPresent(Bool.self, forKey: .hasBounds) ?? false
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1.0
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        container = try c.decodeIfPresent(String.self, forKey: .container) ?? "mbtiles"
    }
}

// MARK: - Store

/// One registry entry decoded on its own, so a single damaged entry can't
/// take every other entry down with it (a plain `[MBTilesOverlay]` decode
/// throws for the whole array on the first bad element).
private struct LossyMBTilesOverlay: Decodable {
    let overlay: MBTilesOverlay?
    let failure: String?

    init(from decoder: Decoder) throws {
        do {
            overlay = try MBTilesOverlay(from: decoder)
            failure = nil
        } catch {
            overlay = nil
            failure = String(describing: error)
        }
    }
}

@MainActor
final class MBTilesOverlayStore: ObservableObject {
    static let shared = MBTilesOverlayStore()

    @Published private(set) var overlays: [MBTilesOverlay] = []
    @Published var isImporting = false
    @Published var importStatus = ""
    @Published var lastError: String?
    /// Goes up every time the tile server (re)starts listening. The map
    /// observes this store, so the change re-runs its overlay refresh, which
    /// installs a source that was skipped because the server wasn't up yet and
    /// replaces one that still points at a dead port.
    @Published private(set) var tileServerGeneration = 0

    private let dir: URL
    private let metaURL: URL
    private let server: MBTilesTileServer

    /// Tile files the store owns inside `dir`.
    private static let tileFileExtensions: Set<String> = ["mbtiles", "gpkg"]

    /// `directory` holds the tile files and the `mbtiles.json` registry; the
    /// default is `Documents/MBTiles`. Tests pass a temp directory and their
    /// own tile server so nothing touches the app's real files or the shared
    /// server.
    init(directory: URL? = nil, tileServer: MBTilesTileServer = .shared) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = directory ?? docs.appendingPathComponent("MBTiles", isDirectory: true)
        metaURL = dir.appendingPathComponent("mbtiles.json")
        server = tileServer
        server.onReady = { [weak self] _ in
            // The server calls this on the main queue each time a listener comes up.
            Task { @MainActor in self?.tileServerGeneration += 1 }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
        for i in overlays.indices where !overlays[i].fileMissing { attach(at: i) } // re-register on launch
    }

    func fileURL(_ overlay: MBTilesOverlay) -> URL { dir.appendingPathComponent(overlay.fileName) }

    /// Tile URL for an overlay, or nil when there is nothing to serve (the
    /// file is missing or unusable, or the tile server isn't listening yet).
    func tileURLTemplate(_ overlay: MBTilesOverlay) -> String? {
        guard overlay.isDrawable else { return nil }
        return server.tileURLTemplate(for: overlay.id)
    }

    /// Open a tile file with the right reader. Throws `TileSetError` for a
    /// file that can't be drawn (not a tile database, no tiles, vector tiles).
    private static func openTileDB(at path: String, container: String) throws -> RasterTileDB {
        if container == "gpkg" {
            guard let db = GPKGDb(path: path) else { throw TileSetError.unreadable(kind: "GeoPackage") }
            return db
        }
        return try MBTilesDB(path: path)
    }

    /// Open the entry's file and hand it to the tile server. A file that is
    /// there but can't be drawn (an older build let vector tiles in) is
    /// flagged with the reason instead of being registered.
    private func attach(at index: Int) {
        let overlay = overlays[index]
        do {
            let db = try Self.openTileDB(at: fileURL(overlay).path, container: overlay.container)
            overlays[index].unsupportedReason = nil
            server.register(db, id: overlay.id)
        } catch {
            server.unregister(overlay.id)
            overlays[index].unsupportedReason = error.localizedDescription
            Logger.map.error("MBTiles file can't be drawn: \(self.fileURL(overlay).path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func fileIsPresent(_ overlay: MBTilesOverlay) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(overlay).path)
    }

    /// Re-check which tile files are still on disk. The Documents folder is
    /// visible in the Files app, so a file can be deleted (or put back) while
    /// the app is running; the panel calls this when it opens.
    func refreshFileState() {
        for i in overlays.indices {
            let missing = !fileIsPresent(overlays[i])
            guard missing != overlays[i].fileMissing else { continue }
            overlays[i].fileMissing = missing
            if missing {
                logMissingFile(overlays[i])
                server.unregister(overlays[i].id)
            } else {
                attach(at: i)
            }
        }
    }

    /// Say why an entry has no file, so the next field report can tell a
    /// deleted file from a wiped or relocated store.
    private func logMissingFile(_ overlay: MBTilesOverlay) {
        let fm = FileManager.default
        let dirPresent = fm.fileExists(atPath: dir.path)
        let tileFiles = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { Self.tileFileExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .count
        Logger.map.error("MBTiles file missing for an entry: \(self.fileURL(overlay).path, privacy: .public) (store dir present: \(dirPresent, privacy: .public), tile files in dir: \(tileFiles, privacy: .public), entries: \(self.overlays.count, privacy: .public))")
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    @discardableResult
    func importMBTiles(from url: URL) async -> Bool { await importTileSet(from: url, container: "mbtiles") }

    @discardableResult
    func importGPKG(from url: URL) async -> Bool { await importTileSet(from: url, container: "gpkg") }

    @discardableResult
    private func importTileSet(from url: URL, container: String) async -> Bool {
        let label = container == "gpkg" ? "GeoPackage" : "MBTiles"
        isImporting = true; lastError = nil; importStatus = "Reading \(label)…"
        let id = UUID().uuidString
        let dest = dir.appendingPathComponent("\(id).\(container)")
        do {
            ensureDirectory() // the folder is visible in Files; it may have been deleted
            try FileManager.default.copyItem(at: url, to: dest)
            let db = try Self.openTileDB(at: dest.path, container: container) // rejects vector / unreadable files
            server.register(db, id: id)
            let b = db.bounds
            overlays.append(MBTilesOverlay(
                id: id, name: url.deletingPathExtension().lastPathComponent, fileName: dest.lastPathComponent,
                minZoom: db.minZoom, maxZoom: db.maxZoom,
                north: b?.n ?? 85, south: b?.s ?? -85, east: b?.e ?? 180, west: b?.w ?? -180,
                hasBounds: b != nil, container: container
            ))
            persist()
            importStatus = "Imported \(label) (z\(db.minZoom)–\(db.maxZoom))"
            isImporting = false
            return true
        } catch {
            try? FileManager.default.removeItem(at: dest)
            // A TileSetError is already a full sentence saying what is wrong
            // with the file; other errors (copy failed...) get the prefix.
            lastError = error is TileSetError ? error.localizedDescription : "\(label) import failed: \(error.localizedDescription)"
            importStatus = ""; isImporting = false
            return false
        }
    }

    func setVisible(_ id: String, _ visible: Bool) { mutate(id) { $0.visible = visible } }
    func setOpacity(_ id: String, _ value: Double) { mutate(id) { $0.opacity = min(max(value, 0.05), 1.0) } }
    func rename(_ id: String, to name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate(id) { $0.name = t }
    }

    /// Delete one tile set. Works for an entry whose file is already gone
    /// (nothing to delete on disk, the entry is still dropped).
    func remove(_ id: String) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        server.unregister(id)
        deleteFile(of: overlays[idx])
        overlays.remove(at: idx); persist()
    }

    /// Delete every tile set, including files the store imported that no
    /// entry points at any more (left behind when the registry was unreadable
    /// or lost an entry). Only `<uuid>.mbtiles` / `<uuid>.gpkg` names are
    /// swept; a file someone dropped into the folder by hand is left alone.
    func removeAll() {
        for o in overlays {
            server.unregister(o.id)
            deleteFile(of: o)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in leftovers
        where Self.tileFileExtensions.contains(file.pathExtension.lowercased())
            && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: file)
        }
        overlays.removeAll(); persist()
    }

    /// Remove an entry's tile file. A file that is already gone is fine; any
    /// other failure is reported instead of swallowed.
    private func deleteFile(of overlay: MBTilesOverlay) {
        let url = fileURL(overlay)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Logger.map.error("MBTiles delete failed: \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't delete the tile file: \(error.localizedDescription)"
        }
    }

    private func mutate(_ id: String, _ change: (inout MBTilesOverlay) -> Void) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        change(&overlays[idx]); persist()
    }

    /// Write the registry atomically (temp file + rename), so a kill or crash
    /// mid-write can't leave a truncated `mbtiles.json` that drops every entry
    /// on the next launch.
    private func persist() {
        do {
            ensureDirectory()
            let data = try JSONEncoder().encode(overlays)
            try data.write(to: metaURL, options: .atomic)
        } catch {
            Logger.map.error("MBTiles registry save failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't save the tile set list: \(error.localizedDescription)"
        }
    }

    /// Read the registry. Entries are decoded one by one and an entry whose
    /// file is missing is kept and flagged, never dropped: it has to stay
    /// visible so the user can see the problem and delete it.
    private func load() {
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return } // first launch
        let data: Data
        do {
            data = try Data(contentsOf: metaURL)
        } catch {
            Logger.map.error("MBTiles registry unreadable: \(self.metaURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = "Couldn't read the saved tile set list: \(error.localizedDescription)"
            return
        }
        let entries: [LossyMBTilesOverlay]
        do {
            entries = try JSONDecoder().decode([LossyMBTilesOverlay].self, from: data)
        } catch {
            // Not a JSON array at all (damaged or truncated). Keep a copy for
            // diagnosis before the next save replaces it.
            Logger.map.error("MBTiles registry is not valid JSON, keeping a copy: \(String(describing: error), privacy: .public)")
            let keep = dir.appendingPathComponent("mbtiles.json.unreadable")
            try? FileManager.default.removeItem(at: keep)
            try? FileManager.default.copyItem(at: metaURL, to: keep)
            lastError = "The saved tile set list is damaged and couldn't be read. Tile files already on this device are still there; import them again to use them."
            return
        }

        var loaded: [MBTilesOverlay] = []
        var skipped = 0
        for entry in entries {
            guard var overlay = entry.overlay else {
                skipped += 1
                Logger.map.error("MBTiles registry entry skipped, couldn't decode it: \(entry.failure ?? "unknown", privacy: .public)")
                continue
            }
            overlay.fileMissing = !fileIsPresent(overlay)
            loaded.append(overlay)
        }
        overlays = loaded
        for overlay in loaded where overlay.fileMissing { logMissingFile(overlay) }
        if skipped > 0 {
            lastError = skipped == 1
                ? "1 saved tile set couldn't be read and was skipped."
                : "\(skipped) saved tile sets couldn't be read and were skipped."
        }
    }
}

// MARK: - Files handed to the app

/// Overlay files the app takes when another app hands it a file ("Open in
/// OmniTAK" from Files, Mail, AirDrop). Kept separate from `onOpenURL` so the
/// routing can be tested.
enum OpenedOverlayFile {
    case kml
    case mbtiles
    case gpkg

    init?(url: URL) {
        guard url.isFileURL else { return nil }
        switch url.pathExtension.lowercased() {
        case "kml", "kmz": self = .kml
        case "mbtiles": self = .mbtiles
        case "gpkg": self = .gpkg
        default: return nil
        }
    }
}
