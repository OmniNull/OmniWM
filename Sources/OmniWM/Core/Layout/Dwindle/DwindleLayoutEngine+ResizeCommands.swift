// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    @discardableResult
    func resizeSelected(
        by delta: CGFloat,
        orientation targetOrientation: DwindleOrientation,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let selected = selectedNode(in: workspaceId)
        else { return false }

        var current = selected
        while let parent = current.parent {
            guard case let .split(orientation, ratio) = parent.kind else {
                current = parent
                continue
            }

            if orientation == targetOrientation,
               splitHasTwoVisibleBranches(parent, excluding: state.excludedTokens)
            {
                let isFirst = current.isFirstChild(of: parent)
                let newRatio = isFirst ? ratio + delta : ratio - delta

                let clampedRatio = clampedRatioRespectingMinimums(
                    newRatio,
                    for: parent,
                    innerGap: settings.innerGap,
                    excludedTokens: state.excludedTokens
                )
                guard clampedRatio != ratio else { return false }
                parent.kind = .split(orientation: orientation, ratio: clampedRatio)
                return true
            }

            current = parent
        }
        return false
    }

    @discardableResult
    func resizeSelected(
        toward direction: Direction,
        by step: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let selected = selectedNode(in: workspaceId)
        else { return false }

        let targetOrientation = direction.dwindleOrientation
        let preferFirstChild = targetOrientation == .horizontal
        var preferred: DwindleNode?
        var fallback: DwindleNode?
        var current = selected
        while preferred == nil, let parent = current.parent {
            if parent.splitOrientation == targetOrientation,
               splitHasTwoVisibleBranches(parent, excluding: state.excludedTokens)
            {
                if current.isFirstChild(of: parent) == preferFirstChild {
                    preferred = parent
                } else if fallback == nil {
                    fallback = parent
                }
            }
            current = parent
        }

        guard let split = preferred ?? fallback,
              case let .split(orientation, ratio) = split.kind
        else { return false }

        let grows = direction == .right || direction == .up
        let clampedRatio = clampedRatioRespectingMinimums(
            grows ? ratio + step : ratio - step,
            for: split,
            innerGap: settings.innerGap,
            excludedTokens: state.excludedTokens
        )
        let movesTowardDirection = grows ? clampedRatio > ratio : clampedRatio < ratio
        guard movesTowardDirection else { return false }
        split.kind = .split(orientation: orientation, ratio: clampedRatio)
        return true
    }

    @discardableResult
    func resizeFocusedWindow(by delta: CGFloat, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let selected = selectedNode(in: workspaceId)
        else { return false }

        var current = selected
        while let parent = current.parent {
            guard case let .split(orientation, ratio) = parent.kind else {
                current = parent
                continue
            }
            guard splitHasTwoVisibleBranches(parent, excluding: state.excludedTokens) else {
                current = parent
                continue
            }
            let isFirst = current.isFirstChild(of: parent)
            let newRatio = isFirst ? ratio + delta : ratio - delta
            let clampedRatio = clampedRatioRespectingMinimums(
                newRatio,
                for: parent,
                innerGap: settings.innerGap,
                excludedTokens: state.excludedTokens
            )
            guard clampedRatio != ratio else { return false }
            parent.kind = .split(orientation: orientation, ratio: clampedRatio)
            return true
        }
        return false
    }

    @discardableResult
    func balanceSizes(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId) else { return false }
        return balanceSizesRecursive(state.root, excludedTokens: state.excludedTokens)
    }

    private func balanceSizesRecursive(
        _ node: DwindleNode,
        excludedTokens: Set<WindowToken>
    ) -> Bool {
        guard case let .split(orientation, ratio) = node.kind else { return false }
        let first = node.firstChild()
        let second = node.secondChild()
        let firstVisible = first.map { subtreeHasVisibleMember($0, excluding: excludedTokens) } ?? false
        let secondVisible = second.map { subtreeHasVisibleMember($0, excluding: excludedTokens) } ?? false
        var changed = false
        if firstVisible, secondVisible {
            let target = clampedRatioRespectingMinimums(
                1.0,
                for: node,
                innerGap: settings.innerGap,
                excludedTokens: excludedTokens
            )
            changed = ratio != target
            if changed {
                node.kind = .split(orientation: orientation, ratio: target)
            }
        }
        if firstVisible, let first {
            changed = balanceSizesRecursive(first, excludedTokens: excludedTokens) || changed
        }
        if secondVisible, let second {
            changed = balanceSizesRecursive(second, excludedTokens: excludedTokens) || changed
        }
        return changed
    }

    @discardableResult
    func swapSplit(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let selected = selectedNode(in: workspaceId),
              let parent = firstVisibleSplitAncestor(
                  from: selected,
                  excluding: state.excludedTokens
              )?.split,
              parent.children.count == 2 else { return false }

        let first = parent.children[0]
        let second = parent.children[1]
        parent.children = [second, first]
        return true
    }

    @discardableResult
    func cycleSplitRatio(forward: Bool, in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        assertSanctionedMutation()
        guard let state = existingState(for: workspaceId),
              let selected = selectedNode(in: workspaceId),
              let ancestor = firstVisibleSplitAncestor(from: selected, excluding: state.excludedTokens),
              case let .split(orientation, currentRatio) = ancestor.split.kind else { return false }

        let presets = DwindleSettings.splitRatioPresets
        let isFirst = ancestor.child.isFirstChild(of: ancestor.split)
        let focusedRatio = isFirst ? currentRatio : 2 - currentRatio
        let currentIndex = presets.indices
            .min { abs(presets[$0] - focusedRatio) < abs(presets[$1] - focusedRatio) } ?? 1
        let preset = presets[(currentIndex + (forward ? 1 : presets.count - 1)) % presets.count]
        let newRatio = clampedRatioRespectingMinimums(
            isFirst ? preset : 2 - preset,
            for: ancestor.split,
            innerGap: settings.innerGap,
            excludedTokens: state.excludedTokens
        )
        guard newRatio != currentRatio else { return false }
        ancestor.split.kind = .split(orientation: orientation, ratio: newRatio)
        return true
    }
}
