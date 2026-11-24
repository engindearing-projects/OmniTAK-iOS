//
//  MumbleClient.swift
//  OmniTAKMobile
//
//  A small Mumble client for push-to-talk against the TAK server's Murmur
//  (OTS co-hosts it on the TAK host, port 64738). Ported in spirit from
//  TAK-XVoice's MumbleSession/MumbleTransport (Android), not line by line:
//
//  - TCP only. Voice rides UDPTunnel (type 1) over the TLS control channel;
//    no UDP / OCB2 path (Android doesn't use one either).
//  - Auth is the enrolled TAK client certificate via the host's
//    VoiceHostBridge (empty password). Username: "<callsign>---<slot>".
//  - Legacy voice packet format (Opus header type 4), one frame per packet,
//    sequence restarting at each PTT burst, empty terminator packet at end.
//  - Ping every 8 s; drop the link if the server is silent for 18 s;
//    reconnect with 1,2,4,8,15,30,60 s backoff; auth rejects are fatal.
//
//  One client per voice slot: slot 1 = "VS1", slot 2 = "VS2" (dual PTT, as
//  on Android). VX call signaling and multicast are not
//  ported.
//

import Foundation
import Network
import CryptoKit

protocol MumbleClientDelegate: AnyObject {
    func mumble(_ client: MumbleClient, stateChanged state: MumbleClient.State)
    /// `suppressed`: the server made us listen-only in this channel.
    /// `settled`: no auto-join is still pending (we are where we asked to be).
    func mumble(_ client: MumbleClient, channelsChanged channels: [UInt32: String], current: UInt32?, suppressed: Bool, settled: Bool, onTarget: Bool)
    func mumble(_ client: MumbleClient, voice opus: Data, from session: UInt32, terminator: Bool)
}

final class MumbleClient {
    enum State: Equatable {
        case idle
        case connecting
        case connected(session: UInt32)
        case reconnecting(inSeconds: Int, reason: String)
        case failed(String)      // fatal (auth reject / kicked): no auto-retry
    }

    enum MsgType: UInt16 {
        case version = 0, udpTunnel = 1, authenticate = 2, ping = 3, reject = 4, serverSync = 5
        case channelRemove = 6, channelState = 7, userRemove = 8, userState = 9
        case textMessage = 11, permissionDenied = 12, cryptSetup = 15, codecVersion = 21
    }

    static let port: UInt16 = 64738
    private static let backoff = [1, 2, 4, 8, 15, 30, 60]

    weak var delegate: MumbleClientDelegate?

    private let queue = DispatchQueue(label: "omnitak.voice.mumble")
    private let makeConnection: (String, UInt16) -> NWConnection?
    private let host: String
    private let username: String

    private var conn: NWConnection?
    private var rx = Data()
    private var pingTimer: DispatchSourceTimer?
    private var lastRx = Date()
    private var attempt = 0
    private var stopped = true
    private var mySession: UInt32?
    private var txSequence: UInt64 = 0

    private(set) var channels: [UInt32: String] = [:]
    private(set) var users: [UInt32: (name: String, channel: UInt32)] = [:]
    private(set) var currentChannel: UInt32?
    /// The channel this slot should be in (nil = stay where the server puts
    /// us). Persistent for the client's life: re-applied after every reconnect,
    /// updated by `join(channelId:)` and by admin moves.
    var desiredChannelName: String?
    /// Preferred over the name when it still exists on the server: channel
    /// names can repeat (Murmur's root channel carries the server's name, and a
    /// sub-channel may share it), ids can't.
    var desiredChannelId: UInt32?
    /// Optional finite retry schedule (seconds). When set, the client gives up
    /// (state .failed) after the last entry instead of retrying forever. Used
    /// for slot 2's ghost-session ladder (3 s, 8 s, then stay down).
    var retryLadder: [Int]?
    private var suppressed = false
    private var userSuppressed: [UInt32: Bool] = [:]
    private var rxCount: [UInt32: Int] = [:]
    /// Bumped on every connect/teardown; callbacks and delayed reconnects from
    /// an older connection compare and bail out, so they can't tear down or
    /// re-schedule the current one.
    private var generation = 0
    /// A join toward the target was sent and not yet confirmed or refused.
    private var joinPending = false
    /// The target channel doesn't exist or the join was refused this session.
    private var targetUnavailable = false

    private(set) var state: State = .idle {
        didSet { if state != oldValue { let s = state; DispatchQueue.main.async { self.delegate?.mumble(self, stateChanged: s) } } }
    }

    let slot: Int

    init(host: String, callsign: String, deviceUid: String, slot: Int = 1,
         makeConnection: @escaping (String, UInt16) -> NWConnection?) {
        self.host = host
        self.makeConnection = makeConnection
        self.slot = slot
        self.username = Self.username(callsign: callsign, deviceUid: deviceUid, slot: slot)
    }

    /// "<callsign with spaces→_>---<first 3 bytes of SHA-256(uid) hex>VS1",
    /// matching TAK-XVoice so other XV clients recognise us in the roster.
    static func username(callsign: String, deviceUid: String, slot: Int = 1) -> String {
        // Murmur's default username rule allows letters, digits and a few
        // symbols; anything else would get a fatal InvalidUsername reject.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-.@()[]{}|"))
        let cleaned = String(callsign.unicodeScalars.map { allowed.contains($0) && $0.isASCII ? Character($0) : "_" })
        let cs = cleaned.isEmpty ? "ATAK" : cleaned
        let digest = SHA256.hash(data: Data(deviceUid.utf8))
        let hex = digest.prefix(3).map { String(format: "%02x", $0) }.joined()
        return "\(cs)---\(hex)VS\(slot)"
    }

    static func displayName(_ username: String) -> String {
        if let r = username.range(of: "---") { return String(username[..<r.lowerBound]) }
        return username
    }

    func userName(_ session: UInt32) -> String? {
        queue.sync { users[session].map { Self.displayName($0.name) } }
    }

    // MARK: - Lifecycle

    func start() {
        queue.async {
            self.stopped = false
            self.attempt = 0
            self.connect()
        }
    }

    func stop() {
        queue.async {
            self.stopped = true
            self.teardown()
            self.state = .idle
        }
    }

    private func connect() {
        guard !stopped else { return }
        teardown()
        let gen = generation
        joinPending = false
        targetUnavailable = false
        state = .connecting
        guard let c = makeConnection(host, Self.port) else {
            state = .failed("No enrolled client certificate for the active TAK server")
            return
        }
        conn = c
        rx.removeAll()
        c.stateUpdateHandler = { [weak self] st in
            guard let self = self, self.generation == gen else { return }
            switch st {
            case .ready:
                print("[Mumble VS\(self.slot)] TLS up to \(self.host):\(Self.port) as \(self.username)")
                self.lastRx = Date()
                self.sendVersion()
                self.sendAuthenticate()
                self.startPing()
                self.receive()
            case .failed(let e):
                self.scheduleReconnect("connection failed: \(e)")
            case .waiting(let e):
                self.scheduleReconnect("network unavailable: \(e)")
            case .cancelled:
                break
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    private func teardown() {
        generation += 1
        pingTimer?.cancel(); pingTimer = nil
        conn?.stateUpdateHandler = nil
        conn?.cancel(); conn = nil
        mySession = nil
        channels.removeAll(); users.removeAll(); currentChannel = nil
        suppressed = false; userSuppressed.removeAll()
    }

    private func scheduleReconnect(_ reason: String) {
        guard !stopped else { return }
        if case .failed = state { return }
        teardown()
        if let ladder = retryLadder, attempt >= ladder.count {
            fail("gave up after \(ladder.count) retries (\(reason))")
            return
        }
        let delay = retryLadder.map { $0[attempt] } ?? Self.backoff[min(attempt, Self.backoff.count - 1)]
        attempt += 1
        print("[Mumble VS\(self.slot)] \(reason) — reconnecting in \(delay)s")
        state = .reconnecting(inSeconds: delay, reason: reason)
        let gen = generation
        queue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self = self, self.generation == gen else { return }   // stopped/restarted meanwhile
            self.connect()
        }
    }

    private func fail(_ reason: String) {
        print("[Mumble VS\(self.slot)] fatal: \(reason)")
        stopped = true
        teardown()
        state = .failed(reason)
    }

    // MARK: - Send

    private func send(_ type: MsgType, _ payload: Data) {
        guard let c = conn else { return }
        let gen = generation
        var frame = Data(capacity: 6 + payload.count)
        let t = type.rawValue.bigEndian, l = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: t) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: l) { frame.append(contentsOf: $0) }
        frame.append(payload)
        c.send(content: frame, completion: .contentProcessed { [weak self] err in
            guard let err = err else { return }
            self?.queue.async {
                guard let self = self, self.generation == gen else { return }
                self.scheduleReconnect("write failed: \(err)")
            }
        })
    }

    private func sendVersion() {
        var w = MumbleProtoWriter()
        w.uint32(1, 0x010304)
        w.string(2, "XV/0.1.0-ios")
        w.string(3, "iOS")
        w.string(4, ProcessInfo.processInfo.operatingSystemVersionString)
        send(.version, w.data)
    }

    private func sendAuthenticate() {
        var w = MumbleProtoWriter()
        w.string(1, username)
        w.string(2, "")
        w.bool(5, true)          // opus
        send(.authenticate, w.data)
    }

    private func startPing() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 8, repeating: 8)
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.conn != nil else { return }
            if Date().timeIntervalSince(self.lastRx) > 18 {
                self.scheduleReconnect("server silent for 18s")
                return
            }
            var w = MumbleProtoWriter()
            w.uint(1, UInt64(Date().timeIntervalSince1970 * 1_000_000))
            self.send(.ping, w.data)
        }
        t.resume()
        pingTimer = t
    }

    /// Join a channel by id (0 = Root).
    func join(channelId: UInt32) {
        queue.async {
            guard let me = self.mySession else {
                print("[Mumble VS\(self.slot)] join \(channelId) dropped: no session yet")
                return
            }
            print("[Mumble VS\(self.slot)] join → channel \(channelId) '\(self.channels[channelId] ?? "?")'")
            self.desiredChannelId = channelId
            self.desiredChannelName = channelId == 0 ? "Lobby" : (self.channels[channelId] ?? self.desiredChannelName)
            self.joinPending = self.currentChannel != channelId
            self.targetUnavailable = false
            var w = MumbleProtoWriter()
            w.uint32(1, me)
            w.uint32(5, channelId)
            w.bool(9, false)   // self_mute
            w.bool(10, false)  // self_deaf
            self.send(.userState, w.data)
        }
    }

    // MARK: - Voice out

    func beginTransmission() { queue.async { self.txSequence = 0 } }

    /// Send one Opus frame (normal speech target 0).
    func sendVoice(_ opus: Data) {
        queue.async { self.sendVoicePacket(opus, terminator: false) }
    }

    /// Mark end of transmission with an empty terminator packet.
    func endTransmission() {
        queue.async { self.sendVoicePacket(Data(), terminator: true) }
    }

    private func sendVoicePacket(_ opus: Data, terminator: Bool) {
        guard case .connected = state else { return }
        // Mumble sequence numbers count 10 ms frames; each packet carries
        // `frameSamples` (20 ms = 2 units). Advancing by 1 per 20 ms packet made
        // receivers' jitter buffers think our audio ran at double speed.
        txSequence += UInt64(VoiceAudioEngine.frameSamples / 480)
        send(.udpTunnel, MumbleVoicePacket.encode(sequence: txSequence, opus: opus, terminator: terminator))
    }

    // MARK: - Receive

    private func receive() {
        let gen = generation
        conn?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self, self.generation == gen else { return }
            if let d = data, !d.isEmpty {
                self.lastRx = Date()
                self.rx.append(d)
                self.drain()
            }
            if let err = err { self.scheduleReconnect("read failed: \(err)"); return }
            if done { self.scheduleReconnect("server closed the connection"); return }
            self.receive()
        }
    }

    private func drain() {
        while rx.count >= 6 {
            let b = [UInt8](rx.prefix(6))
            let type = UInt16(b[0]) << 8 | UInt16(b[1])
            let len = Int(UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5]))
            guard len <= 256 * 1024 else { scheduleReconnect("oversized message"); return }
            guard rx.count >= 6 + len else { return }
            let payload = rx.subdata(in: rx.startIndex + 6 ..< rx.startIndex + 6 + len)
            rx.removeSubrange(rx.startIndex ..< rx.startIndex + 6 + len)
            rx = Data(rx)   // re-base indices
            let gen = generation
            handle(type, payload)
            // A handled message may have failed or reset the connection: stop.
            if generation != gen || conn == nil { rx.removeAll(); return }
        }
    }

    private func handle(_ rawType: UInt16, _ payload: Data) {
        guard let type = MsgType(rawValue: rawType) else { return }
        if type == .udpTunnel { handleVoice(payload); return }
        guard let f = MumbleProtoFields(payload) else { return }
        switch type {
        case .serverSync:
            mySession = f.uint32(1)
            attempt = 0
            if let s = mySession { state = .connected(session: s) }
            // Our own UserState arrives BEFORE ServerSync (and Murmur restores a
            // registered cert user to its last channel), so take the starting
            // channel and suppression from what we already recorded.
            if let me = mySession, let u = users[me] {
                currentChannel = u.channel
                suppressed = userSuppressed[me] ?? false
            }
            print("[Mumble VS\(self.slot)] ServerSync session=\(mySession ?? 0), starting in channel \(currentChannel.map(String.init) ?? "0") '\(channels[currentChannel ?? 0] ?? "?")'")
            autoJoin()
            // The server sends the whole channel directory before ServerSync,
            // so a target still unresolved here doesn't exist on this server.
            // Keep it (it may come back) but don't wait for it.
            if let want = desiredChannelName, !want.isEmpty, resolveTarget() == nil {
                print("[Mumble VS\(self.slot)] channel '\(want)' not found — staying where the server put us")
                targetUnavailable = true
            }
            publishChannels()
        case .channelState:
            guard let id = f.uint32(1) else { return }
            if let name = f.string(3) { channels[id] = name }
            else if channels[id] == nil { channels[id] = id == 0 ? "Root" : "Channel \(id)" }
            autoJoin()
            publishChannels()
        case .channelRemove:
            if let id = f.uint32(1) { channels[id] = nil; publishChannels() }
        case .userState:
            guard let s = f.uint32(1) else { return }
            var u = users[s] ?? (name: "", channel: 0)
            if let n = f.string(3) { u.name = n }
            let movedChannel = f.has(5) && (f.uint32(5) ?? 0) != u.channel
            if f.has(5) { u.channel = f.uint32(5) ?? 0 }
            users[s] = u
            if f.has(8) { userSuppressed[s] = f.bool(8) ?? false } else if movedChannel { userSuppressed[s] = false }
            if s == mySession {
                // Suppression (listen-only) is per channel: reset on a move
                // unless the same message sets it.
                if f.has(8) { suppressed = f.bool(8) ?? false } else if movedChannel { suppressed = false }
                if currentChannel != u.channel {
                    print("[Mumble VS\(slot)] now in channel \(u.channel) '\(channels[u.channel] ?? "?")' (field present: \(f.has(5)))")
                }
                currentChannel = u.channel
                if let t = resolveTarget(), t == u.channel {
                    joinPending = false
                } else if !joinPending, movedChannel, mySession != nil {
                    // Moved by an admin (or a channel removal): adopt it.
                    print("[Mumble VS\(slot)] moved by the server to \(u.channel) — adopting it")
                    desiredChannelId = u.channel
                    desiredChannelName = u.channel == 0 ? "Lobby" : channels[u.channel]
                    targetUnavailable = false
                }
                publishChannels()
            }
        case .userRemove:
            guard let s = f.uint32(1) else { return }
            if s == mySession { fail("Removed from the voice server: \(f.string(3) ?? "kicked")"); return }
            users[s] = nil
        case .reject:
            // RejectType: 1 WrongVersion, 2 InvalidUsername, 3 WrongUserPW,
            // 4 WrongServerPW, 5 UsernameInUse, 6 ServerFull, 7 NoCertificate, 8 AuthenticatorFail
            let t = f.uint32(1) ?? 0, reason = f.string(2) ?? "rejected"
            if [2, 3, 4, 7, 8].contains(t) { fail("Voice server rejected login: \(reason)") }
            else { scheduleReconnect("rejected: \(reason)") }
        case .permissionDenied:
            // PermissionDenied: permission 1, channel_id 2, session 3, reason 4, type 5, name 6
            print("[Mumble VS\(self.slot)] permission denied (type \(f.uint32(5) ?? 0), channel \(f.uint32(2).map(String.init) ?? "-")): \(f.string(4) ?? "")")
            if joinPending {
                joinPending = false
                targetUnavailable = true
                publishChannels()
            }
        case .textMessage, .ping, .version, .cryptSetup, .codecVersion, .authenticate, .udpTunnel:
            break
        }
    }

    /// The target channel's id in the current directory, if it exists.
    private func resolveTarget() -> UInt32? {
        guard let want = desiredChannelName, !want.isEmpty else { return nil }
        if want.caseInsensitiveCompare("Lobby") == .orderedSame || want.caseInsensitiveCompare("Root") == .orderedSame {
            return 0
        }
        if let id = desiredChannelId, let n = channels[id], n.caseInsensitiveCompare(want) == .orderedSame {
            return id
        }
        // By name, never resolving to the root channel (id 0): it is "Lobby"
        // in the UI even when the server names it like a sub-channel.
        return channels.filter { $0.key != 0 && $0.value.caseInsensitiveCompare(want) == .orderedSame }
            .keys.sorted().first
    }

    /// Move to the target channel once we have a session and it exists.
    private func autoJoin() {
        guard mySession != nil, !joinPending, !targetUnavailable, let id = resolveTarget() else { return }
        guard currentChannel != id else { return }
        print("[Mumble VS\(slot)] auto-join → '\(desiredChannelName ?? "")' (\(id))")
        join(channelId: id)
        joinPending = true
    }

    private func publishChannels() {
        let ch = channels, cur = currentChannel ?? (mySession != nil ? 0 : nil)
        let sup = suppressed
        // Settled = not waiting on a join. On target = where we were asked to be.
        let settled = mySession != nil && !joinPending
        let target = resolveTarget()
        let onTarget = (desiredChannelName?.isEmpty ?? true) || (target != nil && target == cur)
        DispatchQueue.main.async {
            self.delegate?.mumble(self, channelsChanged: ch, current: cur, suppressed: sup, settled: settled, onTarget: onTarget)
        }
    }

    /// Legacy voice packet: header, session, sequence, len(+terminator), opus.
    private func handleVoice(_ p: Data) {
        guard let pkt = MumbleVoicePacket.decode(p) else { return }   // Opus only
        let s = pkt.session, opus = pkt.opus, term = pkt.terminator
        rxCount[s, default: 0] += 1
        if rxCount[s] == 1 {
            print("[Mumble VS\(slot)] RX start from session \(s) '\(users[s]?.name ?? "?")' in channel \(users[s]?.channel ?? 0) (we are in \(currentChannel ?? 0))")
        }
        if term {
            print("[Mumble VS\(slot)] RX end from session \(s): \(rxCount[s] ?? 0) packets")
            rxCount[s] = nil
        }
        delegate?.mumble(self, voice: opus, from: s, terminator: term)
    }
}
