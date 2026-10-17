// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
@testable import OmniWM
import XCTest

final class MouseMoveModifierTests: NiriInteractionTestCase {
    private struct Fixture {
        let controller: WMController
        let engine: NiriLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let token: WindowToken
        let windowFrame: CGRect

        @MainActor var handler: MouseEventHandler {
            controller.mouseEventHandler
        }
    }

    func testMouseMoveModifierMappingsResolveExactly() throws {
        XCTAssertNil(MouseMoveModifierKey.off.cgEventFlags)
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: [], required: nil))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: .maskAlternate, required: nil))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: [], required: []))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: .maskShift, required: []))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: [], required: .maskAlternate))
        XCTAssertNil(MouseEventHandler.mouseMoveMode(modifiers: .maskShift, required: .maskAlternate))

        let baseModifierFlags: [CGEventFlags] = [.maskAlternate, .maskControl, .maskCommand]
        for modifier in MouseMoveModifierKey.allCases where modifier != .off {
            let required = try XCTUnwrap(modifier.cgEventFlags)

            XCTAssertEqual(
                MouseEventHandler.mouseMoveMode(modifiers: required, required: required),
                .swap
            )
            XCTAssertEqual(
                MouseEventHandler.mouseMoveMode(
                    modifiers: required.union(.maskShift),
                    required: required
                ),
                .insert
            )
            XCTAssertEqual(
                MouseEventHandler.mouseMoveMode(
                    modifiers: required.union(.maskAlphaShift),
                    required: required
                ),
                .swap
            )

            for extra in baseModifierFlags where !required.contains(extra) {
                XCTAssertNil(
                    MouseEventHandler.mouseMoveMode(
                        modifiers: required.union(extra),
                        required: required
                    )
                )
            }
        }

        XCTAssertNil(
            MouseEventHandler.mouseMoveMode(
                modifiers: [.maskAlternate, .maskCommand],
                required: .maskAlternate
            )
        )
    }

    @MainActor
    func testOffDoesNotStartMoveForOptionDrag() throws {
        let fixture = try makeFixture(pid: 1_101)
        fixture.controller.settings.gestures.mouseMoveModifierKey = .off
        let worldSeq = fixture.controller.workspaceManager.worldSeq

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.windowFrame.center,
                modifiers: .maskAlternate
            )
        )

        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.handler.state.activeInteractionButton)
        XCTAssertNil(fixture.handler.state.dragGhostController)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
    }

    @MainActor
    func testConfiguredModifierReplacesOptionAndShiftSelectsInsert() throws {
        let fixture = try makeFixture(pid: 1_102)
        fixture.controller.settings.gestures.mouseMoveModifierKey = .control

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.windowFrame.center,
                modifiers: .maskAlternate
            )
        )
        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.windowFrame.center,
                modifiers: [.maskControl, .maskShift]
            )
        )
        XCTAssertTrue(fixture.handler.state.isMoving)
        XCTAssertEqual(fixture.handler.state.activeInteractionButton, .left)
        XCTAssertTrue(try XCTUnwrap(fixture.engine.interactiveMove).isInsertMode)

        fixture.handler.dispatchMouseUp(at: fixture.windowFrame.center)

        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
    }

    @MainActor
    func testDefaultOptionStartsSwapAndSettingChangeDoesNotCancelActiveMove() throws {
        let fixture = try makeFixture(pid: 1_103)

        XCTAssertFalse(
            fixture.handler.dispatchMouseDown(
                at: fixture.windowFrame.center,
                modifiers: .maskAlternate
            )
        )
        XCTAssertTrue(fixture.handler.state.isMoving)
        XCTAssertFalse(try XCTUnwrap(fixture.engine.interactiveMove).isInsertMode)

        fixture.controller.settings.gestures.mouseMoveModifierKey = .off

        XCTAssertTrue(fixture.handler.state.isMoving)
        XCTAssertNotNil(fixture.engine.interactiveMove)

        fixture.handler.dispatchMouseUp(at: fixture.windowFrame.center)

        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
    }

    @MainActor
    func testMouseMoveSettingDoesNotChangeRightMouseResize() throws {
        let fixture = try makeFixture(pid: 1_104)
        fixture.controller.settings.gestures.mouseMoveModifierKey = .off
        let resizePoint = CGPoint(x: fixture.windowFrame.maxX - 1, y: fixture.windowFrame.midY)

        XCTAssertTrue(
            fixture.handler.dispatchMouseDown(
                at: resizePoint,
                modifiers: .maskAlternate,
                button: .right
            )
        )
        XCTAssertTrue(fixture.handler.state.isResizing)
        XCTAssertNotNil(fixture.engine.interactiveResize)

        fixture.handler.dispatchMouseUp(at: resizePoint, button: .right)

        XCTAssertFalse(fixture.handler.state.isResizing)
        XCTAssertNil(fixture.engine.interactiveResize)
    }

    @MainActor
    func testNiriResizeTargetIncludesOnlyTheFocusedExteriorBorder() throws {
        let fixture = try makeFixture(pid: 1_105)
        let border = DesiredBorderSurface(
            token: fixture.token,
            frame: fixture.windowFrame,
            config: borderConfig(width: 5)
        )
        let surfaceFrame = border.config.resolvedGeometry(for: border.frame, scale: 1).surfaceFrame
        let exteriorPoints = [
            CGPoint(x: fixture.windowFrame.maxX, y: fixture.windowFrame.midY),
            CGPoint(x: fixture.windowFrame.maxX + 4, y: fixture.windowFrame.midY),
            CGPoint(x: fixture.windowFrame.maxX + 4, y: fixture.windowFrame.maxY + 4)
        ]

        XCTAssertNil(fixture.engine.hitTestTiled(point: exteriorPoints[1], in: fixture.workspaceId))
        for point in exteriorPoints {
            let token = fixture.handler.focusedBorderResizeToken(
                at: point,
                in: fixture.workspaceId,
                scale: 1,
                appliedBorder: border
            )
            XCTAssertEqual(token, fixture.token)
        }

        XCTAssertNil(
            fixture.handler.focusedBorderResizeToken(
                at: CGPoint(x: surfaceFrame.maxX, y: surfaceFrame.midY),
                in: fixture.workspaceId,
                scale: 1,
                appliedBorder: border
            )
        )
        XCTAssertNil(
            fixture.handler.focusedBorderResizeToken(
                at: CGPoint(x: fixture.windowFrame.maxX + 1, y: fixture.windowFrame.midY),
                in: fixture.workspaceId,
                scale: 1,
                appliedBorder: DesiredBorderSurface(
                    token: fixture.token,
                    frame: fixture.windowFrame,
                    config: borderConfig(enabled: false, width: 5)
                )
            )
        )
        XCTAssertTrue(fixture.controller.workspaceManager.recordExternalFocus(pid: 1_108, windowId: 3))
        XCTAssertNil(
            fixture.handler.focusedBorderResizeToken(
                at: exteriorPoints[1],
                in: fixture.workspaceId,
                scale: 1,
                appliedBorder: border
            )
        )
    }

    @MainActor
    func testGlowDoesNotExpandFocusedExteriorBorderResizeZone() throws {
        let fixture = try makeFixture(pid: 1_109)
        var config = borderConfig(width: 5)
        config.glow = BorderGlow(enabled: true, radius: 8, opacity: 0.6)
        let border = DesiredBorderSurface(token: fixture.token, frame: fixture.windowFrame, config: config)
        let haloPoint = CGPoint(x: fixture.windowFrame.maxX + 6, y: fixture.windowFrame.midY)
        XCTAssertTrue(config.resolvedGeometry(for: border.frame, scale: 1).surfaceFrame.contains(haloPoint))
        XCTAssertNil(fixture.engine.hitTestTiled(point: haloPoint, in: fixture.workspaceId))
        XCTAssertNil(fixture.handler.focusedBorderResizeToken(
            at: haloPoint, in: fixture.workspaceId, scale: 1, appliedBorder: border
        ))
        XCTAssertEqual(fixture.handler.focusedBorderResizeToken(
            at: CGPoint(x: fixture.windowFrame.maxX + 4, y: fixture.windowFrame.midY),
            in: fixture.workspaceId, scale: 1, appliedBorder: border
        ), fixture.token)
    }

    @MainActor
    func testDwindleLeftDragWithMoveModifierSwapsTilesOnRelease() throws {
        let fixture = try makeDwindleFixture(pid: 1_201)
        let manager = fixture.controller.workspaceManager
        let worldSeq = manager.worldSeq

        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: fixture.firstFrame.center, modifiers: .maskControl))
        XCTAssertTrue(fixture.handler.state.isMoving)
        XCTAssertEqual(fixture.handler.state.moveLayout, .dwindle)
        XCTAssertEqual(fixture.handler.state.capturedInteractionButton, .left)
        XCTAssertEqual(fixture.engine.interactiveMove?.token, fixture.first)

        fixture.handler.dispatchMouseDragged(at: fixture.secondFrame.center)
        XCTAssertEqual(fixture.engine.interactiveMove?.targetToken, fixture.second)
        XCTAssertEqual(manager.worldSeq, worldSeq)

        fixture.handler.dispatchMouseUp(at: fixture.secondFrame.center)
        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.handler.state.moveLayout)
        XCTAssertNil(fixture.handler.state.activeInteractionButton)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertGreaterThan(manager.worldSeq, worldSeq)
        fixture.relayout()
        XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.secondFrame)
        XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.firstFrame)
    }

    @MainActor
    func testDwindleUnmodifiedAndUnconfiguredModifiersDoNotStartDrag() throws {
        let fixture = try makeDwindleFixture(pid: 1_202)
        let worldSeq = fixture.controller.workspaceManager.worldSeq

        for modifiers in [CGEventFlags.maskShift, CGEventFlags(), .maskAlternate] {
            XCTAssertFalse(fixture.handler.dispatchMouseDown(at: fixture.firstFrame.center, modifiers: modifiers))
            XCTAssertFalse(fixture.handler.state.isMoving)
            XCTAssertNil(fixture.handler.state.activeInteractionButton)
            XCTAssertNil(fixture.engine.interactiveMove)
        }
        XCTAssertNil(fixture.engine.interactiveResize)
        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
    }

    @MainActor
    func testDwindleMouseDragChoosesSwapOrInsertionFromTheDropZone() throws {
        let modifiers: [CGEventFlags] = [.maskControl, [.maskControl, .maskShift]]
        for (index, flags) in modifiers.enumerated() {
            for inserts in [false, true] {
                let fixture = try makeDwindleFixture(pid: pid_t(1_250 + index))
                let worldSeq = fixture.controller.workspaceManager.worldSeq
                let target = fixture.secondFrame
                let point = inserts ? CGPoint(x: target.midX, y: target.minY + 32) : target.center
                XCTAssertFalse(fixture.handler.dispatchMouseDown(at: fixture.firstFrame.center, modifiers: flags))
                fixture.handler.dispatchMouseDragged(at: point)
                XCTAssertEqual(
                    fixture.engine.interactiveMove?.target,
                    .tile(fixture.second, direction: inserts ? .down : nil)
                )
                XCTAssertEqual(
                    fixture.engine.interactiveMoveTargetFrame(at: 0),
                    inserts ? target.divided(atDistance: target.height / 2, from: .minYEdge).slice : target
                )
                XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)

                fixture.handler.dispatchMouseUp(at: point)

                XCTAssertGreaterThan(fixture.controller.workspaceManager.worldSeq, worldSeq)
                fixture.relayout()
                if inserts {
                    let node = try XCTUnwrap(fixture.engine.findNode(for: fixture.first, in: fixture.workspaceId))
                    XCTAssertEqual(node.parent?.splitOrientation, .vertical)
                    XCTAssertTrue(node.isFirstChild(of: try XCTUnwrap(node.parent)))
                } else {
                    XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.secondFrame)
                    XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.firstFrame)
                }
            }
        }
    }

    @MainActor
    func testDwindleConfiguredModifierInsertsAtTileEdgesWithoutShift() throws {
        let directions: [Direction] = [.left, .right, .up, .down]
        for (index, direction) in directions.enumerated() {
            let fixture = try makeDwindleFixture(pid: pid_t(1_210 + index))
            let manager = fixture.controller.workspaceManager
            let worldSeq = manager.worldSeq
            let target = fixture.secondFrame
            let point: CGPoint = switch direction {
            case .left: CGPoint(x: target.minX + 32, y: target.midY)
            case .right: CGPoint(x: target.maxX - 32, y: target.midY)
            case .up: CGPoint(x: target.midX, y: target.maxY - 32)
            case .down: CGPoint(x: target.midX, y: target.minY + 32)
            }
            XCTAssertFalse(fixture.handler.dispatchMouseDown(
                at: fixture.firstFrame.center, modifiers: .maskControl
            ))
            fixture.handler.dispatchMouseDragged(at: point)
            XCTAssertEqual(fixture.engine.interactiveMove?.targetDirection, direction)
            XCTAssertEqual(manager.worldSeq, worldSeq)

            fixture.handler.dispatchMouseUp(at: point)

            XCTAssertGreaterThan(manager.worldSeq, worldSeq)
            XCTAssertNil(fixture.engine.interactiveMove)
            XCTAssertFalse(fixture.handler.state.isMoving)
            fixture.relayout()
            let first = try XCTUnwrap(fixture.engine.findNode(for: fixture.first, in: fixture.workspaceId))
            let second = try XCTUnwrap(fixture.engine.findNode(for: fixture.second, in: fixture.workspaceId))
            XCTAssertTrue(first.parent === second.parent)
            XCTAssertEqual(first.parent?.splitOrientation, direction.dwindleOrientation)
            XCTAssertEqual(
                first.isFirstChild(of: try XCTUnwrap(first.parent)),
                direction == .left || direction == .down
            )
        }
    }

    @MainActor
    func testDwindlePreviewSwitchesBetweenSwapTileInsertionAndWorkspaceEdge() throws {
        let fixture = try makeDwindleFixture(pid: 1_252, count: 3)
        let worldSeq = fixture.controller.workspaceManager.worldSeq
        let target = fixture.secondFrame
        let screen = fixture.screen
        let cases: [(CGPoint, DwindleMoveTarget?, CGRect?)] = [
            (target.center, .tile(fixture.second, direction: nil), target),
            (
                CGPoint(x: target.minX + 32, y: target.midY), .tile(fixture.second, direction: .left),
                target.divided(atDistance: target.width / 2, from: .minXEdge).slice
            ),
            (
                CGPoint(x: screen.midX, y: screen.maxY - 1), .workspaceEdge(.up, frame: screen),
                screen.divided(atDistance: screen.height / 2, from: .maxYEdge).slice
            ),
            (target.center, .tile(fixture.second, direction: nil), target),
            (CGPoint(x: screen.midX, y: screen.maxY + 1), nil, nil)
        ]
        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: fixture.firstFrame.center, modifiers: .maskControl))
        for (point, pendingTarget, preview) in cases {
            fixture.handler.dispatchMouseDragged(at: point)
            XCTAssertEqual(fixture.engine.interactiveMove?.target, pendingTarget)
            XCTAssertEqual(fixture.engine.interactiveMoveTargetFrame(at: 0), preview)
            XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
        }
        fixture.handler.dispatchMouseUp(at: try XCTUnwrap(cases.last).0)
        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
        fixture.relayout()
        XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.firstFrame)
        XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.secondFrame)
    }

    @MainActor
    func testDwindleReleaseChoosesBetweenSwapAndInsertionAgain() throws {
        for inserts in [false, true] {
            let fixture = try makeDwindleFixture(pid: 1_253)
            let target = fixture.secondFrame
            let edge = CGPoint(x: target.midX, y: target.minY + 32)
            XCTAssertFalse(fixture.handler.dispatchMouseDown(at: fixture.firstFrame.center, modifiers: .maskControl))
            fixture.handler.dispatchMouseDragged(at: inserts ? target.center : edge)
            XCTAssertEqual(fixture.engine.interactiveMove?.isInsertion, !inserts)

            fixture.handler.dispatchMouseUp(at: inserts ? edge : target.center)

            fixture.relayout()
            if inserts {
                let node = try XCTUnwrap(fixture.engine.findNode(for: fixture.first, in: fixture.workspaceId))
                XCTAssertEqual(node.parent?.splitOrientation, .vertical)
                XCTAssertTrue(node.isFirstChild(of: try XCTUnwrap(node.parent)))
            } else {
                XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.secondFrame)
                XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.firstFrame)
            }
        }
    }

    @MainActor
    func testDwindleInsertionUsesTheReleaseLocation() throws {
        let fixture = try makeDwindleFixture(pid: 1_220)
        let target = fixture.secondFrame
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: fixture.firstFrame.center, modifiers: .maskControl
        ))
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: target.minX + 32, y: target.midY))
        XCTAssertEqual(fixture.engine.interactiveMove?.targetDirection, .left)
        fixture.handler.dispatchMouseUp(at: CGPoint(x: target.midX, y: target.minY + 32))

        let source = try XCTUnwrap(fixture.engine.findNode(for: fixture.first, in: fixture.workspaceId))
        XCTAssertEqual(source.parent?.splitOrientation, .vertical)
        XCTAssertTrue(source.isFirstChild(of: try XCTUnwrap(source.parent)))
    }

    @MainActor
    func testDwindleWorkspaceEdgeInsertionCommitsOnlyOnRelease() throws {
        for (index, direction) in [Direction.left, .right, .up, .down].enumerated() {
            let fixture = try makeDwindleFixture(pid: pid_t(1_230 + index), count: 3)
            let worldSeq = fixture.controller.workspaceManager.worldSeq
            let screen = fixture.screen
            let point: CGPoint = switch direction {
            case .left: CGPoint(x: screen.minX + 1, y: screen.midY)
            case .right: CGPoint(x: screen.maxX - 1, y: screen.midY)
            case .up: CGPoint(x: screen.midX, y: screen.maxY - 1)
            case .down: CGPoint(x: screen.midX, y: screen.minY + 1)
            }
            XCTAssertFalse(fixture.handler.dispatchMouseDown(
                at: fixture.firstFrame.center,
                modifiers: .maskControl
            ))
            fixture.handler.dispatchMouseDragged(at: point)
            XCTAssertEqual(fixture.engine.interactiveMove?.target, .workspaceEdge(direction, frame: screen))
            XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)

            fixture.handler.dispatchMouseUp(at: point)

            XCTAssertGreaterThan(fixture.controller.workspaceManager.worldSeq, worldSeq)
            XCTAssertNil(fixture.engine.interactiveMove)
            XCTAssertFalse(fixture.handler.state.isMoving)
            let node = try XCTUnwrap(fixture.engine.findNode(for: fixture.first, in: fixture.workspaceId))
            XCTAssertTrue(node.parent === fixture.engine.root(for: fixture.workspaceId))
            XCTAssertEqual(node.parent?.splitOrientation, direction.dwindleOrientation)
            XCTAssertEqual(node.isFirstChild(of: try XCTUnwrap(node.parent)), direction == .left || direction == .down)
            fixture.relayout()
            let frame = try XCTUnwrap(fixture.presentedFrame(fixture.first))
            if direction.dwindleOrientation == .horizontal {
                XCTAssertEqual(frame.height, screen.height)
            } else {
                XCTAssertEqual(frame.width, screen.width)
            }
        }
    }

    @MainActor
    func testDwindleReleaseCanSelectAnEdgeWithoutAHoveredWindow() throws {
        let fixture = try makeDwindleFixture(pid: 1_240, count: 3)
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: fixture.firstFrame.center,
            modifiers: .maskControl
        ))
        fixture.handler.dispatchMouseDragged(at: fixture.secondFrame.center)
        XCTAssertEqual(fixture.engine.interactiveMove?.targetToken, fixture.second)
        fixture.handler.dispatchMouseUp(at: CGPoint(x: fixture.screen.midX, y: fixture.screen.maxY - 1))
        let node = try XCTUnwrap(fixture.engine.findNode(for: fixture.first, in: fixture.workspaceId))
        XCTAssertTrue(node.parent === fixture.engine.root(for: fixture.workspaceId))
        XCTAssertEqual(node.parent?.splitOrientation, .vertical)
        XCTAssertFalse(node.isFirstChild(of: try XCTUnwrap(node.parent)))
    }

    @MainActor
    func testDwindleReleaseOutsideTheWorkingAreaCancelsAnEdgeInsertion() throws {
        let fixture = try makeDwindleFixture(pid: 1_241, count: 3)
        let worldSeq = fixture.controller.workspaceManager.worldSeq
        XCTAssertFalse(fixture.handler.dispatchMouseDown(
            at: fixture.firstFrame.center,
            modifiers: .maskControl
        ))
        fixture.handler.dispatchMouseDragged(at: CGPoint(x: fixture.screen.midX, y: fixture.screen.maxY - 1))
        fixture.handler.dispatchMouseUp(at: CGPoint(x: fixture.screen.midX, y: fixture.screen.maxY + 1))
        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertFalse(fixture.handler.state.isMoving)
    }

    @MainActor
    func testDwindleModifiedClickAtWorkspaceEdgeDoesNotInsert() throws {
        for offset in [CGFloat(0), 2] {
            let fixture = try makeDwindleFixture(pid: 1_242, count: 3)
            let worldSeq = fixture.controller.workspaceManager.worldSeq
            let point = CGPoint(x: fixture.firstFrame.minX + 1, y: fixture.firstFrame.midY)
            XCTAssertFalse(fixture.handler.dispatchMouseDown(at: point, modifiers: .maskControl))
            fixture.handler.dispatchMouseUp(at: CGPoint(x: point.x, y: point.y + offset))
            XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
            XCTAssertNil(fixture.engine.interactiveMove)
            XCTAssertFalse(fixture.handler.state.isMoving)
        }
    }

    @MainActor
    func testDwindleReleaseOverSourceLeavesWorldUnchanged() throws {
        let fixture = try makeDwindleFixture(pid: 1_203)
        let worldSeq = fixture.controller.workspaceManager.worldSeq

        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: fixture.firstFrame.center, modifiers: .maskControl))
        fixture.handler.dispatchMouseDragged(at: fixture.secondFrame.center)
        fixture.handler.dispatchMouseDragged(at: fixture.firstFrame.center)
        XCTAssertNil(fixture.engine.interactiveMove?.targetToken)
        fixture.handler.dispatchMouseUp(at: fixture.firstFrame.center)

        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
        fixture.relayout()
        XCTAssertEqual(fixture.presentedFrame(fixture.first), fixture.firstFrame)
        XCTAssertEqual(fixture.presentedFrame(fixture.second), fixture.secondFrame)
    }

    @MainActor
    func testCleanupReconcilesDwindleMoveEngineAndLocalState() throws {
        let fixture = try makeDwindleFixture(pid: 1_204)
        XCTAssertFalse(fixture.handler.dispatchMouseDown(at: fixture.firstFrame.center, modifiers: .maskControl))
        XCTAssertNotNil(fixture.engine.interactiveMove)

        fixture.handler.cleanup()

        XCTAssertNil(fixture.engine.interactiveMove)
        XCTAssertFalse(fixture.handler.state.isMoving)
        XCTAssertNil(fixture.handler.state.moveLayout)
        XCTAssertNil(fixture.handler.state.activeInteractionButton)
        XCTAssertFalse(fixture.handler.isInteractiveGestureActive)
    }

    private struct DwindleFixture {
        let controller: WMController
        let engine: DwindleLayoutEngine
        let workspaceId: WorkspaceDescriptor.ID
        let screen: CGRect
        let first: WindowToken
        let second: WindowToken
        let firstFrame: CGRect
        let secondFrame: CGRect

        @MainActor var handler: MouseEventHandler {
            controller.mouseEventHandler
        }

        func presentedFrame(_ token: WindowToken) -> CGRect? {
            engine.presentedFrame(for: token, in: workspaceId, at: 0)
        }

        func relayout() {
            _ = engine.calculateLayout(for: workspaceId, screen: screen)
            engine.cancelAnimations(in: workspaceId)
        }
    }

    @MainActor
    private func makeDwindleFixture(pid: pid_t, count: Int = 2) throws -> DwindleFixture {
        let controller = makeController()
        controller.settings.gestures.mouseMoveModifierKey = .control
        let monitor = makeMonitor()
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: monitor)),
                layoutType: .dwindle
            )
        ]
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        controller.workspaceManager.applySettings()
        let workspaceId = try XCTUnwrap(controller.workspaceManager.workspaceId(named: "1"))
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableDwindleLayout()
        let engine = try XCTUnwrap(controller.dwindleEngine)
        var tokens: [WindowToken] = []
        for windowId in 1 ... count {
            let token = controller.workspaceManager.addWindow(
                WindowAdmissionTestSupport.axRef(for: WindowToken(pid: pid, windowId: windowId)),
                pid: pid,
                windowId: windowId,
                to: workspaceId
            )
            controller.workspaceManager.withEngineMutationScope(in: workspaceId) {
                _ = engine.addWindow(token: token, to: workspaceId, activeWindowFrame: nil)
            }
            tokens.append(token)
        }
        let screen = controller.insetWorkingFrame(for: monitor)
        _ = engine.calculateLayout(for: workspaceId, screen: screen)
        engine.cancelAnimations(in: workspaceId)
        controller.mouseEventHandler.pressedMouseButtonsProvider = { 1 }
        let firstFrame = try XCTUnwrap(engine.presentedFrame(for: tokens[0], in: workspaceId, at: 0))
        let secondFrame = try XCTUnwrap(engine.presentedFrame(for: tokens[1], in: workspaceId, at: 0))
        XCTAssertNotEqual(firstFrame, secondFrame)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(controller.settings.workspaces.layoutType(for: "1"), .dwindle)
        XCTAssertEqual(
            MouseEventHandler.mouseMoveMode(
                modifiers: .maskControl,
                required: controller.settings.gestures.mouseMoveModifierKey.cgEventFlags
            ),
            .swap
        )
        XCTAssertEqual(
            engine.hitTestFocusableWindow(
                point: firstFrame.center,
                in: workspaceId,
                at: controller.animationClock.now()
            ),
            tokens[0]
        )

        return DwindleFixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            screen: screen,
            first: tokens[0],
            second: tokens[1],
            firstFrame: firstFrame,
            secondFrame: secondFrame
        )
    }

    @MainActor
    private func makeFixture(pid: pid_t) throws -> Fixture {
        let controller = makeController()
        let monitor = makeMonitor()
        controller.workspaceManager.applyMonitorConfigurationChange([monitor])
        let workspaceId = try XCTUnwrap(
            controller.workspaceManager.workspaceId(for: "1", createIfMissing: true)
        )
        _ = controller.workspaceManager.focusWorkspace(named: "1")
        controller.enableNiriLayout()
        let engine = try XCTUnwrap(controller.niriEngine)
        let window = addWindow(engine, pid: pid, to: workspaceId)
        _ = controller.workspaceManager.addWindow(
            WindowAdmissionTestSupport.axRef(for: window.token),
            pid: window.token.pid,
            windowId: window.token.windowId,
            to: workspaceId
        )
        XCTAssertTrue(
            controller.workspaceManager.confirmManagedFocus(
                window.token,
                in: workspaceId,
                activateWorkspaceOnMonitor: false
            )
        )
        let gap = controller.innerGap(for: monitor)
        let frames = engine.calculateLayout(
            state: controller.workspaceManager.niriViewportState(for: workspaceId),
            workspaceId: workspaceId,
            monitorFrame: controller.insetWorkingFrame(for: monitor),
            gaps: (horizontal: gap, vertical: gap),
            orientation: .horizontal
        )

        return Fixture(
            controller: controller,
            engine: engine,
            workspaceId: workspaceId,
            token: window.token,
            windowFrame: try XCTUnwrap(frames[window.token])
        )
    }

    private func borderConfig(enabled: Bool = true, width: CGFloat) -> BorderConfig {
        BorderConfig(
            enabled: enabled,
            width: width,
            color: SettingsColor(red: 1, green: 0, blue: 0, alpha: 1)
        )
    }

    @MainActor
    private func makeController() -> WMController {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MouseMoveModifierTests-\(UUID().uuidString)", isDirectory: true)
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(
                directory: root.appendingPathComponent("config", isDirectory: true),
                startWatching: false,
                deferSaves: false
            ),
            runtimeState: RuntimeStateStore(
                directory: root.appendingPathComponent("state", isDirectory: true),
                deferSaves: false
            ),
            autosaveEnabled: false
        )
        return WMController(settings: settings)
    }

    private func makeMonitor() -> Monitor {
        Monitor(
            id: .init(displayId: 51_001),
            displayId: 51_001,
            frame: workingFrame,
            visibleFrame: workingFrame,
            hasNotch: false,
            name: "Mouse Move Modifier"
        )
    }
}
