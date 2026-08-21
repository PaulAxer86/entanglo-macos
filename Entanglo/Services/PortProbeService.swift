//
// filename: PortProbeService.swift
// path: Entanglo/Entanglo/Services/PortProbeService.swift
// purpose: User-triggered TCP connect-scan over a small fixed port list,
//          plus a reverse DNS lookup for the target host. Returns open
//          ports and best-effort banners for HTTP/SSH so the UI can tell
//          you "this device runs OpenSSH_for_Windows 8.6" or "this is a
//          Synology DSM".
//

import Foundation

#if canImport(Network)
import Network
#endif

public struct PortProbeResult: Sendable {
    public let host: String
    public let reverseDNS: String?
    public let openPorts: [Int]
    public let banners: [Int: String]
}

public actor PortProbeService {
    public static let commonPorts: [Int] = [
        22,    // SSH
        80,    // HTTP
        139,   // SMB / NetBIOS
        443,   // HTTPS
        445,   // SMB
        515,   // LPD print
        548,   // AFP
        554,   // RTSP (TVs)
        631,   // IPP
        1900,  // SSDP (TCP rarely, mostly UDP — skip in practice)
        2049,  // NFS
        3389,  // RDP
        5000,  // UPnP / Synology
        5060,  // SIP
        5353,  // mDNS (TCP atypical)
        5900,  // VNC
        7000,  // AirPlay
        8000,  // alt-HTTP
        8080,  // alt-HTTP
        8443,  // alt-HTTPS
        8200,  // Synology / Plex
        32400, // Plex
        62078  // iPhone sync
    ]

    private let perPortTimeout: TimeInterval = 1.2

    public init() {}

    public func probe(host: String, ports: [Int]? = nil) async -> PortProbeResult {
        let ports = ports ?? Self.commonPorts
        async let reverse = reverseDNS(for: host)

        var open: [Int] = []
        var banners: [Int: String] = [:]

        await withTaskGroup(of: (Int, String?)?.self) { group in
            for p in ports {
                group.addTask { [perPortTimeout] in
                    await Self.connect(host: host, port: p, timeout: perPortTimeout)
                }
            }
            for await result in group {
                if let (port, banner) = result {
                    open.append(port)
                    if let b = banner, !b.isEmpty { banners[port] = b }
                }
            }
        }

        return PortProbeResult(
            host: host,
            reverseDNS: await reverse,
            openPorts: open.sorted(),
            banners: banners
        )
    }

    private static func connect(host: String, port: Int, timeout: TimeInterval) async -> (Int, String?)? {
        #if canImport(Network)
        return await withCheckedContinuation { (cont: CheckedContinuation<(Int, String?)?, Never>) in
            let conn = NWConnection(host: NWEndpoint.Host(host),
                                    port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                                    using: .tcp)
            let resumed = Resumer<(Int, String?)?>(cont)

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    grabBanner(conn: conn, port: port) { banner in
                        resumed.resume((port, banner))
                        conn.cancel()
                    }
                case .failed, .cancelled:
                    resumed.resume(nil)
                    conn.cancel()
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                resumed.resume(nil)
                conn.cancel()
            }
        }
        #else
        return nil
        #endif
    }

    #if canImport(Network)
    private static func grabBanner(conn: NWConnection, port: Int, completion: @escaping (String?) -> Void) {
        // SSH (22) and SMTP-ish servers send a greeting first.
        if port == 22 {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 256) { data, _, _, _ in
                completion(firstLine(data))
            }
            return
        }
        // HTTP-ish: send HEAD /, take first line + Server header.
        if [80, 8080, 8000, 5000, 32400].contains(port) {
            let request = "HEAD / HTTP/1.0\r\n\r\n"
            conn.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, _, _ in
                    completion(httpBanner(data))
                }
            })
            return
        }
        // Default: no banner.
        completion(nil)
    }

    private static func firstLine(_ data: Data?) -> String? {
        guard let data = data, let s = String(data: data, encoding: .utf8) else { return nil }
        return s.split(separator: "\n", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func httpBanner(_ data: Data?) -> String? {
        guard let data = data, let s = String(data: data, encoding: .utf8) else { return nil }
        for line in s.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("server:") {
                return line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            }
        }
        return firstLine(data)
    }
    #endif

    private func reverseDNS(for host: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                var addr = in_addr()
                guard inet_aton(host, &addr) == 1 else { cont.resume(returning: nil); return }
                var sin = sockaddr_in()
                sin.sin_family = sa_family_t(AF_INET)
                sin.sin_addr = addr
                var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = withUnsafePointer(to: &sin) { ptr -> Int32 in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                    &hostBuf, socklen_t(NI_MAXHOST),
                                    nil, 0, NI_NAMEREQD)
                    }
                }
                if result == 0 {
                    let name = String(cString: hostBuf)
                    cont.resume(returning: name.isEmpty ? nil : name)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

private final class Resumer<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
