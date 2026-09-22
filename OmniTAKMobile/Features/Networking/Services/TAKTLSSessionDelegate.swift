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

// MARK: - Session Delegate

final class TAKTLSSessionDelegate: NSObject, URLSessionDelegate {
    let trustMode: TAKTLSTrustMode
    /// Imported .p12 cert tracked by CertificateManager (mTLS).
    let certificateId: UUID?
    /// Keychain alias of the client cert (= TAKServer.certificateName).
    /// CSR-enrolled identities live under this label and are NOT
    /// tracked by CertificateManager.
    let certificateName: String?

    init(trustMode: TAKTLSTrustMode, certificateId: UUID? = nil, certificateName: String? = nil) {
        self.trustMode = trustMode
        self.certificateId = certificateId
        self.certificateName = certificateName
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            switch trustMode {
            case .acceptUntrusted:
                completionHandler(.useCredential, URLCredential(trust: serverTrust))

            case .system:
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
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                } else {
                    Logger.takNetwork.error("TLS: server certificate rejected against CA anchors: \(error.map { String(describing: $0) } ?? "unknown", privacy: .public)")
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }

        case NSURLAuthenticationMethodClientCertificate:
            if let identity = resolveClientIdentity() {
                let credential = URLCredential(identity: identity, certificates: nil, persistence: .forSession)
                completionHandler(.useCredential, credential)
            } else {
                if certificateId != nil || certificateName != nil {
                    Logger.takNetwork.error("TLS mTLS: no client identity for name=\(self.certificateName ?? "nil", privacy: .public)")
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
    private func resolveClientIdentity() -> SecIdentity? {
        if let certId = certificateId, let identity = try? CertificateManager.shared.getIdentity(for: certId) {
            return identity
        }
        guard let name = certificateName, !name.isEmpty else { return nil }
        return resolveCSREnrolledSecIdentity(label: name)
    }
}
