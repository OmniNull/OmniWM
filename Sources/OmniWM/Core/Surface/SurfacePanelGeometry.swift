// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics

enum SurfacePanelGeometry {
    static func backingFrame(for frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX.rounded(.down), y: frame.minY.rounded(.down),
            width: frame.width.rounded(.up), height: frame.height.rounded(.up)
        )
    }
}
