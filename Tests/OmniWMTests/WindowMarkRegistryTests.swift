// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class WindowMarkRegistryTests: XCTestCase {
    func testNamesAreTrimmedCaseSensitiveAndGloballyUnique() {
        let registry = WindowMarkRegistry()
        let first = WindowToken(pid: 10, windowId: 100)
        let second = WindowToken(pid: 20, windowId: 200)

        let name = "Work"
        XCTAssertEqual(registry.set(" \t\(name)\n", for: first), .inserted)
        XCTAssertEqual(registry.names(for: first), [name])
        XCTAssertEqual(registry.lookup("\(name) "), .found(first))
        XCTAssertEqual(registry.lookup("\u{2003}\(name)\u{2028}"), .found(first))
        XCTAssertEqual(registry.set("work", for: second), .inserted)
        XCTAssertEqual(registry.set("Work", for: second), .duplicate)
        XCTAssertEqual(registry.set("Work", for: first), .unchanged)
        XCTAssertEqual(registry.marks.map(\.name), ["Work", "work"])
    }

    func testEmptyAndEmbeddedControlNamesAreRejected() {
        let registry = WindowMarkRegistry()
        let token = WindowToken(pid: 10, windowId: 100)

        for name in ["", " \t\n ", "bad\nname", "bad\u{0000}name", "bad\u{007F}name"] {
            XCTAssertEqual(registry.set(name, for: token), .invalidName, "name: \(name.debugDescription)")
            XCTAssertEqual(registry.lookup(name), .invalidName)
            XCTAssertEqual(registry.remove(name), .invalidName)
        }
        XCTAssertTrue(registry.marks.isEmpty)
    }

    func testUnicodeSpellingIsPreservedWithoutNormalization() {
        let registry = WindowMarkRegistry()
        let composedToken = WindowToken(pid: 10, windowId: 100)
        let decomposedToken = WindowToken(pid: 20, windowId: 200)
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"

        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        XCTAssertEqual(registry.set(composed, for: composedToken), .inserted)
        XCTAssertEqual(registry.set(decomposed, for: decomposedToken), .inserted)
        XCTAssertEqual(registry.lookup(composed), .found(composedToken))
        XCTAssertEqual(registry.lookup(decomposed), .found(decomposedToken))
        XCTAssertEqual(
            registry.marks.map { Array($0.name.utf8) }.sorted { $0.lexicographicallyPrecedes($1) },
            [Array(composed.utf8), Array(decomposed.utf8)].sorted { $0.lexicographicallyPrecedes($1) }
        )
    }

    func testRekeyMovesAllNamesAndRetirementClearsThem() {
        let registry = WindowMarkRegistry()
        let oldToken = WindowToken(pid: 10, windowId: 100)
        let replacementToken = WindowToken(pid: 11, windowId: 101)
        let replacementAlreadyMarked = WindowToken(pid: 12, windowId: 102)

        XCTAssertEqual(registry.set("primary", for: oldToken), .inserted)
        XCTAssertEqual(registry.set("alias", for: oldToken), .inserted)
        XCTAssertEqual(registry.set("other", for: replacementAlreadyMarked), .inserted)

        XCTAssertEqual(registry.rekey(from: oldToken, to: replacementToken), .rekeyed)
        XCTAssertEqual(registry.names(for: oldToken), [])
        XCTAssertEqual(registry.names(for: replacementToken), ["alias", "primary"])
        XCTAssertEqual(registry.lookup("primary"), .found(replacementToken))
        XCTAssertEqual(registry.rekey(from: replacementToken, to: replacementAlreadyMarked), .rekeyed)
        XCTAssertEqual(registry.names(for: replacementAlreadyMarked), ["alias", "other", "primary"])

        registry.retire(replacementAlreadyMarked)
        XCTAssertEqual(registry.lookup("primary"), .unknown)
        XCTAssertEqual(registry.lookup("alias"), .unknown)
        XCTAssertEqual(registry.lookup("other"), .unknown)
    }

    func testOrderedViewRefreshesAcrossMutations() {
        let registry = WindowMarkRegistry()
        let first = WindowMark(name: "work", token: WindowToken(pid: 10, windowId: 100))
        let second = WindowMark(name: "editor", token: WindowToken(pid: 11, windowId: 101))
        XCTAssertEqual(registry.set(first.name, for: first.token), .inserted)
        let before = registry.marks
        XCTAssertEqual(before, [first])

        XCTAssertEqual(registry.set(second.name, for: second.token), .inserted)
        XCTAssertEqual(registry.marks, [second, first])
        XCTAssertEqual(registry.rekey(from: second.token, to: first.token), .rekeyed)
        XCTAssertEqual(registry.marks, [WindowMark(name: second.name, token: first.token), first])
        XCTAssertEqual(registry.remove(second.name), .removed)
        XCTAssertEqual(registry.marks, [first])
        registry.retire(first.token)
        XCTAssertTrue(registry.marks.isEmpty)
        XCTAssertEqual(before, [first])
    }
}
