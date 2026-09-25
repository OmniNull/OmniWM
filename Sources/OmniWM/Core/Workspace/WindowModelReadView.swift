// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension WindowModel {
    @MainActor
    struct ReadView {
        private let model: WindowModel

        init(model: WindowModel) {
            self.model = model
        }

        func handle(for token: WindowToken) -> WindowHandle? {
            model.handle(for: token)
        }

        func entry(for token: WindowToken) -> WindowState? {
            model.entry(for: token)
        }

        func entry(for handle: WindowHandle) -> WindowState? {
            model.entry(for: handle)
        }

        func entry(forPid pid: pid_t, windowId: Int) -> WindowState? {
            model.entry(forPid: pid, windowId: windowId)
        }

        func entry(forWindowId windowId: Int) -> WindowState? {
            model.entry(forWindowId: windowId)
        }

        func entry(
            forWindowId windowId: Int,
            inVisibleWorkspaces visibleIds: Set<WorkspaceDescriptor.ID>
        ) -> WindowState? {
            model.entry(forWindowId: windowId, inVisibleWorkspaces: visibleIds)
        }

        func entries(forPid pid: pid_t) -> [WindowState] {
            model.entries(forPid: pid)
        }

        func hasEntries(forPid pid: pid_t) -> Bool {
            model.hasEntries(forPid: pid)
        }

        func windows(in workspace: WorkspaceDescriptor.ID) -> [WindowState] {
            model.windows(in: workspace)
        }

        func windowCount(in workspace: WorkspaceDescriptor.ID) -> Int {
            model.windowCount(in: workspace)
        }

        func windows(in workspace: WorkspaceDescriptor.ID, mode: TrackedWindowMode) -> [WindowState] {
            model.windows(in: workspace, mode: mode)
        }

        func firstWindow(
            in workspace: WorkspaceDescriptor.ID,
            mode: TrackedWindowMode,
            where predicate: (WindowState) -> Bool
        ) -> WindowState? {
            for token in model.tokens(in: workspace, mode: mode) {
                if let entry = model.entry(for: token), predicate(entry) {
                    return entry
                }
            }
            return nil
        }

        func allEntries() -> [WindowState] {
            model.allEntries()
        }

        func allEntries(mode: TrackedWindowMode) -> [WindowState] {
            model.allEntries(mode: mode)
        }

        func workspace(for token: WindowToken) -> WorkspaceDescriptor.ID? {
            model.workspace(for: token)
        }

        func mode(for token: WindowToken) -> TrackedWindowMode? {
            model.mode(for: token)
        }

        func lifecyclePhase(for token: WindowToken) -> WindowLifecyclePhase? {
            model.lifecyclePhase(for: token)
        }

        func observedState(for token: WindowToken) -> ObservedWindowState? {
            model.observedState(for: token)
        }

        func desiredState(for token: WindowToken) -> DesiredWindowState? {
            model.desiredState(for: token)
        }

        func restoreIntent(for token: WindowToken) -> RestoreIntent? {
            model.restoreIntent(for: token)
        }

        func managedReplacementMetadata(for token: WindowToken) -> ManagedReplacementMetadata? {
            model.managedReplacementMetadata(for: token)
        }

        func floatingState(for token: WindowToken) -> FloatingState? {
            model.floatingState(for: token)
        }

        func manualLayoutOverride(for token: WindowToken) -> ManualWindowOverride? {
            model.manualLayoutOverride(for: token)
        }

        func admissionHints(for token: WindowToken) -> ManagedWindowAdmissionHints? {
            model.admissionHints(for: token)
        }

        func hiddenState(for token: WindowToken) -> HiddenState? {
            model.hiddenState(for: token)
        }

        func isHiddenInCorner(_ token: WindowToken) -> Bool {
            model.isHiddenInCorner(token)
        }

        func layoutReason(for token: WindowToken) -> LayoutReason {
            model.layoutReason(for: token)
        }

        func isNativeFullscreenSuspended(_ token: WindowToken) -> Bool {
            model.isNativeFullscreenSuspended(token)
        }

        func cachedConstraints(for token: WindowToken, maxAge: TimeInterval = 5.0) -> WindowSizeConstraints? {
            model.cachedConstraints(for: token, maxAge: maxAge)
        }

        func observedSizeEvidence(for token: WindowToken) -> ObservedSizeEvidence? {
            model.observedSizeEvidence(for: token)
        }
    }
}
