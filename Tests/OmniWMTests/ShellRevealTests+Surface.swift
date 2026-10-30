// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellRevealTests {
    private static let surfaceBody = """
    local open=ctx.data.open
    return ui.stack{w=400,h=300,
        ui.box{decorative=true,w=400,h=300,fill='surface'},
        open and ui.stack{key='desk',reveal={response=0.482,bounce=0.31},align='topLeading',dx=100,dy=50,w=200,h=200,
            ui.stack{key='content',w=200,h=200,morph={anchor={x=1,y=0.5},stops={
                {at=0,scale=0.05,opacity=0},{at=0.02,scale=0.05,opacity=0},{at=0.0201,scale=0.05},
                {at=0.03125,scale=0.05},{at=0.625},{at=1},{at=1.25,scale=1.15}}},
                ui.box{key='button',align='topLeading',dx=140,dy=80,w=40,h=40,fill='accent',onClick=function() end},
                ui.input{key='field',align='topLeading',dx=20,dy=20,w=80,h=24,text='note'}}} or nil}
    """

    private static let ownedBody = surfaceBody.replacingOccurrences(
        of: "ui.stack{key='content'",
        with: "ui.box{key='grip',align='topLeading',w=200,h=20,onGesture=function() end,"
            + "gesture={axis='free',track={mode='move',target='desk',bounds={w=400,h=300},"
            + "min={w=200,h=200},max={w=200,h=200}}}},ui.stack{key='content'"
    )

    private func setOpen(_ fixture: Fixture, _ open: Bool) {
        var writer = ShellValueWriter()
        writer.bool(open)
        _ = writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(fixture.script.instance, "open", $0.baseAddress, $0.count)
        }
        fixture.render()
    }

    private func element(_ fixture: Fixture, _ predicate: (OmniWMShellCore.Paint, Content) -> Bool) throws
        -> ElementHandle
    {
        let layout = fixture.surface.layout
        return try XCTUnwrap(layout.core.elements { _ in true }.first {
            predicate(layout.core.paint(of: $0), layout.core.content(of: $0))
        })
    }

    private func expectedButton(at time: CFTimeInterval, plan: ShellReveal) -> CGRect {
        let progress = plan.state(at: time).progress
        let scale = progress <= 0.03125 ? 0.05 : min(1, 0.05 + (progress - 0.03125) / (0.625 - 0.03125) * 0.95)
        return CGRect(x: 300 + (240 - 300) * scale, y: 150 + (130 - 150) * scale, width: 40 * scale, height: 40 * scale)
    }

    func testOpeningHitsTheSampledGroupAndNotTheFinalLayout() throws {
        let clock = Clock()
        let fixture = try Fixture(Self.surfaceBody, animations: true) { clock.now }
        let surface = fixture.surface
        setOpen(fixture, true)
        let desk = try element(fixture) { paint, _ in paint.reveal != 0 }
        let button = try element(fixture) { _, content in content.action != 0 }
        let plan = try XCTUnwrap(surface.reveals[desk]?.plan)
        XCTAssertEqual(plan.begin, clock.now)
        XCTAssertEqual(plan.progress, 0)
        let layoutCenter = CGPoint(x: 260, y: 150)
        XCTAssertEqual(surface.element(at: layoutCenter) { $0.acceptsPointer }, .none)
        clock.now += 0.005
        XCTAssertLessThanOrEqual(plan.state(at: clock.now).progress, 0.02)
        let tiny = expectedButton(at: clock.now, plan: plan)
        XCTAssertFalse(surface.hasAction(at: CGPoint(x: tiny.midX, y: tiny.midY)))
        XCTAssertFalse(surface.hasAction(at: layoutCenter))
        clock.now += 0.055
        let sampled = expectedButton(at: clock.now, plan: plan)
        XCTAssertFalse(sampled.contains(layoutCenter))
        XCTAssertEqual(CGRect(surface.presentedFrame(of: button)).minX, sampled.minX, accuracy: 1e-3)
        XCTAssertEqual(CGRect(surface.presentedFrame(of: button)).width, sampled.width, accuracy: 1e-3)
        XCTAssertEqual(surface.element(at: CGPoint(x: sampled.midX, y: sampled.midY)) { $0.acceptsPointer }, button)
        XCTAssertNotEqual(surface.element(at: layoutCenter) { $0.acceptsPointer }, button)
        XCTAssertEqual(surface.islandRegions().filter { $0 == CGRect(x: 240, y: 130, width: 40, height: 40) }.count, 1)
        let field = try XCTUnwrap(surface.textInputs.first?.value)
        surface.layoutTextInputs()
        let editor = CGRect(surface.presentedFrame(of: field.handle))
        XCTAssertLessThan(editor.width, 80)
        XCTAssertEqual(field.view.frame.minX, editor.minX, accuracy: 1e-3)
        XCTAssertEqual(field.view.frame.minY, editor.minY, accuracy: 1e-3)
        XCTAssertEqual(field.view.frame.width, editor.width, accuracy: 1e-3)
        let point = CGPoint(x: sampled.minX + sampled.width * 0.75, y: sampled.minY + sampled.height * 0.25)
        surface.press(at: point, timestamp: 0)
        surface.release(at: point, timestamp: 0.01)
        let click = try XCTUnwrap(fixture.events.last)
        XCTAssertEqual(click.event.x, 30, accuracy: 1e-3)
        XCTAssertEqual(click.event.y, 10, accuracy: 1e-3)
        var moves = 0
        surface.onMove = { moves += 1 }
        let token = try XCTUnwrap(surface.reveals[desk]?.token)
        surface.revealSettled(desk.slot, token: token &+ 1)
        XCTAssertNotNil(surface.reveals[desk]?.plan)
        surface.revealSettled(desk.slot, token: token)
        surface.revealSettled(desk.slot, token: token)
        XCTAssertEqual(moves, 1)
        XCTAssertNil(surface.presentation)
        XCTAssertEqual(surface.element(at: layoutCenter) { $0.acceptsPointer }, button)
        XCTAssertEqual(field.view.frame.width, 80, accuracy: 1e-3)
    }

    func testRetiringDeskTakesNoHitsAndReopeningSeedsFromItsCloseState() throws {
        let clock = Clock()
        let fixture = try Fixture(Self.surfaceBody, animations: true) { clock.now }
        let surface = fixture.surface
        setOpen(fixture, true)
        let desk = try element(fixture) { paint, _ in paint.reveal != 0 }
        let opening = try XCTUnwrap(surface.reveals[desk]?.plan)
        clock.now += 0.12
        setOpen(fixture, false)
        XCTAssertTrue(surface.reveals.isEmpty)
        let identity = try XCTUnwrap(surface.retiringReveals.keys.first)
        let closing = try XCTUnwrap(surface.retiringReveals[identity])
        let before = opening.state(at: clock.now)
        XCTAssertEqual(closing.progress, before.progress)
        XCTAssertEqual(closing.velocity, before.velocity)
        XCTAssertEqual(closing.target, 0)
        let sampled = expectedButton(at: clock.now, plan: opening)
        for point in [CGPoint(x: 260, y: 150), CGPoint(x: sampled.midX, y: sampled.midY)] {
            XCTAssertFalse(surface.hasAction(at: point))
            XCTAssertFalse(surface.containsShape(at: point))
        }
        XCTAssertTrue(surface.islandRegions().isEmpty)
        clock.now += 0.1
        setOpen(fixture, true)
        let reopened = try XCTUnwrap(surface.reveals.values.first?.plan)
        let seed = closing.state(at: clock.now)
        XCTAssertEqual(reopened.progress, seed.progress)
        XCTAssertEqual(reopened.velocity, seed.velocity)
        XCTAssertGreaterThan(reopened.progress, 0.2)
        XCTAssertTrue(surface.retiringReveals.isEmpty)
    }

    func testReducedMotionPlansNothingAndPresentsTheLayout() throws {
        let fixture = try Fixture(Self.surfaceBody, animations: false)
        let surface = fixture.surface
        setOpen(fixture, true)
        let desk = try element(fixture) { paint, _ in paint.reveal != 0 }
        let button = try element(fixture) { _, content in content.action != 0 }
        XCTAssertNotNil(surface.reveals[desk])
        XCTAssertNil(surface.reveals[desk]?.plan)
        XCTAssertNil(surface.presentation)
        XCTAssertEqual(surface.element(at: CGPoint(x: 260, y: 150)) { $0.acceptsPointer }, button)
        setOpen(fixture, false)
        XCTAssertTrue(surface.retiringReveals.isEmpty)
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue(surface.scene.presence.retained.isEmpty)
            XCTAssertTrue(surface.scene.presence.revealPlans.isEmpty)
        }
    }

    func testOwnedEditorPresentsTransientlyUntilItsGroupSettlesOpen() throws {
        let clock = Clock()
        let fixture = try Fixture(Self.ownedBody, animations: true) { clock.now }
        let surface = fixture.surface
        setOpen(fixture, true)
        let desk = try element(fixture) { paint, _ in paint.reveal != 0 }
        let field = try XCTUnwrap(surface.textInputs.keys.first)
        XCTAssertNotNil(surface.manipulationOwner(of: field))
        let plan = try XCTUnwrap(surface.reveals[desk]?.plan)
        clock.now += 0.2
        XCTAssertGreaterThan(plan.state(at: clock.now).progress, 0.625)
        XCTAssertLessThan(plan.state(at: clock.now).progress, 1)
        XCTAssertEqual(surface.presentedScale(of: field, in: surface.presentation), 1)
        XCTAssertTrue(surface.editorPresentsTransiently(field, in: surface.presentation))
        try surface.revealSettled(desk.slot, token: XCTUnwrap(surface.reveals[desk]?.token))
        XCTAssertFalse(surface.editorPresentsTransiently(field, in: surface.presentation))
        setOpen(fixture, false)
        XCTAssertTrue(surface.textInputs.isEmpty)
    }

    func testLayoutChangeOfAMorphingGroupReplansFromTheCurrentState() throws {
        let clock = Clock()
        let body = Self.surfaceBody.replacingOccurrences(
            of: "ui.stack{key='content',w=200,h=200,", with: "ui.stack{key='content',w=ctx.data.width or 200,h=200,"
        )
        let fixture = try Fixture(body, animations: true) { clock.now }
        let surface = fixture.surface
        setOpen(fixture, true)
        let desk = try element(fixture) { paint, _ in paint.reveal != 0 }
        let first = try XCTUnwrap(surface.reveals[desk])
        let opening = try XCTUnwrap(first.plan)
        clock.now += 0.05
        fixture.render()
        XCTAssertEqual(surface.reveals[desk]?.token, first.token)
        var writer = ShellValueWriter()
        writer.number(160)
        _ = writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(fixture.script.instance, "width", $0.baseAddress, $0.count)
        }
        fixture.render()
        let replanned = try XCTUnwrap(surface.reveals[desk])
        let plan = try XCTUnwrap(replanned.plan)
        XCTAssertGreaterThan(replanned.token, first.token)
        XCTAssertEqual(plan.begin, clock.now)
        XCTAssertEqual(plan.progress, opening.state(at: clock.now).progress)
        XCTAssertEqual(plan.velocity, opening.state(at: clock.now).velocity)
        XCTAssertEqual(plan.target, 1)
    }

    func testHidingFinishesAnInFlightRevealOnce() throws {
        let clock = Clock()
        let fixture = try Fixture(Self.surfaceBody, animations: true) { clock.now }
        let surface = fixture.surface
        setOpen(fixture, true)
        var moves = 0
        surface.onMove = { moves += 1 }
        XCTAssertNotNil(surface.presentation)
        surface.setVisible(false)
        XCTAssertNil(surface.presentation)
        XCTAssertEqual(moves, 1)
        surface.setVisible(true)
        surface.setVisible(false)
        XCTAssertEqual(moves, 1)
    }

    func testHidingDropsCloseSeedsTheSceneNoLongerRetains() throws {
        let clock = Clock()
        let fixture = try Fixture(Self.surfaceBody, animations: true) { clock.now }
        let surface = fixture.surface
        setOpen(fixture, true)
        clock.now += 0.12
        setOpen(fixture, false)
        XCTAssertFalse(surface.retiringReveals.isEmpty)
        surface.setVisible(false)
        XCTAssertTrue(surface.retiringReveals.isEmpty)
        setOpen(fixture, true)
        clock.now += 0.12
        setOpen(fixture, false)
        XCTAssertTrue(surface.retiringReveals.isEmpty)
        surface.setVisible(true)
        ShellLayerScene.engineQueue.sync { XCTAssertTrue(surface.scene.presence.retained.isEmpty) }
        clock.now += 0.05
        setOpen(fixture, true)
        XCTAssertEqual(surface.reveals.values.first?.plan?.progress, 0)
    }

    private static let siblingsBody = """
    local open=ctx.data.open
    local function root(key, dx)
        return ui.stack{key=key,reveal={response=0.482,bounce=0.31},align='topLeading',dx=dx,w=100,h=100,
            ui.stack{key=key..'-content',w=100,h=100,morph={anchor={x=1,y=0.5},stops={
                {at=0,scale=0.05,opacity=0},{at=1}}},
                ui.box{w=100,h=100,fill='accent',onClick=function() end}}}
    end
    return ui.stack{w=400,h=300,
        ui.box{decorative=true,w=400,h=300,fill='surface'},
        open and ui.box{key='plain',align='topLeading',w=10,h=10,fill='accent'} or nil,
        open and root('first', 20) or nil,
        open and root('second', 200) or nil}
    """

    func testRemovingSiblingsTogetherKeepsEveryRevealClose() throws {
        let clock = Clock()
        let fixture = try Fixture(Self.siblingsBody, animations: true) { clock.now }
        let surface = fixture.surface
        setOpen(fixture, true)
        XCTAssertEqual(surface.reveals.count, 2)
        clock.now += 0.12
        setOpen(fixture, false)
        XCTAssertTrue(surface.reveals.isEmpty)
        XCTAssertEqual(surface.retiringReveals.count, 2)
        XCTAssertTrue(surface.retiringReveals.values.allSatisfy { $0.target == 0 && $0.progress > 0.2 })
    }

    private static let trackedBody = """
    local open=ctx.data.open
    return ui.stack{w=400,h=300,
        ui.box{decorative=true,w=400,h=300,fill='surface'},
        open and ui.stack{key='desk',reveal={response=0.482,bounce=0.31},align='topLeading',dx=100,dy=50,w=200,h=200,
            ui.glass{key='glass',w=200,h=200,blend=0,fill='#FFFFFFFF',blurRadius=0,shadow='#00000000',
                shadowRadius=0,saturation=1,
                ui.shape{key='card',w=200,h=200,radius=16,reveal={response=0.482,bounce=0.31},
                    morph={anchor={x=1,y=0.5},stops={{at=0,scale=0.05},{at=1,scale=1}}}}},
            ui.box{key='grip',align='topLeading',w=200,h=20,onGesture=function() end,
                gesture={axis='free',track={mode='move',target='desk',bounds={w=400,h=300},
                    min={w=200,h=200},max={w=200,h=200}}}},
            ui.stack{key='content',w=200,h=200,morph={anchor={x=1,y=0.5},stops={
                {at=0,scale=0.05,opacity=0},{at=1}}},
                ui.input{key='field',align='topLeading',dx=20,dy=40,w=80,h=24,text='note'}}} or nil}
    """

    private func keyed(_ fixture: Fixture, _ name: String) throws -> ElementHandle {
        let key = name.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
            & ~(UInt64(3) << 62)
        let layout = fixture.surface.layout
        return try XCTUnwrap(layout.core.elements { _ in true }.first { layout.core.key(of: $0) == key })
    }

    private func assertRevealRuns(
        _ fixture: Fixture, desk: ElementHandle, card: ElementHandle, content: ElementHandle, _ message: String
    ) throws {
        XCTAssertNotNil(fixture.surface.reveals[desk]?.plan, message)
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            XCTAssertNotNil(scene.presence.revealPlans[desk.slot], message)
            XCTAssertNotNil(scene.presence.revealPlans[card.slot], message)
            XCTAssertNotNil(
                scene.presentedContent(content.slot)?.animation(forKey: ShellLayerScene.revealTransformKey), message
            )
            let entry = try XCTUnwrap(scene.shapeTracks.entries[card.slot], message)
            XCTAssertNotNil(entry.plan, message)
            XCTAssertFalse(entry.animations.isEmpty, message)
            let layers = try XCTUnwrap(scene.glassBodies[entry.body]).lockstepLayers(card.slot)
            XCTAssertFalse(layers.isEmpty, message)
            for layer in layers {
                XCTAssertNotNil(layer.animation(forKey: "omni.glass.position"), message)
            }
        }
    }

    func testUnrelatedUnanimatedUpdatesKeepTheRevealAndItsShapeTrackRunning() throws {
        let clock = Clock()
        let fixture = try Fixture(Self.trackedBody, animations: true) { clock.now }
        let surface = fixture.surface
        let container = surface.scene.container
        let renderer = try ShellLayerScene.engineQueue.sync {
            container.removeFromSuperlayer()
            return try ShellOffscreenRenderer(root: container, width: 400, height: 300)
        }
        defer { withExtendedLifetime(renderer) {} }
        setOpen(fixture, true)
        let desk = try keyed(fixture, "desk")
        let card = try keyed(fixture, "card")
        let content = try keyed(fixture, "content")
        XCTAssertNotNil(surface.manipulationOwner(of: try keyed(fixture, "field")))
        try assertRevealRuns(fixture, desk: desk, card: card, content: content, "opened")
        clock.now += 0.05
        surface.selectManipulation(owner: desk)
        surface.hover(at: CGPoint(x: 150, y: 60))
        surface.layoutTextInputs()
        try assertRevealRuns(fixture, desk: desk, card: card, content: content, "selected")
        surface.press(at: CGPoint(x: 150, y: 60), timestamp: 0)
        surface.drag(to: CGPoint(x: 170, y: 80), screen: .zero, timestamp: 0.01)
        XCTAssertEqual(surface.manipulation?.target, desk)
        try assertRevealRuns(fixture, desk: desk, card: card, content: content, "grabbed")
        surface.cancelInput()
    }

    func testAManipulatedGroupComposesItsMorphInsideThePlacement() throws {
        let clock = Clock()
        let fixture = try Fixture(Self.surfaceBody, animations: true) { clock.now }
        let surface = fixture.surface
        setOpen(fixture, true)
        let desk = try element(fixture) { paint, _ in paint.reveal != 0 }
        let content = try element(fixture) { paint, _ in paint.morph != 0 }
        clock.now += 0.06
        let root = try XCTUnwrap(surface.reveals[desk])
        let recipe = try XCTUnwrap(root.groups.first { $0.handle == content }?.recipe)
        let stop = recipe.stop(at: try XCTUnwrap(root.plan).state(at: clock.now).progress)
        let layout = CGRect(surface.layout.core.layoutFrame(of: content))
        let local = recipe.scaled(layout, by: stop.scale)
        let base = SurfacePresentation(targets: [
            content: .init(frame: Rect(x: 120, y: 60, width: 100, height: 100), scale: 0.5, visible: true)
        ])
        let placement = try XCTUnwrap(surface.revealPresentation(over: base)?.placement(of: content))
        XCTAssertEqual(CGFloat(placement.frame.x), 120 + (local.minX - layout.minX) * 0.5, accuracy: 1e-3)
        XCTAssertEqual(CGFloat(placement.frame.y), 60 + (local.minY - layout.minY) * 0.5, accuracy: 1e-3)
        XCTAssertEqual(CGFloat(placement.frame.width), local.width * 0.5, accuracy: 1e-3)
        XCTAssertEqual(CGFloat(placement.scale), CGFloat(stop.scale) * 0.5, accuracy: 1e-5)
        XCTAssertEqual(placement.visible, stop.opacity > 0)
    }
}
