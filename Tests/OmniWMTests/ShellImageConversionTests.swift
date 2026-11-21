// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 OmniNull — https://github.com/OmniNull/OmniWM

import CoreGraphics
import Foundation
import ImageIO
@testable import OmniWM
import Synchronization
import UniformTypeIdentifiers
import XCTest

@MainActor
final class ShellImageConversionTests: XCTestCase {
    private struct Image {
        let name: String
        let width: Int
        let height: Int
    }

    private struct Progress: Equatable {
        let completed: Int
        let total: Int
    }

    private struct Output {
        let format: ShellImageConversionFormat
        let type: UTType
        let suffix: String
    }

    private let owner = ShellServiceOwner(generation: 19, owner: 3, epoch: 2)
    private let images = [
        Image(name: "../outside/first ; image.png", width: 3, height: 2),
        Image(name: "first ; image.png", width: 4, height: 3)
    ]

    func testFormatsProduceOwnedImageCopiesInInputOrder() async throws {
        let outputs = [
            Output(format: .png, type: .png, suffix: "png"),
            Output(format: .jpeg, type: .jpeg, suffix: "jpg"),
            Output(format: .tiff, type: .tiff, suffix: "tiff")
        ]
        for output in outputs {
            let (store, directory) = try await fixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let inputs = try await admitImages(images, in: store)
            let operation = ShellResourceOperation()
            let (key, action) = try await prepare(inputs, in: store, operation: operation)
            let progress = Mutex<[Progress]>([])
            let result = try await store.convertImages(key, format: output.format) { completed, total in
                XCTAssertFalse(Thread.isMainThread)
                progress.withLock { $0.append(Progress(completed: completed, total: total)) }
            }
            XCTAssertEqual(result.files.count, images.count)
            XCTAssertEqual(result.descriptors.count, images.count)
            XCTAssertEqual(Set(result.files.map(\.path)).count, images.count)
            XCTAssertEqual(progress.withLock { $0 }, (0 ... images.count).map {
                Progress(completed: $0, total: images.count)
            })
            for (index, file) in result.files.enumerated() {
                XCTAssertEqual(file.path, (file.path as NSString).lastPathComponent)
                XCTAssertEqual((file.path as NSString).pathExtension, output.suffix)
                XCTAssertEqual(file.name, file.path)
                XCTAssertEqual(result.descriptors[index].name, file.name)
                XCTAssertEqual(result.descriptors[index].uti, output.type.identifier)
                try assertImage(
                    action.outputDirectory.appendingPathComponent(file.path),
                    type: output.type,
                    image: images[index]
                )
            }
            do {
                _ = try await store.convertImages(key, format: output.format) { _, _ in
                    XCTFail("completed action converted again")
                }
                XCTFail("completed conversion action was reused")
            } catch let failure as ShellResourceFailure {
                XCTAssertEqual(failure, ShellResourceFailure("invalid_conversion"))
            }
            try await assertOwnedCopies(result, key: key, action: action, store: store, type: output.type)
        }
    }

    func testCancellationAfterFirstImageStopsBatchAndPreventsImport() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = try await admitImages(images, in: store)
        let operation = ShellResourceOperation()
        let (key, action) = try await prepare(inputs, in: store, operation: operation)
        let progress = Mutex<[Progress]>([])
        let produced = Mutex<[URL]>([])
        do {
            _ = try await store.convertImages(key, format: .png) { completed, total in
                progress.withLock { $0.append(Progress(completed: completed, total: total)) }
                if completed == 1 {
                    produced.withLock { $0 = (try? FileManager.default.contentsOfDirectory(
                        at: action.outputDirectory, includingPropertiesForKeys: nil
                    )) ?? [] }
                    operation.cancel()
                }
            }
            XCTFail("cancelled image batch completed")
        } catch let failure as ShellResourceFailure {
            XCTAssertEqual(failure, ShellResourceFailure("cancelled"))
        } catch {
            XCTFail("unexpected conversion error: \(error)")
        }
        XCTAssertEqual(progress.withLock { $0 }, (0 ... 1).map { Progress(completed: $0, total: images.count) })
        XCTAssertEqual(produced.withLock { $0.count }, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: action.outputDirectory.path))
        let output = ShellResourceDescriptor(
            id: ShellResourceID(),
            name: "copy.png",
            kind: "image",
            uti: UTType.png.identifier
        )
        try store.catalog.admit([output], owner: owner)
        do {
            try await store.importOutputs(
                [ShellResourceOutput(name: output.name, path: output.name)],
                ids: [output.id],
                action: key
            )
            XCTFail("cancelled image batch imported an output")
        } catch {}
        XCTAssertNotEqual(store.catalog.metadata(output.id, owner: owner)?.state, .ready)
        await store.finishAction(key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: action.outputDirectory.path))
    }

    func testInvalidImageFailsWithoutAdmittingOutput() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = ShellResourceDescriptor(
            id: ShellResourceID(), name: "invalid.png", kind: "image", uti: UTType.png.identifier
        )
        try store.catalog.admit([descriptor], owner: owner)
        try await store.materialize([.bytes(Data("not an image".utf8))], ids: [descriptor.id], owner: owner)
        let (key, action) = try await prepare([descriptor], in: store, operation: ShellResourceOperation())
        do {
            _ = try await store.convertImages(key, format: .png) { _, _ in }
            XCTFail("invalid image converted")
        } catch let failure as ShellResourceFailure {
            XCTAssertEqual(failure, ShellResourceFailure("invalid_image"))
        } catch {
            XCTFail("unexpected conversion error: \(error)")
        }
        XCTAssertEqual(store.catalog.metadata(descriptor.id, owner: owner)?.state, .ready)
        await store.finishAction(key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: action.outputDirectory.path))
    }

    func testPendingInputBeginsConversionOnlyAfterMaterialization() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = try XCTUnwrap(images.first)
        let descriptor = ShellResourceDescriptor(
            id: ShellResourceID(), name: image.name, kind: "image", uti: UTType.png.identifier
        )
        try store.catalog.admit([descriptor], owner: owner)
        let key = actionKey()
        let replies = Mutex<[Result<ShellResourceStore.ActionFiles, ShellResourceFailure>]>([])
        await store.beginAction(key, inputs: [descriptor.id], operation: ShellResourceOperation()) { result in
            replies.withLock { $0.append(result) }
        }
        XCTAssertTrue(replies.withLock { $0.isEmpty })
        try await store.materialize([.bytes(try png(image))], ids: [descriptor.id], owner: owner)
        XCTAssertEqual(replies.withLock { $0.count }, 1)
        let action = try XCTUnwrap(replies.withLock { $0.first }).get()
        let result = try await store.convertImages(key, format: .png) { _, _ in }
        try assertImage(
            action.outputDirectory.appendingPathComponent(try XCTUnwrap(result.files.first).path),
            type: .png,
            image: image
        )
        _ = await store.retire(owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: action.outputDirectory.path))
    }

    func testConversionRequestDecodingValidatesFormatAndResourceBatch() throws {
        let resources = (0 ..< ShellResourceStore.attachmentLimit).map { _ in ShellResourceID() }
        let fields = requestFields(resources.map(resourceValue), format: "jpeg")
        let request = try decode(fields)
        guard case let .convert(ids, format) = request.action else { return XCTFail("expected image conversion") }
        XCTAssertEqual(ids, resources)
        XCTAssertEqual(format.rawValue, "jpeg")
        for invalid in [
            requestFields([], format: "png"),
            requestFields(resources.map(resourceValue) + [resourceValue(ShellResourceID())], format: "png"),
            requestFields([resourceValue(resources[0]), resourceValue(resources[0])], format: "png"),
            requestFields([resourceValue(resources[0])], format: "gif"),
            requestFields([.bytes(Array(repeating: 0, count: MemoryLayout<uuid_t>.size - 1))], format: "png")
        ] { XCTAssertThrowsError(try decode(invalid)) }
    }

    func testDesktopConversionPublishesReadyResourcesAndDiscardsUndeliveredCopies() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = try await admitImages(images, in: store)
        let desktop = ShellDesktopServices(resources: store)
        let ledger = ShellServiceLedger(generation: owner.generation)
        let wakes = AsyncStream<Void>.makeStream()
        let retired = AsyncStream<[ShellResourceID]>.makeStream()
        defer {
            wakes.continuation.finish()
            retired.continuation.finish()
            ledger.close()
        }
        ledger.attachWake { wakes.continuation.yield(()) }
        let bridge = ShellDesktopResourceBridge(admit: { id, items in
            let descriptors = items.map {
                ShellResourceDescriptor(id: ShellResourceID(), name: $0.name, kind: $0.kind, uti: $0.uti)
            }
            try store.catalog.admit(descriptors, owner: id.owner)
            return descriptors.map(\.id)
        }, retireIDs: { _, ids in retired.continuation.yield(ids) })
        XCTAssertTrue(desktop.perform(
            ShellDesktopRequest(id: actionKey().id, action: .convert(inputs.map(\.id), format: .png)),
            ledger: ledger, bridge: bridge
        ))
        let completion = try await terminalCompletion(ledger, wakes: wakes.stream)
        XCTAssertEqual(try ShellServiceValue.decode(completion.payload).fields?["ok"]?.boolean, true)
        let outputs = try XCTUnwrap(completion.desktopResources)
        XCTAssertEqual(outputs.count, inputs.count)
        for output in outputs { XCTAssertEqual(store.catalog.metadata(output, owner: owner)?.state, .ready) }
        XCTAssertTrue(desktop.operations.isEmpty)
        XCTAssertEqual(ledger.activeCount, 0)
        completion.discardUndelivered()
        var retiredIterator = retired.stream.makeAsyncIterator()
        let retiredIDs = await retiredIterator.next()
        XCTAssertEqual(retiredIDs, outputs)
        for output in outputs { XCTAssertNil(store.catalog.metadata(output, owner: owner)) }
        for input in inputs { XCTAssertEqual(store.catalog.metadata(input.id, owner: owner)?.state, .ready) }
    }

    @MainActor
    private func terminalCompletion(
        _ ledger: ShellServiceLedger, wakes: AsyncStream<Void>
    ) async throws -> ShellServiceCompletion {
        for await _ in wakes {
            var terminal: ShellServiceCompletion?
            for update in ledger.takeBatch() {
                if update.isProgress {
                    let progress = try XCTUnwrap(try ShellServiceValue.decode(update.payload).fields?["progress"]?
                        .fields)
                    XCTAssertEqual(progress["total"]?.number, Double(images.count))
                    let completed = try XCTUnwrap(progress["completed"]?.number)
                    XCTAssertTrue((0 ... Double(images.count)).contains(completed))
                } else {
                    XCTAssertNil(terminal)
                    terminal = update
                }
            }
            _ = ledger.finishBatch()
            if let terminal { return terminal }
        }
        throw ShellResourceFailure("conversion event stream closed without a result")
    }

    private func assertOwnedCopies(
        _ result: ShellConvertedImages, key: ShellResourceLeaseKey, action: ShellResourceStore.ActionFiles,
        store: ShellResourceStore, type: UTType
    ) async throws {
        let descriptors = result.descriptors.map {
            ShellResourceDescriptor(id: ShellResourceID(), name: $0.name, kind: $0.kind, uti: $0.uti)
        }
        try store.catalog.admit(descriptors, owner: owner)
        try await store.importOutputs(result.files, ids: descriptors.map(\.id), action: key)
        await store.finishAction(key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: action.outputDirectory.path))
        let otherOwner = ShellServiceOwner(generation: 19, owner: 4, epoch: 2)
        try await store.activate(
            otherOwner,
            namespace: ShellStoreNamespace(profile: "lake", package: "lake", instance: "other-converter")
        )
        for descriptor in descriptors {
            XCTAssertNil(store.catalog.metadata(descriptor.id, owner: otherOwner))
        }
        do {
            _ = try await store.retain(descriptors.map(\.id), owner: otherOwner)
            XCTFail("converted outputs were exposed to another widget owner")
        } catch let failure as ShellResourceFailure {
            XCTAssertEqual(failure, ShellResourceFailure("resource is not ready"))
        }
        let pin = try await store.retain(descriptors.map(\.id), owner: owner)
        XCTAssertEqual(pin.values.count, images.count)
        var ownedFiles: [URL] = []
        for (index, value) in pin.values.enumerated() {
            guard case let .file(url) = value else { return XCTFail("converted output is not file-backed") }
            ownedFiles.append(url)
            try assertImage(url, type: type, image: images[index])
            XCTAssertEqual(store.catalog.metadata(descriptors[index].id, owner: owner)?.state, .ready)
        }
        await store.release(descriptors.map(\.id), owner: owner)
        for file in ownedFiles { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
        await store.release(pin)
        for file in ownedFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
    }
}

extension ShellImageConversionTests {
    func testOtherStoreCallsProceedWhileConversionKeepsCancelledInputsAlive() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = try await admitImages(images, in: store)
        let operation = ShellResourceOperation()
        let (key, action) = try await prepare(inputs, in: store, operation: operation)
        let otherOwner = ShellServiceOwner(generation: 19, owner: 4, epoch: 2)
        try await store.activate(
            otherOwner,
            namespace: ShellStoreNamespace(profile: "lake", package: "lake", instance: "other-widget")
        )
        let pin = try await store.retain(inputs.map(\.id), owner: owner)
        let inputFiles = try pin.values.map { value in
            guard case let .file(url) = value else { throw ShellResourceFailure("expected file") }
            return url
        }
        await store.release(pin)
        let unrelated = ShellResourceDescriptor(
            id: ShellResourceID(),
            name: "other-widget",
            kind: "text",
            uti: "public.text"
        )
        try store.catalog.admit([unrelated], owner: otherOwner)
        let paused = expectation(description: "conversion paused after an image")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let pauseAfter = images.count - 1
        let conversion = Task {
            try await store.convertImages(key, format: .png) { completed, _ in
                if completed == pauseAfter {
                    paused.fulfill()
                    resume.wait()
                }
            }
        }
        await fulfillment(of: [paused], timeout: failureBound)
        let available = expectation(description: "unrelated store call completed")
        let completed = Mutex(false)
        let storeCall = Task {
            try await store.materialize([.text("other widget")], ids: [unrelated.id], owner: otherOwner)
            do {
                _ = try await store.convertImages(key, format: .png) { _, _ in XCTFail("second conversion started") }
                XCTFail("concurrent conversion accepted")
            } catch let failure as ShellResourceFailure {
                XCTAssertEqual(failure, ShellResourceFailure("invalid_conversion"))
            }
            completed.withLock { $0 = true }
            available.fulfill()
        }
        await fulfillment(of: [available], timeout: failureBound)
        guard completed.withLock({ $0 }) else {
            resume.signal()
            _ = try? await conversion.value
            _ = try? await storeCall.value
            return
        }
        try await storeCall.value
        XCTAssertEqual(store.catalog.metadata(unrelated.id, owner: otherOwner)?.state, .ready)
        await store.finishAction(key)
        await store.release(inputs.map(\.id), owner: owner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: action.outputDirectory.path))
        for input in inputFiles { XCTAssertTrue(FileManager.default.fileExists(atPath: input.path)) }
        resume.signal()
        do {
            _ = try await conversion.value
            XCTFail("cancelled conversion completed")
        } catch let failure as ShellResourceFailure {
            XCTAssertEqual(failure, ShellResourceFailure("cancelled"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: action.outputDirectory.path))
        for input in inputFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: input.path)) }
    }

    func testRetirementWaitsForConversionCleanupIncludingOverlappingRetirements() async throws {
        let (store, directory) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputs = try await admitImages(images, in: store)
        let (key, action) = try await prepare(inputs, in: store, operation: ShellResourceOperation())
        let paused = expectation(description: "conversion paused")
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let pauseAfter = images.count - 1
        let conversion = Task {
            try await store.convertImages(key, format: .png) { completed, _ in
                if completed == pauseAfter {
                    paused.fulfill()
                    resume.wait()
                }
            }
        }
        await fulfillment(of: [paused], timeout: failureBound)
        let retirementNames = ["close", "overlapping close"]
        let retiring = expectation(description: "retirements requested")
        retiring.expectedFulfillmentCount = retirementNames.count
        let retirements = retirementNames.map { _ in
            Task {
                retiring.fulfill()
                return await store.retire(owner)
            }
        }
        await fulfillment(of: [retiring], timeout: failureBound)
        let waiters = await store.imageConversionWaiterCount(key)
        XCTAssertEqual(waiters, retirementNames.count)
        XCTAssertFalse(store.catalog.isActive(owner))
        XCTAssertTrue(FileManager.default.fileExists(atPath: action.outputDirectory.path))
        resume.signal()
        for retirement in retirements {
            let failures = await retirement.value
            XCTAssertTrue(failures.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: action.outputDirectory.path))
        }
        do {
            _ = try await conversion.value
            XCTFail("retired conversion completed")
        } catch let failure as ShellResourceFailure {
            XCTAssertEqual(failure, ShellResourceFailure("cancelled"))
        }
    }

    private func fixture() async throws -> (ShellResourceStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = ShellResourceStore(directory: directory)
        try await store.activate(
            owner,
            namespace: ShellStoreNamespace(profile: "lake", package: "lake", instance: "converter")
        )
        return (store, directory)
    }

    private func admitImages(
        _ images: [Image],
        in store: ShellResourceStore
    ) async throws -> [ShellResourceDescriptor] {
        let descriptors = images.map {
            ShellResourceDescriptor(id: ShellResourceID(), name: $0.name, kind: "image", uti: UTType.png.identifier)
        }
        try store.catalog.admit(descriptors, owner: owner)
        try await store.materialize(images.map { .bytes(try png($0)) }, ids: descriptors.map(\.id), owner: owner)
        return descriptors
    }

    private func prepare(
        _ inputs: [ShellResourceDescriptor], in store: ShellResourceStore, operation: ShellResourceOperation
    ) async throws -> (ShellResourceLeaseKey, ShellResourceStore.ActionFiles) {
        let key = actionKey()
        let reply = Mutex<Result<ShellResourceStore.ActionFiles, ShellResourceFailure>?>(nil)
        await store.beginAction(key, inputs: inputs.map(\.id), operation: operation) { result in
            reply.withLock { $0 = result }
        }
        return try (key, XCTUnwrap(reply.withLock { $0 }).get())
    }

    private func actionKey() -> ShellResourceLeaseKey {
        ShellResourceLeaseKey(id: ShellServiceID(owner: owner, request: 1), incarnation: 0)
    }

    private func png(_ image: Image) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func assertImage(_ url: URL, type: UTType, image: Image) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, type.identifier)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, image.width)
        XCTAssertEqual(decoded.height, image.height)
    }

    private func requestFields(_ resources: [ShellServiceValue], format: String) -> ShellServiceValue {
        .object(["op": .text("convert"), "resources": .array(resources), "format": .text(format)])
    }

    private func resourceValue(_ resource: ShellResourceID) -> ShellServiceValue {
        withUnsafeBytes(of: resource.value.uuid) { .bytes(Array($0)) }
    }

    private func decode(_ fields: ShellServiceValue) throws -> ShellDesktopRequest {
        var writer = ShellValueWriter()
        fields.write(to: &writer)
        return try ShellDesktopRequest(id: actionKey().id, bytes: writer.bytes)
    }
}

private extension ShellResourceStore {
    func imageConversionWaiterCount(_ key: ShellResourceLeaseKey) -> Int {
        actions[key]?.conversionWaiters.count ?? 0
    }
}
