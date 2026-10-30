// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import XCTest

@MainActor
final class ShellFollowWireTests: XCTestCase {
    private let grip = """
    ui.box{onGesture=function() end,gesture={track={mode='move',target='desk',
        bounds={w=600,h=400},min={w=50,h=40},max={w=300,h=240}}}}
    """

    func testADuplicateNonTargetKeyDoesNotMakeAFollowTargetAmbiguous() throws {
        let result = try ShellP3WireFixture.render("""
        ui.stack{ui.stack{key='desk',manipulationFollow={response=0.363},\(grip)},
            ui.stack{key='desk',ui.text{text='page component'}},
            ui.glass{ui.shape{follow='desk'}}}
        """)
        XCTAssertEqual(result.nodes.filter { $0.manipulation_follow != 0 }.count, 1)
        XCTAssertEqual(result.nodes.filter { $0.shape_follow != 0 }.count, 1)
    }

    func testTwoManipulationTargetsWithTheSameKeyAreRejected() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx) return ui.stack{
            ui.stack{key='desk',manipulationFollow={response=0.363},\(grip)},
            ui.stack{key='desk',manipulationFollow={response=0.363},\(grip)},
            ui.glass{ui.shape{follow='desk'}}} end
        """)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("unique manipulation target"), script.message)
    }

    func testAGestureOnlyTargetAcceptsAFollowerBesideADuplicateNonTargetKey() throws {
        let result = try ShellP3WireFixture.render("""
        ui.stack{ui.stack{key='desk',\(grip)},ui.stack{key='desk'},
            ui.glass{ui.shape{follow='desk'}}}
        """)
        XCTAssertEqual(result.nodes.filter { $0.manipulation_follow != 0 }.count, 0)
        XCTAssertEqual(result.nodes.filter { $0.gesture_track != 0 }.count, 1)
        XCTAssertEqual(result.nodes.filter { $0.shape_follow != 0 }.count, 1)
    }

    func testTwoGestureOnlyTargetsWithTheSameKeyAreRejected() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx) return ui.stack{
            ui.stack{key='desk',\(grip)},ui.stack{key='desk',\(grip)},
            ui.glass{ui.shape{follow='desk'}}} end
        """)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("unique manipulation target"), script.message)
    }

    func testADeclarationWithoutAGripIsNotCountedBesideTheRealTarget() throws {
        let result = try ShellP3WireFixture.render("""
        ui.stack{ui.stack{key='desk',manipulationFollow={response=0.363},\(grip)},
            ui.stack{key='desk',manipulationFollow={response=0.363}},
            ui.glass{ui.shape{follow='desk'}}}
        """)
        XCTAssertEqual(result.nodes.filter { $0.manipulation_follow != 0 }.count, 2)
        XCTAssertEqual(result.nodes.filter { $0.gesture_track != 0 }.count, 1)
        XCTAssertEqual(result.nodes.filter { $0.shape_follow != 0 }.count, 1)
    }

    func testADeclarationWithoutAGripDoesNotResolveAFollowBinding() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx) return ui.stack{
            ui.stack{key='desk',manipulationFollow={response=0.363}},
            ui.glass{ui.shape{follow='desk'}}} end
        """)
        XCTAssertEqual(script.render().status, OMNI_ERR_RUNTIME)
        XCTAssertTrue(script.message.contains("unique manipulation target"), script.message)
    }

    func testFollowTargetEligibilityMatchesTheSurfaceAncestorResolver() throws {
        for invalid in [
            "ui.row{ui.stack{key='desk',\(grip)}}",
            "ui.stack{key='desk',rotate=30,\(grip)}"
        ] {
            let result = try ShellP3WireFixture.render("""
            ui.stack{ui.stack{key='desk',\(grip)},\(invalid),ui.glass{ui.shape{follow='desk'}}}
            """)
            XCTAssertEqual(result.nodes.filter { $0.gesture_track != 0 }.count, 2)
            XCTAssertEqual(result.nodes.filter { $0.shape_follow != 0 }.count, 1)
        }
    }
}
