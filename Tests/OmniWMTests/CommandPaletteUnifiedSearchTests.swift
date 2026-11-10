// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteUnifiedSearchTests: XCTestCase {
    private struct FileSubmission {
        let query: String
        let generation: Int
        let publish: @MainActor (Int, [LauncherSection<LauncherFileResult>]) -> Void
    }

    private struct AppSubmission {
        let query: String
        let generation: Int
        let publish: @MainActor (Int, [LauncherSection<LauncherApplicationResult>], [LauncherChip]) -> Void
    }

    private final class Recorder {
        var fileSubmissions: [FileSubmission] = []
        var appSubmissions: [AppSubmission] = []
        var openedFiles: [URL] = []
        var openedApplications: [URL] = []
        var copiedClipboardItems: [UUID] = []
        var onClipboardCopied: (() -> Void)?
    }

    func testPlainOpenShowsUnifiedSearchWhilePerModeOpenStaysSingle() throws {
        let (fixture, _) = makeFixture()
        defer { fixture.cleanup() }

        _ = try fixture.show()
        XCTAssertTrue(fixture.palette.isUnifiedSearch)

        fixture.palette.toggle(wmController: fixture.controller, mode: .files)
        XCTAssertFalse(fixture.palette.isUnifiedSearch)
        XCTAssertEqual(fixture.palette.selectedMode, .files)

        fixture.palette.dismiss(reason: .cancel)
        _ = try fixture.show(mode: .clipboard)
        XCTAssertFalse(fixture.palette.isUnifiedSearch)
        XCTAssertEqual(fixture.palette.selectedMode, .clipboard)

        fixture.controller.settings.commandPalette.unifiedSearch = false
        fixture.palette.dismiss(reason: .cancel)
        _ = try fixture.show()
        XCTAssertFalse(fixture.palette.isUnifiedSearch)
        XCTAssertEqual(fixture.palette.selectedMode, .clipboard)
    }

    func testEmptyQueryListsWindowsOnlyWhenWindowsIsSearched() throws {
        let (fixture, _) = makeFixture()
        defer { fixture.cleanup() }
        let tokens = try addWindows(to: fixture.controller, count: 2)

        _ = try fixture.show()
        XCTAssertEqual(Set(fixture.palette.currentSelectionList()), Set(tokens.map { .window($0) }))
        XCTAssertFalse(fixture.palette.isExpanded)

        fixture.palette.dismiss(reason: .cancel)
        fixture.controller.settings.commandPalette.searchedModes = [.files, .commands]
        _ = try fixture.show()
        XCTAssertEqual(fixture.palette.currentSelectionList(), [])
        XCTAssertFalse(fixture.palette.isExpanded)
    }

    func testEnterRunsTheSelectedRowsOwnActionAndTeachesTopHits() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        publishFiles(recorder, ["Report.pdf"])
        publishApplications(recorder, [("Reporter", "com.example.Reporter")])
        XCTAssertEqual(
            fixture.palette.unifiedResults.topHits.first,
            .application(.results, "/Applications/Reporter.app")
        )

        fixture.palette.highlightUnifiedRow(.file(.results, "/tmp/Report.pdf"))
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Return)))

        XCTAssertEqual(recorder.openedFiles, [URL(fileURLWithPath: "/tmp/Report.pdf")])
        XCTAssertTrue(recorder.openedApplications.isEmpty)
        XCTAssertFalse(fixture.palette.isVisible)

        _ = try fixture.show()
        fixture.palette.searchText = "re"
        publishFiles(recorder, ["Report.pdf"])
        publishApplications(recorder, [("Reporter", "com.example.Reporter")])
        XCTAssertEqual(fixture.palette.unifiedResults.topHits.first, .file(.results, "/tmp/Report.pdf"))
        XCTAssertEqual(fixture.palette.selectedItemID, .file(.results, "/tmp/Report.pdf"))
    }

    func testClipboardPicksAreNeverRemembered() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.clipboard])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "alp"
        let selected = try XCTUnwrap(fixture.palette.selectedItemID)
        guard case .clipboard = selected else { return XCTFail("Expected a clipboard row, got \(selected)") }
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Return)))

        XCTAssertFalse(fixture.palette.isVisible)
        let copied = expectation(description: "Clipboard item copied")
        if recorder.copiedClipboardItems.isEmpty {
            recorder.onClipboardCopied = { copied.fulfill() }
        } else {
            copied.fulfill()
        }
        wait(for: [copied], timeout: failureBound)
        XCTAssertEqual(fixture.controller.settings.unifiedSearchLearnedPicks(for: "a"), [])
    }

    func testShowAllRowOpensThatPaletteModeWithTheSameQuery() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        let shownFiles = UnifiedSearch.topHitLimit + UnifiedSearch.groupRowLimit
        publishFiles(recorder, (1 ... shownFiles + 1).map { "Report \($0).pdf" })
        XCTAssertEqual(fixture.palette.currentSelectionList().last, .showAll(.files))

        fixture.palette.highlightUnifiedRow(.showAll(.files))
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Return)))

        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertFalse(fixture.palette.isUnifiedSearch)
        XCTAssertEqual(fixture.palette.selectedMode, .files)
        XCTAssertEqual(fixture.palette.searchText, "rep")
        XCTAssertEqual(recorder.fileSubmissions.last?.query, "rep")
        XCTAssertEqual(fixture.controller.settings.unifiedSearchLearnedPicks(for: "rep"), [])
    }

    func testCommandDigitsOpenTheMatchingTopHit() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        publishFiles(recorder, ["Report 1.pdf", "Report 2.pdf", "Report 3.pdf", "Report 4.pdf"])
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_ANSI_4, modifiers: .command)))
        XCTAssertTrue(recorder.openedFiles.isEmpty)
        XCTAssertTrue(fixture.palette.isUnifiedSearch)

        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_ANSI_2, modifiers: .command)))
        XCTAssertEqual(recorder.openedFiles, [URL(fileURLWithPath: "/tmp/Report 2.pdf")])
        XCTAssertFalse(fixture.palette.isVisible)
    }

    func testTabJumpsBetweenTopHitsAndGroups() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        let topHitLimit = UnifiedSearch.topHitLimit
        publishApplications(recorder, (1 ... topHitLimit + 1).map { ("Reporter \($0)", "com.example.r\($0)") })
        publishFiles(recorder, ["Report.pdf", "Reply.txt"])
        let sections = fixture.palette.unifiedResults.sections
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(fixture.palette.selectedItemID, sections[0].first)

        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Tab)))
        XCTAssertEqual(fixture.palette.selectedItemID, sections[1].first)
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Tab)))
        XCTAssertEqual(fixture.palette.selectedItemID, sections[2].first)
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Tab, modifiers: .shift)))
        XCTAssertEqual(fixture.palette.selectedItemID, sections[1].first)
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_DownArrow)))
        XCTAssertEqual(fixture.palette.selectedItemID, sections[2].first)
    }

    func testLateResultsKeepTheSelectedRow() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        publishFiles(recorder, ["Report.pdf", "Reply.txt"])
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_DownArrow)))
        let selected = fixture.palette.selectedItemID
        XCTAssertEqual(selected, .file(.results, "/tmp/Reply.txt"))

        publishApplications(recorder, [("Reporter", "com.example.Reporter")])
        XCTAssertEqual(
            fixture.palette.unifiedResults.topHits.first,
            .application(.results, "/Applications/Reporter.app")
        )
        XCTAssertEqual(fixture.palette.selectedItemID, selected)
    }

    func testLateResultsKeepASelectedRowBeyondItsGroupsUsualRows() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        let topHitLimit = UnifiedSearch.topHitLimit
        let shownFiles = topHitLimit + UnifiedSearch.groupRowLimit
        publishFiles(recorder, (1 ... shownFiles).map { "Report \($0).pdf" })
        let selected = CommandPaletteSelectionID.file(.results, "/tmp/Report \(shownFiles).pdf")
        fixture.palette.highlightUnifiedRow(selected)

        publishApplications(recorder, (1 ... topHitLimit).map { ("Reporter \($0)", "com.example.r\($0)") })
        XCTAssertEqual(fixture.palette.selectedItemID, selected)
        XCTAssertTrue(fixture.palette.currentSelectionList().contains(selected))
    }

    func testLateResultsMoveTheHighlightUntilTheUserMovesIt() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        publishFiles(recorder, ["Report.pdf", "Reply.txt"])
        XCTAssertEqual(fixture.palette.selectedItemID, .file(.results, "/tmp/Report.pdf"))

        publishApplications(recorder, [("Reporter", "com.example.Reporter")])
        XCTAssertEqual(fixture.palette.selectedItemID, .application(.results, "/Applications/Reporter.app"))
    }

    func testEnterBeforeLateResultsActsOnTheFirstRowOnceTheyArrive() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        publishFiles(recorder, ["Report.pdf"])
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Return)))
        XCTAssertTrue(recorder.openedFiles.isEmpty)
        XCTAssertTrue(fixture.palette.isVisible)

        publishApplications(recorder, [("Reporter", "com.example.Reporter")])
        XCTAssertEqual(recorder.openedApplications, [URL(fileURLWithPath: "/Applications/Reporter.app")])
        XCTAssertTrue(recorder.openedFiles.isEmpty)
        XCTAssertFalse(fixture.palette.isVisible)
    }

    func testMovingTheHighlightCancelsAWaitingTopHit() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        publishFiles(recorder, ["Report.pdf", "Reply.txt"])
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_ANSI_2, modifiers: .command)))
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_DownArrow)))

        publishApplications(recorder, [("Reporter", "com.example.Reporter")])
        XCTAssertTrue(recorder.openedFiles.isEmpty)
        XCTAssertTrue(recorder.openedApplications.isEmpty)
        XCTAssertTrue(fixture.palette.isVisible)
        XCTAssertEqual(fixture.palette.selectedItemID, .file(.results, "/tmp/Reply.txt"))
    }

    func testHighlightReturnsToTheFirstRowWhenTheChosenRowDisappears() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let replay = CommandPaletteSelectionID.application(.results, "/Applications/Replay.app")

        fixture.palette.searchText = "rep"
        publishApplications(recorder, [("Reporter", "com.example.Reporter"), ("Replay", "com.example.Replay")])
        publishFiles(recorder, ["Report.pdf"])
        fixture.palette.searchText = "repl"
        XCTAssertEqual(fixture.palette.selectedItemID, replay)
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_DownArrow)))
        XCTAssertEqual(fixture.palette.selectedItemID, .application(.results, "/Applications/Reporter.app"))

        publishApplications(recorder, [("Replay", "com.example.Replay")])
        XCTAssertEqual(fixture.palette.selectedItemID, replay)
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Return)))
        XCTAssertTrue(recorder.openedApplications.isEmpty)

        publishFiles(recorder, ["Replica.txt"])
        XCTAssertEqual(recorder.openedApplications, [URL(fileURLWithPath: "/Applications/Replay.app")])
        XCTAssertTrue(recorder.openedFiles.isEmpty)
    }

    func testEnterWaitsWhenTheChosenRowDisappearsAndNothingIsLeft() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        publishApplications(recorder, [])
        publishFiles(recorder, ["Report.pdf"])
        fixture.palette.searchText = "repl"
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_DownArrow)))
        XCTAssertEqual(fixture.palette.selectedItemID, .file(.results, "/tmp/Report.pdf"))

        publishFiles(recorder, [])
        XCTAssertNil(fixture.palette.selectedItemID)
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Return)))

        publishApplications(recorder, [("Replay", "com.example.Replay")])
        XCTAssertEqual(recorder.openedApplications, [URL(fileURLWithPath: "/Applications/Replay.app")])
    }

    func testEnterAfterMovingTheHighlightDoesNotWaitForLateResults() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications, .files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        fixture.palette.searchText = "rep"
        publishFiles(recorder, ["Report.pdf", "Reply.txt"])
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_DownArrow)))
        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Return)))

        XCTAssertEqual(recorder.openedFiles, [URL(fileURLWithPath: "/tmp/Reply.txt")])
        XCTAssertFalse(fixture.palette.isVisible)
    }

    func testAppRowsStayUntilTheNextAppSearchAnswers() throws {
        let (fixture, recorder) = makeFixture(searchedModes: [.applications])
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let reporter = CommandPaletteSelectionID.application(.results, "/Applications/Reporter.app")

        fixture.palette.searchText = "rep"
        publishApplications(recorder, [("Reporter", "com.example.Reporter")])
        fixture.palette.searchText = "repl"
        XCTAssertEqual(fixture.palette.unifiedSelectionList, [reporter])
        XCTAssertFalse(fixture.palette.isUnifiedSearchLoading)

        publishApplications(recorder, [("Replay", "com.example.Replay")])
        XCTAssertEqual(fixture.palette.unifiedSelectionList, [.application(.results, "/Applications/Replay.app")])
    }

    func testEnterBeforeTypingStaysCollapsedWhenWindowsIsNotSearched() throws {
        let (fixture, _) = makeFixture(searchedModes: [.files])
        defer { fixture.cleanup() }
        _ = try fixture.show()

        XCTAssertTrue(fixture.palette.handleKeyDown(key(kVK_Return)))
        XCTAssertFalse(fixture.palette.isExpanded)
    }

    private func makeFixture(
        searchedModes: [CommandPaletteMode] = SettingsExport.CommandPalette.defaultSearchedModes
    ) -> (CommandPaletteFocusFixture, Recorder) {
        let recorder = Recorder()
        let fixture = CommandPaletteFocusFixture { environment in
            environment.submitFileSearch = { _, query, _, generation, publish in
                recorder.fileSubmissions.append(FileSubmission(query: query, generation: generation, publish: publish))
            }
            environment.submitApplicationSearch = { _, query, _, generation, publish in
                recorder.appSubmissions.append(AppSubmission(query: query, generation: generation, publish: publish))
            }
            environment.stopFileSearch = {}
            environment.stopApplicationSearch = {}
            environment.runningApplicationForResult = { _ in nil }
            environment.openFile = { url, completion in
                recorder.openedFiles.append(url)
                MainActor.assumeIsolated { completion(nil) }
            }
            environment.openApplication = { url, completion in
                recorder.openedApplications.append(url)
                MainActor.assumeIsolated { completion(nil) }
            }
            environment.copyClipboardItem = { _, id in
                await MainActor.run {
                    recorder.copiedClipboardItems.append(id)
                    recorder.onClipboardCopied?()
                }
                return true
            }
        }
        fixture.controller.settings.commandPalette.unifiedSearch = true
        fixture.controller.settings.commandPalette.searchedModes = searchedModes
        return (fixture, recorder)
    }

    private func publishFiles(_ recorder: Recorder, _ names: [String]) {
        guard let submission = recorder.fileSubmissions.last else { return XCTFail("No file search submitted") }
        let items = names.map { LauncherFileResult(fileURL: URL(fileURLWithPath: "/tmp/\($0)"), displayName: $0) }
        submission.publish(submission.generation, [LauncherSection(id: .results, title: "Files", items: items)])
    }

    private func publishApplications(_ recorder: Recorder, _ apps: [(name: String, bundleID: String)]) {
        guard let submission = recorder.appSubmissions.last else { return XCTFail("No app search submitted") }
        let items = apps.map {
            LauncherApplicationResult(
                bundleURL: URL(fileURLWithPath: "/Applications/\($0.name).app"),
                bundleIdentifier: $0.bundleID,
                displayName: $0.name
            )
        }
        submission.publish(submission.generation, [LauncherSection(id: .results, title: "Apps", items: items)], [])
    }

    private func addWindows(to controller: WMController, count: Int) throws -> [WindowToken] {
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        return (0 ..< count).map { index in
            let pid = pid_t(94_001 + index)
            let windowId = 94_101 + index
            return controller.workspaceManager.addWindow(
                AXWindowRef(element: AXUIElementCreateApplication(pid), windowId: windowId),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
        }
    }

    private func key(_ keyCode: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(keyCode)
        )!
    }
}
