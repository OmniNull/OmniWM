// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import XCTest

final class ShellMetadataConsumerTests: XCTestCase {
    func testGalleryFormPermissionAndTranslationReadersRejectCalculatedValuesAtTheirSource() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let strings = directory.appendingPathComponent(ShellStrings.folder)
        try FileManager.default.createDirectory(at: strings, withIntermediateDirectories: true)
        let locale = ShellStrings.fallbackLocalization
        let widget = "clock"
        let folder = directory.appendingPathComponent(widget)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("return {}".utf8).write(to: folder.appendingPathComponent("component.luau"))

        func rejected(_ file: String, _ operation: () throws -> Void) {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual((error as? ShellScriptFailure)?.kind, .compile)
                XCTAssertTrue(error.localizedDescription.hasPrefix("\(file):2:"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("literal"), error.localizedDescription)
            }
        }

        let manifest = Data("return {\n title = 'Cl' .. 'ock', views = { 'bar' } }".utf8)
        try manifest.write(to: folder.appendingPathComponent(ShellComponentCatalog.manifestName))
        rejected("\(widget)/\(ShellComponentCatalog.manifestName)") {
            _ = try ShellComponentCatalog.load(widget, folder: folder)
        }
        let form = Data("return {\n capabilities = { network = { 'example' .. '.com' } } }".utf8)
        try form.write(to: folder.appendingPathComponent(ShellRootSettings.fileName))
        rejected("\(widget)/\(ShellRootSettings.fileName)") { _ = try ShellRootSettings.load(widget, folder: folder) }

        let style = Data("return {\n title = 'Cl' .. 'ock' }".utf8)
        try style.write(to: directory.appendingPathComponent(ShellStyleManifest.fileName))
        rejected(ShellStyleManifest.fileName) { _ = try ShellStyleManifest.parse(style) }
        rejected(ShellStyleManifest.fileName) { _ = try ShellStyleManifest.load(in: directory) }

        let languageFile = strings.appendingPathComponent("\(locale).luau")
        try Data("return {\n Clock = 'Cl' .. 'ock' }".utf8).write(to: languageFile)
        rejected("\(ShellStrings.folder)/\(languageFile.lastPathComponent)") {
            _ = try ShellStrings.load([directory], localization: locale)
        }
    }
}
