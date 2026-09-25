// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Dispatch
import Foundation

typealias AXFrameRequestId = UInt64

typealias AXFrameComponents = FrameMutationComponents

func axFrameMatches(
    _ observed: CGRect,
    target: CGRect,
    components: AXFrameComponents,
    tolerance: CGFloat = FrameTolerance.frameWrite
) -> Bool {
    (!components.contains(.position)
        || (abs(observed.origin.x - target.origin.x) < tolerance
            && abs(observed.origin.y - target.origin.y) < tolerance))
        && (!components.contains(.size)
            || (abs(observed.width - target.width) < tolerance
                && abs(observed.height - target.height) < tolerance))
}

enum AXFrameWriteOrder {
    case sizeThenPosition
    case positionThenSize
}

enum AXFrameWriteFailureReason: Equatable, Sendable {
    case valueCreationFailed
    case sizeWriteFailed(AXError)
    case positionWriteFailed(AXError)
    case staleElement
    case contextUnavailable
    case readbackFailed
    case verificationMismatch
    case cancelled
    case suppressed

    var traceDescription: String {
        switch self {
        case .valueCreationFailed:
            "valueCreationFailed"
        case let .sizeWriteFailed(error):
            "sizeWriteFailed(raw=\(error.rawValue))"
        case let .positionWriteFailed(error):
            "positionWriteFailed(raw=\(error.rawValue))"
        case .staleElement:
            "staleElement"
        case .contextUnavailable:
            "contextUnavailable"
        case .readbackFailed:
            "readbackFailed"
        case .verificationMismatch:
            "verificationMismatch"
        case .cancelled:
            "cancelled"
        case .suppressed:
            "suppressed"
        }
    }
}

struct AXFrameWriteResult: Equatable, Sendable {
    let observedFrame: CGRect?
    let writeOrder: AXFrameWriteOrder
    let sizeError: AXError
    let positionError: AXError
    let failureReason: AXFrameWriteFailureReason?
    let components: AXFrameComponents

    init(
        observedFrame: CGRect?,
        writeOrder: AXFrameWriteOrder,
        sizeError: AXError,
        positionError: AXError,
        failureReason: AXFrameWriteFailureReason?,
        components: AXFrameComponents = .all
    ) {
        self.observedFrame = observedFrame
        self.writeOrder = writeOrder
        self.sizeError = sizeError
        self.positionError = positionError
        self.failureReason = failureReason
        self.components = components
    }

    var isVerifiedSuccess: Bool {
        failureReason == nil
    }

    var shouldRetryAfterRefresh: Bool {
        failureReason == .staleElement
    }

    static func skipped(
        targetFrame: CGRect,
        currentFrameHint: CGRect?,
        failureReason: AXFrameWriteFailureReason,
        observedFrame: CGRect? = nil,
        components: AXFrameComponents = .all
    ) -> Self {
        Self(
            observedFrame: observedFrame,
            writeOrder: AXWindowService.frameWriteOrder(currentFrame: currentFrameHint, targetFrame: targetFrame),
            sizeError: .success,
            positionError: .success,
            failureReason: failureReason,
            components: components
        )
    }
}

struct AXFrameApplicationRequest: Equatable, Sendable {
    let requestId: AXFrameRequestId
    let pid: pid_t
    let windowId: Int
    let expectedWindow: AXWindowRef
    let frame: CGRect
    let currentFrameHint: CGRect?
    let components: AXFrameComponents
    var verify = true
    let traceRequestId: UInt64

    init(
        requestId: AXFrameRequestId,
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        frame: CGRect,
        currentFrameHint: CGRect?,
        components: AXFrameComponents = .all,
        verify: Bool = true,
        traceRequestId: UInt64 = 0
    ) {
        self.requestId = requestId
        self.pid = pid
        self.windowId = windowId
        self.expectedWindow = expectedWindow
        self.frame = frame
        self.currentFrameHint = currentFrameHint
        self.components = components
        self.verify = verify
        self.traceRequestId = traceRequestId
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestId == rhs.requestId
            && lhs.pid == rhs.pid
            && lhs.windowId == rhs.windowId
            && sameAXWindowIdentity(lhs.expectedWindow, rhs.expectedWindow)
            && lhs.frame == rhs.frame
            && lhs.currentFrameHint == rhs.currentFrameHint
            && lhs.components == rhs.components
            && lhs.verify == rhs.verify
    }
}

struct AXFrameApplyResult: Equatable, Sendable {
    let requestId: AXFrameRequestId
    let pid: pid_t
    let windowId: Int
    let expectedWindow: AXWindowRef
    let targetFrame: CGRect
    let currentFrameHint: CGRect?
    let writeResult: AXFrameWriteResult
    let didAttemptWrite: Bool
    let traceRequestId: UInt64

    init(
        requestId: AXFrameRequestId = 0,
        pid: pid_t,
        windowId: Int,
        expectedWindow: AXWindowRef,
        targetFrame: CGRect,
        currentFrameHint: CGRect?,
        writeResult: AXFrameWriteResult,
        didAttemptWrite: Bool = false,
        traceRequestId: UInt64 = 0
    ) {
        self.requestId = requestId
        self.pid = pid
        self.windowId = windowId
        self.expectedWindow = expectedWindow
        self.targetFrame = targetFrame
        self.currentFrameHint = currentFrameHint
        self.writeResult = writeResult
        self.didAttemptWrite = didAttemptWrite
        self.traceRequestId = traceRequestId
    }

    var confirmedFrame: CGRect? {
        if let observedFrame = writeResult.observedFrame,
           axFrameMatches(observedFrame, target: targetFrame, components: writeResult.components)
        {
            return observedFrame
        }
        guard writeResult.isVerifiedSuccess else { return nil }
        return writeResult.observedFrame ?? targetFrame
    }

    func rekeyed(to windowId: Int) -> Self {
        Self(
            requestId: requestId,
            pid: pid,
            windowId: windowId,
            expectedWindow: AXWindowRef(
                element: expectedWindow.element,
                windowId: windowId
            ),
            targetFrame: targetFrame,
            currentFrameHint: currentFrameHint,
            writeResult: writeResult,
            didAttemptWrite: didAttemptWrite,
            traceRequestId: traceRequestId
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.requestId == rhs.requestId
            && lhs.pid == rhs.pid
            && lhs.windowId == rhs.windowId
            && sameAXWindowIdentity(lhs.expectedWindow, rhs.expectedWindow)
            && lhs.targetFrame == rhs.targetFrame
            && lhs.currentFrameHint == rhs.currentFrameHint
            && lhs.writeResult == rhs.writeResult
            && lhs.didAttemptWrite == rhs.didAttemptWrite
    }
}
