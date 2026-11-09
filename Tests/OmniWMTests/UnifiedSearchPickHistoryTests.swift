// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class UnifiedSearchPickHistoryTests: XCTestCase {
    private let safari = UnifiedSearchPickKey.application(bundleID: "com.apple.Safari")
    private let sample = UnifiedSearchPickKey.file(path: "/Users/me/safety-sample.pdf")
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("OmniWMPickHistoryTests-\(UUID().uuidString)", isDirectory: true)

    func testPicksApplyToQueriesThatArePrefixesOfTheTypedQuery() {
        let store = makeStore()
        store.recordUnifiedSearchPick(query: "Safari", key: safari, date: date(1))
        store.recordUnifiedSearchPick(query: "safe", key: sample, date: date(2))

        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: "saf"), [sample, safari])
        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: "SAFA"), [safari])
        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: "safari"), [safari])
        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: "safaris"), [])
        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: "  "), [])
    }

    func testHigherPickCountWinsThenMoreRecentPick() {
        let store = makeStore()
        store.recordUnifiedSearchPick(query: "sa", key: safari, date: date(1))
        store.recordUnifiedSearchPick(query: "sa", key: safari, date: date(2))
        store.recordUnifiedSearchPick(query: "saf", key: sample, date: date(3))
        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: "s"), [safari, sample])

        store.recordUnifiedSearchPick(query: "safe", key: sample, date: date(4))
        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: "s"), [sample, safari])
    }

    func testHistoryKeepsTheFiveHundredMostRecentlyUsedQueries() {
        let store = makeStore()
        for index in 0 ..< 500 {
            store.recordUnifiedSearchPick(query: query(index), key: safari, date: date(index))
        }
        store.recordUnifiedSearchPick(query: query(0), key: safari, date: date(1_000))
        store.recordUnifiedSearchPick(query: "newest", key: sample, date: date(1_001))

        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: query(0)), [safari])
        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: query(1)), [])
        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: query(2)), [safari])
        XCTAssertEqual(store.unifiedSearchLearnedPicks(for: "newest"), [sample])
    }

    func testHistorySurvivesRelaunchAndClearingForgetsEverything() {
        makeStore().recordUnifiedSearchPick(query: "saf", key: safari, date: date(1))

        let relaunched = makeStore()
        XCTAssertEqual(relaunched.unifiedSearchLearnedPicks(for: "s"), [safari])

        relaunched.clearUnifiedSearchPickHistory()
        XCTAssertEqual(relaunched.unifiedSearchLearnedPicks(for: "s"), [])
        XCTAssertEqual(makeStore().unifiedSearchLearnedPicks(for: "s"), [])
    }

    private func makeStore() -> RuntimeStateStore {
        addTeardownBlock { [directory] in try? FileManager.default.removeItem(at: directory) }
        return RuntimeStateStore(directory: directory, deferSaves: false)
    }

    private func query(_ index: Int) -> String {
        "q" + String(format: "%03d", index)
    }

    private func date(_ seconds: Int) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
