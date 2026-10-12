// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension SkyLight {
    private struct WindowInfoQuery: Sendable {
        let windowIds: Set<UInt32>
        let windowQueryWindows: SkyLightQueryFunctions.WindowQueryWindowsFunc
        let windowQueryResultCopyWindows: SkyLightQueryFunctions.WindowQueryResultCopyWindowsFunc
        let windowIteratorAdvance: SkyLightQueryFunctions.WindowIteratorAdvanceFunc
        let windowIteratorGetWindowID: SkyLightQueryFunctions.WindowIteratorGetWindowIDFunc
        let windowIteratorGetPID: SkyLightQueryFunctions.WindowIteratorGetPIDFunc
        let windowIteratorGetLevel: SkyLightQueryFunctions.WindowIteratorGetLevelFunc
        let windowIteratorGetBounds: SkyLightQueryFunctions.WindowIteratorGetBoundsFunc
        let windowIteratorGetTags: SkyLightQueryFunctions.WindowIteratorGetTagsFunc
        let windowIteratorGetAttributes: SkyLightQueryFunctions.WindowIteratorGetAttributesFunc
        let windowIteratorGetParentID: SkyLightQueryFunctions.WindowIteratorGetParentIDFunc
        let includeOrderedIn: Bool

        nonisolated func read(connectionId cid: Int32) -> [UInt32: WindowServerInfo]? {
            guard !windowIds.isEmpty else { return [:] }
            guard cid != 0,
                  let windowCount = UInt32(exactly: windowIds.count)
            else {
                return nil
            }

            let windowNumbers = windowIds.map { NSNumber(value: $0) } as CFArray
            guard let query = windowQueryWindows(cid, windowNumbers, windowCount)?.takeRetainedValue()
            else { return nil }
            guard let iterator = windowQueryResultCopyWindows(query)?.takeRetainedValue() else { return nil }

            var windowInfoById: [UInt32: WindowServerInfo] = [:]
            windowInfoById.reserveCapacity(windowIds.count)
            while windowIteratorAdvance(iterator) {
                let windowId = windowIteratorGetWindowID(iterator)
                guard windowIds.contains(windowId) else { continue }
                let attributes = windowIteratorGetAttributes(iterator)
                windowInfoById[windowId] = WindowServerInfo(
                    id: windowId,
                    pid: windowIteratorGetPID(iterator),
                    level: windowIteratorGetLevel(iterator),
                    frame: windowIteratorGetBounds(iterator),
                    tags: windowIteratorGetTags(iterator),
                    attributes: attributes,
                    parentId: windowIteratorGetParentID(iterator),
                    isOrderedIn: includeOrderedIn ? (attributes & 0x2) != 0 : nil
                )
            }
            return windowInfoById
        }
    }

    private func windowInfoQuery(_ windowIds: Set<UInt32>, includeOrderedIn: Bool = false) -> WindowInfoQuery {
        WindowInfoQuery(
            windowIds: windowIds,
            windowQueryWindows: queries.windowQueryWindows,
            windowQueryResultCopyWindows: queries.windowQueryResultCopyWindows,
            windowIteratorAdvance: queries.windowIteratorAdvance,
            windowIteratorGetWindowID: queries.windowIteratorGetWindowID,
            windowIteratorGetPID: queries.windowIteratorGetPID,
            windowIteratorGetLevel: queries.windowIteratorGetLevel,
            windowIteratorGetBounds: queries.windowIteratorGetBounds,
            windowIteratorGetTags: queries.windowIteratorGetTags,
            windowIteratorGetAttributes: queries.windowIteratorGetAttributes,
            windowIteratorGetParentID: queries.windowIteratorGetParentID,
            includeOrderedIn: includeOrderedIn
        )
    }

    func queryWindowInfo(windowIds: Set<UInt32>) -> [UInt32: WindowServerInfo]? {
        guard !windowIds.isEmpty else { return [:] }
        return MainThreadAXSpanTrace.measure(.windowServerBatchQuery, count: windowIds.count) {
            windowInfoQuery(windowIds).read(connectionId: getMainConnectionID())
        } succeeded: { $0 != nil }
    }

    func hasOverlappingWindowsAbove(_ windowId: UInt32, among candidates: Set<UInt32>) -> Bool? {
        MainThreadAXSpanTrace.measure(.focusCoverageQuery, windowId: Int(windowId), count: candidates.count) {
            guard let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenAboveWindow, .optionIncludingWindow], windowId
            ) as? [[String: Any]] else { return nil as Bool? }
            return Self.hasOverlappingWindowsAbove(windowId, among: candidates, in: windows)
        } succeeded: { $0 != nil }
    }

    static func hasOverlappingWindowsAbove(
        _ windowId: UInt32,
        among candidates: Set<UInt32>,
        in windows: [[String: Any]]
    ) -> Bool? {
        guard let targetIndex = windows.firstIndex(where: { $0[kCGWindowNumber as String] as? UInt32 == windowId }),
              let targetBounds = windows[targetIndex][kCGWindowBounds as String] as? [String: Any],
              let targetFrame = CGRect(dictionaryRepresentation: targetBounds as CFDictionary)
        else { return nil }
        for window in windows[..<targetIndex] {
            guard let candidateId = window[kCGWindowNumber as String] as? UInt32,
                  candidates.contains(candidateId)
            else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            let overlap = targetFrame.intersection(frame)
            if !overlap.isNull, overlap.width > 4, overlap.height > 4 {
                return true
            }
        }
        return false
    }

    func queryWindowInfoDeferred(
        windowIds: Set<UInt32>,
        includeOrderedIn: Bool = false
    ) async throws -> [UInt32: WindowServerInfo]? {
        try Task.checkCancellation()
        guard !windowIds.isEmpty else { return [:] }
        guard let connection = windowInfoConnection() else { return nil }
        let query = windowInfoQuery(windowIds, includeOrderedIn: includeOrderedIn)
        return try await connection.perform { query.read(connectionId: $0) }
    }

    func queryAllVisibleWindows() -> [WindowServerInfo] {
        let result = MainThreadAXSpanTrace.measure(.windowServerVisibleQuery) { () -> [WindowServerInfo]? in
            let cid = getMainConnectionID()
            guard cid != 0 else { return nil }

            let emptyArray = [] as CFArray
            guard let query = queries.windowQueryWindows(cid, emptyArray, 0)?.takeRetainedValue() else { return nil }
            guard let iterator = queries.windowQueryResultCopyWindows(query)?.takeRetainedValue() else { return nil }

            var results: [WindowServerInfo] = []

            while queries.windowIteratorAdvance(iterator) {
                let parentId = queries.windowIteratorGetParentID(iterator)
                guard parentId == 0 else { continue }

                let level = queries.windowIteratorGetLevel(iterator)
                guard level == 0 || level == 3 || level == 8 else { continue }

                let tags = queries.windowIteratorGetTags(iterator)
                let attributes = queries.windowIteratorGetAttributes(iterator)

                let hasVisibleAttribute = (attributes & 0x2) != 0
                let hasTagBit54 = (tags & 0x0040_0000_0000_0000) != 0
                guard hasVisibleAttribute || hasTagBit54 else { continue }
                let hasDocumentTag = WindowServerInfo.hasDocumentTag(tags)
                let hasFloatingTag = WindowServerInfo.hasFloatingTag(tags)
                let hasModalTag = WindowServerInfo.hasModalTag(tags)
                guard hasDocumentTag || (hasFloatingTag && hasModalTag) else { continue }

                let wid = queries.windowIteratorGetWindowID(iterator)
                let pid = queries.windowIteratorGetPID(iterator)
                let bounds = queries.windowIteratorGetBounds(iterator)
                let info = WindowServerInfo(
                    id: wid,
                    pid: pid,
                    level: level,
                    frame: bounds,
                    tags: tags,
                    attributes: attributes,
                    parentId: parentId
                )

                results.append(info)
            }

            return results
        } succeeded: { $0 != nil }
        return result ?? []
    }

    func queryWindowInfo(_ windowId: UInt32) -> WindowServerInfo? {
        MainThreadAXSpanTrace.measure(.windowServerQuery, windowId: Int(windowId), count: 1) {
            let cid = getMainConnectionID()
            guard cid != 0 else { return nil }

            var widValue = Int32(windowId)
            let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue)!
            let windowArray = [widNumber] as CFArray

            guard let query = queries.windowQueryWindows(cid, windowArray, 1)?.takeRetainedValue() else { return nil }
            guard let iterator = queries.windowQueryResultCopyWindows(query)?.takeRetainedValue() else { return nil }
            guard queries.windowIteratorAdvance(iterator) else { return nil }

            let wid = queries.windowIteratorGetWindowID(iterator)
            let pid = queries.windowIteratorGetPID(iterator)
            let level = queries.windowIteratorGetLevel(iterator)
            let bounds = queries.windowIteratorGetBounds(iterator)
            let tags = queries.windowIteratorGetTags(iterator)
            let attributes = queries.windowIteratorGetAttributes(iterator)
            let parentId = queries.windowIteratorGetParentID(iterator)

            return WindowServerInfo(
                id: wid,
                pid: pid,
                level: level,
                frame: bounds,
                tags: tags,
                attributes: attributes,
                parentId: parentId
            )
        } succeeded: { $0 != nil }
    }
}
