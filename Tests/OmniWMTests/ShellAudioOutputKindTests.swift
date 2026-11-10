// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

private struct KindCase {
    let name: String
    let transport: String
    let kind: String
    var bluetoothKind: String?
}

private struct OutputFixture {
    let id: Int
    let name: String
    let transport: String
    let kind: String
    let isDefault: Bool

    func write(into writer: inout ShellValueWriter) {
        writer.map(5)
        writer.key("id")
        writer.string(String(id))
        writer.key("name")
        writer.string(name)
        writer.key("transport")
        writer.string(transport)
        writer.key("default")
        writer.bool(isDefault)
        writer.key("kind")
        writer.string(kind)
    }
}

@MainActor
final class ShellAudioOutputKindTests: XCTestCase {
    func testOutputKindNamesTheDeviceFromItsNameAndTransport() {
        let cases = [
            KindCase(name: "AirPods", transport: "bluetooth", kind: "airpods"),
            KindCase(name: "Richard’s AirPods", transport: "bluetooth", kind: "airpods"),
            KindCase(name: "AirPods Pro", transport: "bluetooth", kind: "airpodspro"),
            KindCase(name: "Richard’s AirPods Pro", transport: "bluetooth", kind: "airpodspro"),
            KindCase(name: "AirPods Pro 2", transport: "bluetooth", kind: "airpodspro"),
            KindCase(name: "airpods pro", transport: "bluetooth", kind: "airpodspro"),
            KindCase(name: "AirPods Max", transport: "bluetooth", kind: "airpodsmax"),
            KindCase(name: "Richard's AirPods Max", transport: "bluetooth", kind: "airpodsmax"),
            KindCase(name: "Beats Studio Pro", transport: "bluetooth", kind: "beats"),
            KindCase(name: "Powerbeats Pro", transport: "bluetooth", kind: "beats"),
            KindCase(name: "WH-1000XM5", transport: "bluetooth", kind: "headphones"),
            KindCase(name: "AirPods Pro", transport: "usb", kind: "other"),
            KindCase(name: "LG UltraFine", transport: "hdmi", kind: "display"),
            KindCase(name: "Studio Display", transport: "displayport", kind: "display"),
            KindCase(name: "Living Room", transport: "airplay", kind: "airplay"),
            KindCase(name: "MacBook Pro Speakers", transport: "builtin", kind: "builtin"),
            KindCase(name: "Scarlett 2i2", transport: "usb", kind: "other"),
            KindCase(name: "CalDigit TS4", transport: "thunderbolt", kind: "other"),
            KindCase(name: "Mystery", transport: "other", kind: "other"),
            KindCase(name: "JBL Flip 6", transport: "bluetooth", kind: "speaker", bluetoothKind: "speaker"),
            KindCase(name: "WH-1000XM5", transport: "bluetooth", kind: "headphones", bluetoothKind: "headphones"),
            KindCase(name: "AirPods Pro", transport: "bluetooth", kind: "airpodspro", bluetoothKind: "speaker"),
            KindCase(name: "Beats Pill", transport: "bluetooth", kind: "beats", bluetoothKind: "speaker"),
            KindCase(name: "Living Room", transport: "airplay", kind: "airplay", bluetoothKind: "speaker")
        ]
        for entry in cases {
            XCTAssertEqual(
                ShellAudio.outputKind(name: entry.name, transport: entry.transport, bluetoothKind: entry.bluetoothKind),
                entry.kind,
                "\(entry.name) over \(entry.transport) class=\(entry.bluetoothKind ?? "nil")"
            )
        }
    }

    func testBluetoothOutputUIDsYieldTheirPairedDeviceAddress() {
        let cases: [(uid: String, address: String?)] = [
            ("AC-90-85-12-34-5F:output", "ac-90-85-12-34-5f"),
            ("ac:90:85:12:34:5f:output", "ac-90-85-12-34-5f"),
            ("AC-90-85-12-34-5F", "ac-90-85-12-34-5f"),
            ("BuiltInSpeakerDevice", nil),
            ("AppleUSBAudioEngine:Focusrite:Scarlett 2i2:1234:1,2", nil)
        ]
        for entry in cases {
            XCTAssertEqual(ShellAudio.bluetoothAddress(uid: entry.uid), entry.address, entry.uid)
        }
    }

    func testOutputsCarryTheirKindIntoLuau() throws {
        let pods = ShellAudioOutput(id: 3, name: "Richard’s AirPods Pro", transport: "bluetooth", isDefault: true)
        XCTAssertEqual(pods.kind, "airpodspro")

        let widget = try ShellRenderedWidget(name: "outputs", source: """
        function render(ctx)
            local outputs = ctx.data.outputs
            return ui.text{ text = tostring(outputs[1].kind) .. " " .. tostring(outputs[2].kind) }
        end
        """)
        widget.set("outputs") { writer in
            writer.array(2)
            pods.write(into: &writer)
            ShellAudioOutput(id: 42, name: "Speakers", transport: "builtin", isDefault: false).write(into: &writer)
        }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("airpodspro builtin"), "\(widget.strings())")
    }

    func testTheVolumeBarShowsTheDefaultOutputDevice() throws {
        let cases: [(kind: String, symbol: String)] = [
            ("airpods", "airpods"),
            ("airpodspro", "airpodspro"),
            ("airpodsmax", "airpodsmax"),
            ("beats", "beats.headphones"),
            ("headphones", "headphones"),
            ("speaker", "hifispeaker"),
            ("display", "tv"),
            ("airplay", "airplayaudio")
        ]
        for entry in cases {
            let symbols = try renderVolumeBar(volume: 40, muted: false, outputs: [
                OutputFixture(id: 42, name: "Speakers", transport: "builtin", kind: "builtin", isDefault: false),
                OutputFixture(id: 3, name: "Device", transport: "bluetooth", kind: entry.kind, isDefault: true)
            ])
            XCTAssertTrue(symbols.contains(entry.symbol), "\(entry.kind): \(symbols)")
            XCTAssertFalse(symbols.contains { $0.hasPrefix("speaker.") }, "\(entry.kind): \(symbols)")
        }
    }

    func testTheVolumeBarShowsAirPodsProForTheDefaultAirPodsPro() throws {
        let symbols = try renderVolumeBar(volume: 40, muted: false, outputs: [
            OutputFixture(id: 3, name: "AirPods Pro", transport: "bluetooth", kind: "airpodspro", isDefault: true)
        ])
        XCTAssertTrue(symbols.contains("airpodspro"), "\(symbols)")
        XCTAssertFalse(symbols.contains { $0.hasPrefix("speaker.") }, "\(symbols)")
    }

    func testAMutedVolumeBarShowsTheSlashedSpeakerWhateverTheDevice() throws {
        let symbols = try renderVolumeBar(volume: 40, muted: true, outputs: [
            OutputFixture(id: 3, name: "AirPods Pro", transport: "bluetooth", kind: "airpodspro", isDefault: true)
        ])
        XCTAssertTrue(symbols.contains("speaker.slash.fill"), "\(symbols)")
        XCTAssertFalse(symbols.contains("airpodspro"), "\(symbols)")
    }

    func testBuiltInOtherAndMissingOutputsKeepTheLevelSpeaker() throws {
        let output = { (kind: String, isDefault: Bool) in
            OutputFixture(id: 1, name: "Output", transport: "builtin", kind: kind, isDefault: isDefault)
        }
        let fixtures: [(label: String, outputs: [OutputFixture]?)] = [
            ("builtin", [output("builtin", true)]),
            ("other", [output("other", true)]),
            ("no default", [output("airpodspro", false)]),
            ("no outputs", nil)
        ]
        for fixture in fixtures {
            for (volume, symbol) in [
                (10.0, "speaker.wave.1.fill"),
                (50.0, "speaker.wave.2.fill"),
                (90.0, "speaker.wave.3.fill")
            ] {
                let symbols = try renderVolumeBar(volume: volume, muted: false, outputs: fixture.outputs)
                XCTAssertTrue(symbols.contains(symbol), "\(fixture.label) at \(volume): \(symbols)")
            }
        }
    }

    private func renderVolumeBar(volume: Double, muted: Bool, outputs: [OutputFixture]?) throws -> [String] {
        let widget = try ShellRenderedWidget("volume")
        widget.set("volume") { $0.number(volume) }
        widget.set("muted") { $0.bool(muted) }
        if let outputs {
            widget.set("outputs") { writer in
                writer.array(outputs.count)
                for output in outputs {
                    output.write(into: &writer)
                }
            }
        }
        widget.render(ShellBarData())
        return widget.tree().filter { $0.kind == .symbol }.map { widget.text.string($0.content.text) }
    }
}
