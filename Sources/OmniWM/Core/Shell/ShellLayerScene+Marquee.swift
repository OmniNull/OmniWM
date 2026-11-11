// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellMarquee {
    static let animationKey = "omni.marquee"
    static let pointsPerSecond: CGFloat = 30

    let copy: CALayer
    let source: Int32
    let distance: CGFloat
}

extension ShellLayerScene {
    func applyScroll(_ slot: Int32, origin: CGPoint) {
        guard let layer = layers[slot] else { return }
        scrollOrigins[slot] = origin
        layer.masksToBounds = true
        layer.bounds.origin = origin
    }

    func setMarquee(_ slot: Int32, enabled: Bool) {
        if enabled {
            if !marqueeSlots.contains(slot) { marqueeSlots.append(slot) }
        } else {
            if let index = marqueeSlots.firstIndex(of: slot) { marqueeSlots.remove(at: index) }
            stopMarquee(slot)
        }
    }

    func refreshMarqueeContents(_ slot: Int32, contents: CGImage?) {
        guard let parent = parents[slot], let ticker = marquees[parent], ticker.source == slot else { return }
        ticker.copy.contents = contents
    }

    func flushMarquees() {
        guard !marqueeSlots.isEmpty else { return }
        for index in marqueeSlots.indices {
            let slot = marqueeSlots[index]
            guard visible, let viewport = layers[slot], viewport.bounds.width > 0,
                  let descendants = children[slot], descendants.count == 1,
                  let source = descendants.first, let label = layers[source],
                  label.bounds.width > viewport.bounds.width
            else {
                stopMarquee(slot)
                continue
            }
            let gap = label.bounds.height
            let distance = label.bounds.width + gap
            let current = marquees[slot]
            if current?.source == source, current?.distance == distance { continue }
            stopMarquee(slot)
            let copy = CALayer()
            copy.anchorPoint = .zero
            copy.bounds = label.bounds
            copy.position = CGPoint(x: distance, y: 0)
            copy.contents = label.contents
            copy.contentsScale = label.contentsScale
            copy.contentsGravity = label.contentsGravity
            label.addSublayer(copy)
            let animation = CABasicAnimation(keyPath: "transform.translation.x")
            animation.fromValue = 0
            animation.toValue = -distance
            animation.duration = distance / ShellMarquee.pointsPerSecond
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            let time = now()
            animation.beginTime = label.convertTime(time, from: nil)
            label.add(animation, forKey: ShellMarquee.animationKey)
            marquees[slot] = ShellMarquee(copy: copy, source: source, distance: distance)
        }
    }

    private func stopMarquee(_ slot: Int32) {
        guard let ticker = marquees.removeValue(forKey: slot) else { return }
        layers[ticker.source]?.removeAnimation(forKey: ShellMarquee.animationKey)
        ticker.copy.removeFromSuperlayer()
    }
}
