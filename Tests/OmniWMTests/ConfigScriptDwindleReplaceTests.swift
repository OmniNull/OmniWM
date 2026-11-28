// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptDwindleReplaceTests: XCTestCase {
    private let display = NiriGatherFixture.monitor(displayId: 1)

    private struct Row: Equatable {
        var orientation: DwindleOrientation?
        var ratio: Double
        var members: [WindowToken]
        var active: Int
    }

    private struct Unavailable: Error {}

    private func scene(windows: [Int] = [1, 2, 3, 4], tabs: (Int, into: Int)? = (4, into: 3)) async throws
        -> ConfigScriptWindowFixture
    {
        let base = try NiriGatherFixture(
            prefix: "dwindle-replace", monitors: [display],
            workspaces: [
                .init(name: "1", layoutType: .dwindle, monitor: display), .init(name: "2", monitor: display)
            ]
        )
        let fixture = ConfigScriptWindowFixture(base: base)
        let workspace = base.workspace("1")
        XCTAssertTrue(base.manager.setActiveWorkspace(workspace, on: display.id))
        guard let first = windows.first else { return fixture }
        base.add(windows, to: workspace)
        if let tabs {
            try mutate(fixture) { engine in
                XCTAssertTrue(engine.groupWindow(base.token(tabs.0), into: base.token(tabs.into), in: workspace))
            }
        }
        try await fixture.focus(first, on: "1")
        return fixture
    }

    private func startSwipe(on fixture: ConfigScriptWindowFixture) throws -> OverviewPreviewTestDriver {
        let controller = fixture.base.controller
        let frame = display.frame
        let context = try XCTUnwrap(CGContext(
            data: nil, width: Int(ceil(frame.width)), height: Int(ceil(frame.height)),
            bitsPerComponent: UInt8.bitWidth, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let wallpaper = OverviewWallpaperCache()
        wallpaper.desktopImageURL = { _ in nil }
        wallpaper.captureWallpaper = { _ in image }
        let backdrop = WorkspaceSwipeBackdrop(wallpaperCache: wallpaper)
        let driver = OverviewPreviewTestDriver()
        let timestamp = controller.animationClock.now()
        let swipe = WorkspaceSwipePresentation(
            refreshController: controller.layoutRefreshController,
            previewFactory: { controller in
                WorkspaceSwipePreview(
                    ownedWindowRegistry: controller.ownedWindowRegistry,
                    previewCapture: driver.makeCapture(consumer: .workspaceSwipe),
                    backdrop: backdrop, hasCaptureAccess: { true }, captureDisplay: { _, _ in nil }
                )
            }, mediaTimeProvider: { timestamp }
        )
        controller.layoutRefreshController.workspaceSwipe = swipe
        controller.motionPolicy.animationsEnabled = true
        let next = WorkspaceSwipePresentation.Workspace(id: fixture.base.workspace("2"), items: [])
        swipe.preparation = WorkspaceSwipePresentation.Preparation(
            monitor: display, frame: display.visibleFrame,
            source: WorkspaceSwipePresentation.Workspace(id: fixture.base.workspace("1"), items: []),
            previous: next, next: next
        )
        XCTAssertTrue(swipe.begin(axis: .horizontal, cumulative: -display.visibleFrame.width, timestamp: timestamp))
        XCTAssertNotNil(swipe.flights[display.id])
        return driver
    }

    private func mutate(_ fixture: ConfigScriptWindowFixture, _ body: (DwindleLayoutEngine) -> Void) throws {
        let engine = try XCTUnwrap(fixture.base.controller.dwindleEngine)
        fixture.base.manager.withEngineMutationScope(in: fixture.base.workspace("1")) { body(engine) }
    }

    private func rows(_ fixture: ConfigScriptWindowFixture) throws -> [Row] {
        var snapshot: DwindleLayoutSnapshot?
        try mutate(fixture) { snapshot = $0.layoutSnapshot(in: fixture.base.workspace("1")) }
        let captured = try XCTUnwrap(snapshot)
        return captured.nodes.map { node in
            let members = captured.members[node.members].map(\.token)
            return Row(
                orientation: node.orientation, ratio: Double(node.ratio), members: members,
                active: members.firstIndex { $0 == node.active } ?? 0
            )
        }
    }

    private func revision(_ fixture: ConfigScriptWindowFixture) throws -> UInt64 {
        let base = fixture.base
        var hasher = Hasher()
        hasher.combine(base.controller.scriptSession.identity.id)
        let workspace = base.workspace("1")
        let read = try XCTUnwrap(base.controller.dwindleEngine).readTree(
            in: workspace, hasher: hasher,
            admission: { base.manager.windowQueries.tiledAdmission(of: $0, in: workspace) },
            split: { _, _ in true }, leaf: { _, _ in true }
        )
        guard case let .read(_, revision) = read else { throw Unavailable() }
        return revision
    }

    private func literal(
        _ fixture: ConfigScriptWindowFixture, rows: [Row], revision: UInt64, session: ConfigScriptSession? = nil
    ) -> String {
        let base = fixture.base
        let identity = session ?? base.controller.scriptSession.identity
        let nodes = rows.map { row in
            if let orientation = row.orientation {
                return "{ kind = 'split', orientation = '\(orientation == .vertical ? "vertical" : "horizontal")', "
                    + "ratio = \(row.ratio) }"
            }
            let ids = row.members.map { "'\(ConfigScriptWindowID.string($0, session: identity))'" }
            return "{ kind = 'leaf', members = { \(ids.joined(separator: ", ")) }, active = \(row.active + 1) }"
        }
        return "{ workspaceId = '\(base.workspace("1").uuidString)', "
            + "revision = '\(String(format: "%016llX", revision))', nodes = { \(nodes.joined(separator: ", ")) } }"
    }

    private func invoke(_ body: String) async throws -> [ConfigScriptDispatch] {
        let source = "omniwm.command('Stage', function() \(body) end)"
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let vm = try XCTUnwrap(result.generation)
        let stage = try XCTUnwrap(result.namedCommands.first)
        return try await vm.invoke(function: stage.function, context: ConfigScriptContext()).commands
    }

    private func staged(_ tree: String) async throws -> ConfigScriptDwindleReplace {
        let commands = try await invoke("omniwm.dispatch('dwindle', 'replace', \(tree))")
        guard case let .dwindleReplace(replace)? = commands.first?.operation else { throw Unavailable() }
        return replace
    }

    private func swapped(_ rows: [Row]) throws -> [Row] {
        var rows = rows
        let leaves = rows.indices.filter { rows[$0].orientation == nil }
        let (first, second) = try (XCTUnwrap(leaves.first), XCTUnwrap(leaves.dropFirst().first))
        (rows[first], rows[second]) = (rows[second], rows[first])
        let root = try XCTUnwrap(rows.indices.first { rows[$0].orientation != nil })
        rows[root].ratio = DwindleSettings.splitRatioPresets[0]
        return rows
    }

    private func assertRefused(
        _ expected: DwindleTreeRefusal, _ replace: ConfigScriptDwindleReplace, in fixture: ConfigScriptWindowFixture,
        target: ConfigScriptTarget, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let base = fixture.base
        let engine = try XCTUnwrap(base.controller.dwindleEngine)
        let workspace = base.workspace("1")
        let before = try rows(fixture)
        let history = engine.layoutHistoryCounts(in: workspace)
        let refresh = base.controller.layoutRefreshController
        refresh.beginPerformanceCapture()
        XCTAssertEqual(
            base.controller.performConfigScriptDwindleReplace(replace, target: target), .refused(expected),
            file: file, line: line
        )
        XCTAssertEqual(refresh.endPerformanceCapture()?.refreshesEnqueued, 0, file: file, line: line)
        XCTAssertEqual(try rows(fixture), before, file: file, line: line)
        XCTAssertEqual(engine.layoutHistoryCounts(in: workspace).undo, history.undo, file: file, line: line)
    }

    func testTheMemberLimitMatchesTheHost() {
        XCTAssertEqual(Int(OMNI_CONFIG_DWINDLE_MEMBER_LIMIT), DwindleLayoutEngine.treeMemberLimit)
    }

    func testAReplacementAppliesOnceReadsBackAndUndoesInOneStep() async throws {
        let fixture = try await scene()
        let base = fixture.base
        let workspace = base.workspace("1")
        let original = try rows(fixture)
        let wanted = try swapped(original)
        XCTAssertNotEqual(wanted, original)
        let engine = try XCTUnwrap(base.controller.dwindleEngine)
        let history = engine.layoutHistoryCounts(in: workspace)
        let before = try revision(fixture)
        try await fixture.load("""
        omniwm.command('Replace', function()
            omniwm.dispatch('dwindle', 'replace', \(literal(fixture, rows: wanted, revision: before)))
        end)
        """)
        let refresh = base.controller.layoutRefreshController
        refresh.beginPerformanceCapture()
        let trace = base.lastTraceSequence()
        try await fixture.run(named: "Replace")
        XCTAssertEqual(refresh.endPerformanceCapture()?.refreshesEnqueued, 1)
        let lines = base.traceLines(after: trace).filter {
            !$0.contains("label=layout_build") && !$0.contains("event=dwindle_placements_resolved")
        }
        XCTAssertEqual(lines.count, 1, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.first?.contains("op=\(LayoutOperation.treeReplaced.summary)") == true, lines.joined())
        XCTAssertEqual(try rows(fixture), wanted)
        XCTAssertNotEqual(try revision(fixture), before)
        XCTAssertEqual(engine.layoutHistoryCounts(in: workspace).undo, history.undo + 1)
        let state = try XCTUnwrap(engine.existingState(for: workspace))
        XCTAssertEqual(Set(state.leafByToken.keys), Set(original.flatMap(\.members)))
        for (token, leaf) in state.leafByToken {
            XCTAssertTrue(leaf.tile?.members.contains { $0.token == token } == true)
            XCTAssertTrue(leaf.parent.map { $0.children.contains { $0 === leaf } } ?? (leaf === state.root))
        }
        XCTAssertTrue(base.controller.dwindleLayoutHandler.stepLayoutHistory(.undo, in: workspace))
        XCTAssertEqual(try rows(fixture), original)
    }

    func testAnEchoOfTheReadChangesNothing() async throws {
        let fixture = try await scene()
        let base = fixture.base
        let workspace = base.workspace("1")
        let original = try rows(fixture)
        let engine = try XCTUnwrap(base.controller.dwindleEngine)
        let history = engine.layoutHistoryCounts(in: workspace)
        try await fixture.load("""
        omniwm.command('Echo', function(ctx) omniwm.dispatch('dwindle', 'replace', assert(ctx.dwindle)) end,
            { reads = { 'dwindle' } })
        """)
        let refresh = base.controller.layoutRefreshController
        refresh.beginPerformanceCapture()
        try await fixture.run(named: "Echo")
        XCTAssertEqual(refresh.endPerformanceCapture()?.refreshesEnqueued, 0)
        XCTAssertEqual(try rows(fixture), original)
        XCTAssertEqual(engine.layoutHistoryCounts(in: workspace).undo, history.undo)
    }

    func testAChangeBetweenTheReadAndTheApplyIsStale() async throws {
        let fixture = try await scene()
        let replace = try await staged(literal(
            fixture, rows: try swapped(try rows(fixture)), revision: try revision(fixture)
        ))
        let target = fixture.base.controller.configScriptTarget()
        try mutate(fixture) { XCTAssertTrue($0.toggleOrientation(in: fixture.base.workspace("1"))) }
        try assertRefused(.staleRevision, replace, in: fixture, target: target)
    }

    func testAnotherShownWorkspaceRefuses() async throws {
        let fixture = try await scene()
        let replace = try await staged(literal(
            fixture, rows: try swapped(try rows(fixture)), revision: try revision(fixture)
        ))
        let target = fixture.base.controller.configScriptTarget()
        XCTAssertTrue(fixture.base.manager.setActiveWorkspace(fixture.base.workspace("2"), on: display.id))
        try assertRefused(.wrongWorkspace, replace, in: fixture, target: target)
    }

    func testALeftOutWindowIsAMembershipMismatch() async throws {
        let fixture = try await scene()
        var wanted = try rows(fixture)
        let group = try XCTUnwrap(wanted.firstIndex { $0.members.count > 1 })
        wanted[group].members.removeLast()
        wanted[group].active = 0
        let replace = try await staged(literal(fixture, rows: wanted, revision: try revision(fixture)))
        try assertRefused(.membership, replace, in: fixture, target: fixture.base.controller.configScriptTarget())
    }

    func testAMinimizedMemberIsIneligible() async throws {
        let fixture = try await scene()
        let replace = try await staged(literal(
            fixture, rows: try swapped(try rows(fixture)), revision: try revision(fixture)
        ))
        let target = fixture.base.controller.configScriptTarget()
        XCTAssertTrue(fixture.base.manager.setWindowMinimized(true, token: fixture.base.token(2)))
        try assertRefused(.ineligible, replace, in: fixture, target: target)
    }

    func testTheFocusedTabMustStayShown() async throws {
        let fixture = try await scene()
        try await fixture.focus(4, on: "1")
        var wanted = try rows(fixture)
        let group = try XCTUnwrap(wanted.firstIndex { $0.members.contains(fixture.base.token(4)) })
        XCTAssertEqual(wanted[group].members[wanted[group].active], fixture.base.token(4))
        wanted[group].active = try XCTUnwrap(wanted[group].members.firstIndex { $0 != fixture.base.token(4) })
        let replace = try await staged(literal(fixture, rows: wanted, revision: try revision(fixture)))
        try assertRefused(.focusConflict, replace, in: fixture, target: fixture.base.controller.configScriptTarget())
    }

    func testASplitWithOneChildIsInvalid() async throws {
        let fixture = try await scene()
        var wanted = try rows(fixture)
        wanted.removeLast()
        let replace = try await staged(literal(fixture, rows: wanted, revision: try revision(fixture)))
        try assertRefused(.invalid, replace, in: fixture, target: fixture.base.controller.configScriptTarget())
    }

    func testAnIDFromAnotherSessionIsUnknown() async throws {
        let fixture = try await scene()
        let session = fixture.base.controller.scriptSession.identity
        let replace = try await staged(literal(
            fixture, rows: try swapped(try rows(fixture)), revision: try revision(fixture),
            session: ConfigScriptSession(id: session.id &+ 1)
        ))
        try assertRefused(.unknownWindow, replace, in: fixture, target: fixture.base.controller.configScriptTarget())
    }

    func testMinimumSizesObservedBeforeDwindleCatchesUpAreChecked() async throws {
        let fixture = try await scene()
        let base = fixture.base
        let area = base.controller.layoutRefreshController.buildMonitorSnapshot(for: display).workingFrame.size
        let wanted = try swapped(try rows(fixture))
        for token in wanted.flatMap(\.members) {
            XCTAssertTrue(base.manager.setObservedSizeEvidence(ObservedSizeEvidence(minSize: area), for: token))
        }
        let engine = try XCTUnwrap(base.controller.dwindleEngine)
        XCTAssertLessThan(engine.constraints(for: base.token(1)).minSize.width, area.width)
        let replace = try await staged(literal(fixture, rows: wanted, revision: try revision(fixture)))
        try assertRefused(.doesNotFit, replace, in: fixture, target: base.controller.configScriptTarget())
    }

    func testALoneTileIsCheckedAgainstTheFrameItFills() async throws {
        let fixture = try await scene(windows: [1, 2], tabs: (2, into: 1))
        let base = fixture.base
        let gaps = base.controller.settings.gaps
        (gaps.outerGapLeft, gaps.outerGapRight) = (gaps.size, gaps.size)
        let frames = base.controller.layoutRefreshController.buildMonitorSnapshot(for: display)
        XCTAssertTrue(base.controller.resolvedDwindleSettings(for: display).singleWindowFit.usesFullscreenLayoutFrame)
        XCTAssertGreaterThan(frames.borderSafeFillFrame.width, frames.workingFrame.width)
        let minimum = CGSize(
            width: (frames.workingFrame.width + frames.borderSafeFillFrame.width) / 2,
            height: frames.workingFrame.height
        )
        for token in [1, 2].map(base.token) {
            XCTAssertTrue(base.manager.setObservedSizeEvidence(ObservedSizeEvidence(minSize: minimum), for: token))
        }
        var wanted = try rows(fixture)
        XCTAssertEqual(wanted.count, 1)
        wanted[0].members.reverse()
        wanted[0].active = try XCTUnwrap(wanted[0].members.firstIndex(of: base.token(1)))
        let replace = try await staged(literal(fixture, rows: wanted, revision: try revision(fixture)))
        XCTAssertEqual(
            base.controller.performConfigScriptDwindleReplace(replace, target: base.controller.configScriptTarget()),
            .result(.executed)
        )
        XCTAssertEqual(try rows(fixture), wanted)
    }

    func testAMemberOnAnotherDesktopIsIneligible() async throws {
        let fixture = try await scene()
        let base = fixture.base
        base.manager.commitSpaceTopology(SpaceTopology(
            displays: [.init(displayIdentifier: String(display.displayId), spaceIds: [1, 2], currentSpaceId: 1)],
            activeSpaceId: 1, fullscreenSpaceIds: [], windowSpace: [base.token(2).windowId: 2]
        ))
        XCTAssertTrue(base.manager.spaceTopology.isWindowOnKnownInactiveSpace(base.token(2).windowId))
        let replace = try await staged(literal(
            fixture, rows: try swapped(try rows(fixture)), revision: try revision(fixture)
        ))
        try assertRefused(.ineligible, replace, in: fixture, target: base.controller.configScriptTarget())
    }

    func testASwipeOnTheDisplayIsBusy() async throws {
        let fixture = try await scene()
        let replace = try await staged(literal(
            fixture, rows: try swapped(try rows(fixture)), revision: try revision(fixture)
        ))
        let target = fixture.base.controller.configScriptTarget()
        let driver = try startSwipe(on: fixture)
        defer {
            fixture.base.controller.layoutRefreshController.workspaceSwipe.cancelAll(reason: "test")
            driver.finish()
        }
        try assertRefused(.busy, replace, in: fixture, target: target)
    }

    func testAnUnlaidEmptyWorkspaceRefusesALoneSplit() async throws {
        let fixture = try await scene(windows: [], tabs: nil)
        let base = fixture.base
        let workspace = base.workspace("1")
        let engine = try XCTUnwrap(base.controller.dwindleEngine)
        XCTAssertNil(engine.existingState(for: workspace))
        var seed = Hasher()
        seed.combine(base.controller.scriptSession.identity.id)
        let request = try DwindleTreeRequest(
            workspaceId: workspace, revision: revision(fixture), preselection: nil,
            nodes: [.split(.horizontal, ratio: DwindleSettings.splitRatioPresets[0])], members: []
        )
        XCTAssertEqual(base.controller.dwindleLayoutHandler.replaceTree(request, seed: seed), .refused(.invalid))
        XCTAssertNil(engine.existingState(for: workspace))
    }

    func testAnEmptyTreeClearsAPendingPreselectInOneUndoableStep() async throws {
        let fixture = try await scene(windows: [], tabs: nil)
        let base = fixture.base
        let workspace = base.workspace("1")
        let engine = try XCTUnwrap(base.controller.dwindleEngine)
        try mutate(fixture) { XCTAssertTrue($0.setPreselection(.left, in: workspace)) }
        let history = engine.layoutHistoryCounts(in: workspace)
        let replace = try await staged(literal(fixture, rows: [], revision: try revision(fixture)))
        XCTAssertEqual(
            base.controller.performConfigScriptDwindleReplace(replace, target: base.controller.configScriptTarget()),
            .result(.executed)
        )
        XCTAssertNil(engine.existingState(for: workspace)?.preselection)
        XCTAssertEqual(engine.layoutHistoryCounts(in: workspace).undo, history.undo + 1)
        XCTAssertTrue(base.controller.dwindleLayoutHandler.stepLayoutHistory(.undo, in: workspace))
        XCTAssertEqual(engine.existingState(for: workspace)?.preselection, .left)
    }

    func testDisabledCommandsAndAnOpenOverviewRefuseFirst() async throws {
        let fixture = try await scene()
        let controller = fixture.base.controller
        let replace = try await staged(literal(
            fixture, rows: try swapped(try rows(fixture)), revision: try revision(fixture)
        ))
        let target = controller.configScriptTarget()
        controller.isEnabled = false
        XCTAssertEqual(controller.performConfigScriptDwindleReplace(replace, target: target), .result(.ignoredDisabled))
        controller.isEnabled = true
        controller.toggleOverview()
        defer { if controller.isOverviewOpen() { controller.toggleOverview() } }
        XCTAssertEqual(controller.performConfigScriptDwindleReplace(replace, target: target), .result(.ignoredOverview))
    }

    func testTheRotateRecipeTurnsEverySplitAndBack() async throws {
        let fixture = try await scene()
        fixture.base.controller.settings.hotkeyBindings = DefaultHotkeyBindings.all()
        let original = try rows(fixture)
        try await fixture.load(ConfigScriptWindowFixture.recipe("Rotate a Dwindle workspace"))
        XCTAssertNil(fixture.script.diagnostic)
        try await fixture.press("Control+Option+Shift+R")
        let turned = try rows(fixture)
        XCTAssertEqual(turned.count, original.count)
        for (after, before) in zip(turned, original) {
            XCTAssertEqual(after.orientation, before.orientation.map { $0 == .horizontal ? .vertical : .horizontal })
            XCTAssertEqual(after.ratio, before.ratio)
            XCTAssertEqual(after.members, before.members)
            XCTAssertEqual(after.active, before.active)
        }
        try await fixture.press("Control+Option+Shift+R")
        XCTAssertEqual(try rows(fixture), original)
    }

    func testTheHostRejectsMalformedTrees() async throws {
        let fixture = try await scene()
        let tree = literal(fixture, rows: try rows(fixture), revision: try revision(fixture))
        let id = fixture.id(1)
        let head = "omniwm.dispatch('dwindle', 'replace', { workspaceId = 'x', revision = '0', nodes = "
        let bodies = [
            "omniwm.dispatch('dwindle', 'replace', \(tree)) omniwm.dispatch('dwindle', 'replace', \(tree))",
            "omniwm.dispatch('dwindle', 'swap', \(tree))",
            "omniwm.dispatch('dwindle', 'replace')",
            head + "{}, extra = 1 })",
            head + "{ [2] = {} } })",
            head + "{ { kind = 'leaf', members = { '\(id)' }, active = 2 } } })",
            head + "{ { kind = 'leaf', members = {}, active = 1 } } })",
            head + "{ { kind = 'split', orientation = 'diagonal', ratio = 1 } } })",
            head + "{ { kind = 'split', orientation = 'vertical', ratio = '1' } } })",
            head + "{ { kind = 'leaf', members = { '\(id)' }, active = 1, ratio = 1 } } })",
            "omniwm.dispatch('dwindle', 'replace', \(tree.replacingOccurrences(of: "revision = '", with: "revision = 'Z")))",
            "omniwm.dispatch('dwindle', 'replace', \(tree.replacingOccurrences(of: "workspaceId = '", with: "workspaceId = 'x")))"
        ]
        for body in bodies {
            do {
                _ = try await invoke(body)
                XCTFail("Expected a staging error: \(body)")
            } catch {
                XCTAssertTrue(error is ConfigScriptError, body)
            }
        }
        _ = try await staged(tree)
    }
}
