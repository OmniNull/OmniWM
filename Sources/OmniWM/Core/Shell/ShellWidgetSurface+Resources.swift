// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import OmniWMShellCore

extension ShellWidgetSurface {
    struct ResourceImageBinding {
        let handle: ElementHandle
        let source: String
        let points: Float
        var binding: ShellThumbnailBinding?
        var image: CGImage?
        var error: String?
    }

    var failedResourceImage: String? {
        resourceImages.values.lazy.compactMap(\.error).first
    }

    func resourceImageCommand(_ handle: ElementHandle, content: Content, text: ShellTextStore) -> ShellLayerCommand {
        let source = text.string(content.resourceImageRef)
        if let previous = resourceImages[handle.slot], previous.handle == handle,
           previous.source == source, previous.points == content.thumbnail
        {
            return .image(slot: handle.slot, image: previous.image, animation: animation(for: handle))
        }
        let previous = resourceImages[handle.slot].flatMap { $0.handle == handle ? $0.image : nil }
        forgetResourceImage(handle)
        var entry = ResourceImageBinding(handle: handle, source: source, points: content.thumbnail, image: previous)
        do {
            guard let images = resources.resourceImages
            else { throw ShellResourceFailure("resource images are unavailable") }
            let image = try ShellResourceImage(source)
            entry.binding = try images.bind(
                image,
                points: Double(content.thumbnail),
                scale: Double(scale),
                surface: self,
                handle: handle
            )
            if let binding = entry.binding { entry.image = images.bitmap(binding) ?? previous }
        } catch { entry.error = String(describing: error) }
        resourceImages[handle.slot] = entry
        return .image(slot: handle.slot, image: entry.image, animation: animation(for: handle))
    }

    func resourceImageCompleted(
        _ binding: ShellThumbnailBinding,
        handle: ElementHandle,
        image: CGImage?,
        error: String?
    ) {
        guard layout.core.contains(handle), var entry = resourceImages[handle.slot],
              entry.handle == handle, entry.binding == binding, binding.isActive else { return }
        entry.error = error
        if let image { entry.image = image }
        resourceImages[handle.slot] = entry
        if let image {
            scene.submit(
                [.image(slot: handle.slot, image: image, animation: animation(for: handle))],
                animated: animates && motionPolicy.animationsEnabled
            )
        }
    }

    func forgetResourceImage(_ handle: ElementHandle) {
        guard let entry = resourceImages.removeValue(forKey: handle.slot) else { return }
        if let binding = entry.binding { resources.resourceImages?.release(binding) }
    }

    func clearResourceImages() {
        let images = resourceImages.values
        resourceImages.removeAll()
        for entry in images {
            if let binding = entry.binding { resources.resourceImages?.release(binding) }
        }
    }
}
