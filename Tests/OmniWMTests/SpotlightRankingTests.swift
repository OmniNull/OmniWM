// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

final class SpotlightRankingTests: XCTestCase {
    private struct TextFixture {
        var query: String
        var name: String
        var expected: Float
    }

    func testSingleFieldTextScoresMatchOracle() {
        let fixtures: [TextFixture] = [
            .init(query: "calc", name: "Calculator", expected: 0.7334593),
            .init(query: "cal", name: "Calendar", expected: 0.7306035),
            .init(query: "calculator", name: "Calculator", expected: 0.9424864),
            .init(query: "readme", name: "README.md", expected: 0.9108539)
        ]

        for fixture in fixtures {
            let candidate = SpotlightRanking.Candidate(
                id: fixture.name,
                fields: .init(displayName: fixture.name),
                resultType: .typedFile
            )
            let result = SpotlightRanking.score(query: fixture.query, termCount: 1, candidate: candidate) { _ in
                .init(
                    textTokenCount: 1,
                    matchedTermCount: 1,
                    distinctMatchedTokenCount: 1,
                    fraction: 1,
                    firstTokenMatched: true,
                    lastTokenMatched: true,
                    adjacentInOrder: false
                )
            }
            XCTAssertNotNil(result)
            XCTAssertEqual(
                result?.score.text ?? 0,
                fixture.expected,
                accuracy: 0.000001,
                "\(fixture.query)/\(fixture.name)"
            )
        }
    }

    func testAvailabilityMatchesOracle() {
        XCTAssertEqual(SpotlightRanking.availability(present: 61.5), 1, accuracy: 0.000001)
        XCTAssertEqual(SpotlightRanking.availability(present: 9), 0.7644785, accuracy: 0.000001)
    }

    func testEngagementMatchesOracle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = now.addingTimeInterval(-86400)
        XCTAssertEqual(
            SpotlightRanking.timeDecayedEngagement(dates: [past], now: now),
            0.7581708,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            SpotlightRanking.timeDecayedEngagement(dates: Array(repeating: past, count: 3), now: now),
            0.8186281,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            SpotlightRanking.timeDecayedEngagement(dates: Array(repeating: past, count: 10), now: now),
            0.90326846,
            accuracy: 0.000001
        )

        for (useCount, expected): (Int, Float) in [(4, 0.04114081), (49, 0.1)] {
            let candidate = SpotlightRanking.Candidate(
                id: "app",
                fields: .init(displayName: "App"),
                resultType: .application,
                engagement: .init(useCount: useCount)
            )
            let result = SpotlightRanking.score(query: "app", termCount: 1, candidate: candidate) { _ in
                .init(
                    textTokenCount: 1,
                    matchedTermCount: 1,
                    distinctMatchedTokenCount: 1,
                    fraction: 1,
                    firstTokenMatched: true,
                    lastTokenMatched: true,
                    adjacentInOrder: false
                )
            }
            XCTAssertEqual(result?.score.engagement ?? 0, expected, accuracy: 0.000001)
        }
    }

    func testFreshnessMatchesOracle() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for (days, expected): (Int, Double) in [(10, 0.6429527), (120, 0.5), (3000, 0.3549744)] {
            let date = now.addingTimeInterval(-Double(days) * 86400)
            XCTAssertEqual(
                SpotlightRanking.freshnessScore(date: date, now: now),
                expected,
                accuracy: 0.000001
            )
        }
        XCTAssertEqual(SpotlightRanking.freshnessScore(date: nil, now: now), 0.5)
    }

    func testCompositeMatchesOracle() {
        XCTAssertEqual(
            SpotlightRanking.composite(text: 0.8, engagement: 0.7, freshness: 0.6, context: 0.5, resultType: 1),
            0.72,
            accuracy: 0.000001
        )
    }

    func testSingleTermLaunchStringMatchesOracle() {
        XCTAssertEqual(SpotlightRanking.launchStringScore("calc", query: "calc", termCount: 1, match: nil), 1)
        var partial = SpotlightRanking.TokenMatch(
            textTokenCount: 1,
            matchedTermCount: 1,
            distinctMatchedTokenCount: 1,
            fraction: 0.4,
            firstTokenMatched: true,
            lastTokenMatched: true,
            adjacentInOrder: false
        )
        XCTAssertEqual(
            SpotlightRanking.launchStringScore("calculator", query: "calc", termCount: 1, match: partial),
            0.98,
            accuracy: 0.000001
        )
        partial.fraction = 0.3
        XCTAssertEqual(
            SpotlightRanking.launchStringScore("calculator", query: "cal", termCount: 1, match: partial),
            0.65,
            accuracy: 0.000001
        )
        partial.fraction = 0.2
        XCTAssertEqual(
            SpotlightRanking.launchStringScore("calculator", query: "ca", termCount: 1, match: partial),
            0.2,
            accuracy: 0.000001
        )
    }

    func testMultipleTermLaunchStringMatchesOracle() {
        var partial = SpotlightRanking.TokenMatch(
            textTokenCount: 2,
            matchedTermCount: 2,
            distinctMatchedTokenCount: 2,
            fraction: 2,
            firstTokenMatched: true,
            lastTokenMatched: true,
            adjacentInOrder: true
        )
        XCTAssertEqual(
            SpotlightRanking.launchStringScore("Studio Code", query: "studio code", termCount: 2, match: partial),
            1,
            accuracy: 0.000001
        )
        partial.fraction = 1.4
        XCTAssertEqual(
            SpotlightRanking.launchStringScore("My Calculator", query: "my calc", termCount: 2, match: partial),
            0.99,
            accuracy: 0.000001
        )
        partial.firstTokenMatched = false
        partial.textTokenCount = 3
        partial.fraction = 2
        XCTAssertEqual(
            SpotlightRanking.launchStringScore(
                "Visual Studio Code",
                query: "studio code",
                termCount: 2,
                match: partial
            ),
            0,
            accuracy: 0.000001
        )
    }

    func testAlternateNameAndShortcutSelection() {
        let safari = SpotlightRanking.Candidate(
            id: "safari",
            fields: .init(displayName: "Safari", alternateNames: ["browser"]),
            resultType: .application
        )
        let other = SpotlightRanking.Candidate(
            id: "other",
            fields: .init(displayName: "Other"),
            resultType: .application
        )
        let results = SpotlightRanking.rank(
            query: "browser",
            termCount: 1,
            candidates: [other, safari],
            shortcuts: ["browser": "other"]
        ) { text in
            guard text == "browser" else { return nil }
            return .init(
                textTokenCount: 1,
                matchedTermCount: 1,
                distinctMatchedTokenCount: 1,
                fraction: 1,
                firstTokenMatched: true,
                lastTokenMatched: true,
                adjacentInOrder: false
            )
        }
        XCTAssertEqual(results.map(\.id), ["other", "safari"])
        XCTAssertGreaterThan(results[1].score.text, 0)
        XCTAssertEqual(
            SpotlightRanking.rank(query: "", termCount: 0, candidates: [safari]) { _ in nil }.count,
            0
        )
    }

    func testRankingStopsAtCancellationBoundary() {
        let candidates = ["Alpha", "Alpine"].map {
            SpotlightRanking.Candidate(
                id: $0,
                fields: .init(displayName: $0),
                resultType: .application
            )
        }
        var checks = 0
        var matches = 0
        let results = SpotlightRanking.rank(
            query: "al",
            termCount: 1,
            candidates: candidates,
            shouldCancel: {
                checks += 1
                return checks > 1
            },
            match: { _ in
                matches += 1
                return .init(
                    textTokenCount: 1,
                    matchedTermCount: 1,
                    distinctMatchedTokenCount: 1,
                    fraction: 0.4,
                    firstTokenMatched: true,
                    lastTokenMatched: true,
                    adjacentInOrder: false
                )
            }
        )
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(matches, 1)
    }

    func testSubstringWithoutTokenMatchIsNotAdmitted() {
        let xcode = SpotlightRanking.Candidate(
            id: "xcode",
            fields: .init(displayName: "Xcode"),
            resultType: .application
        )
        let noMatch: SpotlightRanking.Matcher = { _ in
            .init(
                textTokenCount: 1,
                matchedTermCount: 0,
                distinctMatchedTokenCount: 0,
                fraction: 0,
                firstTokenMatched: false,
                lastTokenMatched: false,
                adjacentInOrder: false
            )
        }
        XCTAssertTrue(SpotlightRanking.rank(query: "ode", termCount: 1, candidates: [xcode], match: noMatch).isEmpty)
        XCTAssertEqual(
            SpotlightRanking.rank(
                query: "ode",
                termCount: 1,
                candidates: [xcode],
                admitUnmatched: true,
                match: noMatch
            ).map(\.id),
            ["xcode"]
        )
    }

    func testTermsCoveredAcrossFieldsAreAdmitted() {
        let candidate = SpotlightRanking.Candidate(
            id: "code",
            fields: .init(displayName: "Visual Studio", identifier: "vscode"),
            resultType: .application
        )
        let results = SpotlightRanking.rank(query: "visual vscode", termCount: 2, candidates: [candidate]) { text in
            let term: UInt64 = text == "vscode" ? 2 : 1
            return .init(
                textTokenCount: 1,
                matchedTermCount: 1,
                distinctMatchedTokenCount: 1,
                fraction: 1,
                firstTokenMatched: true,
                lastTokenMatched: true,
                adjacentInOrder: false,
                matchedTermMask: term
            )
        }
        XCTAssertEqual(results.map(\.id), ["code"])
    }

    func testLaunchStringMustMatchQueryInOrderFromFirstToken() {
        let reordered = SpotlightRanking.TokenMatch(
            textTokenCount: 2,
            matchedTermCount: 2,
            distinctMatchedTokenCount: 2,
            fraction: 2,
            firstTokenMatched: true,
            lastTokenMatched: true,
            adjacentInOrder: false
        )
        XCTAssertEqual(
            SpotlightRanking.launchStringScore("google chrome", query: "chrome google", termCount: 2, match: reordered),
            0
        )
        let laterToken = SpotlightRanking.TokenMatch(
            textTokenCount: 2,
            matchedTermCount: 1,
            distinctMatchedTokenCount: 1,
            fraction: 1,
            firstTokenMatched: false,
            lastTokenMatched: true,
            adjacentInOrder: false
        )
        XCTAssertEqual(
            SpotlightRanking.launchStringScore("foo calc", query: "calc", termCount: 1, match: laterToken),
            0
        )
    }

    func testLocalizedAlternatesAreMatchedOnlyWhenTheyContainEveryTerm() {
        var matchedTexts: [String] = []
        let candidate = SpotlightRanking.Candidate(
            id: "calculator",
            fields: .init(
                displayName: "Calculator",
                alternateNames: ["Calculatrice", "Rechner"],
                foldedAlternateNames: ["calculatrice", "rechner"]
            ),
            resultType: .application
        )
        let results = SpotlightRanking.rank(query: "rech", termCount: 1, candidates: [candidate]) { text in
            matchedTexts.append(text)
            let matched = text == "Rechner" ? 1 : 0
            return .init(
                textTokenCount: 1,
                matchedTermCount: matched,
                distinctMatchedTokenCount: matched,
                fraction: Float(matched),
                firstTokenMatched: matched == 1,
                lastTokenMatched: matched == 1,
                adjacentInOrder: false,
                matchedTermMask: UInt64(matched)
            )
        }
        XCTAssertEqual(results.map(\.id), ["calculator"])
        XCTAssertFalse(matchedTexts.contains("Calculatrice"))
        XCTAssertTrue(matchedTexts.contains("Rechner"))
    }
}
