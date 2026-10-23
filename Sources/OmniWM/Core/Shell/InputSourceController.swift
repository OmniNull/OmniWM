// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon

enum ShellInputSourceCommand: Equatable, Sendable {
    case select(id: String)

    init?(words: [String]) {
        guard words.count == 2, words[0] == "select" else { return nil }
        self = .select(id: words[1])
    }
}

struct ShellInputSourceEntry: Equatable, Sendable {
    let id: String
    let name: String
    let short: String
}

struct ShellInputSource: Equatable, Sendable, ShellValueWritable {
    let current: ShellInputSourceEntry
    let sources: [ShellInputSourceEntry]

    func write(into writer: inout ShellValueWriter) {
        writer.map(4)
        writer.key("id")
        writer.string(current.id)
        writer.key("name")
        writer.string(current.name)
        writer.key("short")
        writer.string(current.short)
        writer.key("sources")
        writer.array(sources.count)
        for source in sources {
            writer.map(3)
            writer.key("id")
            writer.string(source.id)
            writer.key("name")
            writer.string(source.name)
            writer.key("short")
            writer.string(source.short)
        }
    }

    static func shortNames(_ sources: [(name: String, language: String?)]) -> [String] {
        let languages = sources.map { $0.language?.split(separator: "-").first.map { String($0).uppercased() } }
        return zip(sources, languages).map { source, language in
            if let language, languages.count(where: { $0 == language }) == 1 {
                return language
            }
            return String(source.name.filter(\.isLetter).prefix(3)).uppercased()
        }
    }
}

@MainActor
final class InputSourceController: ShellDeviceSource {
    private(set) var value: ShellInputSource?
    var onChange: ((ShellInputSource?) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    func setListening(_ listening: Bool) {
        guard listening == observers.isEmpty else { return }
        let center = DistributedNotificationCenter.default()
        guard listening else {
            observers.forEach(center.removeObserver)
            observers = []
            value = nil
            return
        }
        observers = [kTISNotifySelectedKeyboardInputSourceChanged, kTISNotifyEnabledKeyboardInputSourcesChanged]
            .map { name in
                center
                    .addObserver(
                        forName: Notification.Name(name as String),
                        object: nil,
                        queue: .main
                    ) { [weak self] _ in
                        // Inside the handler the current source can still be the previous one (#961).
                        Task { @MainActor in
                            self?.refresh()
                        }
                    }
            }
        refresh()
    }

    func perform(_ command: ShellInputSourceCommand) {
        switch command {
        case let .select(id):
            guard let source = Self.enabled().first(where: { Self.string($0, kTISPropertyInputSourceID) == id }) else {
                return
            }
            TISSelectInputSource(source)
        }
    }

    private func refresh() {
        guard !observers.isEmpty else { return }
        let next = Self.read()
        guard next != value else { return }
        value = next
        onChange?(next)
    }

    private static func read() -> ShellInputSource? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let currentID = string(current, kTISPropertyInputSourceID)
        else {
            return nil
        }
        var sources = enabled()
        if !sources.contains(where: { string($0, kTISPropertyInputSourceID) == currentID }) {
            sources.append(current)
        }
        let described = sources.compactMap { source in
            string(source, kTISPropertyInputSourceID).map {
                (id: $0, name: string(source, kTISPropertyLocalizedName) ?? $0, language: language(source))
            }
        }
        let shorts = ShellInputSource.shortNames(described.map { (name: $0.name, language: $0.language) })
        let entries = zip(described, shorts).map { ShellInputSourceEntry(id: $0.id, name: $0.name, short: $1) }
        guard let selected = entries.first(where: { $0.id == currentID }) else { return nil }
        return ShellInputSource(current: selected, sources: entries)
    }

    private static func enabled() -> [TISInputSource] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ] as CFDictionary
        return TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
    }

    private static func string(_ source: TISInputSource, _ key: CFString) -> String? {
        TISGetInputSourceProperty(source, key)
            .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    private static func language(_ source: TISInputSource) -> String? {
        TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages).flatMap {
            (Unmanaged<CFArray>.fromOpaque($0).takeUnretainedValue() as? [String])?.first
        }
    }
}
