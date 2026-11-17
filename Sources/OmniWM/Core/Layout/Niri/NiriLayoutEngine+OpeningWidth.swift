// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension NiriLayoutEngine {
    func noteOpeningWindow(_ token: WindowToken) {
        openingWindows.insert(token)
    }

    func takeOpeningWindow(_ token: WindowToken) -> Bool {
        openingWindows.remove(token) != nil
    }

    func keepsEnteringWindowWidth(
        opening: Bool,
        hasRuleWidth: @autoclosure () -> Bool,
        keepsExistingWidth: Bool,
        in workspaceId: WorkspaceDescriptor.ID
    ) -> Bool {
        guard opening else { return keepsExistingWidth }
        return effectiveSettings(in: workspaceId).opensNewWindowsAtAppWidth && !hasRuleWidth()
    }

    func keptContainerSizingState(
        primarySpan: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID,
        workingSpan: CGFloat,
        gaps: CGFloat,
        orientation: Monitor.Orientation
    ) -> NiriContainerSizingState? {
        guard primarySpan.isFinite, primarySpan >= 1 else { return nil }
        let kept = ProportionalSize.fixed(min(primarySpan, workingSpan - gaps * 2))
        let fallback = ProportionalSize.proportion(resolvedContainerResetPrimarySpan(in: workspaceId).proportion)
        return NiriContainerSizingState(
            width: orientation == .horizontal ? kept : fallback,
            presetWidthIndex: nil,
            isFullWidth: false,
            savedWidth: nil,
            hasManualSingleWindowWidthOverride: false,
            height: orientation == .vertical ? kept : fallback,
            isFullHeight: false,
            savedHeight: nil,
            hasManualSingleWindowHeightOverride: false
        )
    }
}
