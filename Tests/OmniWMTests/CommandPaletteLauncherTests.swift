// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteLauncherTests: XCTestCase {
    private final class Recorder {
        var fileSubmissions: [(
            query: String,
            publish: @MainActor (Int, [LauncherSection<LauncherFileResult>]) -> Void
        )] = []
        var appSubmissions: [(query: String, publish: @MainActor (
            Int,
            [LauncherSection<LauncherApplicationResult>],
            [LauncherChip]
        ) -> Void)] = []
        var fileStops = 0
        var openedFiles: [URL] = []
        var openedApplications: [URL] = []
        var revealed: [URL] = []
        var completions: [@MainActor @Sendable (String?) -> Void] = []
        var recorded: [String] = []
        var failures: [String] = []
    }

    private func makeFixture(mode: CommandPaletteMode, recorder: Recorder) -> CommandPaletteFocusFixture {
        CommandPaletteFocusFixture(initialMode: mode) { environment in
            environment.submitFileSearch = { _, query, _, _, publish in
                recorder.fileSubmissions.append((query, publish))
            }
            environment.submitApplicationSearch = { _, query, _, _, publish in
                recorder.appSubmissions.append((query, publish))
            }
            environment.stopFileSearch = { recorder.fileStops += 1 }
            environment.stopApplicationSearch = {}
            environment.openFile = { url, completion in
                recorder.openedFiles.append(url)
                recorder.completions.append(completion)
            }
            environment.openApplication = { url, completion in
                recorder.openedApplications.append(url)
                recorder.completions.append(completion)
            }
            environment.runningApplicationForResult = { _ in nil }
            environment.revealInFinder = { recorder.revealed.append($0) }
            environment.recordLauncherLaunch = { _, targetID, _, _ in recorder.recorded.append(targetID) }
            environment.presentCommandFailure = { recorder.failures.append($0) }
        }
    }

    private func fileSection(_ names: [String]) -> [LauncherSection<LauncherFileResult>] {
        [LauncherSection(
            id: .results,
            title: "Results",
            items: names.map { LauncherFileResult(fileURL: URL(fileURLWithPath: "/tmp/\($0)"), displayName: $0) }
        )]
    }

    private func key(_ keyCode: Int, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }

    func testReopeningInFilesModeStartsASearchAndDismissStopsIt() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .files, recorder: recorder)
        defer { fixture.cleanup() }

        _ = try fixture.show()
        XCTAssertEqual(recorder.fileSubmissions.map(\.query), [""])
        fixture.palette.toggle(wmController: fixture.controller)
        XCTAssertGreaterThan(recorder.fileStops, 0)
        fixture.palette.show(wmController: fixture.controller)
        XCTAssertEqual(recorder.fileSubmissions.map(\.query), ["", ""])
    }

    func testStalePublicationIsIgnoredAndCurrentOneSelectsFirstResult() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .files, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let staleGeneration = fixture.palette.launcherRequestGeneration

        fixture.palette.searchText = "rep"
        recorder.fileSubmissions[0].publish(staleGeneration, fileSection(["stale.txt"]))
        XCTAssertTrue(fixture.palette.fileSections.isEmpty)

        recorder.fileSubmissions[1].publish(fixture.palette.launcherRequestGeneration, fileSection(["report.txt"]))
        XCTAssertEqual(fixture.palette.fileSections.first?.items.map(\.displayName), ["report.txt"])
        XCTAssertEqual(fixture.palette.selectedItemID, .file(.results, "/tmp/report.txt"))
    }

    func testReturnBeforeResultsOpensFirstResultOnceAndRecordsOnlyAfterSuccess() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .files, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        fixture.palette.searchText = "rep"

        fixture.palette.selectCurrent()
        XCTAssertTrue(recorder.openedFiles.isEmpty)
        recorder.fileSubmissions[1].publish(fixture.palette.launcherRequestGeneration, fileSection(["report.txt"]))

        XCTAssertEqual(recorder.openedFiles, [URL(fileURLWithPath: "/tmp/report.txt")])
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertTrue(recorder.recorded.isEmpty)
        recorder.completions[0](nil)
        XCTAssertEqual(recorder.recorded, ["/tmp/report.txt"])
    }

    func testApplicationOpenFailureIsReportedAndNotRecorded() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .applications, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let app = LauncherApplicationResult(
            bundleURL: URL(fileURLWithPath: "/Applications/Missing.app"),
            bundleIdentifier: "com.example.missing",
            displayName: "Missing"
        )
        recorder.appSubmissions[0].publish(
            fixture.palette.launcherRequestGeneration,
            [LauncherSection(id: .all, title: "", items: [app])],
            []
        )

        fixture.palette.selectCurrent()
        XCTAssertEqual(recorder.openedApplications, [app.bundleURL])
        recorder.completions[0]("The application can’t be opened.")
        XCTAssertEqual(recorder.failures, ["The application can’t be opened."])
        XCTAssertTrue(recorder.recorded.isEmpty)
    }

    func testBackspaceOnEmptyQueryRemovesTheActiveChip() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .files, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        let chip = try XCTUnwrap(FileSearchEngine.chips.first)

        fixture.palette.selectLauncherChip(chip)
        XCTAssertEqual(fixture.palette.selectedFileChip?.id, chip.id)
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_Delete, "\u{7f}"), relevantModifiers: []))
        XCTAssertNil(fixture.palette.selectedFileChip)
    }

    func testRevealAndPreviewShortcutsFollowTheTypedCharacter() throws {
        let recorder = Recorder()
        let fixture = makeFixture(mode: .files, recorder: recorder)
        defer { fixture.cleanup() }
        _ = try fixture.show()
        recorder.fileSubmissions[0].publish(fixture.palette.launcherRequestGeneration, fileSection(["a.txt"]))

        XCTAssertFalse(fixture.palette.handleLauncherKeyDown(
            try key(kVK_ANSI_R, "p", .command),
            relevantModifiers: .command
        ))
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(
            try key(kVK_ANSI_Z, "y", .command),
            relevantModifiers: .command
        ))
        XCTAssertTrue(fixture.palette.isLauncherPreviewVisible)

        fixture.palette.searchText = "a"
        XCTAssertTrue(fixture.palette.isLauncherPreviewVisible)
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(try key(kVK_Escape, "\u{1b}"), relevantModifiers: []))
        XCTAssertFalse(fixture.palette.isLauncherPreviewVisible)

        recorder.fileSubmissions[1].publish(fixture.palette.launcherRequestGeneration, fileSection(["a.txt"]))
        XCTAssertTrue(fixture.palette.handleLauncherKeyDown(
            try key(kVK_ANSI_P, "r", .command),
            relevantModifiers: .command
        ))
        XCTAssertEqual(recorder.revealed, [URL(fileURLWithPath: "/tmp/a.txt")])
    }
}
