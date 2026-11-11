// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
import Combine
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import Synchronization
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    final class CommandPaletteLatencyTests: XCTestCase {
        private struct Sample {
            let shell: Bool
            let run: Int
            let typing: Bool
            let nanoseconds: UInt64
            let results: Int
        }

        private enum Failure: Error {
            case noTree(String)
        }

        private final class Stamp: Sendable {
            let value = Atomic<UInt64>(0)
        }

        @MainActor
        private final class ShellProbe {
            var quiet = false
            var onTree: (() -> Void)?
            private var republished = false

            init(_ shell: CommandPaletteShellPresenter) {
                let window = shell.onWindowChange
                let tree = shell.onTree
                shell.onWindowChange = { [weak self, unowned shell] in
                    let before = shell.published
                    window?()
                    guard let self else { return }
                    republished = republished || shell.published != before
                }
                shell.onTree = { [weak self] in
                    tree?()
                    guard let self else { return }
                    quiet = !republished
                    republished = false
                    onTree?()
                }
            }
        }

        private enum Workload: Equatable {
            case commands, menu, clipboard, unified

            var mode: CommandPaletteMode {
                switch self {
                case .commands: .commands
                case .menu: .menu
                case .clipboard,
                     .unified: .clipboard
                }
            }

            var identifier: String {
                self == .unified ? "unified" : mode.rawValue
            }

            var words: [String] {
                self == .commands ? ["focus", "move", "workspace", "column"] : ["focus", "jump", "verify", "back"]
            }
        }

        private static let runs = 12
        private static let itemCount = 200
        private static let longPreview = ProcessInfo.processInfo.environment["OMNIWM_PALETTE_LONG_PREVIEW"] == "1"
        private static let previewText: String = {
            guard longPreview else { return "Controlled selected-item preview" }
            return ClipboardHistoryPasteboard.previewText(
                String(repeating: "x", count: Int(Content().inputMaxLength))
            )
        }()

        private struct Editing {
            let panel: NSPanel
            let shell: CommandPaletteShellPresenter?
            let probe: ShellProbe?
            let editor: NSTextView
        }

        func testKeystrokeToCommit() throws {
            try benchmark(.commands)
        }

        func testMenuKeystrokeToCommit() throws {
            try benchmark(.menu)
        }

        func testClipboardKeystrokeToCommit() throws {
            try benchmark(.clipboard)
        }

        func testUnifiedKeystrokeToCommit() throws {
            try benchmark(.unified)
        }

        private func benchmark(_ workload: Workload) throws {
            var samples: [Sample] = []
            for run in 0 ..< Self.runs {
                for shell in run.isMultiple(of: 2) ? [false, true] : [true, false] {
                    samples += try measure(shell: shell, run: run, workload: workload)
                }
            }
            try report(samples, mode: workload.identifier)
        }

        private func measure(shell useShell: Bool, run: Int, workload: Workload) throws -> [Sample] {
            let menuFetched = workload == .menu
                ? expectation(description: "The controlled Menu source supplies its rows") : nil
            let fixture = fixture(workload, menuFetched: menuFetched)
            defer { fixture.cleanup() }
            let editing = try prepare(fixture, shell: useShell, workload: workload, menuFetched: menuFetched)
            let panel = editing.panel
            let shell = editing.shell
            let probe = editing.probe
            let editor = editing.editor
            var samples: [Sample] = []
            var query = ""
            for word in workload.words {
                let keys: [String?] = word.map { String($0) } + Array(repeating: nil, count: word.count)
                for letter in keys {
                    let listHeight = useShell ? nil : swiftUIListHeight(panel)
                    query = letter.map { query + $0 } ?? String(query.dropLast())
                    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    if let letter {
                        editor.insertText(letter, replacementRange: NSRange(location: NSNotFound, length: 0))
                    } else {
                        editor.deleteBackward(nil)
                    }
                    let end: UInt64
                    if let probe, let shell {
                        end = try commit(shell, probe: probe, query: query)
                    } else {
                        fixture.layout()
                        CATransaction.flush()
                        end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                        if query == String(word.prefix(1)), letter != nil {
                            XCTAssertNotEqual(
                                swiftUIListHeight(panel),
                                listHeight,
                                "SwiftUI drew \(query) synchronously"
                            )
                        }
                    }
                    try drainMainQueue()
                    XCTAssertEqual(fixture.palette.searchText, query)
                    samples.append(Sample(
                        shell: useShell, run: run, typing: letter != nil, nanoseconds: end - start,
                        results: resultCount(fixture.palette, workload: workload)
                    ))
                }
            }
            return samples
        }

        private func prepare(
            _ fixture: CommandPaletteFocusFixture, shell useShell: Bool, workload: Workload,
            menuFetched: XCTestExpectation?
        ) throws -> Editing {
            try selectProfile(for: fixture)
            if workload == .unified {
                fixture.controller.settings.commandPalette.unifiedSearch = true
                fixture.controller.settings.commandPalette.searchedModes = [.clipboard, .commands]
            }
            if useShell { fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager) }
            let panel = try fixture.show(mode: workload == .unified ? nil : workload.mode)
            fixture.palette.expandResults()
            if !useShell { fixture.palette.presentation.shell?.onFailure?() }
            if let menuFetched {
                wait(for: [menuFetched], timeout: failureBound)
                XCTAssertFalse(fixture.palette.isMenuLoading)
                XCTAssertEqual(fixture.palette.filteredMenuItems.count, Self.itemCount)
            }
            let shell = fixture.palette.presentation.shell
            XCTAssertEqual(shell != nil, useShell)
            if let shell {
                let probe = ShellProbe(shell)
                try awaitPaletteTree(shell) {
                    guard shell.hasTree, shell.published?.expanded == true else { return false }
                    guard workload == .unified else { return shell.drawsPublishedList() }
                    guard let field = shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.queryKey) else {
                        return false
                    }
                    return shell.surface.text?.string(shell.surface.layout.core.content(of: field).placeholder)
                        == shell.published?.placeholder
                }
                shell.focusField(in: panel)
                shell.field.beganEditing()
                return try Editing(panel: panel, shell: shell, probe: probe, editor: XCTUnwrap(shell.field.textEditor))
            }
            let editor = try awaitEditor(panel)
            fixture.layout()
            return Editing(panel: panel, shell: nil, probe: nil, editor: editor)
        }

        func testOpenToFirstTree() throws {
            var opens: [Bool: [Double]] = [:]
            for run in 0 ..< Self.runs {
                for prewarmed in run.isMultiple(of: 2) ? [true, false] : [false, true] {
                    let fixture = CommandPaletteFocusFixture(initialMode: .commands)
                    defer { fixture.cleanup() }
                    if prewarmed {
                        fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
                        let shell = try XCTUnwrap(fixture.palette.presentation.shell)
                        try awaitPaletteTree(shell) { shell.hasTree }
                    }
                    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    _ = try fixture.show(mode: .commands)
                    let shell = try XCTUnwrap(fixture.palette.presentation.shell)
                    let stamp = Stamp()
                    let committed = expectation(description: "The engine commits the opened palette's first tree")
                    let placeholder = CommandPalettePresentation.searchPlaceholder(for: .commands)
                    let chrome = shell.onTree
                    shell.onTree = { [unowned shell] in
                        chrome?()
                        guard let field = shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.queryKey),
                              shell.surface.text?.string(shell.surface.layout.core.content(of: field).placeholder)
                              == placeholder
                        else { return }
                        shell.onTree = chrome
                        ShellLayerScene.engineQueue.async {
                            stamp.value.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
                            committed.fulfill()
                        }
                    }
                    wait(for: [committed], timeout: failureBound)
                    let elapsed = stamp.value.load(ordering: .relaxed) - start
                    if run > 0 { opens[prewarmed, default: []].append(Double(elapsed) / 1_000_000) }
                }
            }
            for (prewarmed, milliseconds) in opens.sorted(by: { $0.key && !$1.key }) {
                let record: [String: Any] = [
                    "arm": prewarmed ? "warm" : "cold", "opens": milliseconds.count,
                    "p50": percentile(milliseconds, 0.5), "p95": percentile(milliseconds, 0.95),
                    "max": milliseconds.max() ?? 0
                ]
                print("PALETTE-OPEN", String(decoding: try JSONSerialization.data(
                    withJSONObject: record, options: [.sortedKeys]
                ), as: UTF8.self))
            }
        }

        private func commit(_ shell: CommandPaletteShellPresenter, probe: ShellProbe, query: String) throws -> UInt64 {
            let stamp = Stamp()
            var committed: XCTestExpectation?
            defer { probe.onTree = nil }
            repeat {
                let tree = expectation(description: "The palette applies a tree for \(query)")
                probe.onTree = { [unowned self, unowned shell, unowned probe] in
                    probe.onTree = nil
                    if committed == nil, self.drawnQuery(shell) == query {
                        let marker = self.expectation(description: "The engine commits the tree for \(query)")
                        ShellLayerScene.engineQueue.async {
                            stamp.value.store(clock_gettime_nsec_np(CLOCK_UPTIME_RAW), ordering: .relaxed)
                            marker.fulfill()
                        }
                        committed = marker
                    }
                    tree.fulfill()
                }
                guard XCTWaiter().wait(for: [tree], timeout: failureBound) == .completed else {
                    throw Failure.noTree(query)
                }
            } while committed == nil || !probe.quiet
            guard let committed, XCTWaiter().wait(for: [committed], timeout: failureBound) == .completed else {
                throw Failure.noTree(query)
            }
            return stamp.value.load(ordering: .relaxed)
        }

        private func drawnQuery(_ shell: CommandPaletteShellPresenter) -> String? {
            guard let field = shell.surface.layout.handle(forKey: CommandPaletteShellPresenter.queryKey) else {
                return nil
            }
            return shell.surface.text?.string(shell.surface.layout.core.content(of: field).text)
        }

        private func awaitEditor(_ panel: NSPanel) throws -> NSTextView {
            let editing = expectation(description: "The SwiftUI search field becomes the first responder")
            let observation = panel.publisher(for: \.firstResponder, options: [.initial, .new])
                .first { $0 is NSTextView }
                .sink { _ in editing.fulfill() }
            defer { observation.cancel() }
            wait(for: [editing], timeout: failureBound)
            return try XCTUnwrap(panel.firstResponder as? NSTextView)
        }

        private func drainMainQueue() throws {
            let drained = expectation(description: "The main queue runs the work queued before this marker")
            DispatchQueue.main.async { drained.fulfill() }
            wait(for: [drained], timeout: failureBound)
        }

        private func swiftUIListHeight(_ panel: NSPanel) -> CGFloat? {
            var pending = panel.contentView.map { [$0] } ?? []
            var list: NSScrollView?
            while let view = pending.popLast() {
                if let scroll = view as? NSScrollView, scroll.frame.width > (list?.frame.width ?? 0) {
                    list = scroll
                }
                pending += view.subviews
            }
            return list?.documentView?.frame.height
        }
    }

    extension CommandPaletteLatencyTests {
        private func fixture(_ workload: Workload, menuFetched: XCTestExpectation?) -> CommandPaletteFocusFixture {
            if workload == .commands { return CommandPaletteFocusFixture(initialMode: .commands) }
            if workload == .clipboard || workload == .unified {
                let items = clipboardItems(words: workload.words)
                return CommandPaletteFocusFixture(initialMode: .clipboard) { environment in
                    environment.clipboardItems = { _ in items }
                    environment.clipboardItemPreview = { _, _ in .text(Self.previewText) }
                    environment.observeClipboardItems = { _, _ in }
                }
            }
            let app = NSRunningApplication.current
            let element = AXUIElementCreateApplication(app.processIdentifier)
            let words = workload.words
            let menuItems = (0 ..< Self.itemCount).map { index in
                let title = words[index % words.count] + " \(index)"
                return MenuItemModel(
                    title: title, fullPath: "Tools > " + title, keyboardShortcut: nil,
                    axElement: element, parentTitles: ["Tools"]
                )
            }
            return CommandPaletteFocusFixture(initialMode: .menu) { environment in
                environment.frontmostApplication = { app }
                environment.runningApplication = { _ in app }
                environment.ownBundleIdentifier = { "org.example.palette-latency" }
                environment.fetchMenuItems = { _ in
                    menuFetched?.fulfill()
                    return menuItems
                }
            }
        }

        private func clipboardItems(words: [String]) -> [ClipboardPaletteItem] {
            let kinds: [ClipboardContentKind] = [.text, .richText, .html, .image, .fileURL, .other]
            return (0 ..< Self.itemCount).map { index in
                let title = words[index % words.count] + " \(index)"
                return ClipboardPaletteItem(
                    id: UUID(), title: title, subtitle: "Tools", kind: kinds[index % kinds.count],
                    sourceBundleIdentifier: nil, lastCopiedAt: Date(timeIntervalSince1970: Double(index)),
                    numberOfCopies: 1, byteCount: title.utf8.count, isPinned: index.isMultiple(of: words.count),
                    searchText: title, canPastePlainText: true
                )
            }
        }

        private func selectProfile(for fixture: CommandPaletteFocusFixture) throws {
            guard let profile = ProcessInfo.processInfo.environment["OMNIWM_PALETTE_PROFILE"],
                  profile != "default"
            else {
                return
            }
            let manager = fixture.controller.workspaceBarManager
            let directory = manager.shellConfiguration.shellDirectory
            XCTAssertEqual(try ShellStyleFixture.prepare(into: directory), [])
            XCTAssertTrue(try ShellProfiles.select(profile, in: directory))
            manager.shellConfigurationSaved(ShellConfig.resolve(shellDirectory: directory))
        }

        private func resultCount(_ palette: CommandPaletteController, workload: Workload) -> Int {
            if workload == .unified { return palette.unifiedResults.selectionOrder.count }
            return switch workload.mode {
            case .commands: palette.filteredCommandItems.count
            case .menu: palette.filteredMenuItems.count
            case .clipboard: palette.filteredClipboardItems.count
            default: 0
            }
        }

        private func percentile(_ values: [Double], _ fraction: Double) -> Double {
            let ordered = values.sorted()
            let position = Double(ordered.count - 1) * fraction
            let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
            return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - Double(lower))
        }

        private func report(_ samples: [Sample], mode: String) throws {
            #if DEBUG
                let build = "Debug"
            #else
                let build = "Release"
            #endif
            for shell in [false, true] {
                let arm = samples.filter { $0.shell == shell }
                let later = arm.filter { $0.run > 0 }
                let sets: [(String, [Sample])] = [
                    ("firstRun", arm.filter { $0.run == 0 }),
                    ("pooled", later),
                    ("typing", later.filter(\.typing)),
                    ("deleting", later.filter { !$0.typing })
                ]
                for (label, set) in sets {
                    let milliseconds = set.map { Double($0.nanoseconds) / 1_000_000 }
                    let record: [String: Any] = [
                        "arm": shell ? "omnishell" : "swiftui", "set": label, "build": build, "keys": set.count,
                        "mode": mode,
                        "profile": ProcessInfo.processInfo.environment["OMNIWM_PALETTE_PROFILE"] ?? "default",
                        "preview": mode == "clipboard" ? (Self.longPreview ? "maximum" : "short") : "none",
                        "previewCharacters": mode == "clipboard" ? Self.previewText.count : 0,
                        "p50": percentile(milliseconds, 0.5), "p95": percentile(milliseconds, 0.95),
                        "p99": percentile(milliseconds, 0.99), "max": milliseconds.max() ?? 0,
                        "resultsMax": set.map(\.results).max() ?? 0
                    ]
                    print("PALETTE-LATENCY", String(decoding: try JSONSerialization.data(
                        withJSONObject: record, options: [.sortedKeys]
                    ), as: UTF8.self))
                }
                for run in 1 ..< Self.runs {
                    let milliseconds = arm.filter { $0.run == run }.map { Double($0.nanoseconds) / 1_000_000 }
                    print("PALETTE-LATENCY-RUN", shell ? "omnishell" : "swiftui", run, percentile(milliseconds, 0.95))
                }
            }
        }
    }
#endif
