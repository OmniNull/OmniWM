// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

private struct PathCase {
    let types: [ShellConnection.InterfaceType]
    let satisfied: Bool
    let unused: Set<Int>
    let kind: String
    let interface: String?

    init(
        _ types: [ShellConnection.InterfaceType],
        satisfied: Bool = true,
        unused: Set<Int> = [],
        _ kind: String,
        _ interface: String?
    ) {
        self.types = types
        self.satisfied = satisfied
        self.unused = unused
        self.kind = kind
        self.interface = interface
    }

    var interfaces: [ShellConnection.Interface] {
        types.enumerated().map {
            ShellConnection.Interface(type: $0.element, name: "if\($0.offset)", inUse: !unused.contains($0.offset))
        }
    }
}

@MainActor
final class ShellConnectionTests: XCTestCase {
    func testConnectionFollowsThePathsFirstPhysicalInterface() {
        let cases = [
            PathCase([.wifi], "wifi", "if0"),
            PathCase([.wiredEthernet], "ethernet", "if0"),
            PathCase([.cellular], "cellular", "if0"),
            PathCase([.other], "other", "if0"),
            PathCase([.wiredEthernet, .wifi], "ethernet", "if0"),
            PathCase([.wifi, .wiredEthernet], "wifi", "if0"),
            PathCase([.loopback, .wiredEthernet], "ethernet", "if1"),
            PathCase([.loopback, .wifi], "wifi", "if1"),
            PathCase([.other, .wifi], "wifi", "if1"),
            PathCase([.other, .wiredEthernet], "ethernet", "if1"),
            PathCase([.other, .loopback, .wiredEthernet], "ethernet", "if2"),
            PathCase([.other, .wifi, .wiredEthernet], "wifi", "if1"),
            PathCase([.wiredEthernet, .wifi], unused: [0], "wifi", "if1"),
            PathCase([.wifi, .wiredEthernet], unused: [0], "ethernet", "if1"),
            PathCase([.other, .wiredEthernet, .wifi], unused: [1], "wifi", "if2"),
            PathCase([.wifi], unused: [0], "none", nil),
            PathCase([.wifi], satisfied: false, "none", nil),
            PathCase([.wiredEthernet], satisfied: false, "none", nil),
            PathCase([], satisfied: false, "none", nil),
            PathCase([.loopback], "none", nil)
        ]
        for entry in cases {
            let connection = ShellConnection(interfaces: entry.interfaces, satisfied: entry.satisfied)
            let context = "\(entry.types) satisfied=\(entry.satisfied)"
            XCTAssertEqual(connection.kind, entry.kind, context)
            XCTAssertEqual(connection.interface, entry.interface, context)
        }
    }

    func testConnectionIsADataKeyWidgetsCanRead() throws {
        XCTAssertEqual(ShellDataKey(rawValue: "connection"), .connection)

        let widget = try ShellRenderedWidget(name: "connection", source: """
        function render(ctx)
            local connection = ctx.data.connection
            return ui.text{ text = connection.kind .. " " .. tostring(connection.interface) }
        end
        """)
        widget.set("connection") { ShellConnection(kind: "ethernet", interface: "en0").write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("ethernet en0"), "\(widget.strings())")

        widget.set("connection") { ShellConnection(kind: "none", interface: nil).write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("none nil"), "\(widget.strings())")
    }

    func testTheWiFiBarShowsAWiredGlyphOnEthernetWithoutWiFiData() throws {
        let widget = try ShellRenderedWidget("wifi")
        widget.set("connection") { connection(&$0, kind: "ethernet", interface: "en0") }
        widget.set("wifi") { $0.null() }
        widget.render(ShellBarData())
        let symbols = barSymbols(widget)
        XCTAssertTrue(symbols.contains("network"), "\(symbols)")
        XCTAssertGreaterThan(widget.surface.size.width, 0)
    }

    func testTheWiFiBarShowsAWiredGlyphOnEthernetEvenWithWiFiData() throws {
        let widget = try ShellRenderedWidget("wifi")
        widget.set("connection") { connection(&$0, kind: "ethernet", interface: "en0") }
        widget.set("wifi") {
            ShellWiFi(power: true, connected: false, location: "authorized").write(into: &$0)
        }
        widget.render(ShellBarData())
        let symbols = barSymbols(widget)
        XCTAssertTrue(symbols.contains("network"), "\(symbols)")
        XCTAssertFalse(widget.tree().contains { $0.kind == .path }, "the Wi-Fi fan is drawn on ethernet")
    }

    func testTheWiFiBarKeepsTheFanOnWiFi() throws {
        let widget = try ShellRenderedWidget("wifi")
        widget.set("connection") { connection(&$0, kind: "wifi", interface: "en1") }
        widget.set("wifi") {
            ShellWiFi(power: true, connected: true, ssid: "Harbourfront", rssi: -58, location: "authorized")
                .write(into: &$0)
        }
        widget.render(ShellBarData())
        XCTAssertFalse(barSymbols(widget).contains("network"), "\(barSymbols(widget))")
        XCTAssertTrue(widget.tree().contains { $0.kind == .path }, "the Wi-Fi fan is missing")
    }

    private func barSymbols(_ widget: ShellRenderedWidget) -> [String] {
        widget.tree().filter { $0.kind == .symbol }.map { widget.text.string($0.content.text) }
    }

    private func connection(_ writer: inout ShellValueWriter, kind: String, interface: String?) {
        writer.map(2)
        writer.key("kind")
        writer.string(kind)
        writer.key("interface")
        interface.map { writer.string($0) } ?? writer.null()
    }
}
