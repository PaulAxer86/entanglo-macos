//
// filename: ClipboardSyncService.swift
// path: Entanglo/Entanglo/Services/ClipboardSyncService.swift
// purpose: OPT-IN, OFF BY DEFAULT plain-text clipboard sync between
//          trusted devices. Never syncs silently.
//

import Foundation

#if canImport(AppKit)
import AppKit
#endif
#if canImport(Combine)
import Combine
#endif

public final class ClipboardSyncService {
    public var enabled: Bool = false {
        didSet { enabled ? startPolling() : stopPolling() }
    }

    /// Called with text to send to all currently-trusted peers.
    public var onLocalChange: ((String) -> Void)?

    private let log: AppLogService
    private var timer: Timer?
    private var lastSeenChangeCount: Int = -1

    public init(log: AppLogService = .shared) { self.log = log }

    public func apply(remoteText text: String) {
        guard enabled else { return }
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastSeenChangeCount = pb.changeCount
        log.log(.network, "Clipboard updated from remote (\(text.count) chars)")
        #endif
    }

    private func startPolling() {
        #if canImport(AppKit)
        lastSeenChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        #endif
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        guard pb.changeCount != lastSeenChangeCount else { return }
        lastSeenChangeCount = pb.changeCount
        if let s = pb.string(forType: .string) {
            log.log(.network, "Clipboard changed locally (\(s.count) chars) — forwarding")
            onLocalChange?(s)
        }
        #endif
    }
}
