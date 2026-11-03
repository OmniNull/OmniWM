// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation

struct StopWindowTarget: Sendable {
    let token: WindowToken
    let window: AXWindowRef
    let visibleFrame: CGRect?
    let placement: StopWindowGeometry.Placement?

    func destination(for currentFrame: CGRect) -> CGRect? {
        StopWindowGeometry.destination(for: currentFrame, in: visibleFrame, placement: placement)
    }
}

struct StopWindowOutcome: Sendable {
    let target: StopWindowTarget
    var confirmedMinimized: Bool?
    var frame: CGRect?
    var failure: String?
}

enum StopRestorationError: String, Error {
    case deadlineExceeded = "restoration deadline exceeded"
    case geometryUnavailable = "window geometry unavailable"
    case monitorUnavailable = "no connected monitor"
    case minimizedStateUnavailable = "native minimized state unavailable"
    case unminimizeRefused = "native unminimize refused"
    case positionRefused = "position restoration refused or unverified"
    case timeoutConfigurationFailed = "AX timeout configuration failed"
}

struct StopWindowOperations {
    var setTimeout: (Float) -> Bool
    var readMinimized: () -> Bool?
    var unminimize: () -> Bool
    var readFrame: () -> CGRect?
    var writePosition: (CGRect, CGRect) -> AXFrameWriteResult

    static func native(_ window: AXWindowRef) -> Self {
        Self(
            setTimeout: { AXUIElementSetMessagingTimeout(window.element, $0) == .success },
            readMinimized: { AXWindowService.isMinimized(window) },
            unminimize: { AXWindowService.unminimize(window) },
            readFrame: { try? AXWindowService.frame(window) },
            writePosition: { frame, current in
                AXWindowService.setFrame(
                    window,
                    frame: frame,
                    currentFrameHint: current,
                    components: .position,
                    verify: true
                )
            }
        )
    }
}

enum AXStopWindowRestoration {
    static func perform(
        _ target: StopWindowTarget,
        deadline: TimeInterval,
        operations: StopWindowOperations,
        checkCancellation: () throws -> Void,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> StopWindowOutcome {
        var outcome = StopWindowOutcome(target: target)
        defer { _ = operations.setTimeout(0) }
        func prepare(calls: Double = 1) throws {
            try checkCancellation()
            let remaining = deadline - now()
            guard remaining > 0 else { throw StopRestorationError.deadlineExceeded }
            guard operations.setTimeout(Float(min(0.5, remaining / calls))) else {
                throw StopRestorationError.timeoutConfigurationFailed
            }
        }
        do {
            try prepare()
            guard let minimized = operations.readMinimized()
            else { throw StopRestorationError.minimizedStateUnavailable }
            outcome.confirmedMinimized = minimized
            if minimized {
                try prepare()
                guard operations.unminimize() else { throw StopRestorationError.unminimizeRefused }
                try prepare()
                outcome.confirmedMinimized = operations.readMinimized()
                guard outcome.confirmedMinimized == false else { throw StopRestorationError.unminimizeRefused }
            }
            try prepare()
            guard let current = operations.readFrame(), current.size.hasFinitePositiveDimensions(),
                  current.origin.x.isFinite, current.origin.y.isFinite
            else { throw StopRestorationError.geometryUnavailable }
            guard let destination = target.destination(for: current)
            else { throw StopRestorationError.monitorUnavailable }
            try prepare(calls: 2)
            let result = operations.writePosition(destination, current)
            try checkCancellation()
            guard now() < deadline else { throw StopRestorationError.deadlineExceeded }
            guard result.isVerifiedSuccess, let observed = result.observedFrame,
                  observed.size.isWithinFrameTolerance(of: current.size)
            else { throw StopRestorationError.positionRefused }
            outcome.frame = observed
        } catch {
            outcome.failure = (error as? StopRestorationError)?.rawValue ?? "restoration cancelled"
        }
        return outcome
    }
}

extension AppAXContext {
    func restoreForStop(
        _ target: StopWindowTarget,
        deadline: TimeInterval,
        operations: @escaping @Sendable (AXWindowRef) -> StopWindowOperations = StopWindowOperations.native
    ) async -> StopWindowOutcome {
        guard let worker = axThread else {
            return StopWindowOutcome(target: target, failure: "AX worker unavailable")
        }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            return StopWindowOutcome(target: target, failure: StopRestorationError.deadlineExceeded.rawValue)
        }
        do {
            return try await worker.runInLoop(timeout: .seconds(remaining)) { job in
                AXStopWindowRestoration.perform(
                    target, deadline: deadline, operations: operations(target.window),
                    checkCancellation: job.checkCancellation
                )
            }
        } catch {
            return StopWindowOutcome(target: target, failure: "AX worker cancelled or restoration deadline exceeded")
        }
    }
}
