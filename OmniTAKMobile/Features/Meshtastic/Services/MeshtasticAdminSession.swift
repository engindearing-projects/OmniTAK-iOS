//
//  MeshtasticAdminSession.swift
//  OmniTAK Mobile
//
//  The parts of talking to a radio's admin module that are not about any one
//  setting (#148): what a request asked for, the table of requests that have not
//  been answered, a place to wait for an answer, and a gate that lets one
//  operation at a time use the link.
//
//  A request is a get_config_request or get_channel_request sent in a packet
//  that has an id the app made up and keeps. The radio echoes that id in the
//  answer (`Data.request_id`). An answer is kept only when it matches a request
//  that is still on the table (MeshtasticManager.acceptAnswer): the id, the
//  thing asked for, the connection and the radio all have to be the ones the
//  request was sent to.
//

import Foundation

/// What a get request asked for.
enum MeshtasticAdminSubject: Hashable {
    /// A sub-config, by its field number inside `Config`.
    case config(variant: Int)
    /// A channel slot.
    case channel(index: Int)
}

/// What came of waiting for an answer.
enum MeshtasticAnswerOutcome: Equatable {
    /// The bytes of the config or channel the radio sent.
    case answer(Data)
    /// Nothing matching arrived before the deadline.
    case noAnswer
    /// The connection the request was sent on is gone.
    case linkLost
}

/// A get request that has been sent and not yet answered, or whose deadline has
/// passed and whose answer may still come.
@MainActor
final class MeshtasticOutstandingRequest {
    let id: UInt32
    let subject: MeshtasticAdminSubject
    /// The connection it was sent on.
    let link: MeshtasticManager.ActiveLink
    /// The radio it was sent to.
    let node: UInt32
    /// True once the deadline has passed. An answer is still taken after that, so
    /// that a slow radio's answer is not thrown away, but nothing waits for it.
    var expired = false
    /// An operation waiting for the answer, while there is one.
    var waiter: MeshtasticAnswerWait?

    init(id: UInt32, subject: MeshtasticAdminSubject, link: MeshtasticManager.ActiveLink, node: UInt32) {
        self.id = id
        self.subject = subject
        self.link = link
        self.node = node
    }
}

/// A place to wait for one outcome. It can be filled before anyone waits, and it
/// is filled once.
@MainActor
final class MeshtasticAnswerWait {
    private var outcome: MeshtasticAnswerOutcome?
    private var continuation: CheckedContinuation<MeshtasticAnswerOutcome, Never>?

    func fulfil(_ result: MeshtasticAnswerOutcome) {
        guard outcome == nil else { return }
        outcome = result
        continuation?.resume(returning: result)
        continuation = nil
    }

    func value() async -> MeshtasticAnswerOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }
}

/// One operation at a time. An operation reads, writes and reads back, and the
/// next one must not start reading until that is done: what the radio holds
/// after a write (a role change rewrites the position config) is only known
/// from the read that follows it.
@MainActor
final class MeshtasticOperationGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// How many operations are running or waiting.
    var count: Int { (busy ? 1 : 0) + waiting.count }

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
