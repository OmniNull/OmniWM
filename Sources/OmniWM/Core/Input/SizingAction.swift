// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

enum SizingAction: Equatable, Hashable {
    case cycleSizeForward
    case cycleSizeBackward
    case cycleWindowPrimarySpanForward
    case cycleWindowPrimarySpanBackward
    case cycleWindowSecondarySpanForward
    case cycleWindowSecondarySpanBackward
    case toggleContainerFullPrimarySpan
    case expandContainerToAvailablePrimarySpan
    case resetWindowSecondarySpan
    case resizeContainerPrimarySpan(grow: Bool)
    case resizeWindowPrimarySpan(grow: Bool)
    case resizeWindowSecondarySpan(grow: Bool)
    case setContainerPrimarySpan(NiriSizeChange)
    case setWindowPrimarySpan(NiriSizeChange)
    case setWindowSecondarySpan(NiriSizeChange)
    case balanceSizes
    case undoResize
}

extension SizingAction {
    func actionDisplayName() -> LocalizedStringResource {
        switch self {
        case .cycleSizeForward: LocalizedStringResource(
                "command.sizing.cycleForward", defaultValue: "Cycle Size Forward", table: "Commands", bundle: .omniWM
            )
        case .cycleSizeBackward: LocalizedStringResource(
                "command.sizing.cycleBackward", defaultValue: "Cycle Size Backward", table: "Commands", bundle: .omniWM
            )
        case .cycleWindowPrimarySpanForward: LocalizedStringResource(
                "command.sizing.cycleWindowPrimaryForward", defaultValue: "Cycle Window Primary Span Forward",
                table: "Commands", bundle: .omniWM
            )
        case .cycleWindowPrimarySpanBackward: LocalizedStringResource(
                "command.sizing.cycleWindowPrimaryBackward", defaultValue: "Cycle Window Primary Span Backward",
                table: "Commands", bundle: .omniWM
            )
        case .cycleWindowSecondarySpanForward: LocalizedStringResource(
                "command.sizing.cycleWindowSecondaryForward", defaultValue: "Cycle Window Secondary Span Forward",
                table: "Commands", bundle: .omniWM
            )
        case .cycleWindowSecondarySpanBackward: LocalizedStringResource(
                "command.sizing.cycleWindowSecondaryBackward", defaultValue: "Cycle Window Secondary Span Backward",
                table: "Commands", bundle: .omniWM
            )
        case .balanceSizes: LocalizedStringResource(
                "command.sizing.balance", defaultValue: "Balance Sizes", table: "Commands", bundle: .omniWM
            )
        case .undoResize: LocalizedStringResource(
                "command.sizing.undoResize", defaultValue: "Undo Resize", table: "Commands", bundle: .omniWM
            )
        case .toggleContainerFullPrimarySpan,
             .expandContainerToAvailablePrimarySpan,
             .resetWindowSecondarySpan,
             .resizeContainerPrimarySpan,
             .resizeWindowPrimarySpan,
             .resizeWindowSecondarySpan,
             .setContainerPrimarySpan,
             .setWindowPrimarySpan,
             .setWindowSecondarySpan:
            spanTitle()
        }
    }

    private func spanTitle() -> LocalizedStringResource {
        switch self {
        case .toggleContainerFullPrimarySpan: LocalizedStringResource(
                "command.sizing.toggleContainerFullPrimary", defaultValue: "Toggle Container Full Primary Span",
                table: "Commands", bundle: .omniWM
            )
        case .expandContainerToAvailablePrimarySpan: LocalizedStringResource(
                "command.sizing.expandContainerPrimary", defaultValue: "Expand Container to Available Primary Span",
                table: "Commands", bundle: .omniWM
            )
        case .resetWindowSecondarySpan: LocalizedStringResource(
                "command.sizing.resetWindowSecondary", defaultValue: "Reset Window Secondary Span", table: "Commands",
                bundle: .omniWM
            )
        case .setContainerPrimarySpan: LocalizedStringResource(
                "command.sizing.setContainerPrimarySpan",
                defaultValue: "Set Container Primary Span", table: "Commands",
                bundle: .omniWM
            )
        case .setWindowPrimarySpan: LocalizedStringResource(
                "command.sizing.setWindowPrimarySpan",
                defaultValue: "Set Window Primary Span", table: "Commands",
                bundle: .omniWM
            )
        case .setWindowSecondarySpan: LocalizedStringResource(
                "command.sizing.setWindowSecondarySpan",
                defaultValue: "Set Window Secondary Span", table: "Commands",
                bundle: .omniWM
            )
        case .resizeContainerPrimarySpan,
             .resizeWindowPrimarySpan,
             .resizeWindowSecondarySpan:
            resizeTitle()
        case .cycleSizeForward,
             .cycleSizeBackward,
             .cycleWindowPrimarySpanForward,
             .cycleWindowPrimarySpanBackward,
             .cycleWindowSecondarySpanForward,
             .cycleWindowSecondarySpanBackward,
             .balanceSizes,
             .undoResize:
            actionDisplayName()
        }
    }

    private func resizeTitle() -> LocalizedStringResource {
        switch self {
        case .resizeContainerPrimarySpan(grow: true): LocalizedStringResource(
                "command.sizing.growContainerPrimary", defaultValue: "Grow Container Primary Span",
                table: "Commands", bundle: .omniWM
            )
        case .resizeContainerPrimarySpan(grow: false): LocalizedStringResource(
                "command.sizing.shrinkContainerPrimary", defaultValue: "Shrink Container Primary Span",
                table: "Commands", bundle: .omniWM
            )
        case .resizeWindowPrimarySpan(grow: true): LocalizedStringResource(
                "command.sizing.growWindowPrimary", defaultValue: "Grow Window Primary Span",
                table: "Commands", bundle: .omniWM
            )
        case .resizeWindowPrimarySpan(grow: false): LocalizedStringResource(
                "command.sizing.shrinkWindowPrimary", defaultValue: "Shrink Window Primary Span",
                table: "Commands", bundle: .omniWM
            )
        case .resizeWindowSecondarySpan(grow: true): LocalizedStringResource(
                "command.sizing.growWindowSecondary", defaultValue: "Grow Window Secondary Span",
                table: "Commands", bundle: .omniWM
            )
        case .resizeWindowSecondarySpan(grow: false): LocalizedStringResource(
                "command.sizing.shrinkWindowSecondary", defaultValue: "Shrink Window Secondary Span",
                table: "Commands", bundle: .omniWM
            )
        case .cycleSizeForward,
             .cycleSizeBackward,
             .cycleWindowPrimarySpanForward,
             .cycleWindowPrimarySpanBackward,
             .cycleWindowSecondarySpanForward,
             .cycleWindowSecondarySpanBackward,
             .toggleContainerFullPrimarySpan,
             .expandContainerToAvailablePrimarySpan,
             .resetWindowSecondarySpan,
             .setContainerPrimarySpan,
             .setWindowPrimarySpan,
             .setWindowSecondarySpan,
             .balanceSizes,
             .undoResize:
            spanTitle()
        }
    }

    func ipcCommandName() -> IPCCommandName? {
        switch self {
        case .resizeContainerPrimarySpan,
             .resizeWindowPrimarySpan,
             .resizeWindowSecondarySpan,
             .undoResize:
            nil
        case .cycleSizeForward:
            .sizing(.cycleSizeForward)
        case .cycleSizeBackward:
            .sizing(.cycleSizeBackward)
        case .cycleWindowPrimarySpanForward:
            .sizing(.cycleWindowPrimarySpanForward)
        case .cycleWindowPrimarySpanBackward:
            .sizing(.cycleWindowPrimarySpanBackward)
        case .cycleWindowSecondarySpanForward:
            .sizing(.cycleWindowSecondarySpanForward)
        case .cycleWindowSecondarySpanBackward:
            .sizing(.cycleWindowSecondarySpanBackward)
        case .toggleContainerFullPrimarySpan:
            .sizing(.toggleContainerFullPrimarySpan)
        case .expandContainerToAvailablePrimarySpan:
            .sizing(.expandContainerToAvailablePrimarySpan)
        case .resetWindowSecondarySpan:
            .sizing(.resetWindowSecondarySpan)
        case .setContainerPrimarySpan:
            .sizing(.setContainerPrimarySpan)
        case .setWindowPrimarySpan:
            .sizing(.setWindowPrimarySpan)
        case .setWindowSecondarySpan:
            .sizing(.setWindowSecondarySpan)
        case .balanceSizes:
            .dwindle(.balanceSizes)
        }
    }

    var compatibility: LayoutCompatibility {
        switch self {
        case .cycleSizeForward,
             .cycleSizeBackward,
             .balanceSizes:
            .shared
        case .cycleWindowPrimarySpanForward,
             .cycleWindowPrimarySpanBackward,
             .cycleWindowSecondarySpanForward,
             .cycleWindowSecondarySpanBackward,
             .toggleContainerFullPrimarySpan,
             .expandContainerToAvailablePrimarySpan,
             .resetWindowSecondarySpan,
             .resizeContainerPrimarySpan,
             .resizeWindowPrimarySpan,
             .resizeWindowSecondarySpan,
             .setContainerPrimarySpan,
             .setWindowPrimarySpan,
             .setWindowSecondarySpan,
             .undoResize:
            .niri
        }
    }
}
