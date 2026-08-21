//
// filename: PairingService.swift
// path: Entanglo/Entanglo/Services/PairingService.swift
// purpose: Owns the 5-state pairing machine, manages the 6-digit PIN flow,
//          and persists the trusted-device list to Application Support.
//          Pure-logic core; UI binds via the published `devices` array.
//

import Foundation
#if canImport(Combine)
import Combine
#endif

public struct PairingPIN: Equatable, Sendable {
    public let value: String      // 6 digits
    public let createdAt: Date
    public let expiresAt: Date

    public init(value: String, createdAt: Date = Date(), ttl: TimeInterval = 120) {
        self.value = value
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(ttl)
    }

    public var isExpired: Bool { Date() > expiresAt }

    public static func random(now: Date = Date()) -> PairingPIN {
        var rng = SystemRandomNumberGenerator()
        let n = UInt32.random(in: 0..<1_000_000, using: &rng)
        let value = String(format: "%06u", n)
        return PairingPIN(value: value, createdAt: now)
    }
}

public enum PairingError: Error, Equatable {
    case illegalTransition(from: PairingState, to: PairingState)
    case unknownDevice(String)
    case pinExpired
    case pinMismatch
    case deviceBlocked
}

public final class PairingService: ObservableObject {
    @Published public private(set) var devices: [Device] = []

    /// Pending PINs keyed by deviceId. Only relevant when a peer is
    /// currently in `.pinRequired`.
    private var pendingPINs: [String: PairingPIN] = [:]

    private let storageURL: URL?

    public init(storageURL: URL? = PairingService.defaultStorageURL()) {
        self.storageURL = storageURL
        self.devices = (try? Self.loadDevices(from: storageURL)) ?? []
    }

    // MARK: - Lookup

    public func device(id: String) -> Device? {
        devices.first(where: { $0.id == id })
    }

    public func isTrusted(_ id: String) -> Bool {
        device(id: id)?.pairing == .trusted
    }

    // MARK: - Mutation

    /// Upserts a freshly-discovered device into the registry without
    /// changing its pairing state if it already exists.
    public func observe(_ device: Device) {
        if let idx = devices.firstIndex(where: { $0.id == device.id }) {
            var merged = devices[idx]
            merged.name = device.name
            merged.hostName = device.hostName
            merged.ipAddress = device.ipAddress
            merged.port = device.port
            merged.iface = device.iface
            merged.lastSeen = Date()
            merged.connection = device.connection
            merged.appVersion = device.appVersion
            devices[idx] = merged
        } else {
            devices.append(device)
        }
        persist()
    }

    /// Attempts the given transition, throws if it is not legal for the
    /// device's current state. The returned new state is also written to
    /// disk if persistence is enabled.
    @discardableResult
    public func transition(deviceId: String, to next: PairingState) throws -> PairingState {
        guard let idx = devices.firstIndex(where: { $0.id == deviceId }) else {
            throw PairingError.unknownDevice(deviceId)
        }
        let current = devices[idx].pairing
        guard current.canTransition(to: next) else {
            throw PairingError.illegalTransition(from: current, to: next)
        }
        if devices[idx].pairing == .blocked && next != .notPaired {
            throw PairingError.deviceBlocked
        }
        devices[idx].pairing = next
        persist()
        return next
    }

    /// Generates a PIN for a device that is moving into pinRequired, and
    /// stores it server-side so the UI can show it. The PIN is the
    /// secret the *other* peer must type.
    @discardableResult
    public func requirePIN(forDevice deviceId: String, now: Date = Date()) throws -> PairingPIN {
        try transition(deviceId: deviceId, to: .pinRequired)
        let pin = PairingPIN.random(now: now)
        pendingPINs[deviceId] = pin
        return pin
    }

    public func pendingPIN(for deviceId: String) -> PairingPIN? {
        pendingPINs[deviceId]
    }

    /// Validates a user-entered PIN. On success, moves the device to
    /// `.trusted` and clears the pending PIN.
    public func validatePIN(_ entered: String, forDevice deviceId: String) throws {
        guard let pin = pendingPINs[deviceId] else {
            throw PairingError.pinMismatch
        }
        if pin.isExpired {
            pendingPINs.removeValue(forKey: deviceId)
            throw PairingError.pinExpired
        }
        guard pin.value == entered else {
            throw PairingError.pinMismatch
        }
        try transition(deviceId: deviceId, to: .trusted)
        pendingPINs.removeValue(forKey: deviceId)
    }

    public func block(deviceId: String) throws {
        try transition(deviceId: deviceId, to: .blocked)
        pendingPINs.removeValue(forKey: deviceId)
    }

    public func revokeTrust(deviceId: String) throws {
        try transition(deviceId: deviceId, to: .notPaired)
    }

    /// Removes the device entry entirely (not just demoting pairing state).
    /// Use this to evict stale discovery ghosts — renamed Macs, loopback
    /// self-discovery from a previous LocalHostName, etc.
    public func forget(deviceId: String) {
        devices.removeAll { $0.id == deviceId }
        pendingPINs.removeValue(forKey: deviceId)
        persist()
    }

    /// Wipes every saved device. Intended for a manual fresh-start from
    /// the Devices page, behind a confirmation prompt.
    public func forgetAll() {
        devices.removeAll()
        pendingPINs.removeAll()
        persist()
    }

    // MARK: - Persistence

    public static func defaultStorageURL() -> URL? {
        let fm = FileManager.default
        guard let base = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("Entanglo", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("devices.json")
    }

    private static func loadDevices(from url: URL?) throws -> [Device] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var devices = try JSONDecoder().decode([Device].self, from: data)
        // `connection` is a runtime signal — the ConnectionCoordinator will
        // republish it on transport state changes. Wipe on load so a stale
        // "connected" from a previous session doesn't lie in the UI.
        for i in devices.indices { devices[i].connection = .discovered }
        return devices
    }

    private func persist() {
        guard let url = storageURL else { return }
        do {
            let data = try JSONEncoder().encode(devices)
            try data.write(to: url, options: .atomic)
        } catch {
            // Persistence failure is non-fatal — surface via AppLog in the
            // app layer if needed.
        }
    }
}
