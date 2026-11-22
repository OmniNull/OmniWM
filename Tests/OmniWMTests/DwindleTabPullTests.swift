// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

extension DwindleLiveTitleBarDragTests {
    @MainActor
    struct TabPullFixture {
        let base: Fixture
        let fourth: WindowToken

        var controller: WMController {
            base.controller
        }

        var manager: WorkspaceManager {
            base.manager
        }

        var handler: MouseEventHandler {
            base.handler
        }

        var engine: DwindleLayoutEngine {
            base.engine
        }

        var workspaceId: WorkspaceDescriptor.ID {
            base.workspaceId
        }

        var pulled: WindowToken {
            base.dragged
        }

        var kept: WindowToken {
            base.tokens[0]
        }

        var target: WindowToken {
            base.neighbor
        }

        func contentFrame(index: Int, grouped: Bool) -> CGRect {
            let area = controller.insetWorkingFrame(for: base.monitor)
            let raw = CGRect(
                x: area.minX + CGFloat(index) * area.width / 2, y: area.minY,
                width: area.width / 2, height: area.height
            )
            var frame = DwindleGapCalculator.applyGaps(nodeRect: raw, tilingArea: area, settings: engine.settings)
            if grouped {
                let rail = min(controller.tabRailStyle.reservedWidth, frame.width)
                frame.origin.x += rail
                frame.size.width -= rail
            }
            return frame
        }

        func begin() throws -> CGPoint {
            let tile = try XCTUnwrap(engine.tile(containing: pulled, in: workspaceId))
            let info = try XCTUnwrap(controller.dwindleLayoutHandler.desiredTabRailInfos().first {
                $0.owner == .dwindleTile(tile.id)
            })
            let index = try XCTUnwrap(info.tabs.first(where: { $0.token == pulled })?.visualIndex)
            let frame = contentFrame(index: 0, grouped: true)
            let press = CGPoint(x: frame.minX - controller.tabRailStyle.reservedWidth / 2, y: frame.midY)
            let anchor = CGPoint(x: frame.minX + MoveConfiguration.default.dragThreshold, y: frame.midY)
            handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }
            base.report(frame)
            handler.handleTabRailDrag(TabRailDrag(
                info: info, visualIndex: index, token: pulled, location: anchor, pressLocation: press
            ))
            base.completeLayout()
            return anchor
        }

        func move(to point: CGPoint) {
            handler.dispatchMouseDragged(at: point)
            base.completeLayout()
        }

        func release(at point: CGPoint) {
            handler.pressedMouseButtonsProvider = { 0 }
            handler.dispatchMouseUp(at: point)
            base.completeLayout()
        }

        func cancel(at point: CGPoint) {
            handler.handleInputSuppressionBegan()
            handler.pressedMouseButtonsProvider = { 0 }
            handler.dispatchMouseUp(at: point)
            base.completeLayout()
        }

        func command(_ command: HotkeyCommand) {
            base.command(command)
        }

        func projection() throws -> WorkspaceLayoutDiff {
            let snapshot = try XCTUnwrap(controller.dwindleLayoutHandler.makeWorkspaceSnapshot(
                workspaceId: workspaceId, monitor: base.monitor, resolveConstraints: false, isActiveWorkspace: true
            ))
            return controller.dwindleLayoutHandler.layoutDiff(
                windows: snapshot.windows, frames: engine.currentFrames(in: workspaceId),
                context: controller.dwindleLayoutHandler.layoutDiffContext(
                    snapshot: snapshot, engine: engine, reassertHidden: true, animationTime: nil
                )
            )
        }

        func assertFloating(
            at point: CGPoint,
            anchor: CGPoint,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let scale = controller.layoutRefreshController.buildMonitorSnapshot(for: base.monitor).scale
            let expected = contentFrame(index: 0, grouped: true)
                .offsetBy(dx: point.x - anchor.x, dy: point.y - anchor.y)
                .roundedToPhysicalPixels(scale: scale)
            let diff = try projection()
            XCTAssertEqual(
                diff.frameChanges.filter { $0.token == pulled }.map(\.frame),
                [expected],
                file: file,
                line: line
            )
            XCTAssertFalse(diff.visibilityChanges.contains {
                if case let .hide(token, _) = $0 { return token == pulled }
                return false
            }, file: file, line: line)
        }

        func assertLayout(joined: Bool, file: StaticString = #filePath, line: UInt = #line) {
            let groups = joined ? [[kept], [target, fourth, pulled]] : [[kept, pulled], [target, fourth]]
            XCTAssertEqual(base.order(), groups, file: file, line: line)
            XCTAssertEqual(engine.root(for: workspaceId)?.splitOrientation, .horizontal, file: file, line: line)
            XCTAssertEqual(engine.root(for: workspaceId)?.splitRatio, 1, file: file, line: line)
            let expected = joined
                ? [kept: contentFrame(index: 0, grouped: false), pulled: contentFrame(index: 1, grouped: true)]
                : [pulled: contentFrame(index: 0, grouped: true), fourth: contentFrame(index: 1, grouped: true)]
            XCTAssertEqual(engine.currentFrames(in: workspaceId), expected, file: file, line: line)
            XCTAssertEqual(
                engine.tile(containing: pulled, in: workspaceId)?.activeToken,
                pulled,
                file: file,
                line: line
            )
            if !joined {
                XCTAssertEqual(
                    engine.tile(containing: target, in: workspaceId)?.activeToken,
                    fourth,
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(
                Set(manager.entries(in: workspaceId).map(\.token)),
                Set([kept, pulled, target, fourth]),
                file: file,
                line: line
            )
            for token in [kept, pulled, target, fourth] {
                XCTAssertEqual(manager.workspace(for: token), workspaceId, file: file, line: line)
            }
        }

        func assertTerminal(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNil(handler.liveDragSession?.carriedWindow, file: file, line: line)
            XCTAssertNil(handler.state.nativeTitleBarDrag, file: file, line: line)
            XCTAssertNil(engine.liveMoveWorkspaceId, file: file, line: line)
            XCTAssertNil(engine.interactiveMove, file: file, line: line)
            XCTAssertFalse(controller.isInteractiveGestureActive, file: file, line: line)
        }
    }

    func makeTabPullFixture() throws -> TabPullFixture {
        let base = try makeFixture()
        let fourth = WindowToken(pid: base.dragged.pid, windowId: base.tokens.count + 1)
        _ = WindowAdmissionTestSupport.track(fourth, in: base.workspaceId, controller: base.controller)
        base.manager.setCachedConstraints(.unconstrained, for: fourth)
        base.manager.withEngineMutationScope(in: base.workspaceId) {
            _ = base.engine.addWindow(token: fourth, to: base.workspaceId, activeWindowFrame: nil)
            XCTAssertTrue(base.engine.groupWindow(fourth, into: base.neighbor, in: base.workspaceId))
        }
        base.completeLayout()
        base.focus()
        return TabPullFixture(base: base, fourth: fourth)
    }

    func testDwindleRailPullJoinsOnlyThePressedMemberAndRecordsOneUndoableRelease() throws {
        let fixture = try makeTabPullFixture()
        fixture.assertLayout(joined: false)
        let anchor = try fixture.begin()
        XCTAssertEqual(fixture.handler.liveDragSession?.carriedWindow?.token, fixture.pulled)
        XCTAssertNil(fixture.handler.state.nativeTitleBarDrag)
        XCTAssertEqual(
            fixture.engine.tile(containing: fixture.kept, in: fixture.workspaceId)?.members.map(\.token),
            [fixture.kept]
        )
        try fixture.assertFloating(at: anchor, anchor: anchor)
        let point = try XCTUnwrap(fixture.engine.presentedFrame(
            for: fixture.fourth, in: fixture.workspaceId, at: fixture.controller.animationClock.now()
        )).center

        fixture.move(to: point)

        XCTAssertEqual(fixture.base.order(), [[fixture.kept], [fixture.target, fixture.fourth, fixture.pulled]])
        XCTAssertEqual(
            fixture.engine.currentFrames(in: fixture.workspaceId)[fixture.kept],
            fixture.contentFrame(index: 0, grouped: false)
        )
        try fixture.assertFloating(at: point, anchor: anchor)
        XCTAssertTrue(try fixture.projection().frameChanges.contains { $0.token == fixture.fourth })
        fixture.base.assertHistory(undo: 0, redo: 0)
        fixture.release(at: point)
        fixture.assertLayout(joined: true)
        fixture.base.assertHistory(undo: 1, redo: 0)
        fixture.assertTerminal()
        fixture.command(.sizing(.undo))
        fixture.assertLayout(joined: false)
        fixture.base.assertHistory(undo: 0, redo: 1)
        fixture.command(.sizing(.redo))
        fixture.assertLayout(joined: true)
        fixture.base.assertHistory(undo: 1, redo: 0)
    }

    func testCancellingDwindleRailPullRestoresBothGroupsAndSelectionWithoutHistory() throws {
        let fixture = try makeTabPullFixture()
        let anchor = try fixture.begin()
        let point = try XCTUnwrap(fixture.engine.presentedFrame(
            for: fixture.fourth, in: fixture.workspaceId, at: fixture.controller.animationClock.now()
        )).center
        fixture.move(to: point)
        XCTAssertEqual(fixture.base.order(), [[fixture.kept], [fixture.target, fixture.fourth, fixture.pulled]])
        try fixture.assertFloating(at: point, anchor: anchor)

        fixture.cancel(at: point)

        fixture.assertLayout(joined: false)
        fixture.base.assertHistory(undo: 0, redo: 0)
        fixture.assertTerminal()
    }

    func testDwindleRailReorderUsesRenderedItemsAndRepeatingThePointDoesNoWork() throws {
        let fixture = try makeTabPullFixture()
        let rails = fixture.controller.dwindleLayoutHandler.desiredTabRailInfos()
        let source = try XCTUnwrap(rails.first { $0.tabs.contains { $0.token == fixture.pulled } })
        let manager = fixture.controller.tabRailManager
        manager.updateRails(rails, style: fixture.controller.tabRailStyle)
        defer { manager.removeAll() }
        let window = try XCTUnwrap(manager.existingWindow(for: source.key) as? TabRailWindow)
        let view = try XCTUnwrap(window.contentView as? TabRailView)
        let layout = TabRailLayout(
            tabCount: source.tabCount, bounds: view.bounds,
            activeVisualIndex: source.activeVisualIndex, scale: window.backingScaleFactor
        )
        let targetItem = try XCTUnwrap(layout.items.first { $0.visualIndex == 0 })
        let pressedItem = try XCTUnwrap(layout.items.first { $0.visualIndex == 1 })
        let point = CGPoint(
            x: window.appliedFrame.minX + targetItem.pillRect.midX,
            y: window.appliedFrame.minY + targetItem.pillRect.midY
        )
        let press = CGPoint(
            x: window.appliedFrame.minX + pressedItem.pillRect.midX,
            y: window.appliedFrame.minY + pressedItem.pillRect.midY
        )
        XCTAssertGreaterThanOrEqual(
            hypot(point.x - press.x, point.y - press.y),
            MoveConfiguration.default.dragThreshold
        )
        XCTAssertEqual(manager.dragTarget(at: point)?.token, fixture.kept)
        XCTAssertEqual(manager.dragTarget(at: point)?.visualIndex, 0)
        XCTAssertTrue(manager.acceptsDrags(source))
        fixture.handler.pressedMouseButtonsProvider = { MouseEventHandler.MouseButton.left.pressedMask }

        manager.onDrag?(TabRailDrag(
            info: source,
            visualIndex: 1,
            token: fixture.pulled,
            location: point,
            pressLocation: press
        ))
        fixture.base.completeLayout()

        XCTAssertEqual(fixture.base.order(), [[fixture.pulled, fixture.kept], [fixture.target, fixture.fourth]])
        try fixture.assertFloating(at: point, anchor: point)
        fixture.base.assertHistory(undo: 0, redo: 0)
        let sequence = fixture.manager.worldSeq
        fixture.handler.dispatchMouseDragged(at: point)
        XCTAssertEqual(fixture.manager.worldSeq, sequence)
        XCTAssertEqual(fixture.base.order(), [[fixture.pulled, fixture.kept], [fixture.target, fixture.fourth]])
        fixture.release(at: point)
        fixture.base.assertHistory(undo: 1, redo: 0)
        fixture.assertTerminal()
        fixture.command(.sizing(.undo))
        fixture.assertLayout(joined: false)
        fixture.base.assertHistory(undo: 0, redo: 1)
    }

    func testDwindleRailPullRefusesStaleAndFullscreenOwnersWithoutMutatingGroups() throws {
        for fullscreen in [false, true] {
            let fixture = try makeTabPullFixture()
            let source = try XCTUnwrap(fixture.controller.dwindleLayoutHandler.desiredTabRailInfos().first {
                $0.tabs.contains { $0.token == fixture.pulled }
            })
            if fullscreen {
                fixture.manager.withEngineMutationScope(in: fixture.workspaceId) {
                    XCTAssertEqual(fixture.engine.toggleFullscreen(in: fixture.workspaceId), fixture.pulled)
                }
            } else {
                fixture.command(.dwindle(.resizeAlongAxis(.horizontal, true)))
            }
            let expectedGroups = [[fixture.kept, fixture.pulled], [fixture.target, fixture.fourth]]
            let sequence = fixture.manager.worldSeq
            let frame = fixture.contentFrame(index: 0, grouped: true)
            let press = CGPoint(x: frame.minX - fixture.controller.tabRailStyle.reservedWidth / 2, y: frame.midY)
            let point = CGPoint(x: frame.minX + MoveConfiguration.default.dragThreshold, y: frame.midY)

            fixture.handler.handleTabRailDrag(TabRailDrag(
                info: source, visualIndex: 1, token: fixture.pulled, location: point, pressLocation: press
            ))

            XCTAssertEqual(fixture.manager.worldSeq, sequence)
            XCTAssertEqual(fixture.base.order(), expectedGroups)
            fixture.assertTerminal()
            fixture.base.assertHistory(undo: fullscreen ? 0 : 1, redo: 0)
        }
    }
}
