// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

@MainActor @Observable
final class AppRulesEditorState {
    @ObservationIgnored var isDirty = false
    var requestedDraft: AppRuleDraft?
}
