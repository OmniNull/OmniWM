// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import ImageIO
@testable import OmniWM
import Synchronization
import UniformTypeIdentifiers
import XCTest

final class ShellResourceThumbnailTests: XCTestCase {
    private actor Decoder {
        struct Call {
            let source: ShellResourceStore.ThumbnailSource
            let request: ShellThumbnailRequest
            let continuation: CheckedContinuation<CGImage, any Error>
        }

        var calls: [Call] = []
        var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

        func produce(
            _ source: ShellResourceStore.ThumbnailSource,
            request: ShellThumbnailRequest
        ) async throws -> CGImage {
            try await withCheckedThrowingContinuation { continuation in
                calls.append(Call(source: source, request: request, continuation: continuation))
                let ready = waiters.filter { calls.count >= $0.0 }
                waiters.removeAll { calls.count >= $0.0 }
                for (_, waiter) in ready { waiter.resume() }
            }
        }

        func waitForCalls(_ count: Int) async {
            if calls.count >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }

        func finish(_ index: Int, image: CGImage) {
            calls[index].continuation.resume(returning: image)
        }

        func file(_ index: Int) -> URL {
            calls[index].source.file
        }

        func count() -> Int {
            calls.count
        }
    }

    private let owner = ShellServiceOwner(generation: 11, owner: 2, epoch: 3)
    private let namespace = ShellStoreNamespace(profile: "lake", package: "lake", instance: "shelf")

    private func fixture(count: Int = 1) async throws -> (ShellResourceStore, URL, [ShellResourceDescriptor]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let store = ShellResourceStore(directory: directory)
        try await store.activate(owner, namespace: namespace)
        let items = (0 ..< count).map { ShellResourceDescriptor(
            id: ShellResourceID(),
            name: "file\($0)",
            kind: "file",
            uti: "public.png"
        ) }
        try store.catalog.admit(items, owner: owner)
        try await store.materialize(items.map { _ in .bytes(Data("test".utf8)) }, ids: items.map(\.id), owner: owner)
        return (store, directory, items)
    }

    private func acquire(
        _ service: ShellResourceThumbnails,
        resource: ShellResourceID,
        owner: ShellServiceOwner,
        points: Double,
        scale: Double
    ) async throws -> ShellThumbnailBinding {
        let binding = try service.binding(resource: resource, owner: owner, points: points, scale: scale)
        try await service.acquire(binding)
        return binding
    }

    private static func image(_ side: Int = 8) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(context.makeImage())
    }

    func testPhysicalPixelsAndOwnerValidation() async throws {
        let (store, directory, items) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try ShellThumbnailRequest(
            resource: items[0].id,
            owner: owner,
            revision: 1,
            points: 127.5,
            scale: 2
        )
        XCTAssertEqual(request.pixels, 255)
        XCTAssertThrowsError(try ShellThumbnailRequest(
            resource: items[0].id,
            owner: owner,
            revision: 1,
            points: 1025,
            scale: 2
        ))
        XCTAssertThrowsError(try ShellThumbnailRequest(
            resource: items[0].id,
            owner: owner,
            revision: 1,
            points: .nan,
            scale: 1
        ))
        let service = ShellResourceThumbnails(store: store)
        let wrong = ShellServiceOwner(generation: owner.generation, owner: owner.owner, epoch: owner.epoch + 1)
        do {
            _ = try await acquire(service, resource: items[0].id, owner: wrong, points: 8, scale: 1)
            XCTFail("stale owner acquired thumbnail")
        } catch {}
        await service.close()
    }

    func testCancelledBindingCannotBeAdmittedOrLookedUp() async throws {
        let (store, directory, items) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = ShellResourceThumbnails(store: store)
        let binding = try service.binding(resource: items[0].id, owner: owner, points: 8, scale: 1)
        binding.cancel()
        do {
            try await service.acquire(binding)
            XCTFail("cancelled binding was admitted")
        } catch {}
        XCTAssertNil(service.cache.status(binding))
        XCTAssertNil(service.cache.bitmap(binding))
        await service.close()
    }

    func testByteLRUEvictionPreservesDeliveredImageAndTouchesLookup() async throws {
        let (store, directory, items) = try await fixture(count: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try Self.image()
        let cache = ShellThumbnailCache(
            catalog: store.catalog,
            byteLimit: image.bytesPerRow * image.height * 2,
            entryLimit: 512
        )
        var bindings: [ShellThumbnailBinding] = []
        for item in items {
            let request = try ShellThumbnailRequest(resource: item.id, owner: owner, revision: 1, points: 8, scale: 1)
            bindings.append(ShellThumbnailBinding(request: request))
        }
        for binding in bindings { cache.admit(binding) }
        for binding in bindings.prefix(2) {
            _ = try cache.publish(
                image,
                key: .init(backing: UUID(), revision: 1, pixels: 8, scale: 1),
                bindings: [binding]
            )
        }
        let delivered = try XCTUnwrap(cache.bitmap(bindings[0]))
        _ = try cache.publish(
            image,
            key: .init(backing: UUID(), revision: 1, pixels: 8, scale: 1),
            bindings: [bindings[2]]
        )
        XCTAssertEqual(cache.status(bindings[1]), .evicted)
        XCTAssertEqual(cache.status(bindings[0]), .ready)
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertEqual(cache.retainedBytes, image.bytesPerRow * image.height * 2)
        XCTAssertEqual(delivered.width, 8)
        store.catalog.deactivate(owner)
        XCTAssertNil(cache.bitmap(bindings[0]))
        cache.retire(owner)
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertEqual(delivered.width, 8)
    }

    func testEntryLimitBoundsTinyImagesIndependentlyOfBytes() async throws {
        let (store, directory, items) = try await fixture(count: 3)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ShellThumbnailCache(catalog: store.catalog, byteLimit: 1 << 20, entryLimit: 2)
        for item in items {
            let binding = ShellThumbnailBinding(request: try ShellThumbnailRequest(
                resource: item.id,
                owner: owner,
                revision: 1,
                points: 1,
                scale: 1
            ))
            cache.admit(binding)
            _ = try cache.publish(
                Self.image(1),
                key: .init(backing: UUID(), revision: 1, pixels: 1, scale: 1),
                bindings: [binding]
            )
        }
        XCTAssertEqual(cache.entryCount, 2)
        XCTAssertEqual(cache.retainedBytes, 8)
    }

    func testDeduplicatesActiveDecodeAndPreservesReadyLookup() async throws {
        let (store, directory, items) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = Decoder()
        let complete = expectation(description: "two bindings share image")
        let delivered = Mutex<[ShellThumbnailBinding]>([])
        let service = ShellResourceThumbnails(
            store: store,
            producer: { try await decoder.produce($0, request: $1) }
        ) { result in
            delivered.withLock { $0 = result.bindings }
            XCTAssertNotNil(result.image)
            complete.fulfill()
        }
        let first = try await acquire(service, resource: items[0].id, owner: owner, points: 8, scale: 1)
        let second = try await acquire(service, resource: items[0].id, owner: owner, points: 8, scale: 1)
        await decoder.waitForCalls(1)
        let count = await decoder.count()
        XCTAssertEqual(count, 1)
        await decoder.finish(0, image: try Self.image())
        await fulfillment(of: [complete], timeout: 5)
        XCTAssertEqual(Set(delivered.withLock { $0 }), Set([first, second]))
        XCTAssertNotNil(service.cache.bitmap(first))
        XCTAssertNotNil(service.cache.bitmap(second))
        await service.close()
    }

    func testReplacementDemandWaitsForCancelledDecoderBeforeRestarting() async throws {
        let (store, directory, items) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = Decoder()
        let complete = expectation(description: "replacement binding completes")
        let delivered = Mutex<[ShellThumbnailBinding]>([])
        let service = ShellResourceThumbnails(
            store: store,
            producer: { try await decoder.produce($0, request: $1) }
        ) { result in
            delivered.withLock { $0 = result.bindings }
            complete.fulfill()
        }
        let first = try await acquire(service, resource: items[0].id, owner: owner, points: 8, scale: 1)
        await decoder.waitForCalls(1)
        first.cancel()
        await service.release(first)
        let second = try await acquire(service, resource: items[0].id, owner: owner, points: 8, scale: 1)
        await decoder.finish(0, image: try Self.image())
        await decoder.waitForCalls(2)
        await decoder.finish(1, image: try Self.image())
        await fulfillment(of: [complete], timeout: 5)
        XCTAssertEqual(delivered.withLock { $0 }, [second])
        XCTAssertNil(service.cache.bitmap(first))
        XCTAssertNotNil(service.cache.bitmap(second))
        await service.close()
    }

    func testRetirementCancelsPublicationAndPinsFileUntilCompletion() async throws {
        let (store, directory, items) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = Decoder()
        let completions = Mutex(0)
        let service = ShellResourceThumbnails(
            store: store,
            producer: { try await decoder.produce($0, request: $1) }
        ) { _ in completions.withLock { $0 += 1 } }
        let binding = try await acquire(service, resource: items[0].id, owner: owner, points: 8, scale: 1)
        await decoder.waitForCalls(1)
        let file = await decoder.file(0)
        store.catalog.deactivate(owner)
        await service.retire(owner)
        _ = await store.retire(owner)
        XCTAssertNil(service.cache.status(binding))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await decoder.finish(0, image: try Self.image())
        await service.close()
        XCTAssertEqual(completions.withLock { $0 }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testMissingFileFailsWithoutCallingDecoder() async throws {
        let (store, directory, items) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try ShellThumbnailRequest(resource: items[0].id, owner: owner, revision: 1, points: 8, scale: 1)
        let source = try await store.thumbnailSource(request)
        try FileManager.default.removeItem(at: source.file)
        await store.release(source.pin)
        let complete = expectation(description: "missing file fails")
        let decodes = Mutex(0)
        let service = ShellResourceThumbnails(store: store, producer: { _, _ in
            decodes.withLock { $0 += 1 }
            return try Self.image()
        }) { result in
            XCTAssertNil(result.image)
            XCTAssertNotNil(result.error)
            complete.fulfill()
        }
        let binding = try await acquire(service, resource: items[0].id, owner: owner, points: 8, scale: 1)
        await fulfillment(of: [complete], timeout: 5)
        guard case .failed = service.cache.status(binding) else { return XCTFail("missing failed status") }
        XCTAssertEqual(decodes.withLock { $0 }, 0)
        await service.close()
    }

    func testQueueBoundHasTwoActiveAndSixtyFourWaiting() async throws {
        let (store, directory, items) = try await fixture(count: 67)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = Decoder()
        let service = ShellResourceThumbnails(store: store, producer: { try await decoder.produce($0, request: $1) })
        var bindings: [ShellThumbnailBinding] = []
        for item in items { bindings.append(try await acquire(
            service,
            resource: item.id,
            owner: owner,
            points: 8,
            scale: 1
        )) }
        await decoder.waitForCalls(2)
        let count = await decoder.count()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(service.cache.status(bindings[66]), .failed("thumbnail queue is full"))
        await service.retire(owner)
        await decoder.finish(0, image: try Self.image())
        await decoder.finish(1, image: try Self.image())
        await service.close()
    }

    func testImageIOUsesPhysicalSizeOffMain() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("source.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            file as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, try Self.image(128), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let store = ShellResourceStore(directory: directory.appendingPathComponent("resources"))
        try await store.activate(owner, namespace: namespace)
        let item = ShellResourceDescriptor(
            id: ShellResourceID(),
            name: "source.png",
            kind: "file",
            uti: UTType.png.identifier
        )
        try store.catalog.admit([item], owner: owner)
        try await store.materialize([.file(file)], ids: [item.id], owner: owner)
        let complete = expectation(description: "ImageIO thumbnail")
        let service = ShellResourceThumbnails(store: store, completed: { result in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(result.image?.width, 32)
            XCTAssertEqual(result.image?.height, 32)
            complete.fulfill()
        })
        let binding = try await acquire(service, resource: item.id, owner: owner, points: 16, scale: 2)
        await fulfillment(of: [complete], timeout: 5)
        XCTAssertEqual(service.cache.bitmap(binding)?.width, 32)
        await service.close()
    }
}
