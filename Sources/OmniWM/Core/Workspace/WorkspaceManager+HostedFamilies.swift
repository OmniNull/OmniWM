// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WorkspaceManager {
    func hostedFamilyRoot(for token: WindowToken) -> WindowToken? {
        windowQueries.hostedFamilyRoot(for: token)
    }

    func hostedFamilyTokens(for token: WindowToken) -> [WindowToken] {
        windowQueries.hostedFamilyTokens(for: token)
    }

    func workspaceAssignmentEntries(includingFamiliesOf entries: [WindowState]) -> [WindowState] {
        var included: Set<WindowToken> = []
        return entries.flatMap { entry -> [WindowState] in
            let tokens = hostedFamilyTokens(for: entry.token)
            return (tokens.isEmpty ? [entry.token] : tokens).compactMap { token in
                guard included.insert(token).inserted else { return nil }
                return self.entry(for: token)
            }
        }
    }
}
