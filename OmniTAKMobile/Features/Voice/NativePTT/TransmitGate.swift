//
//  TransmitGate.swift
//  OmniTAKMobile
//
//  The transmit state machine behind NativePTTManager, kept free of the
//  PushToTalk framework so every ordering of events can be unit tested.
//  NativePTTManager feeds it events (a press, a release, the system's
//  began / ended / refused callbacks) and carries out the actions it returns.
//
//  What it guards against (all seen on device):
//  - Quick tap: released before the system answered requestBeginTransmitting
//    (10-200 ms). The stop is held and issued the moment the transmission
//    begins, instead of being lost and leaving the system transmitting.
//  - Refused stop: soon after a transmission starts the system can refuse a
//    stop with transmissionNotFound. Every refused stop is retried.
//  - Press while a stop is going through: queued, and begun as soon as the
//    old transmission has ended. Any release or abort drops the queued press
//    (a system end such as a phone call included).
//  - A stop the system never accepts: the waiting press, or the next one,
//    takes over the transmission rather than waiting for a timeout.
//

import Foundation

/// Who started or ended a transmission: our own request, or the system
/// (its Talk button, a hands-free button, an incoming call...).
enum TransmitSource: Equatable { case ours, system }

struct TransmitGate {
    enum Action: Equatable {
        /// Call requestBeginTransmitting.
        case requestBegin
        /// Call stopTransmitting.
        case requestStop
        /// Call `stopRetryFired()` after `stopRetryDelay`.
        case scheduleStopRetry
        /// Tell the voice controller a transmission began / ended.
        case notifyBegan(TransmitSource)
        case notifyEnded(TransmitSource)
        /// Diagnostic line for the console.
        case log(String)
    }

    /// A begin request older than this is treated as lost (never answered).
    static let beginRequestTimeout: TimeInterval = 3
    /// Stop attempts in total (the first one plus retries) before giving up.
    static let stopRetries = 6
    static let stopRetryDelay: TimeInterval = 0.15

    /// The system reports a transmission in progress (didBegin, no didEnd yet).
    private(set) var isTransmitting = false
    /// Our begin request is out and the system hasn't answered yet.
    private(set) var beginRequestedAt: Date?
    /// Released while the begin request was in flight: stop it once it begins.
    private(set) var stopWhenBegun = false
    /// We asked the system to stop and it hasn't reported didEnd yet.
    private(set) var stopInFlight = false
    private(set) var stopAttempts = 0
    /// Pressed while a stop was going through: begin once the old one ends.
    private(set) var beginAfterEnd = false
    /// Stops abandoned in a row with no begin/end from the system in between.
    private(set) var consecutiveGiveUps = 0

    // MARK: Operator events

    mutating func press(now: Date) -> [Action] {
        if isTransmitting {
            if stopInFlight {
                beginAfterEnd = true
                return [.log("pressed while the last transmission is still stopping — will begin when it ends")]
            }
            // The system is transmitting with nobody behind it: take it.
            return [.log("pressed while the system is already transmitting — using that transmission"),
                    .notifyBegan(.ours)]
        }
        if let at = beginRequestedAt, now.timeIntervalSince(at) < Self.beginRequestTimeout {
            // The request already out carries this press: just cancel its stop.
            stopWhenBegun = false
            return []
        }
        beginRequestedAt = now
        stopWhenBegun = false
        return [.requestBegin]
    }

    /// A release, or any abort of the current press by the controller.
    mutating func release() -> [Action] {
        // Always drop a queued press first: a system end (a phone call) arrives
        // with isTransmitting already false, and the controller's abort must
        // still cancel the press it queued.
        beginAfterEnd = false
        if isTransmitting {
            return stopInFlight ? [] : startStop()
        }
        if beginRequestedAt != nil {
            stopWhenBegun = true
            return [.log("released before the system began transmitting — will stop it when it does")]
        }
        return []
    }

    // MARK: System events

    mutating func didBegin(_ source: TransmitSource) -> [Action] {
        isTransmitting = true
        consecutiveGiveUps = 0
        if source == .ours, beginRequestedAt != nil {
            beginRequestedAt = nil
            if stopWhenBegun {
                // The operator already let go: end it now, don't start a burst.
                stopWhenBegun = false
                return [.log("stopping a transmission released before it began")] + startStop()
            }
        }
        return [.notifyBegan(source)]
    }

    /// Returns the notification only. After the controller has seen it (it may
    /// abort, calling `release()`), call `afterEndNotified(now:)`.
    mutating func didEnd(_ source: TransmitSource) -> [Action] {
        isTransmitting = false
        consecutiveGiveUps = 0
        beginRequestedAt = nil
        stopWhenBegun = false
        stopInFlight = false
        return [.notifyEnded(source)]
    }

    /// Begins a press that was queued behind the transmission that just ended.
    mutating func afterEndNotified(now: Date) -> [Action] {
        guard beginAfterEnd else { return [] }
        beginAfterEnd = false
        return [.log("previous transmission ended — beginning the queued press")] + press(now: now)
    }

    /// Our begin request was refused. A transmission the system started
    /// itself (isTransmitting) is not affected.
    mutating func failedToBegin() {
        beginRequestedAt = nil
        stopWhenBegun = false
    }

    mutating func failedToStop() -> [Action] {
        guard stopInFlight, isTransmitting else { return [] }
        guard stopAttempts < Self.stopRetries else {
            // The system won't stop it. Never leave the operator stuck: a
            // queued press takes the transmission; otherwise the next press
            // will (press() with no stop in flight).
            stopInFlight = false
            consecutiveGiveUps += 1
            if consecutiveGiveUps >= 2 {
                // Refused again after a takeover: the system evidently has no
                // transmission ("transmissionNotFound"). Believe it, or every
                // later press would "take over" nothing and time out.
                isTransmitting = false
                consecutiveGiveUps = 0
                let queued = beginAfterEnd
                beginAfterEnd = false
                return [.log("the system reports no transmission to stop — treating it as ended")]
                    + (queued ? [.notifyEnded(.ours)] : [])
            }
            var actions: [Action] = [.log("the system kept refusing the stop")]
            if beginAfterEnd {
                beginAfterEnd = false
                actions.append(.notifyBegan(.ours))
            }
            return actions
        }
        stopAttempts += 1
        return [.scheduleStopRetry]
    }

    mutating func stopRetryFired() -> [Action] {
        guard stopInFlight, isTransmitting else { return [] }
        return [.log("retrying the stop (attempt \(stopAttempts))"), .requestStop]
    }

    /// The channel was left: nothing is in flight any more.
    mutating func reset() {
        self = TransmitGate()
    }

    private mutating func startStop() -> [Action] {
        stopInFlight = true
        stopAttempts = 1
        beginAfterEnd = false
        return [.requestStop]
    }
}
