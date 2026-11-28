// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import OmniWMAutomation
import OmniWMIPC
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptColumnTests: XCTestCase {
    private static func display(_ id: UInt32, x: CGFloat) -> Monitor {
        Monitor(
            id: .init(displayId: id), displayId: id, frame: CGRect(x: x, y: 0, width: 1_200, height: 800),
            visibleFrame: CGRect(x: x, y: 0, width: 1_200, height: 800), hasNotch: false, name: "Columns \(id)"
        )
    }

    private let displays = [display(1, x: 0), display(2, x: 1_200)]
    private let start = CGRect(x: 100, y: 200, width: 500, height: 300)
    private static let equalWidths = "Give every Niri column the same width"
    private static let appGroup = "Summon a group of apps"

    private func tab(_ id: Int, in workspace: WorkspaceDescriptor.ID, of base: NiriGatherFixture) {
        base.manager.withEngineMutationScope(in: workspace) {
            let column = base.node(id, in: workspace).flatMap(base.engine.column(of:))
            XCTAssertTrue(column.map {
                base.engine.toggleColumnTabbed($0, in: workspace, motion: .disabled, orientation: .horizontal)
            } == true)
        }
    }

    private func numbers(
        in workspaces: [WorkspaceDescriptor.ID], of base: NiriGatherFixture
    ) throws -> [WindowToken: Int] {
        try workspaces.reduce(into: [:]) { numbers, workspace in
            let summary = try XCTUnwrap(base.handler.columnSummary(for: workspace))
            numbers.merge(summary.columnIndexByToken) { first, _ in first }
        }
    }

    private func expectations(
        _ ids: [Int], numbers: [WindowToken: Int], fixture: ConfigScriptWindowFixture
    ) -> String {
        ids.map { id in
            "['\(fixture.id(id))'] = \(numbers[fixture.base.token(id)].map(String.init) ?? "false")"
        }.joined(separator: ", ")
    }

    private static func spans(_ recipe: String) -> [(chord: String, change: NiriSizeChange)] {
        recipe.matches(of: /equalize\("([^"]+)", "([^"]+)"\)/).compactMap { match in
            IPCSizeChange(token: String(match.2)).map { (String(match.1), NiriSizeChange(ipc: $0)) }
        }
    }

    private static func width(_ change: NiriSizeChange) -> ProportionalSize {
        change.primarySpanSpec(currentPixels: 0, axisSpan: 0, gaps: 0)
    }

    func testColumnsAreOptInAndNumberedLikeTheCommandLine() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: displays, layouts: [.niri, .dwindle])
        let base = fixture.base
        let manager = base.manager
        let strip = base.workspace("1")
        let other = try XCTUnwrap(manager.workspaceId(for: "3", createIfMissing: true))
        let shown = [1, 2, 3, 4, 5, 6, 7, 8]
        base.add(shown, to: strip)
        base.stack(2, onto: 1, in: strip)
        base.stack(4, onto: 3, in: strip)
        tab(3, in: strip, of: base)
        XCTAssertTrue(manager.setWindowMinimized(true, token: base.token(6)))
        XCTAssertTrue(manager.setWindowMode(.floating, for: base.token(8)))
        base.add([21], to: base.workspace("2"))
        base.add([31, 32], to: other)
        try await fixture.focus(1, on: "1")
        manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero, referenceMonitorId: displays[0].id, reason: .layoutTransient(.right)
            ),
            for: base.token(7)
        )
        let numbers = try numbers(in: [strip, other], of: base)
        XCTAssertNil(base.handler.columnSummary(for: base.workspace("2")))
        XCTAssertEqual(numbers[base.token(1)], numbers[base.token(2)])
        XCTAssertEqual(numbers[base.token(3)], numbers[base.token(4)])
        XCTAssertNotNil(numbers[base.token(7)])
        for id in [6, 8, 21] {
            XCTAssertNil(numbers[base.token(id)], "window \(id)")
        }
        let all = shown + [21, 31, 32]
        base.controller.axManager.confirmFrameWrite(for: base.token(1).windowId, frame: start)
        try await fixture.load("""
        local want = { \(expectations(all, numbers: numbers, fixture: fixture)) }
        local function check(rows, total: number)
            local count = 0
            for _, w in rows do
                assert(want[w.id] ~= nil and (w.column or false) == want[w.id], w.id)
                count += 1
            end
            assert(count == total)
        end
        omniwm.command('Off', function(ctx)
            for _, w in ctx.windows do assert(w.column == nil) end
            for _, w in ctx.workspaceWindows do assert(w.column == nil) end
        end, { reads = { 'workspaceWindows', 'windows' } })
        omniwm.command('On', function(ctx)
            check(ctx.windows, \(all.count))
            check(ctx.workspaceWindows, \(shown.count))
            assert(ctx.truncated.windows == false and ctx.truncated.columns == nil)
        end, { reads = { 'workspaceWindows', 'windows', 'columns' } })
        omniwm.command('With frames', function(ctx)
            check(ctx.windows, \(all.count))
            check(ctx.workspaceWindows, \(shown.count))
            for _, w in ctx.workspaceWindows do
                if w.id == '\(fixture.id(1))' then
                    assert(w.frame.x == \(start.minX) and w.frame.width == \(start.width))
                end
            end
        end, { reads = { 'workspaceWindows', 'windows', 'frames', 'columns' } })
        """)
        for name in ["Off", "On", "With frames"] {
            try await fixture.run(named: name)
        }
    }

    func testTheIndexNumbersLikeTheProjectionWithHeldTabsHiddenWindowsAndEdits() throws {
        let display = displays[0]
        let base = try NiriGatherFixture(
            prefix: "column-index", monitors: [display], workspaces: [.init(name: "1", monitor: display)]
        )
        let workspace = base.workspace("1")
        let engine = base.engine
        let ids = [1, 2, 3, 4, 5]
        base.add(ids, to: workspace)
        base.stack(2, onto: 1, in: workspace)
        var index = ConfigScriptColumnIndex()
        func check(_ label: String) throws {
            index.index(engine, in: workspace, windows: ids.count)
            let expected = try XCTUnwrap(base.handler.columnSummary(for: workspace)).columnIndexByToken
            for id in ids {
                let number = expected[base.token(id)].flatMap { UInt16(exactly: $0) } ?? 0
                XCTAssertEqual(index.number(of: base.token(id)), number, "\(label), window \(id)")
            }
        }
        try check("plain")
        let window = try XCTUnwrap(base.node(1, in: workspace))
        let column = try XCTUnwrap(engine.column(of: window))
        let context = NiriInteractionContext(
            workspaceId: workspace, motion: .disabled, workingFrame: base.controller.niriWorkingFrame(for: display),
            gaps: base.controller.innerGap(for: display), orientation: .horizontal
        )
        base.manager.withEngineMutationScope(in: workspace) {
            column.displayMode = .tabbed
            base.manager.withNiriViewportState(for: workspace) { state in
                XCTAssertTrue(engine.liveColumnMoveBegin(
                    windowId: window.id, windowToken: base.token(1), context: context, state: &state
                ))
            }
            engine.liveColumnMove?.heldTabs = column.windowNodes.filter { $0 !== window }
        }
        XCTAssertTrue(engine.isLiveHeldTab(base.token(2), in: workspace))
        try check("held tab")
        XCTAssertTrue(base.manager.setWindowMinimized(true, token: base.token(1)))
        let membership = engine.projectionMembership(in: workspace)
        XCTAssertFalse(membership.admits(base.token(1)) || membership.admits(base.token(2)))
        XCTAssertTrue(engine.projectedColumns(in: workspace).contains { $0.column === column && $0.windows.isEmpty })
        try check("home column with every window held or minimized")
        base.manager.withEngineMutationScope(in: workspace) {
            engine.liveColumnMove = nil
            column.displayMode = .normal
        }
        XCTAssertTrue(base.manager.setWindowMinimized(true, token: base.token(4)))
        let root = try XCTUnwrap(engine.root(for: workspace))
        _ = root.projectedColumns
        XCTAssertNotNil(root.cachedProjectedColumns)
        try check("minimized, with the projection cached")
        root.invalidateChildrenCache()
        XCTAssertNil(root.cachedProjectedColumns)
        try check("minimized, with the projection not cached")
        base.stack(5, onto: 3, in: workspace)
        try check("after an edit")
    }

    func testEveryReadMixDecodesFromItsOwnAndASharedCapture() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        let manager = base.manager
        let controller = base.controller
        let strip = base.workspace("1")
        let ids = [1, 2, 3]
        base.add(ids, to: strip)
        base.stack(2, onto: 1, in: strip)
        XCTAssertTrue(manager.setWindowMode(.floating, for: base.token(3)))
        manager.updateFloatingGeometry(frame: start, for: base.token(3))
        try await fixture.focus(1, on: "1")
        let numbers = try numbers(in: [strip], of: base)
        let names = ["workspaceWindows", "windows", "workspaces", "monitors", "placement", "focusTarget", "dwindle"]
        let words = names + ["frames", "columns"]
        let mixes = (0 ..< 1 << words.count).map { mask in
            words.indices.filter { mask & 1 << $0 != 0 }.map { words[$0] }
        }.filter { mix in
            (!mix.contains("frames") || !Set(mix).isDisjoint(with: ["workspaceWindows", "windows", "monitors"])) &&
                (!mix.contains("columns") || !Set(mix).isDisjoint(with: ["workspaceWindows", "windows"]))
        }
        let listeners = mixes.map { mix in
            let want = mix.map { "\($0) = true" }.joined(separator: ", ")
            let reads = mix.map { "'\($0)'" }.joined(separator: ", ")
            return "omniwm.on('workspace.active', function(e) check(e, { \(want) }) end, { reads = { \(reads) } })"
        }
        let nameList = names.map { "'\($0)'" }.joined(separator: ", ")
        let source = """
        local names = { \(nameList) }
        local columnOf = { \(expectations(ids, numbers: numbers, fixture: fixture)) }
        local function check(e, want)
            local declared = false
            for _, name in names do
                assert((e[name] ~= nil) == (want[name] == true and name ~= 'dwindle'), name)
                declared = declared or want[name] == true
            end
            if declared then
                for _, name in names do
                    assert(e.truncated[name] == (if want[name] then false else nil), name)
                end
            else
                assert(e.truncated == nil)
            end
            for _, list in { 'workspaceWindows', 'windows' } do
                local rows = e[list]
                if rows then
                    assert(#rows == \(ids.count), list)
                    for _, w in rows do
                        assert(w.column == (if want.columns then columnOf[w.id] or nil else nil), w.id)
                        assert((w.frame ~= nil) == (want.frames == true), w.id)
                    end
                end
            end
            for _, m in e.monitors or {} do
                assert((m.frame ~= nil) == (want.frames == true) and (m.visibleFrame ~= nil) == (want.frames == true))
            end
        end
        \(listeners.joined(separator: "\n"))
        """
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        XCTAssertEqual(result.events.count, mixes.count)
        for id in [1, 2] {
            controller.axManager.confirmFrameWrite(for: base.token(id).windowId, frame: start)
        }
        let target = controller.configScriptTarget()
        var pool = ConfigScriptSnapshotPool()
        let union = result.events.reduce(into: ConfigScriptReads()) { $0.formUnion($1.reads) }
        let shared = controller.configScriptSnapshot(reads: union, target: target, pool: &pool)
        let event = ConfigScriptEventPayload(name: "observed")
        for listener in result.events {
            let own = controller.configScriptSnapshot(reads: listener.reads, target: target, pool: &pool)
            for snapshot in [own, shared] {
                _ = try await generation.invoke(function: listener.function, event: event, snapshot: snapshot)
            }
        }
    }

    func testTheEqualWidthRecipeSizesEachColumnOnceWithoutMovingFocus() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        let manager = base.manager
        let controller = base.controller
        let strip = base.workspace("1")
        let ids = [1, 2, 3, 4, 5, 6, 7, 8]
        base.add(ids, to: strip)
        base.stack(2, onto: 1, in: strip)
        base.stack(4, onto: 3, in: strip)
        tab(3, in: strip, of: base)
        XCTAssertTrue(manager.setWindowMinimized(true, token: base.token(6)))
        XCTAssertTrue(manager.setWindowMode(.floating, for: base.token(8)))
        try await fixture.focus(5, on: "1")
        let recipe = try ConfigScriptWindowFixture.recipe(Self.equalWidths)
        let spans = Self.spans(recipe)
        XCTAssertEqual(spans.count, 2)
        try await fixture.load(recipe)
        let numbers = try numbers(in: [strip], of: base)
        let excluded = try XCTUnwrap(base.node(6, in: strip).flatMap(base.engine.column(of:)))
        let excludedWidth = excluded.width

        let result = try await ConfigScriptLoader().evaluate(Data(recipe.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        let target = controller.configScriptTarget()
        var pool = ConfigScriptSnapshotPool()
        for (binding, span) in zip(result.bindings, spans) {
            guard case let .configFunction(function) = binding.command
            else { return XCTFail("The recipe binds a function") }
            let snapshot = controller.configScriptSnapshot(reads: binding.reads, target: target, pool: &pool)
            let invocation = try await generation.invoke(function: function, target: target, snapshot: snapshot)
            let resized = invocation.commands.compactMap { dispatch -> Int? in
                guard case let .window(request) = dispatch.operation,
                      request.action == .setContainerPrimarySpan(span.change)
                else { return nil }
                return numbers[request.token]
            }
            XCTAssertEqual(invocation.commands.count, resized.count)
            XCTAssertEqual(resized.sorted(), Array(Set(numbers.values)).sorted())
        }

        let selection = manager.niriViewportState(for: strip).selectedNodeId
        for span in spans {
            try await fixture.press(span.chord)
            let widths = base.engine.projectedColumns(in: strip).map(\.column.width)
            XCTAssertEqual(widths, Array(repeating: Self.width(span.change), count: Set(numbers.values).count))
            XCTAssertEqual(excluded.width, excludedWidth)
            XCTAssertEqual(manager.nativeManagedFocusToken, base.token(5))
            XCTAssertEqual(manager.focusSessionSnapshot.pendingManagedFocus, .empty)
            XCTAssertEqual(manager.niriViewportState(for: strip).selectedNodeId, selection)
        }
    }

    func testTheEqualWidthRecipeResizesUpToTheCallbackLimitAndRefusesMore() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        let strip = base.workspace("1")
        let limit = Int(OMNI_CONFIG_COMMAND_LIMIT)
        let recipe = try ConfigScriptWindowFixture.recipe(Self.equalWidths)
        XCTAssertTrue(recipe.contains("local limit = \(limit)\n"))
        let notice = try XCTUnwrap(recipe.firstMatch(of: /wm\.notify\("([^"]+)"\)/)?.1)
        let spans = Self.spans(recipe)
        let first = try XCTUnwrap(spans.first)
        let second = try XCTUnwrap(spans.last)
        XCTAssertNotEqual(Self.width(first.change), Self.width(second.change))
        base.add(Array(1 ... limit), to: strip)
        try await fixture.focus(1, on: "1")
        try await fixture.load(recipe)
        func widths() -> [ProportionalSize] {
            base.engine.columns(in: strip).map(\.width)
        }

        try await fixture.press(first.chord)
        XCTAssertEqual(widths(), Array(repeating: Self.width(first.change), count: limit))
        XCTAssertNil(base.controller.commandHandler.scriptNotice.text)

        base.add([limit + 1], to: strip)
        let before = widths()
        XCTAssertEqual(before.count, limit + 1)
        try await fixture.press(second.chord)
        XCTAssertEqual(widths(), before)
        let shown = base.controller.commandHandler.scriptNotice
        XCTAssertEqual(shown.text, String(notice))
        shown.dismissalTimer?.fire()
    }

    func testTheAppGroupRecipeSendsOnlyItsAppsToTheSlotItsKeyToggles() async throws {
        let recipe = try ConfigScriptWindowFixture.recipe(Self.appGroup)
        let listed = try XCTUnwrap(recipe.firstMatch(of: /local chat = \{([^}]*)\}/)?.1)
            .matches(of: /"([^"]+)"/).map { String($0.1) }
        XCTAssertFalse(listed.isEmpty)
        let result = try await ConfigScriptLoader().evaluate(Data(recipe.utf8), hyperMask: 0)
        XCTAssertEqual(result.rules.map(\.rule.bundleId), listed)
        let binding = try XCTUnwrap(result.bindings.first)
        XCTAssertEqual(result.bindings.count, 1)
        guard case let .scratchpad(.toggle(slot)) = binding.command
        else { return XCTFail("The recipe's key toggles a scratchpad slot") }
        let engine = WindowRuleEngine(inputMethodBundleIds: [])
        engine.rebuild(rules: result.rules.map(\.rule))
        let unlisted = listed.joined(separator: ".")
        for bundle in listed + [unlisted] {
            let facts = WindowRuleFacts(
                appName: bundle,
                ax: AXWindowFacts(
                    role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String, title: bundle,
                    hasCloseButton: true, hasFullscreenButton: true, fullscreenButtonEnabled: true,
                    hasZoomButton: true, hasMinimizeButton: true, appPolicy: .regular,
                    bundleId: bundle, attributeFetchSucceeded: true
                ),
                sizeConstraints: nil,
                windowServer: nil
            )
            let decision = engine.decision(for: facts, token: nil, appFullscreen: false)
            XCTAssertEqual(decision.admissionHints.scratchpad?.rawValue, bundle == unlisted ? nil : slot, bundle)
        }
    }

    func testTheColumnAndGroupRecipeShortcutsAreFreeInTheDefaultSettings() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        fixture.base.controller.settings.hotkeyBindings = DefaultHotkeyBindings.all()
        let recipes = try [
            ConfigScriptWindowFixture.recipe(Self.equalWidths),
            ConfigScriptWindowFixture.recipe(Self.appGroup)
        ].joined(separator: "\n")
        try await fixture.load(recipes)
        XCTAssertNil(fixture.script.diagnostic)
        let settings = fixture.base.controller.settings
        XCTAssertNil(settings.configScriptShortcutConflicts)

        let overlapping = "Option+Shift+L"
        let chord = try XCTUnwrap(KeySymbolMapper.fromHumanReadable(overlapping))
        let saved = try XCTUnwrap(settings.hotkeyBindings.first { $0.binding.chordBinding == chord })
        try await fixture.load(recipes + "\nomniwm.keymap.set('\(overlapping)', function() end)")
        XCTAssertNil(fixture.script.diagnostic)
        XCTAssertEqual(settings.configScriptShortcutConflicts?.overrides.map(\.bindingID), [saved.id])
    }
}
