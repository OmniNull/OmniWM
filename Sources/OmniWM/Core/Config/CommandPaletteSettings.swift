// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import Observation

extension SettingsExport {
    struct CommandPalette: Codable, Equatable {
        static let defaultSearchedModes: [CommandPaletteMode] = [.windows, .applications, .commands, .files]

        var unifiedSearch = false
        var searchedModes = CommandPalette.defaultSearchedModes
        var openExpanded = false
    }
}

extension SettingsExport.CommandPalette {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        unifiedSearch = try container.decodeIfPresent(Bool.self, forKey: .unifiedSearch) ?? false
        if let names = try container.decodeIfPresent([String].self, forKey: .searchedModes) {
            searchedModes = Self.firstOccurrenceOfEachMode(names.compactMap(CommandPaletteMode.init(rawValue:)))
        } else {
            searchedModes = Self.defaultSearchedModes
        }
        openExpanded = try container.decodeIfPresent(Bool.self, forKey: .openExpanded) ?? false
    }

    static func firstOccurrenceOfEachMode(_ modes: [CommandPaletteMode]) -> [CommandPaletteMode] {
        var seen = Set<CommandPaletteMode>()
        return modes.filter { seen.insert($0).inserted }
    }
}

@MainActor @Observable
final class CommandPaletteSettings {
    private nonisolated static let defaults = SettingsExport.CommandPalette()
    @ObservationIgnored var onChange: (() -> Void)?

    var unifiedSearch = CommandPaletteSettings.defaults.unifiedSearch {
        didSet { onChange?() }
    }

    var searchedModes = CommandPaletteSettings.defaults.searchedModes {
        didSet { onChange?() }
    }

    var openExpanded = CommandPaletteSettings.defaults.openExpanded {
        didSet { onChange?() }
    }

    func export() -> SettingsExport.CommandPalette {
        SettingsExport.CommandPalette(
            unifiedSearch: unifiedSearch,
            searchedModes: searchedModes,
            openExpanded: openExpanded
        )
    }

    func apply(_ values: SettingsExport.CommandPalette) {
        unifiedSearch = values.unifiedSearch
        searchedModes = SettingsExport.CommandPalette.firstOccurrenceOfEachMode(values.searchedModes)
        openExpanded = values.openExpanded
    }

    func setMode(_ mode: CommandPaletteMode, searched: Bool) {
        if searched {
            guard !searchedModes.contains(mode) else { return }
            searchedModes.append(mode)
        } else {
            searchedModes.removeAll { $0 == mode }
        }
    }

    func moveSearchedMode(_ mode: CommandPaletteMode, by offset: Int) {
        guard let index = searchedModes.firstIndex(of: mode), searchedModes.indices.contains(index + offset) else {
            return
        }
        searchedModes.swapAt(index, index + offset)
    }

    @discardableResult
    func moveSearchedMode(_ mode: CommandPaletteMode, toPositionOf target: CommandPaletteMode) -> Bool {
        guard mode != target,
              let source = searchedModes.firstIndex(of: mode),
              let destination = searchedModes.firstIndex(of: target)
        else {
            return false
        }
        var modes = searchedModes
        modes.remove(at: source)
        modes.insert(mode, at: destination)
        searchedModes = modes
        return true
    }
}

extension SettingsExport.CommandPalette: SettingsWireNames {
    static var settingsWireNames: [String: [String]] {
        [CodingKeys.searchedModes.stringValue: CommandPaletteMode.allCases.map(\.rawValue)]
    }
}
