// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import Synchronization
import XCTest

@MainActor
final class ShellBuiltInPermissionTests: XCTestCase {
    private final class Held<Value: Sendable>: Sendable {
        private let continuations = Mutex<[CheckedContinuation<Value, Never>]>([])
        let onStart: @Sendable () -> Void

        init(onStart: @escaping @Sendable () -> Void) {
            self.onStart = onStart
        }

        func load() async -> Value {
            await withCheckedContinuation { continuation in
                continuations.withLock { $0.append(continuation) }
                onStart()
            }
        }

        func finish(_ value: Value) {
            let pending = continuations.withLock { state in
                let pending = state
                state.removeAll()
                return pending
            }
            for continuation in pending { continuation.resume(returning: value) }
        }
    }

    private final class ProtocolStub: URLProtocol {
        struct Plan: Sendable {
            var body = Data()
            var received: @Sendable () -> Void = {}
        }

        static let plan = Mutex<(@Sendable (URLRequest) -> Plan)?>(nil)

        override class func canInit(with _: URLRequest) -> Bool {
            true
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let url = request.url, let plan = Self.plan.withLock({ $0 })?(request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
                return
            }
            plan.received()
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: plan.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    func testWeatherDisableCancelsAndClearsThenEnableReevaluatesDemand() async throws {
        let started = expectation(description: "weather request started")
        let restarted = expectation(description: "weather request restarted")
        let calls = Mutex(0)
        let held = Held<ShellWeatherReading> {
            let count = calls.withLock { $0 += 1
                return $0
            }
            if count == 1 { started.fulfill() } else { restarted.fulfill() }
        }
        let permissions = ShellNetworkPermissions()
        let feed = ShellDataFeed(permissions: permissions, loadWeather: { _ in await held.load() }, deliver: { _ in })
        defer { feed.stop() }
        feed.setWeatherLocation(.init(place: .city("Toronto")))
        feed.setDemand(ShellDataKey.weather.bit, cadence: .of([(ShellDataKey.weather.bit, nil)]))
        await fulfillment(of: [started], timeout: failureBound)
        let oldTask = try XCTUnwrap(feed.weatherTask)

        var decisions = ShellPermissionDecisions()
        decisions.services.weather = false
        XCTAssertTrue(permissions.update(decisions: decisions))
        feed.permissionsChanged()
        XCTAssertTrue(oldTask.isCancelled)
        XCTAssertNil(feed.weatherTask)
        XCTAssertEqual(feed.current.weather?.access, .off)
        var writer = ShellValueWriter()
        feed.current.weather?.write(into: &writer)
        let fields = try XCTUnwrap(ShellServiceValue.decode(writer.bytes).fields)
        XCTAssertEqual(Set(fields.keys), ["access"])
        XCTAssertEqual(fields["access"]?.string, "off")

        let weather = ShellWeather(temp: 20, code: 0, day: true, unit: "°C")
        held.finish(.init(weather: weather, latitude: 1, longitude: 2))
        await oldTask.value
        XCTAssertEqual(feed.current.weather?.access, .off)

        decisions.services.weather = true
        XCTAssertTrue(permissions.update(decisions: decisions))
        feed.permissionsChanged()
        await fulfillment(of: [restarted], timeout: failureBound)
        let restartedTask = try XCTUnwrap(feed.weatherTask)
        held.finish(.init(weather: weather, latitude: 1, longitude: 2))
        await restartedTask.value
        XCTAssertEqual(feed.current.weather, weather)
    }

    func testMediaChangesWhileLyricsAreOffNeverDispatchAndReportAccess() {
        let permissions = ShellNetworkPermissions()
        var decisions = ShellPermissionDecisions()
        decisions.services.lyrics = false
        permissions.update(decisions: decisions)
        let calls = Mutex(0)
        let lyrics = LyricsController(load: { _ in
            calls.withLock { $0 += 1 }
            return ShellLyrics(lrc: "[00:01]A line")
        })
        let feed = ShellDataFeed(permissions: permissions, lyrics: lyrics, deliver: { _ in })
        defer { feed.stop() }
        feed.setDemand(ShellDataKey.lyrics.bit, cadence: .of([(ShellDataKey.lyrics.bit, nil)]))
        var media = ShellMedia()
        media.title = "First"
        media.artist = "Artist"
        feed.data.media = media
        feed.showLyrics(true)
        media.title = "Second"
        feed.data.media = media
        feed.showLyrics(true)
        XCTAssertEqual(calls.withLock { $0 }, 0)
        XCTAssertNil(lyrics.task)
        XCTAssertEqual(feed.current.lyrics?.access, .off)
        XCTAssertEqual(feed.current.lyrics?.lines, [])
        var managed = ShellManagedPolicy()
        managed.blockedServices = [.lyrics]
        permissions.update(managed: managed)
        feed.permissionsChanged()
        XCTAssertEqual(feed.current.lyrics?.access, .blocked)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    func testLyricsRevocationCancelsLateResultAndClearsCachedTracks() async throws {
        let first = expectation(description: "first lyrics request")
        let second = expectation(description: "lyrics request after reapproval")
        let third = expectation(description: "cached lyrics were cleared by revocation")
        let calls = Mutex(0)
        let held = Held<ShellLyrics> {
            let count = calls.withLock { $0 += 1
                return $0
            }
            if count == 1 { first.fulfill() }
            else if count == 2 { second.fulfill() }
            else { third.fulfill() }
        }
        let permissions = ShellNetworkPermissions()
        let controller = LyricsController(load: { _ in await held.load() }, permissions: permissions)
        let song = ShellLyricsTrack(title: "Song", artist: "Artist")
        let value = ShellLyrics(lrc: "[00:01]A line")
        controller.show(song)
        await fulfillment(of: [first], timeout: failureBound)
        let old = try XCTUnwrap(controller.task)
        var decisions = ShellPermissionDecisions()
        decisions.services.lyrics = false
        permissions.update(decisions: decisions)
        controller.show(song)
        XCTAssertTrue(old.isCancelled)
        XCTAssertEqual(controller.lyrics?.access, .off)
        held.finish(value)
        await old.value
        XCTAssertEqual(controller.lyrics?.access, .off)

        decisions.services.lyrics = true
        permissions.update(decisions: decisions)
        controller.show(song)
        await fulfillment(of: [second], timeout: failureBound)
        let current = try XCTUnwrap(controller.task)
        held.finish(value)
        await current.value
        XCTAssertEqual(controller.lyrics, value)
        decisions.services.lyrics = false
        permissions.update(decisions: decisions)
        controller.show(song)
        XCTAssertEqual(controller.lyrics?.lines, [])
        decisions.services.lyrics = true
        permissions.update(decisions: decisions)
        controller.show(song)
        let final = try XCTUnwrap(controller.task)
        await fulfillment(of: [third], timeout: failureBound)
        controller.show(nil)
        held.finish(value)
        await final.value
    }

    func testActualSendsAndCompletedResponsesUseCurrentServicePolicy() async throws {
        let permissions = ShellNetworkPermissions()
        let calls = Mutex(0)
        ProtocolStub.plan.withLock { $0 = { _ in
            calls.withLock { $0 += 1 }
            var decisions = ShellPermissionDecisions()
            decisions.services.lyrics = false
            let disabled = decisions
            return .init(body: Data("secret".utf8), received: { permissions.update(decisions: disabled) })
        } }
        defer { ProtocolStub.plan.withLock { $0 = nil } }
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://lrclib.net/api/get")))
        do {
            _ = try await ShellBuiltInHTTPClient.load(
                request, service: .lyrics, permissions: permissions, protocolClasses: [ProtocolStub.self]
            )
            XCTFail("A response revoked before delivery must not be returned")
        } catch {}
        XCTAssertEqual(calls.withLock { $0 }, 1)
        do {
            _ = try await ShellBuiltInHTTPClient.load(
                request, service: .lyrics, permissions: permissions, protocolClasses: [ProtocolStub.self]
            )
            XCTFail("A disabled service must not send")
        } catch {}
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testWeatherGeocodingRevocationPreventsTheForecastSend() async throws {
        let permissions = ShellNetworkPermissions()
        let sent = Mutex<[String]>([])
        ProtocolStub.plan.withLock { $0 = { request in
            sent.withLock { $0.append(request.url?.host ?? "") }
            var managed = ShellManagedPolicy()
            managed.blockedHosts = ["api.open-meteo.com"]
            let blocked = managed
            return .init(
                body: Data(#"{"results":[{"latitude":1,"longitude":2,"name":"Toronto"}]}"#.utf8),
                received: { permissions.update(managed: blocked) }
            )
        } }
        defer { ProtocolStub.plan.withLock { $0 = nil } }
        do {
            _ = try await ShellWeatherClient.forecast(
                .init(place: .city("Toronto")), permissions: permissions, protocolClasses: [ProtocolStub.self]
            )
            XCTFail("A blocked forecast cannot be fetched")
        } catch {}
        XCTAssertEqual(sent.withLock { $0 }, ["geocoding-api.open-meteo.com"])
    }

    func testRedirectsRejectForeignHostsHTTPAndCurrentManagedBlocks() throws {
        let permissions = ShellNetworkPermissions()
        let delegate = ShellBuiltInHTTPClient(service: .lyrics, permissions: permissions)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = try XCTUnwrap(URL(string: "https://lrclib.net/api/get"))
        let task = session.dataTask(with: source)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: source,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: [:]
        ))
        for (target, allowed) in [
            ("https://lrclib.net/next", true),
            ("http://lrclib.net/next", false),
            ("https://other.example/next", false),
            ("https://user@lrclib.net/next", false)
        ] {
            let result = Mutex(false)
            delegate.urlSession(
                session, task: task, willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: try XCTUnwrap(URL(string: target)))
            ) { request in result.withLock { $0 = request != nil } }
            XCTAssertEqual(result.withLock { $0 }, allowed, target)
        }
        var managed = ShellManagedPolicy()
        managed.onlyAllowedHosts = true
        permissions.update(managed: managed)
        let accepted = Mutex(true)
        delegate.urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: source)
        ) { request in accepted.withLock { $0 = request != nil } }
        XCTAssertFalse(accepted.withLock { $0 })
    }

    func testBundledWeatherShowsDisabledAndBlockedReasons() throws {
        let widget = try ShellRenderedWidget("weather")
        for access in [ShellServiceAccess.off, .blocked] {
            widget.set("weather") { ShellWeather.unavailable(access).write(into: &$0) }
            widget.render(ShellBarData())
            let expected = access == .off ? "Turned off in Settings" : "Blocked by your organization"
            XCTAssertTrue(widget.strings().contains(ShellLocalizer.string(expected, [])))
            _ = widget.renderPopout()
            XCTAssertTrue(widget.strings(OMNI_VIEW_POPOUT).contains(ShellLocalizer.string(expected, [])))
        }
    }

    func testBundledMediaShowsLyricsDisabledAndBlockedReasons() throws {
        let widget = try ShellRenderedWidget("media")
        var media = ShellMedia()
        media.title = "Song"
        media.artist = "Artist"
        widget.set("media") { media.write(into: &$0) }
        for access in [ShellServiceAccess.off, .blocked] {
            widget.set("lyrics") { ShellLyrics(status: .missing, access: access).write(into: &$0) }
            _ = widget.renderPopout()
            let strings = widget.strings(OMNI_VIEW_POPOUT)
            let expected = access == .off ? "Turned off in Settings" : "Blocked by your organization"
            XCTAssertTrue(strings.contains(ShellLocalizer.string(expected, [])))
            XCTAssertFalse(strings.contains(ShellLocalizer.string("No lyrics found", [])))
        }
    }
}
