// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import AppKit
@testable import OmniWM
import SwiftUI
import XCTest

#if OMNIWM_LIVE_CHECKS

    @MainActor
    extension SettingsUIRenderTests {
        func testWelcomeWindowFitsItsMinimumSizeInLightAndDark() async throws {
            try requireNativeRendering()
            let fixture = try Fixture()
            try await fixture.prepare()
            do {
                fixture.settings.hotkeyBindings = HotkeyBindingRegistry.defaults()
                for dark in [false, true] {
                    let windowClass = WindowClass(size: WelcomeView.minimumSize, dark: dark)
                    try await render(
                        WelcomeView(
                            settings: fixture.settings,
                            reason: .firstRun,
                            onOpenSettings: { _ in },
                            onDone: {}
                        ),
                        fixture: fixture, windowClass: windowClass,
                        name: "welcome-\(windowClass.suffix)",
                        requiredText: [
                            String(localized: "Welcome to OmniWM"),
                            String(localized: "Bar Menus"),
                            String(localized: "Command Palette"),
                            String(localized: "Quake Terminal"),
                            String(localized: "Widget Permissions"),
                            String(localized: "Learn More"),
                            String(localized: "Network & Permissions…"),
                            String(
                                localized: "Open this window again from the OmniWM menu: Help & Links > Welcome to OmniWM."
                            ),
                            String(localized: "Choose a Style…"),
                            String(localized: "Get Started")
                        ]
                    )
                }
            } catch {
                await fixture.close()
                throw error
            }
            await fixture.close()
        }
    }
#endif
