// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum AXWindowIntakeEvent: Sendable {
    case focusedWindowChanged(pid: pid_t, callbackGeneration: UInt64?)
    case windowDestroyed(pid: pid_t, axRef: AXWindowRef, callbackGeneration: UInt64?)
    case windowMiniaturized(pid: pid_t, axRef: AXWindowRef, callbackGeneration: UInt64?)
    case windowDeminiaturized(pid: pid_t, axRef: AXWindowRef, callbackGeneration: UInt64?)
    case titleChanged(pid: pid_t, windowId: UInt32, callbackGeneration: UInt64?)
}
