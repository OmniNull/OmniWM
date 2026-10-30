// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import XCTest

@MainActor
final class HiddenBarMenuAccessFallbackTests: XCTestCase {
    private struct Case {
        let first: [ResolvedMenuBarItem]?
        let covered: Bool
        let clicking: Bool
        let reveals: Bool
    }

    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testAMenuBarOurBarHidesIsRevealedOnlyForAnItemThatNeedsIt() async {
        let key = MenuBarItemKey(bundleID: "app", ordinal: 0)
        let item = ResolvedMenuBarItem(
            key: key,
            pid: 42,
            bounds: CGRect(x: 1100, y: 0, width: 40, height: 24),
            semanticIdentity: nil
        )
        let cases: [String: Case] = [
            "resolved under our bar": Case(first: [item], covered: true, clicking: true, reveals: false),
            "read as a menu while uncovered": Case(first: [item], covered: false, clicking: false, reveals: false),
            "nothing resolved": Case(first: nil, covered: true, clicking: false, reveals: true),
            "no items while hidden": Case(first: [], covered: true, clicking: true, reveals: true),
            "clicked while uncovered": Case(first: [item], covered: false, clicking: true, reveals: true)
        ]
        for (name, testCase) in cases {
            var accesses: [Bool] = []
            var resolves = 0
            let hiddenBar = HiddenBarController(
                settings: settings(),
                setMenuAccess: { accesses.append($0)
                    return true
                },
                menuBarHiddenByBar: { true },
                coversPoint: { _ in testCase.covered },
                resolveItems: { _, _ in
                    resolves += 1
                    return resolves == 1 ? testCase.first : [item]
                }
            )
            hiddenBar.startReconcealForTests(revealedBundleIDs: ["app"])
            XCTAssertEqual(accesses, [], name)

            let items = await hiddenBar.resolveRevealedItemsForTests(
                "app",
                pid: 42,
                clicking: testCase.clicking ? key : nil
            )

            XCTAssertEqual(items?.map(\.key), [key], name)
            XCTAssertEqual(accesses, testCase.reveals ? [true] : [], name)
            XCTAssertEqual(resolves, testCase.reveals ? 2 : 1, name)
            hiddenBar.cleanup()
            XCTAssertEqual(accesses, testCase.reveals ? [true, false] : [], name)
        }
    }

    func testAResolveThatLosesItsRevealOrCannotGetAccessStops() async {
        let key = MenuBarItemKey(bundleID: "app", ordinal: 0)
        let item = ResolvedMenuBarItem(
            key: key,
            pid: 42,
            bounds: CGRect(x: 1100, y: 0, width: 40, height: 24),
            semanticIdentity: nil
        )
        var accesses: [Bool] = []
        var resolves = 0
        var lateBar: HiddenBarController?
        lateBar = HiddenBarController(
            settings: settings(),
            setMenuAccess: { accesses.append($0)
                return true
            },
            menuBarHiddenByBar: { true },
            coversPoint: { _ in true },
            resolveItems: { _, _ in
                resolves += 1
                lateBar?.concealAllRevealed()
                return nil
            }
        )
        lateBar?.startReconcealForTests(revealedBundleIDs: ["app"])
        let late = await lateBar?.resolveRevealedItemsForTests("app", pid: 42, clicking: nil)
        XCTAssertNil(late)
        XCTAssertEqual(accesses, [])
        XCTAssertEqual(resolves, 1)
        lateBar?.cleanup()

        resolves = 0
        let deniedBar = HiddenBarController(
            settings: settings(),
            setMenuAccess: { accesses.append($0)
                return false
            },
            menuBarHiddenByBar: { true },
            coversPoint: { _ in false },
            resolveItems: { _, _ in
                resolves += 1
                return [item]
            }
        )
        deniedBar.startReconcealForTests(revealedBundleIDs: ["app"])
        let denied = await deniedBar.resolveRevealedItemsForTests("app", pid: 42, clicking: key)
        XCTAssertNil(denied)
        XCTAssertEqual(accesses, [true])
        XCTAssertEqual(resolves, 1)
        deniedBar.cleanup()
    }

    func testAMenuReadThatFailsUnderOurBarIsRetriedOnceWithMenuAccess() {
        let retry = HiddenBarController.retriesMenuWithAccess
        XCTAssertTrue(retry(true, false, true))
        XCTAssertFalse(retry(true, true, true))
        XCTAssertFalse(retry(true, false, false))
        XCTAssertFalse(retry(false, false, true))

        var accesses: [Bool] = []
        let hiddenBar = HiddenBarController(
            settings: settings(),
            setMenuAccess: { accesses.append($0)
                return true
            },
            menuBarHiddenByBar: { true }
        )
        XCTAssertTrue(hiddenBar.takeMenuAccessForReveal())
        XCTAssertEqual(accesses, [])
        XCTAssertTrue(hiddenBar.takeMenuAccessForReveal(required: true))
        XCTAssertEqual(accesses, [true])
        hiddenBar.cleanup()
    }

    func testACoveredItemIsPressedAndNeverClicked() {
        let covered = HiddenBarClickForwarder.activationCandidate(pid: 1, covered: true, electron: false)
        XCTAssertTrue(covered.useAXPress)
        guard case .unavailable = MenuBarItemLocator.fallback(for: covered, frame: .zero) else {
            return XCTFail("a covered item must not be clicked when its press fails")
        }
        let uncovered = HiddenBarClickForwarder.activationCandidate(pid: 1, covered: false, electron: false)
        XCTAssertFalse(uncovered.useAXPress)
        guard case .clickFrame = MenuBarItemLocator.fallback(for: uncovered, frame: .zero) else {
            return XCTFail("an uncovered item is still clicked")
        }
        XCTAssertTrue(HiddenBarClickForwarder.activationCandidate(pid: 1, covered: false, electron: true).useAXPress)
    }

    func testAnAgentHostedItemIsPressedAndNeverClicked() {
        let uncovered = HiddenBarClickForwarder.activationCandidate(pid: 1, covered: false, electron: false)
        XCTAssertTrue(MenuBarItemLocator.usesAXPress(for: uncovered, hosted: true))
        XCTAssertFalse(MenuBarItemLocator.usesAXPress(for: uncovered, hosted: false))
        guard case .unavailable = MenuBarItemLocator.fallback(for: uncovered, frame: .zero, hosted: true) else {
            return XCTFail("an agent hosted item must not be clicked when its press fails")
        }
        guard case .clickFrame = MenuBarItemLocator.fallback(for: uncovered, frame: .zero, hosted: false) else {
            return XCTFail("an item from the app's own extras bar is still clicked")
        }
    }

    func testAgentHostedItemsKeepOnlyTheOwnerSortedByPosition() {
        let entries = [
            MenuBarItemLocator.HostedItemEntry(
                pid: 7,
                frame: CGRect(x: 300, y: 0, width: 20, height: 24),
                element: "b"
            ),
            MenuBarItemLocator.HostedItemEntry(
                pid: 9,
                frame: CGRect(x: 100, y: 0, width: 20, height: 24),
                element: "other"
            ),
            MenuBarItemLocator.HostedItemEntry(
                pid: 7,
                frame: CGRect(x: 200, y: 0, width: 20, height: 24),
                element: "a"
            ),
            MenuBarItemLocator.HostedItemEntry(pid: 7, frame: .zero, element: "empty")
        ]
        XCTAssertEqual(MenuBarItemLocator.hostedItems(entries, pid: 7).map(\.element), ["a", "b"])
    }

    func testTheAgentWalkReadsEveryItemAndSkipsItemsWithoutAFrame() {
        let tree = agentTree([
            "window": ["group-a", "group-b"],
            "group-a": ["a"],
            "group-b": ["b", "frameless"]
        ])
        let entries = MenuBarItemLocator.hostedEntries(tree, expired: { false })
        XCTAssertEqual(entries?.map(\.element), ["a", "b"])
        XCTAssertEqual(entries?.map(\.pid), [7, 7])
    }

    func testTheAgentWalkStopsOnceItsDeadlinePasses() {
        let tree = agentTree(["window": ["group"], "group": ["a", "b"]])
        var checks = 0
        let entries = MenuBarItemLocator.hostedEntries(tree, expired: {
            checks += 1
            return checks > 3
        })
        XCTAssertNil(entries)
        XCTAssertEqual(checks, 4)
    }

    func testAHostedItemIndexWalksTheAgentOncePerPass() {
        var walks = 0
        let element = AXUIElementCreateApplication(1)
        let index = MenuBarItemLocator.HostedItemIndex {
            walks += 1
            return [
                .init(pid: 7, frame: CGRect(x: 40, y: 0, width: 20, height: 24), element: element),
                .init(pid: 9, frame: CGRect(x: 10, y: 0, width: 20, height: 24), element: element),
                .init(pid: 7, frame: CGRect(x: 10, y: 0, width: 20, height: 24), element: element)
            ]
        }
        XCTAssertEqual(index.items(for: 7)?.map(\.frame.minX), [10, 40])
        XCTAssertEqual(index.items(for: 9)?.count, 1)
        XCTAssertNil(index.items(for: 3))
        XCTAssertEqual(index.items(for: 7)?.allSatisfy(\.hosted), true)
        XCTAssertEqual(walks, 1)
    }

    func testTheAgentWalkBudgetStartsAtTheWalkNotAtThePass() {
        var now = ContinuousClock.now
        let expired = MenuBarItemLocator.expiry(after: .milliseconds(250), now: { now })
        now = now.advanced(by: .seconds(1))
        XCTAssertFalse(expired())
        now = now.advanced(by: .milliseconds(200))
        XCTAssertFalse(expired())
        now = now.advanced(by: .milliseconds(100))
        XCTAssertTrue(expired())
    }

    private func agentTree(_ children: [String: [String]]) -> MenuBarItemLocator.HostedTree<String> {
        MenuBarItemLocator.HostedTree(
            windows: { ["window"] },
            children: { children[$0] ?? [] },
            owner: { _ in 7 },
            frame: { $0 == "frameless" ? nil : CGRect(x: $0 == "a" ? 10 : 20, y: 0, width: 20, height: 24) }
        )
    }

    private func settings() -> SettingsStore {
        SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false),
            autosaveEnabled: false
        )
    }
}
