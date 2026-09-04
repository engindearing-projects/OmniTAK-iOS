//
//  DittoMeshService.swift
//  OmniTAK Mobile
//
//  Peer-to-peer CoT sync over Ditto — the "no server, no internet" transport.
//
//  OmniTAK already has two mesh paths, but both are LoRa: Meshtastic and
//  MeshCore move a few hundred bytes at a time, so CoT has to be squeezed into
//  compact TAKPacket encodings that drop most of the event. Ditto is a different
//  animal — it syncs over Bluetooth LE, peer-to-peer Wi-Fi (AWDL) and the LAN at
//  real bandwidth, so it carries the *full* CoT XML with nothing thrown away.
//
//  What that buys operationally: two phones with OmniTAK open see each other's
//  position, markers and chat with no TAK server, no data package, no pairing
//  and no internet. When any peer does have connectivity, the same documents
//  replicate through the Ditto cloud, so a remote element joins the same picture
//  without anyone configuring a thing.
//
//  Model. Ditto is a CRDT document store, not a message bus, and CoT maps onto
//  that almost too neatly: a CoT event is *state* keyed by uid, not an event in
//  a stream. Publishing is therefore an upsert keyed on uid, and last-write-wins
//  is exactly right because a given uid has precisely one authoritative emitter
//  — the device that owns it. Two peers can never meaningfully disagree about
//  where THEIR OWN icon is.
//
//  Staleness. Every CoT carries a `stale` timestamp, so each peer can evict
//  independently on a value they all already agree on and the mesh converges
//  without tombstones or a coordinator. That is why this uses EVICT rather than
//  a soft-delete flag.
//
//  This service is inert unless DITTO_DATABASE_ID is set in Config.xcconfig.
//  A fresh clone builds and runs with the mesh simply switched off.
//

import Foundation
import Combine
import OSLog
import UIKit
import DittoSwift

@MainActor
final class DittoMeshService: ObservableObject {

    static let shared = DittoMeshService()

    // MARK: - Types

    enum State: Equatable {
        case disabled          // no credentials compiled in, or operator turned it off
        case starting
        case syncing
        case failed(String)

        var label: String {
            switch self {
            case .disabled:       return "Off"
            case .starting:       return "Starting…"
            case .syncing:        return "Meshing"
            case .failed(let m):  return "Error: \(m)"
            }
        }
    }

    /// UserDefaults keys, shared with the settings view.
    enum Keys {
        static let enabled = "dittoMeshEnabled"
        static let channel = "dittoMeshChannel"
        static let gateway = "dittoMeshGatewayEnabled"
    }

    /// Ditto collection holding CoT state. One collection, scoped by `channel`.
    private static let collection = "cot"

    /// Wire schema version for documents this build writes. Bump on any change
    /// to the field set; readers ignore versions newer than they understand
    /// rather than guessing.
    static let schemaVersion = 1

    /// Default room. Teams that want isolation change this to a shared word;
    /// only peers on the same channel exchange tracks.
    static let defaultChannel = "omnitak"

    // MARK: - Published state

    @Published private(set) var state: State = .disabled
    @Published private(set) var peerCount: Int = 0
    @Published private(set) var published: Int = 0
    @Published private(set) var received: Int = 0
    @Published private(set) var relayed: Int = 0
    /// Peers in range running a wire-incompatible Ditto build. Nonzero means
    /// someone nearby will never sync no matter how close they stand.
    @Published private(set) var incompatiblePeerCount: Int = 0
    @Published private(set) var lastInboundAt: Date?

    // MARK: - Private

    private var ditto: Ditto?
    private var subscription: DittoSyncSubscription?
    private var observer: DittoStoreObserver?
    private var presenceObserver: DittoObserver?
    private var evictionTimer: Timer?

    /// Last `sentAt` we ingested per document. `registerObserver` re-delivers the
    /// whole matching set on every change, so without this every marker on the
    /// mesh would be re-parsed and re-ingested each time any one of them moved.
    private var ingested: [String: Int64] = [:]

    /// Stable per-install id, stamped on every document we write so the inbound
    /// query can exclude our own writes in DQL and never round-trip them.
    private let peerKey: String = {
        let k = "dittoMeshPeerKey"
        if let existing = UserDefaults.standard.string(forKey: k) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: k)
        return fresh
    }()

    private init() {}

    // MARK: - Configuration

    /// How this build authenticates onto the mesh.
    ///
    /// Kept as an explicit mode rather than a bag of strings because the choice
    /// has a hard consequence: **the database ID is the sync boundary.** Peers
    /// only ever see each other if they share one. That rules out the obvious
    /// "let every user bring their own free Ditto account" idea — per-user
    /// accounts would give every user their own database ID and no two installs
    /// would ever mesh, no matter how close together they were.
    ///
    /// The modes, in the order OmniTAK should grow through them:
    ///
    /// - `.playground` — what a dev build uses. Ditto documents this as
    ///   development-only: the token is effectively an API key granting full
    ///   read/write to everything, and it EXPIRES. It also requires reaching
    ///   Ditto's cloud to authenticate at least once, which is a poor fit for a
    ///   radio that is supposed to work in a field with no signal.
    ///
    /// - `.sharedKey` — the shipping mode for OmniTAK. Peers trust each other
    ///   via self-signed TLS certificates signed by one pre-shared key, with no
    ///   cloud involved at any point. Air-gap capable, which is the actual TAK
    ///   use case. Needs an offline-only license token from Ditto.
    ///
    /// Both live behind this type so moving from one to the other is a config
    /// change, not a rewrite of the sync layer.
    enum Identity {
        case playground(databaseID: String, url: URL, token: String)
        case sharedKey(databaseID: String, key: String, licenseToken: String)

        var databaseID: String {
            switch self {
            case .playground(let id, _, _): return id
            case .sharedKey(let id, _, _):  return id
            }
        }

        /// True when this mode can bring a mesh up with no internet, ever.
        var worksFullyOffline: Bool {
            if case .sharedKey = self { return true }
            return false
        }
    }

    /// Credentials come from Config.xcconfig via Info.plist substitution, the
    /// same route the Mapbox and Cesium tokens take. Absent means "not built
    /// with mesh credentials", which is the default for a fresh clone.
    ///
    /// Shared key wins when both are present: a build carrying a real offline
    /// key should never silently fall back to a development token.
    static func bundledIdentity() -> Identity? {
        func str(_ key: String) -> String? {
            guard let v = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty || t.hasPrefix("$(") || t.hasPrefix("REPLACE_ME") ? nil : t
        }
        guard let db = str("DittoDatabaseID") else { return nil }

        if let key = str("DittoSharedKey"), let license = str("DittoOfflineLicense") {
            return .sharedKey(databaseID: db, key: key, licenseToken: license)
        }
        if let token = str("DittoToken"), let raw = str("DittoURL") {
            // xcconfig treats "//" as a comment ANYWHERE in a line, so a value
            // written as https://host silently truncates to "https:" by the
            // time it reaches Info.plist. Reject that remnant explicitly, and
            // accept the bare host exactly as the Ditto portal displays it —
            // the scheme is added here, not in the config file.
            if raw.range(of: "^[A-Za-z][A-Za-z0-9+.-]*:$", options: .regularExpression) != nil {
                return nil
            }
            let candidate = raw.contains("://") ? raw : "https://\(raw)"
            if let url = URL(string: candidate), url.scheme != nil, url.host?.isEmpty == false {
                return .playground(databaseID: db, url: url, token: token)
            }
        }
        return nil
    }

    /// True when the build carries mesh credentials at all. Drives whether the
    /// settings row is shown as configurable or explained as unavailable.
    var isConfigured: Bool { Self.bundledIdentity() != nil }

    var channel: String {
        let c = UserDefaults.standard.string(forKey: Keys.channel) ?? Self.defaultChannel
        return c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.defaultChannel : c
    }

    /// The enable toggle doubles as the opt-in consent gate — the same stance
    /// the Android port committed to. The default is deliberately OFF:
    /// everything else here is built so that two strangers standing near each
    /// other mesh automatically, which is exactly why it cannot be on by
    /// default — it would broadcast the operator's live position to any nearby
    /// install without them ever agreeing to it. Flipping the toggle is that
    /// agreement, and iOS backs it with its own Bluetooth and Local Network
    /// permission prompts the first time the mesh starts.
    var isEnabled: Bool {
        get {
            UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? false
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
            if newValue { start() } else { stop() }
        }
    }

    /// Gateway mode: relay everything heard on the mesh out to every connected
    /// TAK server. One peer with a data connection therefore backhauls the whole
    /// local mesh into TAK — the other four phones in the treeline need no
    /// connectivity of their own and appear on the server's picture anyway.
    ///
    /// Off by default, and deliberately so. Turning it on means this device
    /// starts writing other people's tracks into a server they may not be
    /// enrolled on, which is an operator's decision to make, not a default.
    /// Mirrors the Android Meshtastic gateway toggle (#179).
    var isGatewayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.gateway) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.gateway) }
    }

    // MARK: - Lifecycle

    /// Bring the mesh up. Safe to call repeatedly; a running mesh is left alone.
    func start() {
        guard ditto == nil else { return }
        guard isEnabled else { state = .disabled; return }
        guard let identity = Self.bundledIdentity() else { state = .disabled; return }

        state = .starting

        Task { [weak self] in
            guard let self else { return }
            do {
                let instance: Ditto

                switch identity {
                case .playground(let db, let url, let token):
                    instance = try await Ditto.open(
                        config: DittoConfig(databaseID: db, connect: .server(url: url))
                    )
                    // Playground tokens expire. Re-login on the expiry callback,
                    // otherwise a long-running device quietly stops syncing and
                    // it presents as a range problem rather than an auth one.
                    instance.auth?.expirationHandler = { ditto, _ in
                        ditto.auth?.login(token: token, provider: .development) { _, error in
                            if let error { Logger.takNetwork.error("Ditto re-auth failed: \(error.localizedDescription, privacy: .public)") }
                        }
                    }
                    instance.auth?.login(token: token, provider: .development) { _, error in
                        if let error { Logger.takNetwork.error("Ditto auth failed: \(error.localizedDescription, privacy: .public)") }
                    }

                case .sharedKey(let db, let key, let license):
                    // No cloud in this path at all: peers authenticate each
                    // other with certificates signed by the shared key, so a
                    // device that has never had a signal still meshes.
                    instance = try await Ditto.open(
                        config: DittoConfig(
                            databaseID: db,
                            connect: .smallPeersOnly(privateKey: key)
                        )
                    )
                    try instance.setOfflineOnlyLicenseToken(license)
                }

                // Bluetooth LE + AWDL + LAN. This is what makes two phones in a
                // field with no infrastructure find each other.
                instance.updateTransportConfig { $0.enableAllPeerToPeer() }
                instance.deviceName = UIDevice.current.name

                try instance.sync.start()

                await MainActor.run {
                    self.ditto = instance
                    self.attachSubscription(instance)
                    self.attachObserver(instance)
                    self.attachPresence(instance)
                    self.startEvictionTimer()
                    self.state = .syncing
                }
            } catch {
                await MainActor.run { self.state = .failed(error.localizedDescription) }
                Logger.takNetwork.error("Ditto start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func stop() {
        observer?.cancel();          observer = nil
        presenceObserver?.stop();    presenceObserver = nil
        evictionTimer?.invalidate(); evictionTimer = nil
        subscription = nil
        ditto?.sync.stop()
        ditto = nil
        ingested.removeAll()
        peerCount = 0
        state = .disabled
    }

    /// Re-key the mesh onto a different channel. Tears down and rebuilds so the
    /// subscription and observer bind to the new value.
    func restart() {
        stop()
        start()
    }

    // MARK: - Wiring

    private func attachSubscription(_ instance: Ditto) {
        do {
            // Replicate only this channel's traffic. A subscription's arguments
            // are fixed at registration, so staleness is deliberately NOT part
            // of this predicate — it is handled by the eviction timer instead.
            subscription = try instance.sync.registerSubscription(
                query: "SELECT * FROM \(Self.collection) WHERE channel = :channel",
                arguments: ["channel": channel]
            )
        } catch {
            state = .failed("subscribe: \(error.localizedDescription)")
        }
    }

    private func attachObserver(_ instance: Ditto) {
        do {
            observer = try instance.store.registerObserver(
                query: """
                SELECT * FROM \(Self.collection)
                WHERE channel = :channel AND peer != :me
                """,
                arguments: ["channel": channel, "me": peerKey]
            ) { [weak self] result in
                // Delivered on .main by default, and this type is @MainActor.
                MainActor.assumeIsolated { self?.ingest(result) }
            }
        } catch {
            state = .failed("observe: \(error.localizedDescription)")
        }
    }

    private func attachPresence(_ instance: Ditto) {
        presenceObserver = instance.presence.observe { [weak self] graph in
            let peers = graph.remotePeers
            // Ditto tells us directly when a peer is running an SDK whose wire
            // protocol we cannot talk to. Surfacing it matters because the
            // symptom is indistinguishable from "nobody is around" — the peer
            // appears in presence and then simply never exchanges data. This is
            // the failure mode to expect if iOS and Android ever ship different
            // Ditto versions, which is why both are pinned to the same one.
            let incompatible = peers.filter { $0.isCompatible == false }.count
            Task { @MainActor in
                guard let self else { return }
                self.peerCount = peers.count
                self.incompatiblePeerCount = incompatible
            }
        }
    }

    // MARK: - Inbound

    private func ingest(_ result: DittoQueryResult) {
        for item in result.items {
            let doc = item.value
            guard let id = doc["_id"] as? String,
                  let xml = doc["xml"] as? String, !xml.isEmpty
            else { continue }

            // A newer OmniTAK may write fields this build has never heard of.
            // Skipping is the safe move: the full CoT XML still rides in `xml`,
            // so a later version can add structure without this one inventing
            // meaning for it.
            let docVersion = (doc["v"] as? Int) ?? 1
            if docVersion > Self.schemaVersion { continue }

            // Skip anything we have already handed to CoTEventHandler at this
            // revision — the observer re-delivers the full matching set on every
            // change, not a delta.
            let sentAt = (doc["sentAt"] as? Int64) ?? Int64((doc["sentAt"] as? Double) ?? 0)
            if let seen = ingested[id], seen >= sentAt { continue }
            ingested[id] = sentAt

            // Drop events that were already stale when they reached us rather
            // than briefly painting a dead track on the map.
            if let staleAt = (doc["staleAt"] as? Int64) ?? Int64(exactly: (doc["staleAt"] as? Double) ?? 0),
               staleAt > 0, staleAt < Int64(Date().timeIntervalSince1970 * 1000) {
                continue
            }

            // Onto our own map first — that path is unconditional and is what
            // makes two phones alone in a field useful to each other.
            if let parsed = CoTMessageParser.parse(xml: xml) {
                CoTEventHandler.shared.handle(event: parsed, source: .mesh("Ditto"))
            }
            received += 1
            lastInboundAt = Date()

            // Then, if this device is acting as the gateway, push it onward to
            // the servers. Note this forwards the ORIGINAL xml rather than
            // re-encoding the parsed event: re-encoding would quietly drop every
            // detail element OmniTAK does not model, and the gateway's job is to
            // be a pipe, not an editor. It also means CoT types the app cannot
            // render still reach the server intact.
            if isGatewayEnabled {
                relayToServers(xml: xml)
            }
        }
    }

    /// Forward a mesh-heard event to connected TAK servers.
    ///
    /// `TAKService.sendCoT` is the same call the app's own outbound path uses, so
    /// this cannot loop back into Ditto: publishing happens at the point where
    /// OmniTAK *originates* a CoT, and relayed traffic is explicitly excluded
    /// there via `isRelay`.
    private func relayToServers(xml: String) {
        guard TAKService.shared.isConnected else { return }
        _ = TAKService.shared.sendCoT(xml: xml, isRelay: true)
        relayed += 1
    }

    // MARK: - Outbound

    /// Upsert one CoT event onto the mesh. Called from the single outbound choke
    /// point in TAKService, so anything OmniTAK emits to a server also reaches
    /// peers — including when no server is connected at all.
    func publish(xml: String) {
        guard let ditto, state == .syncing else { return }
        guard let meta = CoTWireMeta(xml: xml) else { return }

        // Chat is a conversation, not state: two messages from the same sender
        // must both survive, so they cannot share a uid-keyed document the way a
        // position does.
        let docID = meta.type == "b-t-f"
            ? "\(channel)|\(meta.uid)|\(meta.sentAt)"
            : "\(channel)|\(meta.uid)"

        let doc: [String: Any?] = [
            "_id": docID,
            // Schema version. Costs one integer now and is the only thing that
            // makes it possible to change this document shape later without
            // older installs in the field misreading the new fields.
            "v": Self.schemaVersion,
            "uid": meta.uid,
            "type": meta.type,
            "channel": channel,
            "peer": peerKey,
            "xml": xml,
            "lat": meta.lat,
            "lon": meta.lon,
            "sentAt": meta.sentAt,
            "staleAt": meta.staleAt
        ]

        Task { [weak self] in
            do {
                try await ditto.store.execute(
                    query: """
                    INSERT INTO \(Self.collection)
                    DOCUMENTS (:doc)
                    ON ID CONFLICT DO UPDATE
                    """,
                    arguments: ["doc": doc]
                )
                await MainActor.run { self?.published += 1 }
            } catch {
                Logger.takCoT.error("Ditto publish failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Eviction

    private func startEvictionTimer() {
        evictionTimer?.invalidate()
        // Every peer evicts on the same `staleAt` the producer stamped, so the
        // mesh converges on what is live without any peer coordinating.
        evictionTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evictStale() }
        }
    }

    private func evictStale() {
        guard let ditto else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        Task {
            do {
                try await ditto.store.execute(
                    query: "EVICT FROM \(Self.collection) WHERE staleAt < :now AND staleAt > 0",
                    arguments: ["now": now]
                )
            } catch {
                Logger.takCoT.debug("Ditto evict failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        ingested = ingested.filter { _, sentAt in sentAt > now - 3_600_000 }
    }
}

// MARK: - Wire metadata

/// The handful of fields the mesh needs to index a CoT document, pulled straight
/// off the `<event>` and `<point>` attributes.
///
/// Deliberately not `CoTMessageParser`: that classifies into position/chat/alert
/// and returns nil for anything it does not model, whereas the mesh has to be
/// able to carry ANY CoT — including types OmniTAK does not render yet — without
/// dropping it on the floor. The full XML rides along untouched regardless.
struct CoTWireMeta {
    let uid: String
    let type: String
    let lat: Double
    let lon: Double
    let sentAt: Int64
    let staleAt: Int64

    init?(xml: String) {
        guard let uid = Self.attr("uid", in: xml), !uid.isEmpty,
              let type = Self.attr("type", in: xml), !type.isEmpty
        else { return nil }
        self.uid = uid
        self.type = type
        self.lat = Double(Self.attr("lat", in: xml) ?? "") ?? 0
        self.lon = Double(Self.attr("lon", in: xml) ?? "") ?? 0
        self.sentAt = Int64(Date().timeIntervalSince1970 * 1000)
        self.staleAt = Self.iso(Self.attr("stale", in: xml)).map { Int64($0.timeIntervalSince1970 * 1000) } ?? 0
    }

    /// First `name="value"` match. CoT attribute values are XML-escaped and never
    /// contain a raw quote, so scanning to the next quote is sufficient here.
    private static func attr(_ name: String, in xml: String) -> String? {
        guard let r = xml.range(of: "\(name)=\"") else { return nil }
        let rest = xml[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
}
