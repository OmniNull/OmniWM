// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import OmniWMScriptHost
import XCTest

final class ConfigScriptStoreTests: XCTestCase {
    private var directory: URL!
    private static let show = "local function show(v) if type(v) == 'table' then return 'list:' .. table.concat(v, ',') "
        + "end return type(v) .. ':' .. tostring(v) end"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL {
        directory.appendingPathComponent("script-store.json")
    }

    private var contents: String? {
        (try? Data(contentsOf: fileURL)).map { String(decoding: $0, as: UTF8.self) }
    }

    private func run(_ lines: [String], store: ConfigScriptStore? = nil) async throws -> [String] {
        let source = (["omniwm.command('Run', function()"] + lines + ["end)"]).joined(separator: "\n")
        let loader = ConfigScriptLoader(store: store ?? ConfigScriptStore(fileURL: fileURL))
        let result = try await loader.evaluate(Data(source.utf8), hyperMask: 0)
        let vm = try XCTUnwrap(result.generation)
        let command = try XCTUnwrap(result.namedCommands.first)
        let invocation = try await vm.invoke(function: command.function, context: ConfigScriptContext())
        return invocation.commands.compactMap { dispatch in
            guard case let .native(.showNotice(text)) = dispatch.operation else { return nil }
            return text
        }
    }

    private func expect(
        _ lines: [String], store: ConfigScriptStore? = nil, shows expected: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let shown = try await run(lines, store: store)
        XCTAssertEqual(shown, expected, file: file, line: line)
    }

    private func refusal(_ lines: [String], store: ConfigScriptStore? = nil) async throws -> ConfigScriptError {
        do {
            _ = try await run(lines, store: store)
        } catch let error as ConfigScriptError {
            return error
        }
        XCTFail("Expected a refusal: \(lines)")
        return ConfigScriptError(line: nil, message: "")
    }

    private func line(of index: Int) -> Int {
        index + 2
    }

    func testEveryValueKindSurvivesARestartWithItsType() async throws {
        let writes = [
            "omniwm.store.set('flag', true)",
            "omniwm.store.set('off', false)",
            "omniwm.store.set('one', 1)",
            "omniwm.store.set('half', 0.5)",
            "omniwm.store.set('path', 'a/b \"c\"')",
            "omniwm.store.set('apps', { 'com.apple.Safari', 'org.mozilla.firefox' })",
            "omniwm.store.set('none', {})"
        ]
        try await expect(writes, shows: [])
        XCTAssertEqual(
            contents,
            #"{"apps":["com.apple.Safari","org.mozilla.firefox"],"flag":true,"half":0.5,"none":[],"off":false,"one":1,"#
                + #""path":"a/b \"c\""}"#
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, Int(S_IRUSR | S_IWUSR))
        let keys = ["flag", "off", "one", "half", "path", "apps", "none", "missing"]
        let shown = try await run(
            [Self.show] + keys.map { "omniwm.notify(show(omniwm.store.get('\($0)')))" },
            store: ConfigScriptStore(fileURL: fileURL)
        )
        XCTAssertEqual(shown, [
            "boolean:true", "boolean:false", "number:1", "number:0.5", "string:a/b \"c\"",
            "list:com.apple.Safari,org.mozilla.firefox", "list:", "nil:nil"
        ])
    }

    func testACallbackReadsItsOwnWritesAndAFailedCallbackSavesNothing() async throws {
        let shown = try await run([
            "omniwm.store.set('count', 1)",
            "omniwm.store.set('count', omniwm.store.get('count') + 1)",
            "omniwm.notify(tostring(omniwm.store.get('count')))"
        ])
        XCTAssertEqual(shown, ["2"])
        let failing = ["omniwm.store.set('count', 10)", "omniwm.store.clear('count')", "error('stop')"]
        let error = try await refusal(failing)
        XCTAssertEqual(error.line, line(of: failing.count - 1))
        try await expect(["omniwm.notify(tostring(omniwm.store.get('count')))"], shows: ["2"])
    }

    func testTheStoreIsRefusedWhileTheConfigLoads() async throws {
        let loader = ConfigScriptLoader(store: ConfigScriptStore(fileURL: fileURL))
        for source in ["omniwm.store.get('k')", "omniwm.store.set('k', 1)", "omniwm.store.clear()"] {
            do {
                _ = try await loader.evaluate(Data(source.utf8), hyperMask: 0)
                XCTFail("Expected \(source) to be refused")
            } catch let error as ConfigScriptError {
                XCTAssertEqual(error.line, 1)
                XCTAssertEqual(error.message, "omniwm.store is only available in a callback")
            }
        }
        XCTAssertNil(contents)
    }

    func testInvalidKeysValuesAndShapesAreRefusedAtTheirLine() async throws {
        let keyMessage = "Store keys need 1 to \(ConfigScriptStore.keyLength) letters, digits, '.', '_' or '-'."
        let longKey = String(repeating: "k", count: ConfigScriptStore.keyLength + 1)
        let listMessage = "store lists must be arrays of strings without holes"
        let valueMessage = "store values must be booleans, numbers, strings or lists of strings"
        let cases: [(String, String)] = [
            ("omniwm.store.set('bad key', 1)", keyMessage),
            ("omniwm.store.set('', 1)", keyMessage),
            ("omniwm.store.get('\(longKey)')", keyMessage),
            ("omniwm.store.set(1, 1)", "store keys must be strings"),
            ("omniwm.store.clear(nil)", "store keys must be strings"),
            ("omniwm.store.set('k')", "omniwm.store.set expects a key and a value"),
            ("omniwm.store.get()", "omniwm.store.get expects a key"),
            ("omniwm.store.clear('a', 'b')", "omniwm.store.clear expects one key, or nothing to clear every key"),
            ("omniwm.store.set('k', function() end)", valueMessage),
            ("omniwm.store.set('k', 0 / 0)", "store numbers must be finite"),
            ("omniwm.store.set('k', math.huge)", "store numbers must be finite"),
            ("omniwm.store.set('k', { 'a', nil, 'c' })", listMessage),
            ("omniwm.store.set('k', { a = 'b' })", listMessage),
            ("omniwm.store.set('k', { 1 })", listMessage),
            (
                "omniwm.store.set('k', string.rep('x', \(ConfigScriptStore.stringLimit + 1)))",
                "store strings are at most \(ConfigScriptStore.stringLimit) bytes"
            ),
            (
                "omniwm.store.set('k', table.create(\(ConfigScriptStore.listLimit + 1), 'x'))",
                "store lists hold at most \(ConfigScriptStore.listLimit) strings"
            ),
            ("omniwm.store.set('k', '\\255')", "Store text must be valid UTF-8.")
        ]
        for (statement, message) in cases {
            let lines = ["local before = 1", statement]
            let error = try await refusal(lines)
            XCTAssertEqual(error.line, line(of: lines.count - 1), statement)
            XCTAssertEqual(error.message, message, statement)
        }
        XCTAssertNil(contents)
    }

    func testWriteKeyAndTextLimitsRefuseTheCallThatCrossesThem() async throws {
        let writes = Int(OMNI_CONFIG_STORE_WRITE_LIMIT)
        let overWrites = ["local before = 1", "for i = 1, \(writes + 1) do omniwm.store.set('k', i) end"]
        let writeError = try await refusal(overWrites)
        XCTAssertEqual(writeError.line, line(of: overWrites.count - 1))
        XCTAssertEqual(writeError.message, "a callback changes the store at most \(writes) times")
        XCTAssertNil(contents)

        let store = ConfigScriptStore(fileURL: fileURL)
        for first in stride(from: 1, through: ConfigScriptStore.keyLimit, by: writes) {
            let last = min(first + writes - 1, ConfigScriptStore.keyLimit)
            try await expect(
                ["for i = \(first), \(last) do omniwm.store.set('k' .. i, true) end"],
                store: store,
                shows: []
            )
        }
        let keyError = try await refusal(["omniwm.store.set('extra', true)"], store: store)
        XCTAssertEqual(keyError.message, "The store holds at most \(ConfigScriptStore.keyLimit) keys.")
        try await expect(["omniwm.store.set('k1', false)", "omniwm.store.clear()"], store: store, shows: [])
        XCTAssertEqual(contents, "{}")

        let key = String(format: "k%02d", 0)
        let entry = ConfigScriptStore.stringLimit + key.utf8.count
        let fit = ConfigScriptStore.byteLimit / entry
        let text = "string.rep('x', \(ConfigScriptStore.stringLimit))"
        let fill = [
            "for i = 1, \(fit) do omniwm.store.set(string.format('k%02d', i), \(text)) end",
            "omniwm.store.set(string.format('k%02d', \(fit + 1)), \(text))"
        ]
        let textError = try await refusal(fill, store: store)
        XCTAssertEqual(textError.line, line(of: fill.count - 1))
        XCTAssertEqual(
            textError.message, "The store holds at most \(ConfigScriptStore.byteLimit / 1024) KiB of keys and text."
        )
        XCTAssertEqual(contents, "{}")
    }

    func testSettingNilRemovesOnlyThatKey() async throws {
        let store = ConfigScriptStore(fileURL: fileURL)
        let kept = 2
        let read = "omniwm.notify(tostring(omniwm.store.get('a')) .. ',' .. tostring(omniwm.store.get('b')))"
        try await expect(["omniwm.store.set('a', 1)", "omniwm.store.set('b', \(kept))"], store: store, shows: [])
        try await expect(
            ["omniwm.store.set('a', nil)", "omniwm.store.set('missing', nil)", read],
            store: store,
            shows: ["nil,\(kept)"]
        )
        try await expect([read], store: ConfigScriptStore(fileURL: fileURL), shows: ["nil,\(kept)"])
    }

    func testClearRemovesOneKeyOrEverything() async throws {
        let store = ConfigScriptStore(fileURL: fileURL)
        let read = "omniwm.notify(tostring(omniwm.store.get('a')) .. ',' .. tostring(omniwm.store.get('b')))"
        try await expect(["omniwm.store.set('a', 1)", "omniwm.store.set('b', 2)"], store: store, shows: [])
        try await expect(
            ["omniwm.store.clear('a')", "omniwm.store.clear('missing')", read],
            store: store,
            shows: ["nil,2"]
        )
        try await expect([read], store: ConfigScriptStore(fileURL: fileURL), shows: ["nil,2"])
        try await expect(["omniwm.store.clear()", read], store: store, shows: ["nil,nil"])
        XCTAssertEqual(contents, "{}")
    }

    func testAnUnreadableStoreIsReportedAndClearingEverythingStartsOver() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for corrupt in ["not json", #"{"bad key":1}"#, #"{"k":[1]}"#] {
            try Data(corrupt.utf8).write(to: fileURL)
            for statement in ["omniwm.store.get('k')", "omniwm.store.set('k', 1)", "omniwm.store.clear('k')"] {
                let error = try await refusal([statement])
                XCTAssertEqual(error.line, line(of: 0), statement)
                XCTAssertEqual(error.message, ConfigScriptStoreError.corrupt.message, statement)
            }
            let shown = try await run([
                "omniwm.store.clear()", "omniwm.notify(tostring(omniwm.store.get('k')))", "omniwm.store.set('k', 1)"
            ])
            XCTAssertEqual(shown, ["nil"])
            XCTAssertEqual(contents, #"{"k":1}"#)
        }
    }

    func testAFailedSaveRefusesTheCallbackAtItsFirstChangeAndKeepsTheSavedFile() async throws {
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        let store = ConfigScriptStore(fileURL: locked.appendingPathComponent("script-store.json"))
        try await expect(["omniwm.store.set('same', 0)"], store: store, shows: [])
        let saved = try Data(contentsOf: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: Int(S_IRUSR | S_IXUSR)], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: Int(S_IRWXU)], ofItemAtPath: locked.path) }
        let lines = ["omniwm.notify('kept')", "omniwm.store.set('same', 1)", "omniwm.store.set('next', 2)"]
        let error = try await refusal(lines, store: store)
        XCTAssertEqual(error.line, line(of: 1))
        XCTAssertTrue(error.message.hasPrefix(ConfigScriptStoreError.unwritable("").message), error.message)
        let read = ["omniwm.notify(tostring(omniwm.store.get('same')) .. ',' .. tostring(omniwm.store.get('next')))"]
        try await expect(read, store: store, shows: ["0,nil"])
        try await expect(read, store: ConfigScriptStore(fileURL: store.fileURL), shows: ["0,nil"])
        XCTAssertEqual(try Data(contentsOf: store.fileURL), saved)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: locked.path),
            [store.fileURL.lastPathComponent]
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: locked.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, Int(S_IRUSR | S_IXUSR))
    }

    func testAFileThatCantBeReadIsReportedByEveryCallAndNeverReplaced() async throws {
        let noAccess = 0
        let saved = Data(#"{"k":1}"#.utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try saved.write(to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: noAccess], ofItemAtPath: fileURL.path)
        let owner = [FileAttributeKey.posixPermissions: Int(S_IRUSR | S_IWUSR)]
        defer { try? FileManager.default.setAttributes(owner, ofItemAtPath: fileURL.path) }
        let statements = [
            "omniwm.store.get('k')",
            "omniwm.store.set('k', 2)",
            "omniwm.store.clear('k')",
            "omniwm.store.clear()"
        ]
        for statement in statements {
            let error = try await refusal([statement])
            XCTAssertEqual(error.line, line(of: 0), statement)
            XCTAssertTrue(error.message.hasPrefix(ConfigScriptStoreError.unreadable("").message), statement)
        }
        try FileManager.default.setAttributes(owner, ofItemAtPath: fileURL.path)
        XCTAssertEqual(try Data(contentsOf: fileURL), saved)
    }

    func testClearingAnEmptyStoreIsNotAChange() async throws {
        let locked = directory.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: Int(S_IRUSR | S_IXUSR)], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: Int(S_IRWXU)], ofItemAtPath: locked.path) }
        let store = ConfigScriptStore(fileURL: locked.appendingPathComponent("script-store.json"))
        try await expect(["omniwm.store.clear()"], store: store, shows: [])
        let lines = ["omniwm.store.clear()", "omniwm.store.set('k', 1)"]
        let error = try await refusal(lines, store: store)
        XCTAssertEqual(error.line, line(of: 1))
        XCTAssertTrue(error.message.hasPrefix(ConfigScriptStoreError.unwritable("").message), error.message)
    }

    func testValuesKeepTheirExactBytes() async throws {
        let composed = "utf8.char(0xE9)"
        let decomposed = "utf8.char(0x65, 0x301)"
        let decomposedBytes = "e\u{301}".utf8.count
        let store = ConfigScriptStore(fileURL: fileURL)
        let first = [
            "omniwm.store.set('s', \(composed))",
            "omniwm.store.set('l', { \(composed) })",
            "omniwm.store.set('n', 0)"
        ]
        try await expect(first, store: store, shows: [])
        let read = "omniwm.notify(#omniwm.store.get('s') .. ',' .. #omniwm.store.get('l')[1] .. ',' "
            + ".. tostring(1 / omniwm.store.get('n')))"
        let expected = "\(decomposedBytes),\(decomposedBytes),-inf"
        let second = [
            "omniwm.store.set('s', \(decomposed))", "omniwm.store.set('l', { \(decomposed) })",
            "omniwm.store.set('n', -0)", read
        ]
        try await expect(second, store: store, shows: [expected])
        try await expect([read], store: ConfigScriptStore(fileURL: fileURL), shows: [expected])
    }

    func testASaveMakesAnExistingSharedDirectoryPrivate() async throws {
        let shared = Int(S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: shared], ofItemAtPath: directory.path)
        try await expect(["omniwm.store.set('k', 1)"], shows: [])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, Int(S_IRWXU))
    }

    func testADirectoryInPlaceOfTheFileIsReportedAndLeftAlone() async throws {
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: true)
        let read = try await refusal(["omniwm.store.get('k')"])
        XCTAssertTrue(read.message.hasPrefix(ConfigScriptStoreError.unreadable("").message), read.message)
        let reset = try await refusal(["omniwm.store.clear()"])
        XCTAssertEqual(reset.line, line(of: 0))
        XCTAssertTrue(reset.message.hasPrefix(ConfigScriptStoreError.unreadable("").message), reset.message)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [fileURL.lastPathComponent])
    }

    func testTheSavedFileIsCappedAtItsEncodedSizeIncludingEscapes() async throws {
        let quote = UInt8(ascii: "\"")
        func encodedSize(_ elements: [String]) -> Int {
            let body = elements.reduce(0) { total, element in
                total + 2 + element.utf8.reduce(0) { $0 + ($1 == quote ? 2 : 1) }
            }
            return #"{"k":["#.utf8.count + body + elements.count - 1 + "]}".utf8.count
        }
        let full = String(repeating: "\"", count: ConfigScriptStore.stringLimit)
        var count = 0
        while encodedSize(Array(repeating: full, count: count + 1) + [""]) <= ConfigScriptStore.byteLimit {
            count += 1
        }
        let room = ConfigScriptStore.byteLimit - encodedSize(Array(repeating: full, count: count) + [""])
        let last = String(repeating: "\"", count: room / 2) + String(repeating: "a", count: room % 2)
        XCTAssertEqual(encodedSize(Array(repeating: full, count: count) + [last]), ConfigScriptStore.byteLimit)
        XCTAssertLessThanOrEqual(last.utf8.count, ConfigScriptStore.stringLimit)
        func statement(extra: Int) -> String {
            "local list = table.create(\(count), string.rep('\"', \(ConfigScriptStore.stringLimit))) "
                + "table.insert(list, string.rep('\"', \(room / 2)) .. string.rep('a', \(room % 2 + extra))) "
                + "omniwm.store.set('k', list)"
        }
        let over = try await refusal([statement(extra: 1)])
        XCTAssertEqual(over.line, line(of: 0))
        XCTAssertEqual(over.message, ConfigScriptStoreError.tooLarge.message)
        XCTAssertNil(contents)
        try await expect([statement(extra: 0)], shows: [])
        XCTAssertEqual(try Data(contentsOf: fileURL).count, ConfigScriptStore.byteLimit)
    }

    func testAReturnedListIsACopy() async throws {
        let lines = [
            "omniwm.store.set('l', { 'a' })",
            "local list = omniwm.store.get('l')",
            "table.insert(list, 'b')",
            "omniwm.notify(tostring(#omniwm.store.get('l')))"
        ]
        try await expect(lines, shows: ["1"])
        try await expect(Array(lines.dropFirst()), shows: ["1"])
        XCTAssertEqual(contents, #"{"l":["a"]}"#)
    }

    func testEventTimerAndShortcutCallbacksShareTheStore() async throws {
        let source = """
        omniwm.on('config.reloaded', function() omniwm.store.set('event', true) end)
        omniwm.timer({ afterSeconds = \(OMNI_CONFIG_TIMER_MINIMUM_SECONDS) }, function() omniwm.store.set('timer', omniwm.store.get('event') == true) end)
        omniwm.keymap.set('Control+Option+K', function() omniwm.notify(tostring(omniwm.store.get('timer'))) end)
        """
        let result = try await ConfigScriptLoader(store: ConfigScriptStore(fileURL: fileURL))
            .evaluate(Data(source.utf8), hyperMask: 0)
        let vm = try XCTUnwrap(result.generation)
        let event = try XCTUnwrap(result.events.first)
        let timer = try XCTUnwrap(result.timers.first)
        guard case let .configFunction(shortcut)? = result.bindings.first?.command else {
            return XCTFail("Expected a function shortcut")
        }
        _ = try await vm.invoke(function: event.function, event: ConfigScriptEventPayload())
        _ = try await vm.invoke(reference: timer.reference, input: .timer)
        let shown = try await vm.invoke(function: shortcut, context: ConfigScriptContext()).commands
        XCTAssertEqual(shown.map(\.operation), [.native(.showNotice("true"))])
        XCTAssertEqual(contents, #"{"event":true,"timer":true}"#)
    }

    func testACancelledCallbackSavesNothing() async throws {
        let source = "omniwm.command('Run', function() omniwm.store.set('k', 1) end)"
        let result = try await ConfigScriptLoader(store: ConfigScriptStore(fileURL: fileURL))
            .evaluate(Data(source.utf8), hyperMask: 0)
        let vm = try XCTUnwrap(result.generation)
        let function = try XCTUnwrap(result.namedCommands.first).function
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await vm.invoke(function: function, context: ConfigScriptContext())
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled callback must not run")
        } catch let error as ConfigScriptError {
            XCTAssertEqual(error.message, "This function belongs to a retired config.")
        }
        XCTAssertNil(contents)
    }

    @MainActor
    func testTheRecipeRemembersOpensAndForgetsAWorkspacesApps() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [NiriGatherFixture.monitor(displayId: 1)])
        let base = fixture.base
        let one = base.workspace("1")
        base.add([1, 2, 3, 4], to: one)
        let bundles = ["com.example.first", "com.example.second"]
        for (window, bundle) in [(1, bundles[0]), (2, bundles[1]), (3, bundles[0]), (4, nil)] {
            XCTAssertTrue(base.manager.setManagedReplacementMetadata(
                .init(bundleId: bundle, workspaceId: one, mode: .tiling, title: "window"), for: base.token(window)
            ))
        }
        let recipe = try ConfigScriptWindowFixture.recipe("Remember a workspace's apps")
        try await fixture.load(recipe)
        try await fixture.run(named: "Remember Work Apps")
        let saved = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: fixture.storeURL))
        XCTAssertEqual(saved, ["work.apps": bundles])
        XCTAssertEqual(base.controller.commandHandler.scriptNotice.text, "Remembered \(bundles.count) apps")

        let reloaded = try await ConfigScriptLoader(store: ConfigScriptStore(fileURL: fixture.storeURL))
            .evaluate(Data(recipe.utf8), hyperMask: 0)
        let open = try XCTUnwrap(reloaded.namedCommands.first { $0.name == "Open Work Apps" })
        let opened = try await XCTUnwrap(reloaded.generation).invoke(
            function: open.function,
            context: ConfigScriptContext()
        )
        XCTAssertEqual(opened.commands.map(\.operation), bundles.map { .native(.openApp($0)) })

        try await fixture.run(named: "Forget Work Apps")
        XCTAssertEqual(try String(contentsOf: fixture.storeURL, encoding: .utf8), "{}")
    }

    @MainActor
    func testASavedChangeStaysWhenALaterActionIsRefused() async throws {
        let fixture = try ConfigScriptWindowFixture(monitors: [NiriGatherFixture.monitor(displayId: 1)])
        let base = fixture.base
        base.add([1], to: base.workspace("1"))
        let session = base.controller.scriptSession.identity
        let stale = ConfigScriptWindowID.string(base.token(1), session: ConfigScriptSession(id: session.id &+ 1))
        try await fixture.load("""
        omniwm.command('Run', function()
            omniwm.store.set('k', 1)
            omniwm.dispatch('window', 'focus', '\(stale)')
        end)
        """)
        let function = try XCTUnwrap(fixture.script.acceptedCommands.first?.function)
        XCTAssertEqual(
            base.controller.commandHandler.handleHotkeyInvocation(HotkeyInvocation(command: .configFunction(function))),
            .executed
        )
        await fixture.script.callbackQueue?.waitUntilParked()
        XCTAssertNotNil(fixture.script.diagnostic)
        XCTAssertEqual(try String(contentsOf: fixture.storeURL, encoding: .utf8), #"{"k":1}"#)
    }

    @MainActor
    func testRestartingTheScriptKeepsTheControllersLoader() throws {
        let wm = WindowAdmissionTestSupport.controller()
        let settingsDirectory = wm.settings.settingsFileURL.deletingLastPathComponent()
        defer {
            wm.stopConfigScript()
            try? FileManager.default.removeItem(at: settingsDirectory.deletingLastPathComponent())
        }
        let file = settingsDirectory.appendingPathComponent(ConfigScriptController.fileName)
        wm.startConfigScript(at: file)
        let first = try XCTUnwrap(wm.configScript)
        wm.stopConfigScript()
        wm.startConfigScript(at: file)
        let second = try XCTUnwrap(wm.configScript)
        XCTAssertFalse(first === second)
        XCTAssertTrue(first.loader === wm.configScriptLoader)
        XCTAssertTrue(second.loader === wm.configScriptLoader)
    }

    func testAnUnchangedStoreIsNotRewritten() async throws {
        let store = ConfigScriptStore(fileURL: fileURL)
        try await expect(["omniwm.store.set('k', { 'a' })"], store: store, shows: [])
        let written = try XCTUnwrap(SettingsFileAccess.currentFingerprint(at: fileURL))
        let unchanged = [
            "omniwm.store.set('k', { 'a' })", "omniwm.store.set('j', 2)", "omniwm.store.clear('j')",
            "omniwm.store.clear('missing')"
        ]
        try await expect(unchanged, store: store, shows: [])
        try await expect(unchanged, store: ConfigScriptStore(fileURL: fileURL), shows: [])
        XCTAssertEqual(SettingsFileAccess.currentFingerprint(at: fileURL), written)
    }
}
