//
//  TakMdns.swift
//  OmniTAKMobile
//
//  LAN TAK server discovery over Bonjour/mDNS (#111, Android parity with
//  data/discovery/TakMdns.kt). The NWBrowser lives in TakServerDiscovery;
//  this is the pure part — validating what a responder claims and turning a
//  survivor into an Add-Server prefill, so it unit-tests without a LAN.
//
//  mDNS has no authentication. Anything on the network can advertise
//  `_tak._tcp` under any name, pointing anywhere, with any TXT records, and
//  every field arrives here attacker-controlled. Nothing that comes out of
//  this file may do more than prefill a form the operator confirms.
//

import Foundation
import Network

// MARK: - Models

/// A `_tak._tcp` service that survived validation.
struct DiscoveredTakService: Identifiable, Equatable {
    let serviceName: String
    let host: String
    let port: UInt16
    /// TXT-record attributes, lower-cased keys.
    let txt: [String: String]

    /// Endpoint identity. Two responders advertising the same host:port under
    /// different instance names are one server, not two rows.
    var id: String { "\(host.lowercased()):\(port)" }
}

/// What a browse hands over before validation — every field is hostile input.
struct RawTakService: Equatable {
    let serviceName: String
    let host: String
    let port: Int
    let txt: [String: String]
}

/// Why a browse can't produce results. Both cases end the browse: the Servers
/// screen degrades to manual entry rather than spinning.
enum TakDiscoveryFailure: Equatable {
    case permissionDenied
    case unavailable(String)
}

/// The only thing a discovery is allowed to produce: values for the
/// Add-Server form. No credentials, no certificate, no connection.
struct TakServerPrefill: Equatable {
    let name: String
    let host: String
    let portText: String
    /// "ssl" or "tcp" — the values SimpleEnrollView's protocol selector uses.
    let protocolValue: String
    let useTLS: Bool
}

// MARK: - TakMdns

enum TakMdns {

    /// The TAK service type advertised on the LAN. Must stay byte-identical to
    /// Android's `TakMdns.SERVICE_TYPE` and to the Info.plist NSBonjourServices
    /// entry, or the two apps can't see each other's servers.
    static let serviceType = "_tak._tcp"

    /// A picker, not an inventory — a busy LAN advertises far more than an
    /// operator will ever scroll.
    static let maxResults = 32

    static let maxNameLength = 64
    /// The DNS name ceiling; anything longer is not a host, it's a payload.
    static let maxHostLength = 253
    static let maxTxtEntries = 16
    static let maxTxtValueLength = 128

    /// TAK streaming/secure ports that imply TLS when no TXT record says
    /// otherwise. Same table as Android.
    private static let tlsPorts: Set<UInt16> = [8089, 8443, 8446, 443]

    /// kDNSServiceErr_PolicyDenied — what mDNSResponder returns once the
    /// operator taps Don't Allow on the iOS 14+ local-network prompt.
    private static let policyDeniedCode: Int32 = -65570

    // MARK: Validation

    /// Turn a raw browse hit into a displayable service, or nil if any field
    /// fails. Rejecting is always preferable to salvaging: a responder that
    /// sent something malformed has no claim on being shown at all.
    static func make(
        serviceName: String,
        host: String,
        port: Int,
        txt: [String: String]
    ) -> DiscoveredTakService? {
        guard let port = validPort(port), let host = normalizedHost(host) else { return nil }
        let name = sanitizedName(serviceName)
        return DiscoveredTakService(
            serviceName: name.isEmpty ? host : name,
            host: host,
            port: port,
            txt: sanitizedTxt(txt)
        )
    }

    private static func validPort(_ port: Int) -> UInt16? {
        guard port > 0, port <= 65535 else { return nil }
        return UInt16(port)
    }

    /// Normalise and validate an advertised host. A Bonjour host field is never
    /// a URL — a scheme, path, credential, query or whitespace in it is someone
    /// trying to smuggle something into whatever builds a URL downstream, so it
    /// is rejected outright rather than trimmed down to a "core" the way the
    /// hand-typed field in ServerValidator is.
    static func normalizedHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // mDNS resolves to the fully-qualified form; the root dot is noise here.
        while host.hasSuffix(".") { host.removeLast() }

        // NWEndpoint hands IPv6 back in either the bare or RFC 3986 bracket form.
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }

        guard !host.isEmpty, host.count <= maxHostLength else { return nil }
        guard host.rangeOfCharacter(from: forbiddenHostScalars) == nil else { return nil }

        // Link-local IPv6 is dead without its scope zone, so the zone travels
        // with the address instead of being scrubbed off into a dud entry.
        var address = host
        if let percent = host.firstIndex(of: "%") {
            let zone = String(host[host.index(after: percent)...])
            guard !zone.isEmpty, zone.count <= 32,
                  zone.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" })
            else { return nil }
            address = String(host[..<percent])
            guard IPv6Address(host) != nil || IPv6Address(address) != nil else { return nil }
            return host
        }

        if IPv4Address(address) != nil || IPv6Address(address) != nil { return host }
        return hostnamePredicate.evaluate(with: address) ? address : nil
    }

    /// Strip anything that lets a responder forge the row it renders into —
    /// ANSI escapes, newlines, bidi overrides — then clamp the length.
    static func sanitizedName(_ raw: String) -> String {
        sanitizedText(raw, limit: maxNameLength)
    }

    /// Lower-case the keys and clamp both the entry count and each value. A TXT
    /// record can be padded to the DNS limit, and nothing here needs more than
    /// the `tls`/`protocol` hints.
    static func sanitizedTxt(_ raw: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for key in raw.keys.sorted().prefix(maxTxtEntries) {
            guard let value = raw[key] else { continue }
            out[key.lowercased()] = sanitizedText(value, limit: maxTxtValueLength)
        }
        return out
    }

    private static func sanitizedText(_ raw: String, limit: Int) -> String {
        let kept = raw.unicodeScalars.filter { !disallowedScalars.contains($0) }
        let cleaned = String(String.UnicodeScalarView(kept))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
    }

    // MARK: Interpretation

    /// Decide whether a discovered service is TLS. A `tls` TXT record wins, then
    /// a `protocol` TXT record (ssl/tls vs tcp), then the port convention —
    /// the same precedence Android uses so both platforms read one responder
    /// the same way.
    static func isTLS(_ service: DiscoveredTakService) -> Bool {
        if let flag = service.txt["tls"] {
            return flag.caseInsensitiveCompare("true") == .orderedSame || flag == "1"
        }
        if let proto = service.txt["protocol"]?.lowercased() {
            if proto.contains("ssl") || proto.contains("tls") { return true }
            if proto.contains("tcp") { return false }
        }
        return tlsPorts.contains(service.port)
    }

    /// Map a discovered service to Add-Server form values. Deliberately not a
    /// `TAKServer`: building one invites someone to hand it to
    /// `ServerManager.addServer`, which auto-connects an enabled server. An
    /// unauthenticated LAN advertisement never gets to do that.
    static func prefill(for service: DiscoveredTakService) -> TakServerPrefill {
        let tls = isTLS(service)
        return TakServerPrefill(
            name: service.serviceName,
            host: service.host,
            portText: String(service.port),
            protocolValue: tls ? "ssl" : "tcp",
            useTLS: tls
        )
    }

    /// True when the operator already has this endpoint saved. The row says so
    /// instead of quietly writing over their certificates and credentials with
    /// whatever the responder claimed.
    static func isAlreadySaved(_ service: DiscoveredTakService, in servers: [TAKServer]) -> Bool {
        servers.contains {
            $0.port == service.port && $0.host.caseInsensitiveCompare(service.host) == .orderedSame
        }
    }

    /// Classify an NWBrowser error. The local-network denial is the one failure
    /// the operator can act on, so it gets its own state.
    static func classify(_ error: NWError) -> TakDiscoveryFailure {
        switch error {
        case .dns(let code) where code == policyDeniedCode:
            return .permissionDenied
        case .posix(let code) where code == .EPERM || code == .EACCES:
            return .permissionDenied
        default:
            return .unavailable("Couldn't browse the local network. Enter the server address below.")
        }
    }

    // MARK: Character tables

    // No colon here on purpose — IPv6 groups are colon-separated. A "host:port"
    // string still fails, just further down: it parses as neither address nor
    // hostname.
    private static let forbiddenHostScalars = CharacterSet(charactersIn: "/\\@?#&=;,[]{}<>\"'")
        .union(.whitespacesAndNewlines)
        .union(.controlCharacters)

    private static let disallowedScalars: CharacterSet = {
        var set = CharacterSet.controlCharacters
        set.formUnion(.illegalCharacters)
        set.formUnion(.newlines)
        return set
    }()

    private static let hostnamePredicate = NSPredicate(
        format: "SELF MATCHES %@",
        "^([a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?\\.)*[a-zA-Z0-9]([a-zA-Z0-9\\-]{0,61}[a-zA-Z0-9])?$"
    )
}
