// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import XCTest

@MainActor
private final class HiddenBarMenuFixture {
    var attributes: [ObjectIdentifier: [String: Any]] = [:]
    var ownerCurrent = true
    var extrasAvailable = true
    var expectedPID: pid_t = 1234
    var failedElement: AXUIElement?
    var pressResult = AXError.success
    var pressed: [AXUIElement] = []
    var reads: [ObjectIdentifier] = []
    private var nextPID: pid_t = 91_800
    let extras: AXUIElement
    let status: AXUIElement
    let root: AXUIElement

    init() {
        extras = AXUIElementCreateApplication(91_797)
        status = AXUIElementCreateApplication(91_798)
        root = AXUIElementCreateApplication(91_799)
        attributes[ObjectIdentifier(extras)] = ["AXChildren": [status]]
        attributes[ObjectIdentifier(status)] = ["AXIdentifier": "status", "AXChildren": [root]]
        attributes[ObjectIdentifier(root)] = ["AXRole": "AXMenu", "AXChildren": [AXUIElement]()]
    }

    func node(_ values: [String: Any]) -> AXUIElement {
        let element = AXUIElementCreateApplication(nextPID)
        nextPID += 1
        attributes[ObjectIdentifier(element)] = values
        return element
    }

    func item(_ title: String, enabled: Bool = true, submenu: AXUIElement? = nil) -> AXUIElement {
        node([
            "AXTitle": title, "AXRole": "AXMenuItem", "AXEnabled": enabled,
            "AXChildren": submenu.map { [$0] } ?? []
        ])
    }

    func target(
        ordinal: Int = 0,
        identifier: String? = "status",
        pid: pid_t = 1234,
        bundleID: String = "com.example.menu"
    ) -> ResolvedMenuBarItem {
        ResolvedMenuBarItem(
            key: MenuBarItemKey(bundleID: bundleID, ordinal: ordinal), pid: pid, bounds: .zero,
            semanticIdentity: identifier.map {
                MenuBarItemSemanticIdentity(identifier: $0, title: nil, accessibilityDescription: nil, help: nil)
            }
        )
    }

    func session() -> HiddenBarMenuSession {
        HiddenBarMenuSession(
            environment: MenuExtractorEnvironment(
                now: { 0 },
                readAttribute: { [self] element, name, _ in
                    if name as String == "AXExtrasMenuBar" {
                        guard extrasAvailable else { throw MenuExtractionError.ax(.noValue) }
                        return extras
                    }
                    if let failedElement, CFEqual(element, failedElement) {
                        throw MenuExtractionError.ax(.cannotComplete)
                    }
                    return attributes[ObjectIdentifier(element)]?[name as String]
                },
                readAttributes: { [self] element, names, _ in
                    reads.append(ObjectIdentifier(element))
                    if let failedElement, CFEqual(element, failedElement) {
                        throw MenuExtractionError.ax(.cannotComplete)
                    }
                    guard let names = names as? [String] else { throw MenuExtractionError.invalidResponse }
                    return names.map { attributes[ObjectIdentifier(element)]?[$0] ?? NSNull() }
                }
            ),
            ownerIsCurrent: { [self] _ in ownerCurrent },
            elementPID: { [self] _ in expectedPID },
            press: { [self] element in
                pressed.append(element)
                return pressResult
            }
        )
    }

    func setChildren(_ children: [AXUIElement], of element: AXUIElement? = nil) {
        attributes[ObjectIdentifier(element ?? root)]?["AXChildren"] = children
    }
}

@MainActor
final class HiddenBarMenuSessionTests: XCTestCase {
    func testExposedMenuLoadsRowsWithoutActivatingNativeItem() throws {
        let fixture = HiddenBarMenuFixture()
        let command = fixture.item("Command")
        fixture.attributes[ObjectIdentifier(command)]?["AXMenuItemMarkChar"] = "✓"
        fixture.attributes[ObjectIdentifier(command)]?["AXMenuItemCmdChar"] = "k"
        fixture.attributes[ObjectIdentifier(command)]?["AXMenuItemCmdModifiers"] = 9
        let separator = fixture.node(["AXRole": "AXSeparator"])
        fixture.setChildren([command, fixture.item("Disabled", enabled: false), separator])
        let session = fixture.session()

        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
        let page = try XCTUnwrap(session.page)
        XCTAssertEqual(page.rows.map(\.title), ["Command", "Disabled", ""])
        XCTAssertEqual(page.rows.map(\.enabled), [true, false, false])
        XCTAssertEqual(page.rows[0].mark, "✓")
        XCTAssertEqual(page.rows[0].shortcut, "⇧⌘K")
        XCTAssertTrue(page.rows[2].separator)
        XCTAssertNil(page.backID)
        XCTAssertEqual(session.bundleID, "com.example.menu")
        XCTAssertTrue(fixture.pressed.isEmpty)
    }

    func testIdentitySurvivesReorderingWithoutGeometry() {
        let fixture = HiddenBarMenuFixture()
        let other = fixture.node(["AXIdentifier": "other"])
        fixture.setChildren([other, fixture.status], of: fixture.extras)
        let session = fixture.session()

        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
        XCTAssertTrue(fixture.pressed.isEmpty)
    }

    func testDuplicateFreshIdentityRejectsAcquisition() {
        let fixture = HiddenBarMenuFixture()
        let duplicate = fixture.node(["AXIdentifier": "status"])
        fixture.setChildren([fixture.status, duplicate], of: fixture.extras)
        let session = fixture.session()

        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .unavailable)
        XCTAssertNil(session.page)
    }

    func testDuplicateCachedIdentityRejectsAcquisition() {
        let fixture = HiddenBarMenuFixture()
        let session = fixture.session()

        XCTAssertEqual(session.open(
            target: fixture.target(), cachedItems: [fixture.target(), fixture.target(ordinal: 1)]
        ), .unavailable)
    }

    func testSemanticMismatchDoesNotUseOrdinal() {
        let fixture = HiddenBarMenuFixture()
        fixture.attributes[ObjectIdentifier(fixture.status)]?["AXIdentifier"] = "replacement"
        let session = fixture.session()

        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .unavailable)
        XCTAssertFalse(session.lastOpenFailedReading)
    }

    func testSoleUnnamedItemCanLoadItsMenu() {
        let fixture = HiddenBarMenuFixture()
        fixture.attributes[ObjectIdentifier(fixture.status)]?["AXIdentifier"] = nil
        let target = fixture.target(identifier: nil)
        let session = fixture.session()

        XCTAssertEqual(session.open(target: target, cachedItems: [target]), .menu)
    }

    func testATooltipDoesNotIdentifyAnItem() {
        let fixture = HiddenBarMenuFixture()
        fixture.attributes[ObjectIdentifier(fixture.status)]?["AXIdentifier"] = nil
        fixture.attributes[ObjectIdentifier(fixture.status)]?["AXHelp"] = "Vorssaint: awake indefinitely"
        let target = fixture.target(identifier: nil)
        let session = fixture.session()

        XCTAssertEqual(session.open(target: target, cachedItems: [target]), .menu)
    }

    func testTooltipsStillTellSeveralItemsApart() {
        let fixture = HiddenBarMenuFixture()
        fixture.attributes[ObjectIdentifier(fixture.status)]?["AXIdentifier"] = nil
        fixture.attributes[ObjectIdentifier(fixture.status)]?["AXHelp"] = "second"
        let first = fixture.node(["AXHelp": "first"])
        fixture.setChildren([first, fixture.status], of: fixture.extras)
        let items = ["first", "second"].enumerated().map { ordinal, help in
            ResolvedMenuBarItem(
                key: MenuBarItemKey(bundleID: "com.example.menu", ordinal: ordinal), pid: 1234, bounds: .zero,
                semanticIdentity: MenuBarItemSemanticIdentity(
                    identifier: nil, title: nil, accessibilityDescription: nil, help: help
                )
            )
        }
        let session = fixture.session()

        XCTAssertEqual(session.open(target: items[1], cachedItems: items), .menu)
    }

    func testMultipleUnnamedItemsRejectAcquisition() {
        let fixture = HiddenBarMenuFixture()
        fixture.attributes[ObjectIdentifier(fixture.status)]?["AXIdentifier"] = nil
        let other = fixture.node([:])
        fixture.setChildren([fixture.status, other], of: fixture.extras)
        let target = fixture.target(identifier: nil)
        let session = fixture.session()

        XCTAssertEqual(session.open(target: target, cachedItems: [target]), .unavailable)
    }

    func testNoMenuAndEmptyMenuAreDistinct() throws {
        let fixture = HiddenBarMenuFixture()
        let session = fixture.session()
        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
        XCTAssertTrue(try XCTUnwrap(session.page).rows.isEmpty)

        fixture.setChildren([], of: fixture.status)
        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .noMenu)
        XCTAssertNil(session.page)
        XCTAssertTrue(fixture.pressed.isEmpty)
    }

    func testDisabledAndSeparatorRowsCannotExecute() throws {
        let fixture = HiddenBarMenuFixture()
        fixture.setChildren([fixture.item("Disabled", enabled: false), fixture.node(["AXRole": "AXSeparator"])])
        let session = fixture.session()
        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)

        for row in try XCTUnwrap(session.page).rows {
            XCTAssertEqual(session.select(id: row.id), .ignored)
        }
        XCTAssertTrue(fixture.pressed.isEmpty)
    }

    func testSubmenusLoadLazilyAndPageCommandsExpire() throws {
        let fixture = HiddenBarMenuFixture()
        let child = fixture.item("Child")
        let submenu = fixture.node(["AXRole": "AXMenu", "AXChildren": [child]])
        let parent = fixture.item("Parent", submenu: submenu)
        fixture.setChildren([parent])
        let session = fixture.session()
        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
        let parentID = try XCTUnwrap(session.page?.rows.first?.id)
        XCTAssertFalse(fixture.reads.contains(ObjectIdentifier(child)))

        XCTAssertEqual(session.select(id: parentID), .updated)
        let page = try XCTUnwrap(session.page)
        XCTAssertEqual(page.title, "Parent")
        XCTAssertEqual(page.rows.first?.title, "Child")
        XCTAssertTrue(fixture.reads.contains(ObjectIdentifier(child)))
        XCTAssertEqual(session.select(id: parentID), .ignored)
        XCTAssertEqual(session.select(id: try XCTUnwrap(page.backID)), .updated)
        XCTAssertNil(session.page?.backID)
        XCTAssertNotEqual(session.page?.rows.first?.id, parentID)
        XCTAssertEqual(session.select(id: page.rows[0].id), .ignored)
    }

    func testEnabledCommandPressesOriginalElementAndCloses() throws {
        let fixture = HiddenBarMenuFixture()
        let command = fixture.item("Command")
        fixture.setChildren([command])
        let session = fixture.session()
        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
        let id = try XCTUnwrap(session.page?.rows.first?.id)

        XCTAssertEqual(session.select(id: id), .performed)
        XCTAssertTrue(try XCTUnwrap(fixture.pressed.first) === command)
        XCTAssertNil(session.page)
        XCTAssertNil(session.bundleID)
        XCTAssertEqual(session.select(id: id), .ignored)
    }

    func testEnabledStateIsRecheckedBeforePress() throws {
        let fixture = HiddenBarMenuFixture()
        let command = fixture.item("Command")
        fixture.setChildren([command])
        let session = fixture.session()
        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
        let id = try XCTUnwrap(session.page?.rows.first?.id)
        fixture.attributes[ObjectIdentifier(command)]?["AXEnabled"] = false

        XCTAssertEqual(session.select(id: id), .ignored)
        XCTAssertTrue(fixture.pressed.isEmpty)
    }

    func testChangedOwnerAndPIDRejectExecution() throws {
        for ownerChanges in [true, false] {
            let fixture = HiddenBarMenuFixture()
            fixture.setChildren([fixture.item("Command")])
            let session = fixture.session()
            XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
            let id = try XCTUnwrap(session.page?.rows.first?.id)
            if ownerChanges { fixture.ownerCurrent = false } else { fixture.expectedPID = 5678 }

            XCTAssertEqual(session.select(id: id), .unavailable)
            XCTAssertNil(session.page)
            XCTAssertTrue(fixture.pressed.isEmpty)
        }
    }

    func testFailedPageReadDoesNotPublishPartialActions() {
        let fixture = HiddenBarMenuFixture()
        let command = fixture.item("Command")
        let failed = fixture.item("Failed")
        fixture.setChildren([command, failed])
        fixture.failedElement = failed
        let session = fixture.session()

        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .unavailable)
        XCTAssertTrue(session.lastOpenFailedReading)
        XCTAssertNil(session.page)
        XCTAssertNil(session.bundleID)
        XCTAssertTrue(fixture.pressed.isEmpty)
    }

    func testCloseAndReopenInvalidateOldCommands() throws {
        let fixture = HiddenBarMenuFixture()
        fixture.setChildren([fixture.item("Command")])
        let session = fixture.session()
        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
        let id = try XCTUnwrap(session.page?.rows.first?.id)
        session.close()
        XCTAssertEqual(session.select(id: id), .ignored)

        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
        XCTAssertEqual(session.select(id: id), .ignored)
        XCTAssertNotEqual(session.page?.rows.first?.id, id)
        XCTAssertTrue(fixture.pressed.isEmpty)
    }

    func testPressFailureIsReportedAndSessionClosed() throws {
        let fixture = HiddenBarMenuFixture()
        fixture.setChildren([fixture.item("Command")])
        let session = fixture.session()
        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .menu)
        fixture.pressResult = .cannotComplete

        XCTAssertEqual(session.select(id: try XCTUnwrap(session.page?.rows.first?.id)), .unavailable)
        XCTAssertNil(session.page)
    }

    func testAcquisitionWaitsForRevealedMenuAndHoldsRevealUntilSelection() async throws {
        let fixture = HiddenBarMenuFixture()
        fixture.extrasAvailable = false
        fixture.setChildren([fixture.item("Command")])
        let session = fixture.session()
        XCTAssertEqual(session.open(target: fixture.target(), cachedItems: [fixture.target()]), .unavailable)
        let ready = AsyncStream.makeStream(of: Void.self)
        var result: HiddenBarMenuSession.OpenResult?
        var releases = 0
        session.acquire(
            target: .init(key: fixture.target().key, ownerPID: fixture.target().pid, cachedItems: [fixture.target()]),
            resolve: {
                for await _ in ready.stream { break }
                fixture.extrasAvailable = true
                return [fixture.target()]
            },
            release: { disposition in
                XCTAssertEqual(disposition, .conceal)
                releases += 1
                fixture.extrasAvailable = false
            },
            onOpen: { result = $0 }
        )
        XCTAssertEqual(session.bundleID, fixture.target().key.bundleID)
        XCTAssertNil(session.page)
        XCTAssertNil(result)
        ready.continuation.yield(())
        ready.continuation.finish()
        await until { result != nil }
        XCTAssertEqual(result, .menu)
        XCTAssertEqual(releases, 0)
        XCTAssertTrue(fixture.pressed.isEmpty)

        XCTAssertEqual(session.select(id: try XCTUnwrap(session.page?.rows.first?.id)), .performed)
        XCTAssertEqual(releases, 1)
        XCTAssertFalse(fixture.extrasAvailable)
        session.close()
        XCTAssertEqual(releases, 1)
    }

    func testClosingPendingAcquisitionReleasesAndRejectsLateCompletion() async {
        let fixture = HiddenBarMenuFixture()
        let session = fixture.session()
        let started = expectation(description: "resolution started")
        let returned = expectation(description: "resolution returned")
        var continuation: CheckedContinuation<[ResolvedMenuBarItem]?, Never>?
        var releases = 0
        session.acquire(
            target: .init(key: fixture.target().key, ownerPID: fixture.target().pid, cachedItems: [fixture.target()]),
            resolve: {
                let items = await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
                returned.fulfill()
                return items
            },
            release: { _ in releases += 1 },
            onOpen: { _ in XCTFail("closed acquisition must not publish") }
        )
        await fulfillment(of: [started], timeout: 5)
        session.close()
        XCTAssertEqual(releases, 1)
        XCTAssertNil(session.bundleID)
        continuation?.resume(returning: [fixture.target()])
        await fulfillment(of: [returned], timeout: 5)
        XCTAssertNil(session.page)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertEqual(releases, 1)
    }

    func testFailedAcquisitionReleasesWithoutReadingOrPressingAnUnverifiedItem() async {
        for replacement in [nil, [ResolvedMenuBarItem](), [HiddenBarMenuFixture().target(identifier: "other")]] {
            let fixture = HiddenBarMenuFixture()
            let session = fixture.session()
            var releases = 0
            var result: HiddenBarMenuSession.OpenResult?
            session.acquire(
                target: .init(
                    key: fixture.target().key,
                    ownerPID: fixture.target().pid,
                    cachedItems: [fixture.target()]
                ),
                resolve: { replacement },
                release: { _ in releases += 1 },
                onOpen: { result = $0 }
            )
            await until { result != nil }
            XCTAssertEqual(result, .unavailable)
            XCTAssertEqual(releases, 1)
            XCTAssertNil(session.bundleID)
            XCTAssertNil(session.page)
            XCTAssertTrue(fixture.reads.isEmpty)
            XCTAssertTrue(fixture.pressed.isEmpty)
        }
    }

    func testAcquiredItemWithoutMenuTransfersRevealToNativeFallback() async {
        let fixture = HiddenBarMenuFixture()
        fixture.setChildren([], of: fixture.status)
        let session = fixture.session()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let menuBar = FakeMenuBarAutohide()
        menuBar.preference = true
        let hold = MenuBarAutohideHold(
            system: menuBar.system,
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false)
        )
        XCTAssertTrue(hold.setMenuAccess(true))
        var releases = 0
        var result: HiddenBarMenuSession.OpenResult?
        session.acquire(
            target: .init(key: fixture.target().key, ownerPID: fixture.target().pid, cachedItems: [fixture.target()]),
            resolve: { [fixture.target()] },
            release: { disposition in
                releases += 1
                XCTAssertEqual(disposition, .nativeFallback)
                if disposition == .conceal { hold.setMenuAccess(false) }
            },
            onOpen: {
                XCTAssertFalse(menuBar.nativeAutohide)
                result = $0
            }
        )
        await until { result != nil }
        XCTAssertEqual(result, .noMenu)
        XCTAssertEqual(releases, 1)
        XCTAssertNil(session.bundleID)
        XCTAssertTrue(fixture.pressed.isEmpty)
        session.close()
        XCTAssertFalse(menuBar.nativeAutohide)
        XCTAssertEqual(releases, 1)
        XCTAssertTrue(hold.setMenuAccess(false))
        XCTAssertTrue(menuBar.nativeAutohide)
        XCTAssertEqual(menuBar.calls, [false, true])
    }

    func testUncachedFallbackAcquiresSingleFreshItemAndPublishesBeforeMenuOrNativeFallback() async {
        for hasMenu in [true, false] {
            let fixture = HiddenBarMenuFixture()
            fixture.setChildren(hasMenu ? [fixture.item("Command")] : [], of: hasMenu ? fixture.root : fixture.status)
            let session = fixture.session()
            let cache = HiddenBarIconCache()
            let target = fixture.target()
            var result: HiddenBarMenuSession.OpenResult?
            var releases = 0
            session.acquire(
                target: .init(key: target.key, ownerPID: target.pid, cachedItems: nil),
                resolve: { [target] },
                onResolve: { cache.replaceResolvedItems([target.key.bundleID: $0]) },
                release: { _ in releases += 1 },
                onOpen: {
                    XCTAssertEqual(cache.resolvedSnapshot(for: target.key.bundleID)?.map(\.key), [target.key])
                    result = $0
                }
            )
            XCTAssertEqual(session.bundleID, target.key.bundleID)
            await until { result != nil }
            XCTAssertEqual(result, hasMenu ? .menu : .noMenu)
            XCTAssertEqual(session.page?.rows.first?.title, hasMenu ? "Command" : nil)
            XCTAssertEqual(releases, hasMenu ? 0 : 1)
            XCTAssertTrue(fixture.pressed.isEmpty)
            session.close()
            XCTAssertEqual(releases, 1)
        }
    }

    func testUncachedFallbackPublishesMultipleVerifiedItemsWithoutGuessingASelection() async {
        let fixture = HiddenBarMenuFixture()
        fixture.setChildren([fixture.item("Command")])
        let other = fixture.node(["AXIdentifier": "other"])
        fixture.setChildren([fixture.status, other], of: fixture.extras)
        let fresh = [fixture.target(), fixture.target(ordinal: 1, identifier: "other")]
        let session = fixture.session()
        let cache = HiddenBarIconCache()
        var result: HiddenBarMenuSession.OpenResult?
        var releases = 0
        session.acquire(
            target: .init(key: fixture.target().key, ownerPID: fixture.target().pid, cachedItems: nil),
            resolve: { fresh },
            onResolve: { cache.replaceResolvedItems([fixture.target().key.bundleID: $0]) },
            release: { _ in releases += 1 },
            onOpen: { result = $0 }
        )
        await until { result != nil }
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(cache.resolvedSnapshot(for: fixture.target().key.bundleID)?.map(\.key), fresh.map(\.key))
        XCTAssertEqual(releases, 1)
        XCTAssertNil(session.page)
        XCTAssertTrue(fixture.reads.isEmpty)
        XCTAssertTrue(fixture.pressed.isEmpty)

        result = nil
        session.acquire(
            target: .init(
                key: fixture.target().key,
                ownerPID: fixture.target().pid,
                cachedItems: cache.resolvedSnapshot(for: fixture.target().key.bundleID)
            ),
            resolve: { fresh },
            release: { _ in releases += 1 },
            onOpen: { result = $0 }
        )
        await until { result != nil }
        XCTAssertEqual(result, .menu)
        XCTAssertEqual(session.page?.rows.first?.title, "Command")
        session.close()
        XCTAssertEqual(releases, 2)
    }

    func testUncachedFallbackRejectsEmptyResolutionAndReplacementOwnersWithoutPublishing() async {
        let fixture = HiddenBarMenuFixture()
        for fresh in [
            [ResolvedMenuBarItem](),
            [fixture.target(pid: 5678)],
            [fixture.target(bundleID: "com.example.other")],
            [fixture.target(), fixture.target(ordinal: 1, pid: 5678)]
        ] {
            let session = fixture.session()
            var result: HiddenBarMenuSession.OpenResult?
            var releases = 0
            session.acquire(
                target: .init(key: fixture.target().key, ownerPID: fixture.target().pid, cachedItems: nil),
                resolve: { fresh },
                onResolve: { _ in XCTFail("Unverified resolution must not be published") },
                release: { _ in releases += 1 },
                onOpen: { result = $0 }
            )
            await until { result != nil }
            XCTAssertEqual(result, .unavailable)
            XCTAssertEqual(releases, 1)
            XCTAssertNil(session.page)
            XCTAssertTrue(fixture.reads.isEmpty)
            XCTAssertTrue(fixture.pressed.isEmpty)
        }
    }

    func testUncachedSelectionDoesNotApplyToOtherOrdinalsOrAnExplicitEmptyCache() async {
        let fixture = HiddenBarMenuFixture()
        let cases: [(MenuBarItemKey, [ResolvedMenuBarItem]?)] = [
            (fixture.target(ordinal: 1).key, nil),
            (fixture.target().key, [])
        ]
        for (key, cachedItems) in cases {
            let session = fixture.session()
            var result: HiddenBarMenuSession.OpenResult?
            session.acquire(
                target: .init(key: key, ownerPID: fixture.target().pid, cachedItems: cachedItems),
                resolve: { [fixture.target()] },
                release: { _ in }, onOpen: { result = $0 }
            )
            await until { result != nil }
            XCTAssertEqual(result, .unavailable)
            XCTAssertNil(session.page)
            XCTAssertTrue(fixture.reads.isEmpty)
        }
    }

    func testOwnerExitingDuringAcquisitionReleasesWithoutOpening() async {
        let fixture = HiddenBarMenuFixture()
        let session = fixture.session()
        var releases = 0
        var result: HiddenBarMenuSession.OpenResult?
        session.acquire(
            target: .init(key: fixture.target().key, ownerPID: fixture.target().pid, cachedItems: [fixture.target()]),
            resolve: {
                fixture.ownerCurrent = false
                return [fixture.target()]
            },
            release: { _ in releases += 1 },
            onOpen: { result = $0 }
        )
        await until { result != nil }
        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(releases, 1)
        XCTAssertNil(session.page)
        XCTAssertTrue(fixture.reads.isEmpty)
    }
}
