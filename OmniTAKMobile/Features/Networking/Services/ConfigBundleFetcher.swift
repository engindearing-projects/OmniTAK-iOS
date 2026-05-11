//
//  ConfigBundleFetcher.swift
//  OmniTAKMobile
//
//  GAP-108 — server-driven config. Operator publishes one URL on their
//  OpenTAKserver onboarding portal; every EUD points at it once and
//  picks up changes on each subsequent launch. The URL response can be
//  either:
//
//    - a TAK data-package `.zip` — handed off to DataPackageImportManager
//    - a `text/plain` body of `tak://com.atakmap.app/preference?…` URLs,
//      one per line. Lines starting with `#` are comments.
//
//  Pull-on-launch only — no periodic poll. Mirrors the Android
//  ConfigBundleFetcher receipts so a single portal URL works against
//  both clients.
//

import Foundation
import os

enum ConfigBundleFetcher {

    enum Result {
        case noUrlConfigured
        case appliedPreferences(applied: [String], ignored: [String])
        case stagedZip(URL)
        case failure(String)
    }

    private static let log = Logger(subsystem: "com.omnitak.mobile", category: "config.bundle")
    private static let maxBytes = 2 * 1024 * 1024 // 2 MB ceiling on text bundles
    private static let userDefaultsKey = "configBundleUrl"

    /// Run a one-shot pull. Call from `OmniTAKMobileApp.init` and from a
    /// Settings → "Refresh config now" button. Safe to call when no URL
    /// is configured (returns `.noUrlConfigured`).
    @discardableResult
    static func runIfConfigured() async -> Result {
        let urlString = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            return .noUrlConfigured
        }
        do {
            var request = URLRequest(url: url)
            request.setValue("OmniTAK-iOS/2.15.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/zip,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 30

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure("HTTP \(http.statusCode)")
            }
            if data.count > maxBytes && !isZip(data) {
                return .failure("body exceeds \(maxBytes) bytes")
            }

            if isZip(data) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("config-\(Int(Date().timeIntervalSince1970)).zip")
                try data.write(to: tmp)
                log.info("Config zip staged at \(tmp.path)")
                // Hand to the importer on the main actor.
                await MainActor.run {
                    Task {
                        let importer = DataPackageImportManager()
                        try? await importer.importPackage(from: tmp) { _ in }
                    }
                }
                return .stagedZip(tmp)
            }

            // text/plain — one tak://preference line per row
            let text = String(data: data, encoding: .utf8) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }

            var resolved: [String: String] = [:]
            for line in lines {
                guard let lineURL = URL(string: line),
                      case .setPreferences(let map) = AtakDeepLinkAction.parse(url: lineURL) ?? .unknown
                else { continue }
                resolved.merge(map) { _, new in new }
            }
            guard !resolved.isEmpty else {
                return .failure("no tak://preference URLs found in body")
            }
            let defaults = UserDefaults.standard
            for (key, value) in resolved {
                if value == "true" || value == "false" {
                    defaults.set(value == "true", forKey: key)
                } else if let i = Int(value), key == "trailMaxLength" {
                    defaults.set(i, forKey: key)
                } else {
                    defaults.set(value, forKey: key)
                }
            }
            log.info("Applied \(resolved.count) prefs from config bundle.")
            return .appliedPreferences(applied: Array(resolved.keys), ignored: [])
        } catch {
            log.error("Fetch failed: \(error.localizedDescription, privacy: .public)")
            return .failure(error.localizedDescription)
        }
    }

    private static func isZip(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        return data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
    }
}
