// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import QuartzCore
import XCTest

@MainActor
extension ShellManipulationSurfaceTests {
    struct Pair {
        let fixture: Fixture
        let left: ElementHandle
        let right: ElementHandle
    }

    static let pairBody = """
    local vars=ctx.data.vars or {}
    local trackA=false
    local function place(id,x,y)
        local rect=ctx.state[id] or {x=x,y=y,w=100,h=80}
        if vars[id] then
            local w=vars[id..'w'] or 100
            rect={x=vars[id],y=y,w=w,h=w*0.8}
        end
        return rect
    end
    local function widget(id,rect)
        local function handle(next,event)
            if event.phase=='ended' then
                next.state[id]=event.rect
                next.state[id..'t']=event.transaction
            end
        end
        local tracked=id=='a' and trackA
        return ui.stack{key=id,align='topLeading',dx=rect.x,dy=rect.y,w=rect.w,h=rect.h,
            manipulationCommit=vars[id..'c'] or ctx.state[id..'t'],
            manipulationFollow={response=0.363,bounce=0.42},fill='surface',
            gesture=if tracked then {axis='y',commit={distance=20},track={dy={0,20}}} else nil,
            onGesture=if tracked then function() end else nil,
            ui.box{key=id..'-move',align='topLeading',w=100,h=20,onGesture=handle,
                gesture={axis='free',track={mode='move',target=id,bounds={w=600,h=400},
                    min={w=50,h=40},max={w=300,h=240}}}}}
    end
    local a=place('a',40,40)
    local b=place('b',300,200)
    local tree=ui.stack{w=600,h=400,ui.box{decorative=true,w=600,h=400,fill='accent'}}
    if not vars.hideA then tree[#tree+1]=widget('a',a) end
    tree[#tree+1]=widget('b',b)
    local k=a.w/100
    tree[#tree+1]=ui.glass{key='panes',w=600,h=400,animate='spring',
        ui.shape{key='card',align='topLeading',follow=if vars.hideA then nil else 'a',
            dx=a.x+10*k,dy=a.y+(vars.cardDy or 90)*k,w=80*k,h=30*k,radius=8},
        ui.shape{key='column',align='topLeading',hit=false,dx=520,dy=20,w=20,h=100},
        ui.shape{key='pill',align='topLeading',dx=500,dy=330,w=60,h=24,radius=12}}
    return tree
    """

    func setValues(
        _ fixture: Fixture,
        numbers: [String: Double] = [:],
        strings: [String: String] = [:],
        flags: [String: Bool] = [:]
    ) {
        var writer = ShellValueWriter()
        writer.map(numbers.count + strings.count + flags.count)
        for (key, value) in numbers {
            writer.key(key)
            writer.number(value)
        }
        for (key, value) in strings {
            writer.key(key)
            writer.string(value)
        }
        for (key, value) in flags {
            writer.key(key)
            writer.bool(value)
        }
        XCTAssertEqual(writer.bytes.withUnsafeBufferPointer {
            omni_instance_set_value(fixture.script.instance, "vars", $0.baseAddress, $0.count)
        }, OMNI_OK)
    }

    func pair(_ body: String = pairBody, clock: Clock) throws -> Pair {
        let fixture = try follow(body, clock: clock)
        return try Pair(fixture: fixture, left: fixture.target(at: 40), right: fixture.target(at: 300))
    }

    func settleBoth(_ fixture: Fixture, extra flags: [String: Bool] = [:]) {
        setValues(fixture, numbers: ["a": 140, "b": 200], strings: ["ac": "a-1", "bc": "b-1"], flags: flags)
        fixture.render()
    }

    func shape(_ fixture: Fixture, _ name: String) throws -> ElementHandle {
        let key = name.utf8.reduce(UInt64(0xCBF2_9CE4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
            & ~(UInt64(3) << 62)
        let layout = fixture.surface.layout
        return try XCTUnwrap(layout.core.elements { _ in true }.first { layout.core.key(of: $0) == key })
    }

    func testTwoFollowTargetsSettleAndPresentIndependently() throws {
        let clock = Clock()
        let both = try pair(clock: clock)
        let (fixture, left, right) = (both.fixture, both.left, both.right)
        let surface = fixture.surface
        XCTAssertEqual(Set(surface.follows.keys), [left, right])
        settleBoth(fixture)
        let first = try XCTUnwrap(surface.follows[left]?.motion)
        let second = try XCTUnwrap(surface.follows[right]?.motion)
        XCTAssertEqual(first.target, CGRect(x: 140, y: 40, width: 100, height: 80))
        XCTAssertEqual(second.target, CGRect(x: 200, y: 200, width: 100, height: 80))
        XCTAssertNotEqual(surface.follows[left]?.token, surface.follows[right]?.token)
        let scene = surface.scene
        for (target, token) in [(left, surface.follows[left]?.token), (right, surface.follows[right]?.token)] {
            let state = try ShellLayerScene.engineQueue.sync { try XCTUnwrap(scene.gestureLayers[target.slot]) }
            XCTAssertEqual(state.token, token)
            XCTAssertTrue(state.moving)
        }
        for step in [0.02, 0.06] {
            clock.now += step
            XCTAssertEqual(try Set(XCTUnwrap(surface.presentation).targets.keys), [left, right])
            for (target, motion) in [(left, first), (right, second)] {
                let shown = CGRect(surface.presentedFrame(of: target))
                assertEqual(shown, motion.rect(at: clock.now))
                let hit = surface.element(at: CGPoint(x: shown.minX + 5, y: shown.minY + 5)) { $0.acceptsPointer }
                XCTAssertEqual(surface.manipulationOwner(of: hit), target)
            }
        }
        XCTAssertNotEqual(
            CGRect(surface.presentedFrame(of: left)).minX - 40,
            CGRect(surface.presentedFrame(of: right)).minX - 300
        )
        surface.cancelInput()
    }

    func testRegrabbingRemovingOrTrackingOneSettlingTargetKeepsTheOtherMotionAndToken() throws {
        for lifecycle in 0 ..< 3 {
            let clock = Clock()
            let body = lifecycle == 2 ? Self.pairBody.replacingOccurrences(
                of: "local trackA=false", with: "local trackA=true"
            ) : Self.pairBody
            let both = try pair(body, clock: clock)
            let (fixture, left, right) = (both.fixture, both.left, both.right)
            let surface = fixture.surface
            settleBoth(fixture)
            clock.now += 0.03
            let motion = try XCTUnwrap(surface.follows[right]?.motion)
            let token = try XCTUnwrap(surface.follows[right]?.token)
            let shown = CGRect(surface.presentedFrame(of: left))
            switch lifecycle {
            case 0:
                surface.press(at: CGPoint(x: shown.minX + 5, y: shown.minY + 5), timestamp: 1)
                surface.drag(to: CGPoint(x: shown.minX + 13, y: shown.minY + 13), screen: .zero, timestamp: 1.01)
                XCTAssertEqual(surface.manipulation?.target, left)
                XCTAssertNotNil(surface.follows[left]?.motion)
            case 1:
                settleBoth(fixture, extra: ["hideA": true])
                XCTAssertFalse(surface.layout.core.contains(left))
                XCTAssertNil(surface.follows[left])
            default:
                let point = CGPoint(x: shown.minX + 50, y: shown.minY + 65)
                surface.press(at: point, timestamp: 1)
                surface.drag(to: CGPoint(x: point.x, y: point.y + 10), screen: .zero, timestamp: 1.01)
                XCTAssertEqual(surface.gestureTracking?.handle, left)
                XCTAssertNil(surface.follows[left]?.motion)
            }
            XCTAssertEqual(surface.follows[right]?.token, token, "lifecycle \(lifecycle)")
            XCTAssertEqual(surface.follows[right]?.motion?.begin, motion.begin, "lifecycle \(lifecycle)")
            XCTAssertEqual(surface.follows[right]?.motion?.target, motion.target, "lifecycle \(lifecycle)")
            let state = try ShellLayerScene.engineQueue.sync {
                try XCTUnwrap(surface.scene.gestureLayers[right.slot])
            }
            XCTAssertEqual(state.token, token)
            XCTAssertTrue(state.moving)
            surface.cancelInput()
        }
    }

    func testHideResetAndDisplaySizeInvalidationFinishEverySettle() throws {
        for lifecycle in 0 ..< 3 {
            let clock = Clock()
            let both = try pair(clock: clock)
            let (fixture, left, right) = (both.fixture, both.left, both.right)
            let surface = fixture.surface
            settleBoth(fixture)
            XCTAssertEqual(surface.follows.values.filter { $0.motion != nil }.count, 2)
            var moves = 0
            surface.onMove = { moves += 1 }
            switch lifecycle {
            case 0: surface.setVisible(false)
            case 1: surface.reset(text: ShellTextStore())
            default: surface.setRootLimit(CGSize(width: 500, height: 350))
            }
            XCTAssertTrue(surface.follows.values.allSatisfy { $0.motion == nil }, "lifecycle \(lifecycle)")
            XCTAssertNil(surface.presentation, "lifecycle \(lifecycle)")
            XCTAssertGreaterThanOrEqual(moves, 1)
            if lifecycle == 1 {
                XCTAssertTrue(surface.follows.isEmpty)
                continue
            }
            for target in [left, right] {
                let state = try ShellLayerScene.engineQueue.sync {
                    try XCTUnwrap(surface.scene.gestureLayers[target.slot])
                }
                XCTAssertFalse(state.moving, "lifecycle \(lifecycle)")
                XCTAssertEqual(state.layer.transform.m41, 0)
            }
        }
    }

    func testTwentyFourFollowTargetsKeepIndependentRecordsAndATwentyFifthIsRejected() throws {
        func widgets(_ count: Int) -> String {
            """
            local vars=ctx.data.vars or {}
            local tree=ui.stack{w=800,h=400}
            for index=1,\(count) do
                local id='w'..index
                tree[#tree+1]=ui.stack{key=id,align='topLeading',dx=vars[id] or (index-1)%8*90,dy=math.floor((index-1)/8)*120,
                    w=80,h=60,manipulationCommit=vars[id..'c'],manipulationFollow={response=0.363,bounce=0.42},
                    fill='surface',ui.box{align='topLeading',w=80,h=20,onGesture=function() end,
                        gesture={track={mode='move',target=id,bounds={w=800,h=400},min={w=40,h=30},max={w=200,h=150}}}}}
            end
            return tree
            """
        }
        let clock = Clock()
        let fixture = try follow(widgets(24), clock: clock)
        let surface = fixture.surface
        XCTAssertEqual(surface.follows.count, 24)
        var numbers: [String: Double] = [:]
        var strings: [String: String] = [:]
        for index in 1 ... 24 {
            numbers["w\(index)"] = Double((index - 1) % 8) * 90 + 5
            strings["w\(index)c"] = "commit-\(index)"
        }
        setValues(fixture, numbers: numbers, strings: strings)
        fixture.render()
        XCTAssertEqual(surface.follows.values.compactMap(\.motion).count, 24)
        XCTAssertEqual(Set(surface.follows.values.map(\.token)).count, 24)
        clock.now += 0.02
        XCTAssertEqual(surface.presentation?.targets.count, 24)
        let rejected = try ShellScriptHostTests.Script("function render(ctx) " + widgets(25) + " end")
        XCTAssertNotEqual(rejected.render().status, OMNI_OK)
        XCTAssertTrue(rejected.message.contains("at most 24 manipulationFollow targets"), rejected.message)
    }

    func testHitDisabledShapeLeavesRegionsAndShapeHitsWhileThePillStays() throws {
        let fixture = try follow(Self.pairBody, clock: Clock())
        let surface = fixture.surface
        let column = CGPoint(x: 530, y: 70)
        let pill = CGPoint(x: 530, y: 342)
        XCTAssertFalse(surface.layout.core.content(of: try shape(fixture, "column")).glassHit)
        XCTAssertFalse(surface.islandRegions().contains { $0.contains(column) })
        XCTAssertFalse(surface.containsShape(at: column))
        XCTAssertTrue(surface.islandRegions().contains { $0.contains(pill) })
        XCTAssertTrue(surface.containsShape(at: pill))
    }

    func commitScaled(_ both: Pair) throws -> (record: ShellManipulationFollow, motion: ShellManipulationMotion) {
        setValues(both.fixture, numbers: ["a": 140, "aw": 50], strings: ["ac": "a-1"])
        both.fixture.render()
        let record = try XCTUnwrap(both.fixture.surface.follows[both.left])
        let motion = try XCTUnwrap(record.motion)
        XCTAssertEqual(motion.start.width / record.frame.width, 2, accuracy: 1e-9)
        return (record, motion)
    }

    func testFollowerShapeHitsAndRegionsUseItsTargetPresentation() async throws {
        let clock = Clock()
        let both = try pair(clock: clock)
        let renderer = try attachRenderer(both.fixture)
        let surface = both.fixture.surface
        let card = try shape(both.fixture, "card")
        XCTAssertEqual(surface.followedTarget(of: card), both.left)
        XCTAssertTrue(surface.containsShape(at: CGPoint(x: 60, y: 145)))
        let (record, motion) = try commitScaled(both)
        let layout = CGRect(surface.layout.core.absoluteFrame(of: card))
        XCTAssertEqual(layout, CGRect(x: 145, y: 85, width: 40, height: 15))
        let springs = try ShellLayerScene.engineQueue.sync {
            let panes = try XCTUnwrap(surface.scene.parents[card.slot].flatMap { surface.scene.glassBodies[$0] })
            return panes.lockstepLayers(card.slot).compactMap { $0.animation(forKey: ShellGlassBody.Channel.x.key) }
        }
        XCTAssertTrue(springs.isEmpty)
        XCTAssertTrue(surface.containsShape(at: CGPoint(x: 60, y: 145)))
        XCTAssertFalse(surface.containsShape(at: CGPoint(x: 150, y: 90)))
        let path = motion.trajectoryBounds(of: layout, about: record.frame)
        XCTAssertTrue(surface.islandRegions().contains(path))
        XCTAssertTrue(path.contains(CGPoint(x: 60, y: 145)))
        XCTAssertTrue(path.contains(CGPoint(x: 180, y: 95)))
        clock.now += 0.05
        let shown = motion.rect(at: clock.now)
        let scale = shown.width / record.frame.width
        XCTAssertTrue(surface.containsShape(at: CGPoint(
            x: shown.minX + (layout.midX - record.frame.minX) * scale,
            y: shown.minY + (layout.midY - record.frame.minY) * scale
        )))
        let follow = try ShellLayerScene.engineQueue.sync {
            try XCTUnwrap(surface.scene.shapeTracks.follows[card.slot])
        }
        XCTAssertEqual(follow.mode, .transform)
        XCTAssertFalse(follow.presentation.isIdentity)
        let (completion, animation) = try ShellLayerScene.engineQueue.sync {
            let layer = try XCTUnwrap(surface.scene.gestureLayers[both.left.slot]?.layer)
            let animation = try XCTUnwrap(ShellManipulationSceneTests.keys.lazy.compactMap {
                layer.animation(forKey: $0)
            }.first { $0.delegate is ShellManipulationCompletion })
            return try (XCTUnwrap(animation.delegate as? ShellManipulationCompletion), animation)
        }
        completion.animationDidStop(animation, finished: true)
        await drain()
        XCTAssertNil(surface.follows[both.left]?.motion)
        XCTAssertTrue(surface.containsShape(at: CGPoint(x: 150, y: 90)))
        XCTAssertFalse(surface.islandRegions().contains(path))
        withExtendedLifetime(renderer) {}
    }

    func testMovedFollowerReceivesItsTargetPresentationAtTheNewOffset() throws {
        let both = try pair(clock: Clock())
        let surface = both.fixture.surface
        let card = try shape(both.fixture, "card")
        let (record, _) = try commitScaled(both)
        setValues(both.fixture, numbers: ["a": 140, "aw": 50, "cardDy": 100], strings: ["ac": "a-1"])
        both.fixture.render()
        XCTAssertEqual(surface.follows[both.left]?.token, record.token)
        XCTAssertEqual(CGRect(surface.layout.core.absoluteFrame(of: card)).minY, 90)
        let rebound = ShellLayerScene.engineQueue.sync { surface.scene.shapeTracks.follows[card.slot]?.presentation }
        guard case let .motion(sent)? = rebound,
              case let .motion(wanted) = surface.currentPresentation(of: both.left).following(CGPoint(x: -5, y: -50)),
              case let .motion(stale) = surface.currentPresentation(of: both.left).following(CGPoint(x: -5, y: -45))
        else { return XCTFail("the moved follower lost its motion") }
        XCTAssertGreaterThan(abs(stale.y.from - wanted.y.from), 1)
        XCTAssertEqual(sent.y.from, wanted.y.from, accuracy: 1e-9)
        XCTAssertEqual(sent.y.to, wanted.y.to, accuracy: 1e-9)
        XCTAssertEqual(sent.x.velocity, wanted.x.velocity, accuracy: 1e-9)
        surface.cancelInput()
    }

    func testTrackOutlineReplacesTheFixedResizeOutline() throws {
        let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        for (suffix, expected) in [
            ("", ShellManipulationClip.standardOutline),
            (",outline=false", nil),
            (",outline='#FF0000'", red)
        ]
            as [(String, CGColor?)]
        {
            let fixture = try Fixture("""
            return ui.stack{w=600,h=400,
                ui.stack{key='widget',align='topLeading',dx=80,dy=70,w=100,h=80,fill='surface',
                    ui.box{align='bottomTrailing',w=12,h=12,onGesture=function() end,
                        gesture={track={mode='resize',target='widget',edge='se',bounds={w=600,h=400},
                            min={w=50,h=40},max={w=300,h=240}\(suffix)}}}}}
            """)
            fixture.surface.press(at: CGPoint(x: 175, y: 145), timestamp: 0)
            fixture.surface.drag(to: CGPoint(x: 145, y: 125), screen: .zero, timestamp: 0.01)
            let target = try fixture.target()
            let layer = try ShellLayerScene.engineQueue.sync {
                try XCTUnwrap(fixture.surface.scene.gestureLayers[target.slot]?.layer)
            }
            let border = ShellLayerScene.engineQueue.sync { (layer.borderWidth, layer.borderColor, layer.bounds.size) }
            XCTAssertEqual(border.2, CGSize(width: 70, height: 60))
            XCTAssertEqual(border.0, expected == nil ? 0 : 0.5, "\(suffix)")
            XCTAssertTrue(ShellLayerScene.same(border.1, expected), "\(suffix)")
            fixture.surface.cancelInput()
        }
    }
}
