// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension AXManager {
    func forceApplyNextFrame(for windowId: Int) {
        frameLedger.forceApplyNextFrame(for: windowId)
    }

    func invalidateAppliedFrame(for windowId: Int) {
        frameLedger.invalidateAppliedFrame(for: windowId)
        clearSkyLightLivePosition(for: windowId)
    }

    func lastAppliedFrame(for windowId: Int) -> CGRect? {
        frameLedger.lastAppliedFrame(for: windowId)
    }

    func animationFrameComponents(for windowId: Int, targetFrame: CGRect) -> FrameMutationComponents {
        guard let trustedSize = frameLedger.trustedVerifiedSize(for: windowId),
              Self.frameSizesMatch(trustedSize, targetFrame.size)
        else {
            return .all
        }
        return .position
    }

    func animationFrameChange(_ change: LayoutFrameChange) -> LayoutFrameChange {
        let components = animationFrameComponents(for: change.token.windowId, targetFrame: change.frame)
        if components != .all {
            return change.writing(change.frame, components: components)
        }
        return enforcedSizeFrameChange(change)
    }

    func enforcedSizeFrameChange(_ change: LayoutFrameChange) -> LayoutFrameChange {
        guard !change.forceApply,
              let placement = frameLedger.enforcedSizePlacement(
                  for: change.token.windowId,
                  targetFrame: change.frame
              )
        else {
            return change
        }
        return change.writing(placement, components: .position)
    }

    private static func frameSizesMatch(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < FrameTolerance.frameWrite
            && abs(lhs.height - rhs.height) < FrameTolerance.frameWrite
    }

    func recentFrameWriteFailure(for windowId: Int) -> AXFrameWriteFailureReason? {
        frameLedger.recentFrameWriteFailure(for: windowId)
    }

    func recentFrameWriteFailureComponents(for windowId: Int) -> AXFrameComponents? {
        frameLedger.recentFrameWriteFailureComponents(for: windowId)
    }

    func hasPendingFrameWrite(for windowId: Int) -> Bool {
        frameLedger.hasPendingFrameWrite(for: windowId)
    }

    func hasInFlightFrameWrite(for token: WindowToken) -> Bool {
        AppAXContextRegistry.contexts[token.pid]?.frameDelivery.hasInFlightFrameWrite(for: token.windowId) == true
    }

    func pendingFrameWrite(for windowId: Int) -> CGRect? {
        frameLedger.pendingFrameWrite(for: windowId)
    }

    func stageFrameWrite(for target: AXFrameApplicationTarget) -> AXFrameApplicationRequest? {
        frameLedger.prepareFrameApplication(
            target,
            isRetry: false,
            verify: true,
            terminalObserver: nil
        ).request
    }

    func shouldSuppressFrameChangeRelayout(for windowId: Int, observedFrame: CGRect?) -> Bool {
        frameLedger.shouldSuppressFrameChangeRelayout(for: windowId, observedFrame: observedFrame)
    }

    func confirmFrameWrite(for windowId: Int, frame: CGRect) {
        frameLedger.confirmFrameWrite(for: windowId, frame: frame)
        clearSkyLightLivePosition(for: windowId)
    }
}
