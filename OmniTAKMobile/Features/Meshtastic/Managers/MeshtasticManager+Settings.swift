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
//  Frames are at least `frameSpacing` apart on the link, and an operation that
//  sets more than one thing wraps its writes in begin_edit_settings and
//  commit_edit_settings. The radio holds the packets addressed to itself in a
//  queue of four and drops the oldest when a fifth arrives, so a burst loses the
//  earliest writes. A commit makes the radio restart.
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
    /// replaced. The requests on the table will not be answered. Writes that were
    /// awaiting their read-back are left unconfirmed (shown, when the link only
    /// dropped) or forgotten (when another radio was chosen).
    func abandonRequests(markPendingWrites: Bool) {
        let requests = Array(outstandingRequests.values)
        outstandingRequests.removeAll()
        latestRequestID.removeAll()
        lastFrameTime = nil
        for request in requests {
            request.waiter?.fulfil(.linkLost)
            request.waiter = nil
        }
        if markPendingWrites {
            for (slot, pending) in pendingChannelWrites {
                setChannelReport(slot: slot, name: pending.name, state: .noAnswer)
                noteSavedChannel(node: pending.node, slot: slot, state: .notConfirmed)
            }
        }
        pendingChannelWrites.removeAll()
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
            bytes = body
        case .channel(let index, let body):
            radioSettings.storeChannel(index: index, body: body)
            settlePendingChannelWrite(slot: index, answer: body)
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
    /// so the position config is read again afterwards.
    func applyDeviceConfig(
        role: MeshtasticAdminCodec.DeviceRole?,
        rebroadcastMode: MeshtasticAdminCodec.RebroadcastMode?
    ) async -> MeshtasticWriteResult {
        let result = await writeConfig(
            variant: MeshtasticAdminCodec.ConfigVariant.device,
            build: { MeshtasticAdminCodec.encodeSetDeviceConfig(current: $0, role: role, rebroadcastMode: rebroadcastMode) },
            confirms: { answer in
                (role == nil || MeshtasticAdminCodec.deviceRole(in: answer) == role?.rawValue)
                    && (rebroadcastMode == nil || MeshtasticAdminCodec.rebroadcastMode(in: answer) == rebroadcastMode?.rawValue)
            })
        return result
    }

    /// Apply the position broadcast interval via AdminMessage.set_config, the
    /// same way: read, change the one field, send, read again. The rest of the
    /// position config (GPS mode, position flags, smart broadcast) stays as the
    /// radio has it. When the radio already has this interval, nothing is sent.
    func applyPositionBroadcastInterval(seconds: UInt32) async -> MeshtasticWriteResult {
        await writeConfig(
            variant: MeshtasticAdminCodec.ConfigVariant.position,
            build: { MeshtasticAdminCodec.encodeSetPositionBroadcastInterval(current: $0, seconds: seconds) },
            confirms: { MeshtasticAdminCodec.positionBroadcastSeconds(in: $0) == seconds })
    }

    private func writeConfig(
        variant: Int,
        build: @escaping (Data) -> MeshtasticAdminCodec.Write?,
        confirms: @escaping (Data) -> Bool
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

            // From here on what the radio holds is not known until it says.
            radioSettings.invalidateConfig(variant: variant)
            guard await sendFrame(write.payload, wantResponse: false, packetID: freshPacketID(), route: route) else {
                radioSettings.storeConfig(variant: variant, body: fresh)
                return .refused(MeshtasticWriteResult.linkChanged)
            }

            // What the radio holds now, and what the operator is told.
            let result: MeshtasticWriteResult
            switch await read(.config(variant: variant), route: route) {
            case .answer(let bytes):
                result = confirms(bytes) ? .applied : .notConfirmed("The radio kept its own value.")
            case .noAnswer:
                result = .notConfirmed("The radio did not confirm. The change may not have been applied.")
            case .linkLost:
                result = .notConfirmed("The radio link changed before the radio confirmed.")
            }

            // A role change rewrites the position config on the radio.
            if variant == MeshtasticAdminCodec.ConfigVariant.device, routeIsCurrent(route) {
                _ = await read(.config(variant: MeshtasticAdminCodec.ConfigVariant.position), route: route)
            }
            return result
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
        /// Channels the radio already has under that name and key.
        var alreadyThere = 0
        /// Channels left out because the radio has no free slot for them.
        var noRoom = 0
        /// Channels left out because they cannot be written, and why.
        var skipped: [String] = []
        /// Why nothing could be sent at all, or why the import stopped.
        var refusal: String?
        /// True when the writes were saved with a commit, which restarts the
        /// radio.
        var restarts = false

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
            if holder.confirmed {
                return ChannelOutcome(result: .unchanged, slot: holder.slot)
            }
            return refusedChannel(
                "A channel \"\(name)\" with that key was already sent to slot \(holder.slot) and the radio has not "
                + "confirmed it. Use Re-read from radio to see whether it is there.")
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

    /// Why no slot can be chosen: all are in use, or some are not known.
    private func noFreeSlotReason() -> String {
        let unknown = (1...7).filter { radioSettings.channelSummary(index: $0) == nil || pendingChannelWrites[$0] != nil }
        if unknown.isEmpty {
            return "No free channel slot. All seven secondary slots on this radio are in use."
        }
        return "Some of this radio's channel slots are not known yet (slots \(unknown.map(String.init).joined(separator: ", "))). "
            + "A write may be waiting for the radio to confirm it. Use Re-read from radio and try again."
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
        case .notSent:
            return refusedChannel(MeshtasticWriteResult.linkChanged)
        }
    }

    enum SlotWriteResult: Equatable {
        case applied
        case radioKept(String)
        case unconfirmed
        case notSent
    }

    /// Send a channel write and read the slot back. The slot is not known from
    /// the moment the write goes until the radio answers, and a write that did not
    /// settle keeps counting as in use.
    private func writeChannel(
        route: Route,
        slot: Int,
        write: MeshtasticAdminCodec.Write,
        expected: MeshtasticAdminCodec.ChannelSummary,
        saved: StoredChannel?
    ) async -> SlotWriteResult {
        let before = radioSettings.channel(index: slot)
        radioSettings.invalidateChannel(index: slot)
        nextWriteToken += 1
        pendingChannelWrites[slot] = PendingChannelWrite(
            token: nextWriteToken, name: expected.name, expected: expected, node: route.node)
        setChannelReport(slot: slot, name: expected.name, state: .sent)
        if let saved { upsertAppChannel(saved) }

        guard await sendFrame(write.payload, wantResponse: false, packetID: freshPacketID(), route: route) else {
            // Nothing went. Put back what the radio said.
            pendingChannelWrites[slot] = nil
            channelReports.removeAll { $0.slot == slot }
            if let before { radioSettings.storeChannel(index: slot, body: before) }
            if let saved { removeAppChannel(saved) }
            return .notSent
        }

        switch await read(.channel(index: slot), route: route) {
        case .answer(let bytes):
            // acceptAnswer has stored it and settled the report.
            switch Self.verdict(of: bytes, expected: expected) {
            case .applied: return .applied
            case .radioKept(let held): return .radioKept(held)
            }
        case .noAnswer, .linkLost:
            if activeLink == route.active, let pending = pendingChannelWrites[slot] {
                setChannelReport(slot: slot, name: pending.name, state: .noAnswer)
                noteSavedChannel(node: route.node, slot: slot, state: .notConfirmed)
            }
            return .unconfirmed
        }
    }

    enum ChannelVerdict: Equatable {
        case applied
        case radioKept(String)
    }

    /// Whether the radio's answer is the channel that was asked for: the name,
    /// the key and the role.
    static func verdict(of answer: Data, expected: MeshtasticAdminCodec.ChannelSummary) -> ChannelVerdict {
        guard let held = MeshtasticAdminCodec.channelSummary(in: answer) else { return .radioKept("") }
        let matches = held.name == expected.name && held.psk == expected.psk && held.role == expected.role
        return matches ? .applied : .radioKept(held.name)
    }

    /// An answer for a slot that has a write waiting for it. It settles the
    /// write, whenever it comes: the row says what the radio reports.
    func settlePendingChannelWrite(slot: Int, answer: Data) {
        guard let pending = pendingChannelWrites[slot] else { return }
        pendingChannelWrites[slot] = nil
        switch Self.verdict(of: answer, expected: pending.expected) {
        case .applied:
            setChannelReport(slot: slot, name: pending.name, state: .applied)
            noteSavedChannel(node: pending.node, slot: slot, state: .onRadio)
        case .radioKept(let held):
            setChannelReport(slot: slot, name: pending.name, state: .radioKept(held))
            noteSavedChannel(node: pending.node, slot: slot, state: .radioKept)
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
    /// overwritten. A channel the radio already has under that name and key, or
    /// has a write waiting for, is not added again. When there are more channels
    /// than free slots the rest are left out and counted. When more than one
    /// channel is written the writes are wrapped in begin_edit_settings and
    /// commit_edit_settings, which makes the radio restart. What is reported is
    /// what the radio's own answers confirmed.
    func importChannels(_ channels: [MeshChannel]) async -> ImportOutcome {
        await serialized {
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
            for channel in channels {
                if let problem = Self.channelNameProblem(channel.name) {
                    outcome.skipped.append(problem)
                    continue
                }
                guard MeshtasticChannelKey.isUsable(channel.psk) else {
                    outcome.skipped.append(Self.unusableKeyReason(name: channel.name, psk: channel.psk))
                    continue
                }
                if slotHolding(name: channel.name, key: channel.psk) != nil
                    || planned.contains(where: { $0.name == channel.name && $0.psk == channel.psk }) {
                    outcome.alreadyThere += 1
                    continue
                }
                planned.append((channel.name, channel.psk))
            }
            guard !planned.isEmpty else { return outcome }

            // More than one write is one edit: the radio saves once, at the end.
            let edit = planned.count > 1
            if edit {
                let began = await sendFrame(
                    MeshtasticAdminCodec.encodeBeginEditSettings(),
                    wantResponse: false, packetID: freshPacketID(), route: route)
                guard began else {
                    outcome.refusal = MeshtasticWriteResult.linkChanged
                    return outcome
                }
            }

            var stale = Set<Int>()
            placing: for item in planned {
                // Find a slot that is free now.
                var slotToWrite: (slot: Int, current: Data)?
                while slotToWrite == nil {
                    guard let slot = candidateFreeSlots(excluding: stale).first else {
                        outcome.noRoom += 1
                        continue placing
                    }
                    switch await read(.channel(index: slot), route: route) {
                    case .answer(let bytes):
                        if let summary = MeshtasticAdminCodec.channelSummary(in: bytes),
                           summary.isDisabled, summary.index == slot {
                            slotToWrite = (slot, bytes)
                        } else {
                            stale.insert(slot)
                        }
                    case .noAnswer:
                        outcome.refusal = MeshtasticWriteResult.noAnswer
                        break placing
                    case .linkLost:
                        outcome.refusal = MeshtasticWriteResult.linkChanged
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
                case .notSent:
                    outcome.refusal = MeshtasticWriteResult.linkChanged
                    break placing
                }
            }

            // Whatever happened, an edit that was begun is committed: the radio
            // holds off saving until it is.
            if edit, routeIsCurrent(route) {
                let committed = await sendFrame(
                    MeshtasticAdminCodec.encodeCommitEditSettings(),
                    wantResponse: false, packetID: freshPacketID(), route: route)
                outcome.restarts = committed
            }
            return outcome
        }
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
        var missing: [String] = []
        var refusal: String?
    }

    /// Ask the radio for its device config, position config and all eight
    /// channels again. What it says replaces what the app holds, and settles a
    /// channel write that was waiting for its answer.
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
            for (label, subject) in subjects {
                switch await read(subject, route: route) {
                case .answer: outcome.answered += 1
                case .noAnswer: outcome.missing.append(label)
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
        // Written to a radio that is not the one connected: what was last known
        // of it, and not a claim about this radio.
        if let node = channel.nodeNum, let connected = radioSettings.nodeNum, node != connected {
            return ("another radio: \(saved.label)", false)
        }
        guard channel.index >= 0, let node = channel.nodeNum,
              node == radioSettings.nodeNum,
              pendingChannelWrites[channel.index] == nil,
              let held = radioSettings.channelSummary(index: channel.index) else {
            return (saved.label, saved == .onRadio)
        }
        let key = MeshCoreChannelCodec.dehex(channel.pskHex) ?? Data()
        if held.isDisabled {
            return ("not on the radio now: slot \(channel.index) is empty", false)
        }
        if held.name != channel.name || held.psk != key {
            return ("not on the radio now: slot \(channel.index) holds another channel", false)
        }
        return (SavedChannelState.onRadio.label, true)
    }

    // MARK: - Reports

    func setChannelReport(slot: Int, name: String, state: MeshtasticChannelReport.State) {
        var reports = channelReports.filter { $0.slot != slot }
        reports.append(MeshtasticChannelReport(slot: slot, name: name, state: state))
        reports.sort { $0.slot < $1.slot }
        channelReports = reports
    }
}
