// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import Synchronization
import XCTest

@MainActor
final class ShellResourceSurfaceTests: XCTestCase {
    private actor Admission {
        private var pending: [(
            ShellDropAuthority,
            CheckedContinuation<Result<ShellDropReservation, ShellResourceFailure>, Never>
        )] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private(set) var count = 0

        func reserve(_ authority: ShellDropAuthority) async -> Result<ShellDropReservation, ShellResourceFailure> {
            await withCheckedContinuation { continuation in
                count += 1
                pending.append((authority, continuation))
                let waiters = waiters
                self.waiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }

        func waitForRequest() async {
            if !pending.isEmpty { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func finish(_ id: ShellServiceID?, error: String = "overloaded") {
            let (authority, continuation) = pending.removeFirst()
            continuation
                .resume(returning: id
                    .map { .success(ShellDropReservation(id: $0, authority: authority)) } ??
                    .failure(ShellResourceFailure(error)))
        }
    }

    private let owner = ShellServiceOwner(generation: 2, owner: 3, epoch: 4)
    private let handle = ElementHandle(slot: 1, generation: 9)

    private func authority(sequence: Int = 1, action: UInt32 = 42) -> ShellDropAuthority {
        ShellDropAuthority(handle: handle, sequence: sequence, action: action, accepts: ShellDropTypes.file.rawValue)
    }

    func testPendingExitReleasesLateNativeReservation() async throws {
        let admission = Admission()
        let finished = Mutex<[ShellDropReservation]>([])
        let preflight = ShellDropPreflight(bridge: ShellDropBridge(
            reserve: { await admission.reserve($0) },
            finish: { value in finished.withLock { $0.append(value) } }
        ))
        preflight.update(authority())
        let preparation = try XCTUnwrap(preflight.preparation)
        await admission.waitForRequest()
        XCTAssertNil(preflight.reservation)
        preflight.clear()
        let id = ShellServiceID(owner: owner, request: 7)
        await admission.finish(id)
        await preparation.value
        XCTAssertNil(preflight.reservation)
        XCTAssertEqual(finished.withLock { $0.map(\.id) }, [id])
    }

    func testReadyReservationSurvivesSequenceOnlyAndTransfersExactlyOnce() async throws {
        let admission = Admission()
        let finished = Mutex<[ShellDropReservation]>([])
        let preflight = ShellDropPreflight(bridge: ShellDropBridge(
            reserve: { await admission.reserve($0) },
            finish: { value in finished.withLock { $0.append(value) } }
        ))
        preflight.update(authority())
        let preparation = try XCTUnwrap(preflight.preparation)
        await admission.waitForRequest()
        let id = ShellServiceID(owner: owner, request: 8)
        await admission.finish(id)
        await preparation.value
        preflight.update(authority(sequence: 100))
        XCTAssertEqual(preflight.reservation?.id, id)
        let count = await admission.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(preflight.take(authority(sequence: 100))?.id, id)
        XCTAssertNil(preflight.take(authority()))
        preflight.clear()
        XCTAssertTrue(finished.withLock { $0.isEmpty })
    }

    func testDeclineDoesNotRetryAndRemovedOwnerFinishesLateAdmission() async throws {
        let admission = Admission()
        let finished = Mutex<[ShellDropReservation]>([])
        var failures: [String] = []
        let bridge = ShellDropBridge(
            reserve: { await admission.reserve($0) },
            finish: { value in finished.withLock { $0.append(value) } }
        )
        var preflight: ShellDropPreflight? = ShellDropPreflight(bridge: bridge, declined: { failures.append($0) })
        preflight?.update(authority())
        let first = try XCTUnwrap(preflight?.preparation)
        await admission.waitForRequest()
        await admission.finish(nil)
        await first.value
        preflight?.update(authority(sequence: 2))
        XCTAssertEqual(failures, ["overloaded"])
        let count = await admission.count
        XCTAssertEqual(count, 1)
        preflight?.update(authority(action: 43))
        let second = try XCTUnwrap(preflight?.preparation)
        await admission.waitForRequest()
        preflight = nil
        let id = ShellServiceID(owner: owner, request: 9)
        await admission.finish(id)
        await second.value
        XCTAssertEqual(finished.withLock { $0.map(\.id) }, [id])
    }

    func testDropTargetsUseAcceptedTypesAndClipsWithoutStealingClicks() throws {
        let script = try ShellScriptHostTests.Script("""
        function render(ctx)
            return ui.box{w=40,h=20,center=false,accepts={"file"},onDrop=function() end,
                ui.box{key="child",w=20,h=10,accepts={"text"},onDrop=function() end,onDropHover=function() end}}
        end
        """)
        XCTAssertEqual(script.render().status, OMNI_OK, script.message)
        let text = ShellTextStore()
        text.ingest(wire: script.output)
        let surface = ShellWidgetSurface(
            scale: 1,
            resources: ShellResources(motion: MotionPolicy(animationsEnabled: false)),
            directories: []
        )
        var events: [ShellClick] = []
        surface.onAction = { events.append($0) }
        XCTAssertTrue(surface.apply(script.output, text: text))
        XCTAssertTrue(surface.hasResourceDrops)
        XCTAssertFalse(surface.hasAction(at: CGPoint(x: 3, y: 3)))
        _ = surface.updateResourceDrop(at: CGPoint(x: 3, y: 3), types: .text)
        let child = try XCTUnwrap(surface.dropTarget?.handle)
        XCTAssertNotEqual(child, surface.layout.core.rootHandle)
        _ = surface.updateResourceDrop(at: CGPoint(x: 4, y: 3), types: .text)
        XCTAssertEqual(events.map(\.event.phase), [.entered])
        XCTAssertEqual(events.first?.event.dropTypes, ShellDropTypes.text.rawValue)
        _ = surface.updateResourceDrop(at: CGPoint(x: 4, y: 3), types: .file)
        XCTAssertEqual(surface.dropTarget?.handle, surface.layout.core.rootHandle)
        XCTAssertEqual(events.map(\.event.phase), [.entered, .exited])
        _ = surface.updateResourceDrop(at: CGPoint(x: 41, y: 3), types: .file)
        XCTAssertNil(surface.dropTarget)
        surface.reset(text: text)
        XCTAssertFalse(surface.hasResourceDrops)
    }

    func testResourceWireRefreshCancelsOldBindingAndKeepsPreparedImage() async throws {
        let catalog = ShellResourceCatalog()
        try catalog.activate(
            owner,
            namespace: ShellStoreNamespace(profile: "lake", package: "lake", instance: "shelf"),
            tokens: [:]
        )
        let first = ShellResourceID(try XCTUnwrap(UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")))
        let second = ShellResourceID()
        try catalog.admit(
            [first, second].map { ShellResourceDescriptor(id: $0, name: "image", kind: "image", uti: "public.png") },
            owner: owner
        )
        let store = ShellResourceStore(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            catalog: catalog
        )
        let images = ShellResourceImages(store: store)
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        resources.resourceImages = images
        let surface = ShellWidgetSurface(scale: 2, resources: resources, directories: [])
        let text = ShellTextStore()
        func recipe(_ id: ShellResourceID) -> String {
            "v1/2/3/4/\(id.string.lowercased())/0"
        }
        for (index, source) in [recipe(first), recipe(second)].enumerated() {
            var record = omni_wire_string(id: UInt32(index + 1), length: UInt32(source.utf8.count))
            var bytes = withUnsafeBytes(of: &record) { Array($0) }
            bytes.append(contentsOf: source.utf8)
            text.ingest(bytes, count: 1)
        }
        var node = omni_wire_node()
        node.kind = ElementKind.bitmap.rawValue
        node.subtree_end = 1
        node.width = 32
        node.height = 32
        node.opacity = 1
        node.scale = 1
        node.resource_image_ref = 1
        node.thumbnail = 24
        XCTAssertTrue(surface.apply(wire(node), text: text))
        let handle = surface.layout.core.rootHandle
        let old = try XCTUnwrap(surface.resourceImages[handle.slot]?.binding)
        XCTAssertEqual(old.request.pixels, 48)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 8,
            height: 8,
            bitsPerComponent: 8,
            bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bitmap = try XCTUnwrap(context.makeImage())
        surface.resourceImageCompleted(old, handle: handle, image: bitmap, error: nil)
        node.resource_image_ref = 2
        XCTAssertTrue(surface.apply(wire(node), text: text))
        let current = try XCTUnwrap(surface.resourceImages[handle.slot]?.binding)
        XCTAssertFalse(old.isActive)
        XCTAssertNotEqual(current.id, old.id)
        XCTAssertTrue(surface.resourceImages[handle.slot]?.image === bitmap)
        surface.resourceImageCompleted(old, handle: handle, image: nil, error: "stale")
        XCTAssertNil(surface.failedResourceImage)
        catalog.deactivate(owner)
        XCTAssertThrowsError(try images.bind(
            ShellResourceImage(recipe(first)),
            points: 8,
            scale: 2,
            surface: surface,
            handle: handle
        ))
        XCTAssertThrowsError(try ShellResourceImage("v1/2/3/4/\(first.string.uppercased())/0"))
        XCTAssertThrowsError(try ShellResourceImage("v1/02/3/4/\(first.string.lowercased())/0"))
        surface.reset(text: text)
        XCTAssertFalse(current.isActive)
        await images.close()
    }

    private func wire(_ node: omni_wire_node) -> [UInt8] {
        var header = omni_wire_header()
        header.magic = UInt32(OMNI_WIRE_MAGIC)
        header.node_count = 1
        var node = node
        var bytes = withUnsafeBytes(of: &header) { Array($0) }
        withUnsafeBytes(of: &node) { bytes.append(contentsOf: $0) }
        return bytes
    }
}
