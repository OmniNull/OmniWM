// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func openingContainerSizingState(
        width: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID,
        workingWidth: CGFloat,
        gaps: CGFloat
    ) -> NiriContainerSizingState? {
        guard effectiveSettings(in: workspaceId).defaultContainerPrimarySpan == nil,
              width.isFinite,
              width >= 1
        else { return nil }
        return NiriContainerSizingState(
            width: .fixed(min(width, workingWidth - gaps * 2)),
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: nil,
            hasManualSingleWindowWidthOverride: false,
            height: .proportion(resolvedContainerResetPrimarySpan(in: workspaceId).proportion),
            isFullHeight: false,
            savedHeight: nil,
            hasManualSingleWindowHeightOverride: false
        )
    }
}
