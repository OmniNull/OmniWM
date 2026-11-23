// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import QuartzCore

extension DwindleLayoutEngine {
    func calculateLayout(
        for workspaceId: WorkspaceDescriptor.ID,
        screen: CGRect,
        borderSafeFillScreen: CGRect? = nil,
        fullscreenScreen: CGRect? = nil,
        calculationSettings: DwindleSettings? = nil
    ) -> [WindowToken: CGRect] {
        guard let state = existingState(for: workspaceId) else { return [:] }
        let calculationSettings = calculationSettings ?? settings
        let excludedTokens = state.excludedTokens
        prepareProjectedLayoutFacts(
            for: state.root,
            boundaryEdges: .all,
            excludedTokens: excludedTokens,
            innerGap: calculationSettings.innerGap
        )
        guard state.root.projectedVisibleLeafCount > 0 else { return [:] }

        var output: [WindowToken: CGRect] = [:]
        output.reserveCapacity(state.root.projectedVisibleLeafCount)
        let tilingArea = screen
        let borderSafeFillArea = borderSafeFillScreen ?? fullscreenScreen ?? screen
        let fullscreenArea = fullscreenScreen ?? screen

        let calculation = LayoutCalculation(
            tilingArea: tilingArea,
            fullscreenArea: fullscreenArea,
            excludedTokens: excludedTokens,
            settings: calculationSettings
        )
        if state.root.projectedVisibleLeafCount == 1 {
            calculateSingleWindowLayout(
                root: state.root,
                calculation: calculation,
                borderSafeFillArea: borderSafeFillArea,
                output: &output
            )
        } else {
            calculateLayoutRecursive(node: state.root, rect: tilingArea, calculation: calculation, output: &output)
        }

        return output
    }

    private func calculateSingleWindowLayout(
        root: DwindleNode,
        calculation: LayoutCalculation,
        borderSafeFillArea: CGRect,
        output: inout [WindowToken: CGRect]
    ) {
        if let leaf = firstVisibleLeaf(in: root, excluding: calculation.excludedTokens),
           let tile = leaf.tile,
           let active = visibleMember(in: tile, excluding: calculation.excludedTokens)
        {
            let rect: CGRect
            if active.isFullscreen {
                rect = calculation.fullscreenArea
            } else {
                rect = singleWindowRect(
                    screen: calculation.tilingArea,
                    borderSafeFillScreen: borderSafeFillArea,
                    minSize: minimumSize(for: tile, excluding: calculation.excludedTokens),
                    settings: calculation.settings
                )
            }
            leaf.cachedFrame = rect
            let content = contentFrame(
                for: tile,
                member: active,
                tileFrame: rect,
                excludedTokens: calculation.excludedTokens
            )
            leaf.cachedContentFrame = content
            output[active.token] = content
        }
    }
}
