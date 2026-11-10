// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

extension AXEventHandler {
    func makeManagedReplacementMetadata(
        bundleId: String?,
        workspaceId: WorkspaceDescriptor.ID,
        mode: TrackedWindowMode,
        facts: WindowRuleFacts,
        readOnlyAdmissionFrame: CGRect? = nil
    ) -> ManagedReplacementMetadata {
        ManagedReplacementMetadata(
            bundleId: bundleId,
            workspaceId: workspaceId,
            mode: mode,
            role: facts.ax.role,
            subrole: facts.ax.subrole,
            title: facts.ax.title,
            windowLevel: facts.windowServer?.level,
            parentWindowId: normalizedParentWindowId(facts.windowServer?.parentId),
            frame: facts.windowServer?.frame,
            transientWindowServerEvidence: facts.windowServer?.hasTransientSurfaceEvidence ?? false,
            degradedWindowServerChildEvidence: facts.degradedWindowServerChildEvidence,
            readOnlyAdmissionFrame: readOnlyAdmissionFrame
        )
    }

    private func normalizedParentWindowId(_ parentWindowId: UInt32?) -> UInt32? {
        guard let parentWindowId, parentWindowId != 0 else { return nil }
        return parentWindowId
    }

    func cachedManagedReplacementMetadata(
        for entry: WindowState,
        fallbackBundleId: String?
    ) -> ManagedReplacementMetadata {
        var metadata = entry.managedReplacementMetadata ?? ManagedReplacementMetadata(
            bundleId: fallbackBundleId,
            workspaceId: entry.workspaceId,
            mode: entry.mode,
            role: nil,
            subrole: nil,
            title: nil,
            windowLevel: nil,
            parentWindowId: nil,
            frame: nil
        )
        metadata.bundleId = metadata.bundleId ?? fallbackBundleId
        metadata.workspaceId = entry.workspaceId
        metadata.mode = entry.mode
        if entry.mode == .floating,
           let floatingFrame = controller?.workspaceManager.floatingState(for: entry.token)?.lastFrame
        {
            metadata.frame = ScreenCoordinateSpace.toWindowServer(rect: floatingFrame)
        } else if let appliedFrame = controller?.axManager.lastAppliedFrame(for: entry.windowId) {
            metadata.frame = ScreenCoordinateSpace.toWindowServer(rect: appliedFrame)
        }
        return metadata
    }

    func overlayWindowServerInfo(
        _ windowInfo: WindowServerInfo?,
        onto metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementMetadata {
        guard let windowInfo else { return metadata }
        var metadata = metadata
        metadata.title = windowInfo.title ?? metadata.title
        metadata.windowLevel = windowInfo.level
        metadata.parentWindowId = normalizedParentWindowId(windowInfo.parentId) ?? metadata.parentWindowId
        if !windowInfo.frame.isNull, !windowInfo.frame.isEmpty {
            metadata.frame = windowInfo.frame
        }
        return metadata
    }

    func managedReplacementFacts(
        for axRef: AXWindowRef,
        pid: pid_t,
        bundleId: String?,
        windowInfo: WindowServerInfo?,
        includeTitle: Bool
    ) -> WindowRuleFacts {
        let app = NSRunningApplication(processIdentifier: pid)
        return WindowRuleFacts(
            appName: app?.localizedName,
            ax: AXWindowService.collectWindowFacts(
                axRef,
                appPolicy: app?.activationPolicy,
                bundleId: bundleId,
                includeTitle: includeTitle
            ).facts,
            sizeConstraints: nil,
            windowServer: windowInfo
        )
    }

    func managedReplacementNeedsLiveAXFacts(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        guard metadata.role != nil, metadata.subrole != nil else {
            return true
        }
        return !managedReplacementHasStructuralAnchor(metadata)
    }

    func managedReplacementCorrelationPolicy(
        for metadata: ManagedReplacementMetadata
    ) -> ManagedReplacementCorrelationPolicy? {
        guard metadata.role != nil,
              metadata.subrole != nil,
              managedReplacementHasStructuralAnchor(metadata)
        else { return nil }
        return .structural
    }

    func managedReplacementMetadataMatches(
        oldToken: WindowToken,
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        if managedReplacementIsDirectFloatingChild(oldToken: oldToken, new: new, newFacts: newFacts) {
            return false
        }

        guard managedReplacementCorrelationPolicy(for: old) != nil,
              managedReplacementCorrelationPolicy(for: new) != nil,
              managedReplacementBundleIdsMatch(old.bundleId, new.bundleId),
              old.workspaceId == new.workspaceId,
              old.role == new.role,
              old.subrole == new.subrole,
              managedReplacementWindowLevelsMatch(old.windowLevel, new.windowLevel)
        else {
            return false
        }

        return managedReplacementStructuralAnchorsMatch(oldToken: oldToken, old: old, new: new)
    }

    private func managedReplacementIsDirectFloatingChild(
        oldToken: WindowToken,
        new: ManagedReplacementMetadata,
        newFacts: WindowRuleFacts?
    ) -> Bool {
        guard new.mode == .floating,
              let oldWindowId = UInt32(exactly: oldToken.windowId),
              new.parentWindowId == oldWindowId
        else {
            return false
        }

        if managedReplacementHasAXChildEvidence(new) {
            return true
        }

        if new.degradedWindowServerChildEvidence {
            return true
        }

        return newFacts?.degradedWindowServerChildEvidence == true
    }

    private func managedReplacementHasAXChildEvidence(_ metadata: ManagedReplacementMetadata) -> Bool {
        if metadata.role == kAXSheetRole as String {
            return true
        }

        guard let subrole = metadata.subrole else {
            return false
        }

        return subrole == kAXDialogSubrole as String
            || subrole == kAXSystemDialogSubrole as String
            || subrole != kAXStandardWindowSubrole as String
    }

    private func managedReplacementHasStructuralAnchor(
        _ metadata: ManagedReplacementMetadata
    ) -> Bool {
        metadata.parentWindowId != nil || metadata.frame != nil
    }

    private func managedReplacementBundleIdsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs?.lowercased(), rhs?.lowercased()) {
        case let (lhs?, rhs?):
            return lhs == rhs
        default:
            return true
        }
    }

    private func managedReplacementWindowLevelsMatch(_ lhs: Int32?, _ rhs: Int32?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    private func managedReplacementStructuralAnchorsMatch(
        oldToken: WindowToken,
        old: ManagedReplacementMetadata,
        new: ManagedReplacementMetadata
    ) -> Bool {
        let framesClose = framesAreCloseForManagedReplacement(old.frame, new.frame)
        let hasFrameEvidence = old.frame != nil && new.frame != nil

        switch (old.parentWindowId, new.parentWindowId) {
        case let (oldParentWindowId?, newParentWindowId?) where oldParentWindowId == newParentWindowId:
            return hasFrameEvidence ? framesClose : true
        case let (_, newParentWindowId?) where UInt32(exactly: oldToken.windowId) == newParentWindowId:
            return framesClose
        case (_?, _?):
            return false
        default:
            return framesClose
        }
    }

    private func framesAreCloseForManagedReplacement(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else { return false }

        return abs(lhs.midX - rhs.midX) <= FrameTolerance.managedReplacementCenter
            && abs(lhs.midY - rhs.midY) <= FrameTolerance.managedReplacementCenter
            && abs(lhs.width - rhs.width) <= FrameTolerance.managedReplacementSize
            && abs(lhs.height - rhs.height) <= FrameTolerance.managedReplacementSize
    }
}
