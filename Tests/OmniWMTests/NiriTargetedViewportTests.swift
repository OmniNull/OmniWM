// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class NiriTargetedViewportTests: XCTestCase {
    private struct Fixture {
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let frame: CGRect
        let orientation: Monitor.Orientation
        let gap: CGFloat
        let tokens: [WindowToken]
        let focusedToken: WindowToken
        var motion: MotionSnapshot
        var state: ViewportState

        var columns: [NiriContainer] {
            engine.columns(in: workspaceId)
        }

        var context: NiriInteractionContext {
            .init(workspaceId: workspaceId, motion: motion, workingFrame: frame, gaps: gap, orientation: orientation)
        }

        var focusedColumn: NiriContainer {
            column(containing: focusedToken)
        }

        func column(containing token: WindowToken) -> NiriContainer {
            columns.first { column in column.windowNodes.contains { $0.token == token } }!
        }

        func columnOrder() -> [WindowToken] {
            columns.map { $0.windowNodes[0].token }
        }

        func frames(animationTime: TimeInterval? = nil) -> [WindowToken: CGRect] {
            engine.calculateLayoutWithVisibility(
                state: state,
                workspaceId: workspaceId,
                monitorFrame: frame,
                gaps: (gap, gap),
                orientation: orientation,
                animationTime: animationTime,
                excludedTokens: engine.projectionExclusions(in: workspaceId)
            ).frames
        }

        func focusedFrame(animationTime: TimeInterval? = nil) -> CGRect? {
            frames(animationTime: animationTime)[focusedToken]
        }
    }

    private struct MoveCase {
        let target: Int
        let move: NiriColumnMoveTarget
        let order: [Int]
    }

    private enum SizingOperation: CaseIterable {
        case toggleFullSpan
        case setSpan
        case cycleSpan
        case toggleTabbed
    }

    private func makeFixture(
        orientation: Monitor.Orientation = .horizontal,
        center: CenterFocusedColumn = .never,
        columnCount: Int = 5,
        focusedIndex: Int = 2,
        motion: MotionSnapshot = .disabled
    ) -> Fixture {
        let engine = NiriLayoutEngine()
        engine.updateConfiguration(centerFocusedColumn: center)
        let workspaceId = WorkspaceDescriptor.ID()
        let frame = CGRect(x: 0, y: 0, width: 1_500, height: 1_500)
        let monitor = Monitor(
            id: Monitor.ID(displayId: 91), displayId: 91, frame: frame, visibleFrame: frame,
            hasNotch: false, name: "Targeted viewport"
        )
        engine.syncWorkspaceAssignments(
            [(workspaceId: workspaceId, monitor: monitor)],
            orientations: [monitor.id: orientation]
        )
        let tokens = (1 ... columnCount).map { WindowToken(pid: 913, windowId: $0) }
        for token in tokens {
            _ = engine.addWindow(token: token, to: workspaceId, afterSelection: nil)
        }
        for column in engine.columns(in: workspaceId) {
            column.width = .proportion(1.0 / 3.0)
            column.height = .proportion(1.0 / 3.0)
        }
        let gap: CGFloat = 12
        engine.resolvePrimaryContainerSpans(
            in: workspaceId, workingFrame: frame, gaps: gap, orientation: orientation
        )

        let focusedToken = tokens[focusedIndex]
        let focusedWindow = engine.findNode(for: focusedToken, in: workspaceId)!
        var fixture = Fixture(
            engine: engine, workspaceId: workspaceId, frame: frame, orientation: orientation, gap: gap,
            tokens: tokens, focusedToken: focusedToken, motion: motion,
            state: ViewportState(selectedNodeId: focusedWindow.id)
        )
        fixture.state.activeColumnIndex = focusedIndex
        fixture.state.jumpOffset(to: -gap)
        return fixture
    }

    private func apply(_ operation: SizingOperation, to column: NiriContainer, fixture: inout Fixture) {
        switch operation {
        case .toggleFullSpan:
            fixture.engine.toggleContainerFullPrimarySpan(column, context: fixture.context, state: &fixture.state)
        case .setSpan:
            fixture.engine.setContainerPrimarySpan(
                column, change: .setProportion(60), context: fixture.context, state: &fixture.state
            )
        case .cycleSpan:
            fixture.engine.toggleContainerPrimarySpan(
                column, forwards: true, context: fixture.context, state: &fixture.state
            )
        case .toggleTabbed:
            XCTAssertTrue(fixture.engine.toggleColumnTabbed(
                column, in: fixture.workspaceId, motion: fixture.motion, orientation: fixture.orientation
            ))
        }
    }

    private func sizingSignature(of column: NiriContainer, orientation: Monitor.Orientation) -> String {
        let spec = orientation == .horizontal ? column.width : column.height
        let full = orientation == .horizontal ? column.isFullWidth : column.isFullHeight
        return "\(spec)-\(full)-\(column.displayMode)"
    }

    func testSizingAColumnBesideTheFocusedColumnKeepsTheFocusedFrame() throws {
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for center in CenterFocusedColumn.allCases {
                for targetIndex in [1, 3] {
                    for operation in SizingOperation.allCases {
                        var fixture = makeFixture(orientation: orientation, center: center)
                        let label = "\(orientation) \(center) target \(targetIndex) \(operation)"
                        let before = try XCTUnwrap(fixture.focusedFrame(), label)
                        let selection = fixture.state.selectedNodeId
                        let target = fixture.columns[targetIndex]
                        let signature = sizingSignature(of: target, orientation: orientation)

                        apply(operation, to: target, fixture: &fixture)

                        XCTAssertNotEqual(sizingSignature(of: target, orientation: orientation), signature, label)
                        XCTAssertEqual(fixture.state.selectedNodeId, selection, label)
                        XCTAssertEqual(fixture.state.activeColumnIndex, 2, label)
                        XCTAssertEqual(try XCTUnwrap(fixture.focusedFrame(), label), before, label)
                    }
                }
            }
        }
    }

    func testMovingAnotherColumnKeepsTheFocusedFrame() throws {
        let cases: [MoveCase] = [
            .init(target: 3, move: .first, order: [3, 0, 1, 2, 4]),
            .init(target: 1, move: .last, order: [0, 2, 3, 4, 1]),
            .init(target: 4, move: .index(2), order: [0, 4, 1, 2, 3]),
            .init(target: 0, move: .direction(.right), order: [1, 0, 2, 3, 4]),
            .init(target: 1, move: .direction(.right), order: [0, 2, 1, 3, 4]),
            .init(target: 3, move: .direction(.left), order: [0, 1, 3, 2, 4])
        ]
        for orientation in [Monitor.Orientation.horizontal, .vertical] {
            for center in CenterFocusedColumn.allCases {
                for testCase in cases {
                    var fixture = makeFixture(orientation: orientation, center: center)
                    let label = "\(orientation) \(center) \(testCase)"
                    let before = try XCTUnwrap(fixture.focusedFrame(), label)
                    let selection = fixture.state.selectedNodeId
                    let column = fixture.columns[testCase.target]
                    let move: NiriColumnMoveTarget = switch testCase.move {
                    case let .direction(direction) where orientation == .vertical:
                        .direction(direction == .right ? .up : .down)
                    default:
                        testCase.move
                    }

                    XCTAssertTrue(fixture.engine.moveColumnPreservingFocus(
                        column, target: move, focused: fixture.focusedColumn,
                        context: fixture.context, state: &fixture.state
                    ), label)

                    XCTAssertEqual(fixture.columnOrder(), testCase.order.map { fixture.tokens[$0] }, label)
                    XCTAssertEqual(fixture.state.selectedNodeId, selection, label)
                    XCTAssertEqual(
                        fixture.state.activeColumnIndex,
                        fixture.engine.columnIndex(of: fixture.focusedColumn, in: fixture.workspaceId),
                        label
                    )
                    XCTAssertEqual(try XCTUnwrap(fixture.focusedFrame(), label), before, label)
                }
            }
        }
    }

    func testMovingAnotherColumnDropsStaleRemovalRestoreMarkers() throws {
        var fixture = makeFixture()
        fixture.state.activatePrevColumnOnRemoval = -123
        fixture.state.viewOffsetToRestore = -456

        XCTAssertTrue(fixture.engine.moveColumnPreservingFocus(
            fixture.columns[4], target: .first, focused: fixture.focusedColumn,
            context: fixture.context, state: &fixture.state
        ))

        XCTAssertNil(fixture.state.activatePrevColumnOnRemoval)
        XCTAssertNil(fixture.state.viewOffsetToRestore)
    }

    func testMovingAnotherColumnPastAProjectionExcludedColumnKeepsTheFocusedFrame() throws {
        var fixture = makeFixture(columnCount: 6, focusedIndex: 3)
        fixture.engine.setProjectionExclusions([fixture.tokens[1]], in: fixture.workspaceId)
        let focusedWindow = try XCTUnwrap(fixture.engine.findNode(for: fixture.focusedToken, in: fixture.workspaceId))
        fixture.engine.ensureProjectedSelectionVisible(
            node: focusedWindow, context: fixture.context, state: &fixture.state,
            animationConfig: nil, fromContainerIndex: nil
        )
        let before = try XCTUnwrap(fixture.focusedFrame())
        let selection = fixture.state.selectedNodeId

        XCTAssertTrue(fixture.engine.moveColumnPreservingFocus(
            fixture.columns[5], target: .first, focused: fixture.focusedColumn,
            context: fixture.context, state: &fixture.state
        ))

        XCTAssertEqual(fixture.columnOrder(), [5, 0, 1, 2, 3, 4].map { fixture.tokens[$0] })
        XCTAssertEqual(fixture.state.selectedNodeId, selection)
        XCTAssertEqual(try XCTUnwrap(fixture.focusedFrame()), before)
    }

    func testMovingTheFocusedColumnMatchesTheFocusedCommand() throws {
        for center in CenterFocusedColumn.allCases {
            var targeted = makeFixture(center: center)
            var focused = makeFixture(center: center)

            XCTAssertTrue(targeted.engine.moveColumnPreservingFocus(
                targeted.focusedColumn, target: .first, focused: targeted.focusedColumn,
                context: targeted.context, state: &targeted.state
            ))
            XCTAssertTrue(focused.engine.moveColumnToFirst(
                focused.focusedColumn, context: focused.context, state: &focused.state
            ))

            XCTAssertEqual(targeted.columnOrder(), focused.columnOrder())
            XCTAssertEqual(targeted.state.activeColumnIndex, focused.state.activeColumnIndex)
            XCTAssertEqual(targeted.state.viewOffset, focused.state.viewOffset)
            XCTAssertEqual(targeted.frames(), focused.frames())
        }
    }

    func testFocusedFrameDoesNotDriftWhileABackgroundColumnAnimates() throws {
        var fixture = makeFixture(motion: .enabled)
        let before = try XCTUnwrap(fixture.focusedFrame())
        let start = CACurrentMediaTime()

        fixture.engine.toggleContainerFullPrimarySpan(
            fixture.columns[1], context: fixture.context, state: &fixture.state
        )
        XCTAssertTrue(fixture.engine.hasAnyColumnAnimationsRunning(in: fixture.workspaceId))

        for offset in [0.016, 0.05, 0.1, 0.2] {
            let frame = try XCTUnwrap(fixture.focusedFrame(animationTime: start + offset))
            XCTAssertEqual(frame.minX, before.minX, accuracy: 0.5, "t+\(offset)")
            XCTAssertEqual(frame.width, before.width, accuracy: 0.5, "t+\(offset)")
        }
        XCTAssertEqual(try XCTUnwrap(fixture.focusedFrame(animationTime: start + 5)), before)
    }
}
