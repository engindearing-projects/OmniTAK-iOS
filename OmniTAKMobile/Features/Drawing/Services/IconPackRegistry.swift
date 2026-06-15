//
//  IconPackRegistry.swift
//  OmniTAKMobile
//
//  Issue #75 Phase 2 — runtime registry for imported ATAK iconset packs.
//
//  Imported packs land in `<app-support>/iconpacks/<uid>/` after extraction by
//  `IconPackImporter`. This registry:
//    - persists the pack metadata list across launches (packs.json)
//    - resolves a `usericon iconsetpath` to the pack that owns it
//    - loads the matching image file as a `UIImage` for `TAKIconRegistry`
//    - exposes the full selectable catalogue for the icon picker
//
//  Thread safety: all mutable state is guarded by `lock`. Image loads are
//  dispatched to a background queue by the caller.
//

import Foundation
import UIKit

// MARK: - Imported Pack Models (Codable for persistence)

/// Lightweight descriptor for a single imported icon entry.
struct ImportedIcon: Codable, Equatable, Identifiable {
    /// Display / lookup name.
    let name: String
    /// Relative path from the pack directory, e.g. `"Ground/Ambulance.png"`.
    let filename: String

    var id: String { filename }

    /// ATAK `iconsetpath` token (filename without extension).
    var pathToken: String {
        var s = filename
        if let dot = s.lastIndex(of: "."), dot != s.startIndex { s = String(s[..<dot]) }
        return s
    }
}

/// Persistent descriptor for an imported pack.
struct ImportedPack: Codable, Equatable, Identifiable {
    /// The pack's UUID — first component of every `iconsetpath` it owns.
    let uid: String
    /// Human-readable name.
    let name: String
    /// Pack version.
    let version: Int
    /// All icon entries for this pack.
    let icons: [ImportedIcon]

    var id: String { uid }
}

// MARK: - IconPackRegistry

/// App-scoped singleton. Safe to call from any thread.
final class IconPackRegistry {

    static let shared = IconPackRegistry()

    private init() {}

    private let lock = NSLock()
    private var packs: [ImportedPack] = []
    private var index: [String: ImportedPack] = [:]   // uid → pack
    private var didLoad = false

    // MARK: - Lifecycle

    /// Ensure packs.json has been read. Idempotent, thread-safe.
    func ensureLoaded() {
        lock.lock(); defer { lock.unlock() }
        guard !didLoad else { return }
        loadLocked()
        didLoad = true
    }

    // MARK: - Query

    /// All currently imported packs, in import order.
    func allPacks() -> [ImportedPack] {
        ensureLoaded()
        lock.lock(); defer { lock.unlock() }
        return packs
    }

    /// Whether any imported pack claims this iconset path.
    func handles(_ iconsetPath: String?) -> Bool {
        resolve(iconsetPath) != nil
    }

    /// Resolve an ATAK `iconsetpath` to its pack + icon entry.
    ///
    /// Wire format: `"<uid>/<filename-no-ext>"`, e.g.
    /// `"f47ac10b-…/Ground/Ambulance"`. Returns nil when no pack owns it.
    func resolve(_ iconsetPath: String?) -> (pack: ImportedPack, icon: ImportedIcon)? {
        guard let path = iconsetPath, !path.isEmpty else { return nil }
        ensureLoaded()
        guard let slash = path.firstIndex(of: "/") else { return nil }
        let uid = String(path[..<slash])
        let token = String(path[path.index(after: slash)...]).removingExtension

        lock.lock()
        let pack = index[uid]
        lock.unlock()

        guard let pack else { return nil }
        let icon = pack.icons.first { icon in
            let t = icon.filename.removingExtension
            return t == token || t.baseName == token.baseName
        }
        guard let icon else { return nil }
        return (pack, icon)
    }

    /// Load the `UIImage` for a resolved icon from app-private storage.
    /// Returns nil when the file is missing or unreadable. Call off the main
    /// thread — does file I/O.
    func loadImage(pack: ImportedPack, icon: ImportedIcon) -> UIImage? {
        let fileURL = packDirectory(for: pack.uid).appendingPathComponent(icon.filename)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    /// Stable image-cache key for an imported icon.
    /// Format: `"import-<uid>-<pathToken>"`, distinct from bundled TAK keys.
    func cacheKey(for iconsetPath: String) -> String {
        let slash = iconsetPath.firstIndex(of: "/")
        guard let slash else { return "import-\(iconsetPath)" }
        let uid = String(iconsetPath[..<slash])
        let token = String(iconsetPath[iconsetPath.index(after: slash)...]).removingExtension
        return "import-\(uid)-\(token)"
    }

    // MARK: - Mutating

    /// Register a newly imported pack. Replaces any existing pack with the same
    /// uid (re-import / update path). Persists immediately.
    func register(_ pack: ImportedPack) {
        ensureLoaded()
        lock.lock()
        packs.removeAll { $0.uid == pack.uid }
        index.removeValue(forKey: pack.uid)
        packs.append(pack)
        index[pack.uid] = pack
        saveLocked()
        lock.unlock()
    }

    /// Remove a pack by uid. Returns true when found and removed.
    @discardableResult
    func remove(uid: String) -> Bool {
        ensureLoaded()
        lock.lock()
        let removed = packs.contains { $0.uid == uid }
        packs.removeAll { $0.uid == uid }
        index.removeValue(forKey: uid)
        if removed { saveLocked() }
        lock.unlock()
        if removed {
            try? FileManager.default.removeItem(at: packDirectory(for: uid))
        }
        return removed
    }

    // MARK: - Paths

    /// App-private directory for a pack's extracted images.
    func packDirectory(for uid: String) -> URL {
        baseDirectory.appendingPathComponent(uid, isDirectory: true)
    }

    private var baseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iconpacks", isDirectory: true)
    }

    private var packsJSONURL: URL {
        baseDirectory.appendingPathComponent("packs.json")
    }

    // MARK: - Persistence (caller must hold lock)

    private func loadLocked() {
        guard let data = try? Data(contentsOf: packsJSONURL) else { return }
        let decoded = try? JSONDecoder().decode([ImportedPack].self, from: data)
        let list = decoded ?? []
        packs = list
        index = Dictionary(uniqueKeysWithValues: list.map { ($0.uid, $0) })
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(packs) else { return }
        try? FileManager.default.createDirectory(at: baseDirectory,
                                                  withIntermediateDirectories: true)
        try? data.write(to: packsJSONURL, options: .atomic)
    }
}

// MARK: - String file-path helpers

private extension String {
    var removingExtension: String {
        guard let dot = lastIndex(of: "."), dot != startIndex else { return self }
        return String(self[..<dot])
    }
    var baseName: String {
        String(split(separator: "/").last ?? Substring(self))
    }
}
