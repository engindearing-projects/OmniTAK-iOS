//
//  LocationPromptTests.swift
//  OmniTAKMobileTests
//
//  A fresh install used to put three system questions on top of the Welcome page before the user
//  had touched anything: notifications, location "while using", and at once location "always".
//  These pin when each question may be asked now.
//

import XCTest
import CoreLocation
import UserNotifications
@testable import OmniTAK

final class LocationPromptTests: XCTestCase {

    private let everyStatus: [CLAuthorizationStatus] =
        [.notDetermined, .restricted, .denied, .authorizedAlways, .authorizedWhenInUse]

    private func asks(_ moment: LocationPrompt.Moment, _ status: CLAuthorizationStatus, done: Bool = true) -> Bool {
        LocationPrompt.shouldAskWhenInUse(at: moment, status: status, onboardingCompleted: done)
    }

    func testNothingIsAskedAtLaunchWhateverTheStatus() {
        for status in everyStatus {
            for done in [false, true] {
                XCTAssertFalse(asks(.launch, status, done: done),
                               "asked at launch (status \(status.rawValue), onboarding done \(done))")
            }
        }
    }

    func testTheOnboardingPageAsksWhenNobodyHasAnswered() {
        XCTAssertTrue(asks(.onboardingLocationPage, .notDetermined, done: false))
    }

    func testSkippingOnboardingAsksWhenNobodyHasAnswered() {
        XCTAssertTrue(asks(.onboardingFinished, .notDetermined, done: true))
    }

    func testTheMapAsksOnlyOnceOnboardingIsOver() {
        // The map screen is built under the onboarding cover, so it appears before anyone has read a word.
        XCTAssertFalse(asks(.mapAppeared, .notDetermined, done: false))
        XCTAssertTrue(asks(.mapAppeared, .notDetermined, done: true))
    }

    func testAQuestionThatHasAnAnswerIsNeverAskedAgain() {
        let answered: [CLAuthorizationStatus] = [.restricted, .denied, .authorizedAlways, .authorizedWhenInUse]
        for moment in LocationPrompt.Moment.allCases {
            for status in answered {
                for done in [false, true] {
                    XCTAssertFalse(asks(moment, status, done: done),
                                   "\(moment) asked again with status \(status.rawValue)")
                }
            }
        }
    }

    func testSomeoneWhoAlreadyChoseAlwaysKeepsItAndIsNotAskedToChangeIt() {
        // The old code asked for "always" a second after "while using" was granted, and at every launch after.
        for moment in LocationPrompt.Moment.allCases {
            XCTAssertFalse(asks(moment, .authorizedAlways), "\(moment)")
            XCTAssertFalse(asks(moment, .authorizedWhenInUse), "\(moment)")
        }
    }
}

final class MapboxStartTests: XCTestCase {

    private let everyStatus: [CLAuthorizationStatus] =
        [.notDetermined, .restricted, .denied, .authorizedAlways, .authorizedWhenInUse]

    func testTheMapIsNotCreatedUntilTheSystemHasReportedTheStatus() {
        // the Mapbox map reads the permission synchronously when it is created: with a slow location
        // service that is a blank white screen at launch
        for status in everyStatus {
            XCTAssertFalse(MapboxStart.mayCreate(reported: false, status: status), "status \(status.rawValue)")
        }
    }

    func testTheMapIsNotCreatedWhileNobodyHasAnsweredTheLocationQuestion() {
        // the map would put the question itself, outside the rules in LocationPrompt
        XCTAssertFalse(MapboxStart.mayCreate(reported: true, status: .notDetermined))
    }

    func testTheMapIsCreatedOnceTheQuestionHasAnAnswerWhateverItIs() {
        for status in everyStatus where status != .notDetermined {
            XCTAssertTrue(MapboxStart.mayCreate(reported: true, status: status), "status \(status.rawValue)")
        }
    }
}

final class NotificationPromptTests: XCTestCase {

    func testOnlyAnUndecidedUserIsAsked() {
        XCTAssertTrue(NotificationPrompt.shouldAsk(status: .notDetermined))
        XCTAssertFalse(NotificationPrompt.shouldAsk(status: .denied))
        XCTAssertFalse(NotificationPrompt.shouldAsk(status: .authorized))
        XCTAssertFalse(NotificationPrompt.shouldAsk(status: .provisional))
        XCTAssertFalse(NotificationPrompt.shouldAsk(status: .ephemeral))
    }
}

// MARK: - The wiring: what the managers are actually asked, and when

/// Stands in for CoreLocation's manager and records every read and request.
final class RecordingLocationService: LocationService {
    weak var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var allowsBackgroundLocationUpdates = false
    var pausesLocationUpdatesAutomatically = true
    var showsBackgroundLocationIndicator = false
    /// What the system would answer.
    var status: CLAuthorizationStatus = .notDetermined
    private(set) var statusReads = 0
    private(set) var whenInUseRequests = 0
    private(set) var alwaysRequests = 0
    private(set) var locationStarts = 0
    private(set) var headingStarts = 0

    var authorizationStatus: CLAuthorizationStatus {
        statusReads += 1
        return status
    }
    func startUpdatingLocation() { locationStarts += 1 }
    func stopUpdatingLocation() {}
    func startUpdatingHeading() { headingStarts += 1 }
    func stopUpdatingHeading() {}
    func requestWhenInUseAuthorization() { whenInUseRequests += 1 }
    func requestAlwaysAuthorization() { alwaysRequests += 1 }
}

final class LocationManagerWiringTests: XCTestCase {

    private func settle() {
        let done = expectation(description: "main queue turn")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    func testCreatingTheManagerReadsNoStatusAndAsksForNothing() {
        // The old init read the permission (a call that waits for the system on the main thread, before the
        // first frame: a blank white screen when the service is slow) and asked for it, "always" included.
        let service = RecordingLocationService()
        let manager = LocationManager(service: service)
        XCTAssertEqual(service.statusReads, 0)
        XCTAssertEqual(service.whenInUseRequests, 0)
        XCTAssertEqual(service.alwaysRequests, 0)
        XCTAssertEqual(service.locationStarts, 1, "updates start by themselves once the user has said yes")
        XCTAssertEqual(service.headingStarts, 1)
        XCTAssertFalse(manager.hasReportedAuthorization, "until the system says, the status is only the starting value")
    }

    func testNothingIsAskedAtLaunchWhoeverHasNotAnswered() {
        let service = RecordingLocationService()
        let manager = LocationManager(service: service)
        manager.ask(at: .launch, onboardingCompleted: false)
        manager.ask(at: .launch, onboardingCompleted: true)
        XCTAssertEqual(service.whenInUseRequests, 0)
        XCTAssertEqual(service.alwaysRequests, 0)
    }

    func testTheOnboardingPageAsksOnceAndTheMapWaitsForOnboardingToEnd() {
        let service = RecordingLocationService()
        let manager = LocationManager(service: service)
        // the map screen is built under the onboarding cover
        manager.ask(at: .mapAppeared, onboardingCompleted: false)
        XCTAssertEqual(service.whenInUseRequests, 0)
        manager.ask(at: .onboardingLocationPage, onboardingCompleted: false)
        XCTAssertEqual(service.whenInUseRequests, 1)
        XCTAssertEqual(service.alwaysRequests, 0, "always is not asked for at all")
    }

    func testTheStatusArrivesThroughTheDelegateAndAnAnswerIsNeverAskedAgain() {
        for answer in [CLAuthorizationStatus.authorizedWhenInUse, .authorizedAlways, .denied, .restricted] {
            let service = RecordingLocationService()
            service.status = answer
            let manager = LocationManager(service: service)
            manager.locationManagerDidChangeAuthorization(CLLocationManager())
            settle()
            XCTAssertEqual(manager.authorizationStatus, answer)
            XCTAssertTrue(manager.hasReportedAuthorization)
            XCTAssertEqual(service.statusReads, 1, "one read, inside the system's own callback")
            for moment in LocationPrompt.Moment.allCases {
                manager.ask(at: moment, onboardingCompleted: true)
                manager.ask(at: moment, onboardingCompleted: false)
            }
            XCTAssertEqual(service.whenInUseRequests, 0, "status \(answer.rawValue)")
            XCTAssertEqual(service.alwaysRequests, 0, "someone who chose always keeps it and is never asked to change it")
        }
    }
}

// MARK: - Notifications: asked when the first one is about to be shown

final class RecordingNotificationCenter: NotificationCentering {
    var status: UNAuthorizationStatus = .notDetermined
    var grants = true
    private(set) var statusReads = 0
    private(set) var requests = 0
    private(set) var added: [UNNotificationRequest] = []

    func authorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        statusReads += 1
        completion(status)
    }
    func requestAuthorization(options: UNAuthorizationOptions, _ completion: @escaping (Bool, Error?) -> Void) {
        requests += 1
        completion(grants, nil)
    }
    func add(_ request: UNNotificationRequest, _ completion: @escaping (Error?) -> Void) {
        added.append(request)
        completion(nil)
    }
}

final class CoTNotificationWiringTests: XCTestCase {

    private func request() -> UNNotificationRequest {
        UNNotificationRequest(identifier: UUID().uuidString, content: UNMutableNotificationContent(), trigger: nil)
    }

    func testCreatingTheHandlerAsksNothing() {
        // It used to put the notification question on top of the Welcome page, at launch.
        let center = RecordingNotificationCenter()
        _ = CoTEventHandler(notifications: center)
        XCTAssertEqual(center.statusReads, 0)
        XCTAssertEqual(center.requests, 0)
    }

    func testTheFirstNotificationAsksOnceThenShowsIt() {
        let center = RecordingNotificationCenter()
        let handler = CoTEventHandler(notifications: center)
        let first = request()
        handler.deliver(first, kind: "chat")
        XCTAssertEqual(center.requests, 1)
        XCTAssertEqual(center.added.map(\.identifier), [first.identifier])
    }

    func testANoIsRespectedAndNothingIsShown() {
        let center = RecordingNotificationCenter()
        center.grants = false
        CoTEventHandler(notifications: center).deliver(request(), kind: "chat")
        XCTAssertEqual(center.requests, 1)
        XCTAssertTrue(center.added.isEmpty)
    }

    func testAnAnsweredQuestionIsNotAskedAgain() {
        for status in [UNAuthorizationStatus.authorized, .denied, .provisional, .ephemeral] {
            let center = RecordingNotificationCenter()
            center.status = status
            CoTEventHandler(notifications: center).deliver(request(), kind: "emergency")
            XCTAssertEqual(center.requests, 0, "status \(status.rawValue)")
            XCTAssertEqual(center.added.count, 1, "the system itself drops it for someone who said no")
        }
    }
}
