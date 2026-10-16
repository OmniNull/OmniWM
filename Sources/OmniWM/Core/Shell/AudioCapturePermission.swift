// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum AudioCapturePermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias Request = @convention(c) (
        CFString,
        CFDictionary?,
        @escaping @convention(block) @Sendable (Bool) -> Void
    )
        -> Void

    private static var service: CFString {
        "kTCCServiceAudioCapture" as CFString
    }

    private static let library = "/System/Library/PrivateFrameworks/TCC.framework/TCC"

    private static let preflight: Preflight? = dlopen(library, RTLD_LAZY)
        .flatMap { dlsym($0, "TCCAccessPreflight") }
        .map { unsafeBitCast($0, to: Preflight.self) }

    private static let requestAccess: Request? = dlopen(library, RTLD_LAZY)
        .flatMap { dlsym($0, "TCCAccessRequest") }
        .map { unsafeBitCast($0, to: Request.self) }

    static var status: AppVolumeAccess? {
        guard let preflight else { return nil }
        switch preflight(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    static func request(_ answered: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard let requestAccess else { return false }
        requestAccess(service, nil, answered)
        return true
    }
}
