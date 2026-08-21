//
// filename: ReleaseNote.swift
// path: Entanglo/Entanglo/Models/ReleaseNote.swift
// purpose: Per-version changelog entry shown in the Updates / News tab.
//          Loaded from `Resources/release-notes.json` embedded in the
//          app bundle. The same shape is reused for a future remote
//          update manifest.
//

import Foundation

public struct ReleaseNote: Codable, Identifiable, Equatable {
    public let version: String
    public let date: String
    public let title: String
    public let highlights: [String]

    public var id: String { version }

    public init(version: String, date: String, title: String, highlights: [String]) {
        self.version = version
        self.date = date
        self.title = title
        self.highlights = highlights
    }
}

/// Three-component semver compare. Missing or non-numeric components
/// sort as 0. Pre-release suffixes (e.g. "0.1.21-beta") are ignored —
/// v0.1 hasn't shipped any. Returns -1 / 0 / 1 like NSNumber.compare.
public enum SemverCompare {
    public static func compare(_ a: String, _ b: String) -> Int {
        let pa = parse(a), pb = parse(b)
        for i in 0..<3 {
            if pa[i] != pb[i] { return pa[i] < pb[i] ? -1 : 1 }
        }
        return 0
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) > 0
    }

    private static func parse(_ s: String) -> [Int] {
        let stripped = s.split(separator: "-").first.map(String.init) ?? s
        var parts = stripped.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count < 3 { parts.append(0) }
        return Array(parts.prefix(3))
    }
}
