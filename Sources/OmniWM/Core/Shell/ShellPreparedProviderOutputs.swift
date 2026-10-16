// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

struct ShellPreparedProviderOutputs: Equatable, Sendable {
    let files: [ShellResourceOutput]
    let descriptors: [ShellPickedResource]
}
