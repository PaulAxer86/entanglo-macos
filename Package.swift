// swift-tools-version:5.9
//
// filename: Package.swift
// path: Entanglo/Package.swift
// purpose: SwiftPM manifest for building and unit-testing the Entanglo core
//          (Protocol/, Models/, and the testable parts of Services/) from
//          the command line. The full SwiftUI app target is built in Xcode.
//

import PackageDescription

let package = Package(
    name: "Entanglo",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "EntangloCore", targets: ["EntangloCore"])
    ],
    targets: [
        .target(
            name: "EntangloCore",
            path: "Entanglo",
            exclude: [
                "EntangloApp.swift",
                "AppState.swift",
                "Views",
                "Resources",
                "Services/InputInjectionService.swift",
                "Services/PermissionService.swift",
                "Services/ClipboardSyncService.swift",
                "Services/RemoteDisplayService.swift",
                "Services/DiscoveryService.swift",
                "Services/NetworkTransport.swift"
            ],
            sources: [
                "Models",
                "Protocol",
                "Services/PairingService.swift",
                "Services/AIWorkerDiscoveryService.swift",
                "Services/AIRequestRouter.swift",
                "Services/NetworkQualityService.swift",
                "Services/AppLogService.swift",
                "Services/InputCaptureService.swift"
            ]
        ),
        .testTarget(
            name: "EntangloTests",
            dependencies: ["EntangloCore"],
            path: "Tests/EntangloTests"
        )
    ]
)
