//
//  TAKLinkLiveness.swift
//  OmniTAKMobile
//
//  The rules that decide when a TAK server connection is dead and how soon to
//  dial it again (#149, #154). Pure logic: no sockets, no timers, and no
//  Date() inside. The clock is passed in as monotonic nanoseconds
//  (DispatchTime.now().uptimeNanoseconds), so the rules run against a fake
//  clock in tests. DirectTCPSender and TAKService supply the real clock and do
//  the sending and the scheduling.
//
//  These are the same rules as the Android connection class (OmniTAK-Android
//  #233 and #246): the ping every TAK client sends, the give-up rule and the
//  re-dial backoff.
//

import Foundation

// MARK: - Ping frames

/// The ping every TAK client sends: a CoT event of type `t-x-c-t`. A TAK Server
/// answers it with `t-x-c-t-r`. OpenTAKServer sends the ping itself back, which
/// counts as an answer too.
enum TAKPing {
    static let pingType = "t-x-c-t"
    static let pongType = "t-x-c-t-r"

    /// How long a ping stays valid, in seconds after its time.
    static let staleAfter: TimeInterval = 10

    /// What a received frame is, as far as the ping exchange is concerned.
    enum Frame: Equatable {
        /// `t-x-c-t-r`: the server answered a ping.
        case pong
        /// A ping carrying the uid of the last ping this connection sent:
        /// the server sent ours back.
        case ownPingEchoed
        /// A ping from somebody else, relayed by a server that answers none.
        /// It proves nothing about this link.
        case otherPing
        /// Anything else. It goes on to the CoT pipeline.
        case other

        /// True when the frame shows the server answers pings.
        var answersOurPing: Bool { self == .pong || self == .ownPingEchoed }
        /// True when the frame belongs to the ping exchange and is not CoT
        /// data: it is consumed and not counted as a received message.
        var isPingTraffic: Bool { self != .other }
    }

    /// The ping frame. Same as Android: how `m-g`, point 0/0 with ce and le
    /// 9999999.0, an empty detail, time and start both `now`, stale ten
    /// seconds later, uid XML-escaped.
    static func xml(uid: String, now: Date) -> String {
        let time = CoTXMLBuilder.timestamp(now)
        let stale = CoTXMLBuilder.timestamp(now.addingTimeInterval(staleAfter))
        return "<event version=\"2.0\" uid=\"\(uid.xmlEscaped)\" type=\"\(pingType)\" how=\"m-g\" "
            + "time=\"\(time)\" start=\"\(time)\" stale=\"\(stale)\">"
            + "<point lat=\"0.0\" lon=\"0.0\" hae=\"0.0\" ce=\"9999999.0\" le=\"9999999.0\"/>"
            + "<detail/></event>"
    }

    /// Sort a received frame. `lastPingUID` is the uid of the last ping this
    /// connection sent, not yet escaped, or nil when it has sent none.
    static func classify(_ xml: String, lastPingUID: String?) -> Frame {
        switch eventType(of: xml) {
        case pongType:
            return .pong
        case pingType:
            if let ours = lastPingUID, eventUID(of: xml) == ours.xmlEscaped {
                return .ownPingEchoed
            }
            return .otherPing
        default:
            return .other
        }
    }

    /// The `type` attribute of the frame's `<event>` start tag. Single or
    /// double quotes, any attribute order, whitespace around `=`. Nil when
    /// there is no event element or it has no type.
    static func eventType(of xml: String) -> String? {
        eventAttribute("type", in: xml)
    }

    /// The `uid` attribute of the frame's `<event>` start tag, as written
    /// (still escaped). Nil when there is none.
    static func eventUID(of xml: String) -> String? {
        eventAttribute("uid", in: xml)
    }

    // The start tag is read attribute by attribute, honouring the quotes, so a
    // uid that happens to contain the text `type='t-x-c-t'` is not mistaken
    // for the type.
    private static func eventAttribute(_ wanted: String, in xml: String) -> String? {
        let wantedBytes = Array(wanted.utf8)
        var text = xml
        return text.withUTF8 { scan($0, for: wantedBytes) }
    }

    private static func scan(_ b: UnsafeBufferPointer<UInt8>, for wanted: [UInt8]) -> String? {
        let n = b.count
        let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/"), eq = UInt8(ascii: "=")
        let dq = UInt8(ascii: "\""), sq = UInt8(ascii: "'")
        let tag = Array("<event".utf8)

        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

        // Find "<event" followed by whitespace, ">" or "/" (not "<events" or "<eventful").
        var i = 0
        var p = -1
        while i + tag.count <= n {
            if b[i] == lt {
                var matches = true
                for k in 1..<tag.count where b[i + k] != tag[k] { matches = false; break }
                if matches {
                    let after = i + tag.count
                    if after < n, isSpace(b[after]) || b[after] == gt || b[after] == slash {
                        p = after
                        break
                    }
                }
            }
            i += 1
        }
        if p < 0 { return nil }

        // Walk the attributes of the start tag.
        while p < n {
            while p < n, isSpace(b[p]) { p += 1 }
            if p >= n || b[p] == gt || b[p] == slash { return nil }
            let nameStart = p
            while p < n, !isSpace(b[p]), b[p] != eq, b[p] != gt, b[p] != slash { p += 1 }
            let nameEnd = p
            if nameEnd == nameStart { p += 1; continue }
            while p < n, isSpace(b[p]) { p += 1 }
            guard p < n, b[p] == eq else { continue }
            p += 1
            while p < n, isSpace(b[p]) { p += 1 }
            guard p < n, b[p] == dq || b[p] == sq else { return nil }
            let quote = b[p]
            p += 1
            let valueStart = p
            while p < n, b[p] != quote { p += 1 }
            guard p < n else { return nil }
            let valueEnd = p
            p += 1
            if nameEnd - nameStart == wanted.count {
                var same = true
                for k in 0..<wanted.count where b[nameStart + k] != wanted[k] { same = false; break }
                if same {
                    return String(decoding: UnsafeBufferPointer(rebasing: b[valueStart..<valueEnd]), as: UTF8.self)
                }
            }
        }
        return nil
    }
}

// MARK: - Liveness

/// Decides when to ping a server and when to give up on it, given what has
/// arrived. It holds no clock: every call says what time it is.
///
/// What it does:
/// - No ping in the first `pingIdle` seconds of a connection, so the app's own
///   first event reaches the server before the ping does.
/// - Until the server has answered one ping, a ping goes out every `pingIdle`
///   seconds, busy stream or not, to learn whether it answers at all.
/// - After that, a ping goes out only when nothing has arrived for `pingIdle`.
/// - A server that has answered is given up on when a ping has had no reply of
///   any kind for `pongWait` seconds on two ticks in a row. The second look is
///   there because a process that was stalled finds a long silence on its
///   clock while the answer may already sit in the socket buffer, unread.
/// - A server that has never answered a ping is never given up on for being
///   quiet: a plain CoT listener that ignores pings would otherwise be dialed
///   again in a loop.
/// - Idle time alone never ends a connection: a ping must have gone unanswered.
struct TAKLinkLiveness {
    struct Timing: Equatable {
        /// Ask the server when nothing has arrived for this long. Also the
        /// wait before a connection's first ping.
        var pingIdle: TimeInterval = 15
        /// How long a server that answers pings gets to send anything after one.
        var pongWait: TimeInterval = 25
        /// How often the owner calls `tick`.
        var tick: TimeInterval = 5
    }

    enum Action: Equatable {
        case nothing
        case sendPing
        case giveUp
    }

    /// True once the server has answered a ping. A fact about the server: the
    /// owner carries it from one connection to the next.
    private(set) var serverAnswersPings: Bool

    private let pingIdleNanos: UInt64
    private let pongWaitNanos: UInt64
    private var lastRx: UInt64
    private var lastPing: UInt64
    /// When the first ping since the last received byte went out, or nil when
    /// no ping is waiting for an answer.
    private var asked: UInt64?
    private var suspected = false

    init(now: UInt64, serverAnswersPings: Bool, timing: Timing = Timing()) {
        self.serverAnswersPings = serverAnswersPings
        self.pingIdleNanos = Self.nanos(timing.pingIdle)
        self.pongWaitNanos = Self.nanos(timing.pongWait)
        // The first ping waits its turn behind the app's own first event.
        self.lastRx = now
        self.lastPing = now
    }

    /// Bytes arrived from the server. Anything counts, a pong or CoT data.
    mutating func received(now: UInt64) {
        lastRx = max(lastRx, now)
    }

    /// The server answered a ping: a pong, or our own ping sent back.
    mutating func answered() {
        serverAnswersPings = true
    }

    /// Look at the link. Call every `Timing.tick`. A `.sendPing` means send it
    /// now (the ping time is already recorded); `.giveUp` means end the connection.
    mutating func tick(now: UInt64) -> Action {
        // A ping is waiting for an answer when nothing has arrived since it went out.
        let waiting = asked.map { lastRx < $0 } ?? false

        if serverAnswersPings, waiting, let asked = asked, Self.elapsed(now, since: asked) >= pongWaitNanos {
            // Look once more on the next tick before giving up.
            if suspected { return .giveUp }
            suspected = true
            return .nothing
        }
        suspected = false

        let due = Self.elapsed(now, since: lastPing) >= pingIdleNanos
            && (!serverAnswersPings || Self.elapsed(now, since: lastRx) >= pingIdleNanos)
        if due {
            lastPing = now
            if !waiting { asked = now }
            return .sendPing
        }
        return .nothing
    }

    /// Rounded, not truncated: 0.3 s must be exactly 300 000 000 ns.
    private static func nanos(_ seconds: TimeInterval) -> UInt64 {
        seconds <= 0 ? 0 : UInt64((seconds * 1_000_000_000).rounded())
    }

    /// Nanoseconds from `earlier` to `now`; zero if the clock reads backwards.
    private static func elapsed(_ now: UInt64, since earlier: UInt64) -> UInt64 {
        now > earlier ? now - earlier : 0
    }
}

// MARK: - Re-dial backoff

/// How long to wait before dialing a server again after a connection ended or
/// a dial failed: 0, 2, 4, 8, 16, 30 seconds, then 30 for ever. A connection
/// that held for `heldLongEnough` starts the delays over, so the next attempt
/// is at once. One that dropped sooner does not, so a server that accepts and
/// drops at once is not dialed in a tight loop.
struct TAKRedialBackoff {
    static let delays: [TimeInterval] = [0, 2, 4, 8, 16, 30]
    static let heldLongEnough: TimeInterval = 10

    private var next = 0

    /// The delay before the next dial. Moves on to the following one.
    mutating func nextDelay() -> TimeInterval {
        let delay = Self.delays[min(next, Self.delays.count - 1)]
        if next < Self.delays.count { next += 1 }
        return delay
    }

    /// A connection ended after being up for `held` seconds. Zero for a dial
    /// that never came up.
    mutating func connectionEnded(after held: TimeInterval) {
        if held >= Self.heldLongEnough { next = 0 }
    }
}
