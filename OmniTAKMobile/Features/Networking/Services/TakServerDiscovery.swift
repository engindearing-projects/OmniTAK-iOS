//
//  TakServerDiscovery.swift
//  OmniTAKMobile
//
//  NWBrowser-backed Bonjour/mDNS discovery of `_tak._tcp` servers (#111,
//  Android parity with data/discovery/TakNsdDiscovery.kt).
//
//  Two pieces on purpose. TakDiscoveryStore holds every decision worth
//  testing — dedupe, debounce, clamping, the permission state — behind a
//  synchronous, injectable seam. BonjourTakBrowser is the thin part that
//  actually talks to mDNSResponder and can only be exercised on a real LAN.
//

import Foundation
import Network

// MARK: - State

enum TakDiscoveryState: Equatable {
    case idle
    case browsing
    case permissionDenied
    case unavailable(String)
    case stopped

    var isSearching: Bool { self == .browsing }

    /// What the Servers screen says when discovery can't run. Every terminal
    /// state has one: the failure this replaces is an empty list under a
    /// spinner that never resolves.
    var operatorMessage: String? {
        switch self {
        case .permissionDenied:
            return "OmniTAK can't see the local network. Allow it in Settings › Privacy & Security › Local Network › OmniTAK, or just type the server address below."
        case .unavailable(let reason):
            return reason
        case .idle, .browsing, .stopped:
            return nil
        }
    }
}

// MARK: - Browser seam

protocol TakServiceBrowsing: AnyObject {
    var onUpdate: (([RawTakService]) -> Void)? { get set }
    var onFailure: ((TakDiscoveryFailure) -> Void)? { get set }
    func start()
    func cancel()
}

// MARK: - Store

/// Holds the discovered list for the Servers screen. It never saves, connects
/// to, enrols with or trusts anything it finds — the only exit is
/// `TakMdns.prefill`, which fills in a form the operator still confirms.
@MainActor
final class TakDiscoveryStore: ObservableObject {

    @Published private(set) var services: [DiscoveredTakService] = []
    @Published private(set) var state: TakDiscoveryState = .idle

    private let browser: TakServiceBrowsing
    private let maxResults: Int
    private let minPublishInterval: TimeInterval

    private var pending: [DiscoveredTakService]?
    private var lastPublish = Date.distantPast
    private var isRunning = false
    private var flushScheduled = false

    var hasPendingUpdate: Bool { pending != nil }

    init(
        browser: TakServiceBrowsing = BonjourTakBrowser(),
        maxResults: Int = TakMdns.maxResults,
        minPublishInterval: TimeInterval = 0.4
    ) {
        self.browser = browser
        self.maxResults = maxResults
        self.minPublishInterval = minPublishInterval

        browser.onUpdate = { [weak self] raw in
            Task { @MainActor in self?.receive(raw) }
        }
        browser.onFailure = { [weak self] failure in
            Task { @MainActor in self?.fail(failure) }
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        state = .browsing
        browser.start()
    }

    /// Tear the browse down with the view. An mDNS browse left running keeps
    /// the Wi-Fi radio awake for a screen nobody is looking at.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        browser.cancel()
        pending = nil
        services = []
        state = .stopped
    }

    /// End the browse and say why. A denied or dead browse stops rather than
    /// sitting in `.browsing` forever.
    func fail(_ failure: TakDiscoveryFailure) {
        if isRunning {
            isRunning = false
            browser.cancel()
        }
        pending = nil
        services = []
        switch failure {
        case .permissionDenied:
            state = .permissionDenied
        case .unavailable(let reason):
            state = .unavailable(reason)
        }
    }

    // MARK: Results

    /// Fold a browse snapshot into the published list. Returns whether it
    /// actually published — an unchanged snapshot, or one inside the debounce
    /// window, doesn't churn the view.
    @discardableResult
    func ingest(_ raw: [RawTakService], now: Date = Date()) -> Bool {
        let snapshot = Self.snapshot(from: raw, cap: maxResults)
        guard snapshot != services else {
            pending = nil
            return false
        }
        pending = snapshot
        return flushPending(now: now)
    }

    /// Publish a coalesced update once the debounce window has passed.
    /// Coalescing must never drop an update, so the pending snapshot survives
    /// until it lands.
    @discardableResult
    func flushPending(now: Date = Date()) -> Bool {
        guard let snapshot = pending else { return false }
        guard now.timeIntervalSince(lastPublish) >= minPublishInterval else { return false }
        pending = nil
        lastPublish = now
        services = snapshot
        return true
    }

    /// Validate, dedupe by endpoint, sort, then cap. Capping last keeps the
    /// visible set deterministic when a busy LAN advertises more than fits.
    static func snapshot(from raw: [RawTakService], cap: Int) -> [DiscoveredTakService] {
        var byEndpoint: [String: DiscoveredTakService] = [:]
        for candidate in raw {
            guard let service = TakMdns.make(
                serviceName: candidate.serviceName,
                host: candidate.host,
                port: candidate.port,
                txt: candidate.txt
            ) else { continue }
            // First claim on an endpoint wins; a later duplicate renaming the
            // row under the operator's thumb is worse than a stale label.
            if byEndpoint[service.id] == nil { byEndpoint[service.id] = service }
        }
        let sorted = byEndpoint.values.sorted {
            let byName = $0.serviceName.localizedCaseInsensitiveCompare($1.serviceName)
            return byName == .orderedSame ? $0.id < $1.id : byName == .orderedAscending
        }
        return Array(sorted.prefix(cap))
    }

    private func receive(_ raw: [RawTakService]) {
        guard isRunning else { return }
        if ingest(raw) { return }
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard pending != nil, !flushScheduled else { return }
        flushScheduled = true
        let delay = minPublishInterval
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.flushScheduled = false
            self.flushPending()
        }
    }
}

// MARK: - NWBrowser

/// The real browse.
///
/// `NWBrowser` reports service endpoints, not addresses, and Network.framework
/// ships no standalone resolver — so each newly seen endpoint gets a throwaway
/// `NWConnection` whose ready path carries the host and port. The connection is
/// torn down the moment it reports, and abandoned after `resolveTimeout`, so a
/// responder that answers the browse but never accepts a socket can't pin a
/// slot open.
final class BonjourTakBrowser: TakServiceBrowsing {

    var onUpdate: (([RawTakService]) -> Void)?
    var onFailure: ((TakDiscoveryFailure) -> Void)?

    private let queue = DispatchQueue(label: "soy.engindearing.omnitak.mdns")
    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]
    private var resolved: [String: RawTakService] = [:]
    private var txtByEndpoint: [String: [String: String]] = [:]

    /// A busy LAN can advertise far more than we'll ever show, and each resolve
    /// costs a connection.
    private let maxResolves = TakMdns.maxResults * 2
    private let resolveTimeout: TimeInterval = 5

    func start() {
        queue.async { [weak self] in
            guard let self, self.browser == nil else { return }

            let parameters = NWParameters()
            // Peer-to-peer would light up AWDL hunting for servers that aren't
            // on the Wi-Fi anyway — pure battery cost for a LAN browse.
            parameters.includePeerToPeer = false

            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: TakMdns.serviceType, domain: nil),
                using: parameters
            )

            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    self?.onFailure?(TakMdns.classify(error))
                case .waiting(let error):
                    // NWBrowser sits in .waiting while the network settles, and
                    // most of those clear on their own. The local-network
                    // denial arrives here too, and that one never clears.
                    let failure = TakMdns.classify(error)
                    if failure == .permissionDenied { self?.onFailure?(failure) }
                default:
                    break
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handle(results)
            }

            self.browser = browser
            browser.start(queue: self.queue)
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.browser?.stateUpdateHandler = nil
            self.browser?.browseResultsChangedHandler = nil
            self.browser?.cancel()
            self.browser = nil
            for connection in self.resolvers.values {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
            self.resolvers.removeAll()
            self.resolved.removeAll()
            self.txtByEndpoint.removeAll()
        }
    }

    // MARK: Browse handling

    private func handle(_ results: Set<NWBrowser.Result>) {
        var live = Set<String>()

        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            let key = Self.key(for: result.endpoint)
            live.insert(key)

            if case let .bonjour(record) = result.metadata {
                txtByEndpoint[key] = record.dictionary
            }

            guard resolved[key] == nil, resolvers[key] == nil else { continue }
            guard resolvers.count + resolved.count < maxResolves else { continue }
            resolve(result.endpoint, key: key, name: name)
        }

        // Anything that left the LAN leaves the list, and stops being resolved.
        for gone in Set(resolved.keys).subtracting(live) {
            resolved[gone] = nil
            txtByEndpoint[gone] = nil
        }
        for gone in Set(resolvers.keys).subtracting(live) {
            finishResolve(gone, publishing: false)
        }

        publish()
    }

    private func resolve(_ endpoint: NWEndpoint, key: String, name: String) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        resolvers[key] = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let remote = connection?.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = remote,
                   let hostText = Self.text(for: host) {
                    self.resolved[key] = RawTakService(
                        serviceName: name,
                        host: hostText,
                        port: Int(port.rawValue),
                        txt: self.txtByEndpoint[key] ?? [:]
                    )
                }
                self.finishResolve(key)
            case .failed, .cancelled:
                self.finishResolve(key)
            default:
                break
            }
        }

        connection.start(queue: queue)

        queue.asyncAfter(deadline: .now() + resolveTimeout) { [weak self] in
            guard let self, self.resolvers[key] != nil else { return }
            self.finishResolve(key)
        }
    }

    private func finishResolve(_ key: String, publishing: Bool = true) {
        if let connection = resolvers.removeValue(forKey: key) {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        if publishing { publish() }
    }

    private func publish() {
        onUpdate?(Array(resolved.values))
    }

    private static func key(for endpoint: NWEndpoint) -> String {
        if case let .service(name, type, domain, _) = endpoint {
            return "\(name)|\(type)|\(domain)"
        }
        return "\(endpoint)"
    }

    private static func text(for host: NWEndpoint.Host) -> String? {
        switch host {
        case .name(let name, _): return name
        case .ipv4(let address): return "\(address)"
        case .ipv6(let address): return "\(address)"
        @unknown default: return nil
        }
    }
}
