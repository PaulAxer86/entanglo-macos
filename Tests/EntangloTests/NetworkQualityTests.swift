//
// filename: NetworkQualityTests.swift
// path: Entanglo/Tests/EntangloTests/NetworkQualityTests.swift
// purpose: Covers NetworkQualityService.suggestion's decision boundaries.
//

import XCTest
@testable import EntangloCore

final class NetworkQualityTests: XCTestCase {

    func testNoHeartbeatIsOffline() {
        let s = NetworkQualityService.suggestion(
            kind: .ethernet, latencyMs: 5, lossRate: 0, lastHeartbeatAge: nil
        )
        XCTAssertEqual(s, .offline)
    }

    func testStaleHeartbeatIsOffline() {
        let s = NetworkQualityService.suggestion(
            kind: .ethernet, latencyMs: 5, lossRate: 0, lastHeartbeatAge: 10
        )
        XCTAssertEqual(s, .offline)
    }

    func testEthernetWithGoodMetricsIsPreferred() {
        let s = NetworkQualityService.suggestion(
            kind: .ethernet, latencyMs: 5, lossRate: 0, lastHeartbeatAge: 0.5
        )
        XCTAssertEqual(s, .ethernetPreferred)
    }

    func testWiFiWithGoodMetricsIsOK() {
        let s = NetworkQualityService.suggestion(
            kind: .wifi, latencyMs: 30, lossRate: 0, lastHeartbeatAge: 0.5
        )
        XCTAssertEqual(s, .wifiOK)
    }

    func testHighLatencyMarksUnstable() {
        let s = NetworkQualityService.suggestion(
            kind: .ethernet, latencyMs: 500, lossRate: 0, lastHeartbeatAge: 0.5
        )
        XCTAssertEqual(s, .unstable)
    }

    func testHighLossMarksUnstable() {
        let s = NetworkQualityService.suggestion(
            kind: .wifi, latencyMs: 20, lossRate: 0.2, lastHeartbeatAge: 0.5
        )
        XCTAssertEqual(s, .unstable)
    }

    func testUnknownKindBehavesLikeWiFi() {
        let s = NetworkQualityService.suggestion(
            kind: .unknown, latencyMs: 20, lossRate: 0, lastHeartbeatAge: 0.5
        )
        XCTAssertEqual(s, .wifiOK)
    }
}
