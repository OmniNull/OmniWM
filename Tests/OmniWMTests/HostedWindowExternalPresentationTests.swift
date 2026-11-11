// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class HostedWindowExternalPresentationTests: XCTestCase {
    func testExternalPaletteOverviewAndMarksKeepTheirExistingFallbacks() throws {
        let fixture = try HostedPresentationFixture()
        defer { fixture.close() }
        let external = try fixture.addExternal()
        let process = NSRunningApplication.current
        let nativeTitle = AXWindowService.titlePreferFast(windowId: UInt32(external.windowId)) ?? ""
        let item = try XCTUnwrap(CommandPaletteSearch.buildWindowItems(from: fixture.controller).first)
        XCTAssertEqual(item.id, external.token)
        XCTAssertEqual(item.title, nativeTitle)
        XCTAssertEqual(item.appName, process.localizedName)
        XCTAssertEqual(item.bundleIdentifier, process.bundleIdentifier)
        XCTAssertNil(item.hostedSymbol)
        var environment = OverviewEnvironment()
        var queriedTokens: [WindowToken] = []
        environment.windowTitle = { entry in
            queriedTokens.append(entry.token)
            return ""
        }
        let overview = OverviewWindowFacts(wmController: fixture.controller, environment: environment)
        let tile = overview.makeOverviewWindowData(
            for: external, preferredFrame: fixture.management.externalFrame,
            appInfoCache: fixture.controller.appInfoCache
        )
        XCTAssertEqual(queriedTokens, [external.token])
        XCTAssertEqual(tile.title, process.localizedName ?? String(localized: "Window"))
        XCTAssertEqual(tile.appName, process.localizedName)
        XCTAssertEqual(tile.appIcon?.tiffRepresentation, process.icon?.tiffRepresentation)
        let markName = "external"
        XCTAssertEqual(fixture.controller.windowMarkRegistry.set(markName, for: external.token), .inserted)
        let response = IPCWindowMarkRequestExecutor(controller: fixture.controller).response(for: .list, id: markName)
        guard case let .windowMarks(result)? = response.result?.payload else {
            return XCTFail("Expected external window marks")
        }
        let mark = try XCTUnwrap(result.marks.first)
        XCTAssertEqual(mark.name, markName)
        XCTAssertEqual(mark.app.name, process.localizedName ?? "PID \(external.pid)")
        XCTAssertEqual(mark.app.bundleId, process.bundleIdentifier)
        XCTAssertEqual(mark.title, nativeTitle.isEmpty ? nil : nativeTitle)
    }
}
