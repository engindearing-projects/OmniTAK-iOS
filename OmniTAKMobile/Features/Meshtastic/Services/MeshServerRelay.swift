//
//  MeshServerRelay.swift
//  OmniTAKMobile
//
//  #113 — CoT relay between the LoRa mesh and the TAK server ("gateway mode"),
//  porting the Android #179 decision layer so both platforms bridge identically.
//
//  A device sitting on BOTH a TAK server and a mesh radio can carry the picture
//  across: mesh-only operators appear on the server, and server contacts reach
//  radios with no IP path. That is genuinely useful and genuinely dangerous, so
//  the whole thing is built as a gate stack rather than a pipe:
//
//   - OFF by default. Enabling it turns one handheld into an unannounced bridge
//     between two networks — an operational and OPSEC decision, not a
//     convenience toggle, so it is never on unless an operator turned it on.
//   - Loop-proof by construction. The direction is decided ONLY by the #180
//     `CoTSource` tag: mesh-origin goes UP, server-origin goes DOWN, and neither
//     can ever be handed back to the transport it arrived on. An untagged event
//     has no origin to reason about and is refused. A relay loop on a LoRa
//     channel has no in-field recovery — the channel simply stops working — so
//     this is the property everything else is arranged around.
//   - Server→mesh passes a type ALLOWLIST. A denylist would let every CoT type
//     nobody has thought about yet (mission-package announcements carrying
//     download URLs, TAK protocol negotiation, future enrollment traffic) onto
//     the air by default. The allowlist inverts that: unknown means no.
//   - Per-uid throttling with a BOUNDED table. A busy server has hundreds of
//     contacts and a hostile one can mint uids forever; an unbounded
//     uid→timestamp dictionary is a slow leak on a device that has to survive a
//     multi-day mission, so the table evicts (stalest first) at a hard cap.
//
//  `relayTarget` / `isRelayableToMesh` / `relayXML` are pure and carry no
//  transport; `admitForward` is pure given the table and an injected `now`.
//  Everything is exercised in `MeshServerRelayTests` without a radio or a socket.
//

import Foundation

final class MeshServerRelay {

    // MARK: - Decision types

    /// Where (if anywhere) an inbound CoT should be relayed.
    enum RelayTarget: Equatable {
        case none
        case toServer
        case toMesh

        /// Namespaces the throttle table so the two directions hold independent
        /// budgets — a uid saturating the LoRa side must not also mute its own
        /// uplink to the server.
        var throttleKeyPrefix: String {
            switch self {
            case .none:     return "-"
            case .toServer: return "S"
            case .toMesh:   return "M"
            }
        }
    }

    /// Inputs to the pure `relayTarget` decision, grouped so the test can build
    /// cases declaratively and the signature stays readable.
    struct RelayInputs {
        let event: CoTEvent
        let source: CoTSource?
        let serverConnected: Bool
        let meshConnected: Bool
        let enabled: Bool
    }

    // MARK: - Tuning

    /// Hard server→mesh per-uid throttle. Matches the dropped-marker send
    /// throttle in `MeshtasticManager` so the gateway can never push a uid onto
    /// LoRa faster than an operator dropping the same marker by hand could.
    static let serverToMeshThrottle: TimeInterval = 30

    /// mesh→server window. Only wide enough to swallow the echo a re-broadcasting
    /// far side bounces back; an IP uplink is cheap, so this stays small.
    static let meshToServerDedupWindow: TimeInterval = 5

    /// Hard cap on throttle table entries. Sized well above a realistic mission
    /// contact count so eviction is the exception, not the steady state — but a
    /// cap, because "however many uids the server feels like sending" is not a
    /// memory budget.
    static let maxThrottleEntries = 512

    /// Eviction target. Dropping to a low-water mark rather than exactly the cap
    /// keeps a uid flood from re-sorting the whole table on every single insert.
    private static let throttleLowWaterMark = (maxThrottleEntries * 3) / 4

    /// Persisted gateway toggle. Absent (fresh install) reads as false.
    static let enabledDefaultsKey = "mesh_server_relay_enabled"

    /// `UserDefaults.bool(forKey:)` is false for a missing key, which is exactly
    /// the default this feature needs — stated explicitly here so nobody
    /// "helpfully" registers a default value of true later.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledDefaultsKey)
    }

    // MARK: - Pure decision

    /// The relay forwarding decision. No I/O, no state — given only the event,
    /// the transport it arrived on, the two connection booleans and the enable
    /// flag, returns which way (if any) to relay.
    ///
    /// Order matters: the toggle and both connections veto first, so an
    /// unconfigured or half-connected device can never be talked into bridging.
    static func relayTarget(_ inputs: RelayInputs) -> RelayTarget {
        guard inputs.enabled else { return .none }
        // A gateway needs both ends. With one side down there is nothing to
        // bridge to, and queueing for it would only produce a burst on reconnect.
        guard inputs.serverConnected, inputs.meshConnected else { return .none }

        switch inputs.source?.transport {
        case .mesh:
            // Airtime for this packet is already spent; the uplink is free. Send
            // it up whatever its type — and, critically, never back down.
            return .toServer
        case .takServer:
            return isRelayableToMesh(inputs.event.type) ? .toMesh : .none
        case .local, .other, nil:
            // Local self-markers already have their own broadcast paths
            // (PositionBroadcastService, the marker send path) — relaying them
            // would double-send. `.other` and untagged events have no origin we
            // can reason about, and refusing is the loop-safe default.
            return .none
        }
    }

    /// Whether a server-origin CoT `type` is worth spending LoRa airtime on.
    /// An ALLOWLIST, deliberately: anything not named here does not cross, which
    /// is what keeps a future credential-, token- or enrollment-bearing CoT type
    /// off the air without anyone having to remember to deny it.
    ///
    ///  - `a-*`      entities: PLI and tactical markers — the picture itself
    ///  - `b-t-f`    GeoChat
    ///  - `b-m-p-*`  map points: waypoints, spot map, bookmarks
    ///
    /// Everything else is dropped on purpose: `t-x-*` tasking/deletes/protocol
    /// negotiation, `b-f-t-*` mission-package announcements (which carry
    /// download URLs and can carry credentials), `b-i-*` sensor and video feeds.
    /// Prefixes are anchored so a type merely *containing* an allowed fragment
    /// cannot slip through.
    ///
    /// Kept byte-identical to the Android `isRelayableToMesh` so a mixed pair of
    /// gateways on one channel cannot disagree about what belongs on the air.
    static func isRelayableToMesh(_ type: String) -> Bool {
        type.hasPrefix("a-") || type == "b-t-f" || type.hasPrefix("b-m-p-")
    }

    /// Rebuild a mesh-origin event as CoT XML for the server.
    ///
    /// Every attacker-controlled field goes through `xmlEscaped`: anyone holding
    /// the channel PSK picks their own uid, callsign and remarks, and pasting
    /// those raw into the envelope would inject arbitrary CoT straight into the
    /// TAK server's stream.
    static func relayXML(for event: CoTEvent) -> String {
        var detail = "        <contact callsign=\"\(event.detail.callsign.xmlEscaped)\"/>\n"
        if let team = event.detail.team {
            let role = event.detail.teamRole ?? "Team Member"
            detail += "        <__group name=\"\(team.xmlEscaped)\" role=\"\(role.xmlEscaped)\"/>\n"
        }
        if let speed = event.detail.speed, let course = event.detail.course {
            detail += "        <track speed=\"\(speed)\" course=\"\(course)\"/>\n"
        }
        if let remarks = event.detail.remarks, !remarks.isEmpty {
            detail += "        <remarks>\(remarks.xmlEscaped)</remarks>\n"
        }
        if let battery = event.detail.battery {
            detail += "        <status battery=\"\(battery)\"/>\n"
        }
        // Provenance. Without it the bridge is invisible: an operator reading the
        // server picture cannot tell a contact that walked in over somebody's
        // handheld gateway from one talking to the server directly, and that
        // ambiguity is the OPSEC failure mode of gateway mode.
        detail += "        <__omnitak_relay via=\"OmniTAK-Gateway\" origin=\"mesh\"/>\n"
        detail += "        <precisionlocation altsrc=\"GPS\" geopointsrc=\"Mesh\"/>"

        return CoTXMLBuilder.buildEvent(
            uid: event.uid,
            type: event.type,
            // Machine-sourced position (the node's own GPS), not a human fix.
            how: "m-g",
            time: event.time,
            // Mesh nodes report on a minutes-scale cadence, so a tighter stale
            // window would ghost them off the server between updates.
            staleAfter: 300,
            lat: event.point.lat,
            lon: event.point.lon,
            hae: event.point.hae,
            ce: event.point.ce,
            le: event.point.le,
            detail: detail
        )
    }

    // MARK: - Throttle state

    /// Last time a (target, uid) pair was forwarded. Guarded because the server
    /// read loop and the mesh frame handler both feed the relay concurrently.
    private var lastForward: [String: Date] = [:]
    private let tableLock = NSLock()

    /// Number of live throttle entries. Read by the tests to pin the bound.
    var throttleEntryCount: Int {
        tableLock.lock(); defer { tableLock.unlock() }
        return lastForward.count
    }

    /// Per-uid + per-target throttle gate. Pure given the table and `now`.
    /// Returns true (recording `now`) when the forward is allowed, false when the
    /// same uid went to the same target inside the applicable window.
    ///
    /// `now` is wall clock, matching every other throttle in the app. A backwards
    /// NTP correction therefore reads as "not due yet" and holds that uid off the
    /// air until the clock catches up — the safe direction for a gate whose
    /// failure mode is transmitting.
    func admitForward(uid: String, target: RelayTarget, now: Date) -> Bool {
        let window: TimeInterval
        switch target {
        case .toMesh:   window = Self.serverToMeshThrottle
        case .toServer: window = Self.meshToServerDedupWindow
        case .none:     return false  // a dropped event must not burn a table slot
        }

        let key = "\(target.throttleKeyPrefix):\(uid)"
        tableLock.lock(); defer { tableLock.unlock() }

        if let last = lastForward[key], now.timeIntervalSince(last) < window {
            return false
        }
        evictLocked(now: now)
        lastForward[key] = now
        return true
    }

    /// Keep the table bounded. Sweeps entries past the widest window first —
    /// they can no longer suppress anything, so they are pure dead weight — and
    /// only then evicts the stalest live entries down to the low-water mark.
    ///
    /// Evicting a live entry forgets that uid's throttle, so its next event
    /// relays immediately. That is the deliberate trade: bounded memory beats
    /// perfect throttling, and because eviction takes the stalest first, the uids
    /// actually transmitting keep their budgets.
    private func evictLocked(now: Date) {
        guard lastForward.count >= Self.maxThrottleEntries else { return }

        let deadline = now.addingTimeInterval(-Self.serverToMeshThrottle)
        lastForward = lastForward.filter { $0.value > deadline }
        guard lastForward.count > Self.throttleLowWaterMark else { return }

        let survivors = lastForward
            .sorted { $0.value > $1.value }
            .prefix(Self.throttleLowWaterMark)
        lastForward = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    /// Drop all throttle state — e.g. on transport teardown, so a reconnect
    /// starts with a clean budget rather than a stale one.
    func reset() {
        tableLock.lock(); defer { tableLock.unlock() }
        lastForward.removeAll()
    }

    // MARK: - Transport wiring

    /// Ships CoT XML to every connected TAK server. Returns true on accept.
    private let sendToServer: (String) -> Bool
    /// Ships a CoT event over the active mesh transport.
    private let sendToMesh: (CoTEvent) -> Void

    /// Decision + throttle happen here rather than on the caller's thread, which
    /// on the server path is the CoT parse queue and on the mesh path is a
    /// radio delegate queue. Serial so the table sees one writer at a time.
    private let relayQueue = DispatchQueue(label: "com.omnitak.meshserverrelay", qos: .utility)

    /// The transports default to no-ops, so an unwired relay is a decision +
    /// throttle object that transmits nowhere. Fail-silent is the right default
    /// for something whose failure mode is broadcasting.
    init(
        sendToServer: @escaping (String) -> Bool = { _ in false },
        sendToMesh: @escaping (CoTEvent) -> Void = { _ in }
    ) {
        self.sendToServer = sendToServer
        self.sendToMesh = sendToMesh
    }

    /// App-wide gateway. `sendToMesh` hops to the main actor because the mesh
    /// managers live there; it sits behind the throttle, so that costs one hop
    /// per uid per window rather than one per inbound packet.
    static let shared = MeshServerRelay(
        sendToServer: { xml in TAKService.shared.sendCoT(xml: xml) },
        sendToMesh: { event in
            Task { @MainActor in
                if #available(iOS 13.0, *), isMeshCoreSelected, MeshCoreManager.shared.isConnected {
                    MeshCoreManager.shared.sendCoTOverMesh(event)
                } else {
                    MeshtasticManager.shared.sendCoTOverMesh(event)
                }
            }
        }
    )

    /// Whether MeshCore, rather than Meshtastic, is the operator's chosen mesh
    /// framework — mirrors the selection ChatManager and PositionBroadcastService
    /// read, so the gateway sends down the same radio everything else uses.
    private static var isMeshCoreSelected: Bool {
        UserDefaults.standard.string(forKey: MeshFramework.storageKey) == MeshFramework.meshcore.rawValue
    }

    /// True when either mesh framework has a live radio. The relay needs this on
    /// the main actor because both managers are `@MainActor`; it is the only
    /// piece of the relay that has to be read there.
    @MainActor
    static var isAnyMeshConnected: Bool {
        if MeshtasticManager.shared.isConnected { return true }
        if #available(iOS 13.0, *), MeshCoreManager.shared.isConnected { return true }
        return false
    }

    /// Feed every inbound CoT here, tagged with the transport it arrived on and
    /// the caller's snapshot of both links. Returns immediately — the decision,
    /// the throttle and the XML rebuild all run off the caller's thread.
    func onInbound(
        _ event: CoTEvent,
        source: CoTSource?,
        serverConnected: Bool,
        meshConnected: Bool,
        enabled: Bool = MeshServerRelay.isEnabled()
    ) {
        // Cheapest possible bail-out for the overwhelmingly common case (gateway
        // off), taken before we even pay for a queue hop per packet.
        guard enabled else { return }

        relayQueue.async { [weak self] in
            guard let self else { return }
            let target = Self.relayTarget(
                RelayInputs(
                    event: event,
                    source: source,
                    serverConnected: serverConnected,
                    meshConnected: meshConnected,
                    enabled: enabled
                )
            )
            guard target != .none,
                  self.admitForward(uid: event.uid, target: target, now: Date()) else { return }

            switch target {
            case .toServer: _ = self.sendToServer(Self.relayXML(for: event))
            case .toMesh:   self.sendToMesh(event)
            case .none:     break
            }
        }
    }
}
