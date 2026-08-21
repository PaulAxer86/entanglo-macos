//
// filename: Device.swift
// path: Entanglo/Entanglo/Models/Device.swift
// purpose: Canonical record of a remote (or local) Entanglo device.
//          Persisted to ~/Library/Application Support/Entanglo/devices.json.
//

import Foundation

public struct Device: Codable, Identifiable, Equatable, Sendable {
    public let id: String          // stable UUID generated on first launch
    public var name: String
    public var hostName: String?
    public var ipAddress: String?
    public var port: Int?
    public var roles: Set<EntangloRole>
    public var pairing: PairingState
    public var connection: ConnectionMode
    public var iface: NetworkInterfaceInfo
    public var lastSeen: Date?
    public var appVersion: String?

    public init(
        id: String,
        name: String,
        hostName: String? = nil,
        ipAddress: String? = nil,
        port: Int? = nil,
        roles: Set<EntangloRole> = [],
        pairing: PairingState = .notPaired,
        connection: ConnectionMode = .discovered,
        iface: NetworkInterfaceInfo = NetworkInterfaceInfo(kind: .unknown, name: "unknown"),
        lastSeen: Date? = nil,
        appVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostName = hostName
        self.ipAddress = ipAddress
        self.port = port
        self.roles = roles
        self.pairing = pairing
        self.connection = connection
        self.iface = iface
        self.lastSeen = lastSeen
        self.appVersion = appVersion
    }
}
