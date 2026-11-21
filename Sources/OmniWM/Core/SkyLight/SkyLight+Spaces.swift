// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

extension SkyLight {
    var displaysHaveSeparateSpaces: DisplaySpacesMode {
        let cid = getMainConnectionID()
        guard cid != 0 else { return .unavailable }
        return spaces.getSpaceManagementMode(cid) == 1 ? .enabled : .disabled
    }

    private static let allSpacesMask: Int32 = 0x7

    private static let nativeSpaceWindowOptions: UInt32 = 0x7

    private static let fullscreenSpaceType = 4

    private typealias DisplayCreateUUIDFromDisplayIDFunc = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?

    private nonisolated static let displayCreateUUIDFromDisplayID: DisplayCreateUUIDFromDisplayIDFunc? = {
        let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
            ?? dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
        guard let handle, let symbol = dlsym(handle, "CGDisplayCreateUUIDFromDisplayID") else { return nil }
        return unsafeBitCast(symbol, to: DisplayCreateUUIDFromDisplayIDFunc.self)
    }()

    nonisolated static var displayUUIDResolved: Bool {
        displayCreateUUIDFromDisplayID != nil
    }

    func displayId(forSpaceId spaceId: UInt64, among monitors: [Monitor]) -> CGDirectDisplayID? {
        guard spaceId != 0, !monitors.isEmpty else { return nil }
        let cid = getMainConnectionID()
        guard cid != 0, let spacesRef = spaces.copyManagedDisplaySpaces(cid)?.takeRetainedValue() else { return nil }
        guard let displaySpaces = spacesRef as? [[String: Any]] else { return nil }

        var displayIdByIdentifier: [String: CGDirectDisplayID] = [:]
        for monitor in monitors {
            displayIdByIdentifier[String(monitor.displayId)] = monitor.displayId
            if let identifier = monitor.displayUUID {
                displayIdByIdentifier[identifier] = monitor.displayId
            }
        }
        if let main = monitors.first(where: \.isMain) ?? monitors.first {
            displayIdByIdentifier["Main"] = main.displayId
        }

        for display in displaySpaces {
            guard Self.displaySpaces(display, contains: spaceId),
                  let identifier = display["Display Identifier"] as? String,
                  let displayId = displayIdByIdentifier[identifier]
            else {
                continue
            }
            return displayId
        }

        return nil
    }

    func activeSpace() -> UInt64? {
        let cid = getMainConnectionID()
        guard cid != 0 else { return nil }
        let space = spaces.getActiveSpace(cid)
        return space != 0 ? space : nil
    }

    func spacesForWindow(_ windowId: UInt32) -> [UInt64] {
        let cid = getMainConnectionID()
        guard cid != 0 else { return [] }
        var widValue = Int32(bitPattern: windowId)
        guard let widNumber = CFNumberCreate(nil, .sInt32Type, &widValue) else { return [] }
        let windowArray = [widNumber] as CFArray
        guard let result = spaces.copySpacesForWindows(cid, Self.allSpacesMask, windowArray)?.takeRetainedValue()
        else { return [] }
        guard let spaceValues = result as? [Any] else { return [] }
        return spaceValues.compactMap(Self.numericUInt64).filter { $0 != 0 }
    }

    func spaceForWindow(_ windowId: UInt32) -> UInt64? {
        spacesForWindow(windowId).first
    }

    func nativeSpaceWindowInventory(
        spaceIds: Set<UInt64>
    ) -> NativeSpaceWindowInventoryResult {
        guard !spaceIds.contains(0) else { return .queryFailed }
        guard !spaceIds.isEmpty else { return .authoritative([:]) }
        guard let copyWindowsWithOptionsAndTags = spaces.copyWindowsWithOptionsAndTags else { return .unavailable }

        let cid = getMainConnectionID()
        guard cid != 0 else { return .queryFailed }

        var windowIdsBySpace: [UInt64: [UInt32]] = [:]
        windowIdsBySpace.reserveCapacity(spaceIds.count)
        var seenWindowIds = Set<UInt32>()

        for spaceId in spaceIds {
            guard let windowIds = nativeSpaceWindowIds(
                spaceId: spaceId,
                connectionId: cid,
                copyWindowsWithOptionsAndTags: copyWindowsWithOptionsAndTags
            ) else {
                return .queryFailed
            }
            windowIdsBySpace[spaceId] = windowIds
            seenWindowIds.formUnion(windowIds)
        }

        guard !seenWindowIds.isEmpty else {
            return .authoritative(windowIdsBySpace.mapValues { _ in [] })
        }

        guard let windowInfoById = queryWindowInfo(windowIds: seenWindowIds) else { return .queryFailed }

        guard let inventory = Self.mergeNativeSpaceWindowInventory(
            windowIdsBySpace: windowIdsBySpace,
            windowInfoById: windowInfoById
        ) else {
            return .queryFailed
        }
        return .authoritative(inventory)
    }

    private func nativeSpaceWindowIds(
        spaceId: UInt64,
        connectionId: Int32,
        copyWindowsWithOptionsAndTags: SkyLightSpaceFunctions.CopyWindowsWithOptionsAndTagsFunc
    ) -> [UInt32]? {
        let spaces = [NSNumber(value: Int64(bitPattern: spaceId))] as CFArray
        var setTags: UInt64 = 0
        var clearTags: UInt64 = 0
        guard let windows = copyWindowsWithOptionsAndTags(
            connectionId,
            0,
            spaces,
            Self.nativeSpaceWindowOptions,
            &setTags,
            &clearTags
        )?.takeRetainedValue() else {
            return nil
        }

        var windowIds: [UInt32] = []
        let count = CFArrayGetCount(windows)
        windowIds.reserveCapacity(count)
        for index in 0 ..< count {
            let pointer = CFArrayGetValueAtIndex(windows, index)
            let rawWindowId = unsafeBitCast(pointer, to: CFTypeRef.self)
            guard let numericWindowId = Self.numericUInt64(rawWindowId),
                  let windowId = UInt32(exactly: numericWindowId),
                  windowId != 0
            else {
                return nil
            }
            windowIds.append(windowId)
        }
        return windowIds
    }

    nonisolated static func mergeNativeSpaceWindowInventory(
        windowIdsBySpace: [UInt64: [UInt32]],
        windowInfoById: [UInt32: WindowServerInfo]
    ) -> [UInt64: [WindowServerInfo]]? {
        var inventory: [UInt64: [WindowServerInfo]] = [:]
        inventory.reserveCapacity(windowIdsBySpace.count)

        for (spaceId, windowIds) in windowIdsBySpace {
            var windows: [WindowServerInfo] = []
            windows.reserveCapacity(windowIds.count)
            var seenWindowIds = Set<UInt32>()
            seenWindowIds.reserveCapacity(windowIds.count)
            for windowId in windowIds where seenWindowIds.insert(windowId).inserted {
                guard let info = windowInfoById[windowId] else { return nil }
                windows.append(info)
            }
            inventory[spaceId] = windows
        }

        return inventory
    }

    nonisolated static func isSuitableNativeSpaceWindow(_ info: WindowServerInfo) -> Bool {
        guard info.id != 0, info.pid > 0 else { return false }
        guard info.parentId == 0 else { return false }
        guard info.level == 0 || info.level == 3 || info.level == 8 else { return false }
        return info.hasDocumentTag || info.hasFloatingTag
    }

    func managedSpaces() -> [ManagedDisplaySpaces] {
        let cid = getMainConnectionID()
        guard cid != 0, let spacesRef = spaces.copyManagedDisplaySpaces(cid)?.takeRetainedValue() else { return [] }
        guard let displaySpaces = spacesRef as? [[String: Any]] else { return [] }

        return displaySpaces.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            var spaceIds: [UInt64] = []
            var fullscreenSpaceIds: Set<UInt64> = []
            if let spaces = display["Spaces"] as? [[String: Any]] {
                for space in spaces {
                    guard let spaceId = Self.spaceId(space) else { continue }
                    spaceIds.append(spaceId)
                    if Self.spaceType(space) == Self.fullscreenSpaceType {
                        fullscreenSpaceIds.insert(spaceId)
                    }
                }
            }
            let currentSpaceId = (display["Current Space"] as? [String: Any]).flatMap(Self.spaceId) ?? 0
            return ManagedDisplaySpaces(
                displayIdentifier: identifier,
                spaceIds: spaceIds,
                currentSpaceId: currentSpaceId,
                fullscreenSpaceIds: fullscreenSpaceIds
            )
        }
    }

    func currentSpaceUUID(forDisplay identifier: String) -> String? {
        let cid = getMainConnectionID()
        guard cid != 0,
              let displaySpaces = spaces.copyManagedDisplaySpaces(cid)?.takeRetainedValue() as? [[String: Any]],
              let display = displaySpaces.first(where: { $0["Display Identifier"] as? String == identifier })
              ?? displaySpaces.first(where: { $0["Display Identifier"] as? String == "Main" })
        else { return nil }
        return (display["Current Space"] as? [String: Any])?["uuid"] as? String
    }

    nonisolated static func displayUUID(for displayId: CGDirectDisplayID) -> String? {
        guard let uuid = displayCreateUUIDFromDisplayID?(displayId)?.takeRetainedValue(),
              let string = CFUUIDCreateString(nil, uuid)
        else { return nil }
        return string as String
    }

    private static func displaySpaces(_ display: [String: Any], contains spaceId: UInt64) -> Bool {
        if let current = display["Current Space"] as? [String: Any],
           space(current, hasId: spaceId)
        {
            return true
        }
        guard let spaces = display["Spaces"] as? [[String: Any]] else { return false }
        return spaces.contains { space($0, hasId: spaceId) }
    }

    private static func space(_ space: [String: Any], hasId spaceId: UInt64) -> Bool {
        numericUInt64(space["id64"]) == spaceId ||
            numericUInt64(space["ManagedSpaceID"]) == spaceId ||
            numericUInt64(space["id"]) == spaceId
    }

    private static func spaceId(_ space: [String: Any]) -> UInt64? {
        numericUInt64(space["id64"]) ?? numericUInt64(space["ManagedSpaceID"]) ?? numericUInt64(space["id"])
    }

    private static func spaceType(_ space: [String: Any]) -> Int? {
        switch space["type"] {
        case let value as Int:
            value
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }

    static func numericUInt64(_ value: Any?) -> UInt64? {
        switch value {
        case let value as UInt64:
            value
        case let value as UInt32:
            UInt64(value)
        case let value as UInt:
            UInt64(value)
        case let value as Int where value >= 0:
            UInt64(value)
        case let value as NSNumber:
            value.uint64Value
        case let value as String:
            UInt64(value)
        default:
            nil
        }
    }
}
