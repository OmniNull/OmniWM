// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class UnifiedSearchComposeTests: XCTestCase {
    func testLearnedPickLeadsTopHitsAndLeavesItsGroup() {
        let safariApp = app("Safari")
        let safariWindow = window(1, "Safari tips", bundleID: "com.example.Notes")
        let results = UnifiedSearch.compose(
            query: "saf",
            searchedModes: [.windows, .applications],
            results: [.windows: [safariWindow], .applications: [safariApp]],
            learnedPicks: [.launcherTarget("/Applications/Safari.app")]
        )

        XCTAssertEqual(results.topHits, [safariApp.id, safariWindow.id])
        XCTAssertEqual(results.groups.map(\.mode), [])
    }

    func testWithoutLearnedPicksTopHitsFollowSharedTiersThenModeOrder() {
        let otherField = window(1, "Inbox", bundleID: "com.example.Mail", appName: "Safari")
        let contains = command("toggle-unsafe", "Toggle Unsafe Mode")
        let wordStart = app("Apple Safari")
        let prefixFile = file("Safari notes.txt")
        let prefixApp = app("Safari")

        let results = UnifiedSearch.compose(
            query: "saf",
            searchedModes: [.windows, .commands, .applications, .files],
            results: [
                .windows: [otherField],
                .commands: [contains],
                .applications: [wordStart, prefixApp],
                .files: [prefixFile]
            ],
            learnedPicks: []
        )

        XCTAssertEqual(results.topHits, [prefixApp.id, prefixFile.id, wordStart.id])
        XCTAssertEqual(results.groups.map(\.mode), [.windows, .commands])
    }

    func testLearnedWindowPickBoostsThatAppsMostRecentlyFocusedWindow() {
        let older = window(1, "Draft one", bundleID: "com.example.Drafts", recency: 4)
        let newest = window(2, "Draft two", bundleID: "com.example.Drafts", recency: 1)
        let otherApp = window(3, "Draft list", bundleID: "com.example.Tasks", recency: 0)

        let results = UnifiedSearch.compose(
            query: "draft",
            searchedModes: [.windows],
            results: [.windows: [older, otherApp, newest]],
            learnedPicks: [.window(bundleID: "com.example.Drafts")]
        )

        XCTAssertEqual(results.topHits.first, newest.id)
    }

    func testLearnedPickThatNoModeReturnedIsSkipped() {
        let notes = file("Notes.txt")
        let results = UnifiedSearch.compose(
            query: "no",
            searchedModes: [.files],
            results: [.files: [notes]],
            learnedPicks: [.launcherTarget("/deleted.txt")]
        )

        XCTAssertEqual(results.topHits, [notes.id])
    }

    func testGroupsShowFiveRowsAndAShowAllRowOnlyWhenMoreAreHidden() {
        let topHitLimit = UnifiedSearch.topHitLimit
        let shownFiles = topHitLimit + UnifiedSearch.groupRowLimit
        let files = (1 ... shownFiles + 1).map { file("Report \($0).pdf") }
        let apps = (1 ... UnifiedSearch.groupRowLimit).map { app("Reporter \($0)") }

        let results = UnifiedSearch.compose(
            query: "rep",
            searchedModes: [.files, .applications],
            results: [.files: files, .applications: apps],
            learnedPicks: []
        )

        XCTAssertEqual(results.topHits, files[0 ..< topHitLimit].map(\.id))
        XCTAssertEqual(results.groups, [
            .init(mode: .files, rows: files[topHitLimit ..< shownFiles].map(\.id), hasMore: true),
            .init(mode: .applications, rows: apps.map(\.id), hasMore: false)
        ])
        XCTAssertEqual(
            results.selectionOrder,
            files[0 ..< shownFiles].map(\.id) + [.showAll(.files)] + apps.map(\.id)
        )
        XCTAssertEqual(results.sections.map(\.first), [files[0].id, files[topHitLimit].id, apps[0].id])
        let rows = { (ids: [CommandPaletteSelectionID]) in ids.map(UnifiedSearchResults.Line.row) }
        XCTAssertEqual(
            results.lines,
            [.topHitsHeading] + rows(files[0 ..< topHitLimit].map(\.id))
                + [.groupHeading(.files)] + rows(files[topHitLimit ..< shownFiles].map(\.id) + [.showAll(.files)])
                + [.groupHeading(.applications)] + rows(apps.map(\.id))
        )
    }

    func testEmptyQueryComposesNothing() {
        let results = UnifiedSearch.compose(
            query: "  ",
            searchedModes: [.files],
            results: [.files: [file("Notes.txt")]],
            learnedPicks: []
        )

        XCTAssertTrue(results.isEmpty)
    }

    private func window(
        _ windowId: Int,
        _ title: String,
        bundleID: String,
        appName: String = "App",
        recency: Int? = nil
    ) -> UnifiedSearchCandidate {
        UnifiedSearchCandidate(
            id: .window(WindowToken(pid: 93_000, windowId: windowId)),
            title: title,
            otherFields: [appName],
            pickKey: .window(bundleID: bundleID),
            focusRecency: recency ?? windowId
        )
    }

    private func app(_ name: String) -> UnifiedSearchCandidate {
        let path = "/Applications/\(name).app"
        return UnifiedSearchCandidate(id: .application(.results, path), title: name, pickKey: .launcherTarget(path))
    }

    private func command(_ id: String, _ title: String) -> UnifiedSearchCandidate {
        UnifiedSearchCandidate(id: .command(id), title: title, pickKey: .command(actionID: id))
    }

    private func file(_ name: String) -> UnifiedSearchCandidate {
        UnifiedSearchCandidate(
            id: .file(.results, "/Users/me/\(name)"),
            title: name,
            pickKey: .launcherTarget("/Users/me/\(name)")
        )
    }
}
