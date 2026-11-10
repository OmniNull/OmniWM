// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import OmniWMIPC

struct RuleReevaluationWindow {
    let token: WindowToken
    let axRef: AXWindowRef
    let existingEntry: WindowState?
    let evaluation: WMController.WindowDecisionEvaluation
    let ruleEffects: ManagedWindowRuleEffects
    let admissionHints: ManagedWindowAdmissionHints
    let admission: WindowAdmission
    let placementOrigin: WorkspacePlacementOrigin
    let createPlacementContext: WindowCreatePlacementContext?

    var mode: TrackedWindowMode {
        admission.mode
    }

    func admissionMetadata(workspaceId: WorkspaceDescriptor.ID) -> ManagedReplacementMetadata {
        let parentWindowId = self.evaluation.facts.windowServer.flatMap { $0.parentId == 0 ? nil : $0.parentId }
        return ManagedReplacementMetadata(
            bundleId: self.evaluation.facts.ax.bundleId ?? self.existingEntry?.managedReplacementMetadata?.bundleId,
            workspaceId: workspaceId,
            mode: self.existingEntry?.mode ?? self.mode,
            role: self.evaluation.facts.ax.role ?? self.existingEntry?.managedReplacementMetadata?.role,
            subrole: self.evaluation.facts.ax.subrole ?? self.existingEntry?.managedReplacementMetadata?.subrole,
            title: self.evaluation.facts.ax.title ?? self.existingEntry?.managedReplacementMetadata?.title,
            windowLevel: self.evaluation.facts.windowServer?.level ?? self.existingEntry?.managedReplacementMetadata?
                .windowLevel,
            parentWindowId: parentWindowId ?? self.existingEntry?.managedReplacementMetadata?.parentWindowId,
            frame: self.evaluation.facts.windowServer?.frame ?? self.existingEntry?.managedReplacementMetadata?.frame,
            transientWindowServerEvidence: self.existingEntry?.managedReplacementMetadata?
                .transientWindowServerEvidence == true
                || self.evaluation.facts.windowServer?.hasTransientSurfaceEvidence == true,
            degradedWindowServerChildEvidence: self.existingEntry?.managedReplacementMetadata?
                .degradedWindowServerChildEvidence == true
                || self.evaluation.facts.degradedWindowServerChildEvidence
        )
    }

    func updatedMetadata(for updatedEntry: WindowState) -> ManagedReplacementMetadata {
        let parentWindowId = if let windowServer = self.evaluation.facts.windowServer {
            windowServer.parentId == 0 ? nil : windowServer.parentId
        } else {
            updatedEntry.managedReplacementMetadata?.parentWindowId
        }
        return ManagedReplacementMetadata(
            bundleId: self.evaluation.facts.ax.bundleId ?? updatedEntry.managedReplacementMetadata?.bundleId,
            workspaceId: updatedEntry.workspaceId,
            mode: updatedEntry.mode,
            role: self.evaluation.facts.ax.role ?? updatedEntry.managedReplacementMetadata?.role,
            subrole: self.evaluation.facts.ax.subrole ?? updatedEntry.managedReplacementMetadata?.subrole,
            title: self.evaluation.facts.ax.title ?? updatedEntry.managedReplacementMetadata?.title,
            windowLevel: self.evaluation.facts.windowServer?.level ?? updatedEntry.managedReplacementMetadata?
                .windowLevel,
            parentWindowId: parentWindowId,
            frame: self.evaluation.facts.windowServer?.frame ?? updatedEntry.managedReplacementMetadata?.frame,
            transientWindowServerEvidence: updatedEntry.managedReplacementMetadata?
                .transientWindowServerEvidence == true
                || self.evaluation.facts.windowServer?.hasTransientSurfaceEvidence == true,
            degradedWindowServerChildEvidence: updatedEntry.managedReplacementMetadata?
                .degradedWindowServerChildEvidence == true
                || self.evaluation.facts.degradedWindowServerChildEvidence
        )
    }
}
