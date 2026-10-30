// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellLayerScene {
    func updateRetainedBounds(
        _ target: Int32, frame: CGRect, presentation: ShellManipulationPresentation, at time: CFTimeInterval
    ) {
        for slot in shapeTracks.retainedBounds[target] ?? [] {
            guard let input = shapeTracks.entries[slot]?.bound?.input, let binding = input.binding else { continue }
            shapeTracks.pendingBounds[slot] = ShellBoundInput(
                layout: frame.offsetBy(dx: -binding.origin.x, dy: -binding.origin.y), canvas: input.canvas,
                presentation: presentation, active: false, time: time, animates: input.animates, binding: binding
            )
        }
    }

    func forgetRetainedBounds(_ slot: Int32) {
        shapeTracks.retainedBounds.removeValue(forKey: slot)
        for (target, slots) in shapeTracks.retainedBounds where slots.contains(slot) {
            shapeTracks.retainedBounds[target]?.remove(slot)
            if shapeTracks.retainedBounds[target]?.isEmpty == true {
                shapeTracks.retainedBounds.removeValue(forKey: target)
            }
        }
    }
}
