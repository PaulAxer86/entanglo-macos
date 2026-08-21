//
// filename: DisplayFrameMessage.swift
// path: Entanglo/Entanglo/Protocol/DisplayFrameMessage.swift
// purpose: Metadata for one frame of the Remote Display prototype
//          stream. The raw encoded bytes follow on a separate data
//          sub-stream in v0.1.
//

import Foundation

public enum DisplayFrameCodec: String, Codable, Sendable {
    case h264
    case hevc
    case rawJPEG
}

public struct DisplayFrameMessage: Codable, Equatable, Sendable {
    public let frameId: UInt64
    public let width: Int
    public let height: Int
    public let codec: DisplayFrameCodec
    public let isKeyframe: Bool
    public let byteCount: Int

    public init(
        frameId: UInt64,
        width: Int,
        height: Int,
        codec: DisplayFrameCodec,
        isKeyframe: Bool,
        byteCount: Int
    ) {
        self.frameId = frameId
        self.width = width
        self.height = height
        self.codec = codec
        self.isKeyframe = isKeyframe
        self.byteCount = byteCount
    }
}
