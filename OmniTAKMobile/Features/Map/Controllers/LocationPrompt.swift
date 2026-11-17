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
