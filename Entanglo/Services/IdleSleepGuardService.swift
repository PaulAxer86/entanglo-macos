//
// filename: IdleSleepGuardService.swift
// path: Entanglo/Entanglo/Services/IdleSleepGuardService.swift
// purpose: Holds IOPMAssertion(s) that prevent display sleep, screensaver,
//          and system idle sleep while Entanglo has at least one trusted
//          peer actively connected. Same mechanism as `caffeinate`; no
//          third-party dependency. Releasing the assertions lets the
//          system fall back to its normal Energy Saver behavior.
//

import Foundation
#if canImport(IOKit)
import IOKit
import IOKit.pwr_mgt
#endif

public final class IdleSleepGuardService {
    private let log: AppLogService
    private var displayAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private var systemAssertion: IOPMAssertionID = IOPMAssertionID(0)
    private(set) public var isHeld: Bool = false

    public init(log: AppLogService = .shared) { self.log = log }

    /// Acquires both assertions. Idempotent — calling it while already
    /// held is a no-op so callers don't have to deduplicate.
    public func acquire(reason: String = "Entanglo session active") {
        #if canImport(IOKit)
        guard !isHeld else { return }
        let reasonCF = reason as CFString

        let dRet = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonCF,
            &displayAssertion
        )
        let sRet = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reasonCF,
            &systemAssertion
        )
        if dRet == kIOReturnSuccess && sRet == kIOReturnSuccess {
            isHeld = true
            log.log(.network, "Idle sleep guard acquired (\(reason))")
        } else {
            // Partial failure: release whatever did succeed so we don't
            // leak an assertion the user can't see.
            if dRet == kIOReturnSuccess { IOPMAssertionRelease(displayAssertion) }
            if sRet == kIOReturnSuccess { IOPMAssertionRelease(systemAssertion) }
            displayAssertion = IOPMAssertionID(0)
            systemAssertion = IOPMAssertionID(0)
            log.log(.error, "Idle sleep guard acquire failed (display=\(dRet), system=\(sRet))")
        }
        #endif
    }

    /// Releases both assertions. Safe to call when nothing is held.
    public func release() {
        #if canImport(IOKit)
        guard isHeld else { return }
        IOPMAssertionRelease(displayAssertion)
        IOPMAssertionRelease(systemAssertion)
        displayAssertion = IOPMAssertionID(0)
        systemAssertion = IOPMAssertionID(0)
        isHeld = false
        log.log(.network, "Idle sleep guard released")
        #endif
    }

    deinit {
        // Best-effort: don't leave the system pinned awake if the service
        // is torn down without an explicit release.
        if isHeld {
            #if canImport(IOKit)
            IOPMAssertionRelease(displayAssertion)
            IOPMAssertionRelease(systemAssertion)
            #endif
        }
    }
}
