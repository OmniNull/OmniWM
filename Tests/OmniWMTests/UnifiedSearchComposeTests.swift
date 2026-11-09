// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class UnifiedSearchComposeTests: XCTestCase {
    func testLearnedPickLeadsTopHitsAndLeavesItsGroup() {
        let safariApp = app("Safari", bundleID: "com.apple.Safari")
        let safariWindow = window(1, "Safari tips", bundleID: "com.example.Notes")
        let results = UnifiedSearch.compose(
            query: "saf",
            searchedModes: [.windows, .applications],
            results: [.windows: [safariWindow], .applications: [safariApp]],
            learnedPicks: [.application(bundleID: "com.apple.Safari")]
        )

        XCTAssertEqual(results.topHits, [safariApp.id, safariWindow.id])
        XCTAssertEqual(results.groups.map(\.mode), [])
    }

    func testWithoutLearnedPicksTopHitsFollowSharedTiersThenModeOrder() {
        let otherField = window(1, "Inbox", bundleID: "com.example.Mail", appName: "Safari")
        let contains = command("toggle-unsafe", "Toggle Unsafe Mode")
        let wordStart = app("Apple Safari", bundleID: "com.example.AppleSafari")
        let prefixFile = file("Safari notes.txt")
        let prefixApp = app("Safari", bundleID: "com.apple.Safari")

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
            learnedPicks: [.file(path: "/deleted.txt")]
        )

        XCTAssertEqual(results.topHits, [notes.id])
    }

    func testGroupsShowFiveRowsAndAShowAllRowOnlyWhenMoreAreHidden() {
        let files = (1 ... 9).map { file("Report \($0).pdf") }
        let apps = (1 ... 5).map { app("Reporter \($0)", bundleID: "com.example.r\($0)") }

        let results = UnifiedSearch.compose(
            query: "rep",
            searchedModes: [.files, .applications],
            results: [.files: files, .applications: apps],
            learnedPicks: []
        )

        XCTAssertEqual(results.topHits, files[0 ..< 3].map(\.id))
        XCTAssertEqual(results.groups, [
            .init(mode: .files, rows: files[3 ..< 8].map(\.id), hasMore: true),
            .init(mode: .applications, rows: apps.map(\.id), hasMore: false)
        ])
        XCTAssertEqual(
            results.selectionOrder,
            files[0 ..< 8].map(\.id) + [.showAll(.files)] + apps.map(\.id)
        )
        XCTAssertEqual(results.sections.map(\.first), [files[0].id, files[3].id, apps[0].id])
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

    private func app(_ name: String, bundleID: String) -> UnifiedSearchCandidate {
        UnifiedSearchCandidate(
            id: .application(.results, "/Applications/\(name).app"),
            title: name,
            pickKey: .application(bundleID: bundleID)
        )
    }

    private func command(_ id: String, _ title: String) -> UnifiedSearchCandidate {
        UnifiedSearchCandidate(id: .command(id), title: title, pickKey: .command(actionID: id))
    }

    private func file(_ name: String) -> UnifiedSearchCandidate {
        UnifiedSearchCandidate(
            id: .file(.results, "/Users/me/\(name)"),
            title: name,
            pickKey: .file(path: "/Users/me/\(name)")
        )
    }
}
