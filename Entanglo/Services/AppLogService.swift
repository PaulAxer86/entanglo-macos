//
// filename: AppLogService.swift
// path: Entanglo/Entanglo/Services/AppLogService.swift
// purpose: OSLog + in-memory ring buffer that backs the Logs view.
//          Never logs keystroke content. Categories map 1:1 to the Logs
//          filter pills.
//

import Foundation
import os

#if canImport(Combine)
import Combine
#endif

public enum LogCategory: String, Codable, CaseIterable, Sendable {
    case network, pairing, input, error, app

    public var displayName: String {
        switch self {
        case .network: return "Network"
        case .pairing: return "Pairing"
        case .input:   return "Input"
        case .error:   return "Error"
        case .app:     return "App"
        }
    }
}

public struct LogEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let category: LogCategory
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), category: LogCategory, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

public final class AppLogService {
    public static let shared = AppLogService()

    #if canImport(Combine)
    @Published public private(set) var entries: [LogEntry] = []
    #else
    public private(set) var entries: [LogEntry] = []
    #endif

    private let ringCapacity = 1_000
    private let lock = NSLock()
    private let subsystem = "com.paoloasara.entanglo"
    private var loggers: [LogCategory: Logger] = [:]

    public init() {
        for cat in LogCategory.allCases {
            loggers[cat] = Logger(subsystem: subsystem, category: cat.rawValue)
        }
    }

    public func log(_ category: LogCategory, _ message: String) {
        let entry = LogEntry(category: category, message: message)
        lock.lock()
        entries.append(entry)
        if entries.count > ringCapacity {
            entries.removeFirst(entries.count - ringCapacity)
        }
        lock.unlock()
        loggers[category]?.log("\(message, privacy: .public)")
    }

    public func clear() {
        lock.lock(); entries.removeAll(); lock.unlock()
    }
}
