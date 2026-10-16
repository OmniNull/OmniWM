// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import os

struct LogChannel: Sendable {
    private static let subsystem = "com.barut.OmniWM"

    private let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    func error(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
        LogErrorTap.shared.record(category: category, level: "error", message: text)
    }

    func fault(_ message: @autoclosure () -> String) {
        let text = message()
        logger.fault("\(text, privacy: .public)")
        LogErrorTap.shared.record(category: category, level: "fault", message: text)
    }

    func notice(_ message: @autoclosure @escaping () -> String) {
        logger.notice("\(message(), privacy: .public)")
    }

    func info(_ message: @autoclosure @escaping () -> String) {
        logger.info("\(message(), privacy: .public)")
    }

    func debug(_ message: @autoclosure @escaping () -> String) {
        logger.debug("\(message(), privacy: .public)")
    }
}

enum Log {
    static let config = LogChannel(category: "config")
    static let terminal = LogChannel(category: "terminal")
    static let ax = LogChannel(category: "ax")
    static let layout = LogChannel(category: "layout")
    static let reconcile = LogChannel(category: "reconcile")
    static let ipc = LogChannel(category: "ipc")
    static let diagnostics = LogChannel(category: "diagnostics")
    static let shell = LogChannel(category: "shell")
    static let hiddenBar = LogChannel(category: "HiddenBar")
}
