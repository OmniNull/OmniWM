// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import ApplicationServices
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class WindowMinimizationTests: XCTestCase {
    func testNiriMinimizingEitherColumnFillsScreenAndRestoresPlacement() throws {
        for minimizedIndex in 0 ... 1 {
            let controller = WindowAdmissionTestSupport.controller()
            let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            let tokens = [WindowToken(pid: 688_001, windowId: 688_101), WindowToken(pid: 688_001, windowId: 688_102)]
            for token in tokens {
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            }
            let engine = try XCTUnwrap(controller.niriEngine)
            _ = controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
            }
            let columns = engine.columns(in: workspaceId)
            XCTAssertEqual(columns.count, 2)
            let columnIds = columns.map(\.id)
            let sizing = columns.map(\.width)
            let minimized = tokens[minimizedIndex]
            let survivor = tokens[1 - minimizedIndex]
            controller.workspaceManager.setWindowMinimized(true, token: minimized)
            let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
            let input = try XCTUnwrap(controller.layoutRefreshController.buildRefreshInput(
                workspaceId: workspaceId, monitor: monitor, resolveConstraints: false, isActiveWorkspace: true
            ))
            XCTAssertEqual(input.excludedTokens, [minimized])
            XCTAssertEqual(Set(input.windows.map(\.token)), Set(tokens))
            let plan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
            })
            XCTAssertFalse(plan.diff.frameChanges.contains { $0.token == minimized })
            XCTAssertFalse(plan.diff.restoreChanges.contains { $0.token == minimized })
            let visibleFrame = try XCTUnwrap(engine.findNode(for: survivor, in: workspaceId)?.frame)
            XCTAssertEqual(visibleFrame, controller.borderSafeFillFrame(for: monitor))
            XCTAssertEqual(engine.columns(in: workspaceId).map(\.id), columnIds)
            XCTAssertEqual(controller.resolveAndSetWorkspaceFocusToken(for: workspaceId), survivor)
            controller.workspaceManager.setWindowMinimized(false, token: minimized)
            _ = controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
            }
            XCTAssertEqual(engine.columns(in: workspaceId).map(\.id), columnIds)
            XCTAssertEqual(engine.columns(in: workspaceId).map(\.width), sizing)
            XCTAssertEqual(engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }, tokens)
        }
    }

    func testDwindleMinimizationRetainsSplitAndRestoresFrames() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(WindowAdmissionTestSupport.workspace(
            named: "688",
            layoutType: .dwindle,
            controller: controller
        ))
        controller.dwindleLayoutHandler.enableDwindleLayout()
        let first = WindowToken(pid: 688_002, windowId: 688_201)
        let second = WindowToken(pid: 688_002, windowId: 688_202)
        _ = WindowAdmissionTestSupport.track(first, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(second, in: workspaceId, controller: controller)
        let engine = try XCTUnwrap(controller.dwindleEngine)
        _ = controller.workspaceManager.withEngineMutationScope {
            engine.syncWindows([first, second], in: workspaceId, focusedToken: first)
        }
        let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let original = controller.workspaceManager.withEngineMutationScope {
            engine.calculateLayout(for: workspaceId, screen: frame)
        }
        let root = try XCTUnwrap(engine.root(for: workspaceId))
        let ratio = root.splitRatio
        controller.workspaceManager.setWindowMinimized(true, token: first)
        XCTAssertEqual(controller.workspaceManager.withEngineMutationScope {
            engine.calculateLayout(for: workspaceId, screen: frame)
        }, [second: frame])
        XCTAssertEqual(engine.root(for: workspaceId)?.id, root.id)
        XCTAssertEqual(engine.root(for: workspaceId)?.splitRatio, ratio)
        controller.workspaceManager.setWindowMinimized(false, token: first)
        XCTAssertEqual(controller.workspaceManager.withEngineMutationScope {
            engine.calculateLayout(for: workspaceId, screen: frame)
        }, original)
    }

    func testWithMacOSFusionMinimizingTheSelectedWindowSelectsTheWindowTakingItsPlace() throws {
        let cases: [(fusion: Bool, minimized: Int, stacked: Bool, expected: Int)] = [
            (true, 2, false, 3),
            (true, 4, false, 3),
            (true, 1, true, 2),
            (false, 2, false, 0),
            (false, 4, false, 0)
        ]
        for (index, testCase) in cases.enumerated() {
            let label = "case \(index)"
            let controller = WindowAdmissionTestSupport.controller()
            controller.settings.niri.macOSFusion = testCase.fusion
            let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            let tokens = (0 ..< 5).map { WindowToken(pid: 688_010 + pid_t(index), windowId: 688_400 + index * 10 + $0) }
            for token in tokens {
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            }
            let engine = try XCTUnwrap(controller.niriEngine)
            layout(controller, workspaceId)
            if testCase.stacked {
                let columns = engine.columns(in: workspaceId)
                let window = try XCTUnwrap(columns[2].windowNodes.first)
                _ = controller.workspaceManager.withEngineMutationScope(in: workspaceId, label: "test_stack") {
                    engine.moveWindowToColumn(window, from: columns[2], to: columns[1], in: workspaceId)
                }
                layout(controller, workspaceId)
            }
            let strip = engine.columns(in: workspaceId).flatMap { $0.windowNodes.map(\.token) }
            XCTAssertEqual(strip.count, 5, label)
            _ = controller.workspaceManager.rememberFocus(strip[0], in: workspaceId)
            let selected = try XCTUnwrap(engine.findNode(for: strip[testCase.minimized], in: workspaceId))
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { $0.selectedNodeId = selected.id }

            controller.workspaceManager.setWindowMinimized(true, token: strip[testCase.minimized])
            let plan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
            }, label)

            let selectedId = try XCTUnwrap(plan.sessionPatch.viewportState?.selectedNodeId, label)
            XCTAssertEqual(plan.sessionPatch.rememberedFocusToken, strip[testCase.expected], label)
            let selectedToken = (engine.findNode(by: selectedId, in: workspaceId) as? NiriWindow)?.token
            XCTAssertEqual(selectedToken, strip[testCase.expected], label)
        }
    }

    func testWithMacOSFusionTheColumnsBesideAMinimizedWindowSlideIntoItsPlaceAndBack() throws {
        for (fusion, animated) in [(true, true), (false, true), (true, false)] {
            let label = "fusion \(fusion) animated \(animated)"
            let controller = WindowAdmissionTestSupport.controller()
            controller.settings.niri.macOSFusion = fusion
            controller.motionPolicy.animationsEnabled = animated
            let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            let tokens = (0 ..< 5).map { WindowToken(pid: 688_030, windowId: 688_500 + $0) }
            for token in tokens {
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            }
            let engine = try XCTUnwrap(controller.niriEngine)
            layout(controller, workspaceId)
            controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
            let columns = engine.columns(in: workspaceId)
            let hidden = try XCTUnwrap(columns[2].windowNodes.first)
            controller.workspaceManager.withNiriViewportState(for: workspaceId) {
                $0.selectedNodeId = hidden.id
                $0.activeColumnIndex = 2
            }
            let span = columns[2].cachedWidth
            let gap = CGFloat(controller.workspaceManager.gaps)
            XCTAssertGreaterThan(span, 0, label)

            controller.workspaceManager.setWindowMinimized(true, token: hidden.token)
            _ = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
            }, label)

            let slides = fusion && animated
            for index in [3, 4] {
                XCTAssertEqual(columns[index].moveAnimation != nil, slides, "\(label) after \(index)")
                if slides {
                    XCTAssertEqual(columns[index].renderOffset().x, span + gap, accuracy: 1, "\(label) \(index)")
                }
            }
            for index in [0, 1] {
                XCTAssertNil(columns[index].moveAnimation, "\(label) before \(index)")
            }

            for column in columns {
                column.animateMoveFrom(
                    displacement: .zero,
                    clock: engine.animationClock,
                    config: engine.windowMovementAnimationConfig,
                    animated: false
                )
            }
            controller.workspaceManager.setWindowMinimized(false, token: hidden.token)
            _ = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
            }, label)
            let reopened = columns.contains { $0.moveAnimation != nil }
            XCTAssertEqual(reopened, slides, "\(label) shown again")
        }
    }

    func testWithMacOSFusionAWindowMinimizedInsideAStackResizesItsMatesWithAnAnimation() throws {
        let controller = WindowAdmissionTestSupport.controller()
        controller.settings.niri.macOSFusion = true
        controller.motionPolicy.animationsEnabled = true
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.applyMacOSFusionSettings()
        let tokens = (0 ..< 4).map { WindowToken(pid: 688_031, windowId: 688_600 + $0) }
        for token in tokens {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        let engine = try XCTUnwrap(controller.niriEngine)
        layout(controller, workspaceId)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        var columns = engine.columns(in: workspaceId)
        let moved = try XCTUnwrap(columns[2].windowNodes.first)
        _ = controller.workspaceManager.withEngineMutationScope(in: workspaceId, label: "test_stack") {
            engine.moveWindowToColumn(moved, from: columns[2], to: columns[1], in: workspaceId)
        }
        layout(controller, workspaceId)
        columns = engine.columns(in: workspaceId)
        for column in columns {
            column.animateMoveFrom(
                displacement: .zero,
                clock: engine.animationClock,
                config: engine.windowMovementAnimationConfig,
                animated: false
            )
        }

        let mate = try XCTUnwrap(columns[1].windowNodes.first { $0 !== moved })
        XCTAssertNil(mate.heightAnimation)
        let heightBefore = try XCTUnwrap(mate.frame).height

        controller.workspaceManager.setWindowMinimized(true, token: moved.token)
        let minimizePlan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
        })

        XCTAssertFalse(columns.contains { $0.moveAnimation != nil })
        XCTAssertNotNil(mate.heightAnimation, "the stack-mate grows with an animation")
        XCTAssertNil(mate.moveXAnimation, "the stack-mate doesn't move sideways")
        let finalHeight = try XCTUnwrap(mate.frame).height
        XCTAssertGreaterThan(finalHeight, heightBefore + 100)
        let written = minimizePlan.diff.frameChanges.first { $0.token == mate.token }?.frame.height
        XCTAssertEqual(try XCTUnwrap(written), heightBefore, accuracy: 60, "the pass writes the animation's start")
        let secondPlan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
        })
        if let rewritten = secondPlan.diff.frameChanges.first(where: { $0.token == mate.token })?.frame.height {
            XCTAssertLessThan(rewritten, finalHeight - 60, "a second pass writes the running animation, not its end")
        }
        XCTAssertTrue(minimizePlan.animationDirectives.contains { directive in
            if case let .startNiriScroll(scrolled) = directive { return scrolled == workspaceId }
            return false
        })

        mate.heightAnimation = nil
        mate.moveXAnimation = nil
        mate.moveYAnimation = nil
        controller.workspaceManager.setWindowMinimized(false, token: moved.token)
        _ = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }

        XCTAssertNotNil(mate.heightAnimation, "the stack-mate shrinks with an animation")
        XCTAssertNil(mate.moveXAnimation, "the stack-mate doesn't move sideways on the restore")
    }

    func testWithMacOSFusionARestoredWindowOpensInItsPlace() throws {
        let wide: [CGFloat] = [0.2, 0.45, 0.4, 0.3, 0.3]
        let cases: [(Int, Int, [CGFloat]?)] = [(2, 3, nil), (4, 3, nil), (0, 1, nil), (2, 1, nil), (1, 2, wide)]
        for (minimized, selectedAfter, widths) in cases {
            let label = "minimized \(minimized) selected \(selectedAfter) wide \(widths != nil)"
            let controller = WindowAdmissionTestSupport.controller()
            controller.settings.niri.macOSFusion = true
            controller.motionPolicy.animationsEnabled = true
            let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            for index in 0 ..< 5 {
                let token = WindowToken(pid: 688_040, windowId: 688_700 + index)
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            }
            let engine = try XCTUnwrap(controller.niriEngine)
            let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
            let geometry = controller.niriInteractionGeometry(for: monitor)
            let context = NiriInteractionContext(
                workspaceId: workspaceId,
                motion: .disabled,
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap,
                orientation: .horizontal
            )
            relayout(controller, workspaceId)
            controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
            let columns = engine.columns(in: workspaceId)
            if let widths {
                for (column, width) in zip(columns, widths) {
                    column.width = .fixed((width * geometry.workingFrame.width).rounded())
                }
                relayout(controller, workspaceId)
            }
            let returning = try XCTUnwrap(columns[minimized].windowNodes.first)
            activate(returning, controller, workspaceId)
            relayout(controller, workspaceId)
            let place: () -> [CGFloat] = {
                let strip = engine.liveColumnStrip(
                    context: context,
                    state: controller.workspaceManager.niriViewportState(for: workspaceId)
                )
                return columns.map { column in strip.first { $0.column === column }?.minX ?? .nan }
            }
            let before = place()

            controller.workspaceManager.setWindowMinimized(true, token: returning.token)
            relayout(controller, workspaceId)
            activate(try XCTUnwrap(columns[selectedAfter].windowNodes.first), controller, workspaceId)
            relayout(controller, workspaceId)
            for column in columns {
                column.animateMoveFrom(
                    displacement: .zero,
                    clock: engine.animationClock,
                    config: engine.windowMovementAnimationConfig,
                    animated: false
                )
            }
            controller.workspaceManager.setWindowMinimized(false, token: returning.token)
            relayout(controller, workspaceId)
            let selectedId = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId
            if minimized < selectedAfter {
                XCTAssertEqual(selectedId, returning.id, "\(label) selection")
            }
            activate(returning, controller, workspaceId)

            let after = place()
            let compared = widths == nil ? Array(columns.indices) : Array(0 ... minimized)
            for index in compared {
                XCTAssertEqual(after[index], before[index], accuracy: 1, "\(label) column \(index)")
            }
        }
    }

    func testWithMacOSFusionMinimizingAndRestoringGivesTheScreenBack() throws {
        for count in [5, 6, 7] {
            for focusedFirst in 0 ..< count {
                for minimized in 0 ..< count {
                    try checkMinimizeAndRestore(count: count, focusedFirst: focusedFirst, minimized: minimized)
                }
            }
        }
    }

    func testWithMacOSFusionMinimizingTheFocusedOneOfTwoCentredWindowsSlidesTheOtherFromWhereItIs() throws {
        for minimized in [1, 0] {
            let label = "minimized \(minimized)"
            let controller = WindowAdmissionTestSupport.controller()
            controller.settings.niri.macOSFusion = true
            controller.settings.niri.alwaysCenterSingleColumn = true
            controller.settings.niri.singleWindowFit = SingleWindowFit(mode: .containerPrimarySpan)
            controller.motionPolicy.animationsEnabled = true
            let workspaceId = try XCTUnwrap(
                controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
            )
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            controller.applyMacOSFusionSettings()
            let tokens = (0 ..< 2).map { WindowToken(pid: 688_070, windowId: 688_950 + $0) }
            for token in tokens {
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            }
            let engine = try XCTUnwrap(controller.niriEngine)
            let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
            let geometry = controller.niriInteractionGeometry(for: monitor)
            let context = NiriInteractionContext(
                workspaceId: workspaceId,
                motion: .disabled,
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap,
                orientation: .horizontal
            )
            relayout(controller, workspaceId)
            controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
            let columns = engine.columns(in: workspaceId)
            for column in columns {
                column.width = .proportion(0.3)
            }
            relayout(controller, workspaceId)
            activate(try XCTUnwrap(columns[minimized].windowNodes.first), controller, workspaceId)
            relayout(controller, workspaceId)
            let stateBefore = controller.workspaceManager.niriViewportState(for: workspaceId)
            let remaining = columns[1 - minimized]
            let placeOf: (ViewportState) -> CGFloat? = { state in
                engine.liveColumnStrip(context: context, state: state).first { $0.column === remaining }?.minX
            }
            let screenBefore = try XCTUnwrap(placeOf(stateBefore), label)

            controller.workspaceManager.setWindowMinimized(
                true,
                token: try XCTUnwrap(columns[minimized].windowNodes.first).token
            )
            let plan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
            }, label)
            var start = try XCTUnwrap(plan.sessionPatch.viewportState, label)
            start.viewOffset = stateBefore.viewOffset
                + start.offsetTransition.rebaseDelta - stateBefore.offsetTransition.rebaseDelta

            XCTAssertEqual(try XCTUnwrap(placeOf(start), label), screenBefore, accuracy: 1, label)
        }
    }

    func testWithMacOSFusionTwoColumnsHiddenAndShownTogetherGiveTheScreenBack() throws {
        for (first, second) in [(1, 3), (0, 4), (2, 3)] {
            let label = "hidden \(first) and \(second)"
            let controller = WindowAdmissionTestSupport.controller()
            controller.settings.niri.macOSFusion = true
            controller.motionPolicy.animationsEnabled = true
            let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            controller.applyMacOSFusionSettings()
            for index in 0 ..< 6 {
                let token = WindowToken(pid: 688_090, windowId: 689_000 + index)
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            }
            let engine = try XCTUnwrap(controller.niriEngine)
            let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
            let geometry = controller.niriInteractionGeometry(for: monitor)
            let context = NiriInteractionContext(
                workspaceId: workspaceId,
                motion: .disabled,
                workingFrame: geometry.workingFrame,
                gaps: geometry.innerGap,
                orientation: .horizontal
            )
            relayout(controller, workspaceId)
            controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
            let columns = engine.columns(in: workspaceId)
            activate(try XCTUnwrap(columns[2].windowNodes.first), controller, workspaceId)
            relayout(controller, workspaceId)
            let place: () -> [CGFloat] = {
                let strip = engine.liveColumnStrip(
                    context: context,
                    state: controller.workspaceManager.niriViewportState(for: workspaceId)
                )
                return columns.map { column in strip.first { $0.column === column }?.minX ?? .nan }
            }
            let before = place()
            let hidden = [first, second].map { columns[$0].windowNodes.first!.token }

            for token in hidden {
                controller.workspaceManager.setWindowMinimized(true, token: token)
            }
            relayout(controller, workspaceId)
            for column in columns {
                column.animateMoveFrom(
                    displacement: .zero,
                    clock: engine.animationClock,
                    config: engine.windowMovementAnimationConfig,
                    animated: false
                )
            }
            let beforeRestore = place()
            for token in hidden {
                controller.workspaceManager.setWindowMinimized(false, token: token)
            }
            relayout(controller, workspaceId)
            let restored = place()

            for index in columns.indices {
                XCTAssertEqual(restored[index], before[index], accuracy: 1, "\(label) column \(index)")
                guard ![first, second].contains(index), !beforeRestore[index].isNaN else { continue }
                let start = restored[index] + (columns[index].moveAnimation?.fromOffset ?? 0)
                XCTAssertEqual(start, beforeRestore[index], accuracy: 2, "\(label) column \(index) starts where it was")
            }
        }
    }

    func testWithMacOSFusionAMinimizesSecondNoticeKeepsTheSlidesItsPassStarted() throws {
        for fusion in [true, false] {
            let label = "fusion \(fusion)"
            let controller = WindowAdmissionTestSupport.controller()
            controller.settings.niri.macOSFusion = fusion
            controller.motionPolicy.animationsEnabled = true
            let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            controller.applyMacOSFusionSettings()
            let tokens = (0 ..< 3).map { WindowToken(pid: 688_100, windowId: 689_100 + $0) }
            for token in tokens {
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            }
            let engine = try XCTUnwrap(controller.niriEngine)
            relayout(controller, workspaceId)
            controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
            let columns = engine.columns(in: workspaceId)
            let minimized = try XCTUnwrap(columns[1].windowNodes.first).token

            XCTAssertTrue(
                controller.axEventHandler.updateWindowNativeWithdrawalState(
                    true,
                    token: minimized,
                    requestRefresh: false
                ),
                label
            )
            relayout(controller, workspaceId)
            columns[2].animateMoveFrom(
                displacement: CGPoint(x: 300, y: 0),
                clock: engine.animationClock,
                config: engine.windowMovementAnimationConfig,
                animated: true
            )
            XCTAssertNotNil(columns[2].moveAnimation, label)

            XCTAssertTrue(
                controller.axEventHandler.updateWindowMinimizedState(true, token: minimized, requestRefresh: false),
                label
            )

            XCTAssertEqual(columns[2].moveAnimation != nil, fusion, "\(label) slide kept")
        }
    }

    func testWithMacOSFusionAPassThatLeavesAViewSlidePendingStartsTheRun() throws {
        for fusion in [true] {
            let label = "fusion \(fusion)"
            let controller = WindowAdmissionTestSupport.controller()
            controller.settings.niri.macOSFusion = fusion
            controller.motionPolicy.animationsEnabled = true
            let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
            _ = controller.workspaceManager.focusWorkspace(named: "1")
            controller.niriLayoutHandler.enableNiriLayout()
            controller.applyMacOSFusionSettings()
            for index in 0 ..< 4 {
                let token = WindowToken(pid: 688_110, windowId: 689_200 + index)
                _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            }
            relayout(controller, workspaceId)
            controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { state in
                state.springOffset(to: state.viewOffset - 200)
            }

            let plan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
                controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
            }, label)

            XCTAssertTrue(try XCTUnwrap(plan.sessionPatch.viewportState, label).hasPendingOffsetAnimation, label)
            let starts = plan.animationDirectives.contains { directive in
                if case let .startNiriScroll(scrolled) = directive { return scrolled == workspaceId }
                return false
            }
            XCTAssertTrue(starts, "\(label) run started")
        }
    }

    private func checkMinimizeAndRestore(count: Int, focusedFirst: Int, minimized: Int) throws {
        let label = "count \(count) focused first \(focusedFirst) minimized \(minimized)"
        let controller = WindowAdmissionTestSupport.controller()
        controller.settings.niri.macOSFusion = true
        controller.motionPolicy.animationsEnabled = true
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        controller.applyMacOSFusionSettings()
        XCTAssertTrue(try XCTUnwrap(controller.niriEngine).keepsStripEndsOnScreen, label)
        for index in 0 ..< count {
            let token = WindowToken(pid: 688_060, windowId: 688_900 + index)
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        let engine = try XCTUnwrap(controller.niriEngine)
        let monitor = try XCTUnwrap(controller.workspaceManager.monitor(for: workspaceId))
        let geometry = controller.niriInteractionGeometry(for: monitor)
        let context = NiriInteractionContext(
            workspaceId: workspaceId,
            motion: .disabled,
            workingFrame: geometry.workingFrame,
            gaps: geometry.innerGap,
            orientation: .horizontal
        )
        relayout(controller, workspaceId)
        controller.layoutRefreshController.layoutState.hasCompletedInitialRefresh = true
        let columns = engine.columns(in: workspaceId)
        activate(try XCTUnwrap(columns[focusedFirst].windowNodes.first), controller, workspaceId)
        relayout(controller, workspaceId)
        let returning = try XCTUnwrap(columns[minimized].windowNodes.first)
        activate(returning, controller, workspaceId)
        relayout(controller, workspaceId)
        let place: () -> [CGFloat] = {
            let strip = engine.liveColumnStrip(
                context: context,
                state: controller.workspaceManager.niriViewportState(for: workspaceId)
            )
            return columns.map { column in strip.first { $0.column === column }?.minX ?? .nan }
        }
        let before = place()

        controller.workspaceManager.setWindowMinimized(true, token: returning.token)
        relayout(controller, workspaceId)
        if let selected = controller.workspaceManager.niriViewportState(for: workspaceId).selectedNodeId,
           let node = engine.findNode(by: selected, in: workspaceId)
        {
            activate(node, controller, workspaceId)
        }
        relayout(controller, workspaceId)
        for column in columns {
            column.animateMoveFrom(
                displacement: .zero,
                clock: engine.animationClock,
                config: engine.windowMovementAnimationConfig,
                animated: false
            )
        }
        let beforeRestore = place()
        controller.workspaceManager.setWindowMinimized(false, token: returning.token)
        relayout(controller, workspaceId)
        let restored = place()
        XCTAssertFalse(
            controller.workspaceManager.niriViewportState(for: workspaceId).hasPendingOffsetAnimation,
            "\(label) view slides"
        )
        XCTAssertEqual(restored[minimized], before[minimized], accuracy: 1, "\(label) returning window placed")
        XCTAssertNil(columns[minimized].moveAnimation, "\(label) returning window moves")
        for index in columns.indices where index != minimized && !beforeRestore[index].isNaN {
            let start = restored[index] + (columns[index].moveAnimation?.fromOffset ?? 0)
            XCTAssertEqual(start, beforeRestore[index], accuracy: 2, "\(label) column \(index) starts where it was")
        }
        activate(returning, controller, workspaceId)
        relayout(controller, workspaceId)

        let after = place()
        for index in columns.indices {
            XCTAssertEqual(after[index], before[index], accuracy: 1, "\(label) column \(index)")
        }
    }

    private func relayout(_ controller: WMController, _ workspaceId: WorkspaceDescriptor.ID) {
        let plan = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
        }
        if let state = plan?.sessionPatch.viewportState {
            controller.workspaceManager.withNiriViewportState(for: workspaceId) { $0 = state }
        }
    }

    private func activate(_ node: NiriNode, _ controller: WMController, _ workspaceId: WorkspaceDescriptor.ID) {
        var state = controller.workspaceManager.niriViewportState(for: workspaceId)
        controller.niriLayoutHandler.activateNode(
            node,
            in: workspaceId,
            state: &state,
            options: NodeActivationOptions(layoutRefresh: false, axFocus: false, startAnimation: false)
        )
        controller.workspaceManager.withNiriViewportState(for: workspaceId) { $0 = state }
    }

    private func layout(_ controller: WMController, _ workspaceId: WorkspaceDescriptor.ID) {
        _ = controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId])
        }
    }

    func testMinimizationCancelsMatchingFocusAndRejectsStalePlan() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.niriLayoutHandler.enableNiriLayout()
        let token = WindowToken(pid: 688_003, windowId: 688_301)
        let axRef = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        let request = controller.intentLedger.beginManagedRequest(
            token: token,
            workspaceId: workspaceId,
            origin: .keyboardOrProgrammatic
        )
        _ = controller.workspaceManager.beginManagedFocusRequest(
            token,
            in: workspaceId,
            onMonitor: nil,
            requestId: request.requestId
        )
        let plan = try XCTUnwrap(controller.workspaceManager.withEngineMutationScope {
            controller.niriLayoutHandler.layoutWithNiriEngine(activeWorkspaces: [workspaceId]).first
        })
        controller.axEventHandler.handleWindowMinimized(pid: token.pid, axRef: axRef, minimized: true)
        XCTAssertNil(controller.intentLedger.activeManagedRequest)
        XCTAssertNil(controller.workspaceManager.pendingFocusedToken)
        XCTAssertFalse(controller.isManagedWindowDisplayable(token))
        XCTAssertFalse(controller.canFocusWindow(pid: token.pid, windowId: token.windowId))
        XCTAssertNil(controller.resolveAndSetWorkspaceFocusToken(for: workspaceId))
        XCTAssertFalse(controller.layoutRefreshController.executeLayoutPlan(plan))
    }

    func testAppUnhidePreservesMinimizedFloatingWindowAndItsParkingState() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: 688_004, windowId: 688_401)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        XCTAssertTrue(controller.workspaceManager.setWindowMode(.floating, for: token))
        let hidden = HiddenState(proportionalPosition: .zero, referenceMonitorId: nil, reason: .workspaceInactive)
        controller.workspaceManager.setHiddenState(hidden, for: token)
        controller.workspaceManager.setWindowMinimized(true, token: token)
        controller.workspaceManager.setAppHidden(true, pid: token.pid, source: .ax)
        controller.workspaceManager.setAppHidden(false, pid: token.pid, source: .ax)
        XCTAssertTrue(controller.workspaceManager.isWindowSuppressedByMacOS(token))
        XCTAssertEqual(
            controller.layoutRefreshController
                .restoreWorkspaceInactiveFloatingWindows(activeWorkspaceIds: [workspaceId]),
            0
        )
        XCTAssertEqual(controller.workspaceManager.hiddenState(for: token), hidden)
        controller.workspaceManager.setWindowMinimized(false, token: token)
        XCTAssertEqual(controller.workspaceManager.hiddenState(for: token), hidden)
    }

    func testMinimizedStateSurvivesRekeyAndEndsWithRetirement() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let manager = controller.workspaceManager
        let workspaceId = try XCTUnwrap(manager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: 688_005, windowId: 688_501)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        manager.setWindowMinimized(true, token: token)
        let replacement = WindowToken(pid: token.pid, windowId: 688_502)
        let axRef = WindowAdmissionTestSupport.axRef(for: replacement)
        XCTAssertNotNil(manager.rekeyWindow(from: token, to: replacement, newAXRef: axRef))
        XCTAssertTrue(try XCTUnwrap(manager.entry(for: replacement)).observedState.isMinimized)
        _ = manager.removeWindow(pid: replacement.pid, windowId: replacement.windowId)
        _ = WindowAdmissionTestSupport.track(replacement, in: workspaceId, controller: controller)
        XCTAssertFalse(try XCTUnwrap(manager.entry(for: replacement)).observedState.isMinimized)
    }

    func testMinimizedWindowIsNotVisibleInIPCWithoutChangingAppHiddenState() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        let token = WindowToken(pid: 688_006, windowId: 688_601)
        _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        controller.workspaceManager.setWindowMinimized(true, token: token)
        let router = IPCQueryRouter(controller: controller, appVersion: nil, sessionToken: "minimize-tests")
        router.windowOrderedInProvider = { _ in true }
        let window = try XCTUnwrap(router.windowsResult(IPCQueryRequest(name: .windows)).windows.first)
        XCTAssertEqual(window.isVisible, false)
        XCTAssertEqual(window.isAppHidden, false)
    }

    func testRestoreNotificationRechecksNativeFocusAfterRescanAlreadyRestoredState() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let token = WindowToken(pid: 688_007, windowId: 688_701)
        let axRef = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        controller.hasStartedServices = true
        defer {
            controller.hasStartedServices = false
            controller.factResolver.stop()
        }
        controller.axEventHandler.frontmostApplicationPIDProvider = { token.pid }
        var factReads = 0
        controller.factResolver.factProvider = { _ in
            factReads += 1
            return nil
        }
        controller.workspaceManager.setWindowMinimized(true, token: token)
        controller.axEventHandler.updateWindowMinimizedState(false, token: token, requestRefresh: false)
        controller.axEventHandler.handleWindowMinimized(pid: token.pid, axRef: axRef, minimized: false)
        XCTAssertEqual(factReads, 1)
    }

    func testWithMacOSFusionRestoringAFloatingWindowRescansItsAppSoItsKindIsReadAgain() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        let floating = WindowToken(pid: 688_009, windowId: 688_901)
        let tiled = WindowToken(pid: 688_010, windowId: 688_902)
        let floatingRef = WindowAdmissionTestSupport.track(floating, in: workspaceId, controller: controller)
        let tiledRef = WindowAdmissionTestSupport.track(tiled, in: workspaceId, controller: controller)
        XCTAssertTrue(controller.workspaceManager.setWindowMode(.floating, for: floating))
        controller.axEventHandler.frontmostApplicationPIDProvider = { 1 }
        func rescans() -> [RescanScope] {
            let layoutState = controller.layoutRefreshController.layoutState
            return [layoutState.activeRefresh, layoutState.pendingRefresh].compactMap { refresh in
                refresh.flatMap { $0.kind == .fullRescan ? $0.rescanScope : nil }
            }
        }

        controller.workspaceManager.setWindowMinimized(true, token: tiled)
        controller.axEventHandler.handleWindowMinimized(pid: tiled.pid, axRef: tiledRef, minimized: false)
        XCTAssertEqual(rescans(), [])

        controller.settings.niri.macOSFusion = false
        controller.workspaceManager.setWindowMinimized(true, token: floating)
        controller.axEventHandler.handleWindowMinimized(pid: floating.pid, axRef: floatingRef, minimized: false)
        XCTAssertEqual(rescans(), [])

        controller.settings.niri.macOSFusion = true
        controller.workspaceManager.setWindowMinimized(true, token: floating)
        controller.axEventHandler.handleWindowMinimized(pid: floating.pid, axRef: floatingRef, minimized: false)
        XCTAssertEqual(rescans(), [.targeted(appPIDs: [floating.pid], nativeSpaceIds: [])])
    }

    func testAFloatingWindowTiledWithMacOSFusionGlidesFromWhereItWas() throws {
        let controller = WindowAdmissionTestSupport.controller()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(for: "1", createIfMissing: true))
        controller.niriLayoutHandler.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let frame = CGRect(x: 300, y: 200, width: 500, height: 400)
        for (index, macOSFusion) in [false, true].enumerated() {
            let token = WindowToken(pid: 688_011, windowId: 688_910 + index)
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
            XCTAssertTrue(controller.workspaceManager.setWindowMode(.floating, for: token))
            controller.settings.niri.macOSFusion = macOSFusion

            XCTAssertTrue(controller.transitionWindowMode(for: token, to: .tiling, observedFrame: frame))

            XCTAssertEqual(engine.stripGlides[token]?.frame, macOSFusion ? frame : nil)
        }
    }

    func testUnknownWindowNotificationInvalidatesInitialEnumeration() {
        let controller = WindowAdmissionTestSupport.controller()
        let token = WindowToken(pid: 688_008, windowId: 688_801)
        let seq = controller.workspaceManager.worldSeq
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 1
        controller.axEventHandler.handleWindowMinimized(
            pid: token.pid,
            axRef: WindowAdmissionTestSupport.axRef(for: token),
            minimized: false
        )
        XCTAssertFalse(controller.workspaceManager.isSeqEpochCurrent(seq, domains: .layoutCommit))
        controller.layoutRefreshController.layoutState.activeFullEnumerationCount = 0
    }
}
