// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore
import QuartzCore

struct ShellFollowChange {
    let target: ElementHandle
    let resized: Bool
    let moves: Bool
    let animated: Bool
}

struct ShellManipulationFollow: Sendable {
    let recipe: UInt32
    let spring: ShellSpringDynamics.Parameters
    var frame: CGRect
    var commit: UInt32
    var token: UInt64 = 0
    var motion: ShellManipulationMotion?
}

extension ShellWrapperMotion.Channel {
    func following(_ offset: Double, scale: ShellWrapperMotion.Channel) -> ShellWrapperMotion.Channel {
        ShellWrapperMotion.Channel(
            from: from + offset * (1 - scale.from),
            to: to + offset * (1 - scale.to),
            velocity: velocity - offset * scale.velocity,
            begin: begin,
            spring: spring,
            duration: duration
        )
    }
}

extension ShellManipulationPresentation {
    func following(_ offset: CGPoint) -> ShellManipulationPresentation {
        switch self {
        case let .still(translation, scale, _):
            .still(
                translation: CGPoint(
                    x: translation.x + offset.x * (1 - scale),
                    y: translation.y + offset.y * (1 - scale)
                ),
                scale: scale,
                clip: nil
            )
        case let .motion(motion):
            .motion(ShellWrapperMotion(
                x: motion.x.following(offset.x, scale: motion.scale),
                y: motion.y.following(offset.y, scale: motion.scale),
                scale: motion.scale
            ))
        }
    }
}

extension ShellManipulationMotion {
    func trajectoryBounds(of rect: CGRect, about layout: CGRect) -> CGRect {
        func reach(_ offset: CGFloat, horizontal: Bool) -> ClosedRange<Double> {
            let share = offset / layout.width
            let base = (horizontal ? target.minX : target.minY) + share * target.width
            let range = ShellSpringDynamics.range(
                displacement: (horizontal ? start.minX - target.minX : start.minY - target.minY)
                    + share * (start.width - target.width),
                initialVelocity: (horizontal ? startVelocity.x : startVelocity.y) + share * startVelocity.width,
                spring: spring
            )
            return (base + range.lowerBound) ... (base + range.upperBound)
        }
        let left = reach(rect.minX - layout.minX, horizontal: true)
        let right = reach(rect.maxX - layout.minX, horizontal: true)
        let top = reach(rect.minY - layout.minY, horizontal: false)
        let bottom = reach(rect.maxY - layout.minY, horizontal: false)
        return CGRect(
            x: left.lowerBound,
            y: top.lowerBound,
            width: right.upperBound - left.lowerBound,
            height: bottom.upperBound - top.lowerBound
        )
    }
}

extension ShellWidgetSurface {
    func followerExitBindings() -> [ElementHandle: [ShellFollowExitBinding]] {
        guard animates, motionPolicy.animationsEnabled else { return [:] }
        var result: [ElementHandle: [ShellFollowExitBinding]] = [:]
        for shape in glassShapeHandles {
            guard let target = followedTarget(of: shape), layout.core.paint(of: target).exit != 0 else { continue }
            let own = CGRect(layout.core.absoluteFrame(of: shape))
            let frame = CGRect(layout.core.absoluteFrame(of: target))
            result[target, default: []].append(ShellFollowExitBinding(
                shape: shape,
                identity: layerIdentity(shape, parent: layout.core.parent(of: shape), kind: .shape),
                offset: CGPoint(x: frame.minX - own.minX, y: frame.minY - own.minY)
            ))
        }
        return result
    }

    private enum FollowChange {
        case started
        case finished
    }

    private static let followAspectTolerance: CGFloat = 0.005

    func appendFollow(into commands: inout [ShellLayerCommand]) {
        refreshBoundShapes()
        let targets = followTargets
        var started = false
        var finished = false
        for (target, record) in follows
            where !targets.contains(target) || record.recipe != layout.core.content(of: target).manipulationFollow
        {
            if record.motion != nil {
                finished = true
                if layout.core.contains(target) { commands += released(target, token: record.token) }
            }
            follows.removeValue(forKey: target)
        }
        for target in targets {
            guard let record = follows[target] else {
                follows[target] = makeFollow(target)
                continue
            }
            switch appendFollow(target, record, into: &commands) {
            case .started: started = true
            case .finished: finished = true
            case nil: break
            }
        }
        appendFollowers(into: &commands)
        if started || finished { layoutTextInputs(into: &commands) }
        if finished { onMove?() }
    }

    private func appendFollow(
        _ target: ElementHandle,
        _ record: ShellManipulationFollow,
        into commands: inout [ShellLayerCommand]
    ) -> FollowChange? {
        let frame = CGRect(layout.core.absoluteFrame(of: target))
        if let current = manipulation, current.target == target {
            if frame != record.frame, let motion = record.motion {
                follows[target]?.frame = frame
                commands += manipulationCommands(
                    target, token: current.token, presentation: .motion(motion.wrapper(for: frame)), active: true
                )
            }
            return nil
        }
        let commit = layout.core.content(of: target).manipulationCommit
        let moved = frame != record.frame
        let settles = record.motion == nil ? moved && commit != record.commit : moved || commit != record.commit
        follows[target]?.frame = frame
        follows[target]?.commit = commit
        guard settles else { return nil }
        if settleFollow(target, to: frame, from: record.frame, into: &commands) { return .started }
        guard record.motion != nil else { return nil }
        commands += released(target, token: record.token)
        follows[target]?.motion = nil
        return .finished
    }

    func settleFollow(
        _ target: ElementHandle,
        to frame: CGRect,
        from previous: CGRect? = nil,
        into commands: inout [ShellLayerCommand]
    ) -> Bool {
        guard var record = follows[target] else { return false }
        let previous = previous ?? record.frame
        let now = clock()
        guard Self.keepsAspect(frame, of: record.motion?.target ?? previous),
              let motion = record.motion?.retargeted(at: now, to: frame)
              ?? ShellManipulationMotion(from: previous, to: frame, begin: now, spring: record.spring)
        else { return false }
        record.motion = motion
        record.token = ShellInvocation.next()
        follows[target] = record
        commands += manipulationCommands(
            target, token: record.token, presentation: .motion(motion.wrapper(for: record.frame)), active: false
        )
        return true
    }

    func finishSettle(where matches: (ElementHandle) -> Bool = { _ in true }) {
        var commands: [ShellLayerCommand] = []
        var finished = false
        for (target, record) in follows where record.motion != nil && matches(target) {
            finished = true
            follows[target]?.motion = nil
            if layout.core.contains(target) { commands += released(target, token: record.token) }
        }
        guard finished else { return }
        scene.submit(commands, animated: false)
        layoutTextInputs()
        onMove?()
    }

    func manipulationSettled(_ slot: Int32, token: UInt64) {
        guard let target = follows.first(where: {
            $0.key.slot == slot && $0.value.token == token && $0.value.motion != nil
        })?.key else { return }
        follows[target]?.motion = nil
        let lowered: [ShellLayerCommand] = selectedManipulation == target ? [] : [.raise(slot: slot, false)]
        scene.submit(
            lowered + followerCommands(of: target, presentation: .identity, active: false),
            animated: false
        )
        layoutTextInputs()
        onMove?()
    }

    func commands(text: ShellTextStore) -> [ShellLayerCommand] {
        followChangeSnapshot = measuredFollowChanges()
        defer { followChangeSnapshot = nil }
        return patchCommands(text: text)
    }

    func followSuppressesAnimation(of handle: ElementHandle) -> Bool {
        if let target = followedTarget(of: handle), movesFollowers(target) { return true }
        return (followChangeSnapshot ?? measuredFollowChanges()).contains { change in
            handle == change.target ? change.moves
                : change.resized && (change.moves || !change.animated) && isWithin(handle, change.target)
        }
    }

    private func measuredFollowChanges() -> [ShellFollowChange] {
        follows.compactMap { target, record in
            guard layout.core.contains(target) else { return nil }
            let frame = CGRect(layout.core.absoluteFrame(of: target))
            guard frame != record.frame else { return nil }
            return ShellFollowChange(
                target: target, resized: frame.size != record.frame.size, moves: movesFollowers(target),
                animated: layout.core.content(of: target).motion != 0
            )
        }
    }

    private func movesFollowers(_ target: ElementHandle) -> Bool {
        if manipulation?.target == target { return true }
        guard let record = follows[target] else { return false }
        if record.motion != nil { return true }
        let frame = CGRect(layout.core.absoluteFrame(of: target))
        return frame != record.frame && layout.core.content(of: target).manipulationCommit != record.commit
            && Self.keepsAspect(frame, of: record.frame)
    }

    func reflowedTarget(of follower: ElementHandle) -> ElementHandle? {
        guard let target = followedTarget(of: follower), let record = follows[target],
              CGRect(layout.core.absoluteFrame(of: target)) != record.frame else { return nil }
        return target
    }

    private static func keepsAspect(_ frame: CGRect, of previous: CGRect) -> Bool {
        abs(frame.height * previous.width / (frame.width * previous.height) - 1) <= followAspectTolerance
    }

    func followedTarget(of handle: ElementHandle) -> ElementHandle? {
        guard layout.core.contains(handle), layout.core.kind(of: handle) == .shape else { return nil }
        let key = layout.core.content(of: handle).glassFollow
        guard key != 0 else { return nil }
        return manipulationTargets.keys.first { layout.core.contains($0) && layout.core.key(of: $0) == key }
    }

    func manipulationCommands(
        _ target: ElementHandle,
        token: UInt64,
        presentation: ShellManipulationPresentation,
        active: Bool
    ) -> [ShellLayerCommand] {
        [.manipulation(slot: target.slot, token: token, presentation: presentation, active: active)]
            + followerCommands(of: target, presentation: presentation, active: active)
    }

    private func followerCommands(
        of target: ElementHandle,
        presentation: ShellManipulationPresentation,
        active: Bool
    ) -> [ShellLayerCommand] {
        let key = layout.core.contains(target) ? layout.core.key(of: target) : 0
        guard key != 0 else { return [] }
        return [.retainedFollowers(
            target: target.slot, frame: CGRect(layout.core.absoluteFrame(of: target)), presentation: presentation,
            time: clock()
        )] + glassShapeHandles.compactMap { shape in
            guard layout.core.contains(shape), layout.core.content(of: shape).glassFollow == key else { return nil }
            return followerCommand(shape, of: target, presentation: presentation)
        } + boundCommands(of: target, presentation: presentation, active: active)
    }

    func currentPresentation(of target: ElementHandle) -> ShellManipulationPresentation {
        if let record = follows[target], let motion = record.motion {
            return .motion(motion.wrapper(for: record.frame))
        }
        if let current = manipulation, current.target == target { return stillPresentation(current) }
        return .identity
    }

    private func appendFollowers(into commands: inout [ShellLayerCommand]) {
        guard !glassShapeHandles.isEmpty || !manipulationTargets.isEmpty else { return }
        var geometry = Set<ElementHandle>()
        var rebound = Set<ElementHandle>()
        var structural = false
        for index in 0 ..< layout.patches.count {
            switch layout.patches.op(at: index) {
            case .insert,
                 .remove: structural = true
            case let .setFrame(handle, _): geometry.insert(handle)
            case let .setGlass(handle): rebound.insert(handle)
            default: continue
            }
        }
        for target in manipulationTargets.keys where layout.core.contains(target)
            && (structural || geometry.contains(where: { isWithin(target, $0) }))
        {
            commands.append(.retainedFollowers(
                target: target.slot, frame: CGRect(layout.core.absoluteFrame(of: target)),
                presentation: currentPresentation(of: target), time: clock()
            ))
        }
        for shape in glassShapeHandles where layout.core.contains(shape)
            && (layout.core.content(of: shape).glassFollow != 0 || boundShapes[shape] != nil)
        {
            let bound = boundShapes[shape] != nil
            let target = bound ? boundTarget(of: shape) : followedTarget(of: shape)
            guard structural || rebound.contains(shape) || geometry.contains(where: { changed in
                isWithin(shape, changed) || target.map { isWithin($0, changed) } == true
            }) else { continue }
            guard let target else {
                if !bound { commands.append(.manipulation(
                    slot: shape.slot,
                    token: 0,
                    presentation: .identity,
                    active: false
                )) }
                continue
            }
            let presentation = currentPresentation(of: target)
            commands.append(bound
                ? boundCommand(shape, of: target, presentation: presentation, active: manipulation?.target == target)
                : followerCommand(shape, of: target, presentation: presentation))
        }
    }

    private func followerCommand(
        _ shape: ElementHandle,
        of target: ElementHandle,
        presentation: ShellManipulationPresentation
    ) -> ShellLayerCommand {
        .shapeFollow(
            slot: shape.slot,
            binding: ShellShapeFollowBinding(
                target: target.slot, frame: CGRect(layout.core.absoluteFrame(of: target)),
                origin: CGRect(layout.core.absoluteFrame(of: shape)).origin
            ),
            presentation: presentation
        )
    }

    private var followTargets: [ElementHandle] {
        guard motionPolicy.animationsEnabled else { return [] }
        return manipulationTargets.keys.filter {
            layout.core.contains($0) && layout.core.content(of: $0).manipulationFollow != 0
        }.sorted { $0.slot < $1.slot }
    }

    private func makeFollow(_ target: ElementHandle) -> ShellManipulationFollow? {
        let content = layout.core.content(of: target)
        guard let motion = text.flatMap({ ShellMotion(recipe: $0.string(content.manipulationFollow)) }),
              let spring = ShellSpringDynamics.Parameters(
                  ShellAnimation(motion: motion, speed: motionPolicy.animationSpeed)
              )
        else { return nil }
        return ShellManipulationFollow(
            recipe: content.manipulationFollow,
            spring: spring,
            frame: CGRect(layout.core.absoluteFrame(of: target)),
            commit: content.manipulationCommit
        )
    }
}
