//
// filename: FileTransferService.swift
// path: Entanglo/Entanglo/Services/FileTransferService.swift
// purpose: Sends and receives files between trusted peers using the
//          existing length-prefixed JSON wire protocol. Splits files
//          into ~2 MB chunks (well under the codec's 4 MB cap once
//          base64-inflated) and reassembles on the receiver under
//          ~/Downloads/Entanglo/.
//

import Foundation
#if canImport(Combine)
import Combine
#endif

@MainActor
public final class FileTransferService: ObservableObject {

    public enum Direction: String, Codable, Sendable { case incoming, outgoing }
    public enum Status: String, Codable, Sendable {
        case offered, active, completed, failed, cancelled
    }

    public struct Transfer: Identifiable, Equatable, Sendable {
        public let id: String
        public var direction: Direction
        public var peerDeviceId: String
        public var peerName: String
        public var fileName: String
        public var sizeBytes: Int
        public var bytesTransferred: Int
        public var totalChunks: Int
        public var chunksDone: Int
        public var status: Status
        public var startedAt: Date
        public var finishedAt: Date?
        public var errorMessage: String?
        public var destinationURL: URL?
        /// Routing hint set by the sender (e.g. "printJob"). Mirrors
        /// FileOfferPayload.kind so AppState's onIncomingFileComplete can
        /// dispatch to PrinterBridgeService instead of UpdateService.
        public var kind: String?

        public var progress: Double {
            sizeBytes > 0 ? Double(bytesTransferred) / Double(sizeBytes) : 0
        }
    }

    /// Chunk size in raw bytes. 512 KB raw → ~700 KB base64 in JSON,
    /// well under MessageCodec.maxMessageBytes (4 MB). Kept small so
    /// each frame flushes inside the 3 s heartbeat window even on a
    /// congested Wi-Fi link — larger chunks used to monopolize the
    /// read pipeline long enough to trip the "link presumed dead"
    /// timeout mid-transfer.
    public static let chunkSizeBytes: Int = 512 * 1024

    @Published public private(set) var transfers: [Transfer] = []

    /// Called when the service wants to send a frame on a specific peer.
    /// Wired by ConnectionCoordinator.
    public var sendToPeer: ((_ peerId: String, _ type: MessageType, _ payloadJSON: Data) -> Void)?

    /// Fired right after an incoming transfer is marked completed. The
    /// UpdateService uses this to detect peer-pushed DMG installers.
    public var onIncomingFileComplete: ((Transfer) -> Void)?

    /// Fired whenever an outgoing transfer transitions to a terminal
    /// state (completed / failed / cancelled). The Install flow uses this
    /// to wait for all peer pushes before opening the local DMG.
    public var onOutgoingFileTerminal: ((Transfer) -> Void)?

    private let log: AppLogService
    /// transferId → open file handle for an incoming write.
    private var incomingHandles: [String: FileHandle] = [:]
    /// transferId → next expected sequence for an incoming transfer.
    private var incomingNextSeq: [String: Int] = [:]

    public init(log: AppLogService = .shared) {
        self.log = log
    }

    // MARK: - Sender

    /// Begin sending `url` to `peerDeviceId`. Returns the transfer id.
    /// `kind` is an optional routing hint shipped to the receiver in the
    /// FileOfferPayload (e.g. "printJob" so AppState dispatches to the
    /// Printer Bridge instead of the regular Downloads pile).
    @discardableResult
    public func sendFile(at url: URL, to peerDeviceId: String, peerName: String, kind: String? = nil) -> String {
        let transferId = UUID().uuidString
        let name = url.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let chunkSize = Self.chunkSizeBytes
        let total = max(1, Int((Double(size) / Double(chunkSize)).rounded(.up)))

        var t = Transfer(
            id: transferId,
            direction: .outgoing,
            peerDeviceId: peerDeviceId,
            peerName: peerName,
            fileName: name,
            sizeBytes: size,
            bytesTransferred: 0,
            totalChunks: total,
            chunksDone: 0,
            status: .offered,
            startedAt: Date(),
            finishedAt: nil,
            errorMessage: nil,
            destinationURL: nil,
            kind: kind
        )
        transfers.insert(t, at: 0)
        log.log(.network, "File offer \(name) (\(size) B, \(total) chunks, kind=\(kind ?? "file")) → \(peerName)")

        // Send offer.
        let offer = FileOfferPayload(
            transferId: transferId, name: name, sizeBytes: size,
            totalChunks: total, chunkSize: chunkSize, kind: kind
        )
        guard let offerData = try? JSONEncoder().encode(offer) else {
            markFailure(transferId, reason: "Offer encode failed"); return transferId
        }
        sendToPeer?(peerDeviceId, .fileOffer, offerData)

        // Stream chunks on a background task; update progress on main.
        t.status = .active
        update(transferId) { $0.status = .active }
        Task.detached(priority: .utility) { [weak self] in
            await self?.streamChunks(transferId: transferId, url: url, total: total, chunkSize: chunkSize, peerId: peerDeviceId)
        }
        return transferId
    }

    private func streamChunks(transferId: String, url: URL, total: Int, chunkSize: Int, peerId: String) async {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            await MainActor.run { self.markFailure(transferId, reason: "Open failed") }
            return
        }
        defer { try? handle.close() }
        for seq in 0..<total {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty && seq < total - 1 {
                await MainActor.run { self.markFailure(transferId, reason: "Read returned empty early") }
                return
            }
            let chunk = FileChunkPayload(transferId: transferId, sequence: seq, data: data)
            guard let json = try? JSONEncoder().encode(chunk) else {
                await MainActor.run { self.markFailure(transferId, reason: "Chunk encode failed") }
                return
            }
            await MainActor.run {
                self.sendToPeer?(peerId, .fileChunk, json)
                self.update(transferId) {
                    $0.chunksDone = seq + 1
                    $0.bytesTransferred += data.count
                }
            }
            // Tiny yield so a 1 GB file doesn't starve the main runloop.
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - Receiver

    public func handleOffer(_ payload: FileOfferPayload, from peerDeviceId: String, peerName: String) {
        let dst = Self.downloadsDir().appendingPathComponent(payload.name)
        let resolved = Self.uniqueDestination(dst)
        // Pre-create empty file we can write chunks into sequentially.
        try? FileManager.default.createDirectory(at: resolved.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: resolved.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: resolved) else {
            log.log(.error, "Cannot open \(resolved.path) for writing")
            sendToPeer?(peerDeviceId, .fileAck, encodeAck(payload.transferId, ok: false, reason: "Write open failed"))
            return
        }
        incomingHandles[payload.transferId] = handle
        incomingNextSeq[payload.transferId] = 0
        let t = Transfer(
            id: payload.transferId,
            direction: .incoming,
            peerDeviceId: peerDeviceId,
            peerName: peerName,
            fileName: payload.name,
            sizeBytes: payload.sizeBytes,
            bytesTransferred: 0,
            totalChunks: payload.totalChunks,
            chunksDone: 0,
            status: .active,
            startedAt: Date(),
            finishedAt: nil,
            errorMessage: nil,
            destinationURL: resolved,
            kind: payload.kind
        )
        transfers.insert(t, at: 0)
        log.log(.network, "Incoming \(payload.name) (\(payload.sizeBytes) B, kind=\(payload.kind ?? "file")) ← \(peerName) → \(resolved.path)")
    }

    public func handleChunk(_ payload: FileChunkPayload, from peerDeviceId: String) {
        guard let handle = incomingHandles[payload.transferId],
              let nextSeq = incomingNextSeq[payload.transferId] else {
            log.log(.error, "Chunk for unknown transfer \(payload.transferId)")
            return
        }
        if payload.sequence != nextSeq {
            log.log(.error, "Out-of-order chunk \(payload.sequence) (expected \(nextSeq)) — abort")
            try? handle.close()
            incomingHandles[payload.transferId] = nil
            incomingNextSeq[payload.transferId] = nil
            markFailure(payload.transferId, reason: "Out-of-order chunk")
            sendToPeer?(peerDeviceId, .fileAck, encodeAck(payload.transferId, ok: false, reason: "Out-of-order"))
            return
        }
        do {
            try handle.write(contentsOf: payload.data)
        } catch {
            log.log(.error, "Write failed: \(error)")
            markFailure(payload.transferId, reason: "Write failed")
            return
        }
        incomingNextSeq[payload.transferId] = nextSeq + 1
        update(payload.transferId) {
            $0.chunksDone = nextSeq + 1
            $0.bytesTransferred += payload.data.count
        }
        if let t = transfers.first(where: { $0.id == payload.transferId }),
           t.chunksDone >= t.totalChunks {
            try? handle.close()
            incomingHandles[payload.transferId] = nil
            incomingNextSeq[payload.transferId] = nil
            markCompleted(payload.transferId)
            sendToPeer?(peerDeviceId, .fileAck, encodeAck(payload.transferId, ok: true))
            if let updated = transfers.first(where: { $0.id == payload.transferId }),
               updated.direction == .incoming {
                onIncomingFileComplete?(updated)
            }
        }
    }

    public func handleAck(_ payload: FileAckPayload) {
        if payload.ok {
            markCompleted(payload.transferId)
        } else {
            markFailure(payload.transferId, reason: payload.failureReason ?? "Remote rejected")
        }
        if let updated = transfers.first(where: { $0.id == payload.transferId }),
           updated.direction == .outgoing {
            onOutgoingFileTerminal?(updated)
        }
    }

    public func clearCompleted() {
        transfers.removeAll { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }
    }

    // MARK: - Helpers

    private func update(_ id: String, _ mutate: (inout Transfer) -> Void) {
        guard let idx = transfers.firstIndex(where: { $0.id == id }) else { return }
        var copy = transfers[idx]
        mutate(&copy)
        transfers[idx] = copy
    }

    private func markCompleted(_ id: String) {
        update(id) {
            $0.status = .completed
            $0.finishedAt = Date()
        }
    }

    private func markFailure(_ id: String, reason: String) {
        update(id) {
            $0.status = .failed
            $0.errorMessage = reason
            $0.finishedAt = Date()
        }
    }

    private func encodeAck(_ transferId: String, ok: Bool, reason: String? = nil) -> Data {
        let ack = FileAckPayload(transferId: transferId, ok: ok, failureReason: reason)
        return (try? JSONEncoder().encode(ack)) ?? Data()
    }

    public static func downloadsDir() -> URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Entanglo")
    }

    /// If `url` exists, append " (1)", " (2)" … to the stem until free.
    private static func uniqueDestination(_ url: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        for n in 1..<1000 {
            let candidate = dir
                .appendingPathComponent("\(stem) (\(n))")
                .appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }
}
