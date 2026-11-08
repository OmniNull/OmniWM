// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class HotkeyPaletteYieldTests: XCTestCase {
    private let commandOne = KeyBinding(keyCode: UInt32(kVK_ANSI_1), modifiers: UInt32(cmdKey))
    private let hyperJ = KeyBinding(
        keyCode: UInt32(kVK_ANSI_J),
        modifiers: UInt32(controlKey | optionKey | cmdKey)
    )

    private let pauseButton = MouseButtonBinding.supportedButtons.lowerBound

    private func makeCenter(extra: [HotkeyBinding] = []) -> HotkeyCenter {
        let center = HotkeyCenter()
        center.updateBindings(
            [
                HotkeyBinding(id: "focus.left", command: .focus(.left), binding: commandOne),
                HotkeyBinding(id: "focus.right", command: .focus(.right), binding: hyperJ)
            ] + extra,
            systemHyperTrigger: .none
        )
        return center
    }

    private func registered(_ center: HotkeyCenter) -> Set<HotkeyCommand> {
        center.carbonRegistrations.registeredCommands
    }

    private let both: Set<HotkeyCommand> = [.focus(.left), .focus(.right)]

    func testCollidingGlobalShortcutYieldsOnlyWhilePaletteShortcutsAreActive() {
        let center = makeCenter()
        center.start()
        defer { center.stop() }
        XCTAssertEqual(registered(center), both)

        center.setPaletteShortcutChords([commandOne])
        XCTAssertEqual(registered(center), [.focus(.right)])

        center.setPaletteShortcutChords([])
        XCTAssertEqual(registered(center), both)
    }

    func testYieldPersistsWhenBindingsReloadWhilePaletteIsOpen() {
        let center = makeCenter()
        center.start()
        defer { center.stop() }

        center.setPaletteShortcutChords([commandOne])
        center.updateBindings(center.configuration.bindings, systemHyperTrigger: .none, force: true)
        XCTAssertEqual(registered(center), [.focus(.right)])

        center.setPaletteShortcutChords([])
        XCTAssertEqual(registered(center), both)
    }

    func testClosingPaletteDuringPauseLeavesShortcutsPausedUntilResume() throws {
        let center = makeCenter(extra: [
            HotkeyBinding(
                id: "toggleShortcutPause",
                command: .keyboardMode(.togglePause),
                trigger: .mouseButton(try XCTUnwrap(MouseButtonBinding(button: pauseButton, modifiers: 0)))
            )
        ])
        center.start()
        defer { center.stop() }

        XCTAssertTrue(center.dispatchMouseButton(pauseButton, flags: []))
        XCTAssertEqual(registered(center), [])
        center.setPaletteShortcutChords([commandOne])
        center.setPaletteShortcutChords([])
        XCTAssertEqual(registered(center), [])

        center.setPaletteShortcutChords([commandOne])
        XCTAssertTrue(center.dispatchMouseButton(pauseButton, flags: []))
        XCTAssertEqual(registered(center), [.focus(.right)])

        center.setPaletteShortcutChords([])
        XCTAssertEqual(registered(center), both)
    }

    func testSuspendedHotkeysStayUnregisteredWhenPaletteCloses() {
        let center = makeCenter()
        center.start()
        defer { center.stop() }

        center.setPaletteShortcutChords([commandOne])
        center.setCommandHotkeysSuspended(true)
        center.setPaletteShortcutChords([])
        XCTAssertEqual(registered(center), [])

        center.setCommandHotkeysSuspended(false)
        XCTAssertEqual(registered(center), both)
    }
}
