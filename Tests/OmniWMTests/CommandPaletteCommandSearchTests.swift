// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteCommandSearchTests: XCTestCase {
    func testBuildIncludesAllCatalogActionsAndUsesCurrentShortcutBindings() throws {
        let controller = makeController()
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey))
        controller.settings.updateBinding(for: "openCommandPalette", newBinding: binding)

        let items = CommandPaletteSearch.buildCommandItems(from: controller)
        XCTAssertEqual(Set(items.map(\.id)), Set(ActionCatalog.allSpecs().map(\.id)))
        XCTAssertEqual(items.count, ActionCatalog.allSpecs().count)

        let configured = try XCTUnwrap(items.first { $0.id == "openCommandPalette" })
        XCTAssertEqual(configured.shortcut, binding.displayString)
        XCTAssertTrue(configured.shortcutSearchTerms.contains(
            ActionCatalog.normalizedSearchTerm(binding.displayString)
        ))
        XCTAssertTrue(configured.shortcutSearchTerms.contains(
            ActionCatalog.normalizedSearchTerm(binding.humanReadableString)
        ))

        XCTAssertEqual(items.first { $0.id == "rescueOffscreenWindows" }?.shortcut, "Unassigned")
        XCTAssertEqual(items.first { $0.id == "consumeOrExpelWindowLeft" }?.shortcut, "No shortcut")
        XCTAssertFalse(try XCTUnwrap(items.first { $0.id == "rescueOffscreenWindows" }).hasShortcut)
        XCTAssertFalse(try XCTUnwrap(items.first { $0.id == "consumeOrExpelWindowLeft" }).hasShortcut)
        XCTAssertTrue(configured.hasShortcut)
        XCTAssertTrue(configured.isLayoutCompatible)
        XCTAssertFalse(try XCTUnwrap(items.first { $0.id == "moveColumn.up" }).isLayoutCompatible)
    }

    func testEmptyQueryReturnsCategoryAndTitleOrder() {
        let items = CommandPaletteSearch.buildCommandItems(from: makeController())
        let reversed = Array(items.reversed())

        XCTAssertEqual(CommandPaletteSearch.filterCommandItems(reversed, query: "  ").map(\.id), items.map(\.id))
    }

    func testSearchFindsCatalogMetadataCategoryLayoutAndConfiguredShortcut() {
        let controller = makeController()
        let binding = KeyBinding(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey))
        controller.settings.updateBinding(for: "openCommandPalette", newBinding: binding)
        let items = CommandPaletteSearch.buildCommandItems(from: controller)

        XCTAssertTrue(CommandPaletteSearch.filterCommandItems(items, query: "adjacent monitor")
            .contains { $0.id == "moveWindowToMonitor.left" })
        XCTAssertTrue(CommandPaletteSearch.filterCommandItems(items, query: "container and column")
            .contains { $0.id == "moveColumnToFirst" })
        XCTAssertTrue(CommandPaletteSearch.filterCommandItems(items, query: "dwindle")
            .contains { $0.id == "moveColumn.up" })
        XCTAssertTrue(CommandPaletteSearch.filterCommandItems(items, query: binding.humanReadableString)
            .contains { $0.id == "openCommandPalette" })
        XCTAssertTrue(CommandPaletteSearch.filterCommandItems(items, query: "not-a-real-command-phrase").isEmpty)
    }

    func testSearchRanksTitlePrefixThenSubstringThenMetadataThenShortcut() {
        let items = [
            item(id: "shortcut", title: "Beta", shortcutSearchTerms: ["focus"]),
            item(id: "keyword", title: "Alpha", keywords: ["focus"]),
            item(id: "substring", title: "Move Focus"),
            item(id: "prefix", title: "Focus Alpha")
        ]

        XCTAssertEqual(
            CommandPaletteSearch.filterCommandItems(items, query: "FOCUS").map(\.id),
            ["prefix", "substring", "keyword", "shortcut"]
        )
    }

    func testSearchMatchesLocalizedTitleAndCanonicalEnglishTitle() {
        let translated = item(id: "translated", title: "Focus Left", localizedTitle: "Фокус налево")

        XCTAssertEqual(CommandPaletteSearch.filterCommandItems([translated], query: "фокус").map(\.id), ["translated"])
        XCTAssertEqual(CommandPaletteSearch.filterCommandItems([translated], query: "focus").map(\.id), ["translated"])
    }

    private func item(
        id: String,
        title: String,
        localizedTitle: String? = nil,
        keywords: [String] = [],
        shortcutSearchTerms: [String] = []
    ) -> CommandPaletteCommandItem {
        CommandPaletteCommandItem(
            spec: ActionSpec(
                id: id,
                command: .openCommandPalette,
                title: title,
                localizedTitle: localizedTitle ?? title,
                keywords: keywords,
                category: .workspace,
                visibility: .normal,
                layoutCompatibility: .shared,
                defaultBinding: .unassigned,
                ipcCommandName: nil
            ),
            shortcut: "Unassigned",
            hasShortcut: false,
            shortcutSearchTerms: shortcutSearchTerms,
            isLayoutCompatible: true
        )
    }

    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OmniWMCommandSearchTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return WMController(
            settings: settings,
            windowFocusOperations: WindowFocusOperations(
                activateApp: { _ in },
                focusSpecificWindow: { _, _, _ in },
                raiseWindow: { _ in }
            )
        )
    }
}
