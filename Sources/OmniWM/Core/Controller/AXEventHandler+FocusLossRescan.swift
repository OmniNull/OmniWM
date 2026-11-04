// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct FocusLossRescans {
    struct Held {
        var appPIDs: Set<pid_t>
        let deadline: Task<Void, Never>
    }

    var previouslyFocusedToken: WindowToken?
    var heldByWindowId: [Int: Held] = [:]
    var sleeper: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

extension AXEventHandler {
    static var focusLossRescanDeadline: Duration {
        stabilizationRetryDelay * (createdWindowRetryLimit + 1)
    }

    var previouslyFocusedManagedToken: WindowToken? {
        get { focusLossRescans.previouslyFocusedToken }
        set { focusLossRescans.previouslyFocusedToken = newValue }
    }

    func untrackedFocusWindowId(_ facts: ActivationFacts) -> Int? {
        guard let windowId = facts.focusedWindow?.axRef.windowId,
              controller?.workspaceManager.entry(forWindowId: windowId) == nil
        else { return nil }
        return windowId
    }

    func rescanAppThatLostFocus(newFocusWindowId: Int? = nil) {
        guard let controller else { return }
        let focusedToken = controller.workspaceManager.nativeManagedFocusToken
        guard focusedToken != nil || controller.workspaceManager.externalFocusToken != nil else { return }
        defer { previouslyFocusedManagedToken = focusedToken }
        guard let previousToken = previouslyFocusedManagedToken,
              previousToken != focusedToken,
              controller.workspaceManager.entry(for: previousToken) != nil
        else { return }
        if let newFocusWindowId, awaitsFirstFrame(windowId: newFocusWindowId, controller: controller) {
            holdFocusLossRescan(of: previousToken.pid, until: newFocusWindowId)
        } else {
            requestTargetedFullRescan(for: [previousToken.pid])
        }
    }

    func releaseFocusLossRescan(windowId: Int) {
        guard let held = focusLossRescans.heldByWindowId.removeValue(forKey: windowId) else { return }
        held.deadline.cancel()
        requestTargetedFullRescan(for: held.appPIDs)
    }

    func cancelFocusLossRescans() {
        for held in focusLossRescans.heldByWindowId.values { held.deadline.cancel() }
        focusLossRescans.heldByWindowId.removeAll()
    }

    private func awaitsFirstFrame(windowId: Int, controller: WMController) -> Bool {
        if let entry = controller.workspaceManager.entry(forWindowId: windowId) { return entry.mode == .tiling }
        guard let id = UInt32(exactly: windowId), let retry = admissionRetryStateByWindowId[id] else { return false }
        return !retry.exhausted
    }

    private func holdFocusLossRescan(of pid: pid_t, until windowId: Int) {
        if focusLossRescans.heldByWindowId[windowId] != nil {
            focusLossRescans.heldByWindowId[windowId]?.appPIDs.insert(pid)
            return
        }
        let sleeper = focusLossRescans.sleeper
        let deadline = Task { @MainActor [weak self] in
            do { try await sleeper(Self.focusLossRescanDeadline) } catch { return }
            self?.releaseFocusLossRescan(windowId: windowId)
        }
        focusLossRescans.heldByWindowId[windowId] = .init(appPIDs: [pid], deadline: deadline)
    }
}
