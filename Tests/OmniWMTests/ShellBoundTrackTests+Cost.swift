// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Darwin
@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import Synchronization
import XCTest

private struct ShellBoundCostSample: Sendable {
    let active: Bool
    let sceneCommitWallMs: Double
    var rendererEncodeWallMs = 0.0
    let generation: UInt64
    let sourceSamples: Int
    let values: Int
    let keyframes: Int
    let animatedShapes: Int
    let calculationMode: String
    var velocity = ShellManipulationMotion.Velocity.zero
    var commandCount = 0

    var stagedAppEncodeWallMs: Double {
        sceneCommitWallMs + rendererEncodeWallMs
    }
}

private final class ShellBoundCostProbe: Sendable {
    private struct State {
        var begin: UInt64?
        var sample: ShellBoundCostSample?
    }

    private let state = Mutex(State())

    func start() {
        state.withLock { $0.begin = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    }

    func finish(at end: UInt64, active: Bool, scene: ShellLayerScene, source: Int32) {
        let entries = scene.shapeTracks.entries
        let bound = entries[source]
        let frames = bound?.animations.compactMap { $0.animation as? CAKeyframeAnimation } ?? []
        let all = entries.values.flatMap { $0.animations.compactMap { $0.animation as? CAKeyframeAnimation } }
        state.withLock { state in
            guard let begin = state.begin else { preconditionFailure("Engine commit preceded its FIFO marker") }
            state.sample = ShellBoundCostSample(
                active: active, sceneCommitWallMs: Double(end - begin) / 1_000_000,
                generation: bound?.generation ?? 0, sourceSamples: bound?.samples.count ?? 0,
                values: all.reduce(0) { $0 + ($1.values?.count ?? 0) }, keyframes: all.count,
                animatedShapes: entries.filter {
                    !$0.value.animations.isEmpty || scene.shapeTracks.follows[$0.key]?.mode == .transform
                }.count,
                calculationMode: frames.first?.calculationMode.rawValue ?? "none"
            )
        }
    }

    func result() -> ShellBoundCostSample? {
        state.withLock { $0.sample }
    }
}

@MainActor
private final class ShellBoundCostArm {
    let fixture: ShellBoundTrackTests.Fixture
    let clock: ShellBoundSurfaceFixture.Clock
    let stage: ShellGlassSceneTests.FollowStage
    let target: ElementHandle
    let source: Int32
    let layout: CGRect
    let active: Bool
    let begin: CFTimeInterval
    var motion: ShellManipulationMotion

    init(_ body: String, active: Bool) throws {
        let clock = ShellBoundSurfaceFixture.Clock()
        let fixture = try ShellBoundTrackTests.Fixture(body, animations: true)
        let helper = ShellManipulationSurfaceTests()
        let target = try fixture.target()
        let layout = CGRect(fixture.surface.layout.core.absoluteFrame(of: target))
        let begin = clock.now
        self.fixture = fixture
        self.clock = clock
        self.target = target
        self.layout = layout
        self.active = active
        self.begin = begin
        source = try helper.shape(fixture, "bound").slot
        stage = try ShellBoundSurfaceFixture.stage(fixture, at: begin)
        motion = try XCTUnwrap(ShellManipulationMotion(
            from: layout, velocity: .init(x: -80, y: 20, width: -30),
            to: layout.offsetBy(dx: -32.5, dy: 0), begin: begin, spring: helper.desk
        ))
        fixture.surface.clock = { [clock] in clock.now }
    }
}

@MainActor
extension ShellBoundTrackTests {
    private var stagedCostBody: String {
        let body = Self.pulseBody.replacingOccurrences(
            of: "source={target='widget',edge='right',from=114,span=50}",
            with: "source={target='widget',edge='right',from=114,span=50,pads={left=-13,right=13,top=-13,bottom=13}}"
        ).replacingOccurrences(
            of: "ui.shape{key='down'",
            with: """
            ui.shape{key='follower',dx=386,dy=70,align='topLeading',w=200,h=160,
                hit=false,follow='widget',radius=4},
            ui.shape{key='down'
            """
        ).replacingOccurrences(
            of: "key='root',w=730,h=400,",
            with: "key='root',w=730,h=400,ui.text{key='render-count',dx=-10000,text=tostring(ctx.state.renders)},"
        )
        return "ctx.state.renders=(ctx.state.renders or 0)+1\n" + body
    }

    private func measureBoundCommit(_ arm: ShellBoundCostArm) throws -> ShellBoundCostSample {
        let scene = arm.stage.scene
        let probe = ShellBoundCostProbe()
        let target = arm.target
        let commands = arm.fixture.surface.manipulationCommands(
            target, token: 0, presentation: .motion(arm.motion.wrapper(for: arm.layout)), active: arm.active
        )
        XCTAssertTrue(commands.contains { if case .manipulation = $0 { true } else { false } })
        XCTAssertTrue(commands.contains { if case .shapeFollow = $0 { true } else { false } })
        XCTAssertTrue(commands.contains { if case .boundTrack = $0 { true } else { false } })
        let active = arm.active, source = arm.source
        ShellLayerScene.engineQueue.sync {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scene.container.timeOffset = arm.clock.now
            CATransaction.commit()
        }
        ShellLayerScene.engineQueue.async { probe.start() }
        scene.submit(commands, animated: false) {
            probe.finish(at: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), active: active, scene: scene, source: source)
        }
        ShellLayerScene.engineQueue.sync {}
        var sample = try XCTUnwrap(probe.result())
        let rendered = try ShellLayerScene.engineQueue.sync {
            let begin = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let marker = try arm.stage.renderer.encode(paused: arm.clock.now + 1.0 / 180)
            let end = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            return (marker, Double(end - begin) / 1_000_000)
        }
        sample.rendererEncodeWallMs = rendered.1
        let bytes = try ShellLayerScene.engineQueue.sync { try arm.stage.renderer.finish(rendered.0) }
        XCTAssertTrue(stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 50 })
        sample.velocity = arm.motion.startVelocity
        sample.commandCount = commands.count
        return sample
    }

    private func boundPercentile(_ values: [Double], _ fraction: Double) -> Double {
        let ordered = values.sorted()
        let position = Double(ordered.count - 1) * fraction
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - Double(lower))
    }

    private func reportBoundCost(_ samples: [ShellBoundCostSample]) throws {
        #if DEBUG
            let build = "Debug"
        #else
            let build = "Release"
        #endif
        for active in [true, false] {
            let arm = samples.filter { $0.active == active }
            let times = arm.map(\.stagedAppEncodeWallMs)
            let record: [String: Any] = [
                "arm": active ? "active" : "settle", "build": build,
                "commits": arm.count, "stagedAppEncodeWallMsP50": boundPercentile(times, 0.5),
                "stagedAppEncodeWallMsP95": boundPercentile(times, 0.95),
                "sceneCommitWallMsP50": boundPercentile(arm.map(\.sceneCommitWallMs), 0.5),
                "rendererEncodeWallMsP50": boundPercentile(arm.map(\.rendererEncodeWallMs), 0.5),
                "keyframeValuesP50": boundPercentile(arm.map { Double($0.values) }, 0.5),
                "sourceSamplesP50": boundPercentile(arm.map { Double($0.sourceSamples) }, 0.5)
            ]
            print("BOUND-COST-SUMMARY", String(decoding: try JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys]
            ), as: UTF8.self))
        }
        try reportBoundCostRuns(samples)
    }

    private func reportBoundCostRuns(_ samples: [ShellBoundCostSample]) throws {
        for (index, sample) in samples.enumerated() {
            let record: [String: Any] = [
                "index": index, "active": sample.active, "sceneCommitWallMs": sample.sceneCommitWallMs,
                "rendererEncodeWallMs": sample.rendererEncodeWallMs,
                "stagedAppEncodeWallMs": sample.stagedAppEncodeWallMs,
                "keyframes": sample.keyframes, "keyframeValues": sample.values,
                "sourceSamples": sample.sourceSamples, "generation": sample.generation,
                "sourceCalculationMode": sample.calculationMode, "commands": sample.commandCount,
                "initialVelocity": [sample.velocity.x, sample.velocity.y, sample.velocity.width]
            ]
            print("BOUND-COST-RUN", String(decoding: try JSONSerialization.data(
                withJSONObject: record, options: [.sortedKeys]
            ), as: UTF8.self))
        }
    }

    private func retargetBoundCost(_ arm: ShellBoundCostArm, step: Int) throws {
        arm.clock.now = arm.begin + Double(step) / 120
        let phase = Double(step % 4)
        arm.motion = try XCTUnwrap(arm.motion.retargeted(
            at: arm.clock.now,
            to: CGRect(
                x: arm.layout.minX - 32.5 - phase * 2,
                y: arm.layout.minY + phase,
                width: arm.layout.width - phase * 3,
                height: (arm.layout.width - phase * 3) * 0.8
            )
        ))
    }

    func testBoundCommitEncodeCostAndNativeValueVolumeForActiveAndSettleSegments() throws {
        let active = try ShellBoundCostArm(stagedCostBody, active: true)
        let settle = try ShellBoundCostArm(stagedCostBody, active: false)
        let wires = [active.fixture.script.output, settle.fixture.script.output]
        for arm in [active, settle] {
            let sample = try measureBoundCommit(arm)
            XCTAssertEqual(sample.animatedShapes, 4)
            XCTAssertGreaterThan(sample.values, 0)
        }
        var samples: [ShellBoundCostSample] = []
        for iteration in 0 ..< 16 {
            for arm in iteration.isMultiple(of: 2) ? [active, settle] : [settle, active] {
                try retargetBoundCost(arm, step: iteration + 1)
                let sample = try measureBoundCommit(arm)
                XCTAssertGreaterThan(abs(sample.velocity.x) + abs(sample.velocity.y) + abs(sample.velocity.width), 1)
                XCTAssertGreaterThanOrEqual(sample.animatedShapes, 2)
                XCTAssertGreaterThan(sample.sourceSamples, 1)
                XCTAssertGreaterThan(sample.values, 0)
                samples.append(sample)
            }
        }
        try reportBoundCost(samples)
        for (arm, wire) in zip([active, settle], wires) {
            XCTAssertEqual(arm.fixture.script.output, wire)
            XCTAssertEqual(try ShellBoundSurfaceFixture.renderCount(arm.fixture), "1")
            arm.fixture.render()
            XCTAssertEqual(try ShellBoundSurfaceFixture.renderCount(arm.fixture), "2")
        }
    }
}
