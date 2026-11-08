//
// filename: EntangloMessage.swift
// path: Entanglo/Entanglo/Protocol/EntangloMessage.swift
// purpose: Top-level Codable envelope for every message exchanged between
//          Entanglo peers. Carries the protocol version, type discriminator,
//          sender/session/timestamp identity, and a base64-encoded payload
//          which is the JSON of the per-type struct.
//

import Foundation

public enum MessageType: String, Codable, Sendable {
    case hello
    case pairRequest
    case pairResponse
    case heartbeat
    case inputEvent
    case clipboardText
    case error
    /// Sent by a receiver to the controlling sender to tell it that the
    /// user has touched local input on the receiver — the sender should
    /// stop forwarding events and hand the cursor back to the local Mac.
    case releaseControl
    case fileOffer
    case fileChunk
    case fileAck
    /// Sent by the controller to push an URL into the receiver's default
    /// browser. Payload: UrlPushPayload.
    case urlPush
    /// Screenshot request and reply. Receiver captures its full-display
    /// snapshot as PNG and returns it inline. Payload sizes can hit the
    /// 4 MB frame limit, so the result is compressed PNG.
    case screenshotRequest
    case screenshotResult
}

public struct FileOfferPayload: Codable, Equatable, Sendable {
    public var transferId: String
    public var name: String
    public var sizeBytes: Int
    public var totalChunks: Int
    public var chunkSize: Int
    /// Optional discriminator so the receiver can route the completed file
    /// without sniffing the filename. Currently used: "printJob" for files
    /// destined to the Printer Bridge. Older peers omit this field; nil
    /// means "regular file transfer".
    public var kind: String?
    public init(transferId: String, name: String, sizeBytes: Int, totalChunks: Int, chunkSize: Int, kind: String? = nil) {
        self.transferId = transferId
        self.name = name
        self.sizeBytes = sizeBytes
        self.totalChunks = totalChunks
        self.chunkSize = chunkSize
        self.kind = kind
    }
}

public struct FileChunkPayload: Codable, Equatable, Sendable {
    public var transferId: String
    public var sequence: Int
    public var data: Data
    public init(transferId: String, sequence: Int, data: Data) {
        self.transferId = transferId
        self.sequence = sequence
        self.data = data
    }
}

public struct FileAckPayload: Codable, Equatable, Sendable {
    public var transferId: String
    public var ok: Bool
    public var failureReason: String?
    public init(transferId: String, ok: Bool, failureReason: String? = nil) {
        self.transferId = transferId
        self.ok = ok
        self.failureReason = failureReason
    }
}

public struct ReleaseControlPayload: Codable, Equatable, Sendable {
    public var reason: String
    public init(reason: String = "local_input") { self.reason = reason }
}

public struct EntangloMessage: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let messageType: MessageType
    public let senderDeviceId: String
    public let sessionId: String
    public let timestamp: TimeInterval
    public let payload: Data

    public init(
        protocolVersion: Int,
        messageType: MessageType,
        senderDeviceId: String,
        sessionId: String,
        timestamp: TimeInterval,
        payload: Data
    ) {
        self.protocolVersion = protocolVersion
        self.messageType = messageType
        self.senderDeviceId = senderDeviceId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.payload = payload
    }
}

public struct HelloPayload: Codable, Equatable, Sendable {
    public var deviceName: String
    public var deviceModel: String
    public var appVersion: String
    public var roles: [EntangloRole]
    /// Coarse OS identifier so cross-platform peers can branch on it
    /// (e.g. "macOS", "Windows", "Linux"). Optional for backwards
    /// compatibility with older peers that don't send it.
    public var platform: String?
    /// Main display's logical-pixel width, used by remote controllers
    /// for cursor seeding and clamping (PROTOCOL.md §5.1). Optional:
    /// absent on peers that pre-date 0.1.60; must be supplied together
    /// with `screenHeight`.
    public var screenWidth: Int?
    /// Main display's logical-pixel height. See `screenWidth`.
    public var screenHeight: Int?

    public init(
        deviceName: String,
        deviceModel: String,
        appVersion: String,
        roles: [EntangloRole],
        platform: String? = nil,
        screenWidth: Int? = nil,
        screenHeight: Int? = nil
    ) {
        self.deviceName = deviceName
        self.deviceModel = deviceModel
        self.appVersion = appVersion
        self.roles = roles
        self.platform = platform
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }
}

public struct PairRequestPayload: Codable, Equatable, Sendable {
    public var requesterDeviceId: String
    public var requesterDeviceName: String
    /// Hash of the user-typed PIN combined with the per-session salt.
    public var pinHash: String

    public init(requesterDeviceId: String, requesterDeviceName: String, pinHash: String) {
        self.requesterDeviceId = requesterDeviceId
        self.requesterDeviceName = requesterDeviceName
        self.pinHash = pinHash
    }
}

public struct PairResponsePayload: Codable, Equatable, Sendable {
    public var accepted: Bool
    public var trustedDeviceId: String?
    public var rejectionReason: String?

    public init(accepted: Bool, trustedDeviceId: String? = nil, rejectionReason: String? = nil) {
        self.accepted = accepted
        self.trustedDeviceId = trustedDeviceId
        self.rejectionReason = rejectionReason
    }
}

public struct ClipboardTextPayload: Codable, Equatable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ErrorPayload: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct UrlPushPayload: Codable, Equatable, Sendable {
    public var url: String
    public init(url: String) { self.url = url }
}

public struct ScreenshotRequestPayload: Codable, Equatable, Sendable {
    public var requestId: String
    public init(requestId: String) { self.requestId = requestId }
}

public struct ScreenshotResultPayload: Codable, Equatable, Sendable {
    public var requestId: String
    public var pngData: Data?
    public var error: String?
    public init(requestId: String, pngData: Data? = nil, error: String? = nil) {
        self.requestId = requestId
        self.pngData = pngData
        self.error = error
    }
}
