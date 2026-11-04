// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension SkyLight {
    func windowPictureDeferred(for token: WindowToken) async throws -> CGImage? {
        try Task.checkCancellation()
        guard let wid = UInt32(exactly: token.windowId), wid != 0,
              let connection = windowInfoConnection(),
              let captureWindowList = surfaces.captureWindowList
        else { return nil }
        return try await connection.perform { [
            windowQueryWindows = queries.windowQueryWindows,
            windowQueryResultCopyWindows = queries.windowQueryResultCopyWindows,
            windowIteratorAdvance = queries.windowIteratorAdvance,
            windowIteratorGetWindowID = queries.windowIteratorGetWindowID,
            windowIteratorGetPID = queries.windowIteratorGetPID
        ] cid in
            guard let query = windowQueryWindows(cid, [NSNumber(value: wid)] as CFArray, 0)?.takeRetainedValue(),
                  let iterator = windowQueryResultCopyWindows(query)?.takeRetainedValue(),
                  windowIteratorAdvance(iterator),
                  windowIteratorGetWindowID(iterator) == wid,
                  windowIteratorGetPID(iterator) == token.pid
            else { return nil }
            var windowId = wid
            let fullBackingCaptureOptions: UInt32 = (1 << 11) | (1 << 15)
            guard let images = captureWindowList(cid, &windowId, 1, fullBackingCaptureOptions)?.takeRetainedValue()
            else { return nil }
            return Self.firstCapturedImage(in: images)
        }
    }
}
