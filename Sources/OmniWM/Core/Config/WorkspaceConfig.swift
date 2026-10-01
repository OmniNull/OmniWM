// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum LayoutType: String, Codable, CaseIterable, Identifiable {
    case defaultLayout = "default"
    case niri
    case dwindle

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .defaultLayout: "Default"
        case .niri: "Niri (Scrolling)"
        case .dwindle: "Dwindle (BSP)"
        }
    }
}

enum MonitorAssignment: Equatable, Hashable {
    case main
    case secondary
    case tertiary
    case specificDisplay(OutputId)

    var displayName: String {
        switch self {
        case .main: "Main"
        case .secondary: "Secondary"
        case .tertiary: "Tertiary"
        case let .specificDisplay(output): output.name
        }
    }

    func toMonitorDescription() -> MonitorDescription {
        switch self {
        case .main: return .main
        case .secondary: return .secondary
        case .tertiary: return .tertiary
        case let .specificDisplay(output): return .output(output)
        }
    }
}

extension MonitorAssignment: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, output
    }

    private enum AssignmentType: String, Codable {
        case main, secondary, tertiary, specificDisplay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(AssignmentType.self, forKey: .type)
        switch type {
        case .main: self = .main
        case .secondary: self = .secondary
        case .tertiary: self = .tertiary
        case .specificDisplay:
            let output = try container.decode(OutputId.self, forKey: .output)
            self = .specificDisplay(output)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .main:
            try container.encode(AssignmentType.main, forKey: .type)
        case .secondary:
            try container.encode(AssignmentType.secondary, forKey: .type)
        case .tertiary:
            try container.encode(AssignmentType.tertiary, forKey: .type)
        case let .specificDisplay(output):
            try container.encode(AssignmentType.specificDisplay, forKey: .type)
            try container.encode(output, forKey: .output)
        }
    }
}

struct WorkspaceConfiguration: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var displayName: String?
    var monitorAssignment: MonitorAssignment
    var layoutType: LayoutType
    var accordion: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, displayName, monitorAssignment, layoutType, accordion
    }

    var effectiveDisplayName: String {
        displayName.flatMap { $0.isEmpty ? nil : $0 } ?? name
    }

    init(
        id: UUID = UUID(),
        name: String,
        displayName: String? = nil,
        monitorAssignment: MonitorAssignment = .main,
        layoutType: LayoutType = .defaultLayout,
        accordion: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.monitorAssignment = monitorAssignment
        self.layoutType = layoutType
        self.accordion = accordion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        monitorAssignment = try container.decode(MonitorAssignment.self, forKey: .monitorAssignment)
        layoutType = try container.decode(LayoutType.self, forKey: .layoutType)
        accordion = try container.decodeIfPresent(Bool.self, forKey: .accordion) ?? false
    }

    func with(layoutType: LayoutType) -> WorkspaceConfiguration {
        var copy = self
        copy.layoutType = layoutType
        return copy
    }

    func with(accordion: Bool) -> WorkspaceConfiguration {
        var copy = self
        copy.accordion = accordion
        return copy
    }

    var sortOrder: Int {
        WorkspaceIDPolicy.workspaceNumber(from: name) ?? .max
    }
}
