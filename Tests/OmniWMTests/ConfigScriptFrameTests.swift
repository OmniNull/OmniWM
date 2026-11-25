// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ConfigScriptFrameTests: XCTestCase {
    private static func display(_ id: UInt32, x: CGFloat) -> Monitor {
        Monitor(
            id: .init(displayId: id), displayId: id, frame: CGRect(x: x, y: 0, width: 1_200, height: 800),
            visibleFrame: CGRect(x: x, y: 70, width: 1_200, height: 705), hasNotch: false, name: "Frames \(id)"
        )
    }

    private let displays = [display(1, x: 0), display(2, x: 1_200)]
    private let start = CGRect(x: 100, y: 200, width: 500, height: 300)

    private struct Section: Equatable {
        let flags: UInt8
        let rows: UInt16
        let bytes: [UInt8]
    }

    private func sections(_ snapshot: ConfigScriptSnapshot) -> [ConfigScriptReads.RawValue: Section] {
        snapshot.withUnsafeBytes { bytes in
            var sections: [ConfigScriptReads.RawValue: Section] = [:]
            var offset = 0
            while offset < bytes.count {
                let kind = bytes[offset]
                let flags = bytes[offset + MemoryLayout<UInt8>.size]
                let rows = bytes.loadUnaligned(fromByteOffset: offset + MemoryLayout<UInt16>.size, as: UInt16.self)
                let length = bytes.loadUnaligned(fromByteOffset: offset + MemoryLayout<UInt32>.size, as: UInt32.self)
                let start = offset + MemoryLayout<UInt64>.size
                let end = start + Int(UInt32(littleEndian: length))
                sections[ConfigScriptReads.RawValue(kind)] = Section(
                    flags: flags, rows: UInt16(littleEndian: rows), bytes: Array(bytes[start ..< end])
                )
                offset = end
            }
            return sections
        }
    }

    private func rect(_ name: String, _ frame: CGRect) -> String {
        "\(name).x == \(frame.origin.x) and \(name).y == \(frame.origin.y) and " +
            "\(name).width == \(frame.size.width) and \(name).height == \(frame.size.height)"
    }

    private func float(_ id: Int, at frame: CGRect, in fixture: ConfigScriptWindowFixture) {
        let manager = fixture.base.manager
        XCTAssertTrue(manager.setWindowMode(.floating, for: fixture.base.token(id)))
        manager.updateFloatingGeometry(frame: frame, for: fixture.base.token(id))
    }

    private func frameWrites(to token: WindowToken, during body: () -> Void) -> [Substring] {
        FrameApplyTrace.shared.beginCapture()
        defer { FrameApplyTrace.shared.endCapture() }
        body()
        return FrameApplyTrace.shared.dump().split(separator: "\n").filter {
            $0.contains("win=\(token.windowId) ") && $0.contains("event=outcome=skip/contextUnavailable")
        }
    }

    private func makeFloatable(_ token: WindowToken, controller: WMController) {
        let frame = start
        controller.windowDispositionEvaluationForTests = { [weak controller] candidate in
            guard candidate == token else { return nil }
            let facts = AXWindowFacts(
                role: kAXWindowRole as String, subrole: kAXStandardWindowSubrole as String, title: "Floatable",
                hasCloseButton: true, hasFullscreenButton: true, fullscreenButtonEnabled: true, hasZoomButton: true,
                hasMinimizeButton: true, appPolicy: .regular, bundleId: "frames.floatable",
                attributeFetchSucceeded: true
            )
            return controller?.evaluateWindowDisposition(
                token: candidate, evidence: AXWindowDecisionEvidence(facts: facts, sizeConstraints: .unconstrained),
                appFullscreen: false,
                windowInfo: WindowServerInfo(
                    id: UInt32(candidate.windowId),
                    pid: candidate.pid,
                    level: 0,
                    frame: frame
                ),
                admissionGeometry: WindowAdmissionGeometryEvidence(isSizeSettable: true, frame: frame)
            )
        }
    }

    private func fields(_ frame: CGRect) -> FloatingFrameFields {
        FloatingFrameFields(x: frame.origin.x, y: frame.origin.y, width: frame.size.width, height: frame.size.height)
    }

    func testFramesAreOptInAndFollowTheCachedGeometry() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: displays)
        let base = fixture.base
        base.add([1, 2], to: base.workspace("1"))
        float(1, at: start, in: fixture)
        try await fixture.focus(1, on: "1")
        let display = displays[0]
        let tiled = CGRect(x: 10, y: 20, width: 600, height: 700)
        let moved = start.offsetBy(dx: start.width, dy: start.height)
        let rows = """
            local rows = {}
            for _, w in ctx.workspaceWindows do rows[w.id] = w end
            local a, b, m = rows['\(fixture.id(1))'], rows['\(fixture.id(2))'], ctx.monitors and ctx.monitors[1]
        """
        try await fixture.load("""
        omniwm.command('Off', function(ctx)
        \(rows)
            assert(a.frame == nil and b.frame == nil and m.frame == nil and m.visibleFrame == nil)
        end, { reads = { 'workspaceWindows', 'monitors' } })
        omniwm.command('On', function(ctx)
        \(rows)
            assert(table.isfrozen(a.frame) and \(rect("a.frame", start)) and \(rect("b.frame", tiled)))
            assert(\(rect("m.frame", display.frame)) and \(rect("m.visibleFrame", display.visibleFrame)))
            assert(ctx.truncated.workspaceWindows == false and ctx.truncated.frames == nil)
        end, { reads = { 'workspaceWindows', 'monitors', 'frames' } })
        omniwm.command('Moved', function(ctx)
        \(rows)
            assert(m == nil and \(rect("a.frame", moved)))
        end, { reads = { 'workspaceWindows', 'frames' } })
        """)
        for name in ["Off", "On", "Moved"] {
            if name == "Moved" { base.manager.updateFloatingGeometry(frame: moved, for: base.token(1)) }
            base.controller.axManager.confirmFrameWrite(for: base.token(2).windowId, frame: tiled)
            try await fixture.run(named: name)
        }
    }

    func testWindowFramesAreAbsentWhileTheWindowIsOffScreen() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        let manager = base.manager
        let controller = base.controller
        let shown = base.workspace("1")
        let other = try XCTUnwrap(manager.workspaceId(for: "3", createIfMissing: true))
        let floating = [1, 3, 4, 5, 6, 7, 9]
        base.add([1, 2, 3, 4, 5, 6, 7, 8, 10], to: shown)
        _ = WindowAdmissionTestSupport.track(base.token(9), in: other, controller: controller)
        for id in floating {
            float(id, at: start, in: fixture)
        }
        let hostedToken = WindowToken(pid: getpid(), windowId: base.token(11).windowId)
        let hosted = try XCTUnwrap(manager.addHostedWindow(
            token: hostedToken,
            metadata: .init(appId: "frames.hosted", title: "Hosted", minimumSize: start.size),
            to: shown, initialFrame: start
        ))
        XCTAssertEqual(manager.entry(for: hosted)?.mode, .tiling)
        try await fixture.focus(1, on: "1")
        try await fixture.load("""
        omniwm.command('Inspect', function(ctx)
            local rows = {}
            for _, w in ctx.windows do rows[w.id] = w end
            for _, id in { '\(fixture.id(1))', '\(fixture.id(8))' } do assert(rows[id].frame, id) end
            for _, id in { \(([2, 3, 4, 5, 6, 7, 9, 10].map { "'\(fixture.id($0))'" } + [
                "'\(ConfigScriptWindowID.string(hosted, session: controller.scriptSession.identity))'"
            ]).joined(separator: ", ")) } do
                assert(rows[id] and rows[id].frame == nil, id)
            end
        end, { reads = { 'windows', 'frames' } })
        """)
        XCTAssertTrue(manager.markNativeFullscreenSuspended(base.token(2), ownsNativeFocus: false))
        manager.setHiddenState(
            HiddenState(
                proportionalPosition: .zero,
                referenceMonitorId: displays[0].id,
                reason: .layoutTransient(.right)
            ),
            for: base.token(3)
        )
        manager.commitSpaceTopology(SpaceTopology(
            displays: [.init(displayIdentifier: String(displays[0].displayId), spaceIds: [1, 2], currentSpaceId: 1)],
            activeSpaceId: 1, fullscreenSpaceIds: [], windowSpace: [base.token(4).windowId: 2]
        ))
        XCTAssertTrue(manager.spaceTopology.isWindowOnKnownInactiveSpace(base.token(4).windowId))
        XCTAssertNil(manager.hiddenState(for: base.token(4)))
        XCTAssertTrue(manager.setWindowMinimized(true, token: base.token(5)))
        manager.setAppHidden(true, pid: base.token(6).pid, source: .ax)
        XCTAssertTrue(manager.setWindowNativeWithdrawn(true, token: base.token(7)))
        XCTAssertNil(manager.monitorIdShowingWorkspace(other))
        for id in [2, 8] {
            controller.axManager.confirmFrameWrite(for: base.token(id).windowId, frame: start)
        }
        try await fixture.run(named: "Inspect")
    }

    func testListenersSharingACaptureGetFramesOnlyOnTheListsTheyDeclared() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: displays)
        let base = fixture.base
        base.add([1, 2], to: base.workspace("1"))
        for id in [1, 2] {
            float(id, at: start, in: fixture)
        }
        try await fixture.focus(1, on: "1")
        let source = """
        omniwm.on('workspace.active', function(e)
            assert(e.workspaceWindows == nil and e.monitors[1].frame and e.monitors[1].visibleFrame)
        end, { reads = { 'monitors', 'frames' } })
        omniwm.on('workspace.active', function(e)
            assert(e.monitors == nil and #e.workspaceWindows == 2)
            for _, w in e.workspaceWindows do assert(w.frame == nil) end
        end, { reads = { 'workspaceWindows' } })
        omniwm.on('workspace.active', function(e)
            for _, w in e.windows do assert(w.frame) end
        end, { reads = { 'windows', 'frames' } })
        omniwm.on('workspace.active', function(e)
            for _, w in e.windows do assert(w.frame == nil) end
        end, { reads = { 'windows' } })
        """
        let result = try await ConfigScriptLoader().evaluate(Data(source.utf8), hyperMask: 0)
        let generation = try XCTUnwrap(result.generation)
        let shared = result.events.reduce(into: ConfigScriptReads()) { $0.formUnion($1.reads) }
        XCTAssertEqual(shared, [.monitors, .monitorFrames, .workspaceWindows, .windows, .windowFrames])
        let controller = base.controller
        let target = controller.configScriptTarget()
        var pool = ConfigScriptSnapshotPool()
        let snapshot = controller.configScriptSnapshot(reads: shared, target: target, pool: &pool)
        let unframed = controller.configScriptSnapshot(
            reads: [.monitors, .workspaceWindows, .windows], target: target, pool: &pool
        )
        let framedSections = sections(snapshot)
        let plainSections = sections(unframed)
        let workspaceWindows = ConfigScriptReads.workspaceWindows.rawValue
        XCTAssertEqual(framedSections[workspaceWindows], plainSections[workspaceWindows])
        for list in [ConfigScriptReads.windows, .monitors] {
            let framed = try XCTUnwrap(framedSections[list.rawValue])
            let plain = try XCTUnwrap(plainSections[list.rawValue])
            XCTAssertEqual(framed.flags, plain.flags | UInt8(OMNI_CONFIG_SECTION_FRAMES))
            XCTAssertEqual(framed.rows, plain.rows)
            XCTAssertGreaterThan(framed.bytes.count, plain.bytes.count)
        }
        for listener in result.events {
            _ = try await generation.invoke(
                function: listener.function, event: ConfigScriptEventPayload(name: "observed"), snapshot: snapshot
            )
        }
    }

    func testSetFloatingFrameMergesAndMovesTheWindowOntoItsDisplay() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        base.add([1], to: base.workspace("1"))
        float(1, at: start, in: fixture)
        let controller = base.controller
        let token = base.token(1)
        let visible = displays[0].visibleFrame
        func lastFrame() -> CGRect? {
            base.manager.floatingState(for: token)?.lastFrame
        }
        let full = CGRect(x: visible.midX, y: visible.midY, width: visible.width / 4, height: visible.height / 4)
        let writes = frameWrites(to: token) {
            XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(fields(full)), on: token), .executed)
        }
        XCTAssertEqual(lastFrame(), full)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.filter { $0.contains("target=\(TraceFormat.rect(full))") }.count, 1)

        let left = FloatingFrameFields(x: visible.minX, y: nil, width: nil, height: nil)
        XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(left), on: token), .executed)
        XCTAssertEqual(lastFrame(), CGRect(origin: CGPoint(x: visible.minX, y: full.minY), size: full.size))

        let pastRight = FloatingFrameFields(x: visible.maxX, y: nil, width: nil, height: nil)
        XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(pastRight), on: token), .executed)
        XCTAssertEqual(
            lastFrame(),
            CGRect(x: visible.maxX - full.width, y: full.minY, width: full.width, height: full.height)
        )

        let wide = FloatingFrameFields(x: nil, y: nil, width: visible.width * 2, height: nil)
        XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(wide), on: token), .executed)
        XCTAssertEqual(
            lastFrame(),
            CGRect(x: visible.minX, y: full.minY, width: visible.width * 2, height: full.height)
        )
    }

    func testSetFloatingFrameNeedsAStandardFloatAndABaseForPartialTables() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        let manager = base.manager
        let controller = base.controller
        base.add([1, 2], to: base.workspace("1"))
        XCTAssertTrue(manager.setWindowMode(.floating, for: base.token(1)))
        XCTAssertNil(manager.floatingState(for: base.token(1)))
        XCTAssertNil(manager.entry(for: base.token(1))?.observedState.frame)
        let visible = displays[0].visibleFrame
        let partial = FloatingFrameFields(x: visible.minX, y: nil, width: nil, height: nil)
        XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(partial), on: base.token(1)), .noChange)
        XCTAssertNil(manager.floatingState(for: base.token(1)))

        let frame = CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height / 2)
        XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(fields(frame)), on: base.token(1)), .executed)
        XCTAssertEqual(manager.floatingState(for: base.token(1))?.lastFrame, frame)

        XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(fields(frame)), on: base.token(2)), .noChange)
        XCTAssertEqual(manager.entry(for: base.token(2))?.mode, .tiling)
        XCTAssertNil(manager.floatingState(for: base.token(2)))
        XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(fields(frame)), on: base.token(3)), .notFound)
    }

    func testSetFloatingFrameLeavesAFloatMacOSIsSuppressingAlone() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        let manager = base.manager
        let controller = base.controller
        base.add([1, 2, 3], to: base.workspace("1"))
        for id in [1, 2, 3] {
            float(id, at: start, in: fixture)
        }
        XCTAssertTrue(manager.setWindowMinimized(true, token: base.token(1)))
        manager.setAppHidden(true, pid: base.token(2).pid, source: .ax)
        XCTAssertTrue(manager.setWindowNativeWithdrawn(true, token: base.token(3)))
        let visible = displays[0].visibleFrame
        let frame = CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height / 2)
        for id in [1, 2, 3] {
            let token = base.token(id)
            XCTAssertTrue(manager.isWindowSuppressedByMacOS(token))
            let writes = frameWrites(to: token) {
                XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(fields(frame)), on: token), .noChange)
            }
            XCTAssertEqual(writes, [])
            XCTAssertFalse(controller.axManager.frameLedger.forceApplyWindowIds.contains(token.windowId))
            XCTAssertEqual(manager.floatingState(for: token)?.lastFrame, start)
        }
    }

    func testAFloatOnAWorkspaceThatIsNotShownGetsItsFrameWhenShown() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        let manager = base.manager
        let controller = base.controller
        let other = try XCTUnwrap(manager.workspaceId(for: "3", createIfMissing: true))
        let token = base.token(1)
        _ = WindowAdmissionTestSupport.track(token, in: other, controller: controller)
        float(1, at: start, in: fixture)
        XCTAssertNil(manager.monitorIdShowingWorkspace(other))
        let visible = displays[0].visibleFrame
        let frame = CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height / 2)
        let writes = frameWrites(to: token) {
            XCTAssertEqual(controller.performWindowAction(.setFloatingFrame(fields(frame)), on: token), .executed)
        }
        XCTAssertEqual(manager.floatingState(for: token)?.lastFrame, frame)
        XCTAssertEqual(writes, [])
        let entry = try XCTUnwrap(manager.entry(for: token))
        let parked = HiddenState(
            proportionalPosition: .zero,
            referenceMonitorId: displays[0].id,
            reason: .workspaceInactive
        )
        let reveal = controller.layoutRefreshController.restoreWindowFromHiddenState(
            entry, monitor: displays[0], hiddenState: parked
        )
        guard case let .asyncFrame(revealed) = reveal
        else { return XCTFail("A parked float reveals its floating frame") }
        XCTAssertEqual(revealed, frame)
    }

    func testToggleFloatingThenSetFloatingFrameRunInOrderFromOneCallback() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        let base = fixture.base
        base.add([1, 2], to: base.workspace("1"))
        makeFloatable(base.token(1), controller: base.controller)
        try await fixture.focus(1, on: "1")
        let visible = displays[0].visibleFrame
        let frame = CGRect(x: visible.minX, y: visible.minY, width: visible.width / 2, height: visible.height / 2)
        try await fixture.inspect([
            "omniwm.dispatch('window', 'toggle-floating', ctx.windowId)",
            "omniwm.dispatch('window', 'set-floating-frame', ctx.windowId, " +
                "{ x = \(frame.minX), y = \(frame.minY), width = \(frame.width), height = \(frame.height) })"
        ], reads: [])
        XCTAssertEqual(base.manager.entry(for: base.token(1))?.mode, .floating)
        XCTAssertEqual(base.manager.floatingState(for: base.token(1))?.lastFrame, frame)
    }

    func testTheRecipesCenterAndSnapOnlyTheFocusedFloatingWindow() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: displays)
        let base = fixture.base
        let manager = base.manager
        base.add([1, 2], to: base.workspace("2"))
        let area = displays[1].visibleFrame
        float(1, at: CGRect(origin: area.origin, size: start.size), in: fixture)
        try await fixture.focus(1, on: "2")
        try await fixture.load([
            ConfigScriptWindowFixture.recipe("Center a floating window"),
            ConfigScriptWindowFixture.recipe("Snap a floating window to halves and quarters")
        ].joined(separator: "\n"))
        func lastFrame() -> CGRect? {
            manager.floatingState(for: base.token(1))?.lastFrame
        }
        try await fixture.press("Control+Option+C")
        XCTAssertEqual(lastFrame(), CGRect(
            x: area.minX + (area.width - start.width) / 2, y: area.minY + (area.height - start.height) / 2,
            width: start.width, height: start.height
        ))
        let half = CGSize(width: area.width / 2, height: area.height)
        let quarter = CGSize(width: area.width / 2, height: area.height / 2)
        let cells: [(String, CGRect)] = [
            ("Control+Option+Left Arrow", CGRect(origin: area.origin, size: half)),
            ("Control+Option+Right Arrow", CGRect(origin: CGPoint(x: area.midX, y: area.minY), size: half)),
            ("Control+Option+Q", CGRect(origin: CGPoint(x: area.minX, y: area.midY), size: quarter)),
            ("Control+Option+W", CGRect(origin: CGPoint(x: area.midX, y: area.midY), size: quarter)),
            ("Control+Option+A", CGRect(origin: area.origin, size: quarter)),
            ("Control+Option+S", CGRect(origin: CGPoint(x: area.midX, y: area.minY), size: quarter))
        ]
        for (chord, cell) in cells {
            try await fixture.press(chord)
            XCTAssertEqual(lastFrame(), cell, chord)
        }
        try await fixture.focus(2, on: "2")
        for chord in ["Control+Option+C", "Control+Option+Left Arrow"] {
            try await fixture.press(chord)
        }
        XCTAssertEqual(manager.entry(for: base.token(2))?.mode, .tiling)
        XCTAssertNil(manager.floatingState(for: base.token(2)))
    }

    func testTheFrameRecipeShortcutsAreFreeInTheDefaultSettings() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [displays[0]])
        fixture.base.controller.settings.hotkeyBindings = DefaultHotkeyBindings.all()
        let recipes = try [
            ConfigScriptWindowFixture.recipe("Center a floating window"),
            ConfigScriptWindowFixture.recipe("Snap a floating window to halves and quarters")
        ].joined(separator: "\n")
        try await fixture.load(recipes)
        XCTAssertNil(fixture.script.diagnostic)
        try await fixture.load(recipes + "\nomniwm.keymap.set('Option+Shift+L', function() end)")
        XCTAssertNotNil(fixture.script.diagnostic)
    }
}
