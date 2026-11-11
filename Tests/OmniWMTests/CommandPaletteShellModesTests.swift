// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteShellModesTests: XCTestCase {
    func testMenuLoadingRowsPreserveParentPathsShortcutsAndFiltering() async throws {
        _ = NSApplication.shared
        let app = NSRunningApplication.current
        let element = AXUIElementCreateApplication(app.processIdentifier)
        let items = [
            MenuItemModel(
                title: "Build",
                fullPath: "Product > Build",
                keyboardShortcut: "⌘B",
                axElement: element,
                parentTitles: ["Product"]
            ),
            MenuItemModel(
                title: "Run",
                fullPath: "Product > Run",
                keyboardShortcut: "⌘R",
                axElement: element,
                parentTitles: ["Product"]
            )
        ]
        let fixture = CommandPaletteFocusFixture(initialMode: .menu) { environment in
            environment.frontmostApplication = { app }
            environment.runningApplication = { $0 == app.processIdentifier ? app : nil }
            environment.ownBundleIdentifier = { "org.example.palette-shell-mode-test" }
            environment.fetchMenuItems = { _ in items }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .menu)
        fixture.palette.expandResults()
        XCTAssertNotNil(fixture.palette.presentation.shell)
        XCTAssertEqual(snapshot(fixture).state, "loading")
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        let loaded = expectation(description: "The shell draws the fetched Menu rows")
        let previous = shell.onTree
        defer { shell.onTree = previous }
        shell.onTree = {
            previous?()
            guard shell.published?.rows.map(\.title) == items.map(\.title), shell.drawsPublishedList() else { return }
            shell.onTree = previous
            loaded.fulfill()
        }
        await fulfillment(of: [loaded], timeout: failureBound)
        let data = snapshot(fixture)
        XCTAssertEqual(data.rows.map(\.kind), Array(repeating: .menu, count: items.count))
        XCTAssertEqual(data.rows.map(\.subtitle), items.map { $0.parentTitles.joined(separator: " > ") })
        XCTAssertEqual(data.rows.flatMap(\.badges).map(\.text), items.compactMap(\.keyboardShortcut))
        fixture.palette.searchText = "Run"
        XCTAssertEqual(snapshot(fixture).rows.map(\.title), [items[1].title])
        fixture.palette.performShellCommand("activate menu-" + items[0].id.uuidString)
        XCTAssertTrue(fixture.palette.isVisible)
    }

    func testClipboardRowsAreWindowedAndCarrySymbolsPinAndIndependentActions() throws {
        let kinds: [ClipboardContentKind] = [.text, .richText, .html, .image, .fileURL, .other]
        let items = (0 ..< 200).map { index in
            clipboard("Entry \(index)", kind: kinds[index % kinds.count], pinned: index == 0)
        }
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.clipboardItems = { _ in items }
            environment.clipboardItemPreview = { _, _ in nil }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .clipboard)
        fixture.palette.expandResults()
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        try awaitPaletteTree(shell) { shell.drawsPublishedList() && shell.published?.total == items.count }
        let data = try XCTUnwrap(shell.published)
        XCTAssertEqual(data.total, items.count)
        XCTAssertLessThan(data.rows.count, items.count)
        XCTAssertGreaterThan(data.after, 0)
        let sources = Dictionary(uniqueKeysWithValues: items.map { ("clipboard-" + $0.id.uuidString, $0) })
        for row in data.rows {
            let item = try XCTUnwrap(sources[row.id])
            XCTAssertEqual(row.kind, .clipboard)
            XCTAssertEqual(row.icon.symbol, item.kind.paletteSymbol)
            XCTAssertEqual(row.pinned, item.isPinned)
            XCTAssertEqual(row.actions.map(\.id), ["paste " + row.id, "menu " + row.id])
        }
        fixture.palette.searchText = items.last?.title ?? ""
        let filtered = snapshot(fixture)
        XCTAssertEqual(filtered.rows.map(\.title), [try XCTUnwrap(items.last).title])
        XCTAssertEqual(filtered.total, 1)
    }

    func testClipboardDisabledStateEnablesHistoryThroughTheOwner() throws {
        let item = clipboard("Saved")
        var enabled = false
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.isClipboardHistoryEnabled = { _ in enabled }
            environment.setClipboardHistoryEnabled = { _, value in enabled = value }
            environment.clipboardItems = { _ in [item] }
            environment.clipboardItemPreview = { _, _ in nil }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .clipboard)
        let disabled = snapshot(fixture)
        XCTAssertEqual(disabled.state, "disabled")
        XCTAssertTrue(disabled.rows.isEmpty)
        XCTAssertNil(disabled.preview)
        XCTAssertTrue(disabled.actions.isEmpty)
        XCTAssertEqual(disabled.emptyAction?.id, "enable")
        fixture.palette.performShellCommand("enable")
        XCTAssertTrue(enabled)
        XCTAssertEqual(snapshot(fixture).rows.map(\.title), [item.title])
    }

    func testClipboardPreviewTracksLoadingTextAndUnavailableStates() throws {
        let item = clipboard("Selected")
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.clipboardItems = { _ in [item] }
            environment.clipboardItemPreview = { _, _ in nil }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .clipboard)
        fixture.palette.isClipboardPreviewLoading = true
        XCTAssertEqual(snapshot(fixture).preview?.state, "loading")
        fixture.palette.isClipboardPreviewLoading = false
        fixture.palette.clipboardPreview = .text("selected full preview")
        let text = snapshot(fixture)
        XCTAssertEqual(text.preview?.state, "text")
        XCTAssertEqual(text.preview?.text, "selected full preview")
        XCTAssertNil(text.preview?.image)
        fixture.palette.clipboardPreview = nil
        XCTAssertEqual(snapshot(fixture).preview?.state, "unavailable")
        fixture.palette.dismiss(reason: .cancel)
        let closed = snapshot(fixture)
        XCTAssertFalse(closed.open)
        XCTAssertTrue(closed.rows.isEmpty)
        XCTAssertNil(closed.preview)
    }

    func testClipboardImageBitmapBelongsToThePresenterAndRetiresOnClose() throws {
        let item = clipboard("Image", kind: .image)
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.clipboardItems = { _ in [item] }
            environment.clipboardItemPreview = { _, _ in nil }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show(mode: .clipboard)
        let image = try XCTUnwrap(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        fixture.palette.isClipboardPreviewLoading = false
        fixture.palette.clipboardPreview = .image(Data())
        fixture.palette.clipboardPreviewImage = NSImage(cgImage: image, size: .zero)
        let data = snapshot(fixture)
        XCTAssertEqual(data.preview?.state, "image")
        XCTAssertNil(data.preview?.text)
        XCTAssertEqual(data.preview?.width, Double(image.width))
        XCTAssertEqual(data.preview?.height, Double(image.height))
        let bitmap = try XCTUnwrap(data.preview?.image)
        let resources = try XCTUnwrap(fixture.controller.workspaceBarManager.commandPaletteResources)
        let registered = try XCTUnwrap(resources.bitmap(bitmap))
        XCTAssertEqual(registered.width, image.width)
        XCTAssertEqual(registered.height, image.height)
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        shell.close()
        XCTAssertNil(resources.bitmap(bitmap))
    }

    func testUnifiedRowsFlattenTheExistingOrderAndKeepShowAllActions() throws {
        let count = UnifiedSearch.topHitLimit + UnifiedSearch.groupRowLimit + 1
        let items = (0 ..< count).map { clipboard("Alpha \($0)") }
        let fixture = unifiedFixture(items: items)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        fixture.palette.searchText = "Alpha"
        let palette = fixture.palette
        let data = snapshot(fixture, whole: true)
        XCTAssertTrue(data.unified)
        XCTAssertNotNil(palette.presentation.shell)
        XCTAssertTrue(data.modes.isEmpty)
        XCTAssertTrue(data.actions.isEmpty)
        XCTAssertFalse(data.browseModes)
        XCTAssertNil(data.preview)
        XCTAssertEqual(data.placeholder, String(localized: "Search…"))
        XCTAssertEqual(data.rows.count, palette.unifiedResults.lines.count)
        XCTAssertEqual(Set(data.rows.map(\.id)).count, data.rows.count)
        let titles = Dictionary(uniqueKeysWithValues: items
            .map { (CommandPaletteSelectionID.clipboard($0.id), $0.title) })
        for (line, row) in zip(palette.unifiedResults.lines, data.rows) {
            switch line {
            case .topHitsHeading:
                XCTAssertEqual(row.title, String(localized: "Top Hits"))
                XCTAssertFalse(row.enabled)
            case let .groupHeading(mode):
                XCTAssertEqual(row.title, mode.localizedDisplayName)
                XCTAssertEqual(row.kind, .heading)
            case let .row(id):
                if case .showAll = id { XCTAssertEqual(row.kind, .showAll) }
                else { XCTAssertEqual(row.title, titles[id]) }
                if let index = palette.unifiedResults.topHits.firstIndex(of: id) {
                    XCTAssertTrue(row.badges
                        .contains { $0.text == CommandPalettePresentation.topHitShortcut(at: index) })
                }
            }
        }
        let showAll = try XCTUnwrap(data.rows.first { $0.kind == .showAll })
        palette.performShellCommand("activate " + showAll.id)
        XCTAssertFalse(palette.isUnifiedSearch)
        XCTAssertEqual(palette.selectedMode, .clipboard)
        XCTAssertEqual(palette.searchText, "Alpha")
    }

    func testUnifiedEmptyAndPendingStatesDoNotDrawModeSpecificChrome() throws {
        let fixture = unifiedFixture(items: [])
        defer { fixture.cleanup() }
        _ = try fixture.show()
        XCTAssertEqual(snapshot(fixture).state, "blank")
        fixture.palette.searchText = "missing"
        fixture.palette.isApplicationLoading = true
        XCTAssertEqual(snapshot(fixture).state, "loading")
        fixture.palette.isApplicationLoading = false
        let empty = snapshot(fixture)
        XCTAssertEqual(empty.state, "empty")
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertTrue(empty.actions.isEmpty)
        XCTAssertTrue(empty.modes.isEmpty)
        XCTAssertNil(empty.preview)
    }

    func testLauncherPaletteShowsFiltersAndSavedCommandsInTheShellTree() throws {
        var entry = LauncherEntry()
        entry.name = "Build Project"
        entry.command = "swift build"
        let finder = LauncherApplicationResult(
            bundleURL: URL(fileURLWithPath: ApplicationCatalogFilter.finderPath),
            bundleIdentifier: "com.apple.finder", displayName: "Finder"
        )
        let fixture = CommandPaletteFocusFixture(initialMode: .applications) { environment in
            environment.submitApplicationSearch = { _, _, _, generation, publish in
                publish(generation, [LauncherSection(id: .all, title: LauncherFilter.apps.title, items: [finder])], [])
            }
            environment.stopApplicationSearch = {}
        }
        defer { fixture.cleanup() }
        fixture.controller.settings.launcher.entries = [entry]
        _ = try fixture.show(mode: .applications)
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        let names = [entry.name, finder.displayName]
        try awaitPaletteTree(shell) {
            let rows = (shell.published?.rows ?? []).flatMap { $0.kind == .gridRow ? $0.cells : [$0] }
            return names.allSatisfy { name in rows.contains { $0.title == name } } && shell.drawsPublishedList()
        }
        let data = snapshot(fixture)
        let launcher = try XCTUnwrap(data.launcher)
        XCTAssertEqual(launcher.filters.map(\.id), LauncherFilter.allCases.map(\.rawValue))
        let text = try XCTUnwrap(shell.surface.text)
        let layout = shell.surface.layout
        let strings = layout.core.elements { _ in true }.map { text.string(layout.core.content(of: $0).text) }
        let add = try XCTUnwrap(launcher.add)
        for title in LauncherFilter.allCases.map(\.title) + names + [add.title] {
            XCTAssertTrue(strings.contains { $0.localizedCaseInsensitiveContains(title) }, title)
        }
        let actions = layout.core.elements { $0.action != 0 }.map { text.string(layout.core.content(of: $0).action) }
        XCTAssertTrue(actions.contains("palette menu " + CommandPaletteController.shellLauncherAddTarget))
    }

    private func snapshot(_ fixture: CommandPaletteFocusFixture, whole: Bool = false) -> ShellCommandPaletteData {
        let size = CGSize(
            width: CommandPalettePanel.width,
            height: whole ? CGFloat(fixture.palette.clipboardItems.count + HotkeyCategory.allCases.count)
                * CommandPalettePanel.expandedHeight : CommandPalettePanel.expandedHeight
        )
        return fixture.palette.shellData(size: size)
    }

    private func clipboard(
        _ title: String,
        kind: ClipboardContentKind = .text,
        pinned: Bool = false
    ) -> ClipboardPaletteItem {
        ClipboardPaletteItem(
            id: UUID(), title: title, subtitle: "Source", kind: kind, sourceBundleIdentifier: nil,
            lastCopiedAt: .distantPast, numberOfCopies: 1, byteCount: title.utf8.count,
            isPinned: pinned, searchText: title, canPastePlainText: kind != .image
        )
    }

    private func unifiedFixture(items: [ClipboardPaletteItem]) -> CommandPaletteFocusFixture {
        let fixture = CommandPaletteFocusFixture { environment in
            environment.clipboardItems = { _ in items }
            environment.clipboardItemPreview = { _, _ in nil }
            environment.submitApplicationSearch = { _, _, _, _, _ in }
            environment.submitFileSearch = { _, _, _, _, _ in }
            environment.stopApplicationSearch = {}
            environment.stopFileSearch = {}
        }
        fixture.controller.settings.commandPalette.unifiedSearch = true
        fixture.controller.settings.commandPalette.searchedModes = [.clipboard]
        return fixture
    }
}
