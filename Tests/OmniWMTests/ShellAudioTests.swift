// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreAudio
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellAudioTests: XCTestCase {
    func testVolumeCommandsParseStepsMuteLevelsAndOutputs() {
        let cases: [(String, ShellVolumeCommand?)] = [
            ("up", .change(percent: 6.25)),
            ("down", .change(percent: -6.25)),
            ("up 5", .change(percent: 5)),
            ("down 12.5", .change(percent: -12.5)),
            ("up 0", nil),
            ("down -3", nil),
            ("mute", .toggleMute),
            ("set 40", .set(percent: 40)),
            ("set nan", nil),
            ("output 42", .output(42)),
            ("output speakers", nil),
            ("louder", nil)
        ]
        for (text, command) in cases {
            XCTAssertEqual(ShellVolumeCommand(words: text.split(separator: " ").map(String.init)), command, text)
        }
    }

    func testTransportCodesNameTheirKind() {
        XCTAssertEqual(ShellAudio.transport(code: kAudioDeviceTransportTypeBuiltIn), "builtin")
        XCTAssertEqual(ShellAudio.transport(code: kAudioDeviceTransportTypeBluetoothLE), "bluetooth")
        XCTAssertEqual(ShellAudio.transport(code: kAudioDeviceTransportTypeDisplayPort), "displayport")
        XCTAssertEqual(ShellAudio.transport(code: kAudioDeviceTransportTypeAutoAggregate), "aggregate")
        XCTAssertEqual(ShellAudio.transport(code: 0), "other")
    }

    func testOutputsAreListedOnlyWhileDemanded() throws {
        let feed = ShellDataFeed(deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        let volume = ShellDataKey.volume.bit
        let outputs = volume | ShellDataKey.outputs.bit
        feed.setDemand(volume, cadence: .of([(volume, nil)]))
        XCTAssertNil(feed.current.outputs)

        feed.setDemand(outputs, cadence: .of([(outputs, nil)]))
        let listed = try XCTUnwrap(feed.current.outputs)
        if let device = ShellAudio.defaultOutput(), listed.contains(where: { $0.id == device }) {
            XCTAssertEqual(listed.filter(\.isDefault).map(\.id), [device])
        }
        XCTAssertEqual(listed.map(\.name), listed.map(\.name).sorted())

        feed.setDemand(volume, cadence: .of([(volume, nil)]))
        XCTAssertNil(feed.current.outputs)
    }

    func testScrollingTheVolumeWidgetStepsInWholeStepsAndResetsOnReversal() throws {
        let widget = try ShellRenderedWidget("volume")
        widget.set("volume") { $0.number(40) }
        widget.render(ShellBarData())
        let action = try XCTUnwrap(widget.tree().first { $0.content.scrollAction != 0 }?.content.scrollAction)
        let scroll = { (dy: Double, precise: Bool) in
            var event = ShellEvent(button: .none)
            event.dy = dy
            event.precise = precise
            return widget.invoke(action, event: event)
        }
        XCTAssertEqual(scroll(5, true), [])
        XCTAssertEqual(scroll(-14, true), ["volume down 6.25"])
        XCTAssertEqual(scroll(8, true), [])
        XCTAssertEqual(scroll(8, true), ["volume up 6.25"])
        XCTAssertEqual(scroll(-30, true), ["volume down 12.5"])
        XCTAssertEqual(scroll(1, false), ["volume up 6.25"])
        XCTAssertEqual(scroll(-0.5, false), [])
        XCTAssertEqual(scroll(-0.5, false), ["volume down 6.25"])

        widget.set("settings") { writer in
            writer.map(1)
            writer.key("step")
            writer.number(5)
        }
        widget.render(ShellBarData())
        XCTAssertEqual(scroll(2, false), ["volume up 10"])
    }

    func testMomentumScrollingDoesNotReachScrollHandlers() throws {
        let widget = try ShellRenderedWidget("volume")
        widget.set("volume") { $0.number(40) }
        widget.render(ShellBarData())
        let center = CGPoint(x: widget.surface.size.width / 2, y: widget.surface.size.height / 2)
        XCTAssertTrue(widget.surface.scroll(at: center, event: ShellEvent(button: .none), momentum: true))
        XCTAssertEqual(widget.actions, [])
        XCTAssertTrue(widget.surface.scroll(at: center, event: ShellEvent(button: .none)))
        XCTAssertEqual(widget.actions.count, 1)
    }

    func testTheVolumePopoutSetsTheLevelAndSwitchesOutputs() throws {
        let widget = try ShellRenderedWidget("volume")
        widget.set("volume") { $0.number(40) }
        widget.set("outputs") { writer in
            writer.array(2)
            ShellAudioOutput(id: 7, name: "Display", transport: "hdmi", isDefault: false).write(into: &writer)
            ShellAudioOutput(id: 42, name: "Speakers", transport: "builtin", isDefault: true).write(into: &writer)
        }
        let nodes = widget.renderPopout()
        let actions = nodes.map { widget.text.string($0.content.action) }
        XCTAssertTrue(actions.contains("volume output 7"))
        XCTAssertTrue(actions.contains("volume output 42"))
        XCTAssertTrue(actions.contains("volume mute"))
        let slider = try XCTUnwrap(nodes.first { $0.kind == .slider }?.content.action)
        var event = ShellEvent(button: .left)
        event.value = 0.504
        event.phase = .changed
        XCTAssertEqual(widget.invoke(slider, view: OMNI_VIEW_POPOUT, event: event), ["volume set 50"])

        widget.set("volume") { $0.null() }
        XCTAssertFalse(widget.renderPopout().contains { $0.kind == .slider })
        XCTAssertTrue(widget.renderPopout().map { widget.text.string($0.content.action) }.contains("volume output 7"))
    }
}
