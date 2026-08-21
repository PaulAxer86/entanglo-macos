//
// filename: MessageCodec.swift
// path: Entanglo/Entanglo/Protocol/MessageCodec.swift
// purpose: Encodes/decodes EntangloMessage envelopes plus their typed
//          payloads. Fails closed on unknown protocol versions, unknown
//          message types, and oversize buffers.
//

import Foundation

public enum MessageCodecError: Error, Equatable {
    case unknownProtocolVersion(Int)
    case oversizeMessage(Int)
    case payloadDecodeFailed(MessageType)
    case payloadTypeMismatch(MessageType)
    case unknownMessageType(String)
}

public enum MessageCodec {
    public static let currentProtocolVersion: Int = 1
    public static let maxMessageBytes: Int = 4 * 1024 * 1024 // 4 MB

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// Wraps a typed payload struct into a versioned envelope.
    public static func encode<Payload: Encodable>(
        type: MessageType,
        senderDeviceId: String,
        sessionId: String,
        payload: Payload,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) throws -> Data {
        let payloadData = try encoder.encode(payload)
        let envelope = EntangloMessage(
            protocolVersion: currentProtocolVersion,
            messageType: type,
            senderDeviceId: senderDeviceId,
            sessionId: sessionId,
            timestamp: timestamp,
            payload: payloadData
        )
        let bytes = try encoder.encode(envelope)
        if bytes.count > maxMessageBytes {
            throw MessageCodecError.oversizeMessage(bytes.count)
        }
        return bytes
    }

    /// Decodes the envelope and enforces the version check. Does NOT yet
    /// decode the inner payload — call `decodePayload` for that.
    ///
    /// Two-pass strategy: first decode the envelope with `messageType` as a
    /// raw `String`, then check that string against the known enum cases.
    /// An unknown value becomes `MessageCodecError.unknownMessageType` so
    /// the transport can log + skip the frame without closing the
    /// connection. This is the forward-compat path that lets cross-platform
    /// peers introduce new message types in v1.x without breaking the Mac.
    public static func decodeEnvelope(_ data: Data) throws -> EntangloMessage {
        if data.count > maxMessageBytes {
            throw MessageCodecError.oversizeMessage(data.count)
        }
        let raw = try decoder.decode(RawEnvelope.self, from: data)
        guard raw.protocolVersion == currentProtocolVersion else {
            throw MessageCodecError.unknownProtocolVersion(raw.protocolVersion)
        }
        guard let type = MessageType(rawValue: raw.messageType) else {
            throw MessageCodecError.unknownMessageType(raw.messageType)
        }
        return EntangloMessage(
            protocolVersion: raw.protocolVersion,
            messageType: type,
            senderDeviceId: raw.senderDeviceId,
            sessionId: raw.sessionId,
            timestamp: raw.timestamp,
            payload: raw.payload
        )
    }

    /// Mirrors `EntangloMessage` but keeps `messageType` as a raw string so
    /// the decoder doesn't blow up on values added by newer peers.
    private struct RawEnvelope: Decodable {
        let protocolVersion: Int
        let messageType: String
        let senderDeviceId: String
        let sessionId: String
        let timestamp: TimeInterval
        let payload: Data
    }

    public static func decodePayload<T: Decodable>(
        _ envelope: EntangloMessage,
        as type: T.Type
    ) throws -> T {
        do {
            return try decoder.decode(T.self, from: envelope.payload)
        } catch {
            throw MessageCodecError.payloadDecodeFailed(envelope.messageType)
        }
    }
}
