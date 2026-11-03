// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

extension ShellWidgetSurface {
    @discardableResult
    func updateDisplayContext(scale next: CGFloat) -> Bool {
        guard next.isFinite, next > 0 else { return false }
        var commands: [ShellLayerCommand] = []
        let changed = scale != next
        if changed {
            scale = next
            symbolImages.removeAll(keepingCapacity: true)
            iconImages.removeAll(keepingCapacity: true)
            inputAppearances.removeAll(keepingCapacity: true)
            samples.removeAll(keepingCapacity: true)
            commands.append(.backingScale(next))
            if let text { commands += backingScaleCommands(text: text) }
        }
        if let text, !effects.isEmpty { commands += effectCommands(text: text, refresh: changed) }
        guard !commands.isEmpty else { return false }
        scene.submit(commands, animated: false)
        if changed { onShapeChange?() }
        return true
    }

    func backingScaleCommands(text: ShellTextStore) -> [ShellLayerCommand] {
        var commands: [ShellLayerCommand] = []
        for handle in layout.core.elements(matching: { _ in true }) {
            let content = layout.core.content(of: handle)
            switch layout.core.kind(of: handle) {
            case .label,
                 .symbol,
                 .image:
                commands.append(textCommand(handle, text: text, content: TextPatch(
                    id: content.text, style: content.style, color: content.color,
                    maxWidth: content.maxWidth, lines: content.lines
                )))
            case .bitmap:
                if content.resourceImageRef != 0 {
                    commands.append(resourceImageCommand(handle, content: content, text: text))
                }
            case .input,
                 .group,
                 .box,
                 .shader,
                 .progress,
                 .slider,
                 .path,
                 .glass,
                 .shape:
                break
            }
        }
        return commands + ownedInputCommands()
    }
}
