// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

struct ManagedWindowIdentityRebind {
    let oldWindow: AXManagedWindowIdentity
    let newWindow: AXManagedWindowIdentity
    let managedReplacementMetadata: ManagedReplacementMetadata?
    let admissionHints: ManagedWindowAdmissionHints?
    let sizeConstraints: WindowSizeConstraints?
    var minimizedAttribute: Bool?
}
