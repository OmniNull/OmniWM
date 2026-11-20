// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreLocation
import CoreWLAN
@testable import OmniWM
import os
import XCTest

extension ShellDevicesTests {
    private struct WiFiJoinTargets {
        let office = ShellWiFiNetwork(
            id: ShellWiFiNetwork.id(Data("Office".utf8)), ssid: "Office", rssi: -50, security: "WPA2 Personal",
            secured: true, known: true
        )
        let cafe = ShellWiFiNetwork(
            id: ShellWiFiNetwork.id(Data("Cafe".utf8)), ssid: "Cafe", rssi: -60, security: "WPA2 Personal",
            secured: true
        )
        let lobby = ShellWiFiNetwork(id: ShellWiFiNetwork.id(Data("Lobby".utf8)), ssid: "Lobby", rssi: -70)
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
        let devices = ShellDevices(wifi: WiFiMonitor(read: { _ in ShellWiFi(power: true, location: "denied") }))
        let (changes, changed) = boundedChanges()
        let feed = ShellDataFeed(devices: devices, deliver: { _ in changed.yield() })
        defer { feed.stop() }
        feed.start()
        let reading = read([.wifi])
        feed.setDemand(reading.deps, cadence: reading.cadence)
        XCTAssertTrue(devices.wifi.isListening)
        await changes.wait { feed.current.wifi != nil }
        XCTAssertEqual(feed.current.wifi, devices.wifi.value)
        XCTAssertEqual(feed.current.wifi?.location, "denied")
        let other = read([.clock])
        feed.setDemand(other.deps, cadence: other.cadence)
        XCTAssertFalse(devices.wifi.isListening)
        XCTAssertNil(feed.current.wifi)
        XCTAssertNil(devices.wifi.onChange)
    }

    func testWiFiJoinCommandsCarryHexSSIDs() {
        let id = ShellWiFiNetwork.id(Data("Café  Wi-Fi".utf8))
        XCTAssertEqual(ShellWiFiNetwork.ssidData(id: id), Data("Café  Wi-Fi".utf8))
        XCTAssertNotEqual(id, ShellWiFiNetwork.id(Data("Café Wi-Fi".utf8)))
        XCTAssertEqual(ShellAction("wifi join \(id)"), .wifi(.join(id)))
        XCTAssertEqual(ShellAction("wifi scan"), .wifi(.scan))
        XCTAssertNil(ShellAction("wifi join Café"))
        XCTAssertNil(ShellAction("wifi join abc"))
        XCTAssertNil(ShellAction("wifi join \(String(repeating: "ab", count: 33))"))
    }

    func testKnownNetworksFollowAutoJoinPriorityAndOtherNetworksFollowSignal() {
        func network(_ ssid: String, _ rssi: Int) -> ShellWiFiNetwork {
            ShellWiFiNetwork(id: ShellWiFiNetwork.id(Data(ssid.utf8)), ssid: ssid, rssi: rssi)
        }
        let id = { (ssid: String) in ShellWiFiNetwork.id(Data(ssid.utf8)) }
        let lists = ShellWiFiNetworks.grouped(
            [
                network("Home", -70), network("Office", -50), network("Cafe", -60), network("Cafe", -40),
                network("Lobby", -60), network("Atrium", -60), network("Current", -30)
            ],
            priority: [id("Office"), id("Current"), id("Gone"), id("Home")],
            current: id("Current")
        )
        XCTAssertEqual(lists.known.map(\.ssid), ["Office", "Home"])
        XCTAssertTrue(lists.known.allSatisfy(\.known))
        XCTAssertEqual(lists.other.map(\.ssid), ["Cafe", "Atrium", "Lobby"])
        XCTAssertEqual(lists.other.first?.rssi, -40)
        XCTAssertFalse(lists.other.contains(where: \.known))
    }

    func testASecuredNetworkIsNeverShadowedByAnOpenOneWithTheSameName() {
        let id = ShellWiFiNetwork.id(Data("Home".utf8))
        let open = ShellWiFiNetwork(id: id, ssid: "Home", rssi: -40, security: "Open")
        let secured = ShellWiFiNetwork(id: id, ssid: "Home", rssi: -75, security: "WPA2 Personal", secured: true)
        for candidates in [[open, secured], [secured, open]] {
            let lists = ShellWiFiNetworks.grouped(candidates, priority: [id], current: nil)
            XCTAssertEqual(lists.known.map(\.secured), [true])
            XCTAssertEqual(lists.known.first?.rssi, -75)
        }
    }

    func testWiFiNetworksScanOnlyWhileReadAndJoinRevalidatesTheTarget() async throws {
        let targets = WiFiJoinTargets()
        let office = targets.office
        let cafe = targets.cafe
        let lobby = targets.lobby
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let joins = OSAllocatedUnfairLock(initialState: [String]())
        var settingsTargets: [ShellWiFiNetwork] = []
        let monitor = WiFiNetworksMonitor(
            read: { ([office], [cafe, lobby]) },
            scan: { scans.withLock { $0 += 1 } },
            join: { network in
                joins.withLock { $0.append(network.ssid) }
                return network.ssid == "Lobby" ? .failed("Refused") : .joined
            },
            joinInSettings: { network in
                settingsTargets.append(network)
                return nil
            }
        )
        let devices = ShellDevices(wifiNetworks: monitor)
        let (changes, changed) = boundedChanges()
        let feed = ShellDataFeed(devices: devices, deliver: { _ in changed.yield() })
        defer { feed.stop() }
        feed.start()
        XCTAssertFalse(monitor.isListening)

        let reading = read([.wifiNetworks])
        feed.setDemand(reading.deps, cadence: reading.cadence)
        XCTAssertTrue(monitor.isListening)
        await changes
            .wait { feed.current.wifiNetworks?.known == [office] && feed.current.wifiNetworks?.scanning == false }
        XCTAssertEqual(scans.withLock { $0 }, 1)
        XCTAssertEqual(feed.current.wifiNetworks?.other, [cafe, lobby])

        devices.perform(.join(ShellWiFiNetwork.id(Data("Gone".utf8))))
        XCTAssertEqual(feed.current.wifiNetworks?.failure?.message, "Network is no longer in range")
        devices.perform(.join(cafe.id))
        await changes.wait { feed.current.wifiNetworks?.joining == nil }
        XCTAssertEqual(settingsTargets, [cafe])

        devices.perform(.join(office.id))
        XCTAssertEqual(feed.current.wifiNetworks?.joining, office.id)
        XCTAssertNil(feed.current.wifiNetworks?.failure)
        await changes.wait { feed.current.wifiNetworks?.joining == nil }
        XCTAssertNil(feed.current.wifiNetworks?.failure)

        devices.perform(.join(lobby.id))
        await changes.wait { feed.current.wifiNetworks?.joining == nil && feed.current.wifiNetworks?.failure != nil }
        XCTAssertEqual(feed.current.wifiNetworks?.failure, ShellWiFiFailure(id: lobby.id, message: "Refused"))
        XCTAssertEqual(joins.withLock { $0 }, ["Office", "Lobby"])

        let other = read([.clock])
        feed.setDemand(other.deps, cadence: other.cadence)
        XCTAssertFalse(monitor.isListening)
        XCTAssertNil(feed.current.wifiNetworks)
    }

    func testWiFiSettingsHandoffSurvivesPopoutClosureAndPreventsAnotherJoin() async throws {
        let target = ShellWiFiNetwork(
            id: ShellWiFiNetwork.id(Data("Office".utf8)), ssid: "Office", rssi: -50,
            secured: true, enterprise: true, known: true
        )
        let (changes, changed) = boundedChanges()
        var pending: CheckedContinuation<String?, Never>?
        var attempts = 0
        let monitor = WiFiNetworksMonitor(
            read: { ([target], []) }, scan: {},
            join: { _ in XCTFail("Enterprise credentials must remain in System Settings")
                return .joined
            },
            joinInSettings: { _ in
                attempts += 1
                return await withCheckedContinuation {
                    pending = $0
                    changed.yield()
                }
            }
        )
        monitor.onChange = { _ in changed.yield() }
        defer {
            pending?.resume(returning: nil)
            monitor.setListening(false)
        }
        monitor.setListening(true)
        await changes.wait { monitor.value?.known == [target] }
        monitor.join(target.id)
        await changes.wait { pending != nil }

        monitor.setListening(false)
        XCTAssertNil(monitor.value)
        monitor.setListening(true)
        await changes.wait { monitor.value?.known == [target] }
        XCTAssertEqual(monitor.value?.joining, target.id)
        monitor.join(target.id)
        XCTAssertEqual(attempts, 1)

        pending?.resume(returning: "Join this network in Wi-Fi Settings")
        pending = nil
        await changes.wait { monitor.value?.failure != nil }
        XCTAssertNil(monitor.value?.joining)
        XCTAssertEqual(monitor.value?.failure?.id, target.id)
        XCTAssertEqual(monitor.value?.failure?.message, "Join this network in Wi-Fi Settings")
    }

    func testADirectJoinSurvivesThePopoutClosing() async throws {
        let office = WiFiJoinTargets().office
        let (changes, changed) = boundedChanges()
        let joins = OSAllocatedUnfairLock(initialState: 0)
        var handedOff: [ShellWiFiNetwork] = []
        let monitor = WiFiNetworksMonitor(
            read: { ([office], []) }, scan: {},
            join: { _ in
                joins.withLock { $0 += 1 }
                return .needsSettings
            },
            joinInSettings: { network in
                handedOff.append(network)
                changed.yield()
                return nil
            }
        )
        monitor.onChange = { _ in changed.yield() }
        defer { monitor.setListening(false) }
        monitor.setListening(true)
        await changes.wait { monitor.value?.known == [office] && monitor.value?.scanning == false }
        monitor.join(office.id)
        monitor.setListening(false)
        monitor.setListening(true)
        XCTAssertEqual(monitor.value?.joining, office.id)
        monitor.join(office.id)
        await changes.wait { !handedOff.isEmpty && monitor.value?.joining == nil }
        WiFiNetworksMonitor.radio.sync {}
        XCTAssertEqual(joins.withLock { $0 }, 1)
        XCTAssertEqual(handedOff, [office])
    }

    func testTheSettingsHandoffOnlyClicksARowWhoseSecurityMatches() {
        let identifiers = { (names: [String]) in Set(names.map { Data($0.utf8) }) }
        let ids = identifiers(["wifi-network-Home-signal", "wifi-network-Home-secure", "wifi-network-Cafe-signal"])
        XCTAssertEqual(WiFiSettingsJoiner.rowSecurity(in: ids, ssid: "Home", secured: true), .matches)
        XCTAssertEqual(WiFiSettingsJoiner.rowSecurity(in: ids, ssid: "Home", secured: false), .conflicts)
        XCTAssertEqual(WiFiSettingsJoiner.rowSecurity(in: ids, ssid: "Cafe", secured: false), .matches)
        XCTAssertEqual(WiFiSettingsJoiner.rowSecurity(in: ids, ssid: "Cafe", secured: true), .conflicts)
        XCTAssertEqual(WiFiSettingsJoiner.rowSecurity(in: ids, ssid: "Office", secured: true), .unknown)

        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed)
        let lookalikes = identifiers([
            "wifi-network-\(composed)-signal",
            "wifi-network-\(decomposed)-signal", "wifi-network-\(decomposed)-secure"
        ])
        XCTAssertEqual(WiFiSettingsJoiner.rowSecurity(in: lookalikes, ssid: composed, secured: true), .conflicts)
        XCTAssertEqual(WiFiSettingsJoiner.rowSecurity(in: lookalikes, ssid: composed, secured: false), .matches)
        XCTAssertEqual(WiFiSettingsJoiner.rowSecurity(in: lookalikes, ssid: decomposed, secured: true), .matches)
    }

    func testTheRecheckReadsOnlyTheTargetRowAndRejectsALateDuplicate() {
        typealias Child = WiFiSettingsJoiner.RowChild
        let label = { (text: String, target: Bool) in Child(text: text, isLabel: true, isTarget: target) }
        let marker = { (identifier: String) in Child(identifier: identifier) }
        let markers = { (names: [String]) in Set(names.map { Data($0.utf8) }) }
        let rows = [
            label("Home", false), marker("wifi-network-Home-secure"), marker("wifi-network-Home-signal"),
            label("Cafe", true), marker("wifi-network-Cafe-signal"),
            label("Office", false), marker("wifi-network-Office-secure"), marker("wifi-network-Office-signal")
        ]
        XCTAssertEqual(
            WiFiSettingsJoiner.rowMarkers(in: rows, ssid: "Cafe"),
            markers(["wifi-network-Cafe-signal"])
        )
        let duplicate = rows + [
            label("Cafe", false), marker("wifi-network-Cafe-secure"), marker("wifi-network-Cafe-signal")
        ]
        XCTAssertNil(WiFiSettingsJoiner.rowMarkers(in: duplicate, ssid: "Cafe"))
        XCTAssertNil(WiFiSettingsJoiner.rowMarkers(in: rows.map { Child(
            text: $0.text, identifier: $0.identifier, isLabel: $0.isLabel, isTarget: false
        ) }, ssid: "Cafe"))
    }

    func testAFailedDirectJoinHandsOffToSettings() async throws {
        let office = WiFiJoinTargets().office
        let (changes, changed) = boundedChanges()
        var handedOff: [ShellWiFiNetwork] = []
        let monitor = WiFiNetworksMonitor(
            read: { ([office], []) }, scan: {},
            join: { _ in .needsSettings },
            joinInSettings: { network in
                handedOff.append(network)
                return nil
            }
        )
        monitor.onChange = { _ in changed.yield() }
        defer { monitor.setListening(false) }
        monitor.setListening(true)
        await changes.wait { monitor.value?.known == [office] && monitor.value?.scanning == false }
        XCTAssertFalse(office.opensSettings)
        monitor.join(office.id)
        await changes.wait { monitor.value?.joining == nil }
        XCTAssertEqual(handedOff, [office])
        XCTAssertNil(monitor.value?.failure)
    }

    func testListsHoldStillWhileAJoinIsInFlight() async throws {
        let targets = WiFiJoinTargets()
        let lists = OSAllocatedUnfairLock(initialState: (known: [targets.office], other: [targets.cafe]))
        let (changes, changed) = boundedChanges()
        var pending: CheckedContinuation<String?, Never>?
        let monitor = WiFiNetworksMonitor(
            read: { lists.withLock { $0 } }, scan: {},
            join: { _ in .needsSettings },
            joinInSettings: { _ in
                await withCheckedContinuation {
                    pending = $0
                    changed.yield()
                }
            }
        )
        monitor.onChange = { _ in changed.yield() }
        defer {
            pending?.resume(returning: nil)
            monitor.setListening(false)
        }
        monitor.setListening(true)
        await changes.wait { monitor.value?.known == [targets.office] && monitor.value?.scanning == false }
        monitor.join(targets.office.id)
        await changes.wait { pending != nil }

        lists.withLock { $0 = (known: [], other: [targets.cafe]) }
        monitor.setListening(false)
        monitor.setListening(true)
        XCTAssertEqual(monitor.value?.known, [targets.office])
        XCTAssertEqual(monitor.value?.joining, targets.office.id)

        pending?.resume(returning: nil)
        pending = nil
        await changes.wait { monitor.value?.joining == nil && monitor.value?.known == [] }
        XCTAssertEqual(monitor.value?.other, [targets.cafe])
    }

    func testWiFiSettingsConnectActionPreservesOpaqueNamesAndRejectsAmbiguity() {
        let action = "Name:Connect\nTarget:0x0\nSelector:(null)"
        XCTAssertEqual(WiFiSettingsJoiner.connectAction(in: [action], title: "Connect"), action)
        let translated = "Name:Připojit\nTarget:0x0\nSelector:(null)"
        XCTAssertEqual(WiFiSettingsJoiner.connectAction(in: [translated], title: "Připojit"), translated)
        XCTAssertNil(WiFiSettingsJoiner.connectAction(in: ["Name:Disconnect\nTarget:0x0"], title: "Connect"))
        XCTAssertNil(WiFiSettingsJoiner.connectAction(in: ["Name:Connect elsewhere\nTarget:0x0"], title: "Connect"))
        XCTAssertNil(WiFiSettingsJoiner.connectAction(in: [action, action], title: "Connect"))
    }
}
