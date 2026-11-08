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
              !isSizeAnimating(entry.token, in: entry.workspaceId),
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
        adoptObservedSizeEvidence(evidence, for: entry.token, in: entry.workspaceId)
    }

    func adoptObservedMinimumAfterTerminalSizeWriteFailure(_ refusal: AXFrameTerminalRefusal) {
        guard case .sizeWriteFailed = refusal.failureReason,
              let entry = workspaceManager.entry(forWindowId: refusal.windowId),
              entry.axRef != nil,
              entry.mode == .tiling,
              workspaceManager.hiddenState(for: entry.token) == nil,
              !isSizeAnimating(entry.token, in: entry.workspaceId)
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
        adoptObservedSizeEvidence(evidence, for: entry.token, in: entry.workspaceId)
    }

    func relaxObservedSizeEvidence(afterVerifiedWrite result: AXFrameApplyResult) {
        let token = WindowToken(pid: result.pid, windowId: result.windowId)
        guard result.writeResult.components == .all,
              result.writeResult.observedFrame != nil,
              let accepted = result.confirmedFrame?.size,
              let window = workspaceManager.withEntry(token, { (axRef: $0.axRef, workspaceId: $0.workspaceId) }),
              let axRef = window.axRef,
              sameAXWindowIdentity(axRef, result.expectedWindow),
              var evidence = workspaceManager.observedSizeEvidence(for: token)
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
        adoptObservedSizeEvidence(evidence, for: token, in: window.workspaceId)
    }

    func reportedMinimumSize(for token: WindowToken) -> CGSize? {
        guard let entry = workspaceManager.entry(for: token) else { return nil }
        var minSize = entry.target.hostedMetadata?.minimumSize
            ?? workspaceManager.cachedConstraints(for: token, maxAge: .greatestFiniteMagnitude)?.minSize
            ?? CGSize(width: 1, height: 1)
        if let minWidth = entry.ruleEffects.minWidth {
            minSize.width = max(minSize.width, minWidth)
        }
        if let minHeight = entry.ruleEffects.minHeight {
            minSize.height = max(minSize.height, minHeight)
        }
        return minSize
    }

    func forgetObservedHeights(of tokens: [WindowToken]) {
        for token in tokens {
            guard let entry = workspaceManager.entry(for: token),
                  var evidence = workspaceManager.observedSizeEvidence(for: token),
                  evidence.minSize.height > 1 || evidence.hints.height != nil
            else { continue }
            MouseTrace.record(
                "live-drag stack guess cleared win=\(token.windowId) height=\(Int(evidence.minSize.height.rounded()))"
            )
            evidence.minSize.height = 1
            evidence.hints.height = nil
            adoptObservedSizeEvidence(evidence, for: token, in: entry.workspaceId)
        }
    }

    func isSizeAnimating(_ token: WindowToken, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        guard settings.niri.macOSFusion,
              let window = niriEngine?.findNode(for: token, in: workspaceId)
        else { return false }
        if window.heightAnimation != nil { return true }
        guard let column = window.parent as? NiriContainer else { return false }
        return column.hasWidthAnimationRunning || column.hasHeightAnimationRunning
    }

    private func adoptObservedSizeEvidence(
        _ evidence: ObservedSizeEvidence,
        for token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) {
        guard workspaceManager.setObservedSizeEvidence(evidence, for: token) else { return }
        workspaceManager.invalidateLayout(for: [workspaceId])
        layoutRefreshController.requestRelayout(
            reason: .observedConstraintsChanged,
            affectedWorkspaceIds: [workspaceId]
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
