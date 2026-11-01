// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

extension WMController {
    func adoptObservedMinimumAfterStableSizeClamp(_ result: AXFrameApplyResult) {
        guard let entry = workspaceManager.entry(forPid: result.pid, windowId: result.windowId),
              let axRef = entry.axRef,
              sameAXWindowIdentity(axRef, result.expectedWindow),
              entry.mode == .tiling,
              entry.layoutReason == .standard,
              entry.hiddenState == nil,
              !workspaceManager.isWindowSuppressedByMacOS(entry.token),
              let observed = result.writeResult.observedFrame?.size
        else {
            return
        }
        let target = result.targetFrame.size
        var evidence = workspaceManager.observedSizeEvidence(for: entry.token) ?? ObservedSizeEvidence()
        Self.learnStableGrowth(
            minimum: &evidence.minSize.width,
            hint: &evidence.hints.width,
            requested: target.width,
            observed: observed.width
        )
        Self.learnStableGrowth(
            minimum: &evidence.minSize.height,
            hint: &evidence.hints.height,
            requested: target.height,
            observed: observed.height
        )
        adoptObservedSizeEvidence(evidence, for: entry)
    }

    func adoptObservedMinimumAfterTerminalSizeWriteFailure(_ refusal: AXFrameTerminalRefusal) {
        guard case .sizeWriteFailed = refusal.failureReason,
              let entry = workspaceManager.entry(forWindowId: refusal.windowId),
              entry.axRef != nil,
              entry.mode == .tiling,
              workspaceManager.hiddenState(for: entry.token) == nil
        else {
            return
        }
        let target = refusal.targetFrame.size
        let observed = refusal.observedFrame.size
        var evidence = workspaceManager.observedSizeEvidence(for: entry.token) ?? ObservedSizeEvidence()
        let observedMin = CGSize(
            width: Self.updatedObservedMinimumAxis(
                existing: evidence.minSize.width,
                target: target.width,
                observed: observed.width
            ),
            height: Self.updatedObservedMinimumAxis(
                existing: evidence.minSize.height,
                target: target.height,
                observed: observed.height
            )
        )
        guard observedMin.width > 1 || observedMin.height > 1 else { return }
        evidence.minSize = observedMin
        adoptObservedSizeEvidence(evidence, for: entry)
    }

    func relaxObservedSizeEvidence(afterVerifiedWrite result: AXFrameApplyResult) {
        guard result.writeResult.components == .all,
              result.writeResult.observedFrame != nil,
              let accepted = result.confirmedFrame?.size,
              let entry = workspaceManager.entry(forPid: result.pid, windowId: result.windowId),
              let axRef = entry.axRef,
              sameAXWindowIdentity(axRef, result.expectedWindow),
              var evidence = workspaceManager.observedSizeEvidence(for: entry.token)
        else {
            return
        }
        Self.relaxContradictedAxis(
            minimum: &evidence.minSize.width,
            hint: &evidence.hints.width,
            accepted: accepted.width
        )
        Self.relaxContradictedAxis(
            minimum: &evidence.minSize.height,
            hint: &evidence.hints.height,
            accepted: accepted.height
        )
        adoptObservedSizeEvidence(evidence, for: entry)
    }

    private func adoptObservedSizeEvidence(_ evidence: ObservedSizeEvidence, for entry: WindowState) {
        guard workspaceManager.setObservedSizeEvidence(evidence, for: entry.token) else { return }
        workspaceManager.invalidateLayout(for: [entry.workspaceId])
        layoutRefreshController.requestRelayout(
            reason: .observedConstraintsChanged,
            affectedWorkspaceIds: [entry.workspaceId]
        )
    }

    private static func learnStableGrowth(
        minimum: inout CGFloat,
        hint: inout ObservedAxisHint?,
        requested: CGFloat,
        observed: CGFloat
    ) {
        guard observed > requested + FrameTolerance.frameWrite else { return }
        if observed - requested <= AXRecentFrameWriteFailure.maxAcceptedSizeSnap {
            hint = ObservedAxisHint(requested: requested, observed: observed)
        } else {
            minimum = max(minimum, observed)
        }
    }

    private static func relaxContradictedAxis(
        minimum: inout CGFloat,
        hint: inout ObservedAxisHint?,
        accepted: CGFloat
    ) {
        if accepted < minimum - FrameTolerance.frameWrite {
            minimum = 1
        }
        if let observed = hint?.observed, accepted < observed - FrameTolerance.frameWrite {
            hint = nil
        }
    }

    private static func updatedObservedMinimumAxis(
        existing: CGFloat,
        target: CGFloat,
        observed: CGFloat
    ) -> CGFloat {
        if observed > target + FrameTolerance.frameWrite { return observed }
        if target < existing - FrameTolerance.frameWrite { return 1 }
        return existing
    }

    func evaluateSizeConstraints(
        for token: WindowToken,
        axRef: AXWindowRef,
        admissionGeometry: WindowAdmissionGeometryEvidence? = nil
    ) -> WindowSizeConstraints {
        if let cached = workspaceManager.cachedConstraints(for: token) {
            return cached
        }

        let currentSize = admissionGeometry?.frame?.size
            ?? AXWindowService.framePreferFast(axRef)?.size
            ?? axManager.lastAppliedFrame(for: token.windowId)?.size
        let resolved = AXWindowService.sizeConstraints(axRef, currentSize: currentSize)
        workspaceManager.setCachedConstraints(resolved, for: token)
        return resolved
    }
}
