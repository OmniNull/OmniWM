// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellBoundTrackTests {
    private struct Retirement {
        let fixture: Fixture
        let source: ShellShapeTrackEntry
        let pulse: ShellShapeTrackEntry
        let sourceSlot: Int32
        let pulseSlot: Int32
        let time: CFTimeInterval
        let futurePulse: CFTimeInterval
    }

    private var recrossingSpring: ShellSpringDynamics.Parameters {
        .init(mass: 1, stiffness: 100, damping: 2)
    }

    private func lifecyclePaint(_ entry: ShellShapeTrackEntry, radius: Double = 0) -> ShellLayerPaint {
        var paint = ShellGlassSceneTests().paint(radius: radius)
        paint.morph = entry.morph
        return paint
    }

    func testChangingBoundFrameAndRadiusPreservesEachFutureCrossingImpulseOnce() throws {
        let fixture = try Fixture(Self.pulseBody, animations: true)
        let source = try helper.shape(fixture, "bound").slot
        let begin = CACurrentMediaTime() + 1
        let boundInput = try input(at: begin, spring: recrossingSpring)
        send(boundInput, to: source, on: fixture)
        let original = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[source])
        }
        let revision = try XCTUnwrap(original.bound).revision
        let planned = original.impulses.map(\.begin).sorted()
        XCTAssertGreaterThan(planned.count, 2)
        XCTAssertTrue(planned.allSatisfy { $0 > begin })
        let resized = original.base.target.rect.insetBy(dx: -3, dy: -2)
        let radius = lifecyclePaint(original, radius: 9)
        let changes: [ShellLayerCommand] = [
            .frame(slot: source, rect: resized, animation: nil),
            .glass(
                slot: source,
                ShellGlassContent(kind: .shape, recipe: "", shape: 0, paint: radius, params: .zero),
                animation: nil
            )
        ]
        var generation = original.generation
        for command in changes {
            fixture.surface.scene.submit([command], animated: true)
            ShellLayerScene.engineQueue.sync {}
            try ShellLayerScene.engineQueue.sync {
                let next = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[source])
                XCTAssertGreaterThan(next.generation, generation)
                generation = next.generation
                XCTAssertEqual(next.bound?.revision, revision)
                XCTAssertEqual(next.impulses.map(\.begin).sorted(), planned)
                XCTAssertEqual(Set(next.impulses.map(\.begin)).count, planned.count)
            }
        }
        try ShellLayerScene.engineQueue.sync {
            let next = try XCTUnwrap(fixture.surface.scene.shapeTracks.entries[source])
            XCTAssertEqual(next.base.target.rect, resized)
            XCTAssertEqual(next.base.target.radius, 9)
        }
    }

    func testChangingATriggerAtALaterCommitDoesNotReplayItsPastCrossing() throws {
        let body = Self.pulseBody.replacingOccurrences(
            of: "trigger={shape='bound',at=0.7,rising=true}",
            with: "trigger={shape='bound',at=(ctx.data.vars or {}).threshold or 0.7,rising=true}"
        )
        let fixture = try Fixture(body, animations: true)
        let source = try helper.shape(fixture, "bound").slot
        let pulse = try helper.shape(fixture, "up").slot
        let begin = CACurrentMediaTime() - 0.2
        send(try input(at: begin, spring: recrossingSpring), to: source, on: fixture)
        let declarationTime = CACurrentMediaTime()
        let before = try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let bound = try XCTUnwrap(scene.shapeTracks.entries[source]?.bound)
            let entry = try XCTUnwrap(scene.shapeTracks.entries[pulse])
            let alreadyStarted = entry.triggerPlans.filter { $0.begin <= declarationTime }
            XCTAssertEqual(alreadyStarted.count, 1)
            XCTAssertTrue(entry.triggerPlans.contains { $0.begin > declarationTime })
            let changedCrossings = bound.crossings(at: 0.05, rising: true)
            XCTAssertEqual(changedCrossings.count, 1)
            XCTAssertTrue(changedCrossings.allSatisfy { $0 < declarationTime })
            return (bound.revision, try XCTUnwrap(alreadyStarted.first).begin, changedCrossings)
        }
        helper.setValues(fixture, numbers: ["threshold": 0.05])
        fixture.render()
        try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let next = try XCTUnwrap(scene.shapeTracks.entries[pulse])
            XCTAssertEqual(scene.shapeTracks.entries[source]?.bound?.revision, before.0)
            XCTAssertEqual(next.morph.trigger?.at, 0.05)
            XCTAssertEqual(next.triggerPlans.map(\.begin), [before.1])
            XCTAssertFalse(next.triggerPlans.contains { before.2.contains($0.begin) })
            XCTAssertGreaterThanOrEqual(next.begin, declarationTime)
        }
    }

    private func retirement() throws -> Retirement {
        let body = Self.pulseBody.replacingOccurrences(
            of: "source={target='widget',edge='right',from=114,span=50}",
            with: "source={target='widget',edge='right',from=114,span=50,pads={left=-13,right=13,top=-13,bottom=13}}"
        ).replacingOccurrences(of: "key='bound',", with: "key='bound',reveal={response=0.12},")
        let fixture = try Fixture(body, animations: true)
        let source = try helper.shape(fixture, "bound").slot
        let pulse = try helper.shape(fixture, "up").slot
        let begin = CACurrentMediaTime()
        send(try input(at: begin, spring: recrossingSpring), to: source, on: fixture)
        let prior = try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let sourceEntry = try XCTUnwrap(scene.shapeTracks.entries[source])
            let pulseEntry = try XCTUnwrap(scene.shapeTracks.entries[pulse])
            XCTAssertGreaterThan(pulseEntry.triggerPlans.count, 1)
            let first = try XCTUnwrap(pulseEntry.triggerPlans.first).begin
            return (sourceEntry, pulseEntry, first + 0.03, pulseEntry.triggerPlans[1].begin)
        }
        let closing = ShellReveal(
            begin: prior.2,
            progress: 1,
            target: 0,
            spring: ShellMorphRecipe.Spring(response: 0.12, bounce: 0).parameters
        )
        fixture.surface.scene.submit([
            .reveal(slot: source, token: 0, closing), .reveal(slot: pulse, token: 0, closing),
            .remove(slot: source), .remove(slot: pulse)
        ], animated: true)
        ShellLayerScene.engineQueue.sync {}
        return try ShellLayerScene.engineQueue.sync {
            let scene = fixture.surface.scene
            let sourceIdentity = try XCTUnwrap(prior.0.identity)
            let pulseIdentity = try XCTUnwrap(prior.1.identity)
            return Retirement(
                fixture: fixture,
                source: prior.0,
                pulse: prior.1,
                sourceSlot: try XCTUnwrap(scene.shapeTracks.retired[sourceIdentity]),
                pulseSlot: try XCTUnwrap(scene.shapeTracks.retired[pulseIdentity]),
                time: prior.2,
                futurePulse: prior.3
            )
        }
    }

    func testRetainingABoundSourcePreservesItsPresentedGeometryAtTheCommit() throws {
        let state = try retirement()
        let expected = state.source.shape(at: state.time)
        XCTAssertNotEqual(expected.rect, state.source.base.target.rect)
        try ShellLayerScene.engineQueue.sync {
            let scene = state.fixture.surface.scene
            let retained = try XCTUnwrap(scene.shapeTracks.entries[state.sourceSlot])
            XCTAssertNotNil(retained.carrier)
            XCTAssertEqual(retained.bound?.revision, state.source.bound?.revision)
            ShellBoundSurfaceFixture.assertRect(retained.shape(at: state.time).rect, expected.rect, accuracy: 1e-9)
            XCTAssertEqual(retained.shape(at: state.time).radius, expected.radius, accuracy: 1e-9)
            let closing = try XCTUnwrap(retained.plan)
            let crossing = try XCTUnwrap(closing.crossings(at: 0.7, rising: false).first)
            XCTAssertGreaterThan(crossing, state.time)
            XCTAssertFalse(retained.impulses.contains { abs($0.begin - crossing) < 1e-9 })
            XCTAssertTrue(retained.impulses.allSatisfy { $0.begin <= state.time })
        }
    }

    func testRetainingATriggeredPulseKeepsTheActiveGeometryAndDropsFuturePulses() throws {
        let state = try retirement()
        let expected = state.pulse.shape(at: state.time)
        XCTAssertGreaterThan(expected.rect.width, 1)
        try ShellLayerScene.engineQueue.sync {
            let scene = state.fixture.surface.scene
            let retained = try XCTUnwrap(scene.shapeTracks.entries[state.pulseSlot])
            XCTAssertNotNil(retained.carrier)
            XCTAssertEqual(retained.triggerPlans.count, 1)
            XCTAssertTrue(retained.triggerPlans.allSatisfy { $0.begin <= state.time })
            XCTAssertFalse(retained.triggerPlans.contains { $0.begin == state.futurePulse })
            XCTAssertLessThan(retained.end, state.futurePulse)
            ShellBoundSurfaceFixture.assertRect(retained.shape(at: state.time).rect, expected.rect, accuracy: 1e-9)
            XCTAssertEqual(retained.shape(at: state.time).radius, expected.radius, accuracy: 1e-9)
        }
    }
}
