//
//  MBTilesOverlayStoreTests.swift
//  OmniTAKMobileTests
//
//  Regression tests for issue #130: imported MBTiles vanished after restarts
//  and could not be deleted.
//
//  Root cause: MBTilesOverlayStore.load() silently dropped any entry whose tile
//  file was missing (and never wrote the list back), and one undecodable entry
//  dropped the whole list. remove(_:) needs the entry to be present, so a
//  vanished entry could never be cleaned up.
//
//  Every test runs the store against a temp directory with its own tile server
//  (MBTilesOverlayStore.init(directory:tileServer:)), so nothing touches the
//  app's Documents folder or MBTilesTileServer.shared.
//

import XCTest
import SQLite3
import UniformTypeIdentifiers
@testable import OmniTAK

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Fixture

/// Builds small, real .mbtiles files for tests (a SQLite file with `metadata`
/// and `tiles` tables, like the files operators import).
enum MBTilesTestFixture {
    enum FixtureError: Error { case sqlite(String) }

    /// A valid 1x1 PNG.
    static let pngTile = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    /// Write an MBTiles file at `url`. `tiles` are given in XYZ coordinates and
    /// stored in TMS row order, as the format requires. Pass `bounds: nil` for a
    /// file with no `bounds` row.
    @discardableResult
    static func makeMBTiles(
        at url: URL,
        format: String = "png",
        bounds: String? = "-122.5,47.5,-122.0,47.8",
        minZoom: Int = 0,
        maxZoom: Int = 4,
        tiles: [(z: Int, x: Int, y: Int)] = [(1, 0, 0)],
        tileData: Data = pngTile
    ) throws -> URL {
        try? FileManager.default.removeItem(at: url)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw FixtureError.sqlite("open \(url.path)")
        }
        defer { sqlite3_close(db) }

        func exec(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
        try exec("CREATE TABLE metadata (name TEXT, value TEXT)")
        try exec("CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)")

        var meta: [(String, String)] = [
            ("name", url.deletingPathExtension().lastPathComponent),
            ("format", format),
            ("minzoom", String(minZoom)),
            ("maxzoom", String(maxZoom)),
        ]
        if let bounds = bounds { meta.append(("bounds", bounds)) }
        for (name, value) in meta {
            try exec("INSERT INTO metadata (name, value) VALUES ('\(name)', '\(value)')")
        }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO tiles VALUES (?, ?, ?, ?)", -1, &stmt, nil) == SQLITE_OK else {
            throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for t in tiles {
            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(t.z))
            sqlite3_bind_int(stmt, 2, Int32(t.x))
            sqlite3_bind_int(stmt, 3, Int32((1 << t.z) - 1 - t.y)) // XYZ -> TMS row
            tileData.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 4, raw.baseAddress, Int32(tileData.count), sqliteTransient)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw FixtureError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
        }
        return url
    }
}

// MARK: - Store tests

final class MBTilesOverlayStoreTests: XCTestCase {

    private var root: URL!
    private var storeDir: URL!
    private var sourceDir: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MBTilesOverlayStoreTests-\(UUID().uuidString)", isDirectory: true)
        storeDir = root.appendingPathComponent("store", isDirectory: true)
        sourceDir = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A store over the temp directory. Calling it again simulates an app
    /// relaunch: a fresh store reading the same folder.
    @MainActor
    private func makeStore() -> MBTilesOverlayStore {
        MBTilesOverlayStore(directory: storeDir, tileServer: MBTilesTileServer())
    }

    @MainActor
    private func importFixture(_ name: String, into store: MBTilesOverlayStore,
                               bounds: String? = "-122.5,47.5,-122.0,47.8") async throws -> MBTilesOverlay {
        let file = try MBTilesTestFixture.makeMBTiles(
            at: sourceDir.appendingPathComponent("\(name).mbtiles"), bounds: bounds)
        let before = Set(store.overlays.map(\.id))
        let ok = await store.importMBTiles(from: file)
        XCTAssertTrue(ok, "import of \(name) should succeed; error: \(store.lastError ?? "none")")
        return try XCTUnwrap(store.overlays.first { !before.contains($0.id) })
    }

    private func registryJSON() throws -> [[String: Any]] {
        let data = try Data(contentsOf: storeDir.appendingPathComponent("mbtiles.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    private func writeRegistryJSON(_ entries: [[String: Any]]) throws {
        let data = try JSONSerialization.data(withJSONObject: entries)
        try data.write(to: storeDir.appendingPathComponent("mbtiles.json"))
    }

    // MARK: Missing file

    /// The bug: an entry whose file was gone disappeared from the list.
    @MainActor
    func testEntryWithMissingFileIsKeptAndFlagged() async throws {
        let store = makeStore()
        let imported = try await importFixture("lake", into: store)
        XCTAssertFalse(imported.fileMissing)

        // The file disappears between launches (deleted from Files, wiped...).
        try FileManager.default.removeItem(at: store.fileURL(imported))

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.overlays.map(\.id), [imported.id],
                       "an entry whose file is gone must stay listed, not vanish")
        let entry = try XCTUnwrap(relaunched.overlays.first)
        XCTAssertTrue(entry.fileMissing)
        XCTAssertNil(relaunched.tileURLTemplate(entry), "a missing file has nothing to serve")

        // Loading must not rewrite or drop anything on disk, and the derived
        // flag must never be persisted (a file that returns has to un-flag).
        let json = try registryJSON()
        XCTAssertEqual(json.count, 1)
        XCTAssertNil(json.first?["fileMissing"])
    }

    @MainActor
    func testMissingEntryCanBeRemovedAndStaysRemoved() async throws {
        let store = makeStore()
        let imported = try await importFixture("lake", into: store)
        try FileManager.default.removeItem(at: store.fileURL(imported))

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.overlays.count, 1)
        relaunched.remove(imported.id)

        XCTAssertTrue(relaunched.overlays.isEmpty, "remove(_:) must work on a flagged entry")
        XCTAssertTrue(makeStore().overlays.isEmpty, "the removal must be persisted")
        XCTAssertEqual(try registryJSON().count, 0)
    }

    @MainActor
    func testFileThatComesBackUnflagsTheEntry() async throws {
        let store = makeStore()
        let imported = try await importFixture("lake", into: store)
        let url = store.fileURL(imported)
        let held = root.appendingPathComponent("held.mbtiles")
        try FileManager.default.moveItem(at: url, to: held)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.overlays.first?.fileMissing, true)

        try FileManager.default.moveItem(at: held, to: url) // file restored
        relaunched.refreshFileState()
        XCTAssertEqual(relaunched.overlays.first?.fileMissing, false)

        try FileManager.default.removeItem(at: url) // and gone again while running
        relaunched.refreshFileState()
        XCTAssertEqual(relaunched.overlays.first?.fileMissing, true)
    }

    @MainActor
    func testRemovingAnEntryDeletesItsTileFile() async throws {
        let store = makeStore()
        let a = try await importFixture("a", into: store)
        let b = try await importFixture("b", into: store)

        store.remove(a.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(a).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.fileURL(b).path))
        XCTAssertEqual(store.overlays.map(\.id), [b.id])
    }

    @MainActor
    func testRemoveAllAlsoSweepsImportedFilesNoEntryPointsAt() async throws {
        let store = makeStore()
        let a = try await importFixture("a", into: store)

        // A file the store imported earlier whose entry was lost, and a file
        // someone dropped into the folder by hand.
        let orphan = storeDir.appendingPathComponent("\(UUID().uuidString).mbtiles")
        try FileManager.default.copyItem(at: store.fileURL(a), to: orphan)
        let handMade = storeDir.appendingPathComponent("my-own-notes.mbtiles")
        try FileManager.default.copyItem(at: store.fileURL(a), to: handMade)

        store.removeAll()

        XCTAssertTrue(store.overlays.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(a).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path), "orphaned import should be swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: handMade.path), "a hand-placed file is not ours to delete")
        XCTAssertEqual(try registryJSON().count, 0)
    }

    // MARK: Corrupt registry

    @MainActor
    func testCorruptEntryDoesNotDropItsSiblings() async throws {
        let store = makeStore()
        let a = try await importFixture("a", into: store)
        let b = try await importFixture("b", into: store)
        let c = try await importFixture("c", into: store)

        // Damage only the middle entry: a wrong type fails its decode.
        var json = try registryJSON()
        let middle = try XCTUnwrap(json.firstIndex { ($0["id"] as? String) == b.id })
        json[middle]["opacity"] = "not a number"
        try writeRegistryJSON(json)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.overlays.map(\.id), [a.id, c.id],
                       "the two healthy entries must survive one damaged entry")
        XCTAssertEqual(relaunched.overlays.map(\.fileMissing), [false, false])
        XCTAssertEqual(relaunched.lastError, "1 saved tile set couldn't be read and was skipped.")
    }

    @MainActor
    func testSeveralDamagedEntriesAreCounted() async throws {
        let store = makeStore()
        let a = try await importFixture("a", into: store)
        _ = try await importFixture("b", into: store)
        _ = try await importFixture("c", into: store)

        var json = try registryJSON()
        json[1].removeValue(forKey: "name") // required field gone
        json[2]["fileName"] = 42            // wrong type
        try writeRegistryJSON(json)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.overlays.map(\.id), [a.id])
        XCTAssertEqual(relaunched.lastError, "2 saved tile sets couldn't be read and were skipped.")
    }

    @MainActor
    func testUnreadableRegistryIsKeptAndReported() throws {
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let garbage = Data("[{\"id\": \"truncated mid-wri".utf8)
        try garbage.write(to: storeDir.appendingPathComponent("mbtiles.json"))

        let store = makeStore()

        XCTAssertTrue(store.overlays.isEmpty)
        XCTAssertNotNil(store.lastError, "a damaged registry must be reported, not silently ignored")
        let kept = try Data(contentsOf: storeDir.appendingPathComponent("mbtiles.json.unreadable"))
        XCTAssertEqual(kept, garbage, "a copy of the damaged file is kept for diagnosis")
    }

    @MainActor
    func testStoreWorksAfterAnUnreadableRegistry() async throws {
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: storeDir.appendingPathComponent("mbtiles.json"))

        let store = makeStore()
        let imported = try await importFixture("fresh", into: store)

        XCTAssertNil(store.lastError, "a successful import clears the old error")
        XCTAssertEqual(makeStore().overlays.map(\.id), [imported.id])
    }

    // MARK: Persistence

    @MainActor
    func testPersistenceRoundTrip() async throws {
        let store = makeStore()
        let withBounds = try await importFixture("harbor", into: store)
        let noBounds = try await importFixture("plain", into: store, bounds: nil)
        store.rename(withBounds.id, to: "Harbor approach")
        store.setOpacity(withBounds.id, 0.4)
        store.setVisible(withBounds.id, false)

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.overlays.count, 2)
        XCTAssertNil(relaunched.lastError)

        let a = try XCTUnwrap(relaunched.overlays.first { $0.id == withBounds.id })
        XCTAssertEqual(a.name, "Harbor approach")
        XCTAssertEqual(a.opacity, 0.4, accuracy: 1e-9)
        XCTAssertFalse(a.visible)
        XCTAssertTrue(a.hasBounds)
        XCTAssertEqual(a.west, -122.5, accuracy: 1e-9)
        XCTAssertEqual(a.south, 47.5, accuracy: 1e-9)
        XCTAssertEqual(a.east, -122.0, accuracy: 1e-9)
        XCTAssertEqual(a.north, 47.8, accuracy: 1e-9)
        XCTAssertEqual(a.minZoom, 0)
        XCTAssertEqual(a.maxZoom, 4)
        XCTAssertEqual(a.container, "mbtiles")
        XCTAssertEqual(a.fileName, withBounds.fileName)
        XCTAssertFalse(a.fileMissing)

        let b = try XCTUnwrap(relaunched.overlays.first { $0.id == noBounds.id })
        XCTAssertFalse(b.hasBounds)
        XCTAssertTrue(b.visible)
    }

    /// A registry written by an older build has no `fileMissing`, `container`
    /// or other optional keys; it must still load.
    @MainActor
    func testRegistryFromAnOlderBuildStillLoads() async throws {
        let store = makeStore()
        let imported = try await importFixture("old", into: store)

        let minimal: [[String: Any]] = [[
            "id": imported.id, "name": "Old entry", "fileName": imported.fileName,
        ]]
        try writeRegistryJSON(minimal)

        let relaunched = makeStore()
        let entry = try XCTUnwrap(relaunched.overlays.first)
        XCTAssertEqual(entry.name, "Old entry")
        XCTAssertEqual(entry.container, "mbtiles")
        XCTAssertEqual(entry.opacity, 1.0, accuracy: 1e-9)
        XCTAssertFalse(entry.fileMissing)
        XCTAssertNil(relaunched.lastError)
    }

    @MainActor
    func testRegistryIsValidJSONAndLeavesNoTempFilesBehind() async throws {
        let store = makeStore()
        let a = try await importFixture("a", into: store)
        store.setOpacity(a.id, 0.5)
        store.setVisible(a.id, false)
        store.rename(a.id, to: "Renamed")

        XCTAssertEqual(try registryJSON().count, 1)
        let names = try FileManager.default.contentsOfDirectory(atPath: storeDir.path).sorted()
        XCTAssertEqual(names, ["mbtiles.json", a.fileName].sorted(),
                       "an atomic write must not leave a temp file next to the registry")
    }

    // MARK: Errors

    @MainActor
    func testImportFailureIsReportedOnTheStoresOwnLastError() async throws {
        let store = makeStore()
        let ok = await store.importMBTiles(from: sourceDir.appendingPathComponent("does-not-exist.mbtiles"))

        XCTAssertFalse(ok)
        XCTAssertTrue(store.overlays.isEmpty)
        let message = try XCTUnwrap(store.lastError)
        XCTAssertTrue(message.hasPrefix("MBTiles import failed"), message)
    }
}

// MARK: - File type declarations (the other half of #130)

final class OverlayFileTypeDeclarationTests: XCTestCase {

    private var bundle: Bundle { Bundle(for: MBTilesOverlayStore.self) }

    private func importedExtensions() throws -> Set<String> {
        let decls = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "UTImportedTypeDeclarations") as? [[String: Any]])
        var out = Set<String>()
        for decl in decls {
            let spec = decl["UTTypeTagSpecification"] as? [String: Any]
            for ext in (spec?["public.filename-extension"] as? [String]) ?? [] { out.insert(ext) }
        }
        return out
    }

    func testInfoPlistDeclaresImportedTypesForEveryOverlayExtension() throws {
        let declared = try importedExtensions()
        for ext in ["kml", "kmz", "mbtiles", "gpkg"] {
            XCTAssertTrue(declared.contains(ext), "Info.plist must declare an imported type for .\(ext)")
        }
    }

    /// Without a declaration `.mbtiles` / `.gpkg` are dynamic types and the
    /// document picker can grey the files out.
    func testMBTilesAndGPKGResolveToDeclaredTypes() {
        for ext in ["mbtiles", "gpkg"] {
            let type = UTType(filenameExtension: ext)
            XCTAssertNotNil(type, ".\(ext) should resolve to a type")
            XCTAssertEqual(type?.isDynamic, false, ".\(ext) resolved to a dynamic type, so Info.plist's declaration is not in effect")
        }
    }

    func testTileSetsAreRegisteredAsOpenableDocumentTypes() throws {
        let docTypes = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let handled = Set(docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })
        for ext in ["mbtiles", "gpkg"] {
            let id = try XCTUnwrap(UTType(filenameExtension: ext)?.identifier)
            XCTAssertTrue(handled.contains(id), "\"Open in OmniTAK\" must be offered for .\(ext) (\(id))")
        }
    }

    /// onOpenURL: kml/kmz and the two tile formats are overlay files, anything
    /// else (tak:// links, other files, web URLs) falls through to deep links.
    func testOpenedOverlayFileRouting() {
        XCTAssertEqual(OpenedOverlayFile(url: URL(fileURLWithPath: "/tmp/Lake.kml")), .kml)
        XCTAssertEqual(OpenedOverlayFile(url: URL(fileURLWithPath: "/tmp/Lake.KMZ")), .kml)
        XCTAssertEqual(OpenedOverlayFile(url: URL(fileURLWithPath: "/tmp/Lake.mbtiles")), .mbtiles)
        XCTAssertEqual(OpenedOverlayFile(url: URL(fileURLWithPath: "/tmp/Lake.MBTiles")), .mbtiles)
        XCTAssertEqual(OpenedOverlayFile(url: URL(fileURLWithPath: "/tmp/Lake.gpkg")), .gpkg)

        XCTAssertNil(OpenedOverlayFile(url: URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertNil(OpenedOverlayFile(url: URL(string: "tak://enroll?host=tak.example.mil")!))
        XCTAssertNil(OpenedOverlayFile(url: URL(string: "https://example.com/Lake.mbtiles")!),
                     "only file URLs are overlay files")
    }
}
