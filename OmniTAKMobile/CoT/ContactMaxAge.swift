//
//  ContactMaxAge.swift
//  OmniTAKMobile
//
//  #137: Hide a teammate who has gone quiet, then remove them.
//
//  Field request (a 50+ operator event): a teammate whose position has not been
//  updated for a long time is noise on a busy map. The operator picks a max age
//  in Settings. Past it the marker leaves the map and the contact moves to a
//  collapsed "not heard from" section of the contact list; at twice that age the
//  contact is removed. Chat conversations with the contact are never touched. A
//  new report brings the contact back at once. Android #215 has the same
//  behaviour.
//
//  Age is measured from when THIS DEVICE last received a report from the
//  contact (`CoTEvent.receivedAt`), not from the time inside the CoT, which is
//  the sender's clock. The CoT stale time is not used: senders often set it a
//  few minutes ahead, which would hide teammates far sooner than the setting
//  says (the existing fade in `CoTAge` already shows that).
//
//  Everything that decides anything is here, as pure functions of its inputs, so
//  it unit-tests without a clock, a timer or the singletons. `ContactMaxAgeMonitor`
//  runs it on a timer and on each report.
//

import Foundation

/// The max-age setting and the rule it drives. No instance state.
enum ContactMaxAge {

    // MARK: - The setting

    /// UserDefaults / `@AppStorage` key. Whole minutes; 0 is Never.
    static let defaultsKey = "contactMaxAgeMinutes"

    /// What an operator who never touched the setting gets.
    static let defaultMinutes = 30

    /// The stored value that turns the rule off. Never keeps the behaviour from
    /// before this setting existed.
    static let never = 0

    /// The choices Settings offers, in the order shown.
    static let choices: [Int] = [5, 10, 15, 30, 60, 120, never]

    /// The stored value, or the default when nothing is stored. A stored 0 means
    /// Never and is not the same as "unset", so this asks for the object instead
    /// of `integer(forKey:)`, which reads both as 0.
    static func currentMinutes(defaults: UserDefaults = .standard) -> Int {
        guard let stored = defaults.object(forKey: defaultsKey) as? Int else { return defaultMinutes }
        return stored
    }

    // MARK: - Words

    static let settingTitle = "Hide teammates not heard from for"
    static let settingHelp = "Their marker leaves the map after this time without a report, " +
        "and they are removed after twice this time. A new report brings them back."

    /// "5 min", "30 min", "1 h", "2 h", "Never". Whole hours read as hours, any
    /// other number as minutes.
    static func label(forMinutes minutes: Int) -> String {
        if minutes <= 0 { return "Never" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes) min"
    }

    /// Title of the collapsed contact-list section: "Not heard from for over 30 min".
    static func staleSectionTitle(maxAgeMinutes: Int) -> String {
        "Not heard from for over \(label(forMinutes: maxAgeMinutes))"
    }

    // MARK: - The rule

    enum Decision: Equatable {
        /// Younger than the max age (or the rule is off): as before, the existing fade still applies.
        case fresh
        /// At least the max age and under twice it: off the map, still in the store.
        case hidden
        /// At least twice the max age: removed from the contact store.
        case remove
    }

    /// The one decision, a function of three inputs and nothing else.
    ///
    /// - `maxAgeMinutes` of 0 or less is Never: always `.fresh`.
    /// - A clock that reads earlier than the last report (the phone's clock was
    ///   set back) gives a negative age, which is `.fresh`.
    /// - `age < max` is fresh, `max <= age < 2 x max` is hidden, `age >= 2 x max`
    ///   is remove. The boundaries belong to the older state.
    static func decision(now: Date, lastReceived: Date, maxAgeMinutes: Int) -> Decision {
        guard maxAgeMinutes > 0 else { return .fresh }
        let age = now.timeIntervalSince(lastReceived)
        let limit = TimeInterval(maxAgeMinutes) * 60
        if age < limit { return .fresh }
        if age < 2 * limit { return .hidden }
        return .remove
    }

    // MARK: - What it applies to

    /// Only another operator's own position report, the same rule as Android #215
    /// so both apps hide the same things. An event qualifies when ALL of these hold:
    ///
    /// 1. it is a messageable contact, not a marker: its uid is not a dropped
    ///    marker (`marker-`) and its type is a position report, not a waypoint or
    ///    spot marker (`b-m-p-...`; covered by the next point);
    /// 2. its CoT type starts with `a-f-` (friendly). Hostile, neutral, unknown and
    ///    other markers placed by someone else are often dropped markers, not people;
    /// 3. its CoT `how` starts with `m-` (machine reported, e.g. `m-g` GPS), which is
    ///    how a device reports where it is. A marker a person placed is `h-...`.
    ///    An event with no `how` at all is unclear and left alone;
    /// 4. its uid is not this operator's own;
    /// 5. its uid does not start with `RID-` (Remote ID drones) or `mesh-`,
    ///    `MESHCORE-`, `MESHTASTIC-` (mesh nodes); those have their own layers.
    ///
    /// One more condition than Android: an event the app tagged as arriving over a
    /// mesh radio or from this device (`CoTSource`) is also left alone. In practice
    /// those carry no `how` or have a mesh uid, so it only guards against odd cases.
    ///
    /// Anything unclear is left alone, so the worst a wrong call does is keep today's
    /// behaviour.
    static func appliesTo(_ event: CoTEvent, selfUID: String?) -> Bool {
        guard event.type.lowercased().hasPrefix("a-f-") else { return false }
        guard let how = event.how, how.lowercased().hasPrefix("m-") else { return false }
        guard isOperatorUID(event.uid, selfUID: selfUID) else { return false }
        if let transport = event.source?.transport, transport != .takServer { return false }
        return true
    }

    /// The same question for a contact-list entry that has no event in the store
    /// (saved from an earlier session). iOS keeps its contact list across restarts
    /// and Android does not, so this has no Android counterpart. A saved contact
    /// qualifies when it was saved from a report that qualified
    /// (`ChatParticipant.fromPositionReport`, set by `CoTEventHandler`). Contacts
    /// saved any other way, or by a build before this setting existed, are left
    /// alone.
    static func appliesTo(_ participant: ChatParticipant, selfUID: String?) -> Bool {
        guard isOperatorUID(participant.id, selfUID: selfUID) else { return false }
        return participant.fromPositionReport == true
    }

    private static let nonOperatorPrefixes = ["marker-", "rid-", "mesh-", "meshcore-", "meshtastic-"]

    private static func isOperatorUID(_ uid: String, selfUID: String?) -> Bool {
        if let selfUID, uid == selfUID { return false }
        let lowered = uid.lowercased()
        return !nonOperatorPrefixes.contains { lowered.hasPrefix($0) }
    }

    // MARK: - One pass over both stores

    /// What one pass of the rule decided.
    struct Outcome: Equatable {
        /// For every contact now hidden: when this device last received a report
        /// from it. The map leaves these off, the contact list shows them in the
        /// collapsed section with their age.
        var hidden: [String: Date] = [:]
        /// Contacts to remove from the contact store (both the map's event store
        /// and the contact list). Their chat conversations are not in this set's
        /// reach: nothing here names a conversation.
        var removed: Set<String> = []
    }

    /// Runs the rule over everything that can be a contact.
    ///
    /// A contact is judged by the last position report in the event store. A
    /// contact-list entry with no event in the store (saved from an earlier
    /// session) is judged by its `lastSeen`, and only when it qualifies. An event
    /// with no receive time (never ingested through the handler) cannot be aged
    /// and is left alone.
    static func evaluate(now: Date,
                         maxAgeMinutes: Int,
                         selfUID: String?,
                         events: [CoTEvent],
                         participants: [ChatParticipant]) -> Outcome {
        var outcome = Outcome()
        guard maxAgeMinutes > 0 else { return outcome }

        func record(_ uid: String, lastReceived: Date) {
            switch decision(now: now, lastReceived: lastReceived, maxAgeMinutes: maxAgeMinutes) {
            case .fresh: break
            case .hidden: outcome.hidden[uid] = lastReceived
            case .remove: outcome.removed.insert(uid)
            }
        }

        var uidsWithAnEvent = Set<String>()
        for event in events {
            uidsWithAnEvent.insert(event.uid)
            guard appliesTo(event, selfUID: selfUID), let received = event.receivedAt else { continue }
            record(event.uid, lastReceived: received)
        }
        for participant in participants
        where !uidsWithAnEvent.contains(participant.id) && appliesTo(participant, selfUID: selfUID) {
            record(participant.id, lastReceived: participant.lastSeen)
        }
        return outcome
    }

    // MARK: - The contact list

    /// Splits the contact list the way it is shown. `visible` stays in the list.
    /// `stale` goes to the collapsed section at the end, the contact heard from
    /// most recently first.
    static func partition(_ contacts: [ChatParticipant],
                          hidden: [String: Date]) -> (visible: [ChatParticipant], stale: [ChatParticipant]) {
        let visible = contacts.filter { hidden[$0.id] == nil }
        let stale = contacts
            .filter { hidden[$0.id] != nil }
            .sorted { (hidden[$0.id] ?? .distantPast) > (hidden[$1.id] ?? .distantPast) }
        return (visible, stale)
    }

    // MARK: - The existing hourly sweep

    /// Whether the five-minute sweep in `CoTEventHandler` removes `event`.
    ///
    /// That sweep drops anything whose CoT time is older than an hour, except
    /// dropped markers. With the max age set to 1 h or 2 h it would remove a
    /// teammate before the rule here has even hidden them, so while the rule is
    /// on it leaves the contacts the rule governs to the rule. With Never it is
    /// exactly what it was.
    static func hourlySweepRemoves(_ event: CoTEvent,
                                   cutoff: Date,
                                   maxAgeMinutes: Int,
                                   selfUID: String?) -> Bool {
        guard !event.uid.isDroppedPointMarkerUID else { return false }
        if maxAgeMinutes > 0, appliesTo(event, selfUID: selfUID) { return false }
        return event.time < cutoff
    }
}
