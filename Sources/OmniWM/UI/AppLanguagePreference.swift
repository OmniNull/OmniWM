// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

public enum AppLanguagePreference {
    private static let key = "AppleLanguages"

    static let availableLanguages: [String] = {
        let languages = Bundle.module.localizations.filter { $0 != "Base" && $0 != "en" }
        return ["en"] + languages.sorted {
            nativeName(for: $0).localizedStandardCompare(nativeName(for: $1)) == .orderedAscending
        }
    }()

    static func nativeName(for language: String) -> String {
        Locale(identifier: language).localizedString(forIdentifier: language) ?? language
    }

    @MainActor
    public static func applyConfiguredLanguage() {
        let defaults = UserDefaults.standard
        guard let arguments = launchArguments(
            defaults.volatileDomain(forName: UserDefaults.argumentDomain),
            selecting: configuredLanguage(in: SettingsFilePersistence.fileURL)
        ) else { return }
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    @MainActor
    static func configuredLanguage(in fileURL: URL) -> String? {
        SettingsFilePersistence.launchLanguage(at: fileURL)
    }

    static func launchArguments(_ arguments: [String: Any], selecting language: String?) -> [String: Any]? {
        guard let language, arguments[key] == nil else { return nil }
        var arguments = arguments
        arguments[key] = [language]
        return arguments
    }
}
