// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

struct ShellBoundBinding: Equatable, Sendable {
    let target: Int32
    let frame: CGRect
    let origin: CGPoint
}

struct ShellBoundInput: Sendable {
    let layout: CGRect
    let canvas: CGRect
    let presentation: ShellManipulationPresentation
    let active: Bool
    let time: CFTimeInterval
    var animates = true
    var binding: ShellBoundBinding?

    var geometryScale: CGFloat {
        binding.map { layout.width / $0.frame.width } ?? 1
    }

    func contactTranslation(of rect: CGRect, at time: CFTimeInterval) -> CGPoint {
        let (translation, scale) = presentation.placement(at: time)
        let authored = binding.map { $0.frame.offsetBy(dx: -$0.origin.x, dy: -$0.origin.y) } ?? layout
        let factor = scale * geometryScale
        return CGPoint(
            x: translation.x + (layout.minX - authored.minX) + (rect.midX - authored.minX) * (factor - 1),
            y: translation.y + (layout.minY - authored.minY) + (rect.midY - authored.minY) * (factor - 1)
        )
    }

    func matches(_ other: ShellBoundInput) -> Bool {
        guard layout == other.layout, canvas == other.canvas, active == other.active,
              animates == other.animates, binding == other.binding else { return false }
        switch (presentation, other.presentation) {
        case let (.still(first, scale, _), .still(second, otherScale, _)):
            return first == second && scale == otherScale
        case let (.motion(first), .motion(second)):
            return first == second
        default:
            return false
        }
    }

    func rect(at time: CFTimeInterval) -> CGRect {
        let (translation, scale) = presentation.placement(at: time)
        return CGRect(
            x: layout.minX + translation.x,
            y: layout.minY + translation.y,
            width: layout.width * scale,
            height: layout.height * scale
        )
    }
}

struct ShellBoundTrack {
    let input: ShellBoundInput
    let source: ShellMorphRecipe.Source
    let plan: ShellReveal
    let previous: Double?
    let revision: UInt64
    let clampCrossings: [CFTimeInterval]

    init(input: ShellBoundInput, source: ShellMorphRecipe.Source, previous: Double?, revision: UInt64) {
        self.input = input
        self.source = source
        self.previous = previous
        self.revision = revision
        if case let .motion(motion) = input.presentation {
            plan = motion.progress(in: input.layout, canvas: input.canvas, source: source)
        } else {
            let progress = ShellBoundGeometry.progress(input.rect(at: input.time), canvas: input.canvas, source: source)
            plan = ShellReveal(
                begin: input.time,
                progress: progress,
                target: progress,
                spring: ShellMorphRecipe.Spring(response: 0.35, bounce: 0.15).parameters,
                duration: 0
            )
        }
        clampCrossings = Self.clampingTimes(input, source: source, plan: plan)
    }

    var end: CFTimeInterval {
        max(input.time, plan.end)
    }

    func state(at time: CFTimeInterval) -> (progress: Double, velocity: Double) {
        let state = plan.state(at: time)
        return (min(1, max(0, state.progress)), state.progress > 0 && state.progress < 1 ? state.velocity : 0)
    }

    func crossings(at value: Double, rising: Bool) -> [CFTimeInterval] {
        guard (0 ... 1).contains(value) else { return [] }
        if case .motion = input.presentation {
            return plan.crossings(at: value, rising: rising).filter { $0 >= input.time }
        }
        guard let previous else { return [] }
        let next = state(at: input.time).progress
        let crossed = rising ? previous < value && next >= value : previous > value && next <= value
        return crossed ? [input.time] : []
    }

    func place(_ shape: ShellGlassShape, progress: Double, at time: CFTimeInterval) -> ShellGlassShape {
        ShellBoundGeometry.place(shape, source: source, input: input, progress: progress, at: time)
    }

    func contact(at time: CFTimeInterval, on shape: ShellGlassShape) -> ShellShapeContact? {
        guard source.contact else { return nil }
        let translation = input.contactTranslation(of: shape.rect, at: time)
        let vertical = source.edge == .left || source.edge == .right
        return ShellShapeContact(
            vertical: vertical,
            position: vertical ? shape.rect.midY + translation.y : shape.rect.midX + translation.x
        )
    }

    private static func clampingTimes(
        _ input: ShellBoundInput, source: ShellMorphRecipe.Source, plan: ShellReveal
    ) -> [CFTimeInterval] {
        guard case let .motion(motion) = input.presentation else { return [] }
        var plans = [plan]
        if source.pads != nil {
            for edge in [ShellMorphRecipe.SourceEdge.top, .left, .right, .bottom] {
                guard let from = source.adhere.from(edge) else { continue }
                let extra = ShellMorphRecipe.Source(
                    target: source.target,
                    edge: edge,
                    from: from,
                    span: source.span,
                    pads: nil
                )
                plans.append(motion.progress(in: input.layout, canvas: input.canvas, source: extra))
            }
        }
        return Array(Set(plans.flatMap { plan in
            [0.0, 1.0].flatMap { value in
                plan.crossings(at: value, rising: true) + plan.crossings(at: value, rising: false)
            }
        }.filter { $0 >= input.time && $0 <= plan.end })).sorted()
    }
}

struct ShellBoundGeometry {
    static func progress(_ rect: CGRect, canvas: CGRect, source: ShellMorphRecipe.Source) -> Double {
        (gap(rect, canvas: canvas, edge: source.edge) - source.from) / source.span
    }

    static func gap(_ rect: CGRect, canvas: CGRect, edge: ShellMorphRecipe.SourceEdge) -> Double {
        switch edge {
        case .left: rect.minX - canvas.minX
        case .top: rect.minY - canvas.minY
        case .right: canvas.maxX - rect.maxX
        case .bottom: canvas.maxY - rect.maxY
        }
    }

    static func contact(_ translation: CGPoint, edge: ShellMorphRecipe.SourceEdge) -> CGPoint {
        switch edge {
        case .left,
             .right: CGPoint(x: 0, y: translation.y)
        case .top,
             .bottom: CGPoint(x: translation.x, y: 0)
        }
    }

    static func place(
        _ shape: ShellGlassShape, source: ShellMorphRecipe.Source, input: ShellBoundInput,
        progress: Double, at time: CFTimeInterval
    ) -> ShellGlassShape {
        guard source.contact || source.pads != nil else { return shape }
        let (translation, scale) = input.presentation.placement(at: time)
        if source.contact {
            let offset = contact(input.contactTranslation(of: shape.rect, at: time), edge: source.edge)
            return shape.with(rect: shape.rect.offsetBy(dx: offset.x, dy: offset.y))
        }
        guard let pads = source.pads else { return shape }
        let rect = CGRect(
            x: input.layout.minX + translation.x, y: input.layout.minY + translation.y,
            width: input.layout.width * scale, height: input.layout.height * scale
        )
        func edge(_ side: ShellMorphRecipe.SourceEdge, _ attached: Double, _ presented: Double) -> Double {
            let amount: Double
            if side == source.edge { amount = progress }
            else if let from = source.adhere.from(side) {
                amount = min(
                    1,
                    max(0, (gap(rect, canvas: input.canvas, edge: side) - from) / source.span)
                )
            } else { return presented }
            return attached + (presented - attached) * amount
        }
        let factor = scale * input.geometryScale
        let left = edge(.left, shape.rect.minX, rect.minX + pads.left * factor)
        let right = edge(.right, shape.rect.maxX, rect.maxX + pads.right * factor)
        let top = edge(.top, shape.rect.minY, rect.minY + pads.top * factor)
        let bottom = edge(.bottom, shape.rect.maxY, rect.maxY + pads.bottom * factor)
        return shape.with(
            rect: CGRect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top)),
            radius: shape.radius * factor
        )
    }
}

struct ShellShapeContact: Equatable, Sendable {
    let vertical: Bool
    let position: CGFloat

    func place(_ shape: ShellGlassShape) -> ShellGlassShape {
        shape.with(rect: shape.rect.offsetBy(
            dx: vertical ? 0 : position - shape.rect.midX,
            dy: vertical ? position - shape.rect.midY : 0
        ))
    }
}
