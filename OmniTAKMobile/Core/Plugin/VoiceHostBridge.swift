//
//  VoiceHostBridge.swift
//  OmniTAKMobile
//
//  A PURPOSE-BUILT, voice-only host capability — deliberately separate from
//  `PluginHost` (the four map/radial/CoT/settings hooks every plugin gets).
//  A voice plugin reaches it with a single cast during activation:
//
//      func activate(host: PluginHost) {
//          guard let voice = host as? VoiceHostBridge else { return }
//          // ... use voice.makeServerTLSConnection(...), etc.
//      }
//
//  WHY A SEPARATE PROTOCOL (not more hooks on PluginHost):
//  voice needs things no other plugin should casually reach — the server
//  connection, the active-server host, the enrolled identity (for outbound
//  mTLS), and the emergency beacon. Bundling those into the general plugin surface
//  would widen it for everyone. Instead this is ONE named, bounded, reviewable
//  protocol: the maintainer can audit exactly what voice can and cannot do.
//
//  WHAT IT DELIBERATELY DOES NOT EXPOSE:
//  - the raw `SecIdentity` / private key — the host keeps the key and only ever
//    vends a live, already-authenticated `NWConnection` (see
//    `makeServerTLSConnection`). The plugin never touches the credential.
//  - a general "open any socket" escape hatch — the transport is pinned to
//    the active server's own host and cert/truststore settings.
//  - any CoT send or receive path: voice doesn't need one.
//
//  TRUST NOTE: plugins run IN-PROCESS with full app permissions (no sandbox —
//  see OmniTAKPlugin.swift). This boundary is about CLARITY and REVIEWABILITY,
//  not runtime enforcement: nothing stops an in-process plugin from reaching
//  around it, but a plugin that stays within this protocol is trivially
//  auditable as "voice, and only voice".
//

import Foundation
import Network

/// The narrow capability a voice (push-to-talk) plugin needs from the host.
/// Implemented by `AppPluginHost` (see `AppPluginHost+Voice.swift`) and reached
/// by a voice plugin via `host as? VoiceHostBridge`.
protocol VoiceHostBridge: AnyObject {
    /// A live, **unstarted** mTLS `NWConnection` to `host:port`, authenticated
    /// with the enrolled TAK client identity — the SAME identity and truststore
    /// the active TAK server connection uses. This is the no-password,
    /// reuse-the-cert path: the host resolves the `SecIdentity` and sets the
    /// local identity + challenge block; the caller gets only the socket and
    /// drives its own read/write loop (e.g. the Mumble framing).
    ///
    /// `host` must be the active TAK server's own host (`activeServerHost()`):
    /// the client identity is never presented to any other host.
    ///
    /// Returns `nil` when there is no active server, `host` isn't its host, no
    /// enrolled client certificate exists for it, or the endpoint is invalid. The caller owns the
    /// returned connection's lifecycle (`start`/`cancel`).
    func makeServerTLSConnection(host: String, port: UInt16) -> NWConnection?

    /// The active TAK Server's hostname, or `nil` if none is active. Murmur
    /// shares this hostname on the standard Mumble port (64738), so the voice
    /// plugin derives its endpoint from this (mirrors Android's
    /// `TakServerDiscovery`).
    func activeServerHost() -> String?

    /// The operator's self callsign (Mumble username is `callsign---slot`).
    /// Read-only; already app-known.
    func selfCallsign() -> String

    /// The operator's self UID (used to tag the Mumble username).
    /// Read-only; already app-known.
    func selfUid() -> String

    /// Start (true) or cancel (false) the host's emergency beacon (911 alert,
    /// CoT b-a-o-tbl) — what a speaker-mic's emergency button does, like
    /// TAK-XVoice driving ATAK's EmergencyManager. Starting while already
    /// active is a no-op (the alert has one start → cancel lifecycle).
    func setEmergency(active: Bool, reason: String)

    /// Whether the host's emergency beacon is currently active.
    func isEmergencyActive() -> Bool
}
