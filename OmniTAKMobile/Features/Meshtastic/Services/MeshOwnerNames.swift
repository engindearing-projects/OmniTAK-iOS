//
//  MeshOwnerNames.swift
//  OmniTAKMobile
//
//  Swift port of the Android MeshOwnerNames.derive helper. Translates a
//  TAK operator callsign into a Meshtastic owner long/short name pair.
//  Pure — used by the callsign → mesh-owner auto-sync and by any future
//  Settings UI that wants to preview the derived short.
//
//  Meshtastic radios truncate `shortName` to 4 characters in their LCD
//  UI. Operators tend to name themselves "ALPHA-1" / "ENGIE-3" — the
//  trailing digits are the identifying part. We keep up to 3 leading
//  letters and append trailing digits (or just take the first 4
//  alphanumerics when there's no letter/digit split).
//
//  Examples (kept in sync with Android MeshOwnerNamesTest):
//    "ENGIE-1"        → ("ENGIE-1", "ENG1")
//    "ALPHA-7"        → ("ALPHA-7", "ALP7")
//    "Alphabravo-12"  → ("Alphabravo-12", "AL12")
//    "ops"            → ("ops", "OPS")
//    "OMNI"           → ("OMNI", "OMNI")
//    ""               → nil
//

import Foundation

enum MeshOwnerNames {
    static func derive(_ callsign: String) -> (long: String, short: String)? {
        let trimmed = callsign.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let cleaned = trimmed.filter { $0.isLetter || $0.isNumber }.uppercased()
        guard !cleaned.isEmpty else { return nil }

        let leadingLetters = cleaned.prefix(while: { $0.isLetter })
        let trailingDigits = cleaned.reversed().prefix(while: { $0.isNumber })
            .reversed()
            .map { String($0) }
            .joined()

        let short: String
        if !leadingLetters.isEmpty && !trailingDigits.isEmpty {
            let keepDigits = String(trailingDigits.prefix(min(3, trailingDigits.count)))
            let keepLetters = String(leadingLetters.prefix(4 - keepDigits.count))
            short = String((keepLetters + keepDigits).prefix(4))
        } else {
            short = String(cleaned.prefix(4))
        }
        guard !short.isEmpty else { return nil }
        return (trimmed, short)
    }
}
