//
// filename: NetworkTransport.swift
// path: Entanglo/Entanglo/Services/NetworkTransport.swift
// purpose: TCP transport for one Entanglo connection. Frames messages
//          with a 4-byte length prefix and a JSON envelope. Sends a
//          heartbeat every second; flags the link dead after 3 s of
//          silence so InputInjectionService can stop immediately.
//

import Foundation
#if canImport(Combine)
import Combine
#endif
#if canImport(Network)
import Network
#endif
#if canImport(QuartzCore)
import QuartzCore
#endif

public protocol NetworkTransportDelegate: AnyObject {
    func transport(_ transport: NetworkTransport, didReceive envelope: EntangloMessage)
    func transport(_ transport: NetworkTransport, didChangeStateTo state: ConnectionMode)
    func transportDidLoseHeartbeat(_ transport: NetworkTransport)
}

public final class NetworkTransport: ObservableObject {
    public static let heartbeatInterval: TimeInterval = 1.0
    public static let heartbeatTimeout: TimeInterval = 3.0

    public weak var delegate: NetworkTransportDelegate?

    public let localDeviceId: String
    public let sessionId: String

    @Published public private(set) var connectionState: ConnectionMode = .offline
    @Published public private(set) var heartbeatAlive: Bool = false
    /// Interface the active NWConnection is actually using, sampled when
    /// it transitions to .ready. nil until the path resolves.
    @Published public private(set) var interfaceKind: NetworkInterfaceKind = .unknown
    /// Last round-trip time measured via the heartbeat echo. Updated on
    /// every heartbeat we receive that carries an `echoSentAtMs` field.
    /// nil until the first round-trip completes.
    @Published public private(set) var lastRttMs: Double?

    private let log: AppLogService

    #if canImport(Network)
    private var connection: NWConnection?
    #endif

    private var heartbeatTimer: Timer?
    private var lastHeartbeatAt: Date?
    private var sequence: UInt64 = 0
    /// Most recent `sentAtMs` seen on an incoming heartbeat. Sent back
    /// on our next outgoing heartbeat so the peer can compute its RTT.
    private var peerLastSentAtMs: Double?

    private static func monotonicNowMs() -> Double {
        #if canImport(QuartzCore)
        return CACurrentMediaTime() * 1000.0
        #else
        return Date().timeIntervalSince1970 * 1000.0
        #endif
    }

    public init(localDeviceId: String, sessionId: String = UUID().uuidString, log: AppLogService = .shared) {
        self.localDeviceId = localDeviceId
        self.sessionId = sessionId
        self.log = log
    }

    // MARK: - Lifecycle

    #if canImport(Network)
    public func connect(to host: String, port: UInt16, requiredInterface: NWInterface.InterfaceType? = nil) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any)
        connect(to: endpoint, requiredInterface: requiredInterface)
    }

    /// - Parameter requiredInterface: if non-nil, the connection is
    ///   pinned to that interface type (e.g. `.wiredEthernet`) and
    ///   will not fall back to Wi-Fi mid-session. Pass nil to let
    ///   Network.framework pick the path itself.
    public func connect(to endpoint: NWEndpoint, requiredInterface: NWInterface.InterfaceType? = nil) {
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        if let requiredInterface {
            params.requiredInterfaceType = requiredInterface
        }
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let connection = NWConnection(to: endpoint, using: params)
        bind(connection)
        connection.start(queue: .main)
    }

    /// Used by the listener side: a connection has already been opened
    /// inbound, we just take it over.
    public func accept(_ connection: NWConnection) {
        bind(connection)
        connection.start(queue: .main)
    }

    private func bind(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state: state)
        }
        self.connection = connection
        startHeartbeat()
        readNextFrame()
    }
    #endif

    public func disconnect() {
        #if canImport(Network)
        connection?.cancel()
        connection = nil
        #endif
        stopHeartbeat()
    }

    // MARK: - Send

    public func send<Payload: Encodable>(type: MessageType, payload: Payload) {
        do {
            let bytes = try MessageCodec.encode(
                type: type,
                senderDeviceId: localDeviceId,
                sessionId: sessionId,
                payload: payload
            )
            sendFrame(bytes)
        } catch {
            log.log(.error, "Encode failed for \(type.rawValue): \(error)")
        }
    }

    /// Send a frame whose inner payload is already JSON-encoded — used by
    /// FileTransferService, which encodes chunks itself so it can split
    /// before handing them to the transport.
    public func sendRaw(type: MessageType, payloadJSON: Data) {
        let envelope = EntangloMessage(
            protocolVersion: MessageCodec.currentProtocolVersion,
            messageType: type,
            senderDeviceId: localDeviceId,
            sessionId: sessionId,
            timestamp: Date().timeIntervalSince1970,
            payload: payloadJSON
        )
        do {
            let bytes = try JSONEncoder().encode(envelope)
            if bytes.count > MessageCodec.maxMessageBytes {
                log.log(.error, "sendRaw oversize frame (\(bytes.count) B) for \(type.rawValue)")
                return
            }
            sendFrame(bytes)
        } catch {
            log.log(.error, "sendRaw encode failed for \(type.rawValue): \(error)")
        }
    }

    private func sendFrame(_ payload: Data) {
        #if canImport(Network)
        var lenBE = UInt32(payload.count).bigEndian
        var frame = Data()
        withUnsafeBytes(of: &lenBE) { frame.append(contentsOf: $0) }
        frame.append(payload)
        connection?.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error { self?.log.log(.error, "Send error: \(error)") }
        })
        #endif
    }

    // MARK: - Receive

    private func readNextFrame() {
        #if canImport(Network)
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == 4, error == nil else {
                self.log.log(.error, "Header read failed: \(String(describing: error))")
                // Peer closed or read errored — tear down so the
                // reconnect path takes over instead of leaving the
                // transport in a zombie state.
                self.disconnect()
                return
            }
            let length = data.withUnsafeBytes { Int(UInt32(bigEndian: $0.load(as: UInt32.self))) }
            guard length > 0, length <= MessageCodec.maxMessageBytes else {
                self.log.log(.error, "Oversize frame announced: \(length) bytes")
                self.disconnect()
                return
            }
            self.connection?.receive(minimumIncompleteLength: length, maximumLength: length) { payload, _, _, error in
                guard let payload, error == nil else {
                    self.log.log(.error, "Payload read failed: \(String(describing: error))")
                    self.disconnect()
                    return
                }
                self.handlePayload(payload)
                self.readNextFrame()
            }
        }
        #endif
    }

    private func handlePayload(_ data: Data) {
        // Any inbound frame proves the peer is alive on this socket —
        // treat it as a keepalive. Prior versions only refreshed
        // lastHeartbeatAt on `.heartbeat` frames, so a peer streaming
        // a 2 MB fileChunk (which occupies the pipe for several seconds
        // on Wi-Fi) would starve the heartbeat receive path and trip
        // the 3 s "link dead" timeout mid-transfer.
        lastHeartbeatAt = Date()
        if !heartbeatAlive { heartbeatAlive = true }
        do {
            let envelope = try MessageCodec.decodeEnvelope(data)
            if envelope.messageType == .heartbeat {
                // Decode the heartbeat to read sentAtMs (store for echo
                // on our next tick) and echoSentAtMs (if the peer is
                // echoing back our own previous sentAt, that's a full
                // round-trip we can measure).
                if let hb = try? MessageCodec.decodePayload(envelope, as: HeartbeatMessage.self) {
                    if let s = hb.sentAtMs { peerLastSentAtMs = s }
                    if let echo = hb.echoSentAtMs {
                        let rtt = Self.monotonicNowMs() - echo
                        if rtt >= 0, rtt < 60_000 { lastRttMs = rtt }
                    }
                }
            }
            delegate?.transport(self, didReceive: envelope)
        } catch MessageCodecError.unknownProtocolVersion(let v) {
            log.log(.error, "Unknown protocol version \(v) — closing")
            disconnect()
        } catch MessageCodecError.unknownMessageType(let t) {
            log.log(.network, "Skipping unknown messageType '\(t)' from peer (forward-compat)")
        } catch {
            log.log(.error, "Decode failed: \(error)")
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        lastHeartbeatAt = Date()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: Self.heartbeatInterval,
            repeats: true
        ) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        lastHeartbeatAt = nil
    }

    private func tick() {
        sequence &+= 1
        let hb = HeartbeatMessage(
            sequence: sequence,
            lastRttMs: lastRttMs,
            sentAtMs: Self.monotonicNowMs(),
            echoSentAtMs: peerLastSentAtMs
        )
        send(type: .heartbeat, payload: hb)
        if let last = lastHeartbeatAt, Date().timeIntervalSince(last) > Self.heartbeatTimeout {
            if heartbeatAlive { heartbeatAlive = false }
            log.log(.network, "Heartbeat lost — link presumed dead")
            delegate?.transportDidLoseHeartbeat(self)
        }
    }

    #if canImport(Network)
    private func handle(state: NWConnection.State) {
        let next: ConnectionMode?
        switch state {
        case .ready:        next = .connected
        case .preparing:    next = .connecting
        case .failed:       next = .errored
        case .cancelled:    next = .disconnected
        default:            next = nil
        }
        if next == .connected, let path = connection?.currentPath {
            interfaceKind = Self.classify(path)
        }
        if let next {
            connectionState = next
            delegate?.transport(self, didChangeStateTo: next)
        }
    }

    private static func classify(_ path: NWPath) -> NetworkInterfaceKind {
        if path.usesInterfaceType(.wiredEthernet) { return .ethernet }
        if path.usesInterfaceType(.wifi)          { return .wifi }
        if path.usesInterfaceType(.loopback)      { return .loopback }
        return .unknown
    }
    #endif
}
