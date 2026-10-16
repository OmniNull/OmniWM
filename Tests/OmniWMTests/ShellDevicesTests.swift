// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreBluetooth
import CoreLocation
import CoreWLAN
@testable import OmniWM
import XCTest

@MainActor
final class ShellDevicesTests: XCTestCase {
    private func read(_ keys: [ShellDataKey]) -> (deps: UInt64, cadence: ShellDataFeed.Cadence) {
        let deps = keys.reduce(UInt64(0)) { $0 | $1.bit }
        return (deps, .of([(deps, nil)]))
    }

    func testInputSourcesGetShortLabelsThatTellThemApart() {
        XCTAssertEqual(ShellInputSource.shortNames([
            (name: "ABC", language: "en"),
            (name: "U.S.", language: "en"),
            (name: "German", language: "de"),
            (name: "Pinyin – Simplified", language: "zh-Hans"),
            (name: "Unknown", language: nil)
        ]), ["ABC", "US", "DE", "ZH", "UNK"])
    }

    func testTheInputSourceIsReadOnlyWhileAWidgetReadsIt() throws {
        let devices = ShellDevices()
        let feed = ShellDataFeed(devices: devices, deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertNil(feed.current.inputSource)
        let reading = read([.inputSource])
        feed.setDemand(reading.deps, cadence: reading.cadence)
        let source = try XCTUnwrap(feed.current.inputSource)
        XCTAssertEqual(source, devices.inputSource.value)
        XCTAssertTrue(source.sources.contains(source.current))
        XCTAssertNotNil(devices.inputSource.onChange)
        let other = read([.clock])
        feed.setDemand(other.deps, cadence: other.cadence)
        XCTAssertNil(feed.current.inputSource)
        XCTAssertNil(devices.inputSource.value)
        XCTAssertNil(devices.inputSource.onChange)
    }

    func testInputSourceCommandsParse() {
        XCTAssertEqual(
            ShellAction("input-source select com.apple.keylayout.ABC"),
            .inputSource(.select(id: "com.apple.keylayout.ABC"))
        )
        XCTAssertEqual(ShellAction("input-source settings"), .settings(.inputSource))
        XCTAssertNil(ShellAction("input-source select"))
        XCTAssertNil(ShellAction("input-source"))
    }

    func testWidgetsReadTheInputSource() throws {
        let widget = try ShellRenderedWidget(name: "source", source: """
        function render(ctx)
            local source = ctx.data.inputSource
            return ui.text{ text = source.short .. " " .. source.sources[2].name }
        end
        """)
        let abc = ShellInputSourceEntry(id: "com.apple.keylayout.ABC", name: "ABC", short: "ABC")
        let german = ShellInputSourceEntry(id: "com.apple.keylayout.German", name: "German", short: "DE")
        widget.set("inputSource") { ShellInputSource(current: abc, sources: [abc, german]).write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("ABC German"))
    }

    func testPrivacyListensOnlyWhileReadAndIgnoresOurOwnProcess() throws {
        XCTAssertFalse(ShellAudio.otherProcesses().contains { ShellAudio.pid(of: $0) == getpid() })
        let devices = ShellDevices()
        let feed = ShellDataFeed(devices: devices, deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertEqual(devices.privacy.listenerCount, 0)
        let reading = read([.privacy])
        feed.setDemand(reading.deps, cadence: reading.cadence)
        XCTAssertGreaterThanOrEqual(devices.privacy.listenerCount, 2)
        XCTAssertEqual(feed.current.privacy, devices.privacy.value)
        XCTAssertNotNil(feed.current.privacy)
        let other = read([.clock])
        feed.setDemand(other.deps, cadence: other.cadence)
        XCTAssertEqual(devices.privacy.listenerCount, 0)
        XCTAssertNil(feed.current.privacy)

        let widget = try ShellRenderedWidget(name: "privacy", source: """
        function render(ctx)
            local privacy = ctx.data.privacy
            return ui.text{ text = tostring(privacy.microphone) .. " " .. tostring(privacy.camera) }
        end
        """)
        widget.set("privacy") { ShellPrivacy(microphone: false, camera: true).write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("false true"))
    }

    func testWiFiDescribesItsLinkAndCommandsParse() throws {
        XCTAssertEqual(ShellWiFi.band(.band6GHz), "6 GHz")
        XCTAssertNil(ShellWiFi.band(.bandUnknown))
        XCTAssertEqual(ShellWiFi.security(.wpa3Personal), "WPA3 Personal")
        XCTAssertEqual(ShellWiFi.location(.authorizedAlways), "authorized")
        XCTAssertEqual(ShellWiFi.location(.denied), "denied")
        XCTAssertEqual(ShellWiFi.location(.notDetermined), "notDetermined")
        XCTAssertEqual(ShellAction("wifi authorize"), .wifi(.authorize))
        XCTAssertEqual(ShellAction("wifi settings"), .settings(.wifi))
        XCTAssertNil(ShellAction("wifi on"))

        let widget = try ShellRenderedWidget(name: "wifi", source: """
        function render(ctx)
            local wifi = ctx.data.wifi
            return ui.text{ text = tostring(wifi.ssid) .. " " .. wifi.rssi .. " " .. wifi.band .. " " .. wifi.location }
        end
        """)
        widget.set("wifi") {
            ShellWiFi(power: true, connected: true, rssi: -61, band: "5 GHz", channel: 149, location: "denied")
                .write(into: &$0)
        }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("nil -61 5 GHz denied"))
    }

    func testWiFiIsReadOffTheMainThreadOnlyWhileAWidgetReadsIt() async throws {
        guard CWWiFiClient.shared().interface() != nil else { throw XCTSkip("this Mac has no Wi-Fi") }
        let devices = ShellDevices()
        let feed = ShellDataFeed(devices: devices, deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        let reading = read([.wifi])
        feed.setDemand(reading.deps, cadence: reading.cadence)
        XCTAssertTrue(devices.wifi.isListening)
        await until { feed.current.wifi != nil }
        XCTAssertEqual(feed.current.wifi, devices.wifi.value)
        XCTAssertEqual(feed.current.wifi?.location, ShellWiFi.location(CLLocationManager().authorizationStatus))
        let other = read([.clock])
        feed.setDemand(other.deps, cadence: other.cadence)
        XCTAssertFalse(devices.wifi.isListening)
        XCTAssertNil(feed.current.wifi)
        XCTAssertNil(devices.wifi.onChange)
    }

    func testBluetoothDescribesDevicesAndWaitsForAccess() throws {
        XCTAssertEqual(ShellBluetooth.access(.allowedAlways), "granted")
        XCTAssertEqual(ShellBluetooth.access(.denied), "denied")
        XCTAssertEqual(ShellBluetooth.kind(major: 0x04, minor: 0), "headphones")
        XCTAssertEqual(ShellBluetooth.kind(major: 0x05, minor: 0x10), "keyboard")
        XCTAssertEqual(ShellBluetooth.kind(major: 0x05, minor: 0x20), "mouse")
        XCTAssertEqual(ShellBluetooth.kind(major: 0x1F, minor: 0), "other")
        XCTAssertEqual(ShellBluetooth.address("A0:B1:C2:D3:E4:F5"), "a0-b1-c2-d3-e4-f5")
        XCTAssertEqual(ShellBluetooth.level(NSNumber(value: 55)), 55)
        XCTAssertNil(ShellBluetooth.level(NSNumber(value: 0)))
        XCTAssertNil(ShellBluetooth.level("55"))
        XCTAssertEqual(ShellAction("bluetooth authorize"), .bluetooth(.authorize))
        XCTAssertEqual(ShellAction("bluetooth settings"), .settings(.bluetooth))

        let widget = try ShellRenderedWidget(name: "bluetooth", source: """
        function render(ctx)
            local pods = ctx.data.bluetooth.devices[1]
            return ui.text{ text = pods.kind .. " " .. pods.battery .. " " .. pods.case .. " " .. tostring(pods.left) }
        end
        """)
        let pods = ShellBluetoothDevice(
            id: "a0", name: "AirPods", kind: "headphones", connected: true, battery: 70, right: 70, caseLevel: 40
        )
        widget.set("bluetooth") { ShellBluetooth(power: true, access: "granted", devices: [pods]).write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("headphones 70 40 nil"))

        let devices = ShellDevices()
        let feed = ShellDataFeed(devices: devices, deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        let reading = read([.bluetooth])
        feed.setDemand(reading.deps, cadence: reading.cadence)
        let access = ShellBluetooth.access(CBCentralManager.authorization)
        XCTAssertEqual(feed.current.bluetooth?.access, access)
        XCTAssertEqual(devices.bluetooth.isWatching, access == "granted")
        let other = read([.clock])
        feed.setDemand(other.deps, cadence: other.cadence)
        XCTAssertNil(feed.current.bluetooth)
        XCTAssertFalse(devices.bluetooth.isWatching)
    }

    func testTheUserAndTheirPictureAreReadOnlyWhileAWidgetReadsThem() async throws {
        let devices = ShellDevices()
        let feed = ShellDataFeed(devices: devices, deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertNil(feed.current.user)
        let reading = read([.user])
        feed.setDemand(reading.deps, cadence: reading.cadence)
        XCTAssertEqual(feed.current.user?.name, NSFullUserName())
        XCTAssertEqual(feed.current.user?.account, NSUserName())
        if UserMonitor.picture(of: NSUserName()) != nil {
            await until { feed.current.user?.avatar == true }
            XCTAssertNotNil(devices.user.bitmap(ShellUser.avatarId))
            let wider = read([.user, .clock])
            feed.setDemand(wider.deps, cadence: wider.cadence)
            XCTAssertEqual(feed.current.user?.avatar, true)
        }
        let other = read([.clock])
        feed.setDemand(other.deps, cadence: other.cadence)
        XCTAssertNil(feed.current.user)
        XCTAssertNil(devices.user.bitmap(ShellUser.avatarId))

        let widget = try ShellRenderedWidget(name: "user", source: """
        function render(ctx)
            local user = ctx.data.user
            return ui.text{ text = user.name .. " " .. tostring(user.avatar) }
        end
        """)
        widget.set("user") { ShellUser(name: "Ada Lovelace", account: "ada", avatar: true).write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("Ada Lovelace user.avatar"))
    }

    func testTemperaturesAreSampledOffTheMainThreadOnlyWhileAWidgetReadsThem() async throws {
        XCTAssertEqual(ShellSMC.sensor("Tp01"), .cpu)
        XCTAssertEqual(ShellSMC.sensor("Te05"), .cpu)
        XCTAssertEqual(ShellSMC.sensor("Tg0f"), .gpu)
        XCTAssertNil(ShellSMC.sensor("TB0T"))
        XCTAssertNil(ShellSMC.sensor("#KEY"))
        XCTAssertTrue(ShellSMC.plausible(45))
        XCTAssertFalse(ShellSMC.plausible(0))
        XCTAssertFalse(ShellSMC.plausible(130))
        XCTAssertEqual(ShellSMC.name(ShellSMC.code("Tp0D")), "Tp0D")

        let devices = ShellDevices()
        let feed = ShellDataFeed(devices: devices, deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        let reading = read([.thermal])
        feed.setDemand(reading.deps, cadence: reading.cadence)
        await until { feed.current.thermal != nil }
        if ShellSMC() != nil {
            XCTAssertNotNil(feed.current.thermal?.cpu)
        }
        let other = read([.clock])
        feed.setDemand(other.deps, cadence: other.cadence)
        XCTAssertNil(feed.current.thermal)
        XCTAssertNil(devices.thermal.value)
    }

    func testTheAppearanceIsReadOnlyWhileAWidgetReadsIt() throws {
        XCTAssertEqual(ShellAppearance.of(try XCTUnwrap(NSAppearance(named: .darkAqua))), ShellAppearance(dark: true))
        XCTAssertEqual(ShellAppearance.of(try XCTUnwrap(NSAppearance(named: .aqua))), ShellAppearance(dark: false))
        let devices = ShellDevices()
        let feed = ShellDataFeed(devices: devices, deliver: { _ in })
        defer { feed.stop() }
        feed.start()
        XCTAssertNil(feed.current.appearance)
        let reading = read([.appearance])
        feed.setDemand(reading.deps, cadence: reading.cadence)
        XCTAssertEqual(feed.current.appearance, .of(NSApplication.shared.effectiveAppearance))
        let current = ShellAppearance.of(NSApplication.shared.effectiveAppearance)
        let saved = NSApplication.shared.appearance
        defer { NSApplication.shared.appearance = saved }
        NSApplication.shared.appearance = NSAppearance(named: current.dark ? .aqua : .darkAqua)
        devices.appearance.refresh()
        XCTAssertEqual(feed.current.appearance, ShellAppearance(dark: !current.dark))
        let other = read([.clock])
        feed.setDemand(other.deps, cadence: other.cadence)
        XCTAssertNil(feed.current.appearance)
        NSApplication.shared.appearance = saved
        devices.appearance.refresh()
        XCTAssertNil(feed.current.appearance)

        let widget = try ShellRenderedWidget(name: "appearance", source: """
        function render(ctx) return ui.text{ text = ctx.data.appearance } end
        """)
        widget.set("appearance") { ShellAppearance(dark: true).write(into: &$0) }
        widget.render(ShellBarData())
        XCTAssertTrue(widget.strings().contains("dark"))
    }

    func testSessionActionsParseAndOnlyTheConfirmedOnesAskLoginWindow() {
        for command in ShellSessionCommand.allCases {
            XCTAssertEqual(ShellAction("session \(command.rawValue)"), .session(command))
        }
        XCTAssertNil(ShellAction("session"))
        XCTAssertNil(ShellAction("session reboot"))
        XCTAssertNil(ShellAction("session restart now"))
        XCTAssertNil(ShellSessionCommand.lock.loginWindowEvent)
        XCTAssertNil(ShellSessionCommand.sleep.loginWindowEvent)
        XCTAssertEqual(ShellSessionCommand.logout.loginWindowEvent, AEEventID(kAELogOut))
        XCTAssertEqual(ShellSessionCommand.restart.loginWindowEvent, AEEventID(kAEShowRestartDialog))
        XCTAssertEqual(ShellSessionCommand.shutdown.loginWindowEvent, AEEventID(kAEShowShutdownDialog))
        XCTAssertNotEqual(AEEventID(kAEShowRestartDialog), AEEventID(kAERestart))
    }
}
