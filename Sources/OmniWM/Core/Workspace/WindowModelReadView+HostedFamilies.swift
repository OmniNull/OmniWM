// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension WindowModel.ReadView {
    func hostedFamilyRoot(for token: WindowToken) -> WindowToken? {
        guard let metadata = entry(for: token)?.target.hostedMetadata else { return nil }
        guard let parent = metadata.role.parent else { return metadata.role == .main ? token : nil }
        guard let owner = entry(for: parent)?.target.hostedMetadata,
              owner.role == .main, owner.instanceID == metadata.instanceID else { return nil }
        return parent
    }

    func hostedFamilyTokens(for token: WindowToken) -> [WindowToken] {
        guard let root = hostedFamilyRoot(for: token),
              let owner = entry(for: root)?.target.hostedMetadata else { return [] }
        let children = allEntries().compactMap { entry -> WindowToken? in
            guard let metadata = entry.target.hostedMetadata,
                  metadata.role.parent == root, metadata.instanceID == owner.instanceID else { return nil }
            return entry.token
        }.sorted { $0.windowId < $1.windowId }
        return [root] + children
    }
}
