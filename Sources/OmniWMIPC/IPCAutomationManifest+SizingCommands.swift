// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    static let sizingCommandDescriptors: [IPCCommandDescriptor] = [
        .init(
            commandWords: ["cycle-size", "forward"],
            name: .sizing(.cycleSizeForward),
            summary: "Cycle layout sizing presets forward."
        ),
        .init(
            commandWords: ["cycle-size", "backward"],
            name: .sizing(.cycleSizeBackward),
            summary: "Cycle layout sizing presets backward."
        ),
        .init(
            commandWords: ["cycle-window-primary-span", "forward"],
            name: .sizing(.cycleWindowPrimarySpanForward),
            summary: "Cycle Niri window primary-span presets forward.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["cycle-window-primary-span", "backward"],
            name: .sizing(.cycleWindowPrimarySpanBackward),
            summary: "Cycle Niri window primary-span presets backward.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["cycle-window-secondary-span", "forward"],
            name: .sizing(.cycleWindowSecondarySpanForward),
            summary: "Cycle Niri window secondary-span presets forward.",
            layoutCompatibility: .niri
        ),
        .init(
            commandWords: ["cycle-window-secondary-span", "backward"],
            name: .sizing(.cycleWindowSecondarySpanBackward),
            summary: "Cycle Niri window secondary-span presets backward.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.toggleContainerFullPrimarySpan),
            summary: "Toggle full-primary-span mode for the focused Niri container.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.expandContainerToAvailablePrimarySpan),
            summary: "Expand the focused Niri container into available primary-axis space.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.resetWindowSecondarySpan),
            summary: "Reset the focused Niri window secondary span.",
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.setContainerPrimarySpan),
            summary: "Set or adjust the focused Niri container primary span.",
            arguments: [.sizeChange],
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.setWindowPrimarySpan),
            summary: "Set or adjust the focused Niri window primary span.",
            arguments: [.sizeChange],
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.setWindowSecondarySpan),
            summary: "Set or adjust the focused Niri window secondary span.",
            arguments: [.sizeChange],
            layoutCompatibility: .niri
        ),
        .init(
            name: .sizing(.setVisibleContainers),
            summary: "Set how many Niri columns fit on screen, or 0 for Off, as the Visible Containers setting does.",
            arguments: [.visibleContainerCount]
        )
    ]
}
