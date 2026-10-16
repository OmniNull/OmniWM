// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation

struct SkyLightSpaceFunctions {
    typealias CopyManagedDisplaySpacesFunc = @convention(c) (Int32) -> Unmanaged<CFArray>?
    typealias GetActiveSpaceFunc = @convention(c) (Int32) -> UInt64
    typealias CopySpacesForWindowsFunc = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    typealias CopyWindowsWithOptionsAndTagsFunc = @convention(c) (
        Int32,
        UInt32,
        CFArray,
        UInt32,
        UnsafeMutablePointer<UInt64>,
        UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?
    typealias GetSpaceManagementModeFunc = @convention(c) (Int32) -> Int32
    typealias SetMenuBarAutohideEnabledFunc = @convention(c) (Int32, Bool) -> CGError

    let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFunc
    let getActiveSpace: GetActiveSpaceFunc
    let copySpacesForWindows: CopySpacesForWindowsFunc
    let copyWindowsWithOptionsAndTags: CopyWindowsWithOptionsAndTagsFunc?
    let getSpaceManagementMode: GetSpaceManagementModeFunc
    let setMenuBarAutohideEnabled: SetMenuBarAutohideEnabledFunc?

    init(resolver: inout SkyLightSymbolResolver) {
        copyManagedDisplaySpaces = resolver.resolve(
            "SLSCopyManagedDisplaySpaces",
            as: CopyManagedDisplaySpacesFunc.self
        )
        getActiveSpace = resolver.resolve("SLSGetActiveSpace", as: GetActiveSpaceFunc.self)
        copySpacesForWindows = resolver.resolve("SLSCopySpacesForWindows", as: CopySpacesForWindowsFunc.self)
        copyWindowsWithOptionsAndTags = resolver.resolveOptional(
            "SLSCopyWindowsWithOptionsAndTags",
            as: CopyWindowsWithOptionsAndTagsFunc.self
        )
        getSpaceManagementMode = resolver.resolve("SLSGetSpaceManagementMode", as: GetSpaceManagementModeFunc.self)
        setMenuBarAutohideEnabled = resolver.resolveOptional(
            "SLSSetMenuBarAutohideEnabled",
            as: SetMenuBarAutohideEnabledFunc.self
        )
    }
}
