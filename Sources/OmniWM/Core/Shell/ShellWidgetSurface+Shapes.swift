// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore

extension ShellWidgetSurface {
    func containsShape(at point: CGPoint) -> Bool {
        let root = layout.core.rootFrame
        guard point.x >= 0, point.y >= 0, point.x < CGFloat(root.width), point.y < CGFloat(root.height) else {
            return false
        }
        let presentation = presentation
        let rings = degenerateRingBodies()
        if glassShapeHandles.contains(where: {
            hits($0) && glassContains($0, at: point, in: presentation, excluding: rings)
        }) {
            return true
        }
        return layout.core.covers(x: Float(point.x), y: Float(point.y), presentation: presentation, where: { handle in
            if layout.core.paint(of: handle).masks {
                return false
            }
            switch layout.core.kind(of: handle) {
            case .glass,
                 .shape:
                return false
            case .shader:
                return shaderCovers(handle.slot, at: layoutPoint(point, in: handle, presentation: presentation))
            case .label,
                 .input,
                 .symbol,
                 .image,
                 .bitmap,
                 .progress,
                 .slider,
                 .path:
                return true
            case .group,
                 .box:
                let paint = layout.core.paint(of: handle)
                let content = layout.core.content(of: handle)
                return paint.fill.isVisible || (paint.stroke.isVisible && paint.strokeWidth > 0)
                    || (paint.material > 0 && UInt32(paint.material) != OMNI_MATERIAL_CLEAR)
                    || content.action != 0 || content.secondaryAction != 0 || content.scrollAction != 0
                    || content.opensPopout || content.menu || content.drag || content.cursor != .none
            }
        }, clip: clips)
    }

    func hits(_ handle: ElementHandle) -> Bool {
        layout.core.contains(handle) && layout.core.content(of: handle).glassHit
    }

    func degenerateRingBodies() -> Set<ElementHandle> {
        var bodies: Set<ElementHandle> = []
        for shape in glassShapeHandles where layout.core.contains(shape) {
            let content = layout.core.content(of: shape)
            guard content.glassShape == 2 else { continue }
            let frame = layout.core.layoutFrame(of: shape)
            if frame.width > 0, frame.height > 0,
               content.params.x <= 0 || content.params.x * 2 >= min(frame.width, frame.height)
            { bodies.insert(layout.core.parent(of: shape)) }
        }
        return bodies
    }

    func glassContains(
        _ handle: ElementHandle,
        at point: CGPoint,
        in presentation: SurfacePresentation?,
        excluding rings: Set<ElementHandle>
    ) -> Bool {
        guard let geometry = glassGeometry(handle, in: presentation, excluding: rings), geometry.clip.contains(point)
        else {
            return false
        }
        var current = layout.core.parent(of: handle)
        while layout.core.contains(current) {
            let local = layoutPoint(point, in: current, presentation: presentation)
            guard clips(current, Float(local.x), Float(local.y)) else { return false }
            current = layout.core.parent(of: current)
        }
        let shape = geometry.shape
        if shape.kind == 1 {
            let x = (point.x - shape.rect.midX) / (shape.rect.width / 2)
            let y = (point.y - shape.rect.midY) / (shape.rect.height / 2)
            return x * x + y * y <= 1
        }
        guard Self.glassRoundedRectContains(point, rect: shape.rect, radius: shape.radius) else { return false }
        guard shape.kind == 2 else { return true }
        return !Self.glassRoundedRectContains(
            point,
            rect: shape.rect.insetBy(dx: shape.thickness, dy: shape.thickness),
            radius: max(0, shape.radius - shape.thickness)
        )
    }

    func glassRegions(
        _ handle: ElementHandle,
        clippedTo bounds: CGRect,
        in presentation: SurfacePresentation?,
        excluding rings: Set<ElementHandle>
    ) -> [CGRect] {
        guard let geometry = glassGeometry(handle, in: presentation, excluding: rings) else { return [] }
        let clip = geometry.clip.intersection(bounds)
        guard !clip.isNull, !clip.isEmpty else { return [] }
        let shape = geometry.shape
        if shape.kind != 2 {
            let rect = shape.rect.intersection(clip)
            return rect.isNull || rect.isEmpty ? [] : [rect]
        }
        let outer = shape.rect
        let hole = outer.insetBy(dx: shape.thickness, dy: shape.thickness)
        let radius = max(0, shape.radius - shape.thickness)
        var regions = [
            CGRect(x: outer.minX, y: outer.minY, width: outer.width, height: shape.thickness),
            CGRect(x: outer.minX, y: hole.maxY, width: outer.width, height: shape.thickness),
            CGRect(x: outer.minX, y: hole.minY, width: shape.thickness, height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: shape.thickness, height: hole.height)
        ]
        if radius > 0 {
            let bands = min(64, max(1, Int(ceil(radius * scale))))
            regions.reserveCapacity(4 + bands * 4)
            for band in 0 ..< bands {
                let top = radius * CGFloat(band) / CGFloat(bands)
                let bottom = radius * CGFloat(band + 1) / CGFloat(bands)
                let width = radius - sqrt(max(0, radius * radius - (radius - bottom) * (radius - bottom)))
                regions.append(CGRect(x: hole.minX, y: hole.minY + top, width: width, height: bottom - top))
                regions.append(CGRect(x: hole.maxX - width, y: hole.minY + top, width: width, height: bottom - top))
                regions.append(CGRect(x: hole.minX, y: hole.maxY - bottom, width: width, height: bottom - top))
                regions.append(CGRect(x: hole.maxX - width, y: hole.maxY - bottom, width: width, height: bottom - top))
            }
        }
        return regions.compactMap {
            let rect = $0.intersection(clip)
            return rect.isNull || rect.isEmpty ? nil : rect
        }
    }

    private func glassGeometry(
        _ handle: ElementHandle,
        in presentation: SurfacePresentation?,
        excluding rings: Set<ElementHandle>
    ) -> (shape: ShellGlassShape, clip: CGRect)? {
        guard layout.core.contains(handle), layout.core.kind(of: handle) == .shape else { return nil }
        let body = layout.core.parent(of: handle)
        guard layout.core.contains(body), layout.core.kind(of: body) == .glass, !rings.contains(body) else {
            return nil
        }
        let followed = followedFrame(of: handle, in: presentation)
        let rect = followed?.rect ?? CGRect(presentedFrame(of: handle, in: presentation))
        guard !rect.isNull, !rect.isEmpty else { return nil }
        var clip = CGRect(presentedFrame(of: body, in: presentation))
        var current = body
        var opacity: Float = 1
        while layout.core.contains(current) {
            let content = layout.core.content(of: current)
            if current != body, content.decorative { return nil }
            opacity *= layout.core.paint(of: current).opacity
            if content.scrolls || isManipulationClip(current) {
                clip = clip.intersection(CGRect(presentedFrame(of: current, in: presentation)))
            }
            current = layout.core.parent(of: current)
        }
        guard opacity > 0, !clip.isNull, !clip.isEmpty else { return nil }
        let content = layout.core.content(of: handle)
        let factor = followed?.scale ?? presentedScale(of: handle, in: presentation)
        return (
            boundGeometry(ShellGlassShape(
                slot: handle.slot,
                kind: content.glassShape,
                rect: rect,
                radius: min(
                    CGFloat(layout.core.paint(of: handle).cornerRadius)
                        * (followed != nil && content.glassFollowFixedRadius ? 1 : factor),
                    min(rect.width, rect.height) / 2
                ),
                thickness: CGFloat(content.params.x) * factor
            ), of: handle),
            clip
        )
    }

    private func followedFrame(
        of handle: ElementHandle,
        in presentation: SurfacePresentation?
    ) -> (rect: CGRect, scale: CGFloat)? {
        guard let target = followedTarget(of: handle), let placement = presentation?.targets[target] else { return nil }
        let layout = CGRect(self.layout.core.absoluteFrame(of: target))
        let local = self.layout.core.layoutFrame(of: target)
        let own = CGRect(self.layout.core.absoluteFrame(of: handle))
        let scale = CGFloat(placement.scale)
        return (
            CGRect(
                x: layout.minX + CGFloat(placement.frame.x - local.x) + (own.minX - layout.minX) * scale,
                y: layout.minY + CGFloat(placement.frame.y - local.y) + (own.minY - layout.minY) * scale,
                width: own.width * scale,
                height: own.height * scale
            ),
            scale
        )
    }

    private static func glassRoundedRectContains(_ point: CGPoint, rect: CGRect, radius: CGFloat) -> Bool {
        let x = abs(point.x - rect.midX) - rect.width / 2 + radius
        let y = abs(point.y - rect.midY) - rect.height / 2 + radius
        return hypot(max(x, 0), max(y, 0)) + min(max(x, y), 0) - radius <= 0
    }

    func clips(_ handle: ElementHandle, _ x: Float, _ y: Float) -> Bool {
        guard !maskOwners.isEmpty || !paths.isEmpty else { return true }
        if let mask = maskOwners[handle.slot], layout.core.contains(mask) {
            let frame = layout.core.layoutFrame(of: mask)
            let shift = layout.core.scrollShift(handle.slot)
            let point = CGPoint(x: CGFloat(x + shift.x - frame.x), y: CGFloat(y + shift.y - frame.y))
            let inside = switch layout.core.kind(of: mask) {
            case .path: pathContains(
                    mask.slot,
                    at: point,
                    size: CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height))
                )
            case .shader: shaderCovers(mask.slot, at: point)
            default: true
            }
            guard inside else { return false }
        }
        let paint = layout.core.paint(of: handle)
        guard layout.core.kind(of: handle) == .path, !paint.masks else { return true }
        let frame = layout.core.layoutFrame(of: handle)
        let stroke = paint.stroke.isVisible ? CGFloat(paint.strokeWidth) : 0
        return pathContains(
            handle.slot,
            at: CGPoint(x: CGFloat(x), y: CGFloat(y)),
            size: CGSize(width: CGFloat(frame.width), height: CGFloat(frame.height)),
            fill: paint.fill.isVisible || stroke <= 0,
            stroke: stroke
        )
    }

    private func pathContains(
        _ slot: Int32,
        at point: CGPoint,
        size: CGSize,
        fill: Bool = true,
        stroke: CGFloat = 0
    ) -> Bool {
        guard let spec = paths[slot] else { return true }
        guard let data = spec.path else { return false }
        let path: CGPath
        if let cached = fittedPaths[slot], cached.size == size {
            path = cached.path
        } else {
            path = data.path(fitting: spec.viewBox, into: size)
            fittedPaths[slot] = (size, path)
        }
        if fill, path.contains(point, using: spec.evenOdd ? .evenOdd : .winding) {
            return true
        }
        guard stroke > 0 else { return false }
        return path.copy(strokingWithWidth: stroke, lineCap: .butt, lineJoin: .miter, miterLimit: 10).contains(point)
    }

    private func shaderCovers(_ slot: Int32, at point: CGPoint) -> Bool {
        if let sample = samples[slot], abs(sample.point.x - point.x) < 1, abs(sample.point.y - point.y) < 1 {
            return sample.inside
        }
        requestSample(slot, at: point)
        return true
    }

    private func requestSample(_ slot: Int32, at point: CGPoint) {
        guard sampling.insert(slot).inserted else {
            wantedSamples[slot] = point
            return
        }
        scene.sampleAlpha(slot, at: point) { [weak self] alpha in
            Task { @MainActor in
                self?.receiveSample(slot, at: point, alpha: alpha)
            }
        }
    }

    private func receiveSample(_ slot: Int32, at point: CGPoint, alpha: Float?) {
        sampling.remove(slot)
        let next = wantedSamples.removeValue(forKey: slot)
        guard let alpha else { return }
        samples[slot] = (point, alpha > Self.alphaThreshold)
        if let next {
            requestSample(slot, at: next)
        }
        onShapeChange?()
    }

    func trackMask(_ handle: ElementHandle, masks: Bool) {
        let host = layout.core.parent(of: handle)
        guard host.slot >= 0 else { return }
        if masks {
            maskOwners[host.slot] = handle
        } else if maskOwners[host.slot] == handle {
            maskOwners.removeValue(forKey: host.slot)
        }
    }

    func forgetShape(_ handle: ElementHandle) {
        fittedPaths.removeValue(forKey: handle.slot)
        samples.removeValue(forKey: handle.slot)
        wantedSamples.removeValue(forKey: handle.slot)
        maskOwners.removeValue(forKey: handle.slot)
        if let host = maskOwners.first(where: { $0.value == handle })?.key {
            maskOwners.removeValue(forKey: host)
        }
    }
}
