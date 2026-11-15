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
        width: CGFloat,
        in workspaceId: WorkspaceDescriptor.ID,
        workingWidth: CGFloat,
        gaps: CGFloat
    ) -> NiriContainerSizingState? {
        guard width.isFinite, width >= 1 else { return nil }
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
