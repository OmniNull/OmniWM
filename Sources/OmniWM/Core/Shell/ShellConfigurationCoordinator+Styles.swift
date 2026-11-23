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

    func explicitProfile(_ profile: String?) async throws -> String? {
        guard let profile else { return nil }
        try await ensureLoaded()
        guard profiles.contains(profile) else { throw CocoaError(.fileNoSuchFile) }
        return profile
    }

    func editFile(
        refreshMetadata: Bool = true,
        scansSources: Bool = true,
        _ operation: @escaping @Sendable (URL) throws -> Bool
    ) async throws -> Bool {
        try await edit(refreshMetadata: refreshMetadata, scansSources: scansSources) { directory in
            let changed = try operation(directory)
            return (changed, changed)
        }
    }

    func editPriority(profile: String? = nil, _ change: @escaping @Sendable (ShellConfig) -> [String]?) async throws {
        let profile = try await explicitProfile(profile)
        _ = try await editFile(refreshMetadata: false, scansSources: false) {
            try ShellBarLayout.editPriority(profile: profile, in: $0, change)
        }
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
