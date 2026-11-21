// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class HostedWindowPresentationTests: XCTestCase {
    func testDeclaredPresentationBypassesNativeTitleAndLeavesProcessInfoIntact() throws {
        let fixture = try HostedPresentationFixture()
        defer { fixture.close() }
        let hosted = try fixture.add(fixture.notes)
        let external = try fixture.addExternal()
        let process = NSRunningApplication.current
        let cache = fixture.controller.appInfoCache
        var titleReads: [WindowToken] = []
        func title(_ entry: WindowState) -> String {
            titleReads.append(entry.token)
            return fixture.externalTitle
        }
        let presentation = cache.presentation(for: hosted, title: title(hosted))
        XCTAssertEqual(presentation.name, fixture.notes.title)
        XCTAssertEqual(presentation.title, fixture.notes.title)
        try assertHostedSymbol(presentation.icon, named: fixture.notes.icon)
        XCTAssertTrue(titleReads.isEmpty)
        XCTAssertTrue(cache.presentation(for: hosted).icon === presentation.icon)
        let control = cache.presentation(for: external, title: title(external))
        XCTAssertEqual(titleReads, [external.token])
        XCTAssertEqual(control.name, process.localizedName)
        XCTAssertEqual(control.title, fixture.externalTitle)
        XCTAssertEqual(control.icon?.tiffRepresentation, process.icon?.tiffRepresentation)
        XCTAssertEqual(cache.info(for: hosted.pid)?.name, process.localizedName)
        XCTAssertEqual(cache.info(for: hosted.pid)?.bundleId, process.bundleIdentifier)
        XCTAssertEqual(cache.presentation(for: external, title: "").title, "")
    }

    func testPaletteOverviewAndMarksUseTheDeclaredWindowPresentation() throws {
        let fixture = try HostedPresentationFixture()
        defer { fixture.close() }
        let entries = try [fixture.add(fixture.notes), fixture.add(fixture.timer)]
        let palette = CommandPaletteSearch.buildWindowItems(from: fixture.controller)
        var environment = OverviewEnvironment()
        environment.windowTitle = { _ in XCTFail("Hosted titles must not query native metadata")
            return nil
        }
        let overview = OverviewWindowFacts(wmController: fixture.controller, environment: environment)
        for (entry, metadata) in zip(entries, [fixture.notes, fixture.timer]) {
            let item = try XCTUnwrap(palette.first { $0.id == entry.token })
            XCTAssertEqual(item.appName, metadata.title)
            XCTAssertEqual(item.title, metadata.title)
            XCTAssertEqual(item.hostedSymbol, metadata.icon)
            XCTAssertNil(item.bundleIdentifier)
            let tile = overview.makeOverviewWindowData(
                for: entry,
                preferredFrame: nil,
                appInfoCache: fixture.controller.appInfoCache
            )
            XCTAssertEqual(tile.appName, metadata.title)
            XCTAssertEqual(tile.title, metadata.title)
            try assertHostedSymbol(tile.appIcon, named: metadata.icon)
            XCTAssertEqual(fixture.controller.windowMarkRegistry.set(metadata.appId, for: entry.token), .inserted)
        }
        let response = IPCWindowMarkRequestExecutor(controller: fixture.controller).response(for: .list, id: "marks")
        guard case let .windowMarks(result)? = response.result?.payload else {
            return XCTFail("Expected hosted window marks")
        }
        let marks = result.marks
        let query = IPCWindowQueryProjection(
            controller: fixture.controller, sessionToken: "", request: IPCQueryRequest(name: .windows),
            windowOrderedInProvider: { _ in true }
        ).result()
        for (entry, metadata) in zip(entries, [fixture.notes, fixture.timer]) {
            let mark = try XCTUnwrap(marks.first { $0.name == metadata.appId })
            XCTAssertEqual(mark.app.name, metadata.title)
            XCTAssertEqual(mark.app.bundleId, metadata.appId)
            XCTAssertEqual(mark.title, metadata.title)
            let window = try XCTUnwrap(query.windows.first { $0.windowId == entry.windowId })
            XCTAssertEqual(window.app, mark.app)
            XCTAssertEqual(window.title, mark.title)
            XCTAssertEqual(window.pid, getpid())
        }
    }

    func testSwitcherPresentsDeclaredTitlesAndIconsWithTheExactHandles() throws {
        let fixture = try HostedPresentationFixture()
        defer { fixture.close() }
        let hosted = try fixture.add(fixture.notes)
        let external = try fixture.addExternal()
        let controller = fixture.controller
        controller.settings.windowSwitcher.enabled = true
        _ = fixture.world.setManagedFocus(hosted.token, in: fixture.workspace)
        controller.commandHandler.frontmostAppPidProvider = { hosted.pid }
        controller.commandHandler.frontmostFocusedWindowTokenProvider = { hosted.token }
        let driver = OverviewPreviewTestDriver()
        let capture = driver.makeCapture(consumer: .windowSwitcher, hasCaptureAccess: { false })
        let switcher = WindowSwitcherController(controller: controller, previewCapture: capture)
        defer { switcher.shutdown()
            driver.finish()
        }
        switcher.handle(.begin(reverse: false, scope: .activeWorkspace))
        let panel = try XCTUnwrap(controller.ownedWindowRegistry.visibleWindows().first as? WindowSwitcherPanel)
        let cards = presentationSubviews(WindowSwitcherTile.self, in: try XCTUnwrap(panel.contentView))
        let card = try XCTUnwrap(cards.first { $0.handle.id == hosted.token })
        XCTAssertTrue(card.handle === fixture.world.handle(for: hosted.token))
        XCTAssertEqual(card.toolTip, fixture.notes.title)
        let labels = presentationSubviews(NSTextField.self, in: card).map(\.stringValue)
        XCTAssertTrue(labels.contains(fixture.notes.title))
        let image = try XCTUnwrap(presentationSubviews(NSImageView.self, in: card).first?.image)
        try assertHostedSymbol(image, named: fixture.notes.icon)
        let control = try XCTUnwrap(cards.first { $0.handle.id == external.token })
        let nativeTitle = AXWindowService.titlePreferFast(windowId: UInt32(external.windowId)) ?? ""
        XCTAssertEqual(
            control.toolTip,
            nativeTitle.isEmpty
                ? NSRunningApplication.current.localizedName ?? String(localized: "Window") : nativeTitle
        )
        switcher.handle(.cancel)
        XCTAssertEqual(fixture.world.nativeManagedFocusToken, hosted.token)
    }

    func testDefinitionIconReachesComponentAndRegisteredMetadata() async throws {
        let fixture = try HostedManagementFixture()
        defer { fixture.close() }
        let app = ShellAppAuthoringFixture()
        defer { try? app.remove() }
        try app.write()
        let definition = try ShellAppDefinition.load(id: app.id, folder: app.folder)
        let declaredIcon = "square.and.pencil"
        XCTAssertEqual(try definition.source().componentDescriptors.first?.icon, declaredIcon)
        XCTAssertTrue(fixture.manager.open(definition, in: fixture.source, newInstance: true))
        let session = try XCTUnwrap(fixture.manager.runtimes.values.first)
        await readyHosted(session)
        let entry = try XCTUnwrap(fixture.world.allEntries().first { $0.target.hostedMetadata != nil })
        XCTAssertEqual(entry.target.hostedMetadata?.icon, declaredIcon)
        try assertHostedSymbol(fixture.controller.appInfoCache.presentation(for: entry).icon, named: declaredIcon)
        fixture.close()
        await ShellWidgetHost.flushRetiredWork()
    }
}
