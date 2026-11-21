// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import XCTest

@MainActor
final class HostedWindowBarPresentationTests: XCTestCase {
    func testHostedGroupsUseAppIdentityAndRespectInstanceDeduplication() throws {
        let fixture = try HostedPresentationFixture()
        defer { fixture.close() }
        let notes = try [fixture.add(fixture.notes), fixture.add(fixture.notes)]
        let timer = try fixture.add(fixture.timer)
        let entries = notes + [timer]
        let projector = fixture.projector()
        let deduped = projector.items(
            entries: entries, order: Array(entries.indices), grouping: .byApp(keepsLayoutOrder: true),
            focusedToken: notes.last?.token, hiddenAppPIDs: []
        )
        XCTAssertEqual(deduped.map(\.id), [notes[0].token, timer.token])
        XCTAssertEqual(deduped.map { $0.allWindows.map(\.id) }, [notes.map(\.token), [timer.token]])
        let group = try XCTUnwrap(deduped.first)
        XCTAssertEqual(group.windowCount, notes.count)
        XCTAssertEqual(group.allWindows.map(\.id), notes.map(\.token))
        XCTAssertTrue(group.isFocused)
        XCTAssertEqual(group.allWindows.map(\.isFocused), [false, true])
        for (item, metadata) in zip(deduped, [fixture.notes, fixture.timer]) {
            XCTAssertEqual(item.appName, metadata.title)
            XCTAssertEqual(item.bundleId, NSRunningApplication.current.bundleIdentifier)
            XCTAssertEqual(item.allWindows.map(\.title), Array(repeating: metadata.title, count: item.windowCount))
            try assertHostedSymbol(item.icon, named: metadata.icon)
        }
        let individual = projector.items(
            entries: entries, order: Array(entries.indices), grouping: .individual,
            focusedToken: timer.token, hiddenAppPIDs: []
        )
        XCTAssertEqual(individual.map(\.id), entries.map(\.token))
        XCTAssertEqual(individual.map(\.windowCount), entries.map { CollectionOfOne($0).count })
        XCTAssertEqual(individual.map(\.isFocused), entries.map { $0.token == timer.token })
        for (item, entry) in zip(individual, entries) {
            let metadata = try XCTUnwrap(entry.target.hostedMetadata)
            XCTAssertEqual(item.allWindows.map(\.title), [metadata.title])
            try assertHostedSymbol(item.icon, named: metadata.icon)
        }
        let apps = fixture.controller.windowActionHandler.runningAppsWithWindows()
        XCTAssertEqual(apps.count, Set(entries.map(\.pid)).count)
        let process = try XCTUnwrap(apps.first)
        XCTAssertEqual(process.appName, NSRunningApplication.current.localizedName)
        XCTAssertEqual(process.bundleId, NSRunningApplication.current.bundleIdentifier)
    }

    func testBundleExclusionsAndOverridesRemainProcessBased() throws {
        let fixture = try HostedPresentationFixture()
        defer { fixture.close() }
        let hosted = try fixture.add(fixture.notes)
        let external = try fixture.addExternal()
        let override = try XCTUnwrap(NSImage(systemSymbolName: "star", accessibilityDescription: nil))
        let projector = fixture.projector(
            overrides: [fixture.notes.appId: "hosted.png", fixture.externalBundle: "external.png"], image: override
        )
        let options = WorkspaceBarProjectionOptions(
            deduplicateAppIcons: true, hideEmptyWorkspaces: false, showFloatingWindows: true,
            excludedBundleIDs: [fixture.notes.appId, fixture.externalBundle]
        )
        XCTAssertFalse(projector.isExcluded(hosted, options: options))
        XCTAssertTrue(projector.isExcluded(external, options: options))
        for grouping in [WorkspaceBarWindowProjector.Grouping.individual, .byApp(keepsLayoutOrder: true)] {
            let items = projector.items(
                entries: [hosted, external], order: [0, 1], grouping: grouping,
                focusedToken: nil, hiddenAppPIDs: []
            )
            let hostedItem = try XCTUnwrap(items.first { $0.id == hosted.token })
            try assertHostedSymbol(hostedItem.icon, named: fixture.notes.icon)
            let control = try XCTUnwrap(items.first { $0.id == external.token })
            XCTAssertEqual(control.appName, NSRunningApplication.current.localizedName)
            XCTAssertEqual(control.bundleId, fixture.externalBundle)
            XCTAssertTrue(control.icon === override)
            let nativeTitle = AXWindowService.titlePreferFast(windowId: UInt32(external.windowId)) ?? ""
            XCTAssertEqual(control.allWindows.map(\.title), [nativeTitle.isEmpty ? control.appName : nativeTitle])
        }
        if let hostBundle = NSRunningApplication.current.bundleIdentifier {
            let hostOverrides = fixture.projector(overrides: [hostBundle: "host.png"], image: override)
            let hostOptions = WorkspaceBarProjectionOptions(
                deduplicateAppIcons: false, hideEmptyWorkspaces: false, showFloatingWindows: true,
                excludedBundleIDs: [hostBundle]
            )
            XCTAssertTrue(hostOverrides.isExcluded(hosted, options: hostOptions))
            let item = try XCTUnwrap(hostOverrides.items(
                entries: [hosted], order: [0], grouping: .individual, focusedToken: nil, hiddenAppPIDs: []
            ).first)
            XCTAssertTrue(item.icon === override)
        }
    }
}
