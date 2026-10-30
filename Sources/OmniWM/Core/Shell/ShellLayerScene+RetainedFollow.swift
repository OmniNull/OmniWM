// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellShapeFollowBinding: Sendable {
    let target: Int32
    let frame: CGRect
    let origin: CGPoint
    var layoutScale: Double = 1

    var offset: CGPoint {
        CGPoint(x: frame.minX - origin.x, y: frame.minY - origin.y)
    }

    func presentation(
        _ value: ShellManipulationPresentation, in current: CGRect
    ) -> ShellManipulationPresentation {
        let scale = current.width / frame.width
        let delta = CGPoint(x: current.minX - frame.minX, y: current.minY - frame.minY)
        let rebased: ShellManipulationPresentation
        switch value {
        case let .still(translation, factor, _):
            rebased = .still(
                translation: CGPoint(x: translation.x + delta.x, y: translation.y + delta.y),
                scale: factor * scale, clip: nil
            )
        case let .motion(motion):
            func mapped(
                _ channel: ShellWrapperMotion.Channel, scale: Double = 1, offset: Double = 0
            ) -> ShellWrapperMotion.Channel {
                .init(
                    from: channel.from * scale + offset, to: channel.to * scale + offset,
                    velocity: channel.velocity * scale, begin: channel.begin,
                    spring: channel.spring, duration: channel.duration
                )
            }
            rebased = .motion(ShellWrapperMotion(
                x: mapped(motion.x, offset: delta.x), y: mapped(motion.y, offset: delta.y),
                scale: mapped(motion.scale, scale: scale)
            ))
        }
        return rebased.following(offset)
    }
}

extension ShellLayerScene {
    func applyFollowCommand(_ command: ShellLayerCommand) -> Bool {
        switch command {
        case let .manipulation(slot, token, presentation, active):
            applyManipulation(slot, token: token, presentation: presentation, active: active)
        case let .raise(slot, raised):
            raise(slot, raised)
        case let .shapeFollow(slot, binding, presentation):
            guard shapeTracks.follows[slot]?.radius != nil else { return true }
            shapeTracks.follows[slot]?.binding = binding
            followShape(slot, binding.presentation(presentation, in: binding.frame))
        case let .retainedFollowers(target, frame, presentation, time):
            updateRetainedBounds(target, frame: frame, presentation: presentation, at: time)
            for slot in shapeTracks.retainedFollowers[target] ?? [] {
                guard var binding = shapeTracks.follows[slot]?.binding else { continue }
                binding.layoutScale = frame.width / binding.frame.width
                shapeTracks.follows[slot]?.binding = binding
                followShape(slot, binding.presentation(presentation, in: frame))
            }
        default: return false
        }
        return true
    }

    func retainShapeFollow(from slot: Int32, to physical: Int32) {
        guard var follow = shapeTracks.follows.removeValue(forKey: slot) else { return }
        follow.dirty = true
        shapeTracks.follows[physical] = follow
        if let binding = follow.binding {
            shapeTracks.retainedFollowers[binding.target, default: []].insert(physical)
        }
    }

    func forgetShapeBindings(_ slot: Int32) {
        forgetRetainedBounds(slot)
        for follower in shapeTracks.retainedFollowers.removeValue(forKey: slot) ?? [] {
            shapeTracks.follows[follower]?.binding = nil
        }
        guard let binding = shapeTracks.follows.removeValue(forKey: slot)?.binding else { return }
        shapeTracks.retainedFollowers[binding.target]?.remove(slot)
        if shapeTracks.retainedFollowers[binding.target]?.isEmpty == true {
            shapeTracks.retainedFollowers.removeValue(forKey: binding.target)
        }
    }
}
