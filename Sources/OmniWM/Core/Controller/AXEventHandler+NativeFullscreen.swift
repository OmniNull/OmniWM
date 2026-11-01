// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension AXEventHandler {
    @discardableResult
    func restoreManagedWindowFromNativeFullscreen(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        let hadRecord = controller.workspaceManager.nativeFullscreenRecord(for: entry.token) != nil
        guard hadRecord || controller.workspaceManager.layoutReason(for: entry.token) == .nativeFullscreen else {
            return false
        }
        let restored = controller.workspaceManager.restoreNativeFullscreenRecord(for: entry.token) || hadRecord
        if restored {
            controller.layoutRefreshController.markNativeFullscreenRestoredForFrameApply(entry.token)
        }
        return restored
    }

    @discardableResult
    func suspendManagedWindowForNativeFullscreen(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        controller.layoutRefreshController.cancelPendingScratchpadReveal(for: entry.token)
        let changed = controller.workspaceManager.markNativeFullscreenSuspended(entry.token)
        if changed {
            requestNativeFullscreenRelayout(for: entry.token, fallback: entry.workspaceId)
        }
        return changed
    }

    private func requestNativeFullscreenRelayout(
        for token: WindowToken,
        fallback workspaceId: WorkspaceDescriptor.ID
    ) {
        guard let controller else { return }
        controller.layoutRefreshController.requestImmediateRelayout(
            reason: .appActivationTransition,
            affectedWorkspaceIds: [
                controller.workspaceManager.workspace(for: token) ?? workspaceId
            ]
        )
    }

    func handleNativeFullscreenDestroy(
        _ token: WindowToken,
        evidence: WindowDestroyEvidence
    ) -> Bool {
        guard evidence == .transientLifecycle else { return false }
        guard let controller,
              let entry = controller.workspaceManager.entry(for: token)
        else {
            return false
        }

        let record = controller.workspaceManager.nativeFullscreenRecord(for: token)
        guard record == nil ? shouldPreserveNativeFullscreenDestroy(entry) : record?.currentToken == token else {
            return false
        }
        let ownsNativeFocus = record == nil || controller.workspaceManager.externalFocusToken == token

        clearManagedFocusState(
            matching: token,
            workspaceId: entry.workspaceId,
            preservesExternalFocusIdentity: ownsNativeFocus
        )
        _ = controller.workspaceManager.markNativeFullscreenSuspended(
            entry.token, ownsNativeFocus: ownsNativeFocus
        )
        requestNativeFullscreenRelayout(for: token, fallback: entry.workspaceId)
        return true
    }

    private func shouldPreserveNativeFullscreenDestroy(_ entry: WindowState) -> Bool {
        guard let controller else { return false }
        guard entry.mode == .tiling else { return false }
        guard controller.workspaceManager.nativeManagedFocusToken == entry.token else { return false }
        guard !controller.workspaceManager.isScratchpadToken(entry.token) else { return false }
        guard let descriptor = controller.workspaceManager.descriptor(for: entry.workspaceId) else { return false }
        guard controller.settings.workspaces.layoutType(for: descriptor.name) != .dwindle else { return false }
        if entry.observedState.isNativeFullscreen {
            return true
        }
        if controller.workspaceManager.isWindowOnObservedNativeFullscreenSpace(entry.windowId) {
            return true
        }
        guard let axRef = entry.axRef else { return false }
        return AXWindowService.isFullscreenAttributeSet(axRef)
    }
}
