//
// filename: ConnectionCoordinator.swift
// path: Entanglo/Entanglo/Services/ConnectionCoordinator.swift
// purpose: Brokers TCP sessions between this Mac and every trusted
//          peer. Owns one outbound NetworkTransport per trusted device
//          (dialed when an endpoint is known) plus a set of inbound
//          transports accepted from the listener. Routes captured
//          InputEventMessage from InputCaptureService → outbound
//          transport, and decoded InputEventMessage from any transport
//          → InputInjectionService, after refreshing the safety gate.
//

import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(Network)
import Network
#endif

@MainActor
public final class ConnectionCoordinator: ObservableObject {

    // MARK: - Inputs

    private let localDeviceId: String
    private let localDeviceName: String
    private let discovery: DiscoveryService
    let pairing: PairingService
    private let permissions: PermissionService
    private let capture: InputCaptureService
    private let injection: InputInjectionService
    private let clipboard: ClipboardSyncService
    private let fileTransfers: FileTransferService
    let log: AppLogService
    private let idleSleepGuard = IdleSleepGuardService()

    // MARK: - Quick-action state (URL push, screenshot)
    @Published public internal(set) var lastScreenshot: ReceivedScreenshot?
    @Published public internal(set) var lastScreenshotError: String?
    @Published public internal(set) var screenshotInProgress: String?
    /// Transient status shown under the Quick Actions card — success ("URL sent to 2 peers")
    /// or a soft warning ("No link to send — copy a URL first."). Auto-clears after 4 s.
    @Published public internal(set) var lastQuickActionMessage: String?
    var quickActionMessageClearTask: Task<Void, Never>?
    var pendingScreenshotRequests: [String: String] = [:]   // requestId -> peerId

    // MARK: - State

    /// Outbound transports we dialed, keyed by the remote Bonjour device id.
    @Published public private(set) var outbound: [String: NetworkTransport] = [:]
    /// Inbound transports accepted from the listener (no key until we have
    /// matching outbound for the same peer). Used only for RX → injection.
    private var inbound: [ObjectIdentifier: NetworkTransport] = [:]
    /// Per-device last reported connection state for the UI.
    @Published public private(set) var connectionStates: [String: ConnectionMode] = [:]
    /// Throttle map for the "edge switch blocked" log — one line per
    /// device every 5 s while the user keeps grinding the mouse into an
    /// edge that points at an offline peer.
    private var lastEdgeBlockLogAt: [String: Date] = [:]
    /// True if any transport's heartbeat is currently alive.
    @Published public private(set) var anyHeartbeatAlive: Bool = false
    /// Interface kind of the freshest live transport. `.unknown` while
    /// nothing is connected.
    @Published public private(set) var activeInterfaceKind: NetworkInterfaceKind = .unknown
    /// Best (lowest) RTT across live transports, measured via the
    /// heartbeat echo. nil until at least one round-trip completes.
    @Published public private(set) var bestRttMs: Double?

    /// Set by the AppState whenever the global emergency-stop flag changes.
    public var emergencyStopActive: Bool = false { didSet { refreshGate(); evaluateIdleGuard() } }
    /// User preference: keep this Mac (and its display) awake while a
    /// trusted peer is connected. When false, normal Energy Saver wins.
    public var keepAwakeWhilePaired: Bool = true { didSet { evaluateIdleGuard() } }
    /// Whether this Mac has opted in to receive remote input.
    public var receiverRoleEnabled: Bool = false { didSet { refreshGate(); updateLocalInputWatcher() } }
    /// Whether this Mac has opted in to send local input.
    public var controllerRoleEnabled: Bool = false { didSet { refreshGate(); applyCaptureRunning() } }
    /// Globally toggles sharing on/off.
    public var sharingEnabled: Bool = false { didSet { applyCaptureRunning(); reconcile() } }

    private var transportDelegates: [TransportBridge] = []
    private var captureBridge: CaptureBridge?
    private var cancellables: Set<AnyCancellable> = []
    private let localInputWatcher = LocalInputWatcher()
    /// Devices for which we've already tried a Wi-Fi → Ethernet upgrade on
    /// the current session. Prevents a reconcile loop if Bonjour keeps
    /// advertising both interfaces but Ethernet dialing fails (link down,
    /// firewall). Reset when the session ends so a fresh reconnect can
    /// try again.
    private var wiredUpgradeAttempted: Set<String> = []

    // MARK: - Init

    public init(
        localDeviceId: String,
        localDeviceName: String,
        discovery: DiscoveryService,
        pairing: PairingService,
        permissions: PermissionService,
        capture: InputCaptureService,
        injection: InputInjectionService,
        clipboard: ClipboardSyncService,
        fileTransfers: FileTransferService,
        log: AppLogService = .shared
    ) {
        self.localDeviceId = localDeviceId
        self.localDeviceName = localDeviceName
        self.discovery = discovery
        self.pairing = pairing
        self.permissions = permissions
        self.capture = capture
        self.injection = injection
        self.clipboard = clipboard
        self.fileTransfers = fileTransfers
        self.log = log
    }

    // MARK: - Lifecycle

    public func start() {
        #if canImport(Network)
        discovery.onIncomingConnection = { [weak self] conn in
            Task { @MainActor in self?.handleIncoming(conn) }
        }
        #endif
        let cb = CaptureBridge(owner: self)
        captureBridge = cb
        capture.delegate = cb
        localInputWatcher.onLocalInput = { [weak self] in
            Task { @MainActor in self?.handleLocalInputWhileReceiving() }
        }
        // Broadcast local clipboard changes to every trusted peer.
        clipboard.onLocalChange = { [weak self] text in
            Task { @MainActor in self?.broadcastClipboard(text) }
        }
        // File transfer service speaks to peers through us — we're the
        // only thing that knows the outbound[peerId] mapping.
        fileTransfers.sendToPeer = { [weak self] peerId, type, json in
            Task { @MainActor in self?.sendRawToPeer(peerId, type: type, json: json) }
        }
        // Re-evaluate dialing whenever trust or discovery changes.
        pairing.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        discovery.$discoveredDevices
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &cancellables)
        permissions.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshGate() }
            .store(in: &cancellables)
        refreshGate()
        reconcile()
    }

    public func stop() {
        for t in outbound.values { t.disconnect() }
        outbound.removeAll()
        for t in inbound.values { t.disconnect() }
        inbound.removeAll()
        connectionStates.removeAll()
        anyHeartbeatAlive = false
        capture.stop()
        capture.delegate = nil
        localInputWatcher.stop()
        cancellables.removeAll()
        refreshGate()
        idleSleepGuard.release()
    }

    // MARK: - Dialing / accepting

    /// Walks the trusted-devices list and:
    ///   1. dials any trusted peer that has a known endpoint but no live
    ///      transport yet, and
    ///   2. upgrades a Wi-Fi transport to Ethernet once the peer's
    ///      wiredEthernet interface shows up on Bonjour.
    ///
    /// The upgrade path exists because Bonjour resolves each browser
    /// result's interface list incrementally: on a dual-homed peer we
    /// almost always see `.wifi` on the first `browseResultsChanged`
    /// callback and `.wiredEthernet` a few hundred ms later. Without
    /// this second pass we'd dial on Wi-Fi and stay there for the entire
    /// session even though the cable is available — which was Paolo's
    /// original complaint (Dashboard reported Wi-Fi/25 ms even after
    /// setting up direct ethernet at 0.7 ms).
    public func reconcile() {
        #if canImport(Network)
        for device in pairing.devices where device.pairing == .trusted {
            guard let endpoint = discovery.endpoint(forDeviceId: device.id) else { continue }
            let types = discovery.interfaceTypes(forDeviceId: device.id)
            let wiredAvailable = types.contains(.wiredEthernet)
            if let existing = outbound[device.id] {
                if wiredAvailable
                    && existing.interfaceKind != .ethernet
                    && !wiredUpgradeAttempted.contains(device.id) {
                    wiredUpgradeAttempted.insert(device.id)
                    log.log(.network,
                            "Upgrading \(device.id) from \(existing.interfaceKind) → wiredEthernet")
                    outbound[device.id] = nil
                    existing.disconnect()
                    dial(deviceId: device.id, endpoint: endpoint)
                }
                continue
            }
            dial(deviceId: device.id, endpoint: endpoint)
        }
        #endif
    }

    #if canImport(Network)
    private func dial(deviceId: String, endpoint: NWEndpoint) {
        let transport = makeTransport()
        let bridge = bind(transport, deviceId: deviceId)
        transportDelegates.append(bridge)
        outbound[deviceId] = transport
        connectionStates[deviceId] = .connecting
        // Pin the socket to a wired path when the peer is advertised on
        // one. Ethernet / Thunderbolt is dramatically more stable than
        // Wi-Fi (heartbeats hold, big fileChunks flush inside the 3 s
        // window) and if we let Network.framework auto-pick it will
        // sometimes settle on Wi-Fi even when Ethernet is available.
        // Passing `requiredInterfaceType` also prevents mid-session
        // fallback to Wi-Fi — the requirement Paolo asked for: if a peer
        // is on cable, we stay on cable, never silently downgrade.
        let types = discovery.interfaceTypes(forDeviceId: deviceId)
        let pin: NWInterface.InterfaceType? = types.contains(.wiredEthernet) ? .wiredEthernet : nil
        log.log(.network, "Dialing \(deviceId) at \(endpoint)\(pin == nil ? "" : " [pinned to wiredEthernet]")")
        transport.connect(to: endpoint, requiredInterface: pin)
        sendLocalHello(on: transport)
    }

    private func handleIncoming(_ connection: NWConnection) {
        let transport = makeTransport()
        let bridge = bind(transport, deviceId: nil)
        transportDelegates.append(bridge)
        inbound[ObjectIdentifier(transport)] = transport
        log.log(.network, "Accepting inbound connection \(connection.endpoint)")
        transport.accept(connection)
        sendLocalHello(on: transport)
        updateLocalInputWatcher()
    }
    #endif

    private func makeTransport() -> NetworkTransport {
        NetworkTransport(localDeviceId: localDeviceId, log: log)
    }

    private func sendLocalHello(on transport: NetworkTransport) {
        var roles: [EntangloRole] = []
        if controllerRoleEnabled { roles.append(.controller) }
        if receiverRoleEnabled { roles.append(.receiver) }
        if roles.isEmpty { roles = [.controller] }
        let payload = HelloPayload(
            deviceName: localDeviceName,
            deviceModel: Self.deviceModelIdentifier(),
            appVersion: Self.appVersion(),
            roles: roles,
            platform: "macOS"
        )
        transport.send(type: .hello, payload: payload)
    }

    private static func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private static func deviceModelIdentifier() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let value = String(cString: model)
        return value.isEmpty ? "Mac" : value
    }

    private func bind(_ transport: NetworkTransport, deviceId: String?) -> TransportBridge {
        let bridge = TransportBridge(owner: self, deviceId: deviceId, transport: transport)
        transport.delegate = bridge
        transport.$interfaceKind
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeActiveInterface() }
            .store(in: &cancellables)
        transport.$lastRttMs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeBestRtt() }
            .store(in: &cancellables)
        return bridge
    }

    private func recomputeBestRtt() {
        let live = (outbound.values.map { $0 } + inbound.values.map { $0 })
            .filter { $0.heartbeatAlive }
            .compactMap { $0.lastRttMs }
        let best = live.min()
        if best != bestRttMs { bestRttMs = best }
    }

    private func recomputeActiveInterface() {
        // Prefer outbound (we picked the endpoint) over inbound. Pick the
        // first transport whose path has resolved to something concrete.
        let candidates = outbound.values.map { $0 } + inbound.values.map { $0 }
        let kind = candidates.first(where: { $0.interfaceKind != .unknown })?.interfaceKind ?? .unknown
        if kind != activeInterfaceKind { activeInterfaceKind = kind }
    }

    // MARK: - RX / TX

    fileprivate func deliver(envelope: EntangloMessage, from transport: NetworkTransport) {
        switch envelope.messageType {
        case .hello:
            do {
                let payload = try MessageCodec.decodePayload(envelope, as: HelloPayload.self)
                let id = knownDeviceId(for: transport) ?? envelope.senderDeviceId
                let device = Device(
                    id: id,
                    name: payload.deviceName,
                    roles: Set(payload.roles),
                    pairing: pairing.device(id: id)?.pairing ?? .notPaired,
                    connection: .connected,
                    iface: transport.interfaceKind == .unknown
                        ? NetworkInterfaceInfo(kind: .unknown, name: payload.platform ?? "unknown")
                        : NetworkInterfaceInfo(kind: transport.interfaceKind, name: payload.platform ?? "network"),
                    lastSeen: Date(),
                    appVersion: payload.appVersion
                )
                pairing.observe(device)
                log.log(.network, "Hello from \(payload.deviceName) (\(payload.platform ?? "unknown")) id=\(envelope.senderDeviceId)")
            } catch {
                log.log(.error, "Bad Hello payload: \(error)")
            }
        case .inputEvent:
            do {
                let event = try MessageCodec.decodePayload(envelope, as: InputEventMessage.self)
                injection.inject(event)
            } catch {
                log.log(.error, "Bad InputEvent payload: \(error)")
            }
        case .clipboardText:
            do {
                let payload = try MessageCodec.decodePayload(envelope, as: ClipboardTextPayload.self)
                clipboard.apply(remoteText: payload.text)
            } catch {
                log.log(.error, "Bad ClipboardText payload: \(error)")
            }
        case .releaseControl:
            // The remote receiver detected local input — drop our cursor
            // back to the local Mac so we don't keep blindly forwarding.
            log.log(.input, "Remote requested control release — returning to local")
            capture.currentTargetDeviceId = nil
        case .fileOffer:
            do {
                let payload = try MessageCodec.decodePayload(envelope, as: FileOfferPayload.self)
                let name = peerDisplayName(forDeviceId: envelope.senderDeviceId)
                fileTransfers.handleOffer(payload, from: envelope.senderDeviceId, peerName: name)
            } catch {
                log.log(.error, "Bad FileOffer payload: \(error)")
            }
        case .fileChunk:
            do {
                let payload = try MessageCodec.decodePayload(envelope, as: FileChunkPayload.self)
                fileTransfers.handleChunk(payload, from: envelope.senderDeviceId)
            } catch {
                log.log(.error, "Bad FileChunk payload: \(error)")
            }
        case .fileAck:
            do {
                let payload = try MessageCodec.decodePayload(envelope, as: FileAckPayload.self)
                fileTransfers.handleAck(payload)
            } catch {
                log.log(.error, "Bad FileAck payload: \(error)")
            }
        case .heartbeat:
            break
        case .urlPush:
            do {
                let payload = try MessageCodec.decodePayload(envelope, as: UrlPushPayload.self)
                handleIncomingUrlPush(payload, fromPeer: envelope.senderDeviceId)
            } catch {
                log.log(.error, "Bad UrlPush payload: \(error)")
            }
        case .screenshotRequest:
            do {
                let payload = try MessageCodec.decodePayload(envelope, as: ScreenshotRequestPayload.self)
                handleScreenshotRequest(payload, fromTransport: transport)
            } catch {
                log.log(.error, "Bad ScreenshotRequest payload: \(error)")
            }
        case .screenshotResult:
            do {
                let payload = try MessageCodec.decodePayload(envelope, as: ScreenshotResultPayload.self)
                handleScreenshotResult(payload, fromPeer: envelope.senderDeviceId)
            } catch {
                log.log(.error, "Bad ScreenshotResult payload: \(error)")
            }
        default:
            break
        }
    }

    private func knownDeviceId(for transport: NetworkTransport) -> String? {
        outbound.first(where: { $0.value === transport })?.key
    }

    private func sendRawToPeer(_ peerId: String, type: MessageType, json: Data) {
        guard let transport = outbound[peerId] else {
            log.log(.error, "sendRaw to \(peerId) but no outbound transport")
            return
        }
        transport.sendRaw(type: type, payloadJSON: json)
    }

    private func peerDisplayName(forDeviceId id: String) -> String {
        if let trusted = pairing.devices.first(where: { $0.id == id }) { return trusted.name }
        return id
    }

    /// Called when LocalInputWatcher observes user input on this Mac.
    /// If a peer is currently controlling us we send a releaseControl
    /// message so the peer stops forwarding events. We also reset our
    /// own injection state so the next stale absolute position from the
    /// peer doesn't snap the cursor.
    private func handleLocalInputWhileReceiving() {
        guard !inbound.isEmpty else { return }
        let payload = ReleaseControlPayload()
        for t in inbound.values {
            t.send(type: .releaseControl, payload: payload)
        }
        log.log(.input, "Local input detected — asked peer to release control")
    }

    private func updateLocalInputWatcher() {
        // Only watch when we're acting as a receiver AND something is
        // actually connected. Avoids running the monitor whenever the
        // app is idle.
        if receiverRoleEnabled && !inbound.isEmpty {
            localInputWatcher.start()
        } else {
            localInputWatcher.stop()
        }
    }

    private func broadcastClipboard(_ text: String) {
        let payload = ClipboardTextPayload(text: text)
        for transport in outbound.values {
            transport.send(type: .clipboardText, payload: payload)
        }
        for transport in inbound.values {
            transport.send(type: .clipboardText, payload: payload)
        }
    }

    fileprivate func handleStateChange(_ state: ConnectionMode, deviceId: String?, transport: NetworkTransport) {
        if let deviceId {
            // Only mirror the state if this callback is for the transport
            // we currently consider live. During a Wi-Fi → Ethernet
            // upgrade we synchronously replace outbound[deviceId] with a
            // fresh transport, then cancel the old one — its async
            // `.cancelled` callback would otherwise stomp the new
            // transport back to nil and roll us straight to `.connecting`.
            let isCurrent = (outbound[deviceId] === transport)
            if isCurrent {
                connectionStates[deviceId] = state
            }
            if state == .disconnected || state == .errored {
                if isCurrent {
                    outbound[deviceId] = nil
                    // A terminal state for the current transport means the
                    // upgrade attempt is over (or the session died) —
                    // clear the guard so the next reconnect can attempt
                    // Ethernet again if the interface reappears.
                    wiredUpgradeAttempted.remove(deviceId)
                    releaseLocalControlIfTargeting(deviceId)
                    // Self-heal: try to redial after a short backoff. The
                    // peer may be momentarily unreachable (Wi-Fi blip) or
                    // just restarted.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        self?.reconcile()
                    }
                }
            }
        } else if state == .disconnected || state == .errored {
            inbound[ObjectIdentifier(transport)] = nil
            updateLocalInputWatcher()
        }
        recomputeHeartbeat()
        recomputeActiveInterface()
        refreshGate()
    }

    fileprivate func handleHeartbeatLoss(_ transport: NetworkTransport, deviceId: String?) {
        log.log(.network, "Heartbeat lost on \(deviceId ?? "inbound")")
        if let deviceId { releaseLocalControlIfTargeting(deviceId) }
        // Drop the dead link so the auto-reconnect path takes over.
        // Without this the transport sits forever reporting "heartbeat
        // lost" and never tries to come back.
        transport.disconnect()
        recomputeHeartbeat()
        refreshGate()
    }

    /// If the user is currently controlling `deviceId` and we just lost
    /// that link, drop the cursor back to local. Otherwise the sender's
    /// cursor stays parked at the edge forever — we sent events into a
    /// black hole and the local Mac feels frozen.
    private func releaseLocalControlIfTargeting(_ deviceId: String) {
        if capture.currentTargetDeviceId == deviceId {
            log.log(.input, "Lost link to \(deviceId) while controlling it — releasing locally")
            capture.currentTargetDeviceId = nil
        }
    }

    fileprivate func captureProducedEvent(_ event: InputEventMessage) {
        guard sharingEnabled, controllerRoleEnabled else { return }
        guard let targetId = capture.currentTargetDeviceId,
              let transport = outbound[targetId] else { return }
        transport.send(type: .inputEvent, payload: event)
    }

    fileprivate func captureRequestsSwitch(to deviceId: String) {
        // Refuse to hand the cursor to a peer whose transport isn't live.
        // Without this the mouse tunnels into a black hole when the peer
        // is off (or the socket died mid-session between edge fires).
        guard let transport = outbound[deviceId], transport.heartbeatAlive else {
            let now = Date()
            let last = lastEdgeBlockLogAt[deviceId] ?? .distantPast
            if now.timeIntervalSince(last) > 5 {
                log.log(.input, "Edge switch to \(deviceId) blocked — peer not connected")
                lastEdgeBlockLogAt[deviceId] = now
            }
            return
        }
        capture.currentTargetDeviceId = deviceId
        log.log(.input, "Control switched to \(deviceId)")
    }

    fileprivate func captureRequestsLocalReturn() {
        capture.currentTargetDeviceId = nil
        log.log(.input, "Control returned to local")
    }

    // MARK: - Heartbeat & safety gate

    private func recomputeHeartbeat() {
        var alive = false
        for t in outbound.values where t.heartbeatAlive { alive = true; break }
        if !alive {
            for t in inbound.values where t.heartbeatAlive { alive = true; break }
        }
        if alive != anyHeartbeatAlive { anyHeartbeatAlive = alive }
        evaluateIdleGuard()
    }

    /// Acquires the IOPM assertions when (a) the user wants the Mac to
    /// stay awake while paired, (b) at least one peer is healthy, and
    /// (c) the emergency stop isn't active. Releases otherwise. Idempotent.
    private func evaluateIdleGuard() {
        let shouldHold = keepAwakeWhilePaired && anyHeartbeatAlive && !emergencyStopActive
        if shouldHold {
            idleSleepGuard.acquire(reason: "Entanglo peer connected")
        } else {
            idleSleepGuard.release()
        }
    }

    private func refreshGate() {
        let snapshot = permissions.snapshot
        let isPaired = pairing.devices.contains(where: { $0.pairing == .trusted })
        injection.gate = InjectionSafetyGate(
            isPaired: isPaired,
            receiverRoleEnabled: receiverRoleEnabled,
            accessibilityGranted: snapshot.accessibility == .granted,
            heartbeatAlive: anyHeartbeatAlive,
            emergencyStopActive: emergencyStopActive
        )
    }

    private func applyCaptureRunning() {
        if sharingEnabled && controllerRoleEnabled {
            capture.start()
        } else {
            capture.stop()
            capture.currentTargetDeviceId = nil
        }
    }
}

// MARK: - Transport delegate bridge

private final class TransportBridge: NSObject, NetworkTransportDelegate {
    weak var owner: ConnectionCoordinator?
    let deviceId: String?
    weak var transport: NetworkTransport?

    init(owner: ConnectionCoordinator, deviceId: String?, transport: NetworkTransport) {
        self.owner = owner
        self.deviceId = deviceId
        self.transport = transport
    }

    func transport(_ transport: NetworkTransport, didReceive envelope: EntangloMessage) {
        Task { @MainActor in self.owner?.deliver(envelope: envelope, from: transport) }
    }

    func transport(_ transport: NetworkTransport, didChangeStateTo state: ConnectionMode) {
        Task { @MainActor in self.owner?.handleStateChange(state, deviceId: self.deviceId, transport: transport) }
    }

    func transportDidLoseHeartbeat(_ transport: NetworkTransport) {
        Task { @MainActor in self.owner?.handleHeartbeatLoss(transport, deviceId: self.deviceId) }
    }
}

// MARK: - Capture delegate bridge

private final class CaptureBridge: InputCaptureDelegate {
    weak var owner: ConnectionCoordinator?
    init(owner: ConnectionCoordinator) { self.owner = owner }

    func inputCapture(_ service: InputCaptureService, didProduce event: InputEventMessage) {
        Task { @MainActor in self.owner?.captureProducedEvent(event) }
    }
    func inputCapture(_ service: InputCaptureService, requestsSwitchTo deviceId: String) {
        Task { @MainActor in self.owner?.captureRequestsSwitch(to: deviceId) }
    }
    func inputCaptureRequestsLocalReturn(_ service: InputCaptureService) {
        Task { @MainActor in self.owner?.captureRequestsLocalReturn() }
    }
}
