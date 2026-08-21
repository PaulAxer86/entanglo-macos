//
// filename: SSDPDiscoverer.swift
// path: Entanglo/Entanglo/Services/SSDPDiscoverer.swift
// purpose: Sends UPnP M-SEARCH multicast to 239.255.255.250:1900, listens
//          for replies, then fetches each device's XML description and
//          extracts <friendlyName> and <modelName>. This is the cheap way
//          to learn that 192.168.1.55 is "Samsung TV UE55" instead of a
//          nameless MAC.
//

import Foundation

#if canImport(Network)
import Network
#endif

public struct SSDPResult: Sendable {
    public let ip: String
    public let friendlyName: String?
    public let modelName: String?
}

public final class SSDPDiscoverer: @unchecked Sendable {
    public var onResult: (@Sendable (SSDPResult) -> Void)?

    private let queue = DispatchQueue(label: "entanglo.ssdp", qos: .utility)
    private var socket: Int32 = -1
    private var listening = false

    public init() {}

    public func start() {
        queue.async { [weak self] in self?.runDiscovery() }
    }

    public func stop() {
        listening = false
        if socket != -1 {
            close(socket)
            socket = -1
        }
    }

    private func runDiscovery() {
        let s = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard s >= 0 else { return }
        socket = s

        var reuse: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var tv = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = (1900 as in_port_t).bigEndian
        addr.sin_addr.s_addr = inet_addr("239.255.255.250")

        let msearch = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: ssdp:all\r\n\r\n"
        msearch.withCString { cstr in
            let len = strlen(cstr)
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(s, cstr, len, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        listening = true
        let deadline = Date().addingTimeInterval(5)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var seenLocations = Set<String>()

        while listening && Date() < deadline {
            var fromAddr = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buffer.withUnsafeMutableBytes { buf -> Int in
                withUnsafeMutablePointer(to: &fromAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        return recvfrom(s, buf.baseAddress, buf.count, 0, sa, &fromLen)
                    }
                }
            }
            guard n > 0 else { continue }
            let response = String(bytes: buffer.prefix(n), encoding: .utf8) ?? ""
            guard let location = extractHeader(response, name: "LOCATION") ?? extractHeader(response, name: "Location") else { continue }
            if seenLocations.contains(location) { continue }
            seenLocations.insert(location)
            fetchDescription(at: location)
        }

        listening = false
        close(s)
        socket = -1
    }

    private func extractHeader(_ raw: String, name: String) -> String? {
        for line in raw.split(separator: "\r\n") {
            if line.lowercased().hasPrefix("\(name.lowercased()):") {
                let value = line.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
                return String(value)
            }
        }
        return nil
    }

    private func fetchDescription(at location: String) {
        guard let url = URL(string: location), let host = url.host else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data = data, let xml = String(data: data, encoding: .utf8) else { return }
            let friendly = Self.tagValue(in: xml, tag: "friendlyName")
            let model = Self.tagValue(in: xml, tag: "modelName")
            guard friendly != nil || model != nil else { return }
            let ip = Self.resolveIPv4(forHost: host) ?? host
            self.onResult?(SSDPResult(ip: ip, friendlyName: friendly, modelName: model))
        }
        task.resume()
    }

    private static func tagValue(in xml: String, tag: String) -> String? {
        guard let openRange = xml.range(of: "<\(tag)>"),
              let closeRange = xml.range(of: "</\(tag)>", range: openRange.upperBound..<xml.endIndex)
        else { return nil }
        let value = xml[openRange.upperBound..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func resolveIPv4(forHost host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(info) }
        guard let addr = info.pointee.ai_addr else { return nil }
        var sin = sockaddr_in()
        memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}
