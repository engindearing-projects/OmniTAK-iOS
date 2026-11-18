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

    // MARK: - The system takes the answer back while the app is running

    private func asksAgain(_ status: CLAuthorizationStatus, showing: Bool = true, done: Bool = true) -> Bool {
        LocationPrompt.shouldAskAgain(status: status, mapScreenShowing: showing, onboardingCompleted: done)
    }

    func testTheQuestionIsPutAgainWhenTheStatusGoesBackToNotAskedWhileTheMapIsShowing() {
        // "Allow Once" runs out after the app has sat in the background, or "Ask Next Time Or When I Share"
        // is chosen in Settings: the system reports "not determined" to the running app
        XCTAssertTrue(asksAgain(.notDetermined))
    }

    func testNothingIsAskedAgainWhileAnotherScreenIsShowing() {
        // the map's own appearance asks when the operator comes back to it
        XCTAssertFalse(asksAgain(.notDetermined, showing: false))
    }

    func testNothingIsAskedAgainBeforeOnboardingIsOver() {
        XCTAssertFalse(asksAgain(.notDetermined, done: false))
    }

    func testAnAnswerIsNeverAskedAgainEvenWhileTheMapIsShowing() {
        for status in everyStatus where status != .notDetermined {
            XCTAssertFalse(asksAgain(status), "status \(status.rawValue)")
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

/// The 2D map is created once the permission is decided and then kept. The rule above is evaluated live on
/// every render, so when the system reported "not determined" to a running app (an "Allow Once" session that
/// ended, or "Ask Next Time" chosen in Settings) the live map was replaced by a black view: tilt, bearing and
/// annotations lost, and nothing put the question again.
final class MapboxStartGateTests: XCTestCase {

    private let everyStatus: [CLAuthorizationStatus] =
        [.notDetermined, .restricted, .denied, .authorizedAlways, .authorizedWhenInUse]

    func testAFreshGateFollowsTheStartRuleUntilItOpens() {
        for reported in [false, true] {
            for status in everyStatus {
                var gate = MapboxStartGate()
                XCTAssertFalse(gate.isOpen)
                gate.update(reported: reported, status: status)
                XCTAssertEqual(gate.isOpen, MapboxStart.mayCreate(reported: reported, status: status),
                               "reported \(reported), status \(status.rawValue)")
            }
        }
    }

    func testOnceOpenTheGateStaysOpenWhateverTheSystemReportsLater() {
        for first in everyStatus where first != .notDetermined {
            var gate = MapboxStartGate()
            gate.update(reported: true, status: first)
            XCTAssertTrue(gate.isOpen)
            for later in everyStatus {
                gate.update(reported: true, status: later)
                XCTAssertTrue(gate.isOpen, "closed by status \(later.rawValue) after \(first.rawValue)")
            }
            gate.update(reported: false, status: .notDetermined)
            XCTAssertTrue(gate.isOpen, "closed by a report that has not come")
        }
    }

    func testTheMapIsKeptWhenAnAllowOnceSessionEnds() {
        // the sequence the system reports to one running app: undecided, then "while using", then undecided again
        var gate = MapboxStartGate()
        var shown: [Bool] = []
        for (reported, status) in [(false, CLAuthorizationStatus.notDetermined), (true, .notDetermined),
                                   (true, .authorizedWhenInUse), (true, .notDetermined), (true, .notDetermined)] {
            gate.update(reported: reported, status: status)
            shown.append(gate.isOpen)
        }
        XCTAssertEqual(shown, [false, false, true, true, true])
    }

    func testTheGateIsPerScreenSoANewScreenWaitsForTheAnswerAgain() {
        var first = MapboxStartGate()
        first.update(reported: true, status: .authorizedWhenInUse)
        let second = MapboxStartGate()
        XCTAssertTrue(first.isOpen)
        XCTAssertFalse(second.isOpen)
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

    // MARK: - The system takes the answer back while the app is running

    private func reportStatus(_ status: CLAuthorizationStatus, to manager: LocationManager, from service: RecordingLocationService) {
        service.status = status
        manager.locationManagerDidChangeAuthorization(CLLocationManager())
        settle()
    }

    func testWhenTheStatusGoesBackToNotAskedTheQuestionIsPutOnceAndByUsOnly() {
        let service = RecordingLocationService()
        let manager = LocationManager(service: service)
        reportStatus(.authorizedWhenInUse, to: manager, from: service)
        manager.ask(at: .mapAppeared, status: manager.authorizationStatus, onboardingCompleted: true)
        XCTAssertEqual(service.whenInUseRequests, 0, "an answer is not asked for again")
        // "Allow Once" has run out: the system reports the question as not answered, to the running app
        reportStatus(.notDetermined, to: manager, from: service)
        XCTAssertEqual(manager.authorizationStatus, .notDetermined)
        XCTAssertEqual(service.whenInUseRequests, 0, "the manager itself asks for nothing when the status changes")
        manager.ask(at: .mapAppeared, status: manager.authorizationStatus, onboardingCompleted: true)
        XCTAssertEqual(service.whenInUseRequests, 1, "one question, put by LocationPrompt's rule")
        XCTAssertEqual(service.alwaysRequests, 0, "always is not asked for at all")
    }

    func testTheStatusJustReportedDecidesAndNotTheOneThisManagerStillHolds() {
        // the screen sees the change through its own manager; this one (the long-lived one that puts the
        // question) may not have taken the report yet
        let service = RecordingLocationService()
        let manager = LocationManager(service: service)
        reportStatus(.authorizedWhenInUse, to: manager, from: service)
        XCTAssertEqual(manager.authorizationStatus, .authorizedWhenInUse, "still the old answer here")
        manager.ask(at: .mapAppeared, status: .notDetermined, onboardingCompleted: true)
        XCTAssertEqual(service.whenInUseRequests, 1)
        manager.ask(at: .mapAppeared, status: .authorizedWhenInUse, onboardingCompleted: true)
        XCTAssertEqual(service.whenInUseRequests, 1, "a status that is an answer asks nothing")
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
