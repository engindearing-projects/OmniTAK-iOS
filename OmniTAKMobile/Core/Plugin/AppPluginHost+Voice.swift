//
//  AppPluginHost+Voice.swift
//  OmniTAKMobile
//
//  `AppPluginHost`'s conformance to the voice-only `VoiceHostBridge` capability
//  (see VoiceHostBridge.swift). Kept in its own file so the voice surface is
//  isolated and reviewable apart from the four general plugin hooks.
//
//  Everything here DELEGATES to existing, already-audited host services:
//    - resolveCSREnrolledSecIdentity(label:)  — the documented single source of
//      truth for the enrolled identity (TAKService.swift)
//    - DirectTCPSender.loadCACertificates / .makeTCPOptions — the server's
//      truststore + TCP options
//    - ServerManager.shared.activeServer      — the active server + its cert config
//    - PositionBroadcastService.shared        — self callsign / uid
//    - TAKService.shared.sendCoT              — the CoT send path
//
//  The host keeps the key: `makeServerTLSConnection` resolves the identity and
//  configures the TLS options, then hands back only the live `NWConnection`.
//  The plugin never sees the `SecIdentity`.
//

import Foundation
import Network
import Security

extension AppPluginHost: VoiceHostBridge {

    // MARK: - Transport (no-password, reuse-the-cert mTLS)

    func makeServerTLSConnection(host: String, port: UInt16) -> NWConnection? {
        // Pin the voice socket to the ACTIVE server's own cert + truststore
        // settings, so voice authenticates exactly as the TAK link does.
        guard let server = ServerManager.shared.activeServer else {
            #if DEBUG
            print("[VoiceHostBridge] makeServerTLSConnection: no active server")
            #endif
            return nil
        }
        // The identity and trust policy below belong to the active server:
        // never present them to any other host (e.g. a voice connection that
        // was started against a server the operator has since switched away
        // from).
        guard host.caseInsensitiveCompare(server.host) == .orderedSame else {
            #if DEBUG
            print("[VoiceHostBridge] makeServerTLSConnection: '\(host)' is not the active server's host — refused")
            #endif
            return nil
        }
        guard let certName = server.certificateName, !certName.isEmpty,
              let identity = resolveCSREnrolledSecIdentity(label: certName),
              let secIdentity = sec_identity_create(identity) else {
            #if DEBUG
            print("[VoiceHostBridge] makeServerTLSConnection: no enrolled identity for '\(server.certificateName ?? "nil")'")
            #endif
            return nil
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }

        let tlsOptions = NWProtocolTLS.Options()
        let secOptions = tlsOptions.securityProtocolOptions

        // --- TLS versions (mirror DirectTCPSender.connect) ---
        if server.allowLegacyTLS {
            // TLS 1.0 for extremely old servers (opt-in; security risk).
            if let tls10 = tls_protocol_version_t(rawValue: 769) {
                sec_protocol_options_set_min_tls_protocol_version(secOptions, tls10)
            } else {
                sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)
            }
        } else {
            sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv12)
        }
        sec_protocol_options_set_max_tls_protocol_version(secOptions, .TLSv13)

        // --- Legacy cipher suites for older TAK servers (mirror connect) ---
        let legacySuites = [TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384, TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
                            TLS_RSA_WITH_AES_256_GCM_SHA384, TLS_RSA_WITH_AES_128_GCM_SHA256,
                            TLS_RSA_WITH_AES_256_CBC_SHA, TLS_RSA_WITH_AES_128_CBC_SHA]
        for raw in legacySuites {
            if let suite = tls_ciphersuite_t(rawValue: UInt16(raw)) {
                sec_protocol_options_append_tls_ciphersuite(secOptions, suite)
            }
        }

        // --- Server trust: same three-way policy as DirectTCPSender.connect
        //     (#127). CA-pin when a truststore is stored and the user hasn't
        //     opted into accept-any; accept-any only on explicit opt-in;
        //     otherwise system trust evaluation. ---
        var caCertificates: [SecCertificate] = []
        if let caName = server.caCertificateName, !caName.isEmpty,
           let loaded = DirectTCPSender.loadCACertificates(name: caName) {
            caCertificates = loaded
        }

        if !server.allowUntrustedTLS && !caCertificates.isEmpty {
            // Chain-validate against our CA anchors (plus system roots), but
            // not the hostname — TAK server certs routinely mismatch the host.
            sec_protocol_options_set_verify_block(secOptions, { (_, trust, complete) in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(secTrust, SecPolicyCreateBasicX509())
                SecTrustSetAnchorCertificates(secTrust, caCertificates as CFArray)
                SecTrustSetAnchorCertificatesOnly(secTrust, false)
                var error: CFError?
                complete(SecTrustEvaluateWithError(secTrust, &error))
            }, .global())
        } else if server.allowUntrustedTLS {
            // Explicit operator opt-in: accept any server certificate (MITM risk).
            sec_protocol_options_set_peer_authentication_required(secOptions, false)
            sec_protocol_options_set_verify_block(secOptions, { (_, _, complete) in
                complete(true)
            }, .global())
        } else {
            // Default: system trust evaluation against the device root store.
            sec_protocol_options_set_verify_block(secOptions, { (_, trust, complete) in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                var error: CFError?
                complete(SecTrustEvaluateWithError(secTrust, &error))
            }, .global())
        }

        // --- Client identity + challenge block (the mTLS the server requires) ---
        sec_protocol_options_set_local_identity(secOptions, secIdentity)
        sec_protocol_options_set_challenge_block(secOptions, { (_, completionHandler) in
            completionHandler(secIdentity)
        }, .main)

        let parameters = NWParameters(tls: tlsOptions, tcp: DirectTCPSender.makeTCPOptions())

        let nwHost: NWEndpoint.Host
        if let ipv4 = IPv4Address(host) {
            nwHost = .ipv4(ipv4)
        } else {
            nwHost = NWEndpoint.Host(host)
        }

        // Unstarted — the caller owns start()/cancel() and its own read loop.
        return NWConnection(host: nwHost, port: nwPort, using: parameters)
    }

    // MARK: - Read-only identity / routing

    func activeServerHost() -> String? {
        ServerManager.shared.activeServer?.host
    }

    func selfCallsign() -> String {
        PositionBroadcastService.shared.userCallsign
    }

    func selfUid() -> String {
        PositionBroadcastService.shared.userUID
    }

    // MARK: - Emergency

    func setEmergency(active: Bool, reason: String) {
        DispatchQueue.main.async {
            let svc = EmergencyBeaconService.shared
            if active {
                guard !svc.emergencyState.isActive else {
                    print("[VoiceHostBridge] emergency already active — \(reason)")
                    return
                }
                print("[VoiceHostBridge] emergency START — \(reason)")
                // From a speaker-mic key: no alert sound (it would blast into
                // the speaker-mic); the phone vibrates.
                svc.activateEmergency(type: .alert911, playSound: false)
            } else {
                print("[VoiceHostBridge] emergency CANCEL — \(reason)")
                svc.cancelEmergency()
            }
        }
    }

    func isEmergencyActive() -> Bool {
        EmergencyBeaconService.shared.emergencyState.isActive
    }
}
