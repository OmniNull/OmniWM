// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class DockBadgeReaderTests: XCTestCase {
    private final class Fixture: Sendable {
        struct State {
            var dockPID: pid_t? = 10_000
            var tiles: [pid_t] = [10_002]
            var labels: [pid_t: String] = [10_002: "3"]
            var errors: [String: AXError] = [:]
            var calls: [String: Int] = [:]
            var identityReads = 0
            var malformedLabel = false
        }

        let state = Mutex(State())

        func reader() -> DockBadgeReader {
            DockBadgeReader(
                processIdentifier: { self.state.withLock { $0.dockPID } },
                readAttribute: { self.attribute($1 as String, element: $0) },
                bundleIdentifier: { url in
                    self.state.withLock { $0.identityReads += 1 }
                    return url.deletingPathExtension().lastPathComponent
                }
            )
        }

        func attribute(_ name: String, element: AXUIElement) -> (AXError, CFTypeRef?) {
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            return state.withLock { state in
                let key = "\(pid):\(name)"
                state.calls[key, default: 0] += 1
                if let error = state.errors[key] { return (error, nil) }
                switch name {
                case kAXChildrenAttribute:
                    let children = pid == state.dockPID ? [10_001] : state.tiles
                    return (.success, children.map { AXUIElementCreateApplication($0) } as CFArray)
                case kAXRoleAttribute:
                    return (.success, kAXListRole as CFString)
                case kAXSubroleAttribute:
                    return (.success, "AXApplicationDockItem" as CFString)
                case kAXURLAttribute:
                    let bundleID = pid == 10_002 ? "app.one" : "app.two"
                    return (.success, URL(fileURLWithPath: "/Applications/\(bundleID).app") as CFURL)
                case "AXStatusLabel":
                    if state.malformedLabel { return (.success, kCFBooleanTrue) }
                    guard let label = state.labels[pid] else { return (.noValue, nil) }
                    return (.success, label as CFString)
                default:
                    return (.attributeUnsupported, nil)
                }
            }
        }

        func calls(_ name: String, pid: pid_t = 10_002) -> Int {
            state.withLock { $0.calls["\(pid):\(name)", default: 0] }
        }
    }

    func testReadsOnlyDemandedBadgesAndCachesIdentityAndElements() async {
        let fixture = Fixture()
        fixture.state.withLock {
            $0.tiles.append(10_003)
            $0.labels[10_003] = "!"
        }
        let reader = fixture.reader()

        let first = await reader.read(bundleIDs: ["app.one"], generation: 1)
        let second = await reader.read(bundleIDs: ["app.one"], generation: 1)

        XCTAssertEqual(first.labels, ["app.one": "3"])
        XCTAssertEqual(second, first)
        XCTAssertEqual(fixture.calls(kAXChildrenAttribute, pid: 10_000), 1)
        XCTAssertEqual(fixture.calls("AXStatusLabel"), 2)
        XCTAssertEqual(fixture.calls("AXStatusLabel", pid: 10_003), 0)
        XCTAssertEqual(fixture.state.withLock { $0.identityReads }, 2)
    }

    func testUnbadgedTilesStayCachedAndReportAuthoritativeClearing() async {
        let fixture = Fixture()
        let reader = fixture.reader()
        _ = await reader.read(bundleIDs: ["app.one"], generation: 1)

        for label in [nil, ""] as [String?] {
            fixture.state.withLock { $0.labels[10_002] = label }
            let result = await reader.read(bundleIDs: ["app.one"], generation: 1)
            XCTAssertEqual(result.clearedBundleIDs, ["app.one"])
            XCTAssertTrue(result.labels.isEmpty)
        }
        fixture.state.withLock { $0.errors["10002:AXStatusLabel"] = .attributeUnsupported }
        let unsupported = await reader.read(bundleIDs: ["app.one"], generation: 1)

        XCTAssertEqual(unsupported.clearedBundleIDs, ["app.one"])
        XCTAssertEqual(fixture.calls(kAXChildrenAttribute, pid: 10_000), 1)
    }

    func testSymbolicBadgeTextIsPreserved() async {
        let fixture = Fixture()
        fixture.state.withLock { $0.labels[10_002] = "•" }
        let result = await fixture.reader().read(bundleIDs: ["app.one"], generation: 1)

        XCTAssertEqual(result.labels, ["app.one": "•"])
    }

    func testResolvedBundleIdentityMatchesNormalizedBarIdentity() async {
        let fixture = Fixture()
        let reader = DockBadgeReader(
            processIdentifier: { 10_000 },
            readAttribute: { fixture.attribute($1 as String, element: $0) },
            bundleIdentifier: { _ in "App.One" }
        )
        let result = await reader.read(bundleIDs: ["app.one"], generation: 1)

        XCTAssertEqual(result.labels, ["app.one": "3"])
    }

    func testMissingTileIsClearedAndRescannedOnNextPoll() async {
        let fixture = Fixture()
        fixture.state.withLock { $0.tiles = [] }
        let reader = fixture.reader()
        let missing = await reader.read(bundleIDs: ["app.one"], generation: 1)
        fixture.state.withLock { $0.tiles = [10_002] }
        let discovered = await reader.read(bundleIDs: ["app.one"], generation: 1)

        XCTAssertEqual(missing.clearedBundleIDs, ["app.one"])
        XCTAssertEqual(discovered.labels, ["app.one": "3"])
        XCTAssertEqual(fixture.calls(kAXChildrenAttribute, pid: 10_000), 2)
    }

    func testIncompleteScanDoesNotClearUnidentifiedApp() async {
        let fixture = Fixture()
        fixture.state.withLock { $0.errors["10002:AXURL"] = .noValue }
        let reader = fixture.reader()
        let incomplete = await reader.read(bundleIDs: ["app.one"], generation: 1)
        fixture.state.withLock { $0.errors = [:] }
        let recovered = await reader.read(bundleIDs: ["app.one"], generation: 1)

        XCTAssertTrue(incomplete.labels.isEmpty)
        XCTAssertTrue(incomplete.clearedBundleIDs.isEmpty)
        XCTAssertEqual(recovered.labels, ["app.one": "3"])
    }

    func testTransientAndMalformedReadsPreservePreviousValue() async {
        let fixture = Fixture()
        let reader = fixture.reader()
        _ = await reader.read(bundleIDs: ["app.one"], generation: 1)
        for error in [AXError.failure, .cannotComplete] {
            fixture.state.withLock { $0.errors["10002:AXStatusLabel"] = error }
            let result = await reader.read(bundleIDs: ["app.one"], generation: 1)
            XCTAssertTrue(result.labels.isEmpty)
            XCTAssertTrue(result.clearedBundleIDs.isEmpty)
        }
        fixture.state.withLock {
            $0.errors = [:]
            $0.malformedLabel = true
        }
        let malformed = await reader.read(bundleIDs: ["app.one"], generation: 1)

        XCTAssertTrue(malformed.labels.isEmpty)
        XCTAssertTrue(malformed.clearedBundleIDs.isEmpty)
        XCTAssertEqual(fixture.calls(kAXChildrenAttribute, pid: 10_000), 1)
    }

    func testInvalidCachedElementTriggersOnlyOneStructuralScanPerPass() async {
        let fixture = Fixture()
        let reader = fixture.reader()
        _ = await reader.read(bundleIDs: ["app.one"], generation: 1)
        fixture.state.withLock { $0.errors["10002:AXStatusLabel"] = .invalidUIElement }
        let result = await reader.read(bundleIDs: ["app.one"], generation: 1)

        XCTAssertTrue(result.labels.isEmpty)
        XCTAssertTrue(result.clearedBundleIDs.isEmpty)
        XCTAssertEqual(fixture.calls(kAXChildrenAttribute, pid: 10_000), 2)
        XCTAssertEqual(fixture.calls("AXStatusLabel"), 3)
        XCTAssertEqual(fixture.state.withLock { $0.identityReads }, 1)
    }

    func testCannotCompleteStopsStructureScanBeforeReadingMoreTiles() async {
        let fixture = Fixture()
        fixture.state.withLock {
            $0.tiles.append(10_003)
            $0.errors["10002:AXSubrole"] = .cannotComplete
        }
        let result = await fixture.reader().read(bundleIDs: ["app.one", "app.two"], generation: 1)

        XCTAssertTrue(result.labels.isEmpty)
        XCTAssertTrue(result.clearedBundleIDs.isEmpty)
        XCTAssertEqual(fixture.calls(kAXSubroleAttribute, pid: 10_003), 0)
    }

    func testDockReplacementAndGenerationResetDropCachedElements() async {
        let fixture = Fixture()
        let reader = fixture.reader()
        _ = await reader.read(bundleIDs: ["app.one"], generation: 1)
        fixture.state.withLock { $0.dockPID = 20_000 }
        let replaced = await reader.read(bundleIDs: ["app.one"], generation: 1)
        _ = await reader.read(bundleIDs: ["app.one"], generation: 2)
        await reader.reset(generation: 1)
        _ = await reader.read(bundleIDs: ["app.one"], generation: 2)
        let stale = await reader.read(bundleIDs: ["app.one"], generation: 1)

        XCTAssertEqual(replaced.dockPID, 20_000)
        XCTAssertEqual(replaced.labels, ["app.one": "3"])
        XCTAssertEqual(fixture.calls(kAXChildrenAttribute, pid: 20_000), 2)
        XCTAssertTrue(stale.labels.isEmpty)
    }

    func testEmptyDemandDoesNotReadDockAttributes() async {
        let fixture = Fixture()
        let result = await fixture.reader().read(bundleIDs: [], generation: 1)

        XCTAssertTrue(result.labels.isEmpty)
        XCTAssertTrue(fixture.state.withLock { $0.calls.isEmpty })
    }

    func testCancelledReadDoesNotContactDock() async {
        let fixture = Fixture()
        let reader = fixture.reader()
        let task = Task { await reader.read(bundleIDs: ["app.one"], generation: 1) }
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.labels.isEmpty)
        XCTAssertTrue(fixture.state.withLock { $0.calls.isEmpty })
    }
}
