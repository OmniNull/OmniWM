// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import ApplicationServices
@testable import OmniWM
import OmniWMShellCore
import Synchronization
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    final class CommandPaletteLatencyTests: XCTestCase {
        private struct Sample {
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
            case commands, menu, clipboard, unified, applications, applicationGrid, files

            var mode: CommandPaletteMode {
                switch self {
                case .commands: .commands
                case .menu: .menu
                case .clipboard,
                     .unified: .clipboard
                case .applications,
                     .applicationGrid: .applications
                case .files: .files
                }
            }

            var identifier: String {
                switch self {
                case .unified: "unified"
                case .applicationGrid: "applications-grid"
                default: mode.rawValue
                }
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
            let shell: CommandPaletteShellPresenter
            let probe: ShellProbe
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

        func testApplicationsKeystrokeToCommit() throws {
            try benchmark(.applications)
        }

        func testApplicationGridKeystrokeToCommit() throws {
            try benchmark(.applicationGrid)
        }

        func testFilesKeystrokeToCommit() throws {
            try benchmark(.files)
        }

        private func benchmark(_ workload: Workload) throws {
            var samples: [Sample] = []
            for run in 0 ..< Self.runs {
                samples += try measure(run: run, workload: workload)
            }
            try report(samples, mode: workload.identifier)
        }

        private func measure(run: Int, workload: Workload) throws -> [Sample] {
            let menuFetched = workload == .menu
                ? expectation(description: "The controlled Menu source supplies its rows") : nil
            let fixture = fixture(workload, menuFetched: menuFetched)
            defer { fixture.cleanup() }
            let editing = try prepare(fixture, workload: workload, menuFetched: menuFetched)
            let shell = editing.shell
            let probe = editing.probe
            let editor = editing.editor
            var samples: [Sample] = []
            var query = ""
            for word in workload.words {
                let keys: [String?] = word.map { String($0) } + Array(repeating: nil, count: word.count)
                for letter in keys {
                    query = letter.map { query + $0 } ?? String(query.dropLast())
                    let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                    if let letter {
                        editor.insertText(letter, replacementRange: NSRange(location: NSNotFound, length: 0))
                    } else {
                        editor.deleteBackward(nil)
                    }
                    let end = try commit(shell, probe: probe, query: query)
                    XCTAssertEqual(fixture.palette.searchText, query)
                    samples.append(Sample(
                        run: run, typing: letter != nil, nanoseconds: end - start,
                        results: resultCount(fixture.palette, workload: workload)
                    ))
                }
            }
            return samples
        }

        private func prepare(
            _ fixture: CommandPaletteFocusFixture, workload: Workload,
            menuFetched: XCTestExpectation?
        ) throws -> Editing {
            try selectProfile(for: fixture)
            if workload == .unified {
                fixture.controller.settings.commandPalette.unifiedSearch = true
                fixture.controller.settings.commandPalette.searchedModes = [.clipboard, .commands]
            }
            fixture.palette.prewarmShell(from: fixture.controller.workspaceBarManager)
            let panel = try fixture.show(mode: workload == .unified ? nil : workload.mode)
            fixture.palette.expandResults()
            if workload == .applicationGrid { fixture.palette.selectLauncherFilter(.apps) }
            if let menuFetched {
                wait(for: [menuFetched], timeout: failureBound)
                XCTAssertFalse(fixture.palette.isMenuLoading)
                XCTAssertEqual(fixture.palette.filteredMenuItems.count, Self.itemCount)
            }
            let shell = try XCTUnwrap(fixture.palette.presentation.shell)
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
            return try Editing(shell: shell, probe: probe, editor: XCTUnwrap(shell.field.textEditor))
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
                    "p99": percentile(milliseconds, 0.99),
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
    }

    extension CommandPaletteLatencyTests {
        private func fixture(_ workload: Workload, menuFetched: XCTestExpectation?) -> CommandPaletteFocusFixture {
            if workload == .commands { return CommandPaletteFocusFixture(initialMode: .commands) }
            if workload.mode == .applications { return applicationFixture(words: workload.words) }
            if workload == .files { return fileFixture(words: workload.words) }
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

        private func applicationFixture(words: [String]) -> CommandPaletteFocusFixture {
            let apps = (0 ..< Self.itemCount).map { index in
                let name = words[index % words.count] + " \(index)"
                return LauncherApplicationResult(
                    bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"),
                    bundleIdentifier: "org.example.latency\(index)",
                    displayName: name,
                    categoryName: "Utilities"
                )
            }
            return CommandPaletteFocusFixture(initialMode: .applications) { environment in
                environment.stopApplicationSearch = {}
                environment.runningApplicationForResult = { _ in nil }
                environment.submitApplicationSearch = { _, query, _, generation, publish in
                    guard !query.isEmpty else {
                        publish(generation, [
                            LauncherSection(id: .suggestions, title: "Suggestions", items: Array(apps.prefix(5))),
                            LauncherSection(id: .all, title: "Applications", items: apps)
                        ], [])
                        return
                    }
                    let matches = apps.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
                    publish(generation, [LauncherSection(id: .results, title: "Results", items: matches)], [])
                }
            }
        }

        private func fileFixture(words: [String]) -> CommandPaletteFocusFixture {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("OmniWMPaletteLatencyFiles", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = (0 ..< Self.itemCount).map { index in
                let name = words[index % words.count] + " \(index).txt"
                let url = directory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: url.path) {
                    try? Data(name.utf8).write(to: url)
                }
                return LauncherFileResult(
                    fileURL: url,
                    displayName: name,
                    kind: "Plain Text",
                    size: Int64(name.utf8.count)
                )
            }
            return CommandPaletteFocusFixture(initialMode: .files) { environment in
                environment.stopFileSearch = {}
                environment.submitFileSearch = { _, query, _, generation, publish in
                    let matches = query.isEmpty ? files
                        : files.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
                    publish(generation, [LauncherSection(
                        id: query.isEmpty ? .recents : .results,
                        title: query.isEmpty ? "Recents" : "Results",
                        items: matches
                    )])
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
            case .applications,
                 .files: palette.currentSelectionList().count
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
            let later = samples.filter { $0.run > 0 }
            let sets: [(String, [Sample])] = [
                ("firstRun", samples.filter { $0.run == 0 }),
                ("pooled", later),
                ("typing", later.filter(\.typing)),
                ("deleting", later.filter { !$0.typing })
            ]
            for (label, set) in sets {
                let milliseconds = set.map { Double($0.nanoseconds) / 1_000_000 }
                let record: [String: Any] = [
                    "arm": "omnishell", "set": label, "build": build, "keys": set.count,
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
                let milliseconds = samples.filter { $0.run == run }.map { Double($0.nanoseconds) / 1_000_000 }
                let record: [String: Any] = [
                    "arm": "omnishell", "mode": mode, "run": run,
                    "profile": ProcessInfo.processInfo.environment["OMNIWM_PALETTE_PROFILE"] ?? "default",
                    "p50": percentile(milliseconds, 0.5), "p95": percentile(milliseconds, 0.95),
                    "p99": percentile(milliseconds, 0.99)
                ]
                print("PALETTE-LATENCY-RUN", String(decoding: try JSONSerialization.data(
                    withJSONObject: record, options: [.sortedKeys]
                ), as: UTF8.self))
            }
        }
    }
#endif
