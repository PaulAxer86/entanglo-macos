//
// filename: Coordinator+QuickActions.swift
// path: Entanglo/Entanglo/Services/Coordinator+QuickActions.swift
// purpose: ConnectionCoordinator methods for the quick-action LAN
//          features: URL push and screenshot push. These reuse the
//          existing outbound transports.
//

import Foundation

#if canImport(AppKit)
import AppKit
#endif

@MainActor
public extension ConnectionCoordinator {

    // MARK: URL push

    /// Push a URL to every connected trusted peer. Returns how many peers
    /// received it. The actual open happens on the receiver via NSWorkspace.
    @discardableResult
    func pushURL(_ url: String) -> Int {
        var sent = 0
        let payload = UrlPushPayload(url: url)
        for transport in connectedTransports() {
            transport.send(type: .urlPush, payload: payload)
            sent += 1
        }
        log.log(.network, "URL push to \(sent) peers: \(url)")
        return sent
    }

    func handleIncomingUrlPush(_ payload: UrlPushPayload, fromPeer peerId: String) {
        #if canImport(AppKit)
        guard let url = URL(string: payload.url) else {
            log.log(.error, "URL push payload malformed: \(payload.url)")
            return
        }
        let from = peerDisplayNamePublic(forDeviceId: peerId)
        log.log(.network, "Opening URL pushed by \(from): \(url.absoluteString)")
        NSWorkspace.shared.open(url)
        #endif
    }

    // MARK: Screenshot push

    /// Ask the peer for a full-screen snapshot. Result arrives async via
    /// pendingScreenshot. If the peer doesn't reply within
    /// `screenshotTimeoutSeconds`, the UI is unstuck with a clear error.
    static let screenshotTimeoutSeconds: UInt64 = 8

    func requestScreenshot(fromPeer peerId: String) {
        guard let transport = outbound[peerId] else {
            log.log(.error, "Screenshot: no outbound transport for \(peerId)")
            return
        }
        let id = UUID().uuidString
        pendingScreenshotRequests[id] = peerId
        screenshotInProgress = peerId
        lastScreenshotError = nil
        transport.send(type: .screenshotRequest, payload: ScreenshotRequestPayload(requestId: id))
        log.log(.network, "Screenshot requested from \(peerId)")

        // Sender-side safety net: if the receiver never replies (Screen
        // Recording denied + a bug in the receiver, payload dropped, old
        // peer version without the screenshot handler …) the Quick
        // Actions card stays in "Capturing…" forever. Clear the state
        // and surface a clear error after the timeout.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.screenshotTimeoutSeconds * 1_000_000_000)
            guard let self else { return }
            guard self.pendingScreenshotRequests[id] != nil else { return }
            self.pendingScreenshotRequests.removeValue(forKey: id)
            if self.screenshotInProgress == peerId { self.screenshotInProgress = nil }
            let name = self.peerDisplayNamePublic(forDeviceId: peerId)
            self.lastScreenshotError = "No reply from \(name) — check Screen Recording permission on that Mac."
            self.log.log(.error, "Screenshot timed out for \(peerId) after \(Self.screenshotTimeoutSeconds)s")
        }
    }

    func handleScreenshotRequest(_ payload: ScreenshotRequestPayload, fromTransport transport: NetworkTransport) {
        #if canImport(AppKit)
        let id = payload.requestId
        Task.detached(priority: .userInitiated) {
            let png = await ScreenshotCapturer.captureMainDisplayPNG()
            let result: ScreenshotResultPayload
            if let png = png {
                result = ScreenshotResultPayload(requestId: id, pngData: png, error: nil)
            } else {
                result = ScreenshotResultPayload(requestId: id, pngData: nil,
                                                 error: "capture failed — grant Screen Recording")
            }
            await MainActor.run {
                transport.send(type: .screenshotResult, payload: result)
            }
        }
        #else
        let result = ScreenshotResultPayload(requestId: payload.requestId, pngData: nil,
                                             error: "unsupported platform")
        transport.send(type: .screenshotResult, payload: result)
        #endif
    }

    func handleScreenshotResult(_ payload: ScreenshotResultPayload, fromPeer peerId: String) {
        pendingScreenshotRequests.removeValue(forKey: payload.requestId)
        if screenshotInProgress == peerId { screenshotInProgress = nil }
        if let err = payload.error {
            log.log(.error, "Screenshot from \(peerId) failed: \(err)")
            lastScreenshotError = err
            return
        }
        guard let png = payload.pngData else { return }
        let from = peerDisplayNamePublic(forDeviceId: peerId)
        lastScreenshot = ReceivedScreenshot(peerId: peerId, peerName: from,
                                            pngData: png, receivedAt: Date())
        log.log(.network, "Screenshot received from \(from): \(png.count) B")
    }

    // MARK: Helpers

    func connectedTransports() -> [NetworkTransport] {
        outbound.values.filter { $0.heartbeatAlive }
    }

    /// Publishes a short transient message shown under the Dashboard's Quick
    /// Actions card. Any previous message is superseded and the auto-clear
    /// timer is restarted so a fresh click doesn't inherit a stale countdown.
    func setQuickActionMessage(_ text: String, autoClearAfter seconds: UInt64 = 4) {
        lastQuickActionMessage = text
        quickActionMessageClearTask?.cancel()
        quickActionMessageClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if Task.isCancelled { return }
            self?.lastQuickActionMessage = nil
        }
    }

    func peerDisplayNamePublic(forDeviceId id: String) -> String {
        if let trusted = pairing.devices.first(where: { $0.id == id }) { return trusted.name }
        return id
    }
}

// MARK: - Shared state holders

public struct ReceivedScreenshot: Identifiable, Equatable, Sendable {
    public let peerId: String
    public let peerName: String
    public let pngData: Data
    public let receivedAt: Date
    public var id: String { "\(peerId)-\(Int(receivedAt.timeIntervalSince1970))" }
}
