// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ShellDesktopPresentationTests: XCTestCase {
    private final class Signal: Sendable {
        private struct State {
            var count = 0
            var waiters: [CheckedContinuation<Void, Never>] = []
        }

        private let state = Mutex(State())
        func fire() {
            let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
                if !state.waiters.isEmpty { return state.waiters.removeFirst() }
                state.count += 1
                return nil
            }
            waiter?.resume()
        }

        func wait() async {
            await withCheckedContinuation { continuation in
                let ready = state.withLock { state in
                    if state.count > 0 { state.count -= 1
                        return true
                    }
                    state.waiters.append(continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        }
    }

    @MainActor
    private final class Platform {
        var opens: [@Sendable (String?) -> Void] = []
        var preview: ShellDesktopPlatform.PresentationCompletion?
        var sharing: ShellDesktopPlatform.PresentationCompletion?
        var previewCount = 0
        var shareCount = 0
        var values: [ShellResourceStore.Value] = []
        var urls: [URL] = []
        var selectedService: String?
        let started = Signal()
        let cancelled = Signal()

        var value: ShellDesktopPlatform {
            ShellDesktopPlatform(
                pick: { _, _, _ in throw ShellResourceFailure("unused") },
                open: { [self] _, completion in opens.append(completion) },
                reveal: { _ in false },
                quicklook: { [self] urls, _, _, completion in
                    ShellDesktopPlatform.Presentation(start: {
                        self.urls = urls
                        self.preview = completion
                        self.previewCount += 1
                        self.started.fire()
                    }, cancel: { self.cancelled.fire() })
                },
                share: { [self] values, service, _, _, completion in
                    ShellDesktopPlatform.Presentation(start: {
                        self.values = values
                        self.selectedService = service
                        self.sharing = completion
                        self.shareCount += 1
                        self.started.fire()
                    }, cancel: { self.cancelled.fire() })
                }
            )
        }
    }

    @MainActor
    private final class Fixture {
        let owner = ShellServiceOwner(generation: 55, owner: 1, epoch: 1)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: ShellResourceStore
        let platform = Platform()
        let desktop: ShellDesktopServices
        let ledger = ShellServiceLedger(generation: 55)
        let completed = Signal()
        let anchorView = NSView()

        init() {
            store = ShellResourceStore(directory: root)
            desktop = ShellDesktopServices(resources: store, platform: platform.value)
            ledger.attachWake { [completed] in completed.fire() }
        }

        func activate(_ owner: ShellServiceOwner? = nil) async throws {
            let owner = owner ?? self.owner
            try await store.activate(
                owner,
                namespace: ShellStoreNamespace(profile: "fixture", package: "desktop", instance: String(owner.owner))
            )
        }

        func id(_ number: UInt64, owner: ShellServiceOwner? = nil) -> ShellServiceID {
            ShellServiceID(owner: owner ?? self.owner, request: number)
        }

        var bridge: ShellDesktopResourceBridge {
            ShellDesktopResourceBridge(admit: { _, _ in throw ShellResourceFailure("unused") }, retireIDs: { _, _ in })
        }

        var source: ShellDesktopSource {
            ShellDesktopSource(window: nil, isCurrent: { true }, beginFocus: { _ in { _ in } })
        }

        var anchor: ShellDesktopAnchor {
            ShellDesktopAnchor(view: anchorView) { CGRect(x: 0, y: 0, width: 20, height: 20) }
        }

        func file() async throws -> ShellResourceID {
            let resource = ShellResourceDescriptor(
                id: ShellResourceID(),
                name: "preview.txt",
                kind: "file",
                uti: "public.text"
            )
            try store.catalog.admit([resource], owner: owner)
            try await store.materialize([.bytes(Data("pinned preview".utf8))], ids: [resource.id], owner: owner)
            return resource.id
        }

        func result() throws -> ShellServiceValue {
            let completion = try XCTUnwrap(ledger.takeBatch().first)
            _ = ledger.finishBatch()
            return try ShellServiceValue.decode(completion.payload)
        }

        func close() {
            ledger.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testCancelledPhysicalOpensRemainBoundedAndActualCompletionRestoresCapacity() async throws {
        let fixture = Fixture()
        try await fixture.activate()
        defer { fixture.close() }
        let url = try XCTUnwrap(URL(string: "https://example.test/"))
        for index in 1 ... 32 {
            let id = fixture.id(UInt64(index))
            XCTAssertTrue(fixture.desktop.perform(
                ShellDesktopRequest(id: id, action: .openURL(url)),
                ledger: fixture.ledger,
                bridge: fixture.bridge
            ))
            if index < 32 { fixture.ledger.cancel(id) }
        }
        XCTAssertEqual(fixture.platform.opens.count, 32)
        XCTAssertTrue(fixture.desktop.perform(
            ShellDesktopRequest(id: fixture.id(33), action: .openURL(url)),
            ledger: fixture.ledger,
            bridge: fixture.bridge
        ))
        XCTAssertEqual(try fixture.result().fields?["error"]?.string, "desktop_busy")
        XCTAssertEqual(fixture.platform.opens.count, 32)
        await fixture.completed.wait()
        fixture.platform.opens[31](nil)
        await fixture.completed.wait()
        XCTAssertEqual(try fixture.result().fields?["ok"]?.boolean, true)
        XCTAssertTrue(fixture.desktop.perform(
            ShellDesktopRequest(id: fixture.id(34), action: .openURL(url)),
            ledger: fixture.ledger,
            bridge: fixture.bridge
        ))
        XCTAssertEqual(fixture.platform.opens.count, 33)
        let completions = fixture.platform.opens
        fixture.platform.opens.removeAll()
        for completion in completions { completion(nil) }
    }

    func testPhysicalGenerationBoundCountsCancelledOwnersTogether() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let url = try XCTUnwrap(URL(string: "https://example.test/"))
        for slot in 1 ... 9 {
            let owner = ShellServiceOwner(generation: 55, owner: UInt32(slot), epoch: 1)
            try await fixture.activate(owner)
            for offset in 0 ..< (slot == 9 ? 1 : 32) {
                let id = fixture.id(UInt64((slot - 1) * 32 + offset + 1), owner: owner)
                XCTAssertTrue(fixture.desktop.perform(
                    ShellDesktopRequest(id: id, action: .openURL(url)),
                    ledger: fixture.ledger,
                    bridge: fixture.bridge
                ))
                if slot != 9 { fixture.ledger.cancel(id) }
            }
        }
        XCTAssertEqual(fixture.platform.opens.count, 256)
        XCTAssertEqual(try fixture.result().fields?["error"]?.string, "desktop_busy")
        let completions = fixture.platform.opens
        fixture.platform.opens.removeAll()
        for completion in completions { completion(nil) }
    }

    func testPreviewKeepsBackingAndBusySlotUntilActualCompletion() async throws {
        let fixture = Fixture()
        try await fixture.activate()
        defer { fixture.close() }
        let resource = try await fixture.file()
        XCTAssertTrue(fixture.desktop.perform(
            ShellDesktopRequest(id: fixture.id(1), action: .quicklook([resource], index: 1)),
            ledger: fixture.ledger,
            bridge: fixture.bridge,
            source: fixture.source
        ))
        await fixture.platform.started.wait()
        let url = try XCTUnwrap(fixture.platform.urls.first)
        await fixture.store.release([resource], owner: fixture.owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(fixture.desktop.perform(
            ShellDesktopRequest(id: fixture.id(2), action: .quicklook([resource], index: 1)),
            ledger: fixture.ledger,
            bridge: fixture.bridge,
            source: fixture.source
        ))
        XCTAssertEqual(try fixture.result().fields?["error"]?.string, "quicklook_busy")
        await fixture.completed.wait()
        let completion = fixture.platform.preview
        fixture.platform.preview = nil
        completion?(nil)
        await fixture.completed.wait()
        XCTAssertEqual(try fixture.result().fields?["ok"]?.boolean, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(fixture.platform.previewCount, 1)
    }

    func testSharingHoldsResourcesThroughServiceCompletionAndForwardsAirDrop() async throws {
        let fixture = Fixture()
        try await fixture.activate()
        defer { fixture.close() }
        let resource = try await fixture.file()
        XCTAssertTrue(fixture.desktop.perform(
            ShellDesktopRequest(id: fixture.id(1), action: .share([resource], service: "airdrop")),
            ledger: fixture.ledger,
            bridge: fixture.bridge,
            source: fixture.source,
            anchor: fixture.anchor
        ))
        await fixture.platform.started.wait()
        XCTAssertEqual(fixture.platform.selectedService, "airdrop")
        guard case let .file(url) = try XCTUnwrap(fixture.platform.values.first) else { return XCTFail("missing file") }
        await fixture.store.release([resource], owner: fixture.owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(fixture.ledger.takeBatch().isEmpty)
        _ = fixture.ledger.finishBatch()
        let completion = fixture.platform.sharing
        fixture.platform.sharing = nil
        completion?("share_failed")
        await fixture.completed.wait()
        XCTAssertEqual(try fixture.result().fields?["error"]?.string, "share_failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRegisteredCancellationBeforeHandoffNeverStartsNativeWork() async throws {
        let fixture = Fixture()
        try await fixture.activate()
        defer { fixture.close() }
        let request = ShellDesktopRequest(
            id: fixture.id(1),
            action: .openURL(try XCTUnwrap(URL(string: "https://example.test/")))
        )
        XCTAssertTrue(fixture.ledger.register(request.id))
        fixture.ledger.cancel(request.id)
        XCTAssertFalse(fixture.desktop.perform(
            request,
            ledger: fixture.ledger,
            bridge: fixture.bridge,
            registered: true
        ))
        XCTAssertTrue(fixture.platform.opens.isEmpty)
    }
}
