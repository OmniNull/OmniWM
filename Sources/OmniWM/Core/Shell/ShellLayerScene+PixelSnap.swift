// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellLayerScene {
    var snapsToPixels: Bool {
        scale < 2
    }

    static func pixelAligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0, rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite
        else { return rect }
        func snap(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        func length(_ value: CGFloat) -> CGFloat {
            value > 0 ? max(snap(value), 1 / scale) : value
        }
        return CGRect(
            x: snap(rect.origin.x),
            y: snap(rect.origin.y),
            width: length(rect.width),
            height: length(rect.height)
        )
    }

    func trackPixelSnap(_ slot: Int32, _ layer: CALayer) {
        guard snapsToPixels, snappedContent[slot]?.layer !== layer else { return }
        snappedContent[slot] = (layer, CGRect(origin: layer.position, size: layer.bounds.size))
    }

    func recordContentFrame(_ slot: Int32, _ rect: CGRect) {
        guard let entry = snappedContent[slot], entry.layer === layers[slot] else { return }
        snappedContent[slot] = (entry.layer, rect)
    }

    func turnQuarter(_ slot: Int32, _ layer: CALayer) {
        layer.bounds.size = CGSize(width: layer.bounds.height, height: layer.bounds.width)
        guard let entry = snappedContent[slot], entry.layer === layer else { return }
        let size = CGSize(width: entry.frame.height, height: entry.frame.width)
        snappedContent[slot] = (entry.layer, CGRect(origin: entry.frame.origin, size: size))
    }

    private func isAxisAligned(_ parent: CALayer) -> Bool {
        let origin = parent.convert(CGPoint.zero, to: container)
        let across = parent.convert(CGPoint(x: 1, y: 0), to: container)
        let down = parent.convert(CGPoint(x: 0, y: 1), to: container)
        return abs(across.y - origin.y) < 0.0001 && abs(down.x - origin.x) < 0.0001
    }

    func flushPixelSnap() {
        guard snapsToPixels else { return }
        for (slot, entry) in snappedContent {
            let layer = entry.layer
            guard layers[slot] === layer else {
                snappedContent.removeValue(forKey: slot)
                continue
            }
            let zoom = scales[slot] ?? 1
            guard let parent = layer.superlayer, rotations[slot] ?? 0 == 0, !quarters.contains(slot), zoom > 0,
                  isAxisAligned(parent)
            else {
                place(slot, layer, at: entry.frame)
                continue
            }
            let frame = entry.frame
            let shown = CGRect(
                x: frame.minX + frame.width * (1 - zoom) / 2,
                y: frame.minY + frame.height * (1 - zoom) / 2,
                width: frame.width * zoom,
                height: frame.height * zoom
            )
            let aligned = parent.convert(
                Self.pixelAligned(parent.convert(shown, to: container), scale: scale),
                from: container
            )
            let size = CGSize(width: aligned.width / zoom, height: aligned.height / zoom)
            let origin = CGPoint(
                x: aligned.minX - size.width * (1 - zoom) / 2,
                y: aligned.minY - size.height * (1 - zoom) / 2
            )
            place(slot, layer, at: CGRect(origin: origin, size: size))
        }
    }

    private func place(_ slot: Int32, _ layer: CALayer, at frame: CGRect) {
        layer.position = frame.origin
        guard layer.bounds.size != frame.size else { return }
        layer.bounds.size = frame.size
        applyScale(slot, to: layer)
    }

    func restoreLayoutFrames() {
        for (slot, entry) in snappedContent where layers[slot] === entry.layer {
            place(slot, entry.layer, at: entry.frame)
        }
        snappedContent.removeAll()
    }
}
