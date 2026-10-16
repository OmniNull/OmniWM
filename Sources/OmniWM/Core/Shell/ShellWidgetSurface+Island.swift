// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import OmniWMScriptHost
import OmniWMShellCore

extension ShellWidgetSurface {
    func islandRegions() -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        return layout.core.elements { _ in true }.compactMap { handle in
            let paint = layout.core.paint(of: handle)
            guard !paint.masks else { return nil }
            let content = layout.core.content(of: handle)
            let actionable = content.acceptsPointer
            var rect = CGRect(layout.core.absoluteFrame(of: handle)).intersection(bounds)
            var current = handle
            var opacity: Float = 1
            while layout.core.contains(current) {
                opacity *= layout.core.paint(of: current).opacity
                if layout.core.content(of: current).scrolls {
                    rect = rect.intersection(CGRect(layout.core.absoluteFrame(of: current)))
                }
                current = layout.core.parent(of: current)
            }
            guard !rect.isNull, !rect.isEmpty, actionable || opacity > 0 else { return nil }
            if actionable { return rect }
            switch layout.core.kind(of: handle) {
            case .group,
                 .box:
                return paint.fill.isVisible || (paint.stroke.isVisible && paint.strokeWidth > 0)
                    || (paint.material > 0 && UInt32(paint.material) != OMNI_MATERIAL_CLEAR) ? rect : nil
            case .label,
                 .symbol:
                return content.text == 0 ? nil : rect
            case .image,
                 .bitmap,
                 .progress,
                 .slider,
                 .path,
                 .shader,
                 .input:
                return rect
            }
        }
    }
}
