// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Carbon
@testable import OmniWM
import XCTest

final class HotkeySettingsDisplayModelTests: XCTestCase {
    func testSearchFindsSizingColumnAndNormalCommands() {
        let sizing = [
            "resizeContainerPrimarySpan.shrink",
            "resizeContainerPrimarySpan.grow",
            "resizeWindowSecondarySpan.shrink",
            "resizeWindowSecondarySpan.grow"
        ]
        let cases: [(String, [String], [String])] = [
            ("increase", sizing, ["resizeContainerPrimarySpan.grow", "resizeWindowSecondarySpan.grow"]),
            ("decrease", sizing, ["resizeContainerPrimarySpan.shrink", "resizeWindowSecondarySpan.shrink"]),
            ("column", ["moveColumn.left", "moveColumn.right"], ["moveColumn.left", "moveColumn.right"]),
            ("left", ["move.left", "moveColumn.left"], ["move.left", "moveColumn.left"])
        ]
        for (search, ids, expected) in cases {
            let bindings = HotkeyBindingRegistry.defaults().filter { ids.contains($0.id) }
            XCTAssertEqual(bindings.count, ids.count, search)
            XCTAssertEqual(Set(searchIDs(search, bindings: bindings)), Set(expected), search)
        }
    }

    func testSearchFindsWindowMarkActionsAndTheyDefaultUnassigned() throws {
        let ids = ["setWindowMark", "removeWindowMark"]
        let bindings = HotkeyBindingRegistry.defaults().filter { ids.contains($0.id) }

        XCTAssertEqual(Set(searchIDs("mark", bindings: bindings)), Set(ids))
        XCTAssertEqual(bindings.count, ids.count)
        XCTAssertTrue(bindings.allSatisfy(\.binding.isUnassigned))
        XCTAssertEqual(
            Set(bindings.map(\.command.displayName)),
            Set(["Set Mark on Focused Window", "Remove Mark from Focused Window"])
        )
    }

    func testSearchFindsAdvancedCommandByConfiguredShortcut() throws {
        let shortcut = try XCTUnwrap(KeySymbolMapper.fromHumanReadable("Hyper+Minus"))
        let binding = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(
            id: "resizeContainerPrimarySpan.shrink",
            binding: shortcut
        ))

        XCTAssertEqual(searchIDs("hyper+minus", bindings: [binding]), [binding.id])
    }

    func testListShowsAdvancedCommandsAndExcludesUnassignableCommands() throws {
        let advanced = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(id: "moveColumn.left", binding: .unassigned))
        let unavailable = HotkeyBinding(
            id: "consumeOrExpelWindowLeft",
            command: .focusNavigation(.previous),
            trigger: .unassigned
        )
        let bindings = [advanced, unavailable]

        XCTAssertEqual(searchIDs("", bindings: bindings), [advanced.id])
        XCTAssertEqual(searchIDs("   ", bindings: bindings), [advanced.id])
    }

    func testSearchPreservesCategoryAndBindingOrderAndOmitsEmptyGroups() {
        let bindings = Array(HotkeyBindingRegistry.defaults().reversed())
        let groups = HotkeySettingsDisplayModel.search("left", bindings: bindings)
        let categories = groups.map(\.category)
        XCTAssertEqual(categories, HotkeyCategory.allCases.filter { categories.contains($0) })
        XCTAssertFalse(groups.isEmpty)
        for group in groups {
            XCTAssertFalse(group.bindings.isEmpty)
            XCTAssertTrue(group.bindings.allSatisfy { $0.category == group.category })
            let ids = Set(group.bindings.map(\.id))
            XCTAssertEqual(group.bindings.map(\.id), bindings.filter { ids.contains($0.id) }.map(\.id))
        }
    }

    func testSearchUpdatesImmediatelyAfterShortcutChanges() throws {
        let first = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(
            id: "move.left",
            binding: KeyBinding(keyCode: UInt32(kVK_F18), modifiers: UInt32(optionKey)).settingSide(.right)
        ))
        let reset = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(id: first.id, binding: .unassigned))
        XCTAssertEqual(searchIDs("F18", bindings: [first]), [first.id])
        XCTAssertEqual(searchIDs(first.binding.humanReadableString, bindings: [first]), [first.id])
        XCTAssertTrue(searchIDs("F18", bindings: [reset]).isEmpty)
        XCTAssertEqual(searchIDs("Unassigned", bindings: [reset]), [first.id])
    }

    func testSearchUsesCurrentHyperCompositionAfterMetadataIsCached() throws {
        let original = try XCTUnwrap(HyperKeyModifiers(carbonMask: KeySymbolMapper.hyperModifiers))
        defer { KeySymbolMapper.setHyperKeyModifiers(original) }
        KeySymbolMapper.setHyperKeyModifiers(.default)
        let binding = try XCTUnwrap(HotkeyBindingRegistry.makeBinding(
            id: "move.left",
            binding: KeyBinding(keyCode: UInt32(kVK_F18), modifiers: HyperKeyModifiers.default.carbonMask)
        ))
        XCTAssertEqual(searchIDs("Hyper+F18", bindings: [binding]), [binding.id])
        KeySymbolMapper
            .setHyperKeyModifiers(try XCTUnwrap(HyperKeyModifiers.fromHumanReadable("Control+Option+Command")))
        XCTAssertTrue(searchIDs("Hyper+F18", bindings: [binding]).isEmpty)
        XCTAssertEqual(searchIDs(binding.binding.humanReadableString, bindings: [binding]), [binding.id])
    }

    func testSearchKeepsUncataloguedBindingFallbackAndNoMatchState() {
        let binding = HotkeyBinding(id: "custom-binding", command: .focusNavigation(.previous), trigger: .unassigned)
        XCTAssertEqual(searchIDs(binding.command.displayName, bindings: [binding]), [binding.id])
        XCTAssertEqual(searchIDs(binding.command.layoutCompatibility.rawValue, bindings: [binding]), [binding.id])
        let groups = HotkeySettingsDisplayModel.search("zzzznotfound", bindings: HotkeyBindingRegistry.defaults())
        XCTAssertTrue(groups.isEmpty)
    }

    func testScriptSearchFindsTheDeclaredChordArgumentsAndCurrentLine() async throws {
        let loader = ConfigScriptLoader()
        let prefix = ["local wm = omniwm"]
        let increase = "+12%"
        let decrease = "-12%"
        let grow = "Control+Option+J"
        let shrink = "Control+Option+K"
        let command = "set-container-primary-span"
        let declarations = [
            "wm.keymap.set('\(grow)', wm.cmd('\(command)', '\(increase)'))",
            "wm.keymap.set('\(shrink)', wm.cmd('\(command)', '\(decrease)'))"
        ]
        func evaluate(_ lines: [String]) async throws -> [ConfigScriptBinding] {
            try await loader.evaluate(
                Data(lines.joined(separator: "\n").utf8),
                hyperMask: HyperKeyModifiers.default.carbonMask
            ).bindings
        }
        let rows = try await evaluate(prefix + declarations)
        let first = try XCTUnwrap(rows.first)
        let location = "init.luau:\(prefix.count + 1)"
        for term in [grow.uppercased(), increase, location] {
            XCTAssertEqual(HotkeySettingsDisplayModel.search(term, scriptBindings: rows), [first], term)
        }
        XCTAssertEqual(HotkeySettingsDisplayModel.search(command, scriptBindings: rows), rows)
        XCTAssertEqual(HotkeySettingsDisplayModel.search(" ", scriptBindings: rows), rows)
        XCTAssertTrue(HotkeySettingsDisplayModel.search(command, bindings: []).isEmpty)
        let shifted = try await evaluate(prefix + [""] + declarations)
        XCTAssertEqual(shifted.map(\.chord), rows.map(\.chord))
        XCTAssertTrue(HotkeySettingsDisplayModel.search(location, scriptBindings: shifted).isEmpty)
    }

    private func searchIDs(_ query: String, bindings: [HotkeyBinding]) -> [String] {
        HotkeySettingsDisplayModel.search(query, bindings: bindings)
            .flatMap(\.bindings).map(\.id)
    }
}
