// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore
import QuartzCore

struct ShellRevealRoot {
    let identity: ShellLayerIdentity?
    var spring: ShellSpringDynamics.Parameters
    var recipe: ShellRevealRecipe
    let shape: Bool
    var plan: ShellReveal?
    var token: UInt64 = 0
    var groups: [(handle: ElementHandle, recipe: ShellMorphRecipe)] = []
}

extension ShellWidgetSurface {
    private var animatesReveals: Bool {
        animates && motionPolicy.animationsEnabled
    }

    private func openReveal(_ handle: ElementHandle, identity: ShellLayerIdentity?, at now: CFTimeInterval) -> Bool {
        guard let recipe = reveal(layout.core.paint(of: handle).reveal),
              let spring = ShellSpringDynamics.Parameters(ShellAnimation(
                  motion: .spring(response: recipe.response, bounce: recipe.bounce),
                  speed: motionPolicy.animationSpeed
              ))
        else { return false }
        let retiring = identity.flatMap { retiringReveals.removeValue(forKey: $0) }
        let seed = retiring?.state(at: now) ?? (progress: 0, velocity: 0)
        let shape = layout.core.kind(of: handle) == .shape
        var root = ShellRevealRoot(identity: identity, spring: spring, recipe: recipe, shape: shape)
        if animatesReveals {
            root.plan = ShellReveal(
                begin: now + (retiring == nil ? recipe.delay / motionPolicy.animationSpeed : 0), commit: now,
                progress: seed.progress, velocity: seed.velocity, target: 1, spring: spring
            )
        }
        reveals[handle] = root
        return root.plan != nil
    }

    private func closeReveal(_ handle: ElementHandle, at now: CFTimeInterval) -> ShellLayerCommand? {
        guard let root = reveals.removeValue(forKey: handle), animatesReveals, visible else { return nil }
        guard !root.shape || root.recipe.exits else { return nil }
        let state = root.plan?.state(at: now) ?? (progress: 1, velocity: 0)
        let closing = ShellReveal(
            begin: now + root.recipe.hold / motionPolicy.animationSpeed, commit: now,
            progress: state.progress, velocity: state.velocity, target: 0, spring: root.spring
        )
        if let identity = root.identity {
            retiringReveals = retiringReveals.filter { $0.value.end > now }
            retiringReveals[identity] = closing
        }
        return .reveal(slot: handle.slot, token: 0, closing)
    }

    func closingReveals(at time: CFTimeInterval? = nil) -> [ShellLayerCommand] {
        let now = time ?? clock()
        guard !reveals.isEmpty else { return [] }
        let commands = (0 ..< layout.patches.count).compactMap { index -> ShellLayerCommand? in
            guard case let .remove(handle) = layout.patches.op(at: index) else { return nil }
            return closeReveal(handle, at: now)
        }
        reveals = reveals.filter { layout.core.contains($0.key) }
        return commands
    }

    func revealCommands(at time: CFTimeInterval? = nil) -> [ShellLayerCommand] {
        var commands: [ShellLayerCommand] = []
        if !animatesReveals {
            finishReveals()
            commands.append(.clearExits)
        }
        let now = time ?? clock()
        var opened = Set<ElementHandle>()
        var changed = Set<ElementHandle>()
        for index in 0 ..< layout.patches.count {
            switch layout.patches.op(at: index) {
            case let .insert(handle, parent, kind, _):
                if openReveal(handle, identity: layerIdentity(handle, parent: parent, kind: kind), at: now) {
                    opened.insert(handle)
                }
            case let .setFrame(handle, _),
                 let .setPaint(handle, _),
                 let .setGlass(handle):
                updateShapeReveal(handle, at: now)
                if let root = revealChange(handle) { changed.insert(root) }
            default:
                continue
            }
        }
        for handle in opened.union(changed) {
            guard var root = reveals[handle], let plan = root.plan, layout.core.contains(handle) else { continue }
            let next = opened.contains(handle) ? plan : plan.retargeted(at: now, to: 1)
            revealTokens &+= 1
            root.plan = next
            root.token = revealTokens
            root.groups = revealGroups(of: handle)
            reveals[handle] = root
            commands.append(.reveal(slot: handle.slot, token: root.token, next))
        }
        return commands
    }

    func revealPresentation(over base: SurfacePresentation?) -> SurfacePresentation? {
        guard reveals.values.contains(where: { $0.plan != nil }) else { return base }
        let now = clock()
        var groups: [ElementHandle: SurfacePresentation.Group] = [:]
        for root in reveals.values {
            guard let progress = root.plan?.state(at: now).progress else { continue }
            for group in root.groups where layout.core.contains(group.handle) {
                let stop = group.recipe.stop(at: progress)
                let layoutFrame = CGRect(layout.core.layoutFrame(of: group.handle))
                var frame = group.recipe.scaled(layoutFrame, by: stop.scale).offsetBy(dx: stop.dx, dy: stop.dy)
                var scale = CGFloat(stop.scale)
                if let placement = base?.targets[group.handle] {
                    let outer = CGFloat(placement.scale)
                    frame = CGRect(
                        x: CGFloat(placement.frame.x) + (frame.minX - layoutFrame.minX) * outer,
                        y: CGFloat(placement.frame.y) + (frame.minY - layoutFrame.minY) * outer,
                        width: frame.width * outer,
                        height: frame.height * outer
                    )
                    scale *= outer
                }
                groups[group.handle] = SurfacePresentation.Group(
                    frame: Rect(
                        x: Float(frame.minX), y: Float(frame.minY),
                        width: Float(frame.width), height: Float(frame.height)
                    ),
                    scale: Float(scale),
                    visible: stop.opacity > 0
                )
            }
        }
        guard !groups.isEmpty else { return base }
        return SurfacePresentation(targets: base?.targets ?? [:], groups: groups)
    }

    func isRevealing(_ handle: ElementHandle, in presentation: SurfacePresentation?) -> Bool {
        guard let groups = presentation?.groups, !groups.isEmpty else { return false }
        var current = handle
        while layout.core.contains(current) {
            if groups[current] != nil { return true }
            current = layout.core.parent(of: current)
        }
        return false
    }

    func revealSettled(_ slot: Int32, token: UInt64) {
        guard let handle = reveals.first(where: {
            $0.key.slot == slot && $0.value.token == token && $0.value.plan != nil
        })?.key else { return }
        reveals[handle]?.plan = nil
        layoutTextInputs()
        onMove?()
    }

    func finishReveals() {
        retiringReveals.removeAll()
        guard reveals.values.contains(where: { $0.plan != nil }) else { return }
        reveals = reveals.mapValues { root in
            var root = root
            root.plan = nil
            return root
        }
        layoutTextInputs()
        onMove?()
    }

    private func updateShapeReveal(_ handle: ElementHandle, at time: CFTimeInterval) {
        guard var root = reveals[handle], root.shape else { return }
        guard let recipe = reveal(layout.core.paint(of: handle).reveal) else {
            reveals.removeValue(forKey: handle)
            return
        }
        guard root.recipe != recipe, let spring = ShellSpringDynamics.Parameters(ShellAnimation(
            motion: .spring(response: recipe.response, bounce: recipe.bounce), speed: motionPolicy.animationSpeed
        )) else { return }
        if let plan = root.plan {
            let state = plan.state(at: time)
            root.plan = ShellReveal(
                begin: time, progress: state.progress, velocity: state.velocity, target: 1, spring: spring
            )
        }
        root.recipe = recipe
        root.spring = spring
        reveals[handle] = root
    }

    private func revealChange(_ handle: ElementHandle) -> ElementHandle? {
        if layout.core.kind(of: handle) == .shape, reveals[handle]?.plan != nil { return handle }
        guard !reveals.isEmpty, layout.core.paint(of: handle).morph != 0, let root = revealRoot(of: handle),
              reveals[root]?.plan != nil else { return nil }
        return root
    }

    private func revealRoot(of handle: ElementHandle) -> ElementHandle? {
        var current = layout.core.parent(of: handle)
        while layout.core.contains(current) {
            if layout.core.paint(of: current).reveal != 0 { return current }
            current = layout.core.parent(of: current)
        }
        return nil
    }

    private func revealGroups(of root: ElementHandle) -> [(handle: ElementHandle, recipe: ShellMorphRecipe)] {
        layout.core.elements { _ in true }.compactMap { handle in
            let reference = layout.core.paint(of: handle).morph
            guard reference != 0, layout.core.kind(of: handle) != .shape, revealRoot(of: handle) == root,
                  let recipe = morph(reference) else { return nil }
            return (handle, recipe)
        }
    }
}
