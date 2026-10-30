// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellManipulationSurfaceTests: XCTestCase {
    @MainActor
    final class Fixture {
        let script: ShellScriptHostTests.Script
        let surface: ShellWidgetSurface
        let text = ShellTextStore()
        var events: [ShellClick] = []
        var lastInvocation: UInt64?
        var observed: ((ShellClick) -> Void)?

        init(_ body: String, animations: Bool = false, clock: (() -> CFTimeInterval)? = nil) throws {
            script = try ShellScriptHostTests.Script("function render(ctx) " + body + " end")
            surface = ShellWidgetSurface(
                scale: 2,
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: animations)),
                directories: []
            )
            if let clock { surface.clock = clock }
            surface.onAction = { [weak self] click in
                guard let self else { return }
                events.append(click)
                if let token = click.event.trackingToken {
                    let invocation = ShellInvocation.next()
                    surface.bindGestureInvocation(trackToken: token, invocationID: invocation)
                    lastInvocation = invocation
                }
                observed?(click)
            }
            render()
        }

        func render(acknowledgement: UInt64 = 0) {
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            text.ingest(wire: script.output)
            surface.sequence += 1
            XCTAssertTrue(surface.apply(script.output, text: text, gestureAcknowledgement: acknowledgement))
            surface.view.frame = CGRect(origin: .zero, size: surface.size)
            surface.layoutTextInputs()
            ShellLayerScene.engineQueue.sync {}
        }

        func beginMove(to point: CGPoint = CGPoint(x: 125, y: 105)) {
            surface.press(at: CGPoint(x: 85, y: 75), timestamp: 0)
            surface.drag(to: point, screen: .zero, timestamp: 0.01)
        }

        func releaseMove(at point: CGPoint = CGPoint(x: 125, y: 105)) throws -> UInt64 {
            surface.release(at: point, timestamp: 0.02)
            return try XCTUnwrap(lastInvocation)
        }

        func invokeRelease() throws {
            let click = try XCTUnwrap(events.last { $0.event.phase == .ended })
            XCTAssertEqual(script.invoke(click.action, event: click.event.bytes), OMNI_OK, script.message)
        }

        func target() throws -> ElementHandle {
            try XCTUnwrap(surface.manipulationTargets.keys.first)
        }

        func target(at x: Float) throws -> ElementHandle {
            try XCTUnwrap(surface.manipulationTargets.keys.first {
                surface.layout.core.absoluteFrame(of: $0).x == x
            })
        }
    }

    @MainActor
    final class Window: ShellFocusPanel {
        weak var selectedResponder: NSResponder?

        override var isVisible: Bool {
            true
        }

        override var occlusionState: NSWindow.OcclusionState {
            [.visible]
        }

        init() {
            _ = NSApplication.shared
            super.init(
                contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [], backing: .buffered, defer: false
            )
            isReleasedWhenClosed = false
        }

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            selectedResponder = responder
            return true
        }
    }

    private static let body = """
    local rect=ctx.state.rect or {x=80,y=70,w=100,h=80}
    local function handle(next,event)
        if event.phase=='ended' then
            next.state.rect=event.rect
            next.state.transaction=event.transaction
        end
    end
    return ui.stack{w=600,h=400,
        ui.box{decorative=true,w=600,h=400,fill='accent'},
        ui.stack{key='widget',align='topLeading',dx=rect.x,dy=rect.y,w=rect.w,h=rect.h,
            manipulationCommit=ctx.state.transaction,fill='surface',
            ui.box{key='move',align='topLeading',w=100,h=20,onGesture=handle,
                gesture={axis='free',track={mode='move',target='widget',bounds={w=600,h=400},
                    min={w=50,h=40},max={w=300,h=240}}}},
            ui.input{key='note',align='topLeading',dy=30,w=80,h=25,text='stateful note'},
            ui.box{key='resize',align='bottomTrailing',w=12,h=12,onGesture=handle,
                gesture={track={mode='resize',target='widget',edge='se',bounds={w=600,h=400},
                    min={w=50,h=40},max={w=300,h=240}}}}}}
    """

    private static let overlappingWidgets = """
    local function widget(id,x)
        return ui.stack{key=id,align='topLeading',dx=x,dy=70,w=100,h=80,fill='surface',
            ui.box{align='topLeading',w=100,h=20,onGesture=function() end,
                gesture={track={mode='move',target=id,bounds={w=600,h=400},
                    min={w=50,h=40},max={w=300,h=240}}}},
            ui.input{key=id..'-input',align='topLeading',dy=30,w=80,h=25,text=id}}
    end
    return ui.stack{w=600,h=400,widget('a',80),widget('b',140)}
    """

    func testFocusedInputSurvivesItsOwnResizeWhenPartiallyOrFullyClipped() throws {
        for offset in [30, 45] {
            let body = Self.body.replacingOccurrences(
                of: "dy=30,w=80,h=25", with: "dy=\(offset),w=80,h=25"
            )
            let fixture = try Fixture(body)
            let surface = fixture.surface
            let handle = try XCTUnwrap(surface.textInputs.keys.first)
            let input = try XCTUnwrap(surface.textInputs[handle])
            input.field?.stringValue = "unsaved draft"
            surface.focusDeclared(handle)
            input.beganEditing()
            surface.press(at: CGPoint(x: 175, y: 145), timestamp: 0)
            surface.drag(to: CGPoint(x: 125, y: 105), screen: .zero, timestamp: 0.01)
            let token = try XCTUnwrap(surface.manipulation?.token)
            XCTAssertEqual(surface.manipulation?.preview.size, CGSize(width: 50, height: 40))
            fixture.render()
            XCTAssertEqual(surface.manipulation?.token, token)
            XCTAssertTrue(surface.declaredFocus)
            XCTAssertEqual(surface.focused, handle)
            XCTAssertTrue(surface.textInputs[handle] === input)
            XCTAssertTrue(input.editing)
            XCTAssertEqual(input.text, "unsaved draft")
            XCTAssertFalse(input.view.isHidden)
            XCTAssertEqual(input.view.alphaValue, 0)
            XCTAssertFalse(fixture.events.contains { $0.event.phase == .cancelled })
            surface.cancelInput()
        }
    }

    func testActiveMoveHoldsOnReleaseAndCancelsOnHideDisplayChangeAndReset() throws {
        for lifecycle in 0 ..< 4 {
            let fixture = try Fixture(Self.body)
            let surface = fixture.surface
            fixture.beginMove()
            XCTAssertNotNil(surface.manipulation)
            switch lifecycle {
            case 0: _ = try fixture.releaseMove()
            case 1: surface.setVisible(false)
            case 2: surface.setRootLimit(CGSize(width: 500, height: 350))
            default: surface.reset(text: ShellTextStore())
            }
            if lifecycle == 0 {
                XCTAssertEqual(surface.manipulation?.holding, true)
            } else {
                XCTAssertNil(surface.manipulation)
            }
            XCTAssertFalse(fixture.events.contains { $0.event.phase == .applied })
            surface.cancelInput()
        }
    }

    func testAnotherMouseButtonDuringAMoveDoesNotLeaveTheNewSelectionRaised() throws {
        for button in [ShellEvent.Button.right, .middle] {
            let fixture = try Fixture(Self.overlappingWidgets)
            let surface = fixture.surface
            let second = try fixture.target(at: 140)
            fixture.beginMove(to: CGPoint(x: 105, y: 85))
            XCTAssertNotNil(surface.manipulation)
            surface.press(at: CGPoint(x: 205, y: 75), button: button, timestamp: 0.02)
            XCTAssertNil(surface.manipulation)
            XCTAssertEqual(surface.selectedManipulation, second)
            fixture.render()
            XCTAssertEqual(surface.selectedManipulation, .none)
            let scene = surface.scene
            XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.gestureLayers[second.slot]?.layer.zPosition }, 0)
        }
    }

    func testTabFocusRaisesTheCoveredOwnedInputWithAnUnshownWindow() throws {
        let fixture = try Fixture(Self.overlappingWidgets)
        let surface = fixture.surface
        let window = Window()
        window.contentView = surface.view
        defer {
            window.contentView = nil
            window.close()
        }
        let first = try fixture.target(at: 80)
        let second = try fixture.target(at: 140)
        let firstHandle = surface.layout.core.firstDescendant(of: first) { $0.focusable }
        let secondHandle = surface.layout.core.firstDescendant(of: second) { $0.focusable }
        let firstInput = try XCTUnwrap(surface.textInputs[firstHandle])
        let secondInput = try XCTUnwrap(surface.textInputs[secondHandle])
        surface.focusTextInput(secondInput)
        XCTAssertEqual(surface.focused, secondHandle)
        XCTAssertEqual(surface.selectedManipulation, second)
        let overlap = CGPoint(x: 150, y: 105)
        XCTAssertFalse(surface.allowsNativeHit(firstInput.view, at: overlap))
        surface.moveTextInputFocus(from: secondHandle, backwards: true)
        XCTAssertEqual(surface.focused, firstHandle)
        XCTAssertEqual(surface.selectedManipulation, first)
        XCTAssertTrue(window.selectedResponder === firstInput.responder)
        XCTAssertTrue(surface.allowsNativeHit(firstInput.view, at: overlap))
        XCTAssertFalse(surface.allowsNativeHit(secondInput.view, at: overlap))
        XCTAssertTrue(surface.textInputs[firstHandle] === firstInput)
        XCTAssertTrue(surface.textInputs[secondHandle] === secondInput)
    }

    func testSettingsOverlayRelinquishesNativeEditorWithoutReplacingItsObject() throws {
        let body = Self.body.replacingOccurrences(
            of: "return ui.stack{w=600,h=400,",
            with: "local tree = ui.stack{w=600,h=400,"
        ) + """
        if ctx.data.vars and ctx.data.vars.overlay then
            tree[#tree+1] = ui.box{key='settings',w=600,h=400,fill='surface',focusable=true}
        end
        return tree
        """
        let fixture = try Fixture(body)
        let handle = try XCTUnwrap(fixture.surface.textInputs.keys.first)
        let input = try XCTUnwrap(fixture.surface.textInputs[handle])
        fixture.surface.focused = handle
        fixture.surface.declaredFocus = true
        input.beganEditing()
        fixture.surface.layoutTextInputs()
        XCTAssertFalse(input.view.isHidden)
        var writer = ShellValueWriter()
        writer.map(1)
        writer.key("overlay")
        writer.bool(true)
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(fixture.script.instance, "vars", $0.baseAddress, $0.count)
        }, OMNI_OK)
        fixture.render()
        XCTAssertFalse(fixture.surface.declaredFocus)
        XCTAssertTrue(input.view.isHidden)
        XCTAssertTrue(fixture.surface.textInputs[handle] === input)
    }

    func testSignedPreviewMovesHitsAnchorsAndRegionsWithoutRebuildingChildren() throws {
        let fixture = try Fixture(Self.body)
        let surface = fixture.surface
        let target = try fixture.target()
        let input = try XCTUnwrap(surface.textInputs.keys.first)
        let originalAnchor = surface.anchor(of: input).frame
        let originalSource = surface.manipulationTargets[target]
        XCTAssertFalse(surface.islandRegions().contains { $0.contains(CGPoint(x: 400, y: 300)) })
        fixture.beginMove(to: CGPoint(x: 65, y: 105))
        XCTAssertEqual(surface.manipulation?.preview, CGRect(x: 60, y: 100, width: 100, height: 80))
        XCTAssertFalse(surface.hasAction(at: CGPoint(x: 85, y: 75)))
        XCTAssertTrue(surface.hasAction(at: CGPoint(x: 65, y: 105)))
        XCTAssertEqual(surface.anchor(of: input).frame.minX, originalAnchor.minX - 20)
        XCTAssertEqual(surface.anchor(of: input).frame.minY, originalAnchor.minY - 30)
        XCTAssertTrue(surface.islandRegions().contains { $0.contains(CGPoint(x: 70, y: 110)) })
        XCTAssertFalse(surface.islandRegions().contains { $0.contains(CGPoint(x: 85, y: 75)) })
        fixture.render()
        XCTAssertEqual(try fixture.target(), target)
        XCTAssertEqual(surface.manipulationTargets[target], originalSource)
        XCTAssertNotNil(surface.textInputs[input])
        XCTAssertEqual(surface.manipulation?.preview.origin, CGPoint(x: 60, y: 100))
    }

    func testCaptureContinuesAcrossAnInitiallyTransparentCanvasHole() throws {
        let fixture = try Fixture(Self.body)
        let surface = fixture.surface
        let hole = CGPoint(x: 400, y: 300)
        XCTAssertFalse(surface.hasAction(at: hole))
        XCTAssertFalse(surface.islandRegions().contains { $0.contains(hole) })
        fixture.beginMove(to: hole)
        XCTAssertNotNil(surface.pointerGesture?.selected)
        XCTAssertEqual(surface.manipulation?.preview.origin, CGPoint(x: 395, y: 295))
        XCTAssertTrue(surface.hasAction(at: hole))
        surface.drag(to: CGPoint(x: 410, y: 310), screen: .zero, timestamp: 0.015)
        XCTAssertEqual(surface.manipulation?.preview.origin, CGPoint(x: 405, y: 305))
        XCTAssertEqual(fixture.events.filter { $0.event.phase == .began }.count, 1)
        XCTAssertEqual(fixture.events.filter { $0.event.phase == .changed }.count, 0)
        surface.cancelInput()
        XCTAssertNil(surface.manipulation)
        XCTAssertNil(surface.pointerGesture)
        XCTAssertEqual(fixture.events.last?.event.phase, .cancelled)
    }

    func testMatchingLayoutEmitsAnApplicationReceiptAfterSceneSubmissionAndPreservesInputIdentity() async throws {
        let fixture = try Fixture(Self.body)
        let surface = fixture.surface
        let target = try fixture.target()
        let input = try XCTUnwrap(surface.textInputs.keys.first)
        let editor = try XCTUnwrap(surface.textInputs[input])
        editor.field?.stringValue = "edited note"
        editor.beganEditing()
        fixture.beginMove()
        let invocation = try fixture.releaseMove()
        let transaction = try XCTUnwrap(surface.manipulation?.transaction)
        XCTAssertEqual(surface.manipulation?.holding, true)
        fixture.render(acknowledgement: invocation - 1)
        XCTAssertEqual(surface.manipulation?.holding, true)
        XCTAssertFalse(fixture.events.contains { $0.event.phase == .applied })
        let applied = expectation(description: "scene application receipt")
        fixture.observed = { click in
            if click.event.phase == .applied { applied.fulfill() }
        }
        try fixture.invokeRelease()
        fixture.render(acknowledgement: invocation)
        XCTAssertNil(surface.manipulation)
        XCTAssertEqual(try fixture.target(), target)
        XCTAssertTrue(surface.textInputs[input] === editor)
        XCTAssertEqual(editor.text, "edited note")
        XCTAssertTrue(editor.editing)
        XCTAssertEqual(
            CGRect(surface.layout.core.absoluteFrame(of: target)),
            CGRect(x: 120, y: 100, width: 100, height: 80)
        )
        await fulfillment(of: [applied], timeout: 2)
        XCTAssertEqual(fixture.events.last?.event.transaction, transaction)
        XCTAssertEqual(fixture.events.last?.event.phase, .applied)
        XCTAssertEqual(fixture.events.last?.event.placement?.rect, CGRect(x: 120, y: 100, width: 100, height: 80))
    }

    func testAcknowledgementWithoutMatchingSuccessfulLayoutCancelsAndNeverApplies() throws {
        for delivery in 0 ..< 3 {
            let fixture = try Fixture(Self.body)
            let surface = fixture.surface
            let target = try fixture.target()
            let accepted = surface.layout.core.absoluteFrame(of: target)
            fixture.beginMove()
            let invocation = try fixture.releaseMove()
            switch delivery {
            case 0: surface.acknowledgeGesture(through: invocation)
            case 1:
                XCTAssertFalse(surface.apply([], text: fixture.text, gestureAcknowledgement: invocation))
            default: fixture.render(acknowledgement: invocation)
            }
            XCTAssertNil(surface.manipulation)
            XCTAssertEqual(surface.layout.core.absoluteFrame(of: target), accepted)
            XCTAssertFalse(fixture.events.contains { $0.event.phase == .applied })
            XCTAssertEqual(fixture.events.last?.event.phase, .cancelled)
            XCTAssertEqual(fixture.events.last?.event.reason, delivery < 2 ? "delivery" : "layout-rejected")
        }
    }

    func testResizePreviewClipsHitsShapesAndRegionsBeforeTheOneCommittedReflow() throws {
        let fixture = try Fixture(Self.body)
        let surface = fixture.surface
        let target = try fixture.target()
        let input = try XCTUnwrap(surface.textInputs.keys.first)
        surface.press(at: CGPoint(x: 175, y: 145), timestamp: 0)
        surface.drag(to: CGPoint(x: 145, y: 125), screen: .zero, timestamp: 0.01)
        XCTAssertEqual(surface.manipulation?.preview, CGRect(x: 80, y: 70, width: 70, height: 60))
        XCTAssertEqual(surface.layout.core.layoutFrame(of: target).width, 100)
        let clipped = CGPoint(x: 155, y: 110)
        XCTAssertFalse(surface.hasAction(at: clipped))
        XCTAssertFalse(surface.containsShape(at: clipped))
        XCTAssertFalse(surface.islandRegions().contains { $0.contains(clipped) })
        surface.release(at: CGPoint(x: 145, y: 125), timestamp: 0.02)
        let invocation = try XCTUnwrap(fixture.lastInvocation)
        try fixture.invokeRelease()
        fixture.render(acknowledgement: invocation)
        XCTAssertEqual(surface.layout.core.layoutFrame(of: target).width, 70)
        XCTAssertEqual(surface.layout.core.layoutFrame(of: target).height, 60)
        XCTAssertNotNil(surface.textInputs[input])
    }

    func testSelectingAnotherWidgetDemotesThePriorWrapperAndRelinquishesItsNativeEditor() throws {
        let fixture = try Fixture(Self.overlappingWidgets)
        let surface = fixture.surface
        let first = try XCTUnwrap(surface.manipulationTargets.keys.first {
            surface.layout.core.absoluteFrame(of: $0).x == 80
        })
        let second = try XCTUnwrap(surface.manipulationTargets.keys.first {
            surface.layout.core.absoluteFrame(of: $0).x == 140
        })
        let secondInput = surface.layout.core.firstDescendant(of: second) { $0.focusable }
        let native = try XCTUnwrap(surface.textInputs[secondInput])
        surface.selectManipulation(at: CGPoint(x: 205, y: 75))
        surface.focusDeclared(secondInput)
        XCTAssertTrue(surface.declaredFocus)
        XCTAssertFalse(native.view.isHidden)
        surface.selectManipulation(at: CGPoint(x: 85, y: 75))
        XCTAssertEqual(surface.selectedManipulation, first)
        XCTAssertFalse(surface.declaredFocus)
        XCTAssertTrue(native.view.isHidden)
        let top = surface.element(at: CGPoint(x: 150, y: 75)) { $0.acceptsPointer }
        XCTAssertEqual(surface.manipulationOwner(of: top), first)
        XCTAssertFalse(surface.allowsNativeHit(native.view, at: CGPoint(x: 150, y: 105)))
        let scene = surface.scene
        let positions = ShellLayerScene.engineQueue.sync {
            (scene.gestureLayers[first.slot]?.layer.zPosition, scene.gestureLayers[second.slot]?.layer.zPosition)
        }
        XCTAssertEqual(positions.0, 1)
        XCTAssertEqual(positions.1, 0)
    }

    func testReloadCancelsActiveAndHeldCapturesAndRejectsOldAcknowledgements() throws {
        for held in [false, true] {
            let fixture = try Fixture(Self.body)
            let surface = fixture.surface
            let target = try fixture.target()
            fixture.beginMove()
            let invocation = held ? try fixture.releaseMove() : 0
            surface.reset(text: ShellTextStore())
            XCTAssertNil(surface.manipulation)
            XCTAssertNil(surface.pointerGesture)
            XCTAssertFalse(surface.layout.core.contains(target))
            surface.acknowledgeGesture(through: invocation)
            XCTAssertFalse(fixture.events.contains { $0.event.phase == .applied })
            fixture.render()
            XCTAssertNotEqual(try fixture.target(), target)
            XCTAssertNil(surface.manipulation)
        }
    }
}
