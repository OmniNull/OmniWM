// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import XCTest

@MainActor
extension CommandPaletteLauncherTests {
    private func application(_ name: String) -> LauncherApplicationResult {
        LauncherApplicationResult(
            bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
            bundleIdentifier: "org.example.\(name.filter(\.isLetter))",
            displayName: name,
            categoryName: "Utilities"
        )
    }

    private func wholeList(_ palette: CommandPaletteController) -> ShellCommandPaletteData {
        let rows = palette.currentSelectionList().count + 2 * (palette.applicationSections.count + 1)
        return palette.shellData(size: CGSize(
            width: CommandPalettePanel.width,
            height: CGFloat(rows) * CommandPalettePanel.expandedHeight
        ))
    }

    private func publishApplications(
        _ recorder: Recorder,
        _ palette: CommandPaletteController,
        _ sections: [LauncherSection<LauncherApplicationResult>],
        chips: [LauncherChip] = []
    ) throws {
        let submission = try XCTUnwrap(recorder.appSubmissions.last)
        submission.publish(palette.launcherRequestGeneration, sections, chips)
    }

    func testShellGridChunksSectionsByTheDrawnColumnCountAndArrowsFollowIt() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .applications, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        fixture.palette.performShellCommand("filter apps")
        XCTAssertEqual(fixture.palette.launcherFilter, .apps)
        let width = CommandPalettePanel.width
        let columns = CommandPaletteController.launcherColumnCount(for: .applications, width: width, style: .grid)
        let apps = (0 ..< 2 * columns + 1).map { application("App \($0)") }
        try publishApplications(recorder, fixture.palette, [
            LauncherSection(id: .suggestions, title: "Suggestions", items: [apps[0]]),
            LauncherSection(id: .all, title: "Applications", items: apps)
        ])
        let data = wholeList(fixture.palette)
        XCTAssertEqual(data.launcher?.grid, true)
        XCTAssertEqual(data.launcher?.columns, columns)
        XCTAssertEqual(fixture.palette.launcherColumnCount, columns)
        let grids = data.rows.filter { $0.kind == .gridRow }
        XCTAssertEqual(grids.map(\.cells.count), [1, columns, columns, 1])
        let cells = grids.flatMap(\.cells)
        XCTAssertEqual(Set(cells.map(\.id)).count, cells.count)
        XCTAssertEqual(cells.map(\.title), [apps[0].displayName] + apps.map(\.displayName))
        XCTAssertEqual(data.selected, grids[0].id)
        XCTAssertTrue(grids[0].selected && grids[0].cells[0].selected)

        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_DownArrow, ""), relevantModifiers: []))
        XCTAssertEqual(fixture.palette.selectedItemID, fixture.palette.shellSelection(for: grids[1].cells[0].id))
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_DownArrow, ""), relevantModifiers: []))
        XCTAssertEqual(fixture.palette.selectedItemID, fixture.palette.shellSelection(for: grids[2].cells[0].id))
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_RightArrow, ""), relevantModifiers: []))
        XCTAssertEqual(fixture.palette.selectedItemID, fixture.palette.shellSelection(for: grids[2].cells[1].id))
        XCTAssertEqual(wholeList(fixture.palette).selected, grids[2].id)
    }

    func testShellCellActivationWaitsForTheCurrentGenerationAndUsesThePublishedIndex() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .applications, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        fixture.palette.performShellCommand("filter apps")
        let apps = [application("Calculator"), application("Chess")]
        try publishApplications(recorder, fixture.palette, [LauncherSection(id: .results, title: "", items: apps)])
        let cell = try XCTUnwrap(wholeList(fixture.palette).rows.first?.cells.last)
        XCTAssertEqual(fixture.palette.shellSelection(for: cell.id), .application(.results, apps[1].id))

        fixture.palette.searchText = "c"
        fixture.palette.performShellCommand("activate " + cell.id)
        XCTAssertTrue(recorder.openedApplications.isEmpty)
        XCTAssertTrue(fixture.palette.isVisible)

        try publishApplications(recorder, fixture.palette, [LauncherSection(id: .results, title: "", items: apps)])
        fixture.palette.performShellCommand("activate " + cell.id)
        XCTAssertEqual(recorder.openedApplications, [apps[1].bundleURL])
        XCTAssertFalse(fixture.palette.isVisible)
    }

    func testShellToolbarVerbsAndMenusDriveTheLauncherOwners() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .applications, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let all = try XCTUnwrap(wholeList(fixture.palette).launcher)
        XCTAssertEqual(all.filters.map(\.id), LauncherFilter.allCases.map(\.rawValue))
        XCTAssertEqual(all.filters.filter(\.selected).map(\.id), [LauncherFilter.all.rawValue])
        XCTAssertEqual(all.add?.id, CommandPaletteController.shellLauncherAddTarget)
        XCTAssertTrue(all.views.isEmpty)
        XCTAssertFalse(all.grid)
        XCTAssertEqual(
            fixture.palette.shellMenuItems(for: CommandPaletteController.shellLauncherAddTarget),
            CommandPaletteNativeMenu.launcherAdd
        )

        fixture.palette.performShellCommand("filter apps")
        let chip = LauncherChip(id: "games", title: "Games", filter: .applicationCategory("games"))
        try publishApplications(
            recorder, fixture.palette,
            [LauncherSection(id: .all, title: "", items: [application("Chess")])],
            chips: [chip]
        )
        let apps = try XCTUnwrap(wholeList(fixture.palette).launcher)
        XCTAssertEqual(apps.views.map(\.id), [LauncherViewStyle.grid.rawValue, LauncherViewStyle.list.rawValue])
        XCTAssertEqual(apps.chips.map(\.id), [chip.id])
        let submissions = recorder.appSubmissions.count
        fixture.palette.performShellCommand("chip " + chip.id)
        XCTAssertEqual(fixture.palette.selectedApplicationChip, chip)
        XCTAssertEqual(recorder.appSubmissions.count, submissions + 1)
        XCTAssertEqual(wholeList(fixture.palette).launcher?.chips.filter(\.selected).map(\.id), [chip.id])

        fixture.palette.performShellCommand("view list")
        XCTAssertEqual(fixture.palette.applicationViewStyle, .list)
        XCTAssertEqual(fixture.controller.settings.commandPaletteApplicationsViewStyle, .list)
        XCTAssertEqual(wholeList(fixture.palette).launcher?.grid, false)

        fixture.palette.performShellCommand("filter saved")
        XCTAssertEqual(fixture.palette.launcherFilter, .saved)
        XCTAssertTrue(try XCTUnwrap(wholeList(fixture.palette).launcher).views.isEmpty)
    }

    func testShellLauncherRowsOfferTheirKindsMenusAndSavedRowsSelectOnHover() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .applications, recorder: recorder)
        defer { fixture.cleanup() }
        var entry = LauncherEntry()
        entry.name = "Deploy"
        entry.command = "true"
        fixture.controller.settings.launcher.entries = [entry]
        _ = try fixture.show()
        let app = application("Calculator")
        try publishApplications(recorder, fixture.palette, [
            LauncherSection(id: .suggestions, title: "Suggestions", items: [app])
        ])
        let rows = wholeList(fixture.palette).rows
        XCTAssertEqual(rows.map(\.kind), [.heading, .saved, .heading, .application])
        let saved = rows[1]
        let suggested = rows[3]
        XCTAssertEqual(saved.badges.map(\.text), [entry.terminal.title])
        let savedSelection = LauncherSelection(sectionID: .saved, itemID: entry.id.uuidString)
        let appSelection = LauncherSelection(sectionID: .suggestions, itemID: app.id)
        XCTAssertEqual(fixture.palette.shellMenuItems(for: saved.id), CommandPaletteNativeMenu.saved(savedSelection))
        XCTAssertEqual(
            fixture.palette.shellMenuItems(for: suggested.id),
            CommandPaletteNativeMenu.launcher(appSelection, quickLook: false, suggestion: app.displayName)
        )

        fixture.palette.selectLauncherItem(appSelection, activate: false)
        fixture.palette.performShellCommand("highlight " + suggested.id)
        XCTAssertEqual(fixture.palette.selectedItemID, .application(.suggestions, app.id))
        fixture.palette.performShellCommand("highlight " + saved.id)
        XCTAssertEqual(fixture.palette.selectedItemID, .launcherEntry(entry.id))
        XCTAssertTrue(fixture.palette.launcherResultsFocused)

        XCTAssertTrue(fixture.palette.performShellMenuAction(.launcher(appSelection, .reveal), target: suggested.id))
        XCTAssertEqual(recorder.revealed, [app.bundleURL])
    }

    func testShellFilesShowPathsWhileCommandIsHeldAndRequestThumbnailsAtTheDrawnSize() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .files, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let file = LauncherFileResult(
            fileURL: URL(fileURLWithPath: "/tmp/notes.txt"),
            displayName: "notes",
            kind: "Text"
        )
        let submission = try XCTUnwrap(recorder.fileSubmissions.last)
        submission.publish(
            fixture.palette.launcherRequestGeneration,
            [LauncherSection(id: .results, title: "", items: [file])]
        )
        fixture.palette.performShellCommand("view grid")
        let grid = wholeList(fixture.palette)
        XCTAssertEqual(grid.rows.map(\.kind), [.gridRow])
        XCTAssertEqual(
            fixture.palette.shellFileIconRequests.map(\.points),
            [CommandPaletteController.shellGridIconPoints]
        )

        fixture.palette.performShellCommand("view list")
        XCTAssertEqual(wholeList(fixture.palette).rows.map(\.subtitle), [file.kind])
        XCTAssertEqual(fixture.palette.shellFileIconRequests.map(\.points), [CommandPaletteController.shellIconPoints])
        fixture.palette.syncLauncherPaths(.command)
        XCTAssertEqual(wholeList(fixture.palette).rows.map(\.subtitle), [file.fileURL.path])
        fixture.palette.syncLauncherPaths([])
        XCTAssertEqual(wholeList(fixture.palette).rows.map(\.subtitle), [file.kind])
    }

    func testShellRejectsADrawnGridWhoseCellsNoLongerMatchThePublishedRow() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .files, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        fixture.palette.performShellCommand("view grid")
        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
        let publish = { (names: [String]) in
            let submission = try XCTUnwrap(recorder.fileSubmissions.last)
            submission.publish(fixture.palette.launcherRequestGeneration, self.fileSection(names))
        }
        let grid = { shell.published?.rows.first { $0.kind == .gridRow } }
        try publish(["a.txt", "b.txt"])
        try awaitPaletteTree(shell) {
            grid()?.cells.map(\.title) == ["a.txt", "b.txt"] && shell.drawsPublishedList()
        }
        let row = try XCTUnwrap(grid()?.id)

        fixture.palette.searchText = "a"
        try publish(["a.txt", "c.txt"])
        fixture.palette.publishShellData()
        XCTAssertEqual(grid()?.id, row)
        XCTAssertEqual(grid()?.cells.map(\.title), ["a.txt", "c.txt"])
        XCTAssertFalse(shell.drawsPublishedList())
        try awaitPaletteTree(shell) { shell.drawsPublishedList() }
    }

    func testShellFilesPreviewPaneShowsTheSelectedFilesPictureAndDetails() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .files, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let modified = Date(timeIntervalSince1970: 0)
        let file = LauncherFileResult(
            fileURL: URL(fileURLWithPath: "/tmp/report.pdf"), displayName: "report", kind: "PDF document",
            size: 2048, modifiedAt: modified
        )
        let submission = try XCTUnwrap(recorder.fileSubmissions.last)
        submission.publish(
            fixture.palette.launcherRequestGeneration,
            [LauncherSection(id: .results, title: "", items: [file])]
        )
        XCTAssertNil(wholeList(fixture.palette).preview)

        let commandY = try key(kVK_ANSI_Y, "y", .command)
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(commandY, relevantModifiers: .command))
        let data = wholeList(fixture.palette)
        let preview = try XCTUnwrap(data.preview)
        XCTAssertEqual(preview.state, "file")
        XCTAssertEqual(preview.title, file.displayName)
        XCTAssertEqual(preview.details.map(\.label), [
            String(localized: "Kind"), String(localized: "Size"), String(localized: "Modified")
        ])
        XCTAssertEqual(preview.details.map(\.value), [
            "PDF document",
            ByteCountFormatter.string(fromByteCount: 2048, countStyle: .file),
            modified.formatted(date: .abbreviated, time: .shortened)
        ])
        let listWidth = (CommandPalettePanel.width * CommandPaletteController.shellPreviewSplit).rounded(.down)
        XCTAssertEqual(
            data.launcher?.columns,
            CommandPaletteController.launcherColumnCount(
                for: .files,
                width: listWidth,
                style: fixture.palette.fileViewStyle
            )
        )

        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_Escape, "\u{1b}"), relevantModifiers: []))
        XCTAssertFalse(fixture.palette.isLauncherPreviewVisible)
        XCTAssertNil(wholeList(fixture.palette).preview)
        XCTAssertTrue(fixture.palette.isVisible)
    }

    func testSpaceOpensQuickLookWithoutDismissingThePaletteAndCloseEndsIt() throws {
        let recorder = Recorder()
        var opened: [[URL]] = []
        var cancels = 0
        var finish: ShellDesktopPlatform.PresentationCompletion?
        var source: ShellDesktopSource?
        let fixture = CommandPaletteFocusFixture(initialMode: .files) { environment in
            environment.submitFileSearch = { _, query, _, _, publish in
                recorder.fileSubmissions.append((query, publish))
            }
            environment.stopFileSearch = {}
            environment.quickLook = { urls, presentationSource, completion in
                opened.append(urls)
                source = presentationSource
                finish = completion
                return ShellDesktopPlatform.Presentation(start: {}, cancel: {
                    cancels += 1
                    completion("cancelled")
                })
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let file = LauncherFileResult(fileURL: URL(fileURLWithPath: "/tmp/photo.png"), displayName: "photo")
        let submission = try XCTUnwrap(recorder.fileSubmissions.last)
        submission.publish(
            fixture.palette.launcherRequestGeneration,
            [LauncherSection(id: .results, title: "", items: [file])]
        )
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_DownArrow, ""), relevantModifiers: []))
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_Space, " "), relevantModifiers: []))
        XCTAssertEqual(opened, [[file.fileURL]])
        XCTAssertFalse(fixture.palette.isLauncherPreviewVisible)
        XCTAssertEqual(source?.isCurrent(), true)

        fixture.palette.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_Escape, "\u{1b}"), relevantModifiers: []))
        XCTAssertEqual(cancels, 1)
        XCTAssertNil(fixture.palette.launcherQuickLook)
        XCTAssertTrue(fixture.palette.isVisible)

        let selection = LauncherSelection(sectionID: .results, itemID: file.id)
        let row = try XCTUnwrap(wholeList(fixture.palette).rows.first?.cells.first)
        XCTAssertTrue(fixture.palette.performShellMenuAction(.launcher(selection, .quickLook), target: row.id))
        XCTAssertEqual(opened.count, 2)
        finish?(nil)
        XCTAssertNil(fixture.palette.launcherQuickLook)
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_Space, " "), relevantModifiers: []))
        XCTAssertEqual(opened.count, 3)

        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertEqual(cancels, 2)
        XCTAssertNil(fixture.palette.launcherQuickLook)
        XCTAssertEqual(source?.isCurrent(), false)
        XCTAssertThrowsError(try source?.beginFocus(nil))
    }

    func testLeavingFilesClosesQuickLookSoFocusLossDismissesThePaletteAgain() throws {
        let recorder = Recorder()
        var cancels = 0
        var source: ShellDesktopSource?
        let fixture = CommandPaletteFocusFixture(initialMode: .files) { environment in
            environment.submitFileSearch = { _, query, _, _, publish in
                recorder.fileSubmissions.append((query, publish))
            }
            environment.stopFileSearch = {}
            environment.submitApplicationSearch = { _, _, _, _, _ in }
            environment.stopApplicationSearch = {}
            environment.quickLook = { _, presentationSource, completion in
                source = presentationSource
                return ShellDesktopPlatform.Presentation(start: {}, cancel: {
                    cancels += 1
                    completion("cancelled")
                })
            }
        }
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let file = LauncherFileResult(fileURL: URL(fileURLWithPath: "/tmp/photo.png"), displayName: "photo")
        let submission = try XCTUnwrap(recorder.fileSubmissions.last)
        submission.publish(
            fixture.palette.launcherRequestGeneration,
            [LauncherSection(id: .results, title: "", items: [file])]
        )
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_DownArrow, ""), relevantModifiers: []))
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_Space, " "), relevantModifiers: []))
        XCTAssertNotNil(fixture.palette.launcherQuickLook)

        fixture.palette.selectMode(.applications)
        XCTAssertEqual(cancels, 1)
        XCTAssertNil(fixture.palette.launcherQuickLook)
        XCTAssertEqual(source?.isCurrent(), false)
        fixture.palette.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(fixture.palette.isVisible)
    }

    func testShellFileRowsKeepTheirCachedTextAcrossSearchesUntilTheirMetadataChanges() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .files, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        fixture.palette.performShellCommand("view list")
        let url = URL(fileURLWithPath: "/tmp/notes.txt")
        let publish = { (kind: String) in
            let submission = try XCTUnwrap(recorder.fileSubmissions.last)
            submission.publish(fixture.palette.launcherRequestGeneration, [LauncherSection(
                id: .results, title: "", items: [LauncherFileResult(fileURL: url, displayName: "notes", kind: kind)]
            )])
        }
        let selection = CommandPaletteSelectionID.file(.results, url.path)
        try publish("Plain Text")
        XCTAssertEqual(wholeList(fixture.palette).rows.map(\.subtitle), ["Plain Text"])

        fixture.palette.searchText = "n"
        try publish("Plain Text")
        XCTAssertNotNil(fixture.palette.shellLauncherRowCache[selection])
        XCTAssertEqual(wholeList(fixture.palette).rows.map(\.subtitle), ["Plain Text"])

        fixture.palette.searchText = "no"
        try publish("Markdown")
        XCTAssertEqual(wholeList(fixture.palette).rows.map(\.subtitle), ["Markdown"])
    }
}
