// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

extension ShellConfigurationCoordinator {
    @discardableResult
    func selectProfile(_ name: String) async throws -> Bool {
        try await editFile(scansSources: false) { try ShellProfiles.select(name, in: $0) }
    }

    @discardableResult
    func selectTheme(_ name: String, profile: String? = nil) async throws -> Bool {
        let profile = try await explicitProfile(profile)
        return try await editFile(refreshMetadata: false, scansSources: false) {
            try ShellProfiles.selectTheme(name, profile: profile, in: $0)
        }
    }

    @discardableResult
    func selectScheme(_ scheme: ShellWallpaperScheme, profile: String? = nil) async throws -> Bool {
        let profile = try await explicitProfile(profile)
        return try await editFile(refreshMetadata: false, scansSources: false) {
            try ShellProfiles.selectScheme(scheme, profile: profile, in: $0)
        }
    }

    var profiles: [String] {
        styles.map(\.name)
    }

    func style(_ profile: String) -> ShellStyle {
        styles.first { $0.name == profile } ?? ShellStyle(name: profile)
    }

    func installStyle(_ payload: ShellStylePayload, replacing: Bool) async throws -> URL? {
        try await edit { directory in
            (true, try ShellStyleInstaller.install(payload, into: directory, replacing: replacing))
        }
    }

    func removeStyle(_ name: String) async throws -> URL {
        if config.profile == name {
            _ = try await selectProfile(ShellDefaults.profile)
        }
        return try await edit { directory in (true, try ShellStyleInstaller.remove(name, from: directory)) }
    }
}
