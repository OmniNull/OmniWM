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
        guard snappedContent[slot]?.layer !== layer else { return }
        snappedContent[slot] = (layer, CGRect(origin: layer.position, size: layer.bounds.size))
    }

    func recordContentFrame(_ slot: Int32, _ rect: CGRect) {
        guard let entry = snappedContent[slot], entry.layer === layers[slot] else { return }
        snappedContent[slot] = (entry.layer, rect)
    }

    func flushPixelSnap() {
        guard snapsToPixels else { return }
        for (slot, entry) in snappedContent {
            let layer = entry.layer
            guard layers[slot] === layer else {
                snappedContent.removeValue(forKey: slot)
                continue
            }
            guard let parent = layer.superlayer else { continue }
            let absolute = parent.convert(entry.frame, to: container)
            let aligned = Self.pixelAligned(absolute, scale: scale)
            layer.position = parent.convert(aligned.origin, from: container)
            if !quarters.contains(slot), absolute.size == entry.frame.size {
                layer.bounds.size = aligned.size
            }
        }
    }
}
