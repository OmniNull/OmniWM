// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

struct WindowAdmission {
    let mode: TrackedWindowMode
    var geometry: WindowAdmissionGeometryEvidence?

    var readOnlyFrame: CGRect? {
        geometry?.isSizeSettable == false ? geometry?.frame : nil
    }
}

extension WMController {
    private static let finderQuickLookSubrole = "Quick Look"
    private static let finderBundleId = "com.apple.finder"
    func shouldInheritTrackedParentWorkspace(for evaluation: WindowDecisionEvaluation) -> Bool {
        let facts = evaluation.facts
        guard let windowServer = facts.windowServer,
              windowServer.parentId != 0
        else {
            return false
        }

        let axFacts = facts.ax
        if axFacts.attributeFetchSucceeded {
            return AXWindowService.isSystemModalSurface(role: axFacts.role, subrole: axFacts.subrole)
        }

        if windowServer.hasDocumentTag {
            return false
        }

        return windowServer.hasModalTag || windowServer.hasTransientSurfaceEvidence
    }

    func allowsFloatingSpawnPlacement(
        for evaluation: WindowDecisionEvaluation,
        mode: TrackedWindowMode
    ) -> Bool {
        let ax = evaluation.facts.ax
        return mode == .floating
            && ax.attributeFetchSucceeded
            && ax.bundleId == Self.finderBundleId
            && ax.role == kAXWindowRole as String
            && ax.subrole == Self.finderQuickLookSubrole
    }

    func trackedModeForLifecycle(
        decision: WindowDecision,
        existingEntry: WindowState?
    ) -> TrackedWindowMode? {
        if let trackedMode = decision.trackedMode {
            return trackedMode
        }
        if decision.disposition == .undecided {
            return existingEntry?.mode
        }
        return nil
    }

    func resolveWindowAdmission(
        evaluation: WindowDecisionEvaluation,
        axRef: AXWindowRef,
        requestedMode: TrackedWindowMode,
        existingMode: TrackedWindowMode? = nil
    ) -> WindowAdmission? {
        let requiresValidation = existingMode == nil || existingMode == .floating && requestedMode == .tiling
        guard requiresValidation else { return WindowAdmission(mode: requestedMode) }

        let sizeSettable: Bool? = if let geometry = evaluation.admissionGeometry {
            geometry.isSizeSettable
        } else if requestedMode == .tiling {
            AXWindowService.sizeSettable(axRef)
        } else {
            nil
        }
        if requestedMode == .tiling, sizeSettable == nil { return nil }

        let serverFrame = WindowAdmissionGeometryEvidence.usableAppKitFrame(
            fromWindowServer: evaluation.facts.windowServer?.frame
        )
        let frame: CGRect? = if let serverFrame {
            serverFrame
        } else if let geometry = evaluation.admissionGeometry {
            WindowAdmissionGeometryEvidence.usableFrame(geometry.frame)
        } else {
            WindowAdmissionGeometryEvidence.usableFrame(AXWindowService.framePreferFast(axRef))
                ?? WindowAdmissionGeometryEvidence.usableFrame(try? AXWindowService.frame(axRef))
        }
        guard let frame else { return nil }
        return WindowAdmission(
            mode: sizeSettable == false ? .floating : requestedMode,
            geometry: .init(isSizeSettable: sizeSettable, frame: frame)
        )
    }

    static func isMeaningfulAdmissionFrame(_ frame: CGRect) -> Bool {
        WindowAdmissionGeometryEvidence.usableFrame(frame) != nil
    }

    func trackedModePreservingAutomaticFallbackState(
        decision: WindowDecision,
        existingEntry: WindowState?,
        context: WindowRuleReevaluationContext
    ) -> TrackedWindowMode? {
        if context == .automatic,
           let existingEntry,
           decision.isUnprovenIndependentRootDecision
        {
            floatDemotionTracker.clearSample(for: existingEntry.token)
            return existingEntry.mode
        }

        guard let trackedMode = trackedModeForLifecycle(
            decision: decision,
            existingEntry: existingEntry
        ) else {
            return nil
        }

        guard context == .automatic,
              let existingEntry,
              decision.layoutDecisionKind == .fallbackLayout
        else {
            return trackedMode
        }

        if existingEntry.mode == .floating,
           trackedMode == .tiling,
           existingEntry.managedReplacementMetadata?.transientWindowServerEvidence == true
        {
            return .floating
        }

        if existingEntry.mode == .tiling,
           trackedMode == .floating
        {
            return floatDemotionTracker.mode(for: existingEntry.token, decision: decision)
        }

        floatDemotionTracker.clearSample(for: existingEntry.token)
        return trackedMode
    }
}
