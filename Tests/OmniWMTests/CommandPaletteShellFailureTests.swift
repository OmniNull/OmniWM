// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Combine
@testable import OmniWM
import XCTest

@MainActor
final class CommandPaletteShellFailureTests: XCTestCase {
    func testBundledRenderFailureStopsAndRetiresItsBitmapsWithoutAnotherFallback() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("widgets/\(ShellWidgetHost.commandPaletteWidget)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("init.luau")
        try """
        function render(ctx) return ui.row{} end
        function popout(ctx)
            local m = ctx.data.commandPalette
            if m and string.sub(m.query, 1, 4) == "fail" then error("terminal palette fixture") end
            return ui.column{ ui.input{ key = "query", text = if m then m.query else "" } }
        end
        """.write(to: script, atomically: true, encoding: .utf8)
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        let source = try ShellWidgetSourceLoader.build(.init(
            name: ShellWidgetHost.commandPaletteWidget, shellDirectory: root, sourceURL: script,
            directories: [root], profile: ShellDefaults.profile
        ))
        var fallbackRequests = 0
        let shell = CommandPaletteShellPresenter(
            source: ShellCommandPaletteSource(
                config: ShellConfig(), bundled: true, fingerprint: [:], source: source, directories: [],
                resources: resources, permissions: ShellNetworkPermissions()
            ),
            scale: 1,
            fieldFrame: CGRect(
                x: 0,
                y: 0,
                width: CommandPalettePanel.width,
                height: CommandPalettePanel.searchFieldHeight
            )
        ) {
            fallbackRequests += 1
            return nil
        }
        defer { shell.close() }
        try awaitPaletteTree(shell) { shell.hasTree }
        let image = try XCTUnwrap(CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        let bitmap = shell.registerBitmap(image, key: "terminal-fixture")
        XCTAssertNotNil(resources.bitmap(bitmap))
        var terminalFailures = 0
        let terminal = expectation(description: "The bundled renderer reaches terminal failure")
        shell.onFailure = {
            terminalFailures += 1
            terminal.fulfill()
        }
        var data = ShellCommandPaletteData()
        data.open = true
        for attempt in 0 ..< ShellWidgetHost.failureLimit {
            let problem = expectation(description: "The bundled renderer reports failure \(attempt)")
            shell.onProblem = { _ in problem.fulfill() }
            data.query = "fail \(attempt)"
            shell.publish(data)
            wait(for: [problem], timeout: failureBound)
            XCTAssertEqual(terminalFailures, attempt == ShellWidgetHost.failureLimit - 1 ? 1 : 0)
        }
        wait(for: [terminal], timeout: failureBound)
        XCTAssertEqual(terminalFailures, 1)
        XCTAssertEqual(fallbackRequests, 0)
        XCTAssertTrue(shell.bitmaps.isEmpty)
        XCTAssertNil(resources.bitmap(bitmap))
    }

    func testTerminalFailureClosesReleasesInputAndReopensFromTheBundledPalette() throws {
        let app = NSRunningApplication.current
        var focusRequests: [pid_t] = []
        var clipboardObserved = false
        var layoutObserved = false
        let fixture = CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
            environment.frontmostApplication = { app }
            environment.ownBundleIdentifier = { app.bundleIdentifier }
            environment.runningApplication = { pid in
                focusRequests.append(pid)
                return nil
            }
            environment.observeClipboardItems = { _, callback in clipboardObserved = callback != nil }
            environment.observeKeyboardLayout = { callback in layoutObserved = callback != nil }
        }
        defer { fixture.cleanup() }
        let panel = try fixture.show(mode: .clipboard)
        let failed = try XCTUnwrap(fixture.palette.presentation.shell)
        let target = try XCTUnwrap(fixture.palette.focusSession.restoreFocusTarget)
        XCTAssertTrue(clipboardObserved)
        XCTAssertTrue(layoutObserved)
        XCTAssertEqual(fixture.controller.focusPolicyEngine.activeLease?.owner, .commandPalette)
        let chord = try XCTUnwrap(fixture.palette.environment.paletteShortcuts().chords.first).binding
        XCTAssertTrue(fixture.controller.hotkeys.yieldsToPalette(chord))
        fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
        XCTAssertNotNil(fixture.palette.deferredShellSource)
        focusRequests.removeAll()
        try XCTUnwrap(failed.onFailure)()
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(fixture.palette.presentation.shell)
        XCTAssertNil(fixture.palette.deferredShellSource)
        XCTAssertNil(fixture.controller.focusPolicyEngine.activeLease)
        XCTAssertFalse(fixture.controller.hotkeys.yieldsToPalette(chord))
        XCTAssertFalse(clipboardObserved)
        XCTAssertFalse(layoutObserved)
        XCTAssertEqual(focusRequests, [target.app.processIdentifier])
        XCTAssertNil(fixture.palette.focusSession.restoreFocusTarget)
        XCTAssertTrue(fixture.palette.searchText.isEmpty)
        let reopenedPanel = try fixture.show(mode: .clipboard)
        let reopened = try XCTUnwrap(fixture.palette.presentation.shell)
        XCTAssertFalse(reopened === failed)
        XCTAssertTrue(reopened.fallback)
        let placeholder = CommandPalettePresentation.searchPlaceholder(for: .clipboard)
        try awaitPaletteTree(reopened) {
            guard let field = reopened.surface.layout.handle(forKey: CommandPaletteShellPresenter.queryKey) else {
                return false
            }
            return reopened.surface.text?
                .string(reopened.surface.layout.core.content(of: field).placeholder) == placeholder
        }
        let editing = expectation(description: "The rebuilt bundled query receives keyboard focus")
        let observation = reopenedPanel.publisher(for: \.firstResponder, options: [.initial, .new])
            .first { $0 is NSTextView }
            .sink { _ in editing.fulfill() }
        defer { observation.cancel() }
        wait(for: [editing], timeout: failureBound)
        try fixture.insertText("reopened")
        XCTAssertEqual(fixture.palette.searchText, "reopened")
    }

    func testTerminalFailureWhilePrewarmedDoesNotRestoreFocusAndNextOpenUsesBundled() throws {
        var focusRequests: [pid_t] = []
        let fixture = CommandPaletteFocusFixture { environment in
            environment.runningApplication = { pid in
                focusRequests.append(pid)
                return nil
            }
        }
        defer { fixture.cleanup() }
        fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
        let failed = try XCTUnwrap(fixture.palette.presentation.shell)
        let panel = try XCTUnwrap(fixture.palette.presentation.panel)
        XCTAssertFalse(panel.isVisible)
        try XCTUnwrap(failed.onFailure)()
        XCTAssertNil(fixture.palette.presentation.shell)
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertTrue(focusRequests.isEmpty)
        XCTAssertNil(fixture.controller.focusPolicyEngine.activeLease)
        _ = try fixture.show()
        let rebuilt = try XCTUnwrap(fixture.palette.presentation.shell)
        XCTAssertFalse(rebuilt === failed)
        XCTAssertTrue(rebuilt.fallback)
        try awaitPaletteTree(rebuilt) { rebuilt.hasTree }
    }

    func testAnUnavailableSourceLeavesThePanelWithoutContentOrInputOwnership() throws {
        let fixture = CommandPaletteFocusFixture()
        defer { fixture.cleanup() }
        fixture.palette.presentation.create(controller: fixture.palette)
        let panel = try XCTUnwrap(fixture.palette.presentation.panel)
        defer {
            fixture.registry.unregister(panel)
            panel.close()
            panel.contentView = nil
            panel.delegate = nil
        }
        XCTAssertFalse(fixture.palette.presentation.prepareShell(
            from: nil,
            controller: fixture.palette,
            checksFiles: false
        ))
        fixture.palette.presentation.showContent()
        XCTAssertNil(fixture.palette.presentation.shell)
        XCTAssertTrue(try XCTUnwrap(panel.contentView).subviews.isEmpty)
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(fixture.palette.isVisible)
        XCTAssertNil(fixture.controller.focusPolicyEngine.activeLease)
    }
}
