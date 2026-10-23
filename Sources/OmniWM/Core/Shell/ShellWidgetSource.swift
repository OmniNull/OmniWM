// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

struct ShellWidgetSource: Sendable {
    struct Module: Sendable {
        let path: String
        let source: String
    }

    let chunk: String
    let main: String
    let modules: [Module]
    var isIslandRoot = false
    var moduleLimit = 64
    var components: [ShellComponentInstance] = []
    var componentDescriptors: [ShellComponentDescriptor] = []
    var assetPackages: [String: URL] = [:]
    var profile = ShellDefaults.profile
    var network: [String] = []
}
