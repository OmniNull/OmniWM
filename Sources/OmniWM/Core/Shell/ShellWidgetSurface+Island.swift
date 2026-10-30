// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import OmniWMScriptHost
import OmniWMShellCore

extension ShellWidgetSurface {
    func islandRegions() -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: view.bounds.size)
        let presentation = placementPresentation
        let moving = follows.compactMap { $0.value.motion == nil ? nil : $0.key }
        let regions = layout.core.elements { _ in true }.compactMap { handle -> CGRect? in
            let paint = layout.core.paint(of: handle)
            guard !paint.masks else { return nil }
            let content = layout.core.content(of: handle)
            guard !content.decorative else { return nil }
            let actionable = content.acceptsPointer
            var rect = CGRect(presentedFrame(of: handle, in: presentation)).intersection(bounds)
            var current = handle
            var opacity: Float = 1
            while layout.core.contains(current) {
                if moving.contains(current) { return nil }
                opacity *= layout.core.paint(of: current).opacity
                if layout.core.content(of: current).scrolls || isManipulationClip(current) {
                    rect = rect.intersection(CGRect(presentedFrame(of: current, in: presentation)))
                }
                current = layout.core.parent(of: current)
            }
            guard !rect.isNull, !rect.isEmpty, actionable || opacity > 0 else { return nil }
            if actionable { return rect }
            switch layout.core.kind(of: handle) {
            case .glass,
                 .shape:
                return nil
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
        return regions + glassIslandRegions(clippedTo: bounds, in: presentation, moving: moving)
    }

    private func glassIslandRegions(
        clippedTo bounds: CGRect,
        in presentation: SurfacePresentation?,
        moving: [ElementHandle]
    ) -> [CGRect] {
        var regions: [CGRect] = []
        let rings = degenerateRingBodies()
        for handle in glassShapeHandles where hits(handle) {
            let target = followedTarget(of: handle) ?? boundTarget(of: handle)
            guard !moving.contains(where: { $0 == target || isWithin(handle, $0) }) else { continue }
            regions.append(contentsOf: glassRegions(handle, clippedTo: bounds, in: presentation, excluding: rings))
        }
        for target in moving {
            guard let record = follows[target], let motion = record.motion else { continue }
            var paths = [motion.trajectoryBounds]
            for handle in glassShapeHandles where hits(handle) && followedTarget(of: handle) == target {
                paths.append(motion.trajectoryBounds(
                    of: CGRect(layout.core.absoluteFrame(of: handle)), about: record.frame
                ))
            }
            for handle in glassShapeHandles where hits(handle) && boundTarget(of: handle) == target {
                paths += glassRegions(handle, clippedTo: bounds, in: presentation, excluding: rings)
                if let pads = boundShapes[handle]?.source?.pads {
                    let range = ShellSpringDynamics.range(
                        displacement: motion.start.width - motion.target.width,
                        initialVelocity: motion.startVelocity.width, spring: motion.spring
                    )
                    let scale = max(0, (motion.target.width + range.upperBound) / record.frame.width)
                    let left = min(0, pads.left * scale), top = min(0, pads.top * scale)
                    let right = max(0, pads.right * scale), bottom = max(0, pads.bottom * scale)
                    paths.append(CGRect(
                        x: motion.trajectoryBounds.minX + left, y: motion.trajectoryBounds.minY + top,
                        width: motion.trajectoryBounds.width + right - left,
                        height: motion.trajectoryBounds.height + bottom - top
                    ))
                }
            }
            regions += paths.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        }
        return regions
    }
}
