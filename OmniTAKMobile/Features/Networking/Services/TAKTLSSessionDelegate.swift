//
//  TAKTLSSessionDelegate.swift
//  OmniTAKMobile
//
//  The single URLSession TLS delegate for all HTTPS traffic to TAK
//  servers (Marti REST, CSR enrollment, deep-link enrollment).
//  Previously four independent NSObject delegates each implemented
//  accept-any-server-trust, so hardening had to be re-applied four
//  times and the copies had drifted. This delegate owns both sides
//  of the handshake:
//  - server trust, governed by an explicit TAKTLSTrustMode
//  - client identity (mTLS), resolved the same way the streaming
//    path does (CertificateManager p12s by id, CSR-enrolled
//    identities by keychain label)
//
//  It also keeps a `TAKTLSHandshakeReport` of what it saw: which trust
//  policy ran and how it decided, whether the server asked for a client
//  certificate, and whether one was presented. A failed request reads
//  that report so the user gets "the server requires a client certificate
//  and this entry has none" instead of "A TLS error caused the secure
//  connection to fail" (#169).
//

import Foundation
import Security
import os

// MARK: - Trust Mode

/// How the server certificate is validated. Mirrors the streaming
/// path's three-way policy in TAKService.connect:
/// CA-anchored > explicit untrusted opt-in > system roots.
enum TAKTLSTrustMode {
    /// Validate the chain against the supplied CA anchors in addition
    /// to the system roots (basic X509 — chain + validity, not
    /// hostname — matching the streaming truststore behavior).
    case anchored([SecCertificate])
    /// Accept ANY server certificate. MITM risk — only for servers
    /// where the user explicitly enabled allowUntrustedTLS, or for
    /// enrollment bootstrap flows that fetch the truststore itself.
    case acceptUntrusted
    /// Default system trust evaluation (public CAs / Let's Encrypt).
    case system
}

extension TAKTLSTrustMode {
    /// Short, log-friendly name of the selected mode, so a device syslog
    /// shows which policy a session actually ran with (#127).
    var label: String {
        switch self {
        case .anchored(let anchors): return "anchored(\(anchors.count))"
        case .acceptUntrusted: return "acceptUntrusted"
        case .system: return "system"
        }
    }

    /// The one precedence rule for server trust, shared by the REST session
    /// (TAKAPIConfiguration) and the streaming connect path (TAKService):
    ///
    ///   explicit "Trust untrusted certificates" opt-in
    ///     > CA anchors from the server's truststore
    ///       > system roots
    ///
    /// The opt-in has to come first. Every app-enrolled server carries a
    /// truststore, so checking anchors first left the toggle unreachable:
    /// mission sync against an OpenTAKServer whose REST port presents a
    /// certificate outside that truststore kept failing with the toggle on
    /// (#127).
    static func resolve(allowUntrustedTLS: Bool, anchors: [SecCertificate]?) -> TAKTLSTrustMode {
        if allowUntrustedTLS { return .acceptUntrusted }
        if let anchors, !anchors.isEmpty { return .anchored(anchors) }
        return .system
    }
}

// MARK: - Handshake report

/// A copy of what the delegate saw, safe to hand around and compare.
struct TAKTLSHandshakeSnapshot: Equatable {
    enum ServerTrust: Equatable {
        /// No server-trust challenge arrived (DNS or TCP failed first, or
        /// the request never ran).
        case notChallenged
        /// The explicit "Trust untrusted certificates" opt-in accepted it.
        case acceptedUntrusted
        /// The enrolled truststore validated the chain (anchor count).
        case acceptedAnchored(Int)
        /// The enrolled truststore rejected the chain; the request was
        /// cancelled, which the system reports as URLError -999.
        case rejectedByAnchors(String)
        /// Left to the system roots (public CAs).
        case systemDefault
    }

    enum ClientIdentity: Equatable {
        /// The server never asked for a client certificate.
        case notRequested
        /// The server asked and this identity was presented.
        case presented(String)
        /// The server asked but this server entry has no certificate.
        case noneConfigured
        /// The server asked, the entry names a certificate, and it could
        /// not be found on the device.
        case lookupFailed(String)
    }

    /// Label of the trust mode the session was created with.
    var trustMode: String
    var serverTrust: ServerTrust = .notChallenged
    var clientIdentity: ClientIdentity = .notRequested
    /// Number of acceptable issuers the server listed in its certificate
    /// request (its truststore CAs). Zero when it listed none or never asked.
    var acceptableIssuerCount: Int = 0
    /// Server-trust challenges seen; the system retries dropped connections,
    /// so this is roughly the number of handshakes attempted.
    var handshakeAttempts: Int = 0

    init(trustMode: String) {
        self.trustMode = trustMode
    }

    /// Human-readable lines for a details view or log.
    var describedLines: [String] {
        var lines: [String] = ["Trust policy: \(trustMode)"]
        switch serverTrust {
        case .notChallenged: lines.append("Server certificate: no TLS handshake reached the certificate step")
        case .acceptedUntrusted: lines.append("Server certificate: accepted without validation (Trust untrusted certificates is on)")
        case .acceptedAnchored(let n): lines.append("Server certificate: validated against the enrolled truststore (\(n) anchor\(n == 1 ? "" : "s"))")
        case .rejectedByAnchors(let why): lines.append("Server certificate: rejected by the enrolled truststore: \(why)")
        case .systemDefault: lines.append("Server certificate: left to iOS system trust")
        }
        switch clientIdentity {
        case .notRequested:
            lines.append("Client certificate: not requested by the server")
        case .presented(let name):
            lines.append("Client certificate: server requested one (\(acceptableIssuerCount) acceptable issuer\(acceptableIssuerCount == 1 ? "" : "s")); presented \"\(name)\"")
        case .noneConfigured:
            lines.append("Client certificate: server requested one (\(acceptableIssuerCount) acceptable issuer\(acceptableIssuerCount == 1 ? "" : "s")); this server entry has none")
        case .lookupFailed(let name):
            lines.append("Client certificate: server requested one; \"\(name)\" is configured but was not found on this device")
        }
        lines.append("Handshake attempts: \(handshakeAttempts)")
        return lines
    }
}

/// What the TLS delegate saw during the most recent handshake(s) of a
/// session. Written from the URLSession delegate queue, read from the
/// request's failure path, so access goes through a lock. One report per
/// session: a request is diagnosed right after it fails, so the last
/// handshake is the one that matters.
final class TAKTLSHandshakeReport {
    private let lock = NSLock()
    private var current: TAKTLSHandshakeSnapshot

    init(trustMode: TAKTLSTrustMode) {
        current = TAKTLSHandshakeSnapshot(trustMode: trustMode.label)
    }

    func snapshot() -> TAKTLSHandshakeSnapshot {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    fileprivate func recordServerTrust(_ outcome: TAKTLSHandshakeSnapshot.ServerTrust) {
        lock.lock(); defer { lock.unlock() }
        current.serverTrust = outcome
        current.handshakeAttempts += 1
        // A new handshake starts the client-certificate story over.
        current.clientIdentity = .notRequested
        current.acceptableIssuerCount = 0
    }

    fileprivate func recordClientIdentity(_ outcome: TAKTLSHandshakeSnapshot.ClientIdentity, acceptableIssuers: Int) {
        lock.lock(); defer { lock.unlock() }
        current.clientIdentity = outcome
        current.acceptableIssuerCount = acceptableIssuers
    }
}

// MARK: - Session Delegate

final class TAKTLSSessionDelegate: NSObject, URLSessionDelegate {
    let trustMode: TAKTLSTrustMode
    /// Imported .p12 cert tracked by CertificateManager (mTLS).
    let certificateId: UUID?
    /// Keychain alias of the client cert (= TAKServer.certificateName).
    /// CSR-enrolled identities live under this label and are NOT
    /// tracked by CertificateManager.
    let certificateName: String?
    /// What the handshake(s) on this session looked like (#169).
    let report: TAKTLSHandshakeReport

    init(trustMode: TAKTLSTrustMode, certificateId: UUID? = nil, certificateName: String? = nil) {
        self.trustMode = trustMode
        self.certificateId = certificateId
        self.certificateName = certificateName
        self.report = TAKTLSHandshakeReport(trustMode: trustMode)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                report.recordServerTrust(.systemDefault)
                completionHandler(.performDefaultHandling, nil)
                return
            }
            switch trustMode {
            case .acceptUntrusted:
                report.recordServerTrust(.acceptedUntrusted)
                completionHandler(.useCredential, URLCredential(trust: serverTrust))

            case .system:
                report.recordServerTrust(.systemDefault)
                completionHandler(.performDefaultHandling, nil)

            case .anchored(let anchors):
                // Validate chain + validity period against our CA anchors
                // in ADDITION to the system roots (matches the streaming
                // path: SecTrustSetAnchorCertificatesOnly(false)).
                SecTrustSetPolicies(serverTrust, SecPolicyCreateBasicX509())
                SecTrustSetAnchorCertificates(serverTrust, anchors as CFArray)
                SecTrustSetAnchorCertificatesOnly(serverTrust, false)

                var error: CFError?
                if SecTrustEvaluateWithError(serverTrust, &error) {
                    report.recordServerTrust(.acceptedAnchored(anchors.count))
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                } else {
                    let why = error.map { String(describing: $0) } ?? "unknown"
                    report.recordServerTrust(.rejectedByAnchors(why))
                    Logger.takNetwork.error("TLS: server certificate rejected against CA anchors: \(why, privacy: .public)")
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }

        case NSURLAuthenticationMethodClientCertificate:
            let issuers = challenge.protectionSpace.distinguishedNames?.count ?? 0
            if let (identity, name) = resolveClientIdentity() {
                report.recordClientIdentity(.presented(name), acceptableIssuers: issuers)
                Logger.takNetwork.info("TLS mTLS: server asked for a client certificate (\(issuers, privacy: .public) acceptable issuers); presenting \(name, privacy: .public)")
                let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                if certificateId != nil || (certificateName.map { !$0.isEmpty } ?? false) {
                    let name = certificateName ?? certificateId?.uuidString ?? "?"
                    report.recordClientIdentity(.lookupFailed(name), acceptableIssuers: issuers)
                    Logger.takNetwork.error("TLS mTLS: server asked for a client certificate but no identity was found for name=\(name, privacy: .public)")
                } else {
                    report.recordClientIdentity(.noneConfigured, acceptableIssuers: issuers)
                    Logger.takNetwork.error("TLS mTLS: server asked for a client certificate (\(issuers, privacy: .public) acceptable issuers) and this server entry has none")
                }
                completionHandler(.performDefaultHandling, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Resolve the client SecIdentity the same way the streaming path
    /// (DirectTCPSender.loadCSREnrolledIdentity) does, by delegating to the
    /// single shared resolver `resolveCSREnrolledSecIdentity(label:)`.
    /// Imported .p12 certs tracked by CertificateManager take priority via
    /// `certificateId`; CSR-enrolled (easy-connect) identities live in the
    /// keychain under a label = `certificateName` and are resolved by name.
    /// Returns the identity with the name it was found under, for the report.
    private func resolveClientIdentity() -> (SecIdentity, String)? {
        if let certId = certificateId, let identity = try? CertificateManager.shared.getIdentity(for: certId) {
            return (identity, certificateName ?? "imported certificate \(certId.uuidString.prefix(8))")
        }
        guard let name = certificateName, !name.isEmpty else { return nil }
        guard let identity = resolveCSREnrolledSecIdentity(label: name) else { return nil }
        return (identity, name)
    }
}
