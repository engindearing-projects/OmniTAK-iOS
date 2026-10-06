//
//  MeshtasticManager+Settings.swift
//  OmniTAK Mobile
//
//  Writing a Meshtastic radio's settings (OmniTAK-iOS #148).
//
//  The radio replaces a whole sub-config (or channel) with the set_config (or
//  set_channel) it receives. So every write below starts from what the radio
//  holds now, changes the fields the operator edited, and sends the whole thing:
//
//      read -> patch -> set -> read back
//
//  The read before the write is a get request, answered by the radio. What this
//  app held from the config download, or from an earlier answer, is only as
//  fresh as that moment: anything changed on the radio since (from another app,
//  or by the radio itself, as a role change does to the position config) would
//  be written back to its old value. If the radio does not answer the read in
//  time, nothing is sent.
//
//  The read after the write is what the operator is told. "Applied" is said only
//  when the radio's own answer shows what was asked for.
//
//  Requests and answers. Every get request goes out in a packet with an id the
//  app made up and keeps, and the radio echoes that id in its answer. An answer
//  is kept only when it answers a request on the table: from this radio, on this
//  connection, with the id and for the thing that was asked, and with none of the
//  metadata a packet has when it was received by radio. The config download's own
//  frames (my_info, config, channel) are not packets and are taken as they come.
//  An answer that arrives after its deadline is still taken, if nothing newer was
//  asked for the same thing.
//
//  One operation at a time. A write waits for the one before it to finish its
//  read-back: a role change rewrites the position config on the radio, and only
//  the read that follows it says what that became.
//
//  Frames are at least `frameSpacing` apart on the link. The radio holds the
//  packets addressed to itself in a queue of four and drops the oldest when a
//  fifth arrives, so a burst loses the earliest writes.
//
//  No edit transaction. The app never sends begin_edit_settings. While one is
//  open the radio holds off saving, and off restarting, and only a commit or a
//  restart closes it, so a link that drops, or an app that is suspended or
//  killed, between the begin and the commit leaves the radio with the
//  transaction open: every write after that stays in the radio's memory and is
//  gone at the next power cycle, while the app says "applied". A set_channel
//  saves itself and does not restart the radio, so a set of channels is sent as
//  one set_channel after another, paced, with nothing to open or close.
//
//  A config write is different. The radio restarts to save it, and over
//  Bluetooth it cuts the link as soon as it takes one, so the read after the
//  write may never come, and a value may be put back when the radio starts
//  (#153). Each write is remembered, and what the radio reports in its config
//  download when it connects again is compared with what was sent: the report
//  says "applied", or what the radio reports instead.
//
//  Whose bytes. The settings belong to one connection: the one the operator
//  chose, which delivered a `my_info` naming the radio. A write is addressed to
//  that radio, sent down that connection, and the client refuses it if either has
//  changed. When the settings, the radio's node number or the connection are not
//  known, nothing is sent and the result says why.
//

import Foundation

extension MeshtasticManager {

    // MARK: - Where a write goes

    /// The radio, the connection and the link a write goes out on.
    struct Route {
        let link: MeshtasticAdminLink
        let active: ActiveLink
        let node: UInt32
    }

    enum Routing {
        case go(Route)
        case stop(String)
    }

    /// The route a write takes, or why there is none.
    func route() -> Routing {
        guard let active = activeLink, isConnected else {
            return .stop(MeshtasticWriteResult.notConnected)
        }
        // The radio the settings are from, on the connection they came from.
        guard let node = radioSettings.nodeNum else {
            return .stop(MeshtasticWriteResult.notLoaded)
        }
        guard let link = adminLink(for: active) else {
            return .stop(MeshtasticWriteResult.notConnected)
        }
        guard link.connectionSerial == active.connection else {
            return .stop(MeshtasticWriteResult.linkChanged)
        }
        return .go(Route(link: link, active: active, node: node))
    }

    /// Whether `route` is still the chosen connection to the same radio.
    func routeIsCurrent(_ route: Route) -> Bool {
        activeLink == route.active
            && isConnected
            && radioSettings.nodeNum == route.node
            && route.link.connectionSerial == route.active.connection
    }

    // MARK: - One operation at a time

    /// True while a settings operation is running or waiting for its turn.
    var settingsBusy: Bool { settingsOperations > 0 }

    func serialized<T>(_ body: () async -> T) async -> T {
        settingsOperations += 1
        await operationGate.acquire()
        defer {
            operationGate.release()
            settingsOperations -= 1
        }
        return await body()
    }

    // MARK: - Frames

    private func uptimeNanoseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Send one admin frame, no sooner than `frameSpacing` after the last one.
    /// False when it did not go.
    func sendFrame(_ payload: Data, wantResponse: Bool, packetID: UInt32, route: Route) async -> Bool {
        if let last = lastFrameTime {
            let spacing = UInt64(max(0, frameSpacing) * 1_000_000_000)
            let elapsed = uptimeNanoseconds() &- last
            if elapsed < spacing {
                try? await Task.sleep(nanoseconds: spacing - elapsed)
            }
        }
        guard routeIsCurrent(route) else { return false }
        let sent = route.link.sendAdmin(
            payload: payload, to: route.node, connection: route.active.connection,
            wantResponse: wantResponse, packetID: packetID)
        lastFrameTime = uptimeNanoseconds()
        return sent
    }

    /// An id for a packet: not 0, and not one a request is waiting on.
    func freshPacketID() -> UInt32 {
        for _ in 0..<64 {
            let id = requestIDSource()
            if id != 0 && outstandingRequests[id] == nil { return id }
        }
        return UInt32.random(in: 1...UInt32.max)
    }

    // MARK: - Reading

    /// Ask the radio for a sub-config or a channel and wait for the answer that
    /// belongs to the request.
    func read(_ subject: MeshtasticAdminSubject, route: Route) async -> MeshtasticAnswerOutcome {
        guard routeIsCurrent(route) else { return .linkLost }

        let payload: Data
        switch subject {
        case .config(let variant):
            guard let type = MeshtasticAdminCodec.ConfigType(variant: variant) else { return .noAnswer }
            payload = MeshtasticAdminCodec.encodeGetConfigRequest(type)
        case .channel(let index):
            payload = MeshtasticAdminCodec.encodeGetChannelRequest(index: index)
        }

        let id = freshPacketID()
        let request = MeshtasticOutstandingRequest(id: id, subject: subject, link: route.active, node: route.node)
        let wait = MeshtasticAnswerWait()
        request.waiter = wait
        outstandingRequests[id] = request
        latestRequestID[subject] = id

        guard await sendFrame(payload, wantResponse: true, packetID: id, route: route) else {
            forgetRequest(id)
            return .linkLost
        }
        // The deadline runs from the send.
        DispatchQueue.main.asyncAfter(deadline: .now() + answerTimeout) { [weak self] in
            self?.expireRequest(id)
        }
        return await wait.value()
    }

    private func forgetRequest(_ id: UInt32) {
        guard let request = outstandingRequests.removeValue(forKey: id) else { return }
        if latestRequestID[request.subject] == id { latestRequestID[request.subject] = nil }
    }

    /// The deadline of a request has passed. Whoever waits is told; the request
    /// stays on the table for a while, because the answer may still come.
    private func expireRequest(_ id: UInt32) {
        guard let request = outstandingRequests[id], !request.expired else { return }
        request.expired = true
        request.waiter?.fulfil(.noAnswer)
        request.waiter = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + lateAnswerWindow) { [weak self] in
            guard let self, let still = self.outstandingRequests[id], still.expired else { return }
            self.forgetRequest(id)
        }
    }

    /// Everything waiting on the link is over: the connection is gone or was
    /// replaced. The requests on the table will not be answered, and a channel
    /// write that was waiting for its read-back will not hear it on this link.
    /// When the link only dropped, the line the operator reads says so, and an
    /// entry the write put in the saved list stops waiting. The write itself
    /// stays on the list of those not settled: the radio may have taken it, and
    /// says so when it reports the slot again, after it connects or on a re-read.
    /// Config writes are not touched: they are checked when the radio reports in.
    func abandonRequests(markPendingWrites: Bool) {
        let requests = Array(outstandingRequests.values)
        outstandingRequests.removeAll()
        latestRequestID.removeAll()
        lastFrameTime = nil
        for request in requests {
            request.waiter?.fulfil(.linkLost)
            request.waiter = nil
        }
        for (slot, pending) in pendingChannelWrites {
            if markPendingWrites {
                setChannelReport(slot: slot, name: pending.name, state: .linkLost)
            }
            if pending.entryInserted {
                noteSavedChannel(node: pending.node, slot: slot, state: .notConfirmed)
            }
        }
    }

    /// The radio reported a channel slot in its config download. A write to it
    /// that was never settled (the link was lost, or it was not answered) is
    /// settled by what the radio reports now.
    func settleChannelWriteAfterReconnect(slot: Int, body: Data) {
        guard let pending = pendingChannelWrites[slot], pending.node == radioSettings.nodeNum else { return }
        settlePendingChannelWrite(slot: slot, answer: body)
    }

    /// Another radio has reported in: a channel write to the one before is not
    /// something it can settle.
    func dropChannelWrites(notFor node: UInt32) {
        let dropped = pendingChannelWrites.filter { $0.value.node != node }.map(\.key)
        for slot in dropped { pendingChannelWrites[slot] = nil }
        if !dropped.isEmpty { channelReports.removeAll { dropped.contains($0.slot) } }
    }

    /// An admin answer arrived on the chosen connection. It is kept only if it
    /// answers a request this app sent and has not yet had an answer: from the
    /// radio the request went to, on the connection it went down, with the id and
    /// for the thing asked, and with nothing that shows it was received by radio.
    func acceptAnswer(_ answer: MeshtasticAdminCodec.Answer) {
        guard let id = answer.requestId, id != 0,
              let request = outstandingRequests[id] else { return }
        guard activeLink == request.link,
              let node = radioSettings.nodeNum,
              node == request.node,
              answer.from == node else { return }
        guard !answer.hasReceiveSignals else { return }
        switch (request.subject, answer.content) {
        case (.config(let asked), .config(let variant, _)) where asked == variant:
            break
        case (.channel(let asked), .channel(let index, _)) where asked == index:
            break
        default:
            return
        }

        outstandingRequests[id] = nil
        // A newer request for the same thing has been sent since: this answer is
        // old news and must not stand for the current state.
        guard latestRequestID[request.subject] == id else { return }
        latestRequestID[request.subject] = nil

        let bytes: Data
        switch answer.content {
        case .config(let variant, let body):
            radioSettings.storeConfig(variant: variant, body: body)
            settleConfigReadBack(variant: variant, body: body, node: request.node)
            bytes = body
        case .channel(let index, let body):
            radioSettings.storeChannel(index: index, body: body)
            settlePendingChannelWrite(slot: index, answer: body)
            adoptSavedChannel(slot: index)
            bytes = body
        }
        request.waiter?.fulfil(.answer(bytes))
        request.waiter = nil
    }

    // MARK: - Device role, rebroadcast scope and position interval

    /// Apply device role + rebroadcast scope via AdminMessage.set_config.
    ///
    /// Reads the device config from the radio first, changes only the fields that
    /// differ from what it says, sends the whole message back, and reads it again
    /// to see what the radio holds. A nil argument leaves that field as the radio
    /// has it, and so does a value the radio already has. When nothing differs,
    /// nothing is sent (`.unchanged`). The rest of the device config (time zone,
    /// LED, button, buzzer) stays as the radio has it. A role change makes the
    /// firmware install that role's defaults, including a new position config,
    /// so the position config is not known from the moment the write goes, and
    /// is read again afterwards.
    ///
    /// The radio restarts to save a config, so what it answers before the restart
    /// is not the last word: the write is remembered, and compared with what the
    /// radio reports when it connects again (`configReports`).
    func applyDeviceConfig(
        role: MeshtasticAdminCodec.DeviceRole?,
        rebroadcastMode: MeshtasticAdminCodec.RebroadcastMode?
    ) async -> MeshtasticWriteResult {
        var expected: [MeshtasticConfigField: UInt64] = [:]
        if let role { expected[.role] = role.rawValue }
        if let rebroadcastMode { expected[.rebroadcastMode] = rebroadcastMode.rawValue }
        return await writeConfig(
            variant: MeshtasticAdminCodec.ConfigVariant.device,
            what: "Device config",
            expected: expected,
            rewritesPosition: { fresh in
                guard let role else { return false }
                return MeshtasticAdminCodec.deviceRole(in: fresh) != role.rawValue
            },
            build: { MeshtasticAdminCodec.encodeSetDeviceConfig(current: $0, role: role, rebroadcastMode: rebroadcastMode) })
    }

    /// Apply the position broadcast interval via AdminMessage.set_config, the
    /// same way: read, change the one field, send, read again. The rest of the
    /// position config (GPS mode, position flags, smart broadcast) stays as the
    /// radio has it. When the radio already has this interval, nothing is sent.
    func applyPositionBroadcastInterval(seconds: UInt32) async -> MeshtasticWriteResult {
        await writeConfig(
            variant: MeshtasticAdminCodec.ConfigVariant.position,
            what: "Position interval",
            expected: [.positionInterval: UInt64(seconds)],
            build: { MeshtasticAdminCodec.encodeSetPositionBroadcastInterval(current: $0, seconds: seconds) })
    }

    private func writeConfig(
        variant: Int,
        what: String,
        expected: [MeshtasticConfigField: UInt64],
        rewritesPosition: @escaping (Data) -> Bool = { _ in false },
        build: @escaping (Data) -> MeshtasticAdminCodec.Write?
    ) async -> MeshtasticWriteResult {
        await serialized {
            let route: Route
            switch self.route() {
            case .stop(let reason): return .refused(reason)
            case .go(let found): route = found
            }

            // Start from what the radio holds now.
            let fresh: Data
            switch await read(.config(variant: variant), route: route) {
            case .answer(let bytes): fresh = bytes
            case .noAnswer: return .refused(MeshtasticWriteResult.noAnswer)
            case .linkLost: return .refused(MeshtasticWriteResult.linkChanged)
            }
            guard let write = build(fresh) else { return .refused(MeshtasticWriteResult.unreadable) }
            guard !write.changesNothing else { return .unchanged }
            // The link may have been lost while the answer was being taken. What
            // the settings held went with it, and nothing is sent or marked.
            guard routeIsCurrent(route) else { return .refused(MeshtasticWriteResult.linkChanged) }

            // From here on what the radio holds is not known until it says. A role
            // change makes the firmware install the new role's defaults, a new
            // position config among them, so what the screen shows of that is not
            // known either.
            let device = MeshtasticAdminCodec.ConfigVariant.device
            let position = MeshtasticAdminCodec.ConfigVariant.position
            let positionBefore = radioSettings.config(variant: position)
            let rewritesPositionConfig = variant == device && rewritesPosition(fresh)
            radioSettings.invalidateConfig(variant: variant)
            if rewritesPositionConfig { radioSettings.invalidateConfig(variant: position) }
            let before = noteConfigWrite(variant: variant, node: route.node, what: what, expected: expected)

            guard await sendFrame(write.payload, wantResponse: false, packetID: freshPacketID(), route: route) else {
                // Nothing went. When this is still the connection the settings came
                // from they are as they were. When it is not, they went with the
                // connection and are not put back.
                restoreConfigWrite(variant: variant, before)
                if routeIsCurrent(route) {
                    radioSettings.storeConfig(variant: variant, body: fresh)
                    if rewritesPositionConfig, let positionBefore {
                        radioSettings.storeConfig(variant: position, body: positionBefore)
                    }
                }
                return .refused(MeshtasticWriteResult.linkChanged)
            }

            // What the radio holds now, and what the operator is told. The answer
            // settles the report when it is taken (`acceptAnswer`).
            switch await read(.config(variant: variant), route: route) {
            case .answer:
                break
            case .noAnswer:
                setConfigReportState(variant: variant, .noAnswer, ifCurrently: .sent)
            case .linkLost:
                setConfigReportState(variant: variant, .linkLost, ifCurrently: .sent)
            }
            let result: MeshtasticWriteResult
            if let report = configReports.first(where: { $0.variant == variant }) {
                result = report.state == .confirmed ? .applied : .notConfirmed(report.reason)
            } else {
                result = .notConfirmed(MeshtasticWriteResult.linkChanged)
            }

            // A role change rewrites the position config on the radio.
            if variant == device, routeIsCurrent(route) {
                _ = await read(.config(variant: position), route: route)
            }
            return result
        }
    }

    // MARK: - What became of a config write

    /// What a config write replaced in the reports, so that a write that was
    /// never sent can put it back.
    struct ConfigWriteSnapshot {
        let pending: PendingConfigWrite?
        let report: MeshtasticConfigReport?
    }

    /// A config write is about to go. Its values are remembered, merged over the
    /// writes to the same sub-config since the radio last reported, and the
    /// report says it is waiting.
    private func noteConfigWrite(
        variant: Int, node: UInt32, what: String, expected: [MeshtasticConfigField: UInt64]
    ) -> ConfigWriteSnapshot {
        let snapshot = ConfigWriteSnapshot(
            pending: pendingConfigWrites[variant], report: configReports.first { $0.variant == variant })
        var merged: [MeshtasticConfigField: UInt64] = [:]
        if let earlier = pendingConfigWrites[variant], earlier.node == node { merged = earlier.expected }
        for (field, value) in expected { merged[field] = value }
        nextWriteToken += 1
        pendingConfigWrites[variant] = PendingConfigWrite(
            token: nextWriteToken, node: node, variant: variant, expected: merged)
        setConfigReport(MeshtasticConfigReport(variant: variant, node: node, what: what, sent: merged, state: .sent))
        return snapshot
    }

    private func restoreConfigWrite(variant: Int, _ snapshot: ConfigWriteSnapshot) {
        pendingConfigWrites[variant] = snapshot.pending
        configReports.removeAll { $0.variant == variant }
        if let report = snapshot.report { setConfigReport(report) }
    }

    func setConfigReport(_ report: MeshtasticConfigReport) {
        var reports = configReports.filter { $0.variant != report.variant }
        reports.append(report)
        reports.sort { $0.variant < $1.variant }
        configReports = reports
    }

    private func setConfigReportState(
        variant: Int, _ state: MeshtasticConfigReport.State, ifCurrently only: MeshtasticConfigReport.State? = nil
    ) {
        guard var report = configReports.first(where: { $0.variant == variant }) else { return }
        if let only, report.state != only { return }
        guard report.state != state else { return }
        report.state = state
        setConfigReport(report)
    }

    /// For each field that was sent, the value the radio reports when it is not
    /// the one that was sent. Nil when the message cannot be read.
    static func differences(
        from expected: [MeshtasticConfigField: UInt64], in body: Data
    ) -> [MeshtasticConfigField: UInt64]? {
        var differing: [MeshtasticConfigField: UInt64] = [:]
        for (field, value) in expected {
            guard let reported = field.value(in: body) else { return nil }
            if reported != value { differing[field] = reported }
        }
        return differing
    }

    /// The radio's answer to the read after a config write, on time or late: what
    /// it holds right now. It settles a write that is still waiting for one.
    func settleConfigReadBack(variant: Int, body: Data, node: UInt32) {
        guard let pending = pendingConfigWrites[variant], pending.node == node,
              let report = configReports.first(where: { $0.variant == variant }) else { return }
        // Only a write still waiting for its answer. After the link was lost, or
        // once the radio has reported again after restarting, an answer is about
        // something else.
        switch report.state {
        case .sent, .noAnswer: break
        default: return
        }
        guard let reported = Self.differences(from: pending.expected, in: body) else { return }
        setConfigReportState(variant: variant, reported.isEmpty ? .confirmed : .radioKept(reported))
    }

    /// The radio reported a sub-config in its config download. When a write to it
    /// was sent before, this is the radio after it restarted, and the report says
    /// whether it kept what was sent.
    func settleConfigWriteAfterRestart(variant: Int, body: Data) {
        guard let pending = pendingConfigWrites[variant], pending.node == radioSettings.nodeNum,
              let reported = Self.differences(from: pending.expected, in: body) else { return }
        pendingConfigWrites[variant] = nil
        setConfigReportState(variant: variant, reported.isEmpty ? .appliedAfterRestart : .differsAfterRestart(reported))
    }

    /// A config download is starting. Another radio's writes cannot be checked
    /// against it, so what was sent to the one before goes. And what a radio
    /// reported after its restart was said for the session it was reported in: a
    /// new session starts without it.
    func dropConfigWrites(notFor node: UInt32) {
        for (variant, pending) in pendingConfigWrites where pending.node != node {
            pendingConfigWrites[variant] = nil
        }
        if configReports.contains(where: { $0.node != node || $0.state.isFinal }) {
            configReports.removeAll { $0.node != node || $0.state.isFinal }
        }
    }

    // MARK: - Channels

    /// What came of a request to put a channel on the radio.
    struct ChannelOutcome: Equatable {
        let result: MeshtasticWriteResult
        /// The slot written to, or nil when nothing was sent.
        let slot: Int?
        /// True when no radio was connected and the channel was saved in the
        /// app's list only.
        var savedOnly = false
    }

    /// What came of importing a set of channels.
    struct ImportOutcome: Equatable {
        /// The slots whose write the radio's own answer confirmed, in order.
        var confirmed: [Int] = []
        /// The slots written to whose confirmation did not come, or showed
        /// something else.
        var unconfirmed: [Int] = []
        /// Channels the radio reported it already has, under that name and key,
        /// when it was asked just now.
        var alreadyThere = 0
        /// Channels that have a write waiting for the radio's answer, and were not
        /// sent again.
        var waiting = 0
        /// Channels left out because every secondary slot is known to be in use.
        var noRoom = 0
        /// Channels left out because they cannot be written, and why.
        var skipped: [String] = []
        /// Channels not tried because the import stopped: the link was lost, the
        /// radio did not answer, or the slots were not known.
        var notTried = 0
        /// Channels kept in the saved list only, because no radio was connected.
        var savedOnly = 0
        /// Why nothing could be sent at all, or why the import stopped.
        var refusal: String?

        /// The slots written to.
        var sent: [Int] { confirmed + unconfirmed }
    }

    /// Create a channel from what the operator typed.
    ///
    /// - The name is at most 11 bytes: the radio drops the whole message for a
    ///   longer one.
    /// - The key is hex or base64 of a private key, or two hex digits for the
    ///   one-byte shorthand. Blank is not "no key": with `noEncryption` it is an
    ///   open channel, chosen on purpose (written as the one byte 0); when
    ///   replacing the primary it keeps the radio's key; for a new channel it is
    ///   refused. Something that is not a key is refused, never turned into none.
    /// - A new channel goes into the first slot the radio reports as disabled,
    ///   after reading that slot again, and inherits nothing from the slot's old
    ///   occupant. The primary is only written when `replacePrimary` is set, which
    ///   is the operator's explicit choice, and only if the radio says slot 0 is
    ///   the primary; then only its name and, if one was typed, its key change.
    /// - With no radio connected, a new channel is saved in the app's list only,
    ///   and the outcome says so.
    func createChannel(
        name rawName: String,
        keyText: String,
        noEncryption: Bool,
        replacePrimary: Bool
    ) async -> ChannelOutcome {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if let problem = Self.channelNameProblem(name) { return refusedChannel(problem) }

        let key: MeshtasticAdminCodec.KeyChange
        switch MeshtasticChannelKey.parse(keyText) {
        case .invalid(let reason):
            return refusedChannel(reason)
        case .key(let bytes):
            if noEncryption { return refusedChannel("Enter a key or choose No encryption, not both.") }
            key = .set(bytes)
        case .blank:
            if noEncryption {
                key = .clear
            } else if replacePrimary {
                key = .keep
            } else {
                return refusedChannel("Enter a key (hex or base64), or choose No encryption for an open channel.")
            }
        }

        // No radio: a new channel is kept for sharing, and says it is not on one.
        if activeLink == nil || !isConnected {
            if replacePrimary { return refusedChannel("Connect a radio to replace its primary channel.") }
            return saveChannelOnly(name: name, key: key)
        }

        return await serialized {
            let route: Route
            switch self.route() {
            case .stop(let reason): return refusedChannel(reason)
            case .go(let found): route = found
            }
            if replacePrimary {
                return await replacePrimaryChannel(route: route, name: name, key: key)
            }
            return await createNewChannel(route: route, name: name, key: key)
        }
    }

    /// The key a write puts on the channel, when it is known without asking the
    /// radio.
    private func keyBytes(_ key: MeshtasticAdminCodec.KeyChange) -> Data? {
        switch key {
        case .set(let bytes): return bytes
        case .clear: return MeshtasticChannelKey.open
        case .keep: return nil
        }
    }

    /// Whether what the radio reports for a slot is this channel: in use, with the
    /// name the radio keeps for it and this key.
    static func holds(_ summary: MeshtasticAdminCodec.ChannelSummary, name: String, key: Data) -> Bool {
        !summary.isDisabled && summary.name == MeshtasticAdminCodec.storedName(name) && summary.psk == key
    }

    private func replacePrimaryChannel(
        route: Route, name: String, key: MeshtasticAdminCodec.KeyChange
    ) async -> ChannelOutcome {
        let fresh: Data
        switch await read(.channel(index: 0), route: route) {
        case .answer(let bytes): fresh = bytes
        case .noAnswer: return refusedChannel(MeshtasticWriteResult.noAnswer)
        case .linkLost: return refusedChannel(MeshtasticWriteResult.linkChanged)
        }
        guard let summary = MeshtasticAdminCodec.channelSummary(in: fresh) else {
            return refusedChannel(MeshtasticWriteResult.unreadable)
        }
        // The primary is only replaced if the radio says slot 0 is the primary.
        // Forcing the role on any other slot would leave the radio with two.
        guard summary.role == MeshtasticAdminCodec.ChannelRole.primary.rawValue else {
            return refusedChannel(
                "Slot 0 is not this radio's primary channel, so nothing was changed. "
                + "Use Re-read from radio to see how its channels are set up.")
        }
        guard let write = MeshtasticAdminCodec.encodeSetChannel(
            current: fresh, name: name, key: key, role: .primary) else {
            return refusedChannel(MeshtasticWriteResult.unreadable)
        }
        guard !write.changesNothing else {
            return ChannelOutcome(result: .unchanged, slot: 0)
        }
        let expected = MeshtasticAdminCodec.ChannelSummary(
            index: 0, name: name, psk: keyBytes(key) ?? summary.psk,
            role: MeshtasticAdminCodec.ChannelRole.primary.rawValue)
        let saved = keyBytes(key).map {
            StoredChannel(index: 0, name: name, pskHex: MeshCoreChannelCodec.hex($0), isPrimary: true,
                          nodeNum: route.node, state: .sent)
        }
        return await finishChannelWrite(route: route, slot: 0, write: write, expected: expected, saved: saved)
    }

    private func createNewChannel(
        route: Route, name: String, key: MeshtasticAdminCodec.KeyChange
    ) async -> ChannelOutcome {
        guard let psk = keyBytes(key) else { return refusedChannel(MeshtasticWriteResult.unreadable) }

        // The same channel is not put on the radio twice, whether the radio
        // says it has it or a write for it is still waiting for its answer.
        if let holder = slotHolding(name: name, key: psk) {
            if !holder.confirmed {
                return refusedChannel(
                    "A channel \"\(name)\" with that key was already sent to slot \(holder.slot) and the radio has not "
                    + "confirmed it. Use Re-read from radio to see whether it is there.")
            }
            // What this app holds says the radio has it. The radio is asked before
            // the app says so.
            switch await read(.channel(index: holder.slot), route: route) {
            case .answer(let bytes):
                if let summary = MeshtasticAdminCodec.channelSummary(in: bytes),
                   Self.holds(summary, name: name, key: psk) {
                    return ChannelOutcome(result: .unchanged, slot: holder.slot)
                }
            case .noAnswer: return refusedChannel(MeshtasticWriteResult.noAnswer)
            case .linkLost: return refusedChannel(MeshtasticWriteResult.linkChanged)
            }
        }

        var stale = Set<Int>()
        while true {
            guard let slot = candidateFreeSlots(excluding: stale).first else {
                return refusedChannel(noFreeSlotReason())
            }
            // The slot is asked about again: it may have been taken since.
            let fresh: Data
            switch await read(.channel(index: slot), route: route) {
            case .answer(let bytes): fresh = bytes
            case .noAnswer: return refusedChannel(MeshtasticWriteResult.noAnswer)
            case .linkLost: return refusedChannel(MeshtasticWriteResult.linkChanged)
            }
            guard let summary = MeshtasticAdminCodec.channelSummary(in: fresh) else {
                return refusedChannel(MeshtasticWriteResult.unreadable)
            }
            if !summary.isDisabled || summary.index != slot {
                // Taken since. If what took it is this very channel, it is there.
                if summary.index == slot, Self.holds(summary, name: name, key: psk) {
                    return ChannelOutcome(result: .unchanged, slot: slot)
                }
                stale.insert(slot)
                continue
            }
            guard let write = MeshtasticAdminCodec.encodeNewChannel(index: slot, current: fresh, name: name, psk: psk) else {
                return refusedChannel(MeshtasticWriteResult.unreadable)
            }
            let expected = MeshtasticAdminCodec.ChannelSummary(
                index: slot, name: name, psk: psk, role: MeshtasticAdminCodec.ChannelRole.secondary.rawValue)
            let saved = StoredChannel(index: slot, name: name, pskHex: MeshCoreChannelCodec.hex(psk), isPrimary: false,
                                      nodeNum: route.node, state: .sent)
            return await finishChannelWrite(route: route, slot: slot, write: write, expected: expected, saved: saved)
        }
    }

    /// The secondary slots nothing is known about, or that have a write waiting
    /// for its answer. They may be in use, so they are neither free nor known to
    /// be in use.
    func unknownSlots() -> [Int] {
        (1...7).filter { radioSettings.channelSummary(index: $0) == nil || pendingChannelWrites[$0] != nil }
    }

    /// What is said when no slot can be chosen because some are not known.
    static func slotsNotKnownReason(_ unknown: [Int]) -> String {
        "Some of this radio's channel slots are not known yet (slots \(unknown.map(String.init).joined(separator: ", "))). "
            + "A write may be waiting for the radio to confirm it. Use Re-read from radio and try again."
    }

    /// Why no slot can be chosen: all are in use, or some are not known.
    private func noFreeSlotReason() -> String {
        let unknown = unknownSlots()
        if unknown.isEmpty {
            return "No free channel slot. All seven secondary slots on this radio are in use."
        }
        return Self.slotsNotKnownReason(unknown)
    }

    /// Save a new channel in the app's list only, because no radio is connected.
    private func saveChannelOnly(name: String, key: MeshtasticAdminCodec.KeyChange) -> ChannelOutcome {
        guard let psk = keyBytes(key) else { return refusedChannel(MeshtasticWriteResult.notConnected) }
        upsertAppChannel(StoredChannel(
            index: -1, name: name, pskHex: MeshCoreChannelCodec.hex(psk), isPrimary: false,
            nodeNum: nil, state: .savedOnly))
        return ChannelOutcome(result: .refused(MeshtasticWriteResult.notConnected), slot: nil, savedOnly: true)
    }

    /// The set_channel is sent, and then the slot is read to see what the radio
    /// holds.
    private func finishChannelWrite(
        route: Route,
        slot: Int,
        write: MeshtasticAdminCodec.Write,
        expected: MeshtasticAdminCodec.ChannelSummary,
        saved: StoredChannel?
    ) async -> ChannelOutcome {
        switch await writeChannel(route: route, slot: slot, write: write, expected: expected, saved: saved) {
        case .applied:
            return ChannelOutcome(result: .applied, slot: slot)
        case .radioKept(let held):
            let value = held.isEmpty ? "" : " (\"\(held)\")"
            return ChannelOutcome(result: .notConfirmed("The radio kept its own value\(value)."), slot: slot)
        case .unconfirmed:
            return ChannelOutcome(
                result: .notConfirmed("The radio did not confirm. If it answers later, the line under Channel writes changes."),
                slot: slot)
        case .linkLost:
            return ChannelOutcome(
                result: .notConfirmed("The link was lost before the radio confirmed. The line under Channel writes changes "
                                      + "when the radio reports the slot again, after it connects or on Re-read from radio."),
                slot: slot)
        case .notSent:
            return refusedChannel(MeshtasticWriteResult.linkChanged)
        }
    }

    enum SlotWriteResult: Equatable {
        case applied
        case radioKept(String)
        case unconfirmed
        /// The link was lost after the write went, and the read-back could not be asked.
        case linkLost
        case notSent
    }

    /// Send a channel write and read the slot back. The slot is not known from
    /// the moment the write goes until the radio answers, and a write that did not
    /// settle keeps counting as in use.
    ///
    /// The saved list is not touched for a slot that already has an entry until
    /// the radio has confirmed the new channel: a write the radio refuses, or that
    /// cannot be sent, must not cost the entry, and its key, for the channel the
    /// radio still holds. A new entry is put in at once, so that its key is not
    /// lost with the link, and taken out again if nothing was sent.
    private func writeChannel(
        route: Route,
        slot: Int,
        write: MeshtasticAdminCodec.Write,
        expected: MeshtasticAdminCodec.ChannelSummary,
        saved: StoredChannel?
    ) async -> SlotWriteResult {
        // The link may have been lost since the slot was read. Nothing is marked
        // or sent for a connection that is gone.
        guard routeIsCurrent(route) else { return .notSent }
        let before = radioSettings.channel(index: slot)
        radioSettings.invalidateChannel(index: slot)
        nextWriteToken += 1
        let hadEntry = appChannels.contains { $0.nodeNum == route.node && $0.index == slot }
        let insert = saved != nil && !hadEntry
        pendingChannelWrites[slot] = PendingChannelWrite(
            token: nextWriteToken, name: expected.name, expected: expected, node: route.node,
            saved: saved, entryInserted: insert)
        setChannelReport(slot: slot, name: expected.name, state: .sent)
        if insert, let saved { upsertAppChannel(saved) }

        guard await sendFrame(write.payload, wantResponse: false, packetID: freshPacketID(), route: route) else {
            // Nothing went. Put back what the radio said, if this is still the
            // connection it said it on.
            pendingChannelWrites[slot] = nil
            channelReports.removeAll { $0.slot == slot }
            if routeIsCurrent(route), let before { radioSettings.storeChannel(index: slot, body: before) }
            if insert, let saved { removeAppChannel(saved) }
            return .notSent
        }

        switch await read(.channel(index: slot), route: route) {
        case .answer(let bytes):
            // acceptAnswer has stored it and settled the report.
            switch Self.verdict(of: bytes, expected: expected) {
            case .applied: return .applied
            case .radioKept(let held): return .radioKept(held)
            }
        case .noAnswer:
            if activeLink == route.active, let pending = pendingChannelWrites[slot] {
                setChannelReport(slot: slot, name: pending.name, state: .noAnswer)
                if pending.entryInserted { noteSavedChannel(node: route.node, slot: slot, state: .notConfirmed) }
            }
            return .unconfirmed
        case .linkLost:
            // abandonRequests says so when the link drops. When this is reached
            // first, it is said now, unless the connection was given up on.
            if activeLink == route.active, let pending = pendingChannelWrites[slot] {
                setChannelReport(slot: slot, name: pending.name, state: .linkLost)
                if pending.entryInserted { noteSavedChannel(node: route.node, slot: slot, state: .notConfirmed) }
            }
            return .linkLost
        }
    }

    enum ChannelVerdict: Equatable {
        case applied
        case radioKept(String)
    }

    /// Whether the radio's answer is the channel that was asked for: the name as
    /// the radio keeps it, the key and the role.
    static func verdict(of answer: Data, expected: MeshtasticAdminCodec.ChannelSummary) -> ChannelVerdict {
        guard let held = MeshtasticAdminCodec.channelSummary(in: answer) else { return .radioKept("") }
        let matches = held.name == MeshtasticAdminCodec.storedName(expected.name)
            && held.psk == expected.psk && held.role == expected.role
        return matches ? .applied : .radioKept(held.name)
    }

    /// An answer for a slot that has a write waiting for it. It settles the
    /// write, whenever it comes: the row says what the radio reports. The entry
    /// for the saved list goes in, replacing the one that was there, only when the
    /// radio confirms it.
    func settlePendingChannelWrite(slot: Int, answer: Data) {
        guard let pending = pendingChannelWrites[slot] else { return }
        pendingChannelWrites[slot] = nil
        switch Self.verdict(of: answer, expected: pending.expected) {
        case .applied:
            setChannelReport(slot: slot, name: pending.name, state: .applied)
            if var saved = pending.saved {
                saved.state = .onRadio
                upsertAppChannel(saved)
            }
        case .radioKept(let held):
            setChannelReport(slot: slot, name: pending.name, state: .radioKept(held))
            if pending.entryInserted { noteSavedChannel(node: pending.node, slot: slot, state: .radioKept) }
        }
    }

    /// Set the state of the saved entry for a slot of a radio, if there is one.
    func noteSavedChannel(node: UInt32, slot: Int, state: SavedChannelState) {
        var list = appChannels
        guard let i = list.firstIndex(where: { $0.nodeNum == node && $0.index == slot }) else { return }
        guard list[i].state != state else { return }
        list[i].state = state
        appChannels = list
    }

    private func refusedChannel(_ reason: String) -> ChannelOutcome {
        ChannelOutcome(result: .refused(reason), slot: nil)
    }

    // MARK: - Importing channels

    /// Apply an imported Meshtastic channel-set (from a scanned QR / pasted
    /// link) to the radio.
    ///
    /// Each channel goes into a slot the radio reports as disabled, in order,
    /// after that slot is read again, and inherits nothing from the slot's old
    /// occupant. The primary is never touched, and no slot in use is
    /// overwritten. A channel the radio reports it already has under that name
    /// and key (it is asked just now, not taken from what was downloaded) is not
    /// added again, nor is one that has a write waiting for its answer. When
    /// there are more channels than free slots the rest are left out and counted,
    /// and when the slots are not known, or the link is lost, or the radio does
    /// not answer, the rest are counted as not tried.
    ///
    /// Each channel is a set_channel of its own, paced, and the radio saves it as
    /// it takes it. There is no edit transaction (see the top of this file). What
    /// is reported is what the radio's own answers confirmed.
    ///
    /// With no radio connected the channels are kept in the saved list, as a
    /// create is, and the outcome says they are not on a radio.
    func importChannels(_ channels: [MeshChannel]) async -> ImportOutcome {
        if activeLink == nil || !isConnected {
            return saveImportedChannelsOnly(channels)
        }
        return await serialized {
            var outcome = ImportOutcome()
            let route: Route
            switch self.route() {
            case .stop(let reason):
                outcome.refusal = reason
                return outcome
            case .go(let found):
                route = found
            }

            // Which channels can be written at all.
            var planned: [(name: String, psk: Data)] = []
            planning: for (index, channel) in channels.enumerated() {
                if let problem = Self.channelNameProblem(channel.name) {
                    outcome.skipped.append(problem)
                    continue
                }
                guard MeshtasticChannelKey.isUsable(channel.psk) else {
                    outcome.skipped.append(Self.unusableKeyReason(name: channel.name, psk: channel.psk))
                    continue
                }
                if planned.contains(where: { $0.name == channel.name && $0.psk == channel.psk }) {
                    outcome.skipped.append("\"\(channel.name)\" is in the link more than once. It is added once.")
                    continue
                }
                if let holder = slotHolding(name: channel.name, key: channel.psk) {
                    if !holder.confirmed {
                        outcome.waiting += 1
                        continue
                    }
                    // What this app holds says the radio has it. The radio is
                    // asked before the app says so.
                    switch await read(.channel(index: holder.slot), route: route) {
                    case .answer(let bytes):
                        if let summary = MeshtasticAdminCodec.channelSummary(in: bytes),
                           Self.holds(summary, name: channel.name, key: channel.psk) {
                            outcome.alreadyThere += 1
                            continue
                        }
                    case .noAnswer:
                        outcome.refusal = MeshtasticWriteResult.noAnswer
                        outcome.notTried += planned.count + (channels.count - index)
                        break planning
                    case .linkLost:
                        outcome.refusal = MeshtasticWriteResult.linkChanged
                        outcome.notTried += planned.count + (channels.count - index)
                        break planning
                    }
                }
                planned.append((channel.name, channel.psk))
            }
            guard outcome.refusal == nil, !planned.isEmpty else { return outcome }

            var stale = Set<Int>()
            placing: for (position, item) in planned.enumerated() {
                // The channels from this one on, if the import stops here.
                let remaining = planned.count - position
                guard routeIsCurrent(route) else {
                    outcome.refusal = MeshtasticWriteResult.linkChanged
                    outcome.notTried += remaining
                    break placing
                }
                // Find a slot that is free now.
                var slotToWrite: (slot: Int, current: Data)?
                while slotToWrite == nil {
                    guard let slot = candidateFreeSlots(excluding: stale).first else {
                        let unknown = unknownSlots()
                        if unknown.isEmpty {
                            outcome.noRoom += 1
                            continue placing
                        }
                        // Slots nothing is known about are not slots in use.
                        outcome.refusal = Self.slotsNotKnownReason(unknown)
                        outcome.notTried += remaining
                        break placing
                    }
                    switch await read(.channel(index: slot), route: route) {
                    case .answer(let bytes):
                        if let summary = MeshtasticAdminCodec.channelSummary(in: bytes), summary.index == slot {
                            if summary.isDisabled {
                                slotToWrite = (slot, bytes)
                            } else if Self.holds(summary, name: item.name, key: item.psk) {
                                // Put there since the download: it is there.
                                outcome.alreadyThere += 1
                                continue placing
                            } else {
                                stale.insert(slot)
                            }
                        } else {
                            stale.insert(slot)
                        }
                    case .noAnswer:
                        outcome.refusal = MeshtasticWriteResult.noAnswer
                        outcome.notTried += remaining
                        break placing
                    case .linkLost:
                        outcome.refusal = MeshtasticWriteResult.linkChanged
                        outcome.notTried += remaining
                        break placing
                    }
                }
                guard let target = slotToWrite else { break }
                guard let write = MeshtasticAdminCodec.encodeNewChannel(
                    index: target.slot, current: target.current, name: item.name, psk: item.psk) else {
                    outcome.skipped.append("\"\(item.name)\": slot \(target.slot) is not in a state this app can write to.")
                    stale.insert(target.slot)
                    continue
                }
                let expected = MeshtasticAdminCodec.ChannelSummary(
                    index: target.slot, name: item.name, psk: item.psk,
                    role: MeshtasticAdminCodec.ChannelRole.secondary.rawValue)
                let saved = StoredChannel(
                    index: target.slot, name: item.name, pskHex: MeshCoreChannelCodec.hex(item.psk), isPrimary: false,
                    nodeNum: route.node, state: .sent)
                switch await writeChannel(route: route, slot: target.slot, write: write, expected: expected, saved: saved) {
                case .applied:
                    outcome.confirmed.append(target.slot)
                case .radioKept, .unconfirmed:
                    outcome.unconfirmed.append(target.slot)
                case .linkLost:
                    // The write went and the link was lost before it was read back.
                    outcome.unconfirmed.append(target.slot)
                    outcome.refusal = MeshtasticWriteResult.linkChanged
                    outcome.notTried += remaining - 1
                    break placing
                case .notSent:
                    outcome.refusal = MeshtasticWriteResult.linkChanged
                    outcome.notTried += remaining
                    break placing
                }
            }
            return outcome
        }
    }

    /// With no radio connected: keep what the link carries in the saved list, for
    /// sharing, and say it is not on a radio.
    private func saveImportedChannelsOnly(_ channels: [MeshChannel]) -> ImportOutcome {
        var outcome = ImportOutcome()
        for channel in channels {
            if let problem = Self.channelNameProblem(channel.name) {
                outcome.skipped.append(problem)
                continue
            }
            guard MeshtasticChannelKey.isUsable(channel.psk) else {
                outcome.skipped.append(Self.unusableKeyReason(name: channel.name, psk: channel.psk))
                continue
            }
            upsertAppChannel(StoredChannel(
                index: -1, name: channel.name, pskHex: MeshCoreChannelCodec.hex(channel.psk), isPrimary: false,
                nodeNum: nil, state: .savedOnly))
            outcome.savedOnly += 1
        }
        return outcome
    }

    /// The reason a channel's key is not one the radio would take.
    static func unusableKeyReason(name: String, psk: Data) -> String {
        if psk.isEmpty {
            return "\"\(name)\" has no key. A channel with no key uses this radio's primary key, so it was left out."
        }
        return "\"\(name)\" has a key of \(psk.count) bytes. A key is 16 or 32 bytes, or one byte 0 to 10."
    }

    /// The reason a channel name cannot be written, or nil. The radio drops the
    /// whole message for a name over 11 bytes, so it is refused here, and the
    /// operator is told why.
    static func channelNameProblem(_ name: String) -> String? {
        let bytes = name.utf8.count
        guard bytes > MeshtasticAdminCodec.maxChannelNameBytes else { return nil }
        return "Channel names are at most \(MeshtasticAdminCodec.maxChannelNameBytes) bytes. "
            + "\"\(name)\" is \(bytes). The radio would drop the whole message."
    }

    // MARK: - Which slots are free

    /// The secondary slots that can take a new channel: reported as disabled, and
    /// with no write waiting for its answer. A slot nothing is known about is not
    /// free: it may be in use, or a write to it may be on its way.
    func candidateFreeSlots(excluding: Set<Int> = []) -> [Int] {
        radioSettings.freeChannelSlots.filter { pendingChannelWrites[$0] == nil && !excluding.contains($0) }
    }

    /// The slot that holds, or has a write waiting for, a channel with this name
    /// and key. `confirmed` is false for a write that has not been answered.
    func slotHolding(name: String, key: Data) -> (slot: Int, confirmed: Bool)? {
        if let slot = radioSettings.slotHolding(name: name, key: key) {
            return (slot, true)
        }
        for (slot, pending) in pendingChannelWrites.sorted(by: { $0.key < $1.key })
        where pending.expected.name == name && pending.expected.psk == key {
            return (slot, false)
        }
        return nil
    }

    // MARK: - Reading everything again

    /// What came of asking the radio for everything again.
    struct RereadOutcome: Equatable {
        var answered = 0
        /// What did not answer. Asking stops there: another request to a radio
        /// that is not answering would wait as long again.
        var missing: [String] = []
        /// What was not asked because of that.
        var notAsked: [String] = []
        var refusal: String?
    }

    /// Ask the radio for its device config, position config and all eight
    /// channels again. What it says replaces what the app holds, and settles a
    /// channel write that was waiting for its answer. It stops at the first thing
    /// the radio does not answer.
    func rereadFromRadio() async -> RereadOutcome {
        await serialized {
            var outcome = RereadOutcome()
            let route: Route
            switch self.route() {
            case .stop(let reason):
                outcome.refusal = reason
                return outcome
            case .go(let found):
                route = found
            }
            var subjects: [(String, MeshtasticAdminSubject)] = [
                ("device config", .config(variant: MeshtasticAdminCodec.ConfigVariant.device)),
                ("position config", .config(variant: MeshtasticAdminCodec.ConfigVariant.position)),
            ]
            for index in MeshtasticRadioSettings.channelSlots { subjects.append(("channel \(index)", .channel(index: index))) }
            for (position, entry) in subjects.enumerated() {
                switch await read(entry.1, route: route) {
                case .answer:
                    outcome.answered += 1
                case .noAnswer:
                    outcome.missing.append(entry.0)
                    outcome.notAsked = subjects.dropFirst(position + 1).map { $0.0 }
                    return outcome
                case .linkLost:
                    outcome.refusal = MeshtasticWriteResult.linkChanged
                    return outcome
                }
            }
            return outcome
        }
    }

    // MARK: - The saved list, against what the radio says now

    /// Where a saved channel stands, as far as the connected radio can tell. An
    /// entry written to the radio that is connected, whose slot the radio has
    /// reported, is checked against what the radio says: the name, the key and
    /// that the slot is in use. Anything else is the state it was left in.
    func standing(of channel: StoredChannel) -> (label: String, onRadio: Bool) {
        let saved = channel.effectiveState
        // Saved by an earlier version, which did not record the radio it was
        // written to. What the connected radio holds in that slot says.
        if channel.nodeNum == nil, channel.index >= 0 {
            guard radioSettings.nodeNum != nil else {
                return ("saved earlier, not checked against a radio", false)
            }
            if let held = radioSettings.channelSummary(index: channel.index),
               Self.holds(held, name: channel.name, key: MeshCoreChannelCodec.dehex(channel.pskHex) ?? Data()) {
                return (SavedChannelState.onRadio.label, true)
            }
            return ("saved earlier, not on the connected radio", false)
        }
        // Written to a radio that is not the one connected: what was last known
        // of it, and not a claim about this radio.
        if let node = channel.nodeNum, let connected = radioSettings.nodeNum, node != connected {
            return ("another radio: \(saved.label)", false)
        }
        guard channel.index >= 0, let node = channel.nodeNum, node == radioSettings.nodeNum else {
            return (saved.label, saved == .onRadio)
        }
        if let pending = pendingChannelWrites[channel.index], pending.node == node {
            // An entry this write put in says so. One that was there before is of
            // what the radio held, and a replacement for it has not been confirmed.
            return pending.entryInserted
                ? (saved.label, false)
                : ("a new channel for this slot is waiting for the radio to confirm", false)
        }
        guard let held = radioSettings.channelSummary(index: channel.index) else {
            return (saved.label, saved == .onRadio)
        }
        let key = MeshCoreChannelCodec.dehex(channel.pskHex) ?? Data()
        if held.isDisabled {
            return ("not on the radio now: slot \(channel.index) is empty", false)
        }
        if held.name != MeshtasticAdminCodec.storedName(channel.name) || held.psk != key {
            return ("not on the radio now: slot \(channel.index) holds another channel", false)
        }
        return (SavedChannelState.onRadio.label, true)
    }

    /// An entry that was saved with no radio, by an earlier version from a slot or
    /// for sharing (no slot at all), is on a radio when the connected radio holds
    /// exactly that channel, name and key. It then takes that radio and slot and
    /// says so. When this radio's slot already has an entry for the same channel
    /// (a write just made one), the entry that was saved with no radio is that
    /// channel's twin, and goes: the channel is listed once.
    func adoptSavedChannel(slot: Int) {
        guard let node = radioSettings.nodeNum,
              let held = radioSettings.channelSummary(index: slot), !held.isDisabled else { return }
        var list = appChannels
        var changed = false
        for i in list.indices.reversed() where list[i].nodeNum == nil && (list[i].index == slot || list[i].index < 0) {
            let entry = list[i]
            guard Self.holds(held, name: entry.name, key: MeshCoreChannelCodec.dehex(entry.pskHex) ?? Data()) else { continue }
            if let existing = list.firstIndex(where: { $0.nodeNum == node && $0.index == slot }) {
                if list[existing].name == entry.name && list[existing].pskHex == entry.pskHex {
                    list.remove(at: i)
                    changed = true
                }
                continue
            }
            list[i].nodeNum = node
            list[i].index = slot
            list[i].isPrimary = slot == 0
            list[i].state = .onRadio
            changed = true
        }
        if changed {
            list.sort { ($0.nodeNum ?? 0, $0.index) < ($1.nodeNum ?? 0, $1.index) }
            appChannels = list
        }
    }

    // MARK: - Reports

    func setChannelReport(slot: Int, name: String, state: MeshtasticChannelReport.State) {
        var reports = channelReports.filter { $0.slot != slot }
        reports.append(MeshtasticChannelReport(slot: slot, name: name, state: state))
        reports.sort { $0.slot < $1.slot }
        channelReports = reports
    }
}
