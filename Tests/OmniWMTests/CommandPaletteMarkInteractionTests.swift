// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteMarkInteractionTests: XCTestCase {
    func testSetUsesCapturedFocusedWindowAndPromptedName() {
        let target = WindowToken(pid: 92_201, windowId: 92_301)
        let registry = WindowMarkRegistry()
        var promptCount = 0
        let interaction = makeInteraction(target: target, registry: registry, requestName: {
            promptCount += 1
            return "editor"
        })

        XCTAssertEqual(interaction.setFocusedWindowMark(), .marked("editor"))
        XCTAssertEqual(promptCount, 1)
        XCTAssertEqual(registry.lookup("editor"), .found(target))
    }

    func testSetOutcomesUseCanonicalTrimmedName() {
        let target = WindowToken(pid: 92_211, windowId: 92_311)
        let other = WindowToken(pid: 92_212, windowId: 92_312)
        let registry = WindowMarkRegistry()

        let marked = makeInteraction(target: target, registry: registry, requestName: { " \t editor \n " })
        XCTAssertEqual(marked.setFocusedWindowMark(), .marked("editor"))

        let unchanged = makeInteraction(target: target, registry: registry, requestName: { " \t editor \n " })
        XCTAssertEqual(unchanged.setFocusedWindowMark(), .alreadyMarked("editor"))

        let duplicate = makeInteraction(target: other, registry: registry, requestName: { " \t editor \n " })
        XCTAssertEqual(duplicate.setFocusedWindowMark(), .duplicateName("editor"))
    }

    func testCancellingNamePromptDoesNotMutateMarkState() {
        let target = WindowToken(pid: 92_202, windowId: 92_302)
        let registry = WindowMarkRegistry()
        let interaction = makeInteraction(target: target, registry: registry, requestName: { nil })

        XCTAssertEqual(interaction.setFocusedWindowMark(), .cancelled)
        XCTAssertTrue(registry.marks.isEmpty)
    }

    func testMissingOrStaleCapturedTargetDoesNotPromptOrMutate() {
        let registry = WindowMarkRegistry()
        var promptCount = 0
        let missingTarget = makeInteraction(target: nil, registry: registry, requestName: {
            promptCount += 1
            return "editor"
        })
        XCTAssertEqual(missingTarget.setFocusedWindowMark(), .noFocusedWindow)

        let target = WindowToken(pid: 92_203, windowId: 92_303)
        let staleTarget = makeInteraction(target: target, registry: registry, isEligible: { _ in false }, requestName: {
            promptCount += 1
            return "editor"
        })
        XCTAssertEqual(staleTarget.setFocusedWindowMark(), .staleWindow)
        XCTAssertEqual(promptCount, 0)
        XCTAssertTrue(registry.marks.isEmpty)
    }

    func testSetRevalidatesCapturedTargetAfterPrompt() {
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

        XCTAssertEqual(interaction.setFocusedWindowMark(), .staleWindow)
        XCTAssertTrue(registry.marks.isEmpty)
    }

    func testSetReportsDuplicateAndInvalidNames() {
        let target = WindowToken(pid: 92_205, windowId: 92_305)
        let other = WindowToken(pid: 92_206, windowId: 92_306)
        let registry = WindowMarkRegistry()
        XCTAssertEqual(registry.set("editor", for: other), .inserted)

        let duplicate = makeInteraction(target: target, registry: registry, requestName: { "editor" })
        XCTAssertEqual(duplicate.setFocusedWindowMark(), .duplicateName("editor"))

        let invalid = makeInteraction(target: target, registry: registry, requestName: { "  " })
        XCTAssertEqual(invalid.setFocusedWindowMark(), .invalidName)
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
        XCTAssertEqual(CommandPaletteMarkNamePrompt.title, "Mark focused window")
        XCTAssertEqual(CommandPaletteMarkNamePrompt.fieldLabel, "Window mark name")
        XCTAssertEqual(CommandPaletteMarkNamePrompt.confirmTitle, "Set Mark")
        XCTAssertEqual(CommandPaletteMarkNamePrompt.cancelTitle, "Cancel")
        XCTAssertEqual(CommandPaletteMarkRemovalPrompt.title, "Remove a window mark")
        XCTAssertEqual(CommandPaletteMarkRemovalPrompt.fieldLabel, "Window mark to remove")
        XCTAssertEqual(CommandPaletteMarkRemovalPrompt.confirmTitle, "Remove Mark")
        XCTAssertEqual(CommandPaletteMarkRemovalPrompt.cancelTitle, "Cancel")
    }

    private func makeInteraction(
        target: WindowToken?,
        registry: WindowMarkRegistry,
        isEligible: @escaping (WindowToken) -> Bool = { _ in true },
        requestName: @escaping () -> String? = { nil },
        chooseRemovalName: @escaping ([String]) -> String? = { _ in nil }
    ) -> CommandPaletteMarkInteraction {
        CommandPaletteMarkInteraction(
            focusedWindowToken: target,
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
