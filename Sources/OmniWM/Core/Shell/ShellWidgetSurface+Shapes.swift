// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

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
        return layout.core.covers(x: Float(point.x), y: Float(point.y), where: { handle in
            if layout.core.paint(of: handle).masks {
                return false
            }
            switch layout.core.kind(of: handle) {
            case .shader:
                let frame = layout.core.absoluteFrame(of: handle)
                return shaderCovers(
                    handle.slot,
                    at: CGPoint(x: point.x - CGFloat(frame.x), y: point.y - CGFloat(frame.y))
                )
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
                    || content.opensPopout || content.menu || content.drag
            }
        }, clip: clips)
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
