// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore
import QuartzCore

struct ShellBoundDeclaration {
    let recipe: String
    let morph: ShellMorphRecipe
    var source: ShellMorphRecipe.Source? {
        morph.source
    }
}

extension ShellWidgetSurface {
    func refreshBoundShapes() {
        var next: [ElementHandle: ShellBoundDeclaration] = [:]
        for shape in glassShapeHandles where layout.core.contains(shape) {
            let reference = layout.core.paint(of: shape).morph
            guard reference != 0, let recipe = text?.string(reference), recipe.contains("|source:") else { continue }
            if let old = boundShapes[shape], old.recipe == recipe { next[shape] = old }
            else if let morph = ShellMorphRecipe(recipe), morph.source != nil {
                next[shape] = ShellBoundDeclaration(recipe: recipe, morph: morph)
            }
        }
        boundShapes = next
    }

    func boundTarget(of shape: ElementHandle) -> ElementHandle? {
        guard let key = boundShapes[shape]?.source?.target else { return nil }
        return manipulationTargets.keys.first { layout.core.contains($0) && layout.core.key(of: $0) == key }
    }

    func boundCommand(
        _ shape: ElementHandle, of target: ElementHandle, presentation: ShellManipulationPresentation, active: Bool
    ) -> ShellLayerCommand {
        let body = layout.core.parent(of: shape)
        let canvas = CGRect(layout.core.absoluteFrame(of: body))
        let binding = ShellBoundBinding(
            target: target.slot,
            frame: CGRect(layout.core.absoluteFrame(of: target)),
            origin: canvas.origin
        )
        let rect = binding.frame.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
        return .boundTrack(slot: shape.slot, ShellBoundInput(
            layout: rect, canvas: CGRect(origin: .zero, size: canvas.size),
            presentation: presentation, active: active && manipulation?.holding != true,
            time: clock(), animates: motionPolicy.animationsEnabled, binding: binding
        ))
    }

    func boundCommands(
        of target: ElementHandle, presentation: ShellManipulationPresentation, active: Bool
    ) -> [ShellLayerCommand] {
        guard layout.core.contains(target) else { return [] }
        let key = layout.core.key(of: target)
        return boundShapes.compactMap { shape, binding in
            guard binding.source?.target == key, layout.core.contains(shape) else { return nil }
            return boundCommand(shape, of: target, presentation: presentation, active: active)
        }
    }
}

extension ShellWidgetSurface {
    func boundGeometry(
        _ shape: ShellGlassShape, of handle: ElementHandle
    ) -> ShellGlassShape {
        guard let declaration = boundShapes[handle], let source = declaration.source,
              let target = boundTarget(of: handle) else { return shape }
        let layout = CGRect(self.layout.core.absoluteFrame(of: target))
        let now = clock()
        let input = ShellBoundInput(
            layout: layout, canvas: CGRect(self.layout.core.absoluteFrame(of: self.layout.core.parent(of: handle))),
            presentation: currentPresentation(of: target), active: false, time: now
        )
        let progress = min(1, max(0, ShellBoundGeometry.progress(
            input.rect(at: now), canvas: input.canvas, source: source
        )))
        let velocity: Double
        if declaration.morph.stretch.gain != 0, case let .motion(motion) = input.presentation {
            let state = motion.progress(in: layout, canvas: input.canvas, source: source).state(at: now)
            velocity = state.progress > 0 && state.progress < 1 ? state.velocity : 0
        } else { velocity = 0 }
        let morphed = declaration.morph.shape(shape, progress: progress, velocity: velocity)
        return ShellBoundGeometry.place(morphed, source: source, input: input, progress: progress, at: now)
    }
}
