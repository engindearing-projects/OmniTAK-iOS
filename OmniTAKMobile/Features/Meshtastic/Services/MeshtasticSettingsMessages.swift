//
//  MeshtasticSettingsMessages.swift
//  OmniTAK Mobile
//
//  What the Mesh Settings screen tells the operator about a write (#148). The
//  words are here, and not in the view, so that a test can read them: a message
//  that says more than the app knows is a defect like any other.
//
//  The rules the words follow:
//   - "applied" is said only when the radio's own answer shows what was asked for;
//   - "already on the radio" is said only when the radio was asked just now;
//   - "no free slot" is said only when every slot is known to be in use, and a
//     slot nothing is known about is said to be unknown;
//   - a restart is promised only after a config the radio confirmed, and never
//     after a channel, which the radio saves without restarting;
//   - nothing promises that a line will change unless something can change it.
//

import Foundation

enum MeshtasticSettingsMessages {

    /// What the operator is told about creating a channel.
    static func create(_ outcome: MeshtasticManager.ChannelOutcome, name: String) -> String {
        if outcome.savedOnly {
            return "Channel \"\(name)\" saved in this list only. It is not on a radio. "
                + "Connect a radio and create it again to put it there."
        }
        switch outcome.result {
        case .applied:
            var text = "Channel \"\(name)\" applied to slot \(outcome.slot ?? 0). The radio reports it."
            if MeshtasticAdminCodec.storedName(name) != name {
                text += " The radio keeps the name \(name) as no name."
            }
            return text
        case .notConfirmed(let reason):
            return "Channel \"\(name)\" sent to slot \(outcome.slot ?? 0). \(reason)"
        case .unchanged:
            return "Slot \(outcome.slot ?? 0): the radio reports this channel is already there. Nothing was sent."
        case .refused(let reason):
            // What was typed stays, so that it can be corrected and sent again.
            return "Not applied: \(reason)"
        }
    }

    /// What an import did, as the radio confirmed it: which slots it has now,
    /// which it did not confirm, how many it reported it already had, how many
    /// were left out and why, and how many were not tried. With no radio, the
    /// channels were kept in the list.
    static func importSummary(_ outcome: MeshtasticManager.ImportOutcome, total: Int) -> String {
        var parts: [String] = []
        if outcome.savedOnly > 0 {
            parts.append("Saved \(outcome.savedOnly) of \(total) in this list only. They are not on a radio. "
                         + "Connect a radio and join the link again to put them there.")
        }
        if !outcome.confirmed.isEmpty {
            let slots = outcome.confirmed.map(String.init).joined(separator: ", ")
            parts.append("Applied \(outcome.confirmed.count) of \(total) to slot \(slots). The radio reports them.")
        }
        if !outcome.unconfirmed.isEmpty {
            let slots = outcome.unconfirmed.map(String.init).joined(separator: ", ")
            parts.append("Sent to slot \(slots), but the radio did not confirm. See Channel writes.")
        }
        if outcome.alreadyThere > 0 {
            parts.append("\(outcome.alreadyThere) already on the radio: it reported them when asked just now.")
        }
        if outcome.waiting > 0 {
            parts.append("\(outcome.waiting) have a write waiting for the radio's answer and were not sent again. "
                         + "See Channel writes.")
        }
        if outcome.noRoom > 0 {
            parts.append("\(outcome.noRoom) not added: all seven secondary slots on the radio are in use.")
        }
        parts.append(contentsOf: outcome.skipped)
        if let refusal = outcome.refusal {
            let didSomething = !outcome.sent.isEmpty || outcome.alreadyThere > 0 || outcome.waiting > 0
                || outcome.noRoom > 0
            parts.append(didSomething ? "Stopped: \(refusal)" : "Not applied to the radio: \(refusal)")
        }
        if outcome.notTried > 0 {
            parts.append("\(outcome.notTried) not tried.")
        }
        if parts.isEmpty { parts.append("The link has no channels to add.") }
        return parts.joined(separator: " ")
    }

    /// What the operator is told about a config write. The restart is promised
    /// only after a write the radio confirmed: a write it did not confirm may not
    /// have reached it.
    static func config(_ result: MeshtasticWriteResult, what: String) -> String {
        switch result {
        case .applied:
            return "\(what) applied. The radio reports it, and restarts a few seconds later to save it. "
                + "Reconnect when it is back: it is checked again then."
        case .notConfirmed(let reason):
            return "\(what) sent. \(reason)"
        case .unchanged:
            return MeshtasticWriteResult.nothingToChange
        case .refused(let reason):
            return "Apply failed: \(reason)"
        }
    }

    /// What the operator is told after asking the radio for everything again.
    static func reread(_ outcome: MeshtasticManager.RereadOutcome) -> String {
        if let refusal = outcome.refusal { return "Could not re-read: \(refusal)" }
        if outcome.missing.isEmpty { return "Read \(outcome.answered) settings from the radio." }
        var text = "Read \(outcome.answered) settings. No answer for \(outcome.missing.joined(separator: ", "))."
        if !outcome.notAsked.isEmpty {
            text += " Not asked, because the radio had stopped answering: \(outcome.notAsked.joined(separator: ", "))."
        }
        return text
    }
}
