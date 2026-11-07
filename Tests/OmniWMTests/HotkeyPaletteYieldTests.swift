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

    private func mouseTrigger(_ button: Int64) throws -> HotkeyTrigger {
        .mouseButton(try XCTUnwrap(MouseButtonBinding(button: button, modifiers: 0)))
    }

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

    func testCollidingGlobalShortcutYieldsOnlyWhilePaletteShortcutsAreActive() {
        let center = makeCenter()
        center.start()
        defer { center.stop() }
        XCTAssertEqual(center.carbonRegistrations.count, 2)

        center.setPaletteShortcutChords([commandOne])
        XCTAssertEqual(center.carbonRegistrations.count, 1)

        center.setPaletteShortcutChords([])
        XCTAssertEqual(center.carbonRegistrations.count, 2)
    }

    func testYieldPersistsWhenBindingsReloadWhilePaletteIsOpen() {
        let center = makeCenter()
        center.start()
        defer { center.stop() }

        center.setPaletteShortcutChords([commandOne])
        center.updateBindings(center.configuration.bindings, systemHyperTrigger: .none, force: true)
        XCTAssertEqual(center.carbonRegistrations.count, 1)

        center.setPaletteShortcutChords([])
        XCTAssertEqual(center.carbonRegistrations.count, 2)
    }

    func testClosingPaletteDuringPauseLeavesShortcutsPausedUntilResume() throws {
        let center = makeCenter(extra: [
            HotkeyBinding(
                id: "toggleShortcutPause",
                command: .keyboardMode(.togglePause),
                trigger: try mouseTrigger(3)
            )
        ])
        center.start()
        defer { center.stop() }

        XCTAssertTrue(center.dispatchMouseButton(3, flags: []))
        XCTAssertEqual(center.carbonRegistrations.count, 0)
        center.setPaletteShortcutChords([commandOne])
        center.setPaletteShortcutChords([])
        XCTAssertEqual(center.carbonRegistrations.count, 0)

        center.setPaletteShortcutChords([commandOne])
        XCTAssertTrue(center.dispatchMouseButton(3, flags: []))
        XCTAssertEqual(center.carbonRegistrations.count, 1)

        center.setPaletteShortcutChords([])
        XCTAssertEqual(center.carbonRegistrations.count, 2)
    }

    func testSuspendedHotkeysStayUnregisteredWhenPaletteCloses() {
        let center = makeCenter()
        center.start()
        defer { center.stop() }

        center.setPaletteShortcutChords([commandOne])
        center.setCommandHotkeysSuspended(true)
        center.setPaletteShortcutChords([])
        XCTAssertEqual(center.carbonRegistrations.count, 0)

        center.setCommandHotkeysSuspended(false)
        XCTAssertEqual(center.carbonRegistrations.count, 2)
    }
}
