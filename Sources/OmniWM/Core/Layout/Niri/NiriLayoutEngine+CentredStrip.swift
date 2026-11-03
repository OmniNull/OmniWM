// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func centresFittingStrip(in workspaceId: WorkspaceDescriptor.ID) -> Bool {
        centersFittingStrips
            && effectiveSettings(in: workspaceId).alwaysCenterSingleColumn
            && !isLiveColumnMoveActive(in: workspaceId)
    }

    func centresWholeStrip(_ columns: [NiriContainer], context: NiriInteractionContext) -> Bool {
        guard effectiveSettings(in: context.workspaceId).alwaysCenterSingleColumn else { return false }
        return columns.count == 1
            || centresFittingStrip(in: context.workspaceId)
            && ViewportState.centredStripStart(
                of: columns,
                context: context,
                scale: displayScale(in: context.workspaceId)
            ) != nil
    }

    func fittingStripDrift(_ strip: [LiveColumnMove.StripColumn], context: NiriInteractionContext) -> CGFloat? {
        guard centresFittingStrip(in: context.workspaceId),
              let first = strip.first,
              let last = strip.last
        else { return nil }
        let frame = context.workingFrame
        guard let offset = ViewportState.centredStripOffset(
            stripSpan: last.maxX - first.minX,
            viewSpan: frame.width,
            gap: context.gaps,
            scale: displayScale(in: context.workspaceId)
        ) else { return nil }
        return first.minX - (frame.minX - offset)
    }
}
