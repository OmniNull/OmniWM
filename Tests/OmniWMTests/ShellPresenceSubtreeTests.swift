// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
final class ShellPresenceSubtreeTests: XCTestCase {
    private func makeScene(reveal: Bool = true, rootExit: Bool = true, enabled: Bool = true) -> ShellLayerScene {
        let scene = ShellLayerScene(container: CALayer(), scale: 2)
        let rootIdentity = ShellLayerIdentity(parent: .none, key: 7, kind: .group)
        let animation = enabled ? ShellAnimation(motion: .ease, speed: 1) : nil
        let departure = ShellPresence(opacity: 0, scale: 1, offset: CGPoint(x: 0, y: 12), animation: animation)
        func paint(exit: ShellPresence?, reveal: ShellRevealRecipe? = nil) -> ShellLayerPaint {
            ShellLayerPaint(
                fill: nil, border: nil, borderWidth: 0, radius: 0, opacity: 1, scale: 1,
                shadow: nil, shadowRadius: 0, exit: exit, reveal: reveal
            )
        }
        scene.submit([
            .insert(slot: 0, parent: -1, kind: .group, after: -1, identity: rootIdentity),
            .paint(slot: 0, paint(
                exit: rootExit ? departure : nil, reveal: reveal ? ShellRevealRecipe("reveal:0.4:0.2") : nil
            ), animation: nil),
            .frame(slot: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 100), animation: nil),
            .insert(slot: 1, parent: 0, kind: .group, after: -1),
            .paint(slot: 1, paint(exit: departure), animation: nil),
            .frame(slot: 1, rect: CGRect(x: 0, y: 0, width: 80, height: 80), animation: nil),
            .insert(slot: 2, parent: 1, kind: .box, after: -1),
            .paint(slot: 2, paint(exit: departure), animation: nil),
            .frame(slot: 2, rect: CGRect(x: 0, y: 0, width: 60, height: 20), animation: nil)
        ], animated: false)
        ShellLayerScene.engineQueue.sync {}
        return scene
    }

    func testRevealRemovalRunsRootAndTopmostSectionAndWaitsForDistinctCompletions() {
        let scene = makeScene()
        scene.submit([.remove(slot: 0)], animated: true) {
            guard let (token, retained) = scene.presence.retained.first else {
                XCTFail("Reveal root must retain its departing subtree")
                return
            }
            XCTAssertEqual(scene.presence.retained.count, 1)
            XCTAssertEqual(Set(retained.animations.values.map(\.slot)), [0, 1])
            XCTAssertEqual(retained.pending.count, 2)
            XCTAssertTrue(scene.layers.isEmpty)
            XCTAssertTrue(scene.presence.reveals.isEmpty)
            let root = retained.animations.first { $0.value.slot == 0 }
            let section = retained.animations.first { $0.value.slot == 1 }
            guard let root, let section else { XCTFail("Both root and section must animate")
                return
            }
            XCTAssertEqual(root.value.layer.opacity, 0)
            XCTAssertEqual(section.value.layer.opacity, 0)
            XCTAssertEqual(section.value.layer.transform.m42, 12, accuracy: 0.0001)
            XCTAssertEqual(section.value.layer.sublayers?.first?.opacity, 1)
            XCTAssertTrue(retained.subtree.superlayer === scene.container)
            scene.completePresenceAnimation(token, identifier: root.key)
            XCTAssertEqual(scene.presence.retained[token]?.pending.count, 1)
            XCTAssertTrue(retained.subtree.superlayer === scene.container)
            scene.completePresenceAnimation(token, identifier: root.key)
            XCTAssertEqual(scene.presence.retained[token]?.pending.count, 1)
            scene.completePresenceAnimation(token, identifier: section.key)
            XCTAssertTrue(scene.presence.retained.isEmpty)
            XCTAssertNil(retained.subtree.superlayer)
            scene.completePresenceAnimation(token, identifier: section.key)
            XCTAssertTrue(scene.presence.retained.isEmpty)
            XCTAssertTrue(scene.presence.retainedByIdentity.isEmpty)
        }
        ShellLayerScene.engineQueue.sync {}
    }

    func testNonRevealRemovalKeepsRootOnlyExit() {
        let scene = makeScene(reveal: false)
        scene.submit([.remove(slot: 0)], animated: true) {
            guard let (token, retained) = scene.presence.retained.first else { XCTFail("Expected root exit")
                return
            }
            XCTAssertEqual(retained.animations.values.map(\.slot), [0])
            XCTAssertEqual(retained.subtree.sublayers?.first?.opacity, 1)
            scene.finishPresenceExit(token)
        }
        ShellLayerScene.engineQueue.sync {}
    }

    func testRevealRootWithoutOwnExitStillRetainsASectionExit() {
        let scene = makeScene(rootExit: false)
        scene.submit([.remove(slot: 0)], animated: true) {
            guard let (token, retained) = scene.presence.retained.first else { XCTFail("Expected section exit")
                return
            }
            XCTAssertEqual(retained.animations.values.map(\.slot), [1])
            XCTAssertEqual(retained.subtree.opacity, 1)
            XCTAssertTrue(retained.subtree.superlayer === scene.container)
            scene.finishPresenceExit(token)
        }
        ShellLayerScene.engineQueue.sync {}
    }

    func testDescendantSearchPassesThroughNonExitingSections() {
        let scene = makeScene()
        ShellLayerScene.engineQueue.sync { scene.setPresence(1, appear: nil, exit: nil) }
        scene.submit([.remove(slot: 0)], animated: true) {
            guard let (token, retained) = scene.presence.retained.first else { XCTFail("Expected exits")
                return
            }
            XCTAssertEqual(Set(retained.animations.values.map(\.slot)), [0, 2])
            scene.finishPresenceExit(token)
        }
        ShellLayerScene.engineQueue.sync {}
    }

    func testReducedMotionRevealAndUnanimatedRemovalRetainNothing() {
        for (enabled, animated) in [(false, true), (true, false)] {
            let scene = makeScene(enabled: enabled)
            scene.submit([.remove(slot: 0)], animated: animated) {
                XCTAssertTrue(scene.presence.retained.isEmpty)
                XCTAssertTrue(scene.container.sublayers?.isEmpty != false)
                XCTAssertTrue(scene.presence.departures.isEmpty)
                XCTAssertTrue(scene.presence.reveals.isEmpty)
            }
            ShellLayerScene.engineQueue.sync {}
        }
    }

    func testRetainedWrapperKeepsItsManipulationAnimationSeparateFromRootExit() throws {
        let scene = makeScene()
        let begin = CACurrentMediaTime()
        let renderer = try ShellLayerScene.engineQueue.sync {
            scene.container.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
            let renderer = try ShellOffscreenRenderer(root: scene.container, width: 200, height: 200)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scene.container.speed = 0
            scene.container.timeOffset = begin
            CATransaction.commit()
            return renderer
        }
        let layout = CGRect(x: 0, y: 0, width: 100, height: 100)
        let motion = try XCTUnwrap(ShellManipulationMotion(
            from: CGRect(x: 40, y: 20, width: 80, height: 80), to: layout,
            begin: begin, spring: .init(mass: 1, stiffness: 300, damping: 20)
        ))
        scene.submit([
            .manipulation(slot: 0, token: 7, presentation: .motion(motion.wrapper(for: layout)), active: false)
        ], animated: true)
        scene.submit([.remove(slot: 0)], animated: true) {
            guard let (token, retained) = scene.presence.retained.first,
                  let root = retained.animations.values.first(where: { $0.slot == 0 })
            else { XCTFail("Expected retained root")
                return
            }
            XCTAssertFalse(retained.subtree === root.layer)
            XCTAssertTrue(root.layer.superlayer === retained.subtree)
            XCTAssertTrue(retained.subtree.superlayer === scene.container)
            XCTAssertEqual(retained.subtree.opacity, 1)
            XCTAssertEqual(root.layer.opacity, 0)
            XCTAssertNotNil(retained.subtree.animation(forKey: "transform.translation.x"))
            XCTAssertNil(root.layer.animation(forKey: "transform.translation.x"))
            scene.finishPresenceExit(token)
        }
        withExtendedLifetime(renderer) { ShellLayerScene.engineQueue.sync {} }
    }

    func testRevealReinsertionFinishesTheOldCopyAndForgetsItsPlan() throws {
        let scene = makeScene()
        try ShellLayerScene.engineQueue.sync {
            let root = try XCTUnwrap(scene.layers[0])
            scene.retirePresence(0, subtree: root, animated: true, children: [0: [1], 1: [2]])
            let retained = try XCTUnwrap(scene.presence.retained.values.first)
            XCTAssertTrue(root.superlayer === scene.container)
            scene.forgetPresence(0)
            scene.insertPresence(8, identity: retained.identity)
            XCTAssertTrue(scene.presence.retained.isEmpty)
            XCTAssertNil(root.superlayer)
            XCTAssertTrue(scene.presence.revealPlans.isEmpty)
        }
    }

    func testAdditionalRevealCompletionCanParticipateInTheSameRetainedRecord() throws {
        let scene = makeScene()
        let state = try ShellLayerScene.engineQueue.sync {
            let root = try XCTUnwrap(scene.layers[0])
            scene.retirePresence(0, subtree: root, animated: true, children: [0: [1], 1: [2]])
            let token = try XCTUnwrap(scene.presence.retained.keys.first)
            let extra = try XCTUnwrap(scene.addPresenceCompletion(token, slot: 0, layer: root, key: "omni.reveal"))
            let ordinary = try XCTUnwrap(scene.presence.retained[token]).pending.sorted()
            XCTAssertEqual(ordinary.count, 3)
            for identifier in ordinary.prefix(2) { scene.completePresenceAnimation(token, identifier: identifier) }
            XCTAssertEqual(scene.presence.retained[token]?.pending.count, 1)
            XCTAssertTrue(root.superlayer === scene.container)
            return extra
        }
        state.animationDidStop(CAAnimation(), finished: true)
        XCTAssertTrue(ShellLayerScene.engineQueue.sync {
            scene.presence.retained.isEmpty && scene.container.sublayers?.isEmpty != false
        })
    }
}
