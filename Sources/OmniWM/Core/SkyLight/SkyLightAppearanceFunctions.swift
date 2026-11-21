// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct SkyLightAppearanceFunctions: Sendable {
    typealias GetThemeFunc = @convention(c) () -> Int32
    typealias SetThemeFunc = @convention(c) (Int32) -> Void

    static let light: Int32 = 0
    static let dark: Int32 = 1

    static let system: SkyLightAppearanceFunctions = {
        var resolver = SkyLightSymbolResolver()
        return SkyLightAppearanceFunctions(
            getTheme: resolver.resolveOptional("SLSGetAppearanceThemeLegacy", as: GetThemeFunc.self),
            setTheme: resolver.resolveOptional("SLSSetAppearanceThemeLegacy", as: SetThemeFunc.self)
        )
    }()

    let getTheme: GetThemeFunc?
    let setTheme: SetThemeFunc?
}
