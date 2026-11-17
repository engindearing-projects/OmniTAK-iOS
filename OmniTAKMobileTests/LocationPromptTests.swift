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

final class NotificationPromptTests: XCTestCase {

    func testOnlyAnUndecidedUserIsAsked() {
        XCTAssertTrue(NotificationPrompt.shouldAsk(status: .notDetermined))
        XCTAssertFalse(NotificationPrompt.shouldAsk(status: .denied))
        XCTAssertFalse(NotificationPrompt.shouldAsk(status: .authorized))
        XCTAssertFalse(NotificationPrompt.shouldAsk(status: .provisional))
        XCTAssertFalse(NotificationPrompt.shouldAsk(status: .ephemeral))
    }
}
