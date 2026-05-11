//
//  DataPackageBootstrap.swift
//  OmniTAKMobile
//
//  GAP-112 — iOS auto-import of bundled demo-package.zip on first launch.
//  Mirrors the Android DataPackageBootstrap pattern: closed testers
//  shouldn't have to manually configure a server. On first run, we copy
//  the bundled zip out of the app bundle, hand it to the import pipeline,
//  and drop a sentinel so subsequent launches don't repeat the work.
//
//  Known caveat (carried over from Android v0.3.0 vc29): shared identity
//  — every tester connects as the same `engie-ios` cert until per-device
//  CSR enrollment is initiated. Per-device CSR ships via tak://enroll.
//

import Foundation
import os

enum DataPackageBootstrap {

    private static let sentinelName = "demo-package.zip.imported"
    private static let log = Logger(subsystem: "com.omnitak.mobile", category: "datapackage.bootstrap")

    /// Run once at app launch. No-op if the sentinel already exists or
    /// the bundled zip isn't shipped (developer builds without the
    /// closed-test bundle).
    static func runIfNeeded() {
        let fm = FileManager.default
        let sentinelDir = applicationSupportDirectory()
        let sentinel = sentinelDir.appendingPathComponent(sentinelName)
        if fm.fileExists(atPath: sentinel.path) {
            log.debug("Sentinel present — skipping bootstrap.")
            return
        }
        guard let bundled = Bundle.main.url(forResource: "demo-package", withExtension: "zip") else {
            log.warning("demo-package.zip not bundled; skipping (developer build).")
            return
        }

        // Run on the main actor — DataPackageImportManager is @MainActor.
        Task { @MainActor in
            do {
                let importer = DataPackageImportManager()
                try await importer.importPackage(from: bundled) { status in
                    Self.log.debug("Bootstrap import status: \(String(describing: status))")
                }
                try? fm.createDirectory(at: sentinelDir, withIntermediateDirectories: true)
                fm.createFile(atPath: sentinel.path, contents: Data(), attributes: nil)
                log.info("Demo package imported; sentinel written at \(sentinel.path).")
            } catch {
                log.error("Demo package import failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// `~/Library/Application Support/<bundle-id>/`. Creates if missing.
    private static func applicationSupportDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let bundleId = Bundle.main.bundleIdentifier ?? "com.omnitak.mobile"
        let dir = base.appendingPathComponent(bundleId, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
