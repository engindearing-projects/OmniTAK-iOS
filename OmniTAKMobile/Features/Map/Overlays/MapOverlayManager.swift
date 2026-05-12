//
//  UserMapOverlayManager.swift
//  OmniTAKMobile
//
//  CRUD store for user-imported, passive map overlays (Issue #17).
//
//  Responsibilities:
//    - Persist [UserMapOverlay] to Documents/map_overlays.json.
//    - Copy imported files into Documents/MapOverlays/<uuid>.<ext>.
//    - On demand, hydrate each descriptor's MKOverlays by parsing the
//      source file via KMLParser / KMZHandler and KMLOverlayRenderer.
//    - GeoPDF is recognised but import is disabled (parser deferred).
//
//  See docs/specs/map-overlays.md.
//

import Foundation
import MapKit
import Combine

@MainActor
final class UserMapOverlayManager: ObservableObject {

    static let shared = UserMapOverlayManager()

    @Published private(set) var overlays: [UserMapOverlay] = []
    @Published var isImporting: Bool = false
    @Published var lastError: String?

    private let fileManager = FileManager.default
    private let overlaysDirectory: URL
    private let indexURL: URL

    /// Cached parsed MKOverlays per descriptor id. Recomputed on demand.
    private var cachedOverlays: [UUID: [MKOverlay]] = [:]

    private init() {
        let docs = fileManager.urls(for: .documentDirectory,
                                    in: .userDomainMask)[0]
        self.overlaysDirectory = docs.appendingPathComponent("MapOverlays",
                                                             isDirectory: true)
        self.indexURL = docs.appendingPathComponent("map_overlays.json")
        try? fileManager.createDirectory(at: overlaysDirectory,
                                         withIntermediateDirectories: true)
        loadIndex()
    }

    // MARK: - Public API

    /// Best-guess UserMapOverlayKind from a file URL's extension.
    static func kind(for url: URL) -> UserMapOverlayKind? {
        switch url.pathExtension.lowercased() {
        case "kml":   return .kml
        case "kmz":   return .kmz
        case "pdf":   return .geoPDF
        default:      return nil
        }
    }

    /// Import a file selected via SwiftUI .fileImporter. Throws if the
    /// kind is not yet supported (e.g. GeoPDF).
    func importFile(from url: URL) async throws {
        defer { isImporting = false }
        isImporting = true
        lastError = nil

        guard let kind = Self.kind(for: url) else {
            throw ImportError.unsupportedFormat(extension: url.pathExtension)
        }
        guard kind.isImportable else {
            throw ImportError.kindNotYetSupported(kind: kind)
        }

        // The file picker hands us a security-scoped URL on real devices.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        let originalName = url.deletingPathExtension().lastPathComponent
        let id = UUID()
        let destExtension = kind == .kmz ? "kmz" : (kind == .kml ? "kml" : "pdf")
        let storedFileName = "\(id.uuidString).\(destExtension)"
        let destination = overlaysDirectory.appendingPathComponent(storedFileName)

        do {
            let data = try Data(contentsOf: url)
            try data.write(to: destination, options: .atomic)
        } catch {
            lastError = "Failed to copy overlay file: \(error.localizedDescription)"
            throw error
        }

        // Parse once to compute bounds and to warm the overlay cache.
        let parsedOverlays: [MKOverlay]
        let bounds: UserMapOverlayBounds?
        do {
            let (document, _) = try Self.parseKMLDocument(at: destination, kind: kind)
            parsedOverlays = KMLOverlayRenderer.makeOverlays(from: document,
                                                            overlayId: id)
            bounds = KMLOverlayRenderer.bounds(of: document)
        } catch {
            try? fileManager.removeItem(at: destination)
            lastError = "Failed to parse overlay: \(error.localizedDescription)"
            throw error
        }

        let descriptor = UserMapOverlay(id: id,
                                              name: originalName,
                                              kind: kind,
                                              sourceFileName: storedFileName,
                                              bounds: bounds)
        overlays.append(descriptor)
        cachedOverlays[id] = parsedOverlays
        saveIndex()
    }

    func setOpacity(_ opacity: Double, for id: UUID) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[idx].opacity = max(0.0, min(1.0, opacity))
        saveIndex()
    }

    func setVisible(_ visible: Bool, for id: UUID) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        overlays[idx].isVisible = visible
        saveIndex()
    }

    func rename(_ id: UUID, to name: String) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        overlays[idx].name = trimmed
        saveIndex()
    }

    func delete(_ id: UUID) {
        guard let idx = overlays.firstIndex(where: { $0.id == id }) else { return }
        let descriptor = overlays.remove(at: idx)
        cachedOverlays.removeValue(forKey: id)
        let url = overlaysDirectory.appendingPathComponent(descriptor.sourceFileName)
        try? fileManager.removeItem(at: url)
        saveIndex()
    }

    /// All MKOverlays from descriptors that are currently visible. Parses
    /// lazily and caches the result per descriptor id.
    func visibleMKOverlays() -> [(UserMapOverlay, [MKOverlay])] {
        var result: [(UserMapOverlay, [MKOverlay])] = []
        for descriptor in overlays where descriptor.isVisible {
            let overlays = cachedOverlays[descriptor.id] ?? loadOverlays(for: descriptor)
            cachedOverlays[descriptor.id] = overlays
            result.append((descriptor, overlays))
        }
        return result
    }

    /// Look up the owning descriptor for an MKOverlay produced by this
    /// manager. Returns nil for overlays that originate elsewhere.
    func descriptor(for overlay: MKOverlay) -> UserMapOverlay? {
        let id: UUID?
        if let p = overlay as? MapOverlayPolygon { id = p.overlayId }
        else if let l = overlay as? MapOverlayPolyline { id = l.overlayId }
        else { id = nil }
        guard let id else { return nil }
        return overlays.first(where: { $0.id == id })
    }

    // MARK: - Errors

    enum ImportError: LocalizedError {
        case unsupportedFormat(extension: String)
        case kindNotYetSupported(kind: UserMapOverlayKind)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                return "Unsupported file extension '.\(ext)'. KML and KMZ are supported today."
            case .kindNotYetSupported(let kind):
                return "\(kind.displayName) import is coming in a future build."
            }
        }
    }

    // MARK: - Private

    private func loadOverlays(for descriptor: UserMapOverlay) -> [MKOverlay] {
        let url = overlaysDirectory.appendingPathComponent(descriptor.sourceFileName)
        do {
            let (document, _) = try Self.parseKMLDocument(at: url, kind: descriptor.kind)
            return KMLOverlayRenderer.makeOverlays(from: document, overlayId: descriptor.id)
        } catch {
            print("UserMapOverlayManager: failed to load \(descriptor.name): \(error)")
            return []
        }
    }

    private static func parseKMLDocument(at url: URL,
                                         kind: UserMapOverlayKind) throws -> (KMLDocument, [String: Data]) {
        let data: Data
        var resources: [String: Data] = [:]
        switch kind {
        case .kml:
            data = try Data(contentsOf: url)
        case .kmz:
            (data, resources) = try KMZHandler.extractKML(from: url)
        case .geoPDF:
            throw ImportError.kindNotYetSupported(kind: .geoPDF)
        }
        let document = try KMLParser(fileName: url.lastPathComponent).parse(data: data)
        return (document, resources)
    }

    private func loadIndex() {
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            self.overlays = try decoder.decode([UserMapOverlay].self, from: data)
        } catch {
            print("UserMapOverlayManager: failed to load index: \(error)")
        }
    }

    private func saveIndex() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(overlays)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("UserMapOverlayManager: failed to save index: \(error)")
        }
    }
}
