//
// filename: MessageCodecTests.swift
// path: Entanglo/Tests/EntangloTests/MessageCodecTests.swift
// purpose: Verifies the message envelope round-trips, that unknown
//          protocol versions are rejected, and that oversize messages
//          are rejected.
//

import XCTest
@testable import EntangloCore

final class MessageCodecTests: XCTestCase {

    func testRoundTripInputEvent() throws {
        let payload = InputEventMessage(
            kind: .mouseMove,
            x: 100, y: 50,
            modifierFlags: 0
        )
        let data = try MessageCodec.encode(
            type: .inputEvent,
            senderDeviceId: "dev-1",
            sessionId: "sess-1",
            payload: payload
        )
        let envelope = try MessageCodec.decodeEnvelope(data)
        XCTAssertEqual(envelope.protocolVersion, MessageCodec.currentProtocolVersion)
        XCTAssertEqual(envelope.messageType, .inputEvent)
        XCTAssertEqual(envelope.senderDeviceId, "dev-1")

        let decoded = try MessageCodec.decodePayload(envelope, as: InputEventMessage.self)
        XCTAssertEqual(decoded, payload)
    }

    func testUnknownProtocolVersionIsRejected() throws {
        // Hand-build an envelope with a bad version.
        let payloadBytes = try JSONEncoder().encode(HeartbeatMessage(sequence: 1))
        let bogus = EntangloMessage(
            protocolVersion: 999,
            messageType: .heartbeat,
            senderDeviceId: "dev",
            sessionId: "sess",
            timestamp: 0,
            payload: payloadBytes
        )
        let data = try JSONEncoder().encode(bogus)

        XCTAssertThrowsError(try MessageCodec.decodeEnvelope(data)) { error in
            guard case MessageCodecError.unknownProtocolVersion(let v) = error else {
                return XCTFail("Wrong error: \(error)")
            }
            XCTAssertEqual(v, 999)
        }
    }

    func testOversizeIsRejected() {
        let big = Data(repeating: 0, count: MessageCodec.maxMessageBytes + 1)
        XCTAssertThrowsError(try MessageCodec.decodeEnvelope(big)) { error in
            guard case MessageCodecError.oversizeMessage = error else {
                return XCTFail("Wrong error: \(error)")
            }
        }
    }

    func testHelloPayloadRoundTrip() throws {
        let payload = HelloPayload(
            deviceName: "iMac",
            deviceModel: "iMac12,2",
            appVersion: "0.1.0",
            roles: [.controller, .aiWorker]
        )
        let data = try MessageCodec.encode(
            type: .hello,
            senderDeviceId: "id",
            sessionId: "s",
            payload: payload
        )
        let env = try MessageCodec.decodeEnvelope(data)
        let decoded = try MessageCodec.decodePayload(env, as: HelloPayload.self)
        XCTAssertEqual(decoded, payload)
    }
}
