// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation

enum ShellIslandTitles {
    static func titles(
        components: [ShellComponentInstance], descriptors: [String: ShellComponentDescriptor],
        strings: ShellStrings = .empty
    ) -> [String: String] {
        let base = components.map {
            descriptors[$0.widget].map { strings.title($0.title) } ?? ShellBarLayout.title(of: $0.widget)
        }
        var ordinals: [String: Int] = [:]
        let labelled = zip(components, base).map { component, title in
            ordinals[title, default: 0] += 1
            guard base.count(where: { $0 == title }) > 1 else { return title }
            if let label = label(of: component, in: descriptors) {
                return String(localized: "\(title) · \(label)")
            }
            return String(localized: "\(title) \(ordinals[title, default: 1])")
        }
        var seen: [String: Int] = [:]
        var titles: [String: String] = [:]
        for (component, title) in zip(components, labelled) {
            guard labelled.count(where: { $0 == title }) > 1 else {
                titles[component.id] = title
                continue
            }
            seen[title, default: 0] += 1
            titles[component.id] = String(localized: "\(title) \(seen[title, default: 1])")
        }
        return titles
    }

    private static func label(
        of component: ShellComponentInstance, in descriptors: [String: ShellComponentDescriptor]
    ) -> String? {
        guard let option = descriptors[component.widget]?.options["label"], option.kind == .string,
              case let .string(text)? = component.options["label"] ?? option.defaultValue
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
