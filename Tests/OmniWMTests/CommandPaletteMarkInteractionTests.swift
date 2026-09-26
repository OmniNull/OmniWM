// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteMarkInteractionTests: XCTestCase {
    func testSetUsesCapturedSelectedWindowAndPromptedName() {
        let target = WindowToken(pid: 92_201, windowId: 92_301)
        let registry = WindowMarkRegistry()
        var promptCount = 0
        let interaction = makeInteraction(target: target, registry: registry, requestName: {
            promptCount += 1
            return "editor"
        })

        XCTAssertEqual(interaction.setSelectedWindowMark(), .marked("editor"))
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(registry.lookup("editor"), .found(target))
    }

    func testSetOutcomesUseCanonicalTrimmedName() {
        let target = WindowToken(pid: 92_211, windowId: 92_311)
        let other = WindowToken(pid: 92_212, windowId: 92_312)
        let registry = WindowMarkRegistry()

        let marked = makeInteraction(target: target, registry: registry, requestName: { " \t editor \n " })
        XCTAssertEqual(marked.setSelectedWindowMark(), .marked("editor"))

        let unchanged = makeInteraction(target: target, registry: registry, requestName: { " \t editor \n " })
        XCTAssertEqual(unchanged.setSelectedWindowMark(), .alreadyMarked("editor"))

        let duplicate = makeInteraction(target: other, registry: registry, requestName: { " \t editor \n " })
        XCTAssertEqual(duplicate.setSelectedWindowMark(), .duplicateName("editor"))
    }

    func testCancellingNamePromptDoesNotMutateMarkState() {
        let target = WindowToken(pid: 92_202, windowId: 92_302)
        let registry = WindowMarkRegistry()
        let interaction = makeInteraction(target: target, registry: registry, requestName: { nil })

        XCTAssertEqual(interaction.setSelectedWindowMark(), .cancelled)
        XCTAssertTrue(registry.marks.isEmpty)
    }

    func testMissingOrStaleSelectedTargetDoesNotPromptOrMutate() {
        let registry = WindowMarkRegistry()
        var promptCount = 0
        let missingTarget = makeInteraction(target: nil, registry: registry, requestName: {
            promptCount += 1
            return "editor"
        })
        XCTAssertEqual(missingTarget.setSelectedWindowMark(), .noSelectedWindow)

        let target = WindowToken(pid: 92_203, windowId: 92_303)
        let staleTarget = makeInteraction(target: target, registry: registry, isEligible: { _ in false }, requestName: {
            promptCount += 1
            return "editor"
        })
        XCTAssertEqual(staleTarget.setSelectedWindowMark(), .staleWindow)
        XCTAssertEqual(promptCount, 0)
        XCTAssertTrue(registry.marks.isEmpty)
    }

    func testSetRevalidatesSelectedTargetAfterPrompt() {
        let target = WindowToken(pid: 92_204, windowId: 92_304)
        let registry = WindowMarkRegistry()
        var isEligible = true
        let interaction = makeInteraction(
            target: target,
            registry: registry,
            isEligible: { _ in isEligible },
            requestName: {
                isEligible = false
                return "editor"
            }
        )

        XCTAssertEqual(interaction.setSelectedWindowMark(), .staleWindow)
        XCTAssertTrue(registry.marks.isEmpty)
    }

    func testSetReportsDuplicateAndInvalidNames() {
        let target = WindowToken(pid: 92_205, windowId: 92_305)
        let other = WindowToken(pid: 92_206, windowId: 92_306)
        let registry = WindowMarkRegistry()
        XCTAssertEqual(registry.set("editor", for: other), .inserted)

        let duplicate = makeInteraction(target: target, registry: registry, requestName: { "editor" })
        XCTAssertEqual(duplicate.setSelectedWindowMark(), .duplicateName("editor"))

        let invalid = makeInteraction(target: target, registry: registry, requestName: { "  " })
        XCTAssertEqual(invalid.setSelectedWindowMark(), .invalidName)
        XCTAssertEqual(registry.lookup("editor"), .found(other))
    }

    func testRemoveChooserGetsExactNamesAndRemovesOnlyItsChoice() {
        let target = WindowToken(pid: 92_207, windowId: 92_307)
        let registry = WindowMarkRegistry()
        XCTAssertEqual(registry.set("editor", for: target), .inserted)
        XCTAssertEqual(registry.set("focus-later", for: target), .inserted)
        var offeredNames: [String] = []
        let interaction = makeInteraction(
            target: nil,
            registry: registry,
            chooseRemovalName: { names in
                offeredNames = names
                return "editor"
            }
        )

        XCTAssertEqual(interaction.removeMarkFromSelectedWindow(target), .removed("editor"))
        XCTAssertEqual(offeredNames, ["editor", "focus-later"])
        XCTAssertEqual(registry.names(for: target), ["focus-later"])
        XCTAssertEqual(registry.lookup("focus-later"), .found(target))
    }

    func testRemoveRejectsANameThatChangedWhileChooserWasOpen() {
        let target = WindowToken(pid: 92_208, windowId: 92_308)
        let other = WindowToken(pid: 92_209, windowId: 92_309)
        let registry = WindowMarkRegistry()
        XCTAssertEqual(registry.set("editor", for: target), .inserted)
        let interaction = makeInteraction(
            target: nil,
            registry: registry,
            chooseRemovalName: { _ in
                _ = registry.remove("editor")
                _ = registry.set("editor", for: other)
                return "editor"
            }
        )

        XCTAssertEqual(interaction.removeMarkFromSelectedWindow(target), .staleMark)
        XCTAssertEqual(registry.lookup("editor"), .found(other))
    }

    func testPromptsExposeAccessibleLabelsAndExplicitActions() {
        XCTAssertEqual(CommandPaletteMarkNamePrompt.title, "Mark selected window")
        XCTAssertEqual(CommandPaletteMarkNamePrompt.fieldLabel, "Window mark name")
        XCTAssertEqual(CommandPaletteMarkNamePrompt.confirmTitle, "Set Mark")
        XCTAssertEqual(CommandPaletteMarkNamePrompt.cancelTitle, "Cancel")
        XCTAssertEqual(CommandPaletteMarkRemovalPrompt.title, "Remove a window mark")
        XCTAssertEqual(CommandPaletteMarkRemovalPrompt.fieldLabel, "Window mark to remove")
        XCTAssertEqual(CommandPaletteMarkRemovalPrompt.confirmTitle, "Remove Mark")
        XCTAssertEqual(CommandPaletteMarkRemovalPrompt.cancelTitle, "Cancel")
    }

    func testBothMarkPromptsBindEscapeToCancel() {
        let nameAlert = CommandPaletteMarkNamePrompt.makeAlert(nameField: NSTextField())
        let pickerAlert = CommandPaletteMarkRemovalPrompt.makeAlert(namePicker: NSPopUpButton(frame: .zero))

        XCTAssertEqual(nameAlert.buttons.last?.title, "Cancel")
        XCTAssertEqual(nameAlert.buttons.last?.keyEquivalent, "\u{1b}")
        XCTAssertEqual(pickerAlert.buttons.last?.title, "Cancel")
        XCTAssertEqual(pickerAlert.buttons.last?.keyEquivalent, "\u{1b}")
    }

    private func makeInteraction(
        target: WindowToken?,
        registry: WindowMarkRegistry,
        isEligible: @escaping (WindowToken) -> Bool = { _ in true },
        requestName: @escaping () -> String? = { nil },
        chooseRemovalName: @escaping ([String]) -> String? = { _ in nil }
    ) -> CommandPaletteMarkInteraction {
        CommandPaletteMarkInteraction(
            selectedWindowToken: target,
            isEligibleWindow: isEligible,
            requestName: requestName,
            chooseRemovalName: chooseRemovalName,
            namesForWindow: { registry.names(for: $0) },
            lookupMark: { registry.lookup($0) },
            setMark: { token, name in registry.set(name, for: token) },
            removeMark: { registry.remove($0) }
        )
    }
}
