//
//  GeofenceAlertText.swift
//  OmniTAKMobile
//
//  The words of a geofence alert and the order they are shown in. Both are pure, so they
//  are tested without a screen: the sentence builder takes the translation as an argument,
//  and the queue takes the time.
//

import Foundation

// MARK: - Sentences

enum GeofenceAlertText {
    /// Looks up a localisation key. The app's own tables by default; a test passes a lookup
    /// pinned to one language.
    typealias Localize = (_ key: String) -> String

    static let appLookup: Localize = { L($0) }

    /// "ALPHA-2 entered North gate", "You left North gate",
    /// "ALPHA-2 has been in North gate for 5 min".
    static func sentence(type: GeofenceEventType,
                         geofenceName: String,
                         subjectName: String,
                         byOperator: Bool,
                         stay: TimeInterval?,
                         localize: Localize = appLookup) -> String {
        switch (type, byOperator) {
        case (.entry, true):
            return String(format: localize("geofence.alert.you.entered"), geofenceName)
        case (.exit, true):
            return String(format: localize("geofence.alert.you.left"), geofenceName)
        case (.dwell, true):
            return String(format: localize("geofence.alert.you.dwell"), geofenceName,
                          duration(stay ?? 0, localize: localize))
        case (.entry, false):
            return String(format: localize("geofence.alert.other.entered"), subjectName, geofenceName)
        case (.exit, false):
            return String(format: localize("geofence.alert.other.left"), subjectName, geofenceName)
        case (.dwell, false):
            return String(format: localize("geofence.alert.other.dwell"), subjectName, geofenceName,
                          duration(stay ?? 0, localize: localize))
        }
    }

    static func sentence(for transition: GeofenceTransition, localize: Localize = appLookup) -> String {
        sentence(type: transition.type, geofenceName: transition.geofenceName,
                 subjectName: transition.subjectName, byOperator: transition.isOperator,
                 stay: transition.stay, localize: localize)
    }

    /// The same sentence for an event kept in the history. An event stored by an earlier
    /// version has no name and no operator flag, and reads as a teammate called "Someone".
    static func sentence(for event: GeofenceEvent, localize: Localize = appLookup) -> String {
        sentence(type: event.eventType, geofenceName: event.geofenceName,
                 subjectName: event.userName ?? localize("geofence.alert.someone"),
                 byOperator: event.byOperator, stay: event.dwellDuration, localize: localize)
    }

    /// The line on a geofence's card: "You are inside", "2 teammates inside", "Nobody inside",
    /// or that it is switched off.
    static func stateLine(isActive: Bool,
                          occupancy: GeofenceOccupancy,
                          localize: Localize = appLookup) -> String {
        guard isActive else { return localize("geofence.state.off") }
        switch (occupancy.operatorInside, occupancy.teammates) {
        case (false, 0):
            return localize("geofence.state.nobody")
        case (true, 0):
            return localize("geofence.state.you")
        case (false, 1):
            return localize("geofence.state.teammate.one")
        case (false, let count):
            return String(format: localize("geofence.state.teammates"), count)
        case (true, 1):
            return localize("geofence.state.you.teammate.one")
        case (true, let count):
            return String(format: localize("geofence.state.you.teammates"), count)
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    /// How long ago an event was, for the list: "now", "49 seconds ago", "5 minutes ago". The
    /// default style would say "in 0 seconds" for one that has just happened. A time a moment
    /// ahead of `now` (the clock moved back a little) reads as now as well.
    static func age(of date: Date, now: Date, locale: Locale = .current) -> String {
        relativeFormatter.locale = locale
        return relativeFormatter.localizedString(for: min(date, now), relativeTo: now)
    }

    /// "45 s", "5 min", "2 h", "1 h 5 min". Whole minutes, rounded down.
    static func duration(_ seconds: TimeInterval, localize: Localize = appLookup) -> String {
        let total = max(0, Int(seconds))
        if total < 60 {
            return String(format: localize("geofence.duration.seconds"), total)
        }
        let minutes = total / 60
        if minutes < 60 {
            return String(format: localize("geofence.duration.minutes"), minutes)
        }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 {
            return String(format: localize("geofence.duration.hours"), hours)
        }
        return String(format: localize("geofence.duration.hoursMinutes"), hours, rest)
    }
}

// MARK: - Banners

/// One alert on its way to the top of the map.
struct GeofenceBanner: Identifiable, Equatable {
    let id: UUID
    let sentence: String
    let type: GeofenceEventType
    let geofenceID: UUID

    init(id: UUID = UUID(), sentence: String, type: GeofenceEventType, geofenceID: UUID) {
        self.id = id
        self.sentence = sentence
        self.type = type
        self.geofenceID = geofenceID
    }
}

/// Several alerts at once queue; each is shown for `showFor` seconds, then the next.
/// The time is passed in, so the order is tested without waiting.
struct GeofenceBannerQueue {
    /// How long each banner stays up.
    static let showFor: TimeInterval = 5
    /// How many may wait behind the one showing. The history keeps them all; past this the
    /// oldest waiting one is dropped so a burst does not keep the map busy for minutes.
    static let mostWaiting = 10

    private(set) var current: GeofenceBanner?
    private(set) var waiting: [GeofenceBanner] = []
    private var shownAt: Date?

    /// When the one showing is due to go; nil when nothing is showing.
    var showUntil: Date? {
        shownAt.map { $0.addingTimeInterval(Self.showFor) }
    }

    /// Shows the banner now if nothing is showing, otherwise puts it in line.
    mutating func add(_ banner: GeofenceBanner, now: Date) {
        if current == nil {
            current = banner
            shownAt = now
        } else {
            waiting.append(banner)
            if waiting.count > Self.mostWaiting { waiting.removeFirst(waiting.count - Self.mostWaiting) }
        }
    }

    /// Moves on if the one showing has had its time.
    mutating func tick(now: Date) {
        guard let until = showUntil, now >= until else { return }
        advance(now: now)
    }

    /// Takes the one showing away (tapped, or closed) and shows the next.
    mutating func dismissCurrent(now: Date) {
        guard current != nil else { return }
        advance(now: now)
    }

    private mutating func advance(now: Date) {
        if waiting.isEmpty {
            current = nil
            shownAt = nil
        } else {
            current = waiting.removeFirst()
            shownAt = now
        }
    }
}
