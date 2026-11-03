// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import OmniWMShellCore
import QuartzCore

struct ShellGlassContent: Sendable {
    let kind: ElementKind
    let recipe: String
    let shape: UInt8
    let paint: ShellLayerPaint
    let params: SIMD4<Float>
    var follow: ShellFollowRadius?
    var spectrumMotion = MotionSnapshot.enabled
}

extension ShellLayerScene {
    func applyGlass(_ slot: Int32, _ content: ShellGlassContent, preset: ShellAnimation?, animated: Bool) {
        guard let layer = layers[slot] else { return }
        if content.kind == .glass {
            guard let parsed = ShellGlassRecipe(content.recipe) else {
                Log.shell.error("Invalid native glass body recipe")
                return
            }
            glassStyles[slot] = (parsed, content.paint)
            applyPaint(slot, content.paint, preset: preset, animated: animated)
            dirtyGlass.insert(slot)
        } else if content.kind == .shape {
            glassShapes[slot] = ShellGlassShape(
                slot: slot,
                kind: content.shape,
                rect: layer.frame,
                radius: content.paint.radius,
                thickness: CGFloat(content.params.x),
                rotation: content.paint.rotation
            )
            if let shape = glassShapes[slot] { bindSpectrum(slot, shape: shape, content: content) }
            if content.paint.reveal == nil { presence.revealPlans.removeValue(forKey: slot) }
            if content.paint.morph == nil, content.paint.reveal == nil, content.follow == nil,
               let entry = shapeTracks.entries.removeValue(forKey: slot), let body = glassBodies[entry.body]
            {
                body.setTrackGeometry(entry.shape(at: now()))
                body.removeTrack(slot)
                shapeTracks.follows[slot]?.dirty = true
            }
            presence.morphs[slot] = content.paint.morph
            presence.reveals[slot] = content.paint.reveal
            bindShapeFollow(slot, content.follow)
            markGlassDirty(slot)
        }
        if framed.contains(slot) { glassAnimations[slot] = animated ? preset : nil }
    }

    func insertGlass(_ slot: Int32, kind: ElementKind, layer: CALayer) {
        if kind == .glass {
            let body = ShellGlassBody(forceFallback: !glassNativeEnabled)
            glassBodies[slot] = body
            layer.addSublayer(body.layer)
        } else {
            layer.isHidden = true
            glassShapeSlots[ObjectIdentifier(layer)] = slot
        }
    }

    func forgetGlass(_ slot: Int32) {
        shapeTracks.pendingBounds.removeValue(forKey: slot)
        forgetSpectrum(slot)
        forgetShapeTracks(slot)
        markGlassDirty(slot)
        if let layer = layers[slot], glassShapeSlots[ObjectIdentifier(layer)] == slot {
            glassShapeSlots.removeValue(forKey: ObjectIdentifier(layer))
        }
        glassShapes.removeValue(forKey: slot)
        forgetShapeBindings(slot)
        glassBodies.removeValue(forKey: slot)
        glassStyles.removeValue(forKey: slot)
        glassAnimations.removeValue(forKey: slot)
        dirtyGlass.remove(slot)
    }

    func markGlassDirty(_ slot: Int32) {
        if glassBodies[slot] != nil { dirtyGlass.insert(slot) }
        if let parent = parents[slot], glassBodies[parent] != nil { dirtyGlass.insert(parent) }
    }

    func updateGlassFrame(_ slot: Int32, rect: CGRect, animation: ShellAnimation?, entering: Bool) {
        if let shape = glassShapes[slot] {
            glassShapes[slot] = ShellGlassShape(
                slot: slot,
                kind: shape.kind,
                rect: rect,
                radius: shape.radius,
                thickness: shape.thickness,
                rotation: shape.rotation
            )
        }
        if let shape = glassShapes[slot], spectrum.bindings[slot] != nil { spectrum.bindings[slot]?.base = shape }
        markGlassDirty(slot)
        if !entering, glassBodies[slot] != nil || glassShapes[slot] != nil { glassAnimations[slot] = animation }
    }

    func flushGlass(animated: Bool) {
        shapeTracks.updatedBodies.formUnion(dirtyGlass)
        shapeTracks.presets = glassAnimations
        prepareShapeTracks(animated: animated)
        for slot in dirtyGlass {
            guard let body = glassBodies[slot], let layer = layers[slot],
                  let style = glassStyles[slot] else { continue }
            finishReplacedFrames(in: slot)
            let shapes = (layer.sublayers ?? []).compactMap { part in
                glassShapeSlots[ObjectIdentifier(part)].flatMap { glassShapes[$0] }
            }.filter { $0.rect.width > 0 && $0.rect.height > 0 }
            body.apply(
                size: layer.bounds.size,
                shapes: shapes,
                recipe: style.recipe,
                paint: style.paint,
                animation: animated ? glassAnimations[slot] : nil,
                shapeAnimations: animated ? glassAnimations : [:],
                geometryOwners: spectrumOwners(in: slot)
            )
        }
        flushShapeFollows()
        refreshSpectrumTargets(in: dirtyGlass)
        dirtyGlass.removeAll(keepingCapacity: true)
        glassAnimations.removeAll(keepingCapacity: true)
    }
}
