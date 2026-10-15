// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics

struct NiriSizingGeometry: Equatable {
    let workingFrame: CGRect
    let gaps: CGFloat
    let orientation: Monitor.Orientation
}
