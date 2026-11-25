//
//  EmergencyPressTracker.swift
//  OmniTAKMobile
//
//  Pure press/hold logic for a speaker-mic emergency button, ported from
//  TAK-XVoice's EmergencyController (LMR-style):
//    PRESS               → arm; the caller schedules thresholdReached() at 1 s.
//    RELEASE before 1 s  → .fire (start the emergency alert).
//    HELD to 1 s         → .cancel at the threshold (feedback without letting
//                          go); the later release does nothing.
//    RELEASE at ≥1 s before the threshold callback ran → .cancel.
//  A stuck button can't keep firing, and holding the same button is how an
//  operator affirmatively cancels.
//

import Foundation

struct EmergencyPressTracker {
    enum Action: Equatable { case none, fire, cancel }
    static let longPress: TimeInterval = 1.0

    private var pressedAt: Date?
    private var longHoldFired = false

    mutating func press(at t: Date) {
        pressedAt = t
        longHoldFired = false
    }

    /// Called by the caller's 1 s timer.
    mutating func thresholdReached() -> Action {
        guard pressedAt != nil, !longHoldFired else { return .none }
        longHoldFired = true
        return .cancel
    }

    mutating func release(at t: Date) -> Action {
        guard let at = pressedAt else { return .none }   // release with no armed press
        pressedAt = nil
        if longHoldFired { return .none }                // already cancelled at the threshold
        return t.timeIntervalSince(at) >= Self.longPress ? .cancel : .fire
    }
}
