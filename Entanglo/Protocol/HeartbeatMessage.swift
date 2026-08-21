//
// filename: HeartbeatMessage.swift
// path: Entanglo/Entanglo/Protocol/HeartbeatMessage.swift
// purpose: Tiny heartbeat payload exchanged by NetworkTransport every
//          tick. Loss of heartbeats stops input injection immediately.
//

import Foundation

public struct HeartbeatMessage: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let lastRttMs: Double?
    /// Monotonic timestamp (ms) recorded by the *sender* when this
    /// heartbeat went out. Opaque to the receiver — only echoed back.
    public let sentAtMs: Double?
    /// The most recent `sentAtMs` the sender saw on a heartbeat from
    /// the peer. The peer subtracts this from its own `now` to obtain
    /// the round-trip time. Nil until the first heartbeat round-trip.
    public let echoSentAtMs: Double?

    public init(
        sequence: UInt64,
        lastRttMs: Double? = nil,
        sentAtMs: Double? = nil,
        echoSentAtMs: Double? = nil
    ) {
        self.sequence = sequence
        self.lastRttMs = lastRttMs
        self.sentAtMs = sentAtMs
        self.echoSentAtMs = echoSentAtMs
    }
}
