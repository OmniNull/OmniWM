// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit

extension CommandPaletteShellPresenter {
    func registerBitmap(_ image: CGImage, key: String) -> String {
        let id = bitmapPrefix + String(bitmapGeneration) + "/" + key
        surface.resources.setBitmap(image, for: id)
        bitmaps.insert(id)
        return id
    }

    func removeBitmap(_ id: String) {
        guard bitmaps.remove(id) != nil else { return }
        surface.resources.setBitmap(nil, for: id)
    }

    func retireBitmaps() {
        for id in bitmaps { surface.resources.setBitmap(nil, for: id) }
        bitmaps.removeAll(keepingCapacity: true)
    }
}
