// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension SkyLight {
    var resolvedCornerRadiiAvailable: Bool {
        queries.windowIteratorGetResolvedCornerRadii != nil
    }

    func cornerSample(forWindowId wid: Int) -> WindowCornerSample? {
        queryWindowIterator(forWindowId: wid) { iterator in
            cornerSample(from: iterator)
        }
    }

    func cornerSampleDeferred(for token: WindowToken) async throws -> WindowCornerSample? {
        try Task.checkCancellation()
        guard let wid = UInt32(exactly: token.windowId), wid != 0,
              let connection = windowInfoConnection()
        else { return nil }
        return try await connection.perform { [
            windowQueryWindows = queries.windowQueryWindows,
            windowQueryResultCopyWindows = queries.windowQueryResultCopyWindows,
            windowIteratorAdvance = queries.windowIteratorAdvance,
            windowIteratorGetWindowID = queries.windowIteratorGetWindowID,
            windowIteratorGetBounds = queries.windowIteratorGetBounds,
            windowIteratorGetResolvedCornerRadii = queries.windowIteratorGetResolvedCornerRadii,
            windowIteratorGetCornerRadii = queries.windowIteratorGetCornerRadii,
            captureWindowList = surfaces.captureWindowList
        ] cid in
            let windowNumbers = [NSNumber(value: wid)] as CFArray
            guard let query = windowQueryWindows(cid, windowNumbers, 1)?.takeRetainedValue(),
                  let iterator = windowQueryResultCopyWindows(query)?.takeRetainedValue(),
                  windowIteratorAdvance(iterator),
                  windowIteratorGetWindowID(iterator) == wid
            else { return nil }
            let observedSize = windowIteratorGetBounds(iterator).size
            let resolved = windowIteratorGetResolvedCornerRadii?(iterator, 0)?.takeRetainedValue()
            if let sample = Self.cornerSample(resolved: resolved, raw: nil, observedSize: observedSize) {
                return sample
            }
            let raw = windowIteratorGetCornerRadii(iterator, 0)?.takeRetainedValue()
            if let sample = Self.cornerSample(resolved: nil, raw: raw, observedSize: observedSize) {
                return sample
            }
            guard observedSize.hasFinitePositiveDimensions(),
                  let captureWindowList, CGPreflightScreenCaptureAccess()
            else { return nil }
            var windowId = wid
            guard let images = captureWindowList(cid, &windowId, 1, (1 << 11) | (1 << 8) | (1 << 19))?
                .takeRetainedValue(),
                let image = Self.firstCapturedImage(in: images),
                let contour = WindowCornerContour(image: image, observedSize: observedSize)
            else { return nil }
            return WindowCornerSample(
                radii: .zero, observedSize: observedSize, source: .captured, contour: contour
            )
        }
    }

    func diagnosticCornerSamples(
        forWindowId wid: Int
    ) -> (resolved: WindowCornerSample?, raw: WindowCornerSample?) {
        queryWindowIterator(forWindowId: wid) { iterator in
            let observedSize = queries.windowIteratorGetBounds(iterator).size
            let resolved = queries.windowIteratorGetResolvedCornerRadii?(iterator, 0)?.takeRetainedValue()
            let raw = queries.windowIteratorGetCornerRadii(iterator, 0)?.takeRetainedValue()
            return Self.diagnosticCornerSamples(
                resolved: resolved,
                raw: raw,
                observedSize: observedSize
            )
        } ?? (nil, nil)
    }

    private func queryWindowIterator<T>(forWindowId wid: Int, _ read: (CFTypeRef) -> T?) -> T? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }

        var widValue = Int32(wid)
        let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue)!
        let windowArray = [widNumber] as CFArray

        guard let query = queries.windowQueryWindows(cid, windowArray, 0)?.takeRetainedValue() else { return nil }
        guard let iterator = queries.windowQueryResultCopyWindows(query)?.takeRetainedValue() else { return nil }

        guard queries.windowIteratorGetCount(iterator) > 0,
              queries.windowIteratorAdvance(iterator)
        else {
            return nil
        }
        return read(iterator)
    }

    private func cornerSample(from iterator: CFTypeRef) -> WindowCornerSample? {
        let observedSize = queries.windowIteratorGetBounds(iterator).size
        let resolved = queries.windowIteratorGetResolvedCornerRadii?(iterator, 0)?.takeRetainedValue()
        if let sample = Self.cornerSample(resolved: resolved, raw: nil, observedSize: observedSize) {
            return sample
        }
        let raw = queries.windowIteratorGetCornerRadii(iterator, 0)?.takeRetainedValue()
        return Self.cornerSample(resolved: nil, raw: raw, observedSize: observedSize)
    }

    nonisolated static func cornerSample(
        resolved: CFArray?,
        raw: CFArray?,
        observedSize: CGSize
    ) -> WindowCornerSample? {
        guard observedSize.hasFinitePositiveDimensions() else {
            return nil
        }
        if let radii = parseCornerRadii(resolved), !radii.isAllZero {
            return WindowCornerSample(radii: radii, observedSize: observedSize, source: .resolved)
        }
        guard let radii = parseCornerRadii(raw), !radii.isAllZero else { return nil }
        return WindowCornerSample(radii: radii, observedSize: observedSize, source: .raw)
    }

    static func diagnosticCornerSamples(
        resolved: CFArray?,
        raw: CFArray?,
        observedSize: CGSize
    ) -> (resolved: WindowCornerSample?, raw: WindowCornerSample?) {
        (
            resolved: cornerSample(resolved: resolved, raw: nil, observedSize: observedSize),
            raw: cornerSample(resolved: nil, raw: raw, observedSize: observedSize)
        )
    }

    nonisolated static func parseCornerRadii(_ values: CFArray?) -> WindowCornerRadii? {
        guard let values else { return nil }
        let count = CFArrayGetCount(values)
        guard count == 1 || count == 4 else { return nil }

        func radius(at index: CFIndex) -> CGFloat? {
            let pointer = CFArrayGetValueAtIndex(values, index)
            let value = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard CFGetTypeID(value) == CFNumberGetTypeID() else { return nil }
            var radius = 0.0
            guard CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .doubleType, &radius),
                  radius.isFinite,
                  radius >= 0
            else {
                return nil
            }
            return CGFloat(radius)
        }

        guard let topLeft = radius(at: 0) else { return nil }
        if count == 1 {
            return WindowCornerRadii(uniform: topLeft)
        }
        guard let topRight = radius(at: 1),
              let bottomRight = radius(at: 2),
              let bottomLeft = radius(at: 3)
        else {
            return nil
        }
        return WindowCornerRadii(
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight
        )
    }
}
