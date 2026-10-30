// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import QuartzCore
import XCTest

@MainActor
extension ShellBoundTrackTests {
    private var pulseImpulseBody: String {
        Self.pulseBody.replacingOccurrences(
            of: "key='up',dx=80,", with: "key='up',dx=(ctx.data.vars or {}).pulseX or 80,"
        ).replacingOccurrences(
            of: "morph={trigger={shape='bound',at=0.7,rising=true},",
            with: """
            morph={trigger={shape='bound',at=0.7,rising=true},
                impulses={{after=0.05,spring={response=0.2},velocity=60,w=1}},
            """
        )
    }

    func testPulseRebuildPreservesTheImpulsesOfEveryFuturePlan() throws {
        let clock = ShellManipulationSurfaceTests.Clock()
        let fixture = try Fixture(pulseImpulseBody, animations: true, clock: { clock.now })
        let source = try helper.shape(fixture, "bound").slot
        let pulse = try helper.shape(fixture, "up").slot
        send(try input(at: clock.now, spring: .init(mass: 1, stiffness: 100, damping: 2)), to: source, on: fixture)
        let expected = try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[pulse])
            XCTAssertGreaterThan(entry.triggerPlans.count, 1)
            return entry.triggerPlans.map { $0.begin + 0.05 }.sorted()
        }
        helper.setValues(fixture, numbers: ["pulseX": 84])
        fixture.render()
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[pulse])
            XCTAssertEqual(entry.impulses.map(\.begin).sorted(), expected)
            XCTAssertTrue(entry.impulses.allSatisfy { $0.velocity == 60 })
        }
    }

    func testPointerRevisionsKeepACarriedPulsesPendingImpulseAndAnimationGeneration() throws {
        let clock = ShellManipulationSurfaceTests.Clock()
        let fixture = try Fixture(pulseImpulseBody, animations: true, clock: { clock.now })
        let source = try helper.shape(fixture, "bound").slot
        let pulse = try helper.shape(fixture, "up").slot
        let layout = CGRect(x: 386, y: 70, width: 200, height: 160)
        func sample(_ x: Double) {
            send(ShellBoundInput(
                layout: layout, canvas: CGRect(x: 0, y: 0, width: 700, height: 400),
                presentation: .still(translation: CGPoint(x: x, y: 0), scale: 1, clip: nil),
                active: true, time: clock.now
            ), to: source, on: fixture)
        }
        sample(-40)
        let before = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[pulse])
        }
        let start = try XCTUnwrap(before.triggerPlans.first).begin
        XCTAssertEqual(before.impulses.map(\.begin), [start + 0.05])
        for index in 1 ... 3 {
            clock.now = start + Double(index) / 120
            sample(-40 - Double(index))
            try ShellLayerScene.engineQueue.sync {
                let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[pulse])
                XCTAssertEqual(entry.triggerPlans, before.triggerPlans)
                XCTAssertEqual(entry.begin, before.begin)
                XCTAssertEqual(entry.base.begin, before.base.begin)
                XCTAssertEqual(entry.generation, before.generation)
                XCTAssertEqual(entry.impulses.map(\.begin), [start + 0.05])
            }
        }
        clock.now = start + 0.03
        let retarget = try XCTUnwrap(ShellManipulationMotion(
            from: layout.offsetBy(dx: -43, dy: 0), velocity: .init(x: 500, y: 0, width: 0),
            to: layout.offsetBy(dx: -40, dy: 0), begin: clock.now, spring: helper.desk
        ))
        send(ShellBoundInput(
            layout: layout, canvas: CGRect(x: 0, y: 0, width: 700, height: 400),
            presentation: .motion(retarget.wrapper(for: layout)), active: true, time: clock.now
        ), to: source, on: fixture)
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[pulse])
            XCTAssertGreaterThan(entry.triggerPlans.count, 1)
            XCTAssertEqual(entry.triggerPlans.first?.begin, start)
            XCTAssertEqual(entry.impulses.map(\.begin).sorted(), entry.triggerPlans.map { $0.begin + 0.05 }.sorted())
        }
    }

    func testTriggeredPulsesCanChainFromABoundHead() throws {
        let body = Self.pulseBody.replacingOccurrences(
            of: "ui.shape{key='down',", with: """
            ui.shape{key='tail',dx=300,dy=260,w=30,h=20,hit=false,
                reveal={response=0.12},morph={trigger={shape='up',at=0.5,rising=true},
                    stops={{at=0,w=0},{at=1}}}},
            ui.shape{key='down',
            """
        )
        let begin = CACurrentMediaTime()
        let fixture = try Fixture(body, animations: true, clock: { begin })
        let source = try helper.shape(fixture, "bound").slot
        let head = try helper.shape(fixture, "up").slot
        let tail = try helper.shape(fixture, "tail").slot
        send(try input(at: begin, spring: .init(mass: 1, stiffness: 100, damping: 2)), to: source, on: fixture)
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let plans = try XCTUnwrap(scene.shapeTracks.entries[head]).triggerPlans
            XCTAssertGreaterThan(plans.count, 1)
            let crossings = plans.flatMap { $0.crossings(at: 0.5, rising: true) }.sorted()
            XCTAssertFalse(crossings.isEmpty)
            let entry = try XCTUnwrap(scene.shapeTracks.entries[tail])
            XCTAssertNil(entry.plan)
            XCTAssertEqual(entry.triggerPlans.map(\.begin), crossings)
            XCTAssertGreaterThan(entry.shape(at: crossings[0] + 0.03).rect.width, 1)
        }
    }

    func testSwitchingToARevealSourceClearsTheOldMultiPlanOwner() throws {
        let body = Self.pulseBody.replacingOccurrences(
            of: "trigger={shape='bound',at=0.7,rising=true}",
            with: "trigger={shape=(ctx.data.vars or {}).triggerSource or 'bound',at=0.7,rising=true}"
        ).replacingOccurrences(of: "ui.shape{key='down',", with: """
        ui.shape{key='leader',dx=300,dy=300,w=20,h=20,hit=false,
            reveal={response=0.3},morph={stops={{at=0,w=0},{at=1}}}},
        ui.shape{key='down',
        """)
        let begin = CACurrentMediaTime()
        let fixture = try Fixture(body, animations: true, clock: { begin })
        let source = try helper.shape(fixture, "bound").slot
        let pulse = try helper.shape(fixture, "up").slot
        let leader = try helper.shape(fixture, "leader").slot
        send(try input(at: begin), to: source, on: fixture)
        XCTAssertFalse(ShellLayerScene.engineQueue.sync {
            fixture.surface.scene.shapeTracks.entries[pulse]?.triggerPlans.isEmpty ?? true
        })
        let plan = ShellReveal(
            begin: begin + 1, progress: 0, target: 1,
            spring: ShellMorphRecipe.Spring(response: 0.3, bounce: 0).parameters
        )
        fixture.surface.scene.submit([.reveal(slot: leader, token: 20, plan)], animated: true)
        ShellLayerScene.engineQueue.sync {}
        helper.setValues(fixture, strings: ["triggerSource": "leader"])
        fixture.render()
        let crossing = try XCTUnwrap(plan.crossings(at: 0.7, rising: true).first)
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[pulse])
            XCTAssertTrue(entry.triggerPlans.isEmpty)
            XCTAssertNil(entry.triggerRevision)
            XCTAssertEqual(entry.plan?.begin, crossing)
            XCTAssertGreaterThan(entry.shape(at: crossing + 0.03).rect.width, 1)
        }
    }

    func testFutureTriggerWaitUsesOnlyItsBoundaryKeysBeforeThePulse() throws {
        let begin = CACurrentMediaTime()
        let fixture = try Fixture(Self.pulseBody, animations: true, clock: { begin })
        let source = try helper.shape(fixture, "bound").slot
        let pulse = try helper.shape(fixture, "down").slot
        send(try input(at: begin), to: source, on: fixture)
        try ShellLayerScene.engineQueue.sync {
            let entry = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[pulse])
            let first = try XCTUnwrap(entry.triggerPlans.first).begin - entry.begin
            XCTAssertGreaterThan(first, 0.1)
            let before = entry.samples.filter { $0.time < first }
            XCTAssertEqual(before.count, 2)
            XCTAssertEqual(before.first?.time, 0)
            XCTAssertEqual(before.last?.time, (ceil(first * 120) - 1) / 120)
            XCTAssertEqual(before.first?.shape.rect, before.last?.shape.rect)
            XCTAssertTrue(entry.samples.contains { $0.time == first })
        }
    }
}
