// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellPointerEventTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let script: ShellScriptHostTests.Script
        let surface: ShellWidgetSurface
        let text = ShellTextStore()
        var events: [ShellClick] = []

        init(_ body: String) throws {
            script = try ShellScriptHostTests.Script("function render(ctx) " + body + " end")
            surface = ShellWidgetSurface(
                scale: 2,
                resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
                directories: []
            )
            surface.onAction = { [weak self] in self?.events.append($0) }
            render()
        }

        func render(_ value: Double = 0) {
            XCTAssertEqual(omni_instance_set_number(script.instance, "seconds", value), OMNI_OK)
            XCTAssertEqual(script.render().status, OMNI_OK, script.message)
            text.ingest(wire: script.output)
            surface.sequence += 1
            XCTAssertTrue(surface.apply(script.output, text: text))
            ShellLayerScene.engineQueue.sync {}
        }
    }

    func testPressPaintIsNativeAndRestoresOnRelease() throws {
        let fixture =
            try Fixture("return ui.box{w=40,h=20,fill='accent',pressOpacity=0.4,pressScale=0.9,onClick='focus left'}")
        let surface = fixture.surface
        let root = surface.layout.core.rootHandle
        let scene = surface.scene
        surface.press(at: CGPoint(x: 8, y: 7))
        XCTAssertTrue(fixture.events.isEmpty)
        let pressedOpacity = ShellLayerScene.engineQueue.sync { scene.layers[root.slot]?.opacity }
        XCTAssertEqual(pressedOpacity, 0.4)
        surface.release(at: CGPoint(x: 8, y: 7))
        XCTAssertEqual(fixture.events.count, 1)
        XCTAssertEqual(fixture.events[0].event.x, 8)
        XCTAssertEqual(fixture.events[0].event.y, 7)
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.layers[root.slot]?.opacity }, 1)
    }

    func testExplicitZeroPressScaleIsAppliedAndRestoredWithoutALuauHandler() throws {
        let fixture = try Fixture("return ui.box{w=40,h=20,pressScale=0}")
        let surface = fixture.surface
        let root = surface.layout.core.rootHandle
        let scene = surface.scene
        XCTAssertTrue(surface.hasAction(at: CGPoint(x: 8, y: 7)))
        surface.press(at: CGPoint(x: 8, y: 7))
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.scales[root.slot] }, 0)
        XCTAssertTrue(fixture.events.isEmpty)
        surface.release(at: CGPoint(x: 8, y: 7))
        XCTAssertNil(ShellLayerScene.engineQueue.sync { scene.scales[root.slot] })
        XCTAssertTrue(fixture.events.isEmpty)
    }

    func testPressLifecycleCancelsOutsideAndCarriesLocalCoordinates() throws {
        let fixture =
            try Fixture(
                "return ui.box{w=40,h=20,pad=4,center=false,ui.box{w=20,h=10,onPress=function() end,onClick=function() end}}"
            )
        let surface = fixture.surface
        var input = ShellEvent(button: .left, shift: true)
        input.clicks = 2
        surface.press(at: CGPoint(x: 7, y: 6), event: input)
        surface.release(at: CGPoint(x: 7, y: 6), event: input)
        XCTAssertEqual(fixture.events.map(\.event.phase), [.down, .up, nil])
        XCTAssertEqual(fixture.events.first?.event.x, 3)
        XCTAssertEqual(fixture.events.first?.event.y, 2)
        XCTAssertEqual(fixture.events.first?.event.clicks, 2)
        XCTAssertEqual(fixture.events.first?.event.shift, true)
        fixture.events.removeAll()
        surface.press(at: CGPoint(x: 7, y: 6))
        surface.release(at: CGPoint(x: 70, y: 60))
        XCTAssertEqual(fixture.events.map(\.event.phase), [.down, .cancel])
    }

    func testRemovedPressedNodeCancelsWithCapturedSequence() throws {
        let fixture =
            try Fixture("return ui.box{key=ctx.data.seconds==0 and 'old' or 'new',w=40,h=20,onPress=function() end}")
        fixture.surface.press(at: CGPoint(x: 3, y: 2))
        let sequence = fixture.surface.sequence
        fixture.render(1)
        XCTAssertEqual(fixture.events.map(\.event.phase), [.down, .cancel])
        XCTAssertEqual(fixture.events.last?.sequence, sequence)
        XCTAssertEqual(fixture.surface.pressed, .none)
    }

    func testInputDeclarationCacheRefreshesWithTheTreeAndReset() throws {
        let fixture =
            try Fixture(
                "return ui.box{w=40,h=20,onHover=ctx.data.seconds==1 and function() end or nil,onOutsidePress=ctx.data.seconds==1 and function() end or nil}"
            )
        let surface = fixture.surface
        XCTAssertFalse(surface.hasHoverHandlers)
        XCTAssertTrue(surface.outsidePressTargets.isEmpty)
        surface.hover(at: CGPoint(x: 3, y: 2))
        XCTAssertNil(surface.hoverIntent)
        fixture.render(1)
        XCTAssertTrue(surface.hasHoverHandlers)
        XCTAssertEqual(surface.outsidePressTargets, [surface.layout.core.rootHandle])
        surface.reset(text: fixture.text)
        XCTAssertFalse(surface.hasHoverHandlers)
        XCTAssertTrue(surface.outsidePressTargets.isEmpty)
        XCTAssertNil(surface.hoverIntent)
    }

    func testDwellCancelsOnEarlyExitAndGraceCancelsOnReentry() throws {
        let fixture = try Fixture("return ui.box{w=40,h=20,hoverDelay=60,hoverGrace=60,onHover=function() end}")
        let surface = fixture.surface
        let point = CGPoint(x: 3, y: 2)
        surface.hover(at: point)
        let early = try XCTUnwrap(surface.hoverIntent)
        surface.hover(at: nil)
        surface.advanceHoverIntent(ending: false, capture: early)
        XCTAssertTrue(fixture.events.isEmpty)
        surface.hover(at: point)
        let active = try XCTUnwrap(surface.hoverIntent)
        surface.advanceHoverIntent(ending: false, capture: active)
        XCTAssertEqual(fixture.events.map(\.event.phase), [.began])
        surface.hover(at: nil)
        XCTAssertTrue(surface.hoverEnding)
        surface.hover(at: point)
        XCTAssertFalse(surface.hoverEnding)
        XCTAssertEqual(fixture.events.count, 1)
        surface.hover(at: nil)
        surface.advanceHoverIntent(ending: true, capture: active)
        XCTAssertEqual(fixture.events.map(\.event.phase), [.began, .ended])
        XCTAssertNil(surface.hoverTimer)
    }

    func testPointerGestureCapturesOutsideWithoutChangedCallsByDefault() throws {
        let fixture =
            try Fixture(
                "return ui.box{w=40,h=20,onPress=function() end,onClick=function() end,gesture={axis='x',commit={distance=30}},onGesture=function() end}"
            )
        let surface = fixture.surface
        surface.press(at: CGPoint(x: 3, y: 2), timestamp: 0)
        surface.drag(to: CGPoint(x: 8, y: 2), screen: .zero, timestamp: 0.01)
        surface.drag(to: CGPoint(x: 200, y: 2), screen: .zero, timestamp: 0.02)
        surface.release(at: CGPoint(x: 201, y: 2), timestamp: 0.03)
        XCTAssertEqual(fixture.events.map(\.event.phase), [.down, .cancel, .began, .ended])
        XCTAssertEqual(fixture.events.last?.event.dx, 198)
        XCTAssertEqual(fixture.events.last?.event.committed, true)
        XCTAssertNil(surface.pointerGesture)
        XCTAssertEqual(surface.pressed, .none)
    }

    func testScrollEndPreservesReleaseVelocity() throws {
        let fixture =
            try Fixture(
                "return ui.box{w=40,h=20,gesture={axis='x',source='scroll',commit={velocity=100}},onGesture=function() end}"
            )
        let point = CGPoint(x: 3, y: 2)
        var event = ShellEvent(button: .none)
        event.phase = .began
        XCTAssertTrue(fixture.surface.scroll(at: point, event: event, timestamp: 0))
        event.phase = .changed
        event.dx = 6
        XCTAssertTrue(fixture.surface.scroll(at: point, event: event, timestamp: 0.01))
        event.phase = .ended
        event.dx = 0
        XCTAssertTrue(fixture.surface.scroll(at: point, event: event, timestamp: 0.02))
        XCTAssertEqual(fixture.events.map(\.event.phase), [.began, .ended])
        XCTAssertEqual(fixture.events.last?.event.dx, 6)
        XCTAssertEqual(fixture.events.last?.event.vx, 300)
        XCTAssertEqual(fixture.events.last?.event.committed, true)
    }

    func testExistingSlidersAndWindowDragsKeepPointerOwnership() throws {
        let slider =
            try Fixture(
                "return ui.box{w=40,h=20,gesture={axis='x'},onGesture=function() end,ui.slider{w=40,h=12,onChange=function() end}}"
            )
        slider.surface.press(at: CGPoint(x: 6, y: 6), timestamp: 0)
        slider.surface.drag(to: CGPoint(x: 20, y: 6), screen: .zero, timestamp: 0.01)
        slider.surface.release(at: CGPoint(x: 34, y: 6), timestamp: 0.02)
        XCTAssertEqual(slider.events.map(\.event.phase), [.began, .changed, .ended])
        XCTAssertTrue(slider.events.allSatisfy { $0.event.kind == .slider })
        XCTAssertEqual(slider.events.last?.event.value, 1)
        let window =
            try Fixture(
                "return ui.box{w=40,h=20,gesture={axis='x'},onGesture=function() end,ui.box{w=40,h=20,drag=true,target='window ow_a',onClick='focus left'}}"
            )
        var drags: [String] = []
        window.surface.onDrag = {
            switch $0 {
            case .began: drags.append("began")
            case .moved: drags.append("moved")
            case .ended: drags.append("ended")
            }
        }
        window.surface.press(at: CGPoint(x: 3, y: 2), timestamp: 0)
        window.surface.drag(to: CGPoint(x: 8, y: 2), screen: .zero, timestamp: 0.01)
        XCTAssertTrue(drags.isEmpty)
        window.surface.drag(to: CGPoint(x: 10, y: 2), screen: .zero, timestamp: 0.02)
        XCTAssertTrue(window.surface.endDrag(at: .zero))
        XCTAssertEqual(drags, ["began", "ended"])
        XCTAssertTrue(window.events.isEmpty)
    }

    func testFocusOnlyBlurDoesNotRestartHoverAndHiddenTreeCannotRearmIt() throws {
        let fixture = try Fixture("return ui.box{w=40,h=20,focusable=true,onHover=function() end}")
        let surface = fixture.surface
        surface.hover(at: CGPoint(x: 3, y: 2))
        surface.press(at: CGPoint(x: 3, y: 2))
        surface.release(at: CGPoint(x: 3, y: 2))
        surface.blurDeclaredFocus()
        fixture.render(1)
        XCTAssertEqual(fixture.events.map(\.event.phase), [.began])
        surface.setVisible(false)
        fixture.render(2)
        XCTAssertEqual(fixture.events.map(\.event.phase), [.began, .ended])
        XCTAssertNil(surface.hoverIntent)
    }

    func testMomentumIsOptInAndDoesNotReopenGesture() throws {
        for deliver in [false, true] {
            let fixture =
                try Fixture(
                    "return ui.box{w=40,h=20,scrollMomentum='\(deliver ? "deliver" : "consume")',onScroll=function() end,gesture={source='scroll',axis='y'},onGesture=function() end}"
                )
            var event = ShellEvent(button: .none)
            event.dy = 12
            event.phase = .changed
            event.momentum = .changed
            XCTAssertTrue(fixture.surface.scroll(at: CGPoint(x: 3, y: 2), event: event, momentum: true))
            XCTAssertEqual(fixture.events.count, deliver ? 1 : 0)
            XCTAssertNil(fixture.surface.pointerGesture)
            if deliver { XCTAssertEqual(fixture.events.first?.event.momentum, .changed) }
        }
    }

    func testScrollAxisMismatchReleasesToRawScrollUntilSequenceEnds() throws {
        let fixture =
            try Fixture(
                "return ui.box{w=40,h=20,onScroll=function() end,gesture={source='scroll',axis='y'},onGesture=function() end}"
            )
        let point = CGPoint(x: 3, y: 2)
        var event = ShellEvent(button: .none)
        event.phase = .began
        XCTAssertTrue(fixture.surface.scroll(at: point, event: event, timestamp: 0))
        XCTAssertTrue(fixture.events.isEmpty)
        event.phase = .changed
        event.dx = 12
        XCTAssertTrue(fixture.surface.scroll(at: point, event: event, timestamp: 0.01))
        XCTAssertEqual(fixture.events.map(\.event.kind), [.scroll])
        event.dx = 0
        event.dy = 20
        XCTAssertTrue(fixture.surface.scroll(at: point, event: event, timestamp: 0.02))
        XCTAssertEqual(fixture.events.map(\.event.kind), [.scroll, .scroll])
        event.phase = .ended
        event.dy = 0
        XCTAssertTrue(fixture.surface.scroll(at: point, event: event, timestamp: 0.03))
        XCTAssertEqual(fixture.events.map(\.event.kind), [.scroll, .scroll, .scroll])
        XCTAssertNil(fixture.surface.pointerGesture)
        event.phase = .began
        event.dy = 12
        XCTAssertTrue(fixture.surface.scroll(at: point, event: event, timestamp: 1))
        XCTAssertEqual(fixture.events.last?.event.kind, .gesture)
        XCTAssertEqual(fixture.events.last?.event.phase, .began)
    }

    func testDeclaredFocusTransfersAcrossPromotionWithoutAcquiringFromData() throws {
        let body = """
        return ui.row{
            ui.box{key='a',w=40,h=20,focusable=ctx.data.seconds==0,keys={'right'},onKey=function() end,
                ui.box{w=20,h=10,onClick=function() end}},
            ui.box{key='b',w=40,h=20,focusable=ctx.data.seconds==1,keys={'right'},onKey=function() end}
        }
        """
        let fixture = try Fixture(body)
        let surface = fixture.surface
        var focus: [Bool] = []
        surface.onFocusChange = { focus.append($0) }
        surface.press(at: CGPoint(x: 3, y: 2))
        surface.release(at: CGPoint(x: 3, y: 2))
        let first = surface.focused
        XCTAssertEqual(focus, [true])
        XCTAssertTrue(surface.declaredFocus)
        fixture.render(1)
        XCTAssertTrue(surface.layout.core.contains(first))
        XCTAssertNotEqual(surface.focused, first)
        XCTAssertEqual(focus, [true])
        XCTAssertTrue(surface.declaredFocus)
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: UInt16(kVK_RightArrow)
        ))
        XCTAssertTrue(surface.handleDeclaredKey(event))
        XCTAssertEqual(fixture.events.last?.source, surface.focused)
        XCTAssertEqual(fixture.events.last?.action, surface.layout.core.content(of: surface.focused).keyAction)
        XCTAssertEqual(fixture.events.last?.sequence, surface.sequence)
        fixture.render(2)
        XCTAssertFalse(surface.declaredFocus)
        XCTAssertEqual(focus, [true, false])
        let passive = try Fixture(body)
        passive.render(1)
        XCTAssertFalse(passive.surface.declaredFocus)
        XCTAssertEqual(passive.surface.focused, .none)
        XCTAssertFalse(passive.surface.handleDeclaredKey(event))
    }

    func testFocusRingOptOutChangesOnlyPaintWhileDeclaredKeysAndFocusStayLive() throws {
        let fixture = try Fixture("""
        return ui.box{w=80,h=40,fill='#000000',border='#ff0000',borderWidth=1,
            focusable=true,focusRing=ctx.data.seconds~=1,keys={'left','escape'},onKey=function() end}
        """)
        let surface = fixture.surface
        let root = surface.layout.core.rootHandle
        let scene = surface.scene
        var focus: [Bool] = []
        surface.onFocusChange = { focus.append($0) }
        surface.press(at: CGPoint(x: 3, y: 2))
        surface.release(at: CGPoint(x: 3, y: 2))
        let left = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_LeftArrow)
        ))
        for (value, width) in [(0.0, CGFloat(2)), (1.0, CGFloat(1)), (2.0, CGFloat(2))] {
            fixture.render(value)
            XCTAssertTrue(surface.declaredFocus)
            XCTAssertEqual(surface.focused, root)
            XCTAssertEqual(focus, [true])
            XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.layers[root.slot]?.borderWidth }, width)
            XCTAssertTrue(surface.handleDeclaredKey(left))
            XCTAssertEqual(fixture.events.last?.event.key, "left")
            XCTAssertEqual(fixture.events.last?.source, root)
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Escape)
        ))
        XCTAssertTrue(surface.handleDeclaredKey(escape))
        XCTAssertEqual(focus, [true, false])
        XCTAssertFalse(surface.declaredFocus)
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.layers[root.slot]?.borderWidth }, 1)
    }

    func testContainerOptOutPreventsDescendantFallbackButChildFocusKeepsItsDefaultRing() throws {
        let fixture = try Fixture("""
        return ui.box{w=80,h=40,focusable=true,focusRing=false,keys={'left'},onKey=function() end,
            ui.box{w=60,h=30,focusable=true,hover='#ffffff22',keys={'right'},onKey=function() end}}
        """)
        let surface = fixture.surface
        let root = surface.layout.core.rootHandle
        let child = surface.layout.core.firstDescendant(of: root) { $0.focusable }
        XCTAssertTrue(surface.layout.core.contains(child))
        let scene = surface.scene
        surface.focusDeclared(root)
        XCTAssertTrue(surface.focusPath().contains(child))
        XCTAssertEqual(surface.ringed, .none)
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.layers[child.slot]?.borderWidth }, 0)
        surface.focusDeclared(child)
        XCTAssertTrue(surface.declaredFocus)
        XCTAssertEqual(surface.ringed, child)
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.layers[root.slot]?.borderWidth }, 0)
        XCTAssertEqual(ShellLayerScene.engineQueue.sync { scene.layers[child.slot]?.borderWidth }, 2)
    }

    func testDeclaredKeysConsumeOnlyTheirNamesAndEscapeReleasesFocus() throws {
        let fixture = try Fixture("return ui.box{w=40,h=20,focusable=true,keys={'left','escape'},onKey=function() end}")
        let surface = fixture.surface
        var focus: [Bool] = []
        surface.onFocusChange = { focus.append($0) }
        surface.press(at: CGPoint(x: 3, y: 2))
        surface.release(at: CGPoint(x: 3, y: 2))
        XCTAssertEqual(focus, [true])
        let make = { (code: Int, characters: String) throws in
            try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 1,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: UInt16(code)
            ))
        }
        XCTAssertFalse(surface.handleDeclaredKey(try make(kVK_RightArrow, "")))
        XCTAssertTrue(surface.handleDeclaredKey(try make(kVK_LeftArrow, "")))
        XCTAssertEqual(fixture.events.last?.event.key, "left")
        XCTAssertTrue(surface.handleDeclaredKey(try make(kVK_Escape, "")))
        XCTAssertEqual(focus, [true, false])
        XCTAssertFalse(surface.declaredFocus)
    }
}
