//
// filename: AppState.swift
// path: Entanglo/Entanglo/AppState.swift
// purpose: Single ObservableObject that wires the services together,
//          exposes published values the SwiftUI views observe, and
//          persists user-toggleable settings to UserDefaults so they
//          survive relaunch.
//

import Foundation
import SwiftUI
import Combine

#if canImport(AppKit)
import AppKit
#endif
#if canImport(ServiceManagement)
import ServiceManagement
#endif

@MainActor
final class AppState: ObservableObject {

    // MARK: - Identity / settings
    @Published var localDeviceName: String
    @Published var localDeviceId: String
    @Published var enabledRoles: Set<EntangloRole>
    @Published var edgeConfig: EdgeSwitchConfig
    @Published var clipboardSyncEnabled: Bool
    @Published var preferEthernet: Bool
    @Published var allowWiFi: Bool
    @Published var manualIP: String
    @Published var hotkey: String
    @Published var sharingEnabled: Bool
    @Published var launchAtLoginEnabled: Bool
    @Published var runAsMenuBarApp: Bool
    @Published var keepAwakeWhilePaired: Bool
    @Published var printerBridgeEnabled: Bool
    @Published var printerSSID: String
    @Published var printerPassword: String
    @Published var printerQueue: String
    @Published var soundsEnabled: Bool

    // MARK: - Selection
    @Published var sidebarSelection: SidebarSection = .dashboard

    // MARK: - Services
    let log = AppLogService.shared
    let permissions = PermissionService()
    let pairing = PairingService()
    let discovery = DiscoveryService()
    let clipboard = ClipboardSyncService()
    let inputCapture = InputCaptureService()
    let inputInjection = InputInjectionService()
    let networkQuality = NetworkQualityMonitor()
    let fileTransfers = FileTransferService()
    let updates: UpdateService
    let lanScanner = LANScannerService()
    let printerBridge = PrinterBridgeService()
    let sounds = SoundService()
    private(set) var coordinator: ConnectionCoordinator!

    // MARK: - Live snapshots
    @Published var qualitySnapshot: NetworkQualitySnapshot?
    @Published var receiverHeartbeatAlive = false
    @Published var emergencyStopActive = false
    @Published var isRefreshing: Bool = false

    // MARK: - Mirrors of nested-service state (so SwiftUI re-renders)
    @Published var discoveredDevices: [Device] = []
    @Published var trustedDevices: [Device] = []
    @Published var isAdvertising = false
    @Published var isBrowsing = false
    @Published var connectionStates: [String: ConnectionMode] = [:]

    /// Mirror of coordinator.lastScreenshot so MainWindowView's sheet
    /// binding actually re-evaluates when the screenshot is set or
    /// cleared. Without this AppState wouldn't republish on coordinator
    /// changes and the Close button wouldn't dismiss the sheet.
    @Published var pendingScreenshot: ReceivedScreenshot?

    // MARK: - Install flow
    /// When the user clicks Install, we kick off pushes to peers and then
    /// open + quit. The UI watches this to show a modal progress sheet.
    @Published var installInFlight: InstallProgress?

    /// On the receiving Mac, after a peer-pushed DMG completes, the app
    /// runs a short cancellable countdown before the same auto-replace
    /// path is triggered.
    @Published var autoInstallCountdown: AutoInstallCountdown?

    struct InstallProgress: Equatable {
        var version: String
        var pendingTransferIds: Set<String>
        var totalPeers: Int
        var completedPeers: Int
        var failedPeers: Int
        var startedAt: Date
    }

    struct AutoInstallCountdown: Equatable {
        var version: String
        var peerName: String
        var secondsLeft: Int
        var startedAt: Date
    }

    private var autoInstallTimer: Timer?

    // 0 = let the kernel pick a free port. Bonjour publishes whatever the
    // listener was actually bound to, so peers always resolve the right port.
    // Picking a fixed port runs into TIME_WAIT on quick restarts.
    static let defaultListenPort: UInt16 = 0

    private var cancellables: Set<AnyCancellable> = []

    init() {
        let host = Host.current().localizedName ?? "Mac"
        let savedName = SettingsStore.shared.string(.deviceName)
        self.localDeviceName = (savedName?.isEmpty == false) ? savedName! : host
        self.localDeviceId = AppState.loadOrCreateDeviceId()

        // Update sources. The local dist/ folder is only useful when
        // running the dev build from inside the repo; the shared Updates
        // outbox is the release channel used by installed copies (Paolo
        // drops the freshly built DMG there and every Mac picks it up).
        var sources: [UpdateSource] = []
        let devDist = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("entanglo/Entanglo/dist")
        if FileManager.default.fileExists(atPath: devDist.path) {
            sources.append(LocalDistFolderSource(folder: devDist))
        }
        let outbox = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Entanglo/Updates")
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        sources.append(LocalDistFolderSource(folder: outbox))
        if let manifestURL = URL(string: "https://entanglo.pages.dev/updates/latest.json") {
            sources.append(RemoteHTTPSource(
                manifestURL: manifestURL,
                outbox: outbox,
                currentVersion: UpdateService.bundleVersion()
            ))
        }
        self.updates = UpdateService(sources: sources)

        // Hydrate every persisted setting up front. Defaults match what
        // used to be hard-coded in this initializer.
        self.enabledRoles = SettingsStore.shared.roles(default: [.controller])
        self.edgeConfig = SettingsStore.shared.codable(.edgeConfig, default: EdgeSwitchConfig(
            leftEdgeTargetId: nil,
            rightEdgeTargetId: nil,
            edgeThicknessPoints: 2,
            enabled: true
        ))
        self.clipboardSyncEnabled = SettingsStore.shared.bool(.clipboardSync, default: false)
        self.preferEthernet = SettingsStore.shared.bool(.preferEthernet, default: true)
        self.allowWiFi = SettingsStore.shared.bool(.allowWiFi, default: true)
        self.manualIP = SettingsStore.shared.string(.manualIP) ?? ""
        self.hotkey = SettingsStore.shared.string(.hotkey) ?? "Ctrl+Opt+Cmd+E"
        self.sharingEnabled = SettingsStore.shared.bool(.sharingEnabled, default: false)
        self.launchAtLoginEnabled = SettingsStore.shared.bool(.launchAtLogin, default: false)
        self.runAsMenuBarApp = SettingsStore.shared.bool(.runAsMenuBarApp, default: false)
        self.keepAwakeWhilePaired = SettingsStore.shared.bool(.keepAwakeWhilePaired, default: true)
        self.printerBridgeEnabled = SettingsStore.shared.bool(.printerBridgeEnabled, default: false)
        self.printerSSID = SettingsStore.shared.string(.printerSSID) ?? ""
        self.printerPassword = SettingsStore.shared.string(.printerPassword) ?? ""
        self.printerQueue = SettingsStore.shared.string(.printerQueue) ?? ""
        self.soundsEnabled = SettingsStore.shared.bool(.soundsEnabled, default: true)
        sounds.enabled = soundsEnabled

        permissions.refresh()
        clipboard.enabled = clipboardSyncEnabled
        inputCapture.edgeConfig = edgeConfig

        // MARK: - Persistence + side-effect sinks
        // Each `.dropFirst()` skips the value we just loaded from disk so
        // we don't immediately rewrite it.
        $clipboardSyncEnabled.dropFirst()
            .sink { [weak self] on in
                self?.clipboard.enabled = on
                SettingsStore.shared.setBool(.clipboardSync, on)
            }
            .store(in: &cancellables)
        $preferEthernet.dropFirst()
            .sink { SettingsStore.shared.setBool(.preferEthernet, $0) }
            .store(in: &cancellables)
        $allowWiFi.dropFirst()
            .sink { SettingsStore.shared.setBool(.allowWiFi, $0) }
            .store(in: &cancellables)
        $manualIP.dropFirst()
            .sink { SettingsStore.shared.setString(.manualIP, $0) }
            .store(in: &cancellables)
        $hotkey.dropFirst()
            .sink { SettingsStore.shared.setString(.hotkey, $0) }
            .store(in: &cancellables)
        $launchAtLoginEnabled.dropFirst()
            .sink { [weak self] on in
                SettingsStore.shared.setBool(.launchAtLogin, on)
                self?.applyLaunchAtLogin(on)
            }
            .store(in: &cancellables)
        $runAsMenuBarApp.dropFirst()
            .sink { on in
                SettingsStore.shared.setBool(.runAsMenuBarApp, on)
                #if canImport(AppKit)
                NSApp.setActivationPolicy(on ? .accessory : .regular)
                if !on {
                    NSApp.activate(ignoringOtherApps: true)
                }
                #endif
            }
            .store(in: &cancellables)
        $localDeviceName.dropFirst()
            .sink { SettingsStore.shared.setString(.deviceName, $0) }
            .store(in: &cancellables)
        $edgeConfig.dropFirst()
            .sink { [weak self] cfg in
                SettingsStore.shared.setCodable(.edgeConfig, cfg)
                self?.inputCapture.edgeConfig = cfg
            }
            .store(in: &cancellables)

        // Printer Bridge settings — mirror into the service so the
        // bridge picks up changes without needing a relaunch.
        printerBridge.bridgeEnabled = printerBridgeEnabled
        printerBridge.printerSSID = printerSSID
        printerBridge.printerPassword = printerPassword
        printerBridge.printerQueue = printerQueue
        $printerBridgeEnabled.dropFirst()
            .sink { [weak self] on in
                SettingsStore.shared.setBool(.printerBridgeEnabled, on)
                self?.printerBridge.bridgeEnabled = on
            }
            .store(in: &cancellables)
        $printerSSID.dropFirst()
            .sink { [weak self] v in
                SettingsStore.shared.setString(.printerSSID, v)
                self?.printerBridge.printerSSID = v
            }
            .store(in: &cancellables)
        $printerPassword.dropFirst()
            .sink { [weak self] v in
                SettingsStore.shared.setString(.printerPassword, v)
                self?.printerBridge.printerPassword = v
            }
            .store(in: &cancellables)
        $printerQueue.dropFirst()
            .sink { [weak self] v in
                SettingsStore.shared.setString(.printerQueue, v)
                self?.printerBridge.printerQueue = v
            }
            .store(in: &cancellables)
        $soundsEnabled.dropFirst()
            .sink { [weak self] on in
                SettingsStore.shared.setBool(.soundsEnabled, on)
                self?.sounds.enabled = on
            }
            .store(in: &cancellables)

        // Mirror nested-service publishers into AppState so any SwiftUI view
        // bound to `state.<x>` re-renders without having to observe the
        // nested objects directly.
        discovery.$discoveredDevices
            .receive(on: RunLoop.main)
            .assign(to: &$discoveredDevices)
        discovery.$isAdvertising
            .receive(on: RunLoop.main)
            .assign(to: &$isAdvertising)
        discovery.$isBrowsing
            .receive(on: RunLoop.main)
            .assign(to: &$isBrowsing)
        pairing.$devices
            .receive(on: RunLoop.main)
            .assign(to: &$trustedDevices)

        // Build the coordinator now that the supporting services are wired.
        coordinator = ConnectionCoordinator(
            localDeviceId: localDeviceId,
            localDeviceName: localDeviceName,
            discovery: discovery,
            pairing: pairing,
            permissions: permissions,
            capture: inputCapture,
            injection: inputInjection,
            clipboard: clipboard,
            fileTransfers: fileTransfers,
            log: log
        )
        coordinator.$connectionStates
            .receive(on: RunLoop.main)
            .assign(to: &$connectionStates)
        coordinator.$anyHeartbeatAlive
            .receive(on: RunLoop.main)
            .assign(to: &$receiverHeartbeatAlive)
        coordinator.$anyHeartbeatAlive
            .receive(on: RunLoop.main)
            .sink { [weak self] alive in self?.networkQuality.updateHeartbeat(alive: alive) }
            .store(in: &cancellables)
        // Audio cue on peer link transitions. `removeDuplicates()` keeps us
        // from re-firing on every heartbeat tick — only true → false or
        // false → true edges produce a sound. Suppress the very first
        // value (which is the launch-time `false`) so we don't yelp
        // "peer lost" before any pairing happened.
        coordinator.$anyHeartbeatAlive
            .receive(on: RunLoop.main)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] alive in
                self?.sounds.play(alive ? .peerBack : .peerLost)
            }
            .store(in: &cancellables)
        coordinator.$activeInterfaceKind
            .receive(on: RunLoop.main)
            .sink { [weak self] kind in self?.networkQuality.updateTransportInterface(kind) }
            .store(in: &cancellables)
        coordinator.$bestRttMs
            .receive(on: RunLoop.main)
            .sink { [weak self] ms in self?.networkQuality.updateLatency(ms) }
            .store(in: &cancellables)
        coordinator.$lastScreenshot
            .receive(on: RunLoop.main)
            .assign(to: &$pendingScreenshot)
        networkQuality.$snapshot
            .receive(on: RunLoop.main)
            .assign(to: &$qualitySnapshot)

        // Apply current role flags to the coordinator.
        coordinator.controllerRoleEnabled = enabledRoles.contains(.controller)
        coordinator.receiverRoleEnabled  = enabledRoles.contains(.receiver)
        coordinator.sharingEnabled       = sharingEnabled
        coordinator.keepAwakeWhilePaired = keepAwakeWhilePaired
        $keepAwakeWhilePaired
            .dropFirst()
            .sink { [weak self] on in
                self?.coordinator.keepAwakeWhilePaired = on
                SettingsStore.shared.setBool(.keepAwakeWhilePaired, on)
            }
            .store(in: &cancellables)
        $enabledRoles
            .dropFirst()
            .sink { [weak self] roles in
                self?.coordinator.controllerRoleEnabled = roles.contains(.controller)
                self?.coordinator.receiverRoleEnabled  = roles.contains(.receiver)
                SettingsStore.shared.setRoles(roles)
            }
            .store(in: &cancellables)
        $emergencyStopActive
            .sink { [weak self] flag in self?.coordinator.emergencyStopActive = flag }
            .store(in: &cancellables)
        $sharingEnabled
            .dropFirst()
            .sink { [weak self] on in
                self?.coordinator.sharingEnabled = on
                SettingsStore.shared.setBool(.sharingEnabled, on)
            }
            .store(in: &cancellables)

        // Start advertising + browsing automatically. Without this the app
        // would just sit there with an empty Devices list.
        // coordinator.start() must run first so its onIncomingConnection
        // callback is installed before the listener can accept anything.
        coordinator.start()
        startDiscovery()
        updates.start()
        lanScanner.start()
        applyLaunchAtLogin(launchAtLoginEnabled)
        registerGlobalHotkeys()
        wireUpdatePeerPush()
        startPermissionAutoPolling()
    }

    private var permissionPollTimer: Timer?

    /// Polls the system every 2.5 seconds and on every app-focus event so
    /// the Permissions UI updates as soon as the user grants in System
    /// Settings — no manual "Refresh permissions" click. Also re-arms the
    /// Bonjour browser/advertiser when Local Network flips so peer pushes
    /// (URL, screenshot) start arriving without restarting the app.
    private func startPermissionAutoPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPermissions() }
        }
        permissionPollTimer = timer
        #if canImport(AppKit)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pollPermissions() }
        }
        #endif
        pollPermissions()
    }

    private func pollPermissions() {
        let before = permissions.snapshot
        permissions.refresh()
        let after = permissions.snapshot
        if before.accessibility != after.accessibility ||
           before.inputMonitoring != after.inputMonitoring ||
           before.screenRecording != after.screenRecording {
            log.log(.app, "Permissions changed: ax=\(after.accessibility.rawValue) im=\(after.inputMonitoring.rawValue) sr=\(after.screenRecording.rawValue)")
        }
        // If discovery never came up (Local Network prompt was pending or
        // denied at launch), retry now that the user may have granted.
        if !isAdvertising || !isBrowsing {
            startDiscovery()
        }
    }

    private func wireUpdatePeerPush() {
        updates.wirePeerPush(coordinator: coordinator, fileTransfers: fileTransfers)
        // Receiver side: when a DMG arrives via FileTransferService, ask
        // UpdateService to evaluate it. If it really is a newer Entanglo
        // build, start the auto-install countdown.
        fileTransfers.onIncomingFileComplete = { [weak self] transfer in
            guard let self else { return }
            guard let url = transfer.destinationURL else { return }
            // Route by kind so a printJob doesn't accidentally get
            // evaluated as a DMG update and vice versa.
            if transfer.kind == "printJob" {
                self.printerBridge.submitIncomingPrintJob(fileURL: url, fromPeerName: transfer.peerName)
                return
            }
            self.updates.evaluateIncomingFile(url)
            if let update = self.updates.availableUpdate, update.url == url {
                self.scheduleAutoInstall(fromPeer: transfer.peerName, version: update.version)
                // DMG pushes get their own auto-install UI; no audio cue
                // so we don't double up with the countdown sheet.
            } else {
                self.sounds.play(.fileReceived)
            }
        }
        // Sender side: track outgoing terminal transitions for the install
        // progress modal. When every pending push has resolved, open the
        // local DMG and quit the app.
        fileTransfers.onOutgoingFileTerminal = { [weak self] transfer in
            self?.installTransferDidFinish(transfer)
        }
    }

    /// Called by UpdatesView's Install button. Pushes the available DMG
    /// to every connected peer, then auto-replaces this Mac's bundle and
    /// quits — chained via installTransferDidFinish so we wait for the
    /// pushes to complete first.
    func beginInstall(pushToPeers: Bool = true) {
        guard let update = updates.availableUpdate else { return }
        let ids = pushToPeers ? updates.pushUpdateToPeers() : []
        if ids.isEmpty {
            log.log(.app, "Install: no pushes — auto-replacing local bundle immediately")
            updates.performAutoReplaceAndQuit()
            return
        }
        installInFlight = InstallProgress(
            version: update.version,
            pendingTransferIds: Set(ids),
            totalPeers: ids.count,
            completedPeers: 0,
            failedPeers: 0,
            startedAt: Date()
        )
        log.log(.app, "Install: pushing \(ids.count) peer(s) before auto-replace")
    }

    private func installTransferDidFinish(_ transfer: FileTransferService.Transfer) {
        guard var progress = installInFlight,
              progress.pendingTransferIds.contains(transfer.id) else { return }
        progress.pendingTransferIds.remove(transfer.id)
        if transfer.status == .completed {
            progress.completedPeers += 1
        } else {
            progress.failedPeers += 1
        }
        installInFlight = progress
        if progress.pendingTransferIds.isEmpty {
            log.log(.app, "Install: pushes done (\(progress.completedPeers) ok, \(progress.failedPeers) failed) — auto-replacing")
            installInFlight = nil
            updates.performAutoReplaceAndQuit()
        }
    }

    func cancelInstallAndOpenLocal() {
        installInFlight = nil
        updates.performAutoReplaceAndQuit()
    }

    // MARK: - Auto-install countdown (receiver side)

    private func scheduleAutoInstall(fromPeer peerName: String, version: String) {
        cancelAutoInstall()
        autoInstallCountdown = AutoInstallCountdown(
            version: version, peerName: peerName, secondsLeft: 5, startedAt: Date()
        )
        // Make sure the user actually sees the countdown.
        sidebarSelection = .updates
        log.log(.app, "Auto-install scheduled: \(version) from \(peerName) in 5s")
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickAutoInstall() }
        }
        autoInstallTimer = timer
    }

    private func tickAutoInstall() {
        guard var auto = autoInstallCountdown else { return }
        auto.secondsLeft -= 1
        if auto.secondsLeft <= 0 {
            commitAutoInstallNow()
        } else {
            autoInstallCountdown = auto
        }
    }

    func commitAutoInstallNow() {
        cancelAutoInstallTimer()
        autoInstallCountdown = nil
        log.log(.app, "Auto-install: committing replace-and-relaunch now")
        // No peer push — this Mac received the DMG from a peer.
        beginInstall(pushToPeers: false)
    }

    func cancelAutoInstall() {
        cancelAutoInstallTimer()
        if autoInstallCountdown != nil {
            log.log(.app, "Auto-install cancelled by user")
        }
        autoInstallCountdown = nil
    }

    private func cancelAutoInstallTimer() {
        autoInstallTimer?.invalidate()
        autoInstallTimer = nil
    }

    private func registerGlobalHotkeys() {
        GlobalHotkeyManager.shared.register(.urlPush) { [weak self] in
            self?.pushCurrentURLToPeers()
        }
        GlobalHotkeyManager.shared.register(.screenshotPush) { [weak self] in
            self?.requestPeerScreenshot()
        }
    }

    /// Reads a URL from the clipboard, or falls back to the active browser
    /// via AppleScript, then pushes to every connected trusted peer.
    func pushCurrentURLToPeers() {
        guard let url = URLGrabber.grab() else {
            log.log(.app, "URL push: no URL available (clipboard not a URL, browser not Safari/Chrome)")
            coordinator.setQuickActionMessage("No link to send — copy a URL or focus a browser tab first.")
            return
        }
        let n = coordinator.pushURL(url)
        log.log(.app, "URL push → \(n) peer(s): \(url)")
        if n == 0 {
            coordinator.setQuickActionMessage("No peer online — nothing to send the URL to.")
        } else {
            coordinator.setQuickActionMessage("URL sent to \(n) peer\(n == 1 ? "" : "s").")
        }
    }

    /// Fallback used by the ⌘⇧S global shortcut when no explicit peer is
    /// picked — targets the first connected peer. The Dashboard's Quick
    /// Actions card now offers a per-peer picker menu (see
    /// `requestScreenshot(fromPeerId:)`) so multi-peer setups are
    /// unambiguous about which Mac gets captured.
    func requestPeerScreenshot() {
        guard let firstPeer = coordinator.outbound.keys.first else {
            log.log(.app, "Screenshot: no connected peer")
            coordinator.setQuickActionMessage("No peer online — nothing to capture.")
            return
        }
        coordinator.requestScreenshot(fromPeer: firstPeer)
    }

    /// Explicit-peer screenshot request used by the Quick Actions picker.
    /// Kept separate from `requestPeerScreenshot()` so the global-shortcut
    /// path (which cannot show a menu) keeps its "first-peer" behavior.
    func requestScreenshot(fromPeerId peerId: String) {
        guard coordinator.outbound[peerId] != nil else {
            log.log(.app, "Screenshot: peer \(peerId) not connected")
            coordinator.setQuickActionMessage("That peer is not connected right now.")
            return
        }
        coordinator.requestScreenshot(fromPeer: peerId)
    }

    func startDiscovery() {
        discovery.startAdvertising(name: localDeviceName, port: Self.defaultListenPort)
        discovery.startBrowsing()
    }

    func startSharing() { sharingEnabled = true }
    func stopSharing()  { sharingEnabled = false }

    // MARK: - Helpers

    func refreshPermissions() {
        permissions.refresh()
    }

    /// Runs all refresh actions and toggles `isRefreshing` so the UI
    /// can show a spinner. The minimum visible duration makes the
    /// spinner perceptible even when every check is instant.
    func refreshAll() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            let started = Date()
            permissions.refresh()
            let minVisible: TimeInterval = 0.4
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < minVisible {
                try? await Task.sleep(nanoseconds: UInt64((minVisible - elapsed) * 1_000_000_000))
            }
            isRefreshing = false
        }
    }

    func toggleRole(_ role: EntangloRole) {
        if enabledRoles.contains(role) {
            enabledRoles.remove(role)
        } else {
            enabledRoles.insert(role)
        }
    }

    // MARK: - Persistence of the local device ID

    private static func loadOrCreateDeviceId() -> String {
        let key = "EntangloLocalDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    // MARK: - Login Item

    func applyLaunchAtLogin(_ enabled: Bool) {
        #if canImport(ServiceManagement)
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                log.log(.error, "Login Item toggle failed: \(error.localizedDescription)")
            }
        }
        #endif
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard, devices, inputSharing, files, print, network, updates, settings, logs
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dashboard:       return "Dashboard"
        case .devices:         return "Devices"
        case .inputSharing:    return "Input Sharing"
        case .files:           return "Files"
        case .print:           return "Print"
        case .network:         return "Network"
        case .updates:         return "News & Updates"
        case .settings:        return "Settings"
        case .logs:            return "Logs"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard:       return "rectangle.3.group"
        case .devices:         return "macbook.and.iphone"
        case .inputSharing:    return "keyboard"
        case .files:           return "arrow.up.arrow.down.circle"
        case .print:           return "printer"
        case .network:         return "network"
        case .updates:         return "shippingbox"
        case .settings:        return "gearshape"
        case .logs:            return "doc.text"
        }
    }

    enum Group { case tools, utilities }
    var group: Group {
        switch self {
        case .dashboard, .devices, .inputSharing, .files, .print: return .tools
        case .network, .updates, .settings, .logs:                return .utilities
        }
    }
}
