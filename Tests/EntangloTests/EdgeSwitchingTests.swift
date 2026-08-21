//
// filename: EdgeSwitchingTests.swift
// path: Entanglo/Tests/EntangloTests/EdgeSwitchingTests.swift
// purpose: Covers the pure edge-switching decision function and the
//          triple-Escape emergency-stop state machine.
//

import XCTest
@testable import EntangloCore

final class EdgeSwitchingTests: XCTestCase {

    private let screenMinX: CGFloat = 0
    private let screenMaxX: CGFloat = 1920
    private let screenMinY: CGFloat = 0
    private let screenMaxY: CGFloat = 1080

    private func decide(
        x: CGFloat,
        y: CGFloat,
        currentlyRemote: Bool = false,
        config: EdgeSwitchConfig
    ) -> EdgeSwitchDecision {
        EdgeSwitchingLogic.decide(
            mouseX: x, mouseY: y,
            screenMinX: screenMinX, screenMaxX: screenMaxX,
            screenMinY: screenMinY, screenMaxY: screenMaxY,
            currentlyRemote: currentlyRemote, config: config
        )
    }

    func testLeftEdgeTriggersSwitch() {
        let cfg = EdgeSwitchConfig(leftEdgeTargetId: "left-mac",
                                   edgeThicknessPoints: 2, enabled: true)
        XCTAssertEqual(decide(x: 1, y: 540, config: cfg),
                       .switchTo(deviceId: "left-mac"))
    }

    func testRightEdgeTriggersSwitch() {
        let cfg = EdgeSwitchConfig(rightEdgeTargetId: "right-mac",
                                   edgeThicknessPoints: 2, enabled: true)
        XCTAssertEqual(decide(x: 1919, y: 540, config: cfg),
                       .switchTo(deviceId: "right-mac"))
    }

    func testTopEdgeTriggersSwitch() {
        let cfg = EdgeSwitchConfig(topEdgeTargetId: "top-pc",
                                   edgeThicknessPoints: 2, enabled: true)
        XCTAssertEqual(decide(x: 960, y: 1, config: cfg),
                       .switchTo(deviceId: "top-pc"))
    }

    func testBottomEdgeTriggersSwitch() {
        let cfg = EdgeSwitchConfig(bottomEdgeTargetId: "bottom-pc",
                                   edgeThicknessPoints: 2, enabled: true)
        XCTAssertEqual(decide(x: 960, y: 1079, config: cfg),
                       .switchTo(deviceId: "bottom-pc"))
    }

    func testCenterStaysLocal() {
        let cfg = EdgeSwitchConfig(leftEdgeTargetId: "L", rightEdgeTargetId: "R",
                                   topEdgeTargetId: "T", bottomEdgeTargetId: "B",
                                   edgeThicknessPoints: 2, enabled: true)
        XCTAssertEqual(decide(x: 800, y: 540, config: cfg), .stayLocal)
    }

    func testDisabledNeverSwitches() {
        let cfg = EdgeSwitchConfig(leftEdgeTargetId: "L", rightEdgeTargetId: "R",
                                   topEdgeTargetId: "T", bottomEdgeTargetId: "B",
                                   edgeThicknessPoints: 2, enabled: false)
        XCTAssertEqual(decide(x: 0, y: 0, config: cfg), .stayLocal)
    }

    func testAlreadyRemoteDoesNotChain() {
        let cfg = EdgeSwitchConfig(leftEdgeTargetId: "L", rightEdgeTargetId: "R",
                                   topEdgeTargetId: "T", bottomEdgeTargetId: "B",
                                   edgeThicknessPoints: 2, enabled: true)
        XCTAssertEqual(decide(x: 0, y: 0, currentlyRemote: true, config: cfg),
                       .stayLocal)
    }

    func testNoTargetOnSideStaysLocal() {
        let cfg = EdgeSwitchConfig(leftEdgeTargetId: nil, rightEdgeTargetId: "R",
                                   edgeThicknessPoints: 2, enabled: true)
        XCTAssertEqual(decide(x: 0, y: 540, config: cfg), .stayLocal)
    }

    /// L/R priority over T/B in corner ambiguity: matches decide() order
    /// — protects against regression for users with all four edges set.
    func testTopLeftCornerPrefersLeftEdge() {
        let cfg = EdgeSwitchConfig(leftEdgeTargetId: "L", rightEdgeTargetId: "R",
                                   topEdgeTargetId: "T", bottomEdgeTargetId: "B",
                                   edgeThicknessPoints: 2, enabled: true)
        XCTAssertEqual(decide(x: 0, y: 0, config: cfg),
                       .switchTo(deviceId: "L"))
    }

    // Emergency stop

    func testTripleEscapeWithinWindowFires() {
        var s = EmergencyStopState()
        let t0 = Date()
        XCTAssertFalse(s.record(at: t0))
        XCTAssertFalse(s.record(at: t0.addingTimeInterval(0.1)))
        XCTAssertTrue(s.record(at: t0.addingTimeInterval(0.2)))
    }

    func testTripleEscapeOutsideWindowDoesNotFire() {
        var s = EmergencyStopState()
        let t0 = Date()
        XCTAssertFalse(s.record(at: t0))
        XCTAssertFalse(s.record(at: t0.addingTimeInterval(2.0)))
        XCTAssertFalse(s.record(at: t0.addingTimeInterval(3.0)))
    }

    func testEmergencyStopResetsAfterFiring() {
        var s = EmergencyStopState()
        let t0 = Date()
        _ = s.record(at: t0)
        _ = s.record(at: t0.addingTimeInterval(0.1))
        XCTAssertTrue(s.record(at: t0.addingTimeInterval(0.2)))
        // After firing, next press should NOT immediately fire.
        XCTAssertFalse(s.record(at: t0.addingTimeInterval(0.3)))
    }
}
