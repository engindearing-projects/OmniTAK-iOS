//
//  MeshCoreCoTConverter.swift
//  OmniTAK Mobile
//
//  Converts decoded MeshCore contacts to TAK CoT events. Mirrors
//  MeshtasticCoTConverter's node->CoT mapping; the only material difference is
//  the UID namespace — MeshCore PLIs use `MESHCORE-<pubkey8>` so they never
//  collide with Meshtastic's `mesh-<nodenum>` markers and stay stable across
//  sessions (keyed on the node's public key, not a volatile node number).
//

import Foundation

enum MeshCoreCoTConverter {

    /// CoT UID for a MeshCore contact: `MESHCORE-` + first 12 uppercase hex chars
    /// (6 bytes) of the node's public key. Matches the 6-byte prefix the firmware
    /// uses to key contacts (Android-consistent: MESHCORE-<12 uppercase hex>).
    static func uid(forPubKeyHex pubKeyHex: String) -> String {
        let prefix = String(pubKeyHex.prefix(12)).uppercased()
        return "MESHCORE-\(prefix.isEmpty ? "UNKNOWN" : prefix)"
    }

    /// Build a CoT PLI event for a MeshCore contact with a valid position.
    /// Returns nil if the contact has no usable position.
    static func toCoTEvent(contact: MeshCoreContact,
                           isOwnNode: Bool = false,
                           batteryPercent: Int? = nil) -> CoTEvent? {
        guard contact.hasValidPosition else { return nil }

        let uid = Self.uid(forPubKeyHex: contact.pubKeyHex)
        // Friendly ground unit for self, neutral ground unit for others —
        // same convention MeshtasticCoTConverter uses.
        let cotType = isOwnNode ? "a-f-G-U-C" : "a-n-G-U-C"
        let callsign = contact.name.isEmpty ? shortName(forPubKeyHex: contact.pubKeyHex) : contact.name

        var remarks = "MeshCore Node"
        remarks += " | Key: \(String(contact.pubKeyHex.prefix(8)))"
        if contact.isRepeater { remarks += " | Repeater" }
        if let battery = batteryPercent, battery >= 0 { remarks += " | Bat: \(battery)%" }

        let point = CoTPoint(
            lat: contact.latitude,
            lon: contact.longitude,
            hae: 0.0,
            ce: 50.0,
            le: 50.0
        )

        let detail = CoTDetail(
            callsign: callsign,
            team: "MeshCore",
            teamRole: nil,
            speed: nil,
            course: nil,
            remarks: remarks,
            battery: (batteryPercent ?? -1) >= 0 ? batteryPercent : nil,
            device: "MeshCore",
            platform: "LoRa"
        )

        let time = contact.advertTimestampSec > 0
            ? Date(timeIntervalSince1970: TimeInterval(contact.advertTimestampSec))
            : Date()

        return CoTEvent(uid: uid, type: cotType, time: time, point: point, detail: detail)
    }

    /// A short, human-ish fallback name from the pubkey (first 12 hex = 6 bytes),
    /// matching the 6-byte-prefix convention (e.g. "MeshCore-DEADBEEFCAFE").
    private static func shortName(forPubKeyHex pubKeyHex: String) -> String {
        let id12 = String(pubKeyHex.prefix(12)).uppercased()
        return id12.isEmpty ? "MeshCore" : "MeshCore-\(id12)"
    }
}
