// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

struct ShellEffectRecipe {
    let source: String
    let rate: Int
    let bleed: CGFloat
    let values: SIMD4<Float>

    init?(_ source: String) {
        let fields = source.split(separator: ":", maxSplits: 7, omittingEmptySubsequences: false)
        guard fields.count == 8, fields[0] == "effect", let rate = Int(fields[1]), (0 ... 120).contains(rate),
              let bleed = Double(fields[2]), bleed.isFinite, (0 ... 128).contains(bleed) else { return nil }
        var values = SIMD4<Float>.zero
        for index in 0 ..< 4 {
            guard let value = Float(fields[index + 3]), value.isFinite, abs(value) <= 1_000_000 else { return nil }
            values[index] = value
        }
        let name = String(fields[7])
        guard !name.isEmpty, name.utf8.count <= 240,
              !name.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else { return nil }
        self.source = name
        self.rate = rate
        self.bleed = bleed
        self.values = values
    }
}

extension ShellWidgetSurface {
    struct EffectBinding {
        let handle: ElementHandle
        let reference: UInt32
        let recipe: ShellEffectRecipe
        let program: ShellShaderProgram
        let display: UInt32?
        let size: CGSize
    }

    func effectCommands(text: ShellTextStore, refresh: Bool = false) -> [ShellLayerCommand] {
        var commands: [ShellLayerCommand] = []
        var bindings: [Int32: EffectBinding] = [:]
        let display = view.window?.screen?.displayId
        for handle in layout.core.elements(matching: { $0.effect != 0 }) {
            let reference = layout.core.content(of: handle).effect
            let size = CGRect(layout.core.layoutFrame(of: handle)).size
            guard let recipe = ShellEffectRecipe(text.string(reference)) else { continue }
            if !refresh, let old = effects[handle.slot], old.handle == handle, old.reference == reference,
               old.display == display, old.size == size
            {
                bindings[handle.slot] = old
                continue
            }
            let program = resources.shaders.program(
                source: recipe.source,
                directories: shaderDirectories,
                packages: assetFolders
            )
            bindings[handle.slot] = EffectBinding(
                handle: handle,
                reference: reference,
                recipe: recipe,
                program: program,
                display: display,
                size: size
            )
            let input = ShellShaderInput(
                values: recipe.values,
                rate: motionPolicy.animationsEnabled ? min(recipe.rate, 60) : 0,
                colors: palette.shaderColors
            )
            commands.append(.effect(
                slot: handle.slot,
                input: ShellGroupEffectInput(program: program, shader: input, bleed: recipe.bleed, display: display)
            ))
        }
        for (slot, binding) in effects where bindings[slot] == nil && layout.core.contains(binding.handle) {
            commands.append(.effect(slot: slot, input: nil))
        }
        effects = bindings
        return commands
    }

    func effectNeutralCommands() -> [ShellLayerCommand] {
        let owner = declaredFocus && textInputs[focused] != nil ? manipulationOwner(of: focused) : nil
        return effects.map { slot, binding in
            let neutral = !motionPolicy
                .animationsEnabled || (owner != nil && manipulationOwner(of: binding.handle) == owner)
            return .effectNeutral(slot: slot, neutral)
        }
    }
}
