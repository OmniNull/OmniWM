// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import QuartzCore

extension ShellLayerScene {
    func applyEffect(_ slot: Int32, input: ShellGroupEffectInput?) {
        guard let input, input.program.failure == nil else {
            if let effect = effects.removeValue(forKey: slot) {
                shaders?.remove(slot)
                effect.restore()
            }
            return
        }
        guard input.program.pipeline != nil else { return }
        if let effect = effects[slot] {
            if effect.failed || effect.output.superlayer == nil {
                effects.removeValue(forKey: slot)
                shaders?.remove(slot)
                effect.restore()
            } else {
                effect.update(input)
                shaderDrawer().updateGroup(slot, group: effect)
                return
            }
        }
        guard let source = layers[slot], input.bleed.isFinite, (0 ... 256).contains(input.bleed),
              !hasEffectAncestor(slot), !containsBackdropOrEffect(slot)
        else {
            Log.shell.error("Group effect \(input.program.name): nested effects and backdrop materials are unsupported")
            return
        }
        let effect = ShellGroupEffect(source: source, scale: scale, input: input)
        effects[slot] = effect
        effect.attach()
        shaderDrawer().updateGroup(slot, group: effect)
    }

    @discardableResult
    func invalidateContainingEffect(_ slot: Int32) -> Bool {
        var current: Int32? = slot
        while let candidate = current {
            if let effect = effects[candidate] {
                effect.invalidate()
                return true
            }
            current = parents[candidate]
        }
        return false
    }

    func invalidateEffect(for command: ShellLayerCommand) {
        switch command {
        case let .insert(slot, _, _, _, _),
             let .remove(slot),
             let .move(slot, _),
             let .frame(slot, _, _),
             let .paint(slot, _, _),
             let .text(slot, _, _, _, _, _, _),
             let .image(slot, _, _, _),
             let .value(slot, _, _, _, _),
             let .scroll(slot, _),
             let .path(slot, _, _),
             let .glass(slot, _, _),
             let .shader(slot, _, _),
             let .gesture(slot, _, _),
             let .settleGesture(slot, _, _, _):
            invalidateContainingEffect(slot)
        case .transition:
            for effect in effects.values { effect.invalidate() }
        default:
            break
        }
    }

    private func hasEffectAncestor(_ slot: Int32) -> Bool {
        var current = parents[slot]
        while let candidate = current {
            if effects[candidate] != nil { return true }
            current = parents[candidate]
        }
        return false
    }

    private func containsBackdropOrEffect(_ slot: Int32) -> Bool {
        for candidate in Set(backdrops.keys).union(effects.keys).union(glassBodies.keys) {
            var current: Int32? = candidate
            while let value = current {
                if value == slot { return true }
                current = parents[value]
            }
        }
        return false
    }
}
