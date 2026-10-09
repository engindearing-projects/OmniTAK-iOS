//
//  DiagnosticsLog.swift
//  OmniTAKMobile
//
//  The app's own log, readable from inside the app. OmniTAK writes to the
//  unified log (Logger, subsystem com.omnitak.mobile) but until now the only
//  way to read it was Console.app on a Mac. A user whose Mission Sync shows
//  "A TLS error caused the secure connection to fail" could not tell us
//  more (#169). This reads the current process's entries through OSLogStore,
//  keeps the app's lines plus the system networking lines that name TLS
//  alerts, and renders them as text for a share sheet.
//
//  The reader is split from the rendering so the rendering is unit-tested
//  without OSLogStore, which only yields real entries on a device or
//  simulator.
//

import Foundation
import OSLog
import UIKit

/// One log line, independent of OSLogEntryLog so it can be built in tests.
struct DiagnosticsLogLine: Equatable {
    let date: Date
    let level: String
    let subsystem: String
    let category: String
    let message: String
}

enum DiagnosticsLog {

    /// OmniTAK's own subsystem.
    static let appSubsystem = "com.omnitak.mobile"

    /// System lines worth keeping next to ours: CFNetwork and boringssl are
    /// where a TLS alert is named ("received fatal alert: certificate_required").
    static let networkSubsystems: Set<String> = [
        "com.apple.network", "com.apple.CFNetwork", "com.apple.NetworkExtension"
    ]

    /// Words that mark a system networking line worth keeping. Everything
    /// else CFNetwork says (task summaries for every map tile, socket
    /// notifications) would bury the lines that explain a failure.
    static let networkKeywords = [
        "alert", "handshake", "certificate", "tls", "ssl", "trust",
        "error", "fail", "refused", "reset", "timed out", "cancel"
    ]

    /// Which lines a diagnostics export keeps.
    static func isRelevant(subsystem: String, category: String, message: String, includeSystemNetworking: Bool) -> Bool {
        if subsystem == appSubsystem { return true }
        guard includeSystemNetworking else { return false }
        let c = category.lowercased()
        if c.contains("boringssl") || c.contains("tls") || c.contains("ssl") { return true }
        guard networkSubsystems.contains(subsystem) else { return false }
        let m = message.lowercased()
        return networkKeywords.contains { m.contains($0) }
    }

    // MARK: Header

    /// What every report starts with: versions, device, and the server
    /// entries with their trust settings. Never passwords.
    static func header(servers: [TAKServer] = ServerManager.shared.servers, now: Date = Date()) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "OmniTAK diagnostics",
            "Generated: \(Self.timestamp.string(from: now)) \(TimeZone.current.abbreviation() ?? "")",
            "App: \(version) (\(build))",
            "iOS: \(UIDevice.current.systemVersion), device: \(UIDevice.current.model)",
            "Servers: \(servers.count)"
        ]
        for s in servers {
            lines.append(describe(server: s))
        }
        return lines.joined(separator: "\n")
    }

    /// One line per server: endpoint, ports, what secures it. No secrets.
    static func describe(server s: TAKServer) -> String {
        var parts = ["- \(s.name): \(s.host):\(s.port) \(s.protocolType)\(s.useTLS ? " tls" : "")"]
        parts.append(s.enabled ? "enabled" : "disabled")
        parts.append("api \(s.secureAPIPort ?? 8443)")
        parts.append("enroll \(s.enrollmentPort ?? 8446)")
        parts.append("cert \(s.certificateName ?? "none")")
        parts.append("truststore \(s.caCertificateName ?? "none")")
        if s.allowUntrustedTLS { parts.append("trust-untrusted ON") }
        if s.allowLegacyTLS { parts.append("legacy-tls ON") }
        parts.append(s.username.map { _ in "credentials stored" } ?? "no credentials")
        return parts.joined(separator: ", ")
    }

    // MARK: Rendering

    static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func render(line: DiagnosticsLogLine) -> String {
        let scope = line.subsystem == appSubsystem ? line.category : "\(line.subsystem)/\(line.category)"
        return "\(timestamp.string(from: line.date)) \(line.level.uppercased().padding(toLength: 6, withPad: " ", startingAt: 0)) [\(scope)] \(line.message)"
    }

    /// The full export: header, blank line, one rendered line per entry.
    static func render(header: String, lines: [DiagnosticsLogLine]) -> String {
        var out = header
        out += "\n\nLog (\(lines.count) lines)\n"
        out += lines.map(render(line:)).joined(separator: "\n")
        return out
    }

    // MARK: Reading

    /// Entries from this process, oldest first, capped to the most recent
    /// `limit`. OSLogStore(scope: .currentProcessIdentifier) only sees lines
    /// written since the app launched, which is what a "retry, then export"
    /// flow needs.
    static func read(includeSystemNetworking: Bool, since: Date? = nil, limit: Int = 3000) throws -> [DiagnosticsLogLine] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let position = since.map { store.position(date: $0) } ?? store.position(timeIntervalSinceLatestBoot: 0)
        var lines: [DiagnosticsLogLine] = []
        for entry in try store.getEntries(at: position) {
            guard let log = entry as? OSLogEntryLog else { continue }
            guard isRelevant(subsystem: log.subsystem, category: log.category, message: log.composedMessage,
                             includeSystemNetworking: includeSystemNetworking) else { continue }
            lines.append(DiagnosticsLogLine(date: log.date, level: levelName(log.level), subsystem: log.subsystem,
                                            category: log.category, message: log.composedMessage))
        }
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        return lines
    }

    static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        case .undefined: return "log"
        @unknown default: return "log"
        }
    }

    /// Writes the export to a temporary .txt so the share sheet offers it as
    /// a file (Mail, Files, AirDrop) rather than a wall of text.
    static func exportFile(_ text: String, now: Date = Date()) throws -> URL {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniTAK-diagnostics-\(stamp.string(from: now)).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
