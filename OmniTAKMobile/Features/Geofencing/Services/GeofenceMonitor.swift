//
//  GeofenceMonitor.swift
//  OmniTAKMobile
//
//  The rules of geofencing, kept free of any location manager, timer or clock so they
//  can be tested on their own. The service feeds it positions and the time; it says
//  what happened.
//
//  Rules:
//    - The first time a subject is seen against a zone only sets the baseline and
//      raises nothing: making a zone around yourself must not announce that you
//      "entered" it, and a relaunch must not announce everyone again.
//    - Entry is outside -> inside, exit is inside -> outside, and dwell fires once
//      per stay when the stay reaches the zone's dwell threshold (above zero).
//    - A zone that is switched off, deleted, or no longer watching a kind of subject
//      forgets those subjects; switching it back on starts from a new baseline.
//    - A subject that disappears (a contact removed or gone stale) raises nothing,
//      and is forgotten, so its next sighting is a new baseline.
//    - `now` is always passed in. Nothing here reads a clock.
//

import Foundation
import CoreLocation

// MARK: - What the monitor reports

/// One thing that happened: a subject crossed a zone's edge, or stayed long enough.
struct GeofenceTransition: Equatable {
    let geofenceID: UUID
    let geofenceName: String
    /// A stable id: the operator's own uid, or a contact's CoT uid.
    let subjectID: String
    /// What to call them: a callsign.
    let subjectName: String
    let isOperator: Bool
    let type: GeofenceEventType
    /// Where the subject was when it happened.
    let coordinate: CLLocationCoordinate2D
    let time: Date
    /// How long the subject had been inside: set for an exit and for a dwell.
    let stay: TimeInterval?

    static func == (lhs: GeofenceTransition, rhs: GeofenceTransition) -> Bool {
        lhs.geofenceID == rhs.geofenceID &&
        lhs.geofenceName == rhs.geofenceName &&
        lhs.subjectID == rhs.subjectID &&
        lhs.subjectName == rhs.subjectName &&
        lhs.isOperator == rhs.isOperator &&
        lhs.type == rhs.type &&
        lhs.coordinate.latitude == rhs.coordinate.latitude &&
        lhs.coordinate.longitude == rhs.coordinate.longitude &&
        lhs.time == rhs.time &&
        lhs.stay == rhs.stay
    }
}

/// Who is inside a zone right now, as far as the monitor knows.
struct GeofenceOccupancy: Equatable {
    var operatorInside = false
    var teammates = 0

    var isEmpty: Bool { !operatorInside && teammates == 0 }
}

// MARK: - Who counts as a teammate

enum GeofenceSubjectRule {
    /// Whether a position report is a teammate for geofencing: a unit (CoT type `a-...`) that
    /// is not hostile, suspect or joker, reported by a device (`how` starts with `m-`, or is
    /// absent) and not placed by hand (`h-`). Not the operator's own uid (the phone's GPS
    /// covers that), not a dropped marker (`marker-`), not a drone detection (`RID-`).
    ///
    /// Contacts heard over a mesh radio are teammates too: they reach the app through the
    /// same stream as the ones heard from a TAK server.
    static func isTeammate(uid: String, type: String, how: String?, selfUID: String?) -> Bool {
        if let selfUID, uid == selfUID { return false }
        let lowered = uid.lowercased()
        if lowered.hasPrefix("marker-") || lowered.hasPrefix("rid-") { return false }

        let parts = type.lowercased().split(separator: "-")
        guard parts.count >= 2, parts[0] == "a" else { return false }
        if ["h", "s", "j"].contains(String(parts[1])) { return false }

        if let how = how?.lowercased(), !how.hasPrefix("m-") { return false }
        return true
    }
}

// MARK: - The monitor

/// Holds, for every zone and every subject, whether the subject was inside, since when,
/// and whether the dwell alert has fired for this stay.
struct GeofenceMonitor {
    private struct Key: Hashable {
        let zone: UUID
        let subject: String
    }

    private struct Stay {
        var isOperator: Bool
        var inside: Bool
        /// When the current stay began; nil while outside.
        var since: Date?
        var dwellFired: Bool
    }

    private var stays: [Key: Stay] = [:]

    /// Takes one position of one subject at `now` and returns what changed, for every zone
    /// that watches that kind of subject.
    ///
    /// - Parameters:
    ///   - subject: the subject's stable id.
    ///   - name: what to call it in an alert.
    ///   - zones: every geofence there is, not just the ones to look at: the ones that
    ///     are gone or switched off are forgotten here.
    ///   - isOperator: the phone's own position, as opposed to a teammate's.
    /// - Returns: the transitions the zones asked to hear about: entry only if the zone
    ///   alerts on entry, exit only if it alerts on exit, dwell only if its threshold is
    ///   above zero. State is kept whether or not an alert was asked for.
    ///
    /// Dwell is judged from the times it is given, so a subject that stays put and sends
    /// nothing new needs its last position given again later for dwell to fire.
    mutating func update(subject: String,
                         name: String,
                         coordinate: CLLocationCoordinate2D,
                         now: Date,
                         zones: [Geofence],
                         isOperator: Bool = false) -> [GeofenceTransition] {
        retain(zones: zones)

        var transitions: [GeofenceTransition] = []
        for zone in zones where zone.isActive && zone.hasUsableShape && zone.watches(operator: isOperator) {
            let key = Key(zone: zone.id, subject: subject)
            let inside = zone.containsPoint(coordinate)

            guard var stay = stays[key] else {
                // First sighting: the baseline. Nothing is raised.
                stays[key] = Stay(isOperator: isOperator, inside: inside, since: inside ? now : nil, dwellFired: false)
                continue
            }

            func transition(_ type: GeofenceEventType, stay length: TimeInterval?) -> GeofenceTransition {
                GeofenceTransition(geofenceID: zone.id, geofenceName: zone.name,
                                   subjectID: subject, subjectName: name, isOperator: isOperator,
                                   type: type, coordinate: coordinate, time: now, stay: length)
            }

            if inside && !stay.inside {
                stay = Stay(isOperator: isOperator, inside: true, since: now, dwellFired: false)
                if zone.alertOnEntry { transitions.append(transition(.entry, stay: nil)) }
            } else if !inside && stay.inside {
                let spent = stay.since.map { max(0, now.timeIntervalSince($0)) }
                stay = Stay(isOperator: isOperator, inside: false, since: nil, dwellFired: false)
                if zone.alertOnExit { transitions.append(transition(.exit, stay: spent)) }
            } else if inside, !stay.dwellFired, zone.dwellTimeThreshold > 0, let since = stay.since {
                let spent = max(0, now.timeIntervalSince(since))
                if spent >= zone.dwellTimeThreshold {
                    stay.dwellFired = true
                    transitions.append(transition(.dwell, stay: spent))
                }
            }
            stays[key] = stay
        }
        return transitions
    }

    /// Forgets a subject everywhere. It raises nothing, and its next sighting is a new baseline.
    mutating func forget(subject: String) {
        stays = stays.filter { $0.key.subject != subject }
    }

    /// Forgets what the zones no longer watch: zones that are gone, switched off, without
    /// a shape, or not watching that kind of subject any more.
    mutating func retain(zones: [Geofence]) {
        var byID: [UUID: Geofence] = [:]
        for zone in zones { byID[zone.id] = zone }
        stays = stays.filter { entry in
            guard let zone = byID[entry.key.zone], zone.isActive, zone.hasUsableShape else { return false }
            return zone.watches(operator: entry.value.isOperator)
        }
    }

    /// Who is inside one zone now.
    func occupancy(of zone: UUID) -> GeofenceOccupancy {
        var result = GeofenceOccupancy()
        for (key, stay) in stays where key.zone == zone && stay.inside {
            if stay.isOperator { result.operatorInside = true } else { result.teammates += 1 }
        }
        return result
    }
}
