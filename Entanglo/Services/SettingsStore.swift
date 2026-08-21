//
// filename: SettingsStore.swift
// path: Entanglo/Entanglo/Services/SettingsStore.swift
// purpose: Thin typed wrapper over UserDefaults so AppState can persist
//          user-toggleable settings without scattering string keys.
//

import Foundation

final class SettingsStore {
    static let shared = SettingsStore()

    enum Key: String {
        case deviceName = "EntangloDeviceName"
        case roles = "EntangloEnabledRoles"
        case edgeConfig = "EntangloEdgeConfig"
        case clipboardSync = "EntangloClipboardSync"
        case preferEthernet = "EntangloPreferEthernet"
        case allowWiFi = "EntangloAllowWiFi"
        case manualIP = "EntangloManualIP"
        case hotkey = "EntangloHotkey"
        case sharingEnabled = "EntangloSharingEnabled"
        case launchAtLogin = "EntangloLaunchAtLogin"
        case runAsMenuBarApp = "EntangloRunAsMenuBarApp"
        case keepAwakeWhilePaired = "EntangloKeepAwakeWhilePaired"
        case printerBridgeEnabled = "EntangloPrinterBridgeEnabled"
        case printerSSID = "EntangloPrinterSSID"
        case printerPassword = "EntangloPrinterPassword"
        case printerQueue = "EntangloPrinterQueue"
        case soundsEnabled = "EntangloSoundsEnabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Primitives

    func bool(_ key: Key, default fallback: Bool) -> Bool {
        if defaults.object(forKey: key.rawValue) == nil { return fallback }
        return defaults.bool(forKey: key.rawValue)
    }

    func setBool(_ key: Key, _ value: Bool) {
        defaults.set(value, forKey: key.rawValue)
    }

    func string(_ key: Key) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    func setString(_ key: Key, _ value: String) {
        defaults.set(value, forKey: key.rawValue)
    }

    // MARK: - Codable

    func codable<T: Codable>(_ key: Key, default fallback: T) -> T {
        guard let data = defaults.data(forKey: key.rawValue),
              let decoded = try? JSONDecoder().decode(T.self, from: data) else {
            return fallback
        }
        return decoded
    }

    func setCodable<T: Codable>(_ key: Key, _ value: T) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key.rawValue)
        }
    }

    // MARK: - Roles

    func roles(default fallback: Set<EntangloRole>) -> Set<EntangloRole> {
        guard let raw = defaults.array(forKey: Key.roles.rawValue) as? [String] else {
            return fallback
        }
        return Set(raw.compactMap(EntangloRole.init(rawValue:)))
    }

    func setRoles(_ roles: Set<EntangloRole>) {
        defaults.set(roles.map(\.rawValue), forKey: Key.roles.rawValue)
    }
}
