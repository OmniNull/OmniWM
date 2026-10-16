// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
@testable import OmniWM
import Synchronization
import XCTest

@MainActor
final class ShellThumbnailUtilityCaptureTests: XCTestCase {
    private let owner = ShellServiceOwner(generation: 9, owner: 1, epoch: 1)

    private func fixture(count: Int) async throws -> (ShellResourceStore, URL, [ShellResourceDescriptor]) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let store = ShellResourceStore(directory: directory)
        try await store.activate(owner, namespace: .init(profile: "lake", package: "lake", instance: "capture"))
        let items = (0 ..< count).map {
            ShellResourceDescriptor(id: ShellResourceID(), name: "file\($0)", kind: "file", uti: "public.png")
        }
        try store.catalog.admit(items, owner: owner)
        try await store.materialize(items.map { _ in .bytes(Data("fixture".utf8)) }, ids: items.map(\.id), owner: owner)
        return (store, directory, items)
    }

    private func image() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try XCTUnwrap(context.makeImage())
    }

    func testCacheBaselinePeakAndRemovalSurviveCapture() async throws {
        let (store, directory, items) = try await fixture(count: 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try image()
        let cost = image.bytesPerRow * image.height
        let cache = ShellThumbnailCache(catalog: store.catalog, byteLimit: cost * 2, entryLimit: 2)
        for (index, item) in items.enumerated() {
            if index == 1 { cache.captureBegin(1) }
            let binding = ShellThumbnailBinding(request: try ShellThumbnailRequest(
                resource: item.id, owner: owner, revision: 1, points: 8, scale: 1
            ))
            XCTAssertTrue(cache.admit(binding))
            _ = try cache.publish(
                image,
                key: .init(backing: UUID(), revision: 1, pixels: 8, scale: 1),
                bindings: [binding]
            )
        }
        cache.removeAll()
        XCTAssertNil(cache.captureEnd(2))
        let capture = try XCTUnwrap(cache.captureEnd(1))
        XCTAssertEqual(capture.bytesBegin, cost)
        XCTAssertEqual(capture.bytesPeak, cost * 2)
        XCTAssertEqual(capture.bytesEnd, 0)
        XCTAssertEqual(capture.entriesBegin, 1)
        XCTAssertEqual(capture.entriesPeak, 2)
        XCTAssertEqual(capture.entriesEnd, 0)
        XCTAssertNil(cache.captureEnd(1))
    }

    func testProducerCountsMissOnceWhileWarmReusePublishesWithoutDecode() async throws {
        let (store, directory, items) = try await fixture(count: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try image()
        let first = expectation(description: "first image")
        let second = expectation(description: "cached image")
        let deliveries = Mutex(0)
        let calls = Mutex(0)
        let thumbnails = ShellResourceThumbnails(store: store, producer: { _, _ in
            calls.withLock { $0 += 1 }
            return image
        }) { completion in
            XCTAssertNotNil(completion.image)
            let index = deliveries.withLock { $0 += 1
                return $0
            }
            if index == 1 { first.fulfill() } else { second.fulfill() }
        }
        await thumbnails.captureBegin(3)
        let binding = try thumbnails.binding(resource: items[0].id, owner: owner, points: 8, scale: 1)
        try await thumbnails.acquire(binding)
        await fulfillment(of: [first], timeout: 5)
        let another = try thumbnails.binding(resource: items[0].id, owner: owner, points: 8, scale: 1)
        try await thumbnails.acquire(another)
        await fulfillment(of: [second], timeout: 5)
        await thumbnails.close()
        let result = await thumbnails.captureEnd(3)
        let capture = try XCTUnwrap(result)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertEqual(capture.producerAttempts, 1)
        XCTAssertEqual(capture.producerSuccesses, 1)
        XCTAssertEqual(capture.cache.entriesPeak, 1)
        XCTAssertEqual(capture.cache.entriesEnd, 0)
        XCTAssertEqual(capture.cache.bytesEnd, 0)
    }
}
