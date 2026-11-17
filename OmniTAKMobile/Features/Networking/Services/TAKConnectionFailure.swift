//
//  TAKConnectionFailure.swift
//  OmniTAKMobile
//
//  A Marti REST request that never got an HTTP answer, explained. URLSession
//  reports such failures as one sentence ("A TLS error caused the secure
//  connection to fail", "The network connection was lost") that says nothing
//  about the cause. Combined with the TLS delegate's handshake report, the
//  same failure reads "the server requires a client certificate and this
//  server entry has none", which is something a user can act on (#169).
//
//  Pure mapping over values, so it is unit-tested without a network.
//

import Foundation

struct TAKConnectionFailure: Error, Equatable {

    enum Kind: Equatable {
        /// The server asked for a client certificate; this entry has none.
        case clientCertificateMissing
        /// The entry names a certificate that is not on the device.
        case clientCertificateUnavailable
        /// A certificate was presented and the server dropped the connection.
        case clientCertificateRejected
        /// iOS system trust rejected the server certificate (private CA, no truststore).
        case serverCertificateUntrusted
        /// The enrolled truststore rejected the server certificate.
        case serverCertificateFailedAnchors
        /// The handshake failed before any certificate was exchanged.
        case tlsHandshakeFailed
        case connectionRefused
        case hostNotFound
        case timedOut
        case offline
        /// The server closed the connection before answering (no certificate story).
        case connectionLost
        case cancelled
        case other
        /// The enrollment port answered but did not take the stored username and password.
        case credentialsRejected
    }

    let kind: Kind
    let host: String
    let port: Int
    let errorDomain: String
    let errorCode: Int
    /// `_kCFStreamErrorDomainKey` / `_kCFStreamErrorCodeKey` when CFNetwork
    /// attached them: domain 3 is SecureTransport (the code is the SSL
    /// status), domain 4 is HTTP, domain 1 is POSIX.
    let streamErrorDomain: Int?
    let streamErrorCode: Int?
    /// What the system said, verbatim.
    let systemDescription: String
    let handshake: TAKTLSHandshakeSnapshot
    /// What the username/password route said when it was tried after this
    /// failure and did not work either (#169).
    var fallbackNote: String?

    private init(kind: Kind, host: String, port: Int, errorDomain: String, errorCode: Int,
                 streamErrorDomain: Int?, streamErrorCode: Int?, systemDescription: String,
                 handshake: TAKTLSHandshakeSnapshot) {
        self.kind = kind
        self.host = host
        self.port = port
        self.errorDomain = errorDomain
        self.errorCode = errorCode
        self.streamErrorDomain = streamErrorDomain
        self.streamErrorCode = streamErrorCode
        self.systemDescription = systemDescription
        self.handshake = handshake
    }

    /// A fallback through the enrollment port that got an HTTP answer
    /// refusing the credentials: no transport failure to wrap.
    static func credentialsRejected(host: String, port: Int, note: String) -> TAKConnectionFailure {
        TAKConnectionFailure(kind: .credentialsRejected, host: host, port: port,
                             errorDomain: "OmniTAK.MissionSync", errorCode: 0,
                             streamErrorDomain: nil, streamErrorCode: nil,
                             systemDescription: note,
                             handshake: TAKTLSHandshakeSnapshot(trustMode: "n/a"))
    }

    init(error: Error, host: String, port: Int, handshake: TAKTLSHandshakeSnapshot) {
        let nsError = error as NSError
        self.host = host
        self.port = port
        self.errorDomain = nsError.domain
        self.errorCode = nsError.code
        self.systemDescription = nsError.localizedDescription
        self.handshake = handshake

        // CFNetwork puts the stream-level cause on the top error or on the
        // underlying one; take whichever is present.
        let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        func streamValue(_ key: String) -> Int? {
            if let v = nsError.userInfo[key] as? Int { return v }
            if let v = (nsError.userInfo[key] as? NSNumber)?.intValue { return v }
            if let v = underlying?.userInfo[key] as? Int { return v }
            return (underlying?.userInfo[key] as? NSNumber)?.intValue
        }
        self.streamErrorDomain = streamValue("_kCFStreamErrorDomainKey")
        self.streamErrorCode = streamValue("_kCFStreamErrorCodeKey")

        self.kind = Self.classify(code: nsError.code, handshake: handshake)
    }

    // MARK: Classification

    /// Codes that mean "the server ended the connection around the
    /// handshake": a TLS alert (-1200), a close right after the handshake
    /// (-1005, what a TAK Server's Tomcat does to a connection without an
    /// acceptable client certificate), or the system's own client-certificate
    /// verdicts (-1205, -1206).
    private static let connectionDropCodes: Set<Int> = [
        NSURLErrorSecureConnectionFailed,     // -1200
        NSURLErrorNetworkConnectionLost,      // -1005
        NSURLErrorClientCertificateRejected,  // -1205
        NSURLErrorClientCertificateRequired   // -1206
    ]

    static func classify(code: Int, handshake: TAKTLSHandshakeSnapshot) -> Kind {
        // The handshake report is the better witness: if the server asked for
        // a client certificate and then dropped us, that is the story.
        if connectionDropCodes.contains(code) {
            switch handshake.clientIdentity {
            case .noneConfigured: return .clientCertificateMissing
            case .lookupFailed: return .clientCertificateUnavailable
            case .presented: return .clientCertificateRejected
            case .notRequested: break
            }
        }

        switch code {
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return .serverCertificateUntrusted
        case NSURLErrorCancelled:
            if case .rejectedByAnchors = handshake.serverTrust { return .serverCertificateFailedAnchors }
            return .cancelled
        case NSURLErrorClientCertificateRequired:
            return .clientCertificateMissing
        case NSURLErrorClientCertificateRejected:
            return .clientCertificateRejected
        case NSURLErrorSecureConnectionFailed:
            return .tlsHandshakeFailed
        case NSURLErrorCannotConnectToHost:
            return .connectionRefused
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .hostNotFound
        case NSURLErrorTimedOut:
            return .timedOut
        case NSURLErrorNotConnectedToInternet:
            return .offline
        case NSURLErrorNetworkConnectionLost:
            return .connectionLost
        default:
            return .other
        }
    }

    // MARK: Text

    var endpoint: String { "\(host):\(port)" }

    var isClientCertificateProblem: Bool {
        switch kind {
        case .clientCertificateMissing, .clientCertificateUnavailable, .clientCertificateRejected: return true
        default: return false
        }
    }

    var isServerTrustProblem: Bool {
        switch kind {
        case .serverCertificateUntrusted, .serverCertificateFailedAnchors: return true
        default: return false
        }
    }

    /// Whether trying the enrollment port with a username and password could
    /// help: anything the certificate port did at the TLS or TCP layer, not
    /// a host that cannot be resolved or a network that is down.
    var allowsCredentialFallback: Bool {
        switch kind {
        case .hostNotFound, .timedOut, .offline, .cancelled, .other, .credentialsRejected: return false
        default: return true
        }
    }

    /// One sentence or two for the server row. Names the endpoint and what
    /// to do about it, plus what the credential route said if it was tried.
    var summary: String {
        guard let fallbackNote else { return baseSummary }
        return baseSummary + " Username and password did not work either (\(fallbackNote))."
    }

    private var baseSummary: String {
        switch kind {
        case .clientCertificateMissing:
            return "\(endpoint) requires a client certificate and this server has none. Enroll with your username and password, or import a .p12."
        case .clientCertificateUnavailable:
            if case .lookupFailed(let name) = handshake.clientIdentity {
                return "\(endpoint) asked for a client certificate but \"\(name)\" was not found on this device. Re-enroll the server."
            }
            return "\(endpoint) asked for a client certificate that is not on this device. Re-enroll the server."
        case .clientCertificateRejected:
            if case .presented(let name) = handshake.clientIdentity {
                return "\(endpoint) dropped the connection after the certificate \"\(name)\" was presented. The server did not accept it: check that it was issued by this server's CA, or re-enroll."
            }
            return "\(endpoint) did not accept the client certificate. Re-enroll the server."
        case .serverCertificateUntrusted:
            return "The certificate \(endpoint) presented is not trusted by iOS and no truststore is stored for this server. Enroll to install the server CA, or turn on Trust untrusted certificates."
        case .serverCertificateFailedAnchors:
            return "The certificate \(endpoint) presented does not chain to this server's enrolled truststore. Re-enroll, or turn on Trust untrusted certificates."
        case .tlsHandshakeFailed:
            return "TLS handshake with \(endpoint) failed before authentication: \(systemDescription)"
        case .connectionRefused:
            return "\(endpoint) refused the connection. Check the Marti API port (usually 8443)."
        case .hostNotFound:
            return "Could not resolve \(host)."
        case .timedOut:
            return "\(endpoint) did not answer in time."
        case .offline:
            return "No network connection."
        case .connectionLost:
            return "\(endpoint) closed the connection before answering."
        case .cancelled:
            return "The request to \(endpoint) was cancelled."
        case .other:
            return "\(endpoint): \(systemDescription)"
        case .credentialsRejected:
            return "\(endpoint) did not accept the stored username and password (\(systemDescription)). Check them in the server settings."
        }
    }

    /// Everything a bug report needs, one fact per line.
    var details: String {
        var lines: [String] = []
        lines.append("Server: \(endpoint)")
        lines.append("Result: \(summary)")
        lines.append("System error: \(errorDomain) \(errorCode) \"\(systemDescription)\"")
        if let d = streamErrorDomain, let c = streamErrorCode {
            lines.append("Underlying: stream domain \(d) code \(c)\(Self.streamDomainName(d))")
        }
        lines.append(contentsOf: handshake.describedLines)
        if let fallbackNote { lines.append("Fallback: \(fallbackNote)") }
        return lines.joined(separator: "\n")
    }

    private static func streamDomainName(_ domain: Int) -> String {
        switch domain {
        case 1: return " (POSIX)"
        case 3: return " (SecureTransport / TLS)"
        case 4: return " (HTTP)"
        case 12: return " (DNS)"
        default: return ""
        }
    }
}
