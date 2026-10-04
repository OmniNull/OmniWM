// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation

enum WindowStructuralEligibility {
    case eligible
    case requiresExplicitInclusion
    case requiresExplicitUserInclusion
    case requiresIndependentRootInclusion
    case external
    case deferred(WindowDecisionDeferredReason)
}

@MainActor
struct WindowEligibilityPolicy {
    private static let nativeFullscreenSubrole = "AXFullScreenWindow"
    private static let systemSurfaceLevelFloor = CGWindowLevelForKey(.statusWindow)
    private static let mozillaPictureInPictureTitleRegex = compilePictureInPictureTitle("^Picture-in-Picture$")
    private static let chromiumPictureInPictureTitleRegex = compilePictureInPictureTitle("^Picture-in-picture$")
    private static let edgePictureInPictureTitleRegex = compilePictureInPictureTitle("^Picture in Picture$")

    let hiddenTitleBarFullscreenButtonOptionalBundleIds: Set<String>
    let hiddenTitleBarNonStandardSubroleBundleIds: Set<String>
    let inputMethodBundleIds: Set<String>

    func isExternalSurface(_ facts: WindowRuleFacts) -> Bool {
        if facts.ax.role == (kAXHelpTagRole as String) {
            return true
        }
        if let bundleId = facts.ax.bundleId?.lowercased(), inputMethodBundleIds.contains(bundleId) {
            return true
        }
        if facts.ax.attributeFetchSucceeded,
           facts.ax.role == (kAXWindowRole as String),
           let titleRegex = Self.pictureInPictureTitleRegex(for: facts.ax.bundleId),
           let title = facts.ax.title,
           titleRegex.firstMatch(
               in: title,
               range: NSRange(title.startIndex..., in: title)
           ) != nil
        {
            return true
        }
        return false
    }

    func requiresPictureInPictureTitle(for bundleId: String?) -> Bool {
        Self.pictureInPictureTitleRegex(for: bundleId) != nil
    }

    private static func pictureInPictureTitleRegex(for bundleId: String?) -> NSRegularExpression? {
        switch bundleId?.lowercased() {
        case "org.mozilla.firefox",
             "app.zen-browser.zen",
             "net.librewolf.librewolf": mozillaPictureInPictureTitleRegex
        case "com.google.chrome",
             "com.brave.browser": chromiumPictureInPictureTitleRegex
        case "com.microsoft.edgemac": edgePictureInPictureTitleRegex
        default: nil
        }
    }

    private static func compilePictureInPictureTitle(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("Invalid built-in Picture-in-Picture pattern: \(error)")
        }
    }

    func acceptsHiddenTitleBar(_ facts: WindowRuleFacts) -> Bool {
        HiddenTitleBarRegistry.decision(
            for: facts.ax,
            windowServer: facts.windowServer,
            fullscreenButtonOptionalBundleIds: hiddenTitleBarFullscreenButtonOptionalBundleIds,
            nonStandardSubroleBundleIds: hiddenTitleBarNonStandardSubroleBundleIds
        )
    }

    func eligibility(
        for facts: WindowRuleFacts,
        token: WindowToken?,
        appFullscreen: Bool
    ) -> WindowStructuralEligibility {
        guard facts.ax.attributeFetchSucceeded else {
            return .deferred(.attributeFetchFailed)
        }

        guard let role = facts.ax.role,
              let subrole = facts.ax.subrole
        else {
            return .deferred(.attributeFetchFailed)
        }

        let windowServerEvidence: WindowServerInfo?
        if let token {
            guard let windowServer = facts.windowServer,
                  let windowId = UInt32(exactly: token.windowId),
                  windowServer.id == windowId,
                  pid_t(windowServer.pid) == token.pid
            else {
                return .deferred(.windowServerEvidenceMissing)
            }
            windowServerEvidence = windowServer
        } else {
            windowServerEvidence = facts.windowServer
        }

        if let windowServer = windowServerEvidence,
           windowServer.parentId != 0,
           windowServer.parentId != windowServer.id
        {
            return .external
        }

        if let windowServer = windowServerEvidence,
           windowServer.level >= Self.systemSurfaceLevelFloor
        {
            return .requiresExplicitUserInclusion
        }

        if facts.ax.appPolicy == .prohibited
            || (facts.ax.appPolicy == .accessory && !facts.ax.hasCloseButton)
        {
            return .requiresExplicitInclusion
        }

        guard role == (kAXWindowRole as String) else {
            return .requiresExplicitInclusion
        }

        if appFullscreen || Self.automaticRootSubroles.contains(subrole) {
            return .eligible
        }

        if Self.independentRootSubroles.contains(subrole) {
            return independentRootEligibility(for: facts)
        }

        return .requiresExplicitInclusion
    }

    private func independentRootEligibility(for facts: WindowRuleFacts) -> WindowStructuralEligibility {
        if acceptsHiddenTitleBar(facts) {
            return .eligible
        }

        let hasWindowChrome = facts.ax.hasCloseButton
            || facts.ax.hasFullscreenButton
            || facts.ax.hasZoomButton
            || facts.ax.hasMinimizeButton
        if hasWindowChrome || facts.ax.isMain == true || facts.ax.isModal == true {
            return .eligible
        }
        if facts.ax.isMain == nil || facts.ax.isModal == nil {
            return .deferred(.independentRootEvidenceMissing)
        }
        return .requiresIndependentRootInclusion
    }

    private static let automaticRootSubroles: Set<String> = [
        kAXStandardWindowSubrole as String,
        nativeFullscreenSubrole
    ]

    private static let independentRootSubroles: Set<String> = [
        kAXDialogSubrole as String,
        kAXFloatingWindowSubrole as String
    ]
}
