// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import OmniWMScriptHost
import OmniWMShellCore
import XCTest

@MainActor
final class ShellBackingScaleResourceTests: XCTestCase {
    func testDensityRebindPreservesImageUntilCurrentPublicationAndRejectsOldBinding() async throws {
        let owner = ShellServiceOwner(generation: 1, owner: 1, epoch: 1)
        let resource = ShellResourceID()
        let revision: UInt64 = 0
        let points: Float = 24
        let originalScale: CGFloat = 1
        let nextScale: CGFloat = 2
        let catalog = ShellResourceCatalog()
        try catalog.activate(
            owner, namespace: ShellStoreNamespace(profile: "density", package: "density", instance: "window"),
            tokens: [:]
        )
        try catalog.admit([
            ShellResourceDescriptor(id: resource, name: "density image", kind: "image", uti: "public.png")
        ], owner: owner)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        XCTAssertEqual(catalog.metadata(resource, owner: owner)?.state, .pending)
        let store = ShellResourceStore(directory: directory, catalog: catalog)
        let images = ShellResourceImages(store: store)
        let resources = ShellResources(motion: MotionPolicy(animationsEnabled: false))
        resources.resourceImages = images
        let fixture = ShellBackingScaleFixture(scale: originalScale, resources: resources)
        let source = "v1/\(owner.generation)/\(owner.owner)/\(owner.epoch)/\(resource.string.lowercased())/\(revision)"
        var node = ShellBackingScaleFixture.node(.bitmap, size: CGSize(width: CGFloat(points), height: CGFloat(points)))
        node.subtree_end = 1
        node.resource_image_ref = 1
        node.thumbnail = points
        fixture.apply([node], strings: [source])
        await fixture.complete()
        let surface = fixture.surface
        let handle = surface.layout.core.rootHandle
        let old = try XCTUnwrap(surface.resourceImages[handle.slot]?.binding)
        let oldImage = try ShellBackingScaleFixture.image(
            size: CGSize(width: old.request.pixels, height: old.request.pixels)
        )
        surface.resourceImageCompleted(old, handle: handle, image: oldImage, error: nil)
        await fixture.complete()
        XCTAssertFalse(surface.updateDisplayContext(scale: originalScale))
        XCTAssertEqual(surface.resourceImages[handle.slot]?.binding, old)
        XCTAssertTrue(surface.updateDisplayContext(scale: nextScale))
        await fixture.complete()
        let current = try XCTUnwrap(surface.resourceImages[handle.slot]?.binding)
        let expected = try ShellThumbnailRequest(
            resource: resource, owner: owner, revision: revision, points: Double(points), scale: Double(nextScale)
        )
        XCTAssertEqual(current.request, expected)
        XCTAssertFalse(old.isActive)
        XCTAssertNotEqual(current, old)
        XCTAssertTrue(surface.resourceImages[handle.slot]?.image === oldImage)
        surface.resourceImageCompleted(old, handle: handle, image: nil, error: "obsolete density")
        XCTAssertNil(surface.failedResourceImage)
        let currentImage = try ShellBackingScaleFixture.image(
            size: CGSize(width: expected.pixels, height: expected.pixels)
        )
        surface.resourceImageCompleted(current, handle: handle, image: currentImage, error: nil)
        await fixture.complete()
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue((surface.scene.layers[handle.slot]?.contents as AnyObject?) === currentImage)
        }
        surface.resourceImageCompleted(old, handle: handle, image: oldImage, error: nil)
        await fixture.complete()
        ShellLayerScene.engineQueue.sync {
            XCTAssertTrue((surface.scene.layers[handle.slot]?.contents as AnyObject?) === currentImage)
        }
        XCTAssertFalse(surface.updateDisplayContext(scale: nextScale))
        XCTAssertEqual(surface.resourceImages[handle.slot]?.binding, current)
        surface.clearResourceImages()
        await images.close()
        XCTAssertFalse(current.isActive)
    }
}
