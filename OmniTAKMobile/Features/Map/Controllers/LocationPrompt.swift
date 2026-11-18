//
//  LocationPrompt.swift
//  OmniTAKMobile
//
//  When the app may put the location and notification questions to the user. Nothing asks at
//  launch: each question is asked when its answer is about to matter, and this file is the one
//  place that decides it. The system dialogs themselves are shown by LocationManager (location)
//  and CoTEventHandler (notifications).
//

import CoreLocation
import UserNotifications

enum LocationPrompt {

    /// A moment in the life of the app at which the location question could be put.
    enum Moment: Equatable, CaseIterable {
        /// The process has just started.
        case launch
        /// The onboarding page that explains why the app wants the location is on screen.
        case onboardingLocationPage
        /// Onboarding has just closed (Skip, or the last page).
        case onboardingFinished
        /// The map screen has appeared.
        case mapAppeared
    }

    /// Whether to ask for location "while using the app" at `moment`: only when nobody has answered
    /// yet, and never at launch. "Always" is not asked for at all: every feature here (the position,
    /// sharing it, tracks, navigation) keeps running in the background under "while using", and
    /// someone who has already chosen "always" keeps it.
    static func shouldAskWhenInUse(at moment: Moment, status: CLAuthorizationStatus, onboardingCompleted: Bool) -> Bool {
        guard status == .notDetermined else { return false }
        switch moment {
        case .launch: return false
        case .onboardingLocationPage, .onboardingFinished: return true
        case .mapAppeared: return onboardingCompleted
        }
    }
}

enum NotificationPrompt {

    /// Whether to ask the system for permission to show a notification now: only when nobody has
    /// decided yet. Asked when the first notification is about to be shown, not at launch.
    static func shouldAsk(status: UNAuthorizationStatus) -> Bool {
        status == .notDetermined
    }
}

enum MapboxStart {

    /// Whether the 2D map may be created yet. The Mapbox map reads the location permission itself,
    /// on the main thread and waiting for the system, when it is created, and asks the location
    /// question itself if nobody has answered it. Both are wrong for this app: a slow location
    /// service left a blank white screen, and the question belongs to `LocationPrompt`. So the map
    /// is created once the system has reported the status and it is an answer.
    static func mayCreate(reported: Bool, status: CLAuthorizationStatus) -> Bool {
        reported && status != .notDetermined
    }
}

/// `MapboxStart.mayCreate` as a latch: once the 2D map may be created it stays created for the life of the
/// screen. The rule is a statement about the start: evaluated live on every render it would turn false again
/// whenever the system reports "not determined" to a running app (an "Allow Once" session that has ended, or
/// "Ask Next Time Or When I Share" chosen in Settings), and the live map, with its tilt, bearing and
/// annotations, would be replaced by a black view that nothing brings back. The question is put again by
/// `LocationPrompt.shouldAskAgain`; the map is not touched.
struct MapboxStartGate: Equatable {
    /// True once `MapboxStart.mayCreate` has been true. Never goes back to false.
    private(set) var isOpen = false

    /// Hands the gate the permission as the system last reported it.
    mutating func update(reported: Bool, status: CLAuthorizationStatus) {
        if !isOpen, MapboxStart.mayCreate(reported: reported, status: status) {
            isOpen = true
        }
    }
}

extension LocationPrompt {
    /// Whether to put the question again to a running app that the system has just reported `status` to: only
    /// when the answer has been taken back ("not determined" again), the map screen is the one showing and
    /// onboarding is over. That is the `.mapAppeared` moment: the operator who comes back to the map after an
    /// "Allow Once" session is asked, as they would be on opening it. Another screen waits until the map is
    /// back (its appearance asks).
    static func shouldAskAgain(status: CLAuthorizationStatus, mapScreenShowing: Bool, onboardingCompleted: Bool) -> Bool {
        mapScreenShowing && shouldAskWhenInUse(at: .mapAppeared, status: status, onboardingCompleted: onboardingCompleted)
    }
}
