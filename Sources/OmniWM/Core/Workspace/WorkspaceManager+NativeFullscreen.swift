// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
import QuartzCore

extension WorkspaceManager {
    func nativeFullscreenRecord(for token: WindowToken) -> NativeFullscreenRecord? {
        guard let originalToken = nativeFullscreenOriginalToken(forCurrentToken: token),
              let record = nativeFullscreenRecordsByOriginalToken[originalToken],
              record.currentToken == token
        else {
            return nil
        }
        return record
    }

    func nativeFullscreenRecord(originalToken: WindowToken) -> NativeFullscreenRecord? {
        nativeFullscreenRecordsByOriginalToken[originalToken]
    }

    func hasNativeFullscreenRecord(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        nativeFullscreenRecordsByOriginalToken.values.contains {
            $0.workspaceId == workspaceId
        }
    }

    @discardableResult
    func requestNativeFullscreenEnter(
        _ token: WindowToken,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        let existing = nativeFullscreenRecord(for: token)
        guard existing != nil || nativeFullscreenRecordsByOriginalToken[token] == nil else { return false }
        var changed = rememberFocus(token, in: workspaceId)
        let originalToken = existing?.originalToken ?? token
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            transition: .enterRequested
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.workspaceId != workspaceId {
            record.workspaceId = workspaceId
            changed = true
        }
        if record.transition != .enterRequested {
            record.transition = .enterRequested
            changed = true
        }
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        return true
    }

    @discardableResult
    func markNativeFullscreenSuspended(
        _ token: WindowToken,
        ownsNativeFocus: Bool = true
    ) -> Bool {
        guard let entry = entry(for: token) else { return false }

        let existing = nativeFullscreenRecord(for: token)
        guard existing != nil || nativeFullscreenRecordsByOriginalToken[token] == nil else { return false }
        var changed = ownsNativeFocus ? rememberFocus(token, in: entry.workspaceId) : false
        let workspaceId = workspace(for: token) ?? entry.workspaceId
        let originalToken = existing?.originalToken ?? token
        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            transition: .suspended
        )

        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.workspaceId != workspaceId {
            record.workspaceId = workspaceId
            changed = true
        }
        if record.transition != .suspended {
            record.transition = .suspended
            changed = true
        }
        if existing == nil || changed {
            upsertNativeFullscreenRecord(record)
        }

        if layoutReason(for: token) != .nativeFullscreen {
            setLayoutReason(.nativeFullscreen, for: token)
            scriptWindowFullscreenObserver?.nativeFullscreenChanged(true, for: token, confirming: existing, in: self)
            changed = true
        }
        if ownsNativeFocus {
            changed = recordExternalFocus(pid: token.pid, windowId: token.windowId) || changed
        }
        return changed
    }

    @discardableResult
    func requestNativeFullscreenExit(_ token: WindowToken) -> Bool {
        let existing = nativeFullscreenRecord(for: token)
        if existing == nil, entry(for: token) == nil {
            return false
        }
        guard existing != nil || nativeFullscreenRecordsByOriginalToken[token] == nil else { return false }

        let originalToken = existing?.originalToken ?? token
        let workspaceId = existing?.workspaceId ?? workspace(for: token)
        guard let workspaceId else { return false }

        var record = existing ?? NativeFullscreenRecord(
            originalToken: originalToken,
            currentToken: token,
            workspaceId: workspaceId,
            transition: .exitRequested
        )

        var changed = existing == nil
        if record.currentToken != token {
            record.currentToken = token
            changed = true
        }
        if record.workspaceId != workspaceId {
            record.workspaceId = workspaceId
            changed = true
        }
        if record.transition != .exitRequested {
            record.transition = .exitRequested
            changed = true
        }
        if changed {
            upsertNativeFullscreenRecord(record)
        }

        return true
    }

    @discardableResult
    func restoreNativeFullscreenRecord(
        for token: WindowToken,
        clearsNativeFocusOwner: Bool = true
    ) -> Bool {
        let record = nativeFullscreenRecord(for: token)
        let resolvedToken = record?.currentToken ?? token
        if let record {
            _ = removeNativeFullscreenRecord(
                originalToken: record.originalToken,
                clearsNativeFocusOwner: clearsNativeFocusOwner
            )
        }
        let restored = restoreFromNativeState(
            for: resolvedToken,
            drainPendingRuntimeMonitorOverrides: false
        )
        if clearsNativeFocusOwner, record == nil, externalFocusToken == resolvedToken {
            _ = clearNativeFocusOwner()
            clearExternalFocusIdentity(matching: resolvedToken)
        }
        drainPendingRuntimeMonitorOverrideClears()
        if restored {
            scriptWindowFullscreenObserver?.nativeFullscreenChanged(
                false,
                for: resolvedToken,
                confirming: record,
                in: self
            )
        }
        return restored
    }

    func nativeFullscreenCommandTarget(frontmostToken: WindowToken?) -> WindowToken? {
        if let frontmostToken,
           let record = nativeFullscreenRecord(for: frontmostToken),
           record.currentToken == frontmostToken,
           record.transition == .suspended || record.transition == .exitRequested
        {
            return record.currentToken
        }

        let candidates = nativeFullscreenRecordsByOriginalToken.values.filter {
            $0.transition == .suspended || $0.transition == .exitRequested
        }
        guard candidates.count == 1 else { return nil }
        return candidates[0].currentToken
    }
}
