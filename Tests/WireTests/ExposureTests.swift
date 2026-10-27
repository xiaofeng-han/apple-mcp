import Foundation
import Testing
@testable import Wire

func tool(_ name: String, _ effect: Tool.Effect) -> Tool {
    Tool(name, title: name, summary: name, input: Schema.object([:]), effect: effect) { _ in ToolAnswer("ran \(name)") }
}

/// Out of order on purpose: the service lists them by name.
let sample = [tool("write_b", .writes), tool("read_a", .reads), tool("delete_a", .deletes), tool("read_b", .reads),
              tool("write_a", .writes), tool("delete_b", .deletes)]

/// A tools.json in a throwaway folder.
struct Box {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wire-tests-\(UUID().uuidString)", isDirectory: true)
    var exposure: ToolExposure { ToolExposure(file: folder.appendingPathComponent("tools.json"), changedIn: "the Tools tab") }

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: exposure.file)
    }

    func read() throws -> String {
        String(decoding: try Data(contentsOf: exposure.file), as: UTF8.self)
    }

    func service() -> Service {
        Service(name: "test", version: "1", instructions: "Base.", tools: sample, exposure: exposure)
    }
}

extension Service {
    func send(_ method: String, _ params: JSON = [:], id: Int? = 1) async -> JSON? {
        var message: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method), "params": params]
        if let id { message["id"] = .int(id) }
        return await reply(to: JSON.object(message).text).flatMap(JSON.parse)
    }

    /// Lists the tools as StdioServer does: the reply, then what is to follow it.
    func listed() async -> [String] {
        let names = (await send("tools/list")?["result"]?["tools"]?.array ?? []).compactMap { $0["name"]?.string }
        #expect(notices(afterReply: true) == [])
        return names
    }

    func started() async {
        _ = await send("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "t", "version": "1"]])
        _ = await send("notifications/initialized", id: nil)
    }
}

@Suite struct ExposureTests {
    func offered(_ choices: [String: Bool]) -> [String] {
        sample.filter { ToolExposure.exposes($0, among: sample, choices: choices) }.map(\.name).sorted()
    }

    @Test func everythingWithoutAFile() async throws {
        let box = try Box()
        #expect(try box.exposure.choices() == [:])
        #expect(await box.service().listed() == ["delete_a", "delete_b", "read_a", "read_b", "write_a", "write_b"])
    }

    @Test func unnamedToolsFollowTheirKind() {
        // A full read-only choice, then a version adds one tool of each kind.
        let readOnly = ["read_a": true, "write_a": false, "delete_a": false]
        #expect(offered(readOnly) == ["read_a", "read_b"])
        // Turning off one tool that deletes keeps the unnamed ones that delete off, and nothing else.
        #expect(offered(["delete_a": false]) == ["read_a", "read_b", "write_a", "write_b"])
        // A tool named in the file goes by the file.
        #expect(offered(["delete_a": false, "delete_b": true]) == ["delete_b", "read_a", "read_b", "write_a", "write_b"])
        #expect(offered(["read_a": false]) == ["delete_a", "delete_b", "write_a", "write_b"])
    }

    @Test func savingKeepsWhatANewerVersionWrote() throws {
        let box = try Box()
        try box.write(#"{"newer_setting": {"x": 1}, "tools": {"from_newer_version": false, "read_a": false}}"#)
        try box.exposure.save(["read_a": true, "write_a": false])
        #expect(try box.read() == """
            {
              "newer_setting" : {
                "x" : 1
              },
              "tools" : {
                "from_newer_version" : false,
                "read_a" : true,
                "write_a" : false
              }
            }

            """)
    }

    @Test func savingReplacesAnUnreadableFileKeepingACopy() throws {
        let box = try Box()
        try box.write("{not json")
        try box.exposure.save(["read_a": true])
        #expect(try box.exposure.choices() == ["read_a": true])
        let copies = try FileManager.default.contentsOfDirectory(atPath: box.folder.path).filter { $0.hasPrefix("tools.json.bak-") }
        #expect(copies.count == 1)
        #expect(try copies.first.map { String(decoding: try Data(contentsOf: box.folder.appendingPathComponent($0)), as: UTF8.self) } == "{not json")
    }

    @Test func savingLeavesAFileItCannotCopy() throws {
        let box = try Box()
        try box.write(#"{"tools": {"read_a": false}}"#)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: box.exposure.file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.exposure.file.path) }
        #expect(throws: ToolExposure.Unreadable.self) { try box.exposure.choices() }
        #expect(throws: (any Error).self) { try box.exposure.save(["read_a": true]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.exposure.file.path)
        #expect(try box.exposure.choices() == ["read_a": false])
    }

    @Test func savingWritesThroughALink() throws {
        let box = try Box()
        let real = box.folder.appendingPathComponent("dotfiles/tools.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: box.exposure.file, withDestinationURL: real)
        try box.exposure.save(["read_a": false])
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: box.exposure.file.path)) != nil)
        #expect(try box.exposure.choices() == ["read_a": false])
    }

    @Test(arguments: [("", .empty), (" \n", .empty), ("{not json", .notJSON), (#"{"tools": ["read_a"]}"#, .wrongShape), ("[]", .wrongShape),
                      (#"{"tools": {"read_a": "yes"}}"#, .notTrueOrFalse("read_a"))] as [(String, ToolExposure.Unreadable.Reason)])
    func unreadableFileOffersNothing(_ text: String, _ reason: ToolExposure.Unreadable.Reason) async throws {
        let box = try Box()
        try box.write(text)
        #expect(throws: ToolExposure.Unreadable(reason: reason)) { try box.exposure.choices() }
        let service = box.service()
        #expect(await service.listed() == [])
        let reply = await service.send("tools/call", ["name": "read_a", "arguments": [:]])
        #expect(reply?["error"]?["code"]?.int == -32602)
        #expect(reply?["error"]?["message"]?.string?.contains("can't be read") == true)
    }

    @Test func turnedOffToolsAreRefusedAndNamed() async throws {
        let box = try Box()
        try box.exposure.save(["delete_a": false, "delete_b": false, "read_a": true, "read_b": true, "write_a": true, "write_b": true])
        let service = box.service()
        let initialized = await service.send("initialize", ["protocolVersion": "2025-06-18"])
        #expect(initialized?["result"]?["capabilities"]?["tools"]?["listChanged"] == true)
        // The same whatever is turned off, since clients keep it.
        #expect(initialized?["result"]?["instructions"]?.string
                == "Base.\n\nThe user chooses which of these tools are offered, in the Tools tab. A tool named here that is not in your tool list is turned off there.")
        #expect(await service.listed() == ["read_a", "read_b", "write_a", "write_b"])
        let refused = await service.send("tools/call", ["name": "delete_a"])
        #expect(refused?["error"]?["message"]?.string == "delete_a is turned off. The user can turn it on in the Tools tab.")
        let ran = await service.send("tools/call", ["name": "write_a"])
        #expect(ran?["result"]?["content"]?.array?.first?["text"]?.string == "ran write_a")
        #expect(await service.send("tools/call", ["name": "nothing"])?["error"]?["message"]?.string == "There is no tool named nothing")
    }

    @Test func refusalSaysWhy() throws {
        let box = try Box()
        let readA = sample.first { $0.name == "read_a" }!
        #expect(box.exposure.refusal(readA, among: sample) == nil)
        try box.exposure.save(["read_a": false])
        #expect(box.exposure.refusal(readA, among: sample) == "read_a is turned off. The user can turn it on in the Tools tab.")
        try box.write("{")
        #expect(box.exposure.refusal(readA, among: sample)?.contains("can't be read") == true)
    }

    @Test func withoutExposureNothingChanges() async {
        let service = Service(name: "test", version: "1", instructions: "Base.", tools: sample)
        let initialized = await service.send("initialize", ["protocolVersion": "2025-06-18"])
        #expect(initialized?["result"]?["capabilities"]?["tools"]?["listChanged"] == false)
        #expect(initialized?["result"]?["instructions"]?.string == "Base.")
        #expect(await service.listed().count == 6)
        #expect(service.notices(afterReply: true) == [])
        let discovered = await service.send("server/discover", stateless)
        #expect(discovered?["result"]?["capabilities"]?["tools"]?["listChanged"] == false)
        let ack = await service.send("subscriptions/listen", stateless.merging(["notifications": ["toolsListChanged": true]]), id: 7)
        #expect(ack?["params"]?["notifications"] == [:])
    }

    @Test func sessionClientIsToldOnceAboutAChange() async throws {
        let box = try Box()
        let service = box.service()
        // Not before the client has initialized and listed.
        try box.exposure.save(["read_a": false])
        #expect(service.notices() == [])
        await service.started()
        #expect(service.notices() == [])
        _ = await service.listed()
        #expect(service.notices() == [])

        try box.exposure.save(["read_a": true])
        #expect(service.notices() == [#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#])
        #expect(service.notices() == [])
        // Changed back before the client listed again: it is told again.
        try box.exposure.save(["read_a": false])
        #expect(service.notices().count == 1)
        _ = await service.listed()
        #expect(service.notices() == [])
        // A stateless stream is no part of the session protocol.
        #expect(await service.send("subscriptions/listen", ["notifications": ["toolsListChanged": true]])?["error"]?["code"] == -32601)
    }

    @Test func statelessClientIsToldOnItsStream() async throws {
        let box = try Box()
        let service = box.service()
        let discovered = await service.send("server/discover", stateless)
        #expect(discovered?["result"]?["capabilities"]?["tools"]?["listChanged"] == true)
        let listed = await service.send("tools/list", stateless)
        #expect(listed?["result"]?["ttlMs"] == 0)
        #expect(listed?["result"]?["cacheScope"] == "private")
        #expect(listed?["result"]?["resultType"] == "complete")
        // No stream, nothing to say.
        try box.exposure.save(["read_a": false])
        #expect(service.notices(afterReply: true) == [])

        // The change since the client listed comes right after the acknowledgment, and only then.
        let ack = await service.send("subscriptions/listen", stateless.merging(["notifications": ["toolsListChanged": true, "promptsListChanged": true]]),
                                     id: 7)
        #expect(ack?["id"] == nil)
        #expect(ack?["method"] == "notifications/subscriptions/acknowledged")
        #expect(ack?["params"]?["_meta"]?["io.modelcontextprotocol/subscriptionId"] == 7)
        #expect(ack?["params"]?["notifications"] == ["toolsListChanged": true])
        #expect(service.notices() == [])
        let first = service.notices(afterReply: true)
        #expect(first == [#"{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{"_meta":{"io.modelcontextprotocol/subscriptionId":7}}}"#])
        #expect(service.notices() == [])
        try box.exposure.save(["read_a": true])
        #expect(service.notices().count == 1)
        #expect(service.notices() == [])

        // A list the client asked for is news to no stream, and a change while it is on its way
        // follows it.
        _ = await service.send("tools/list", stateless)
        try box.exposure.save(["read_a": false])
        #expect(service.notices() == [])
        #expect(service.notices(afterReply: true).count == 1)
        try box.exposure.save(["read_a": true])
        _ = await service.send("tools/list", stateless)
        #expect(service.notices(afterReply: true) == [])

        // Cancelled: nothing more on it.
        _ = await service.send("notifications/cancelled", ["requestId": 7], id: nil)
        try box.exposure.save(["read_a": false])
        #expect(service.notices(afterReply: true) == [])
    }
}

let stateless: JSON = ["_meta": ["io.modelcontextprotocol/protocolVersion": "2026-07-28"]]

extension JSON {
    func merging(_ other: [String: JSON]) -> JSON {
        .object((object ?? [:]).merging(other) { $1 })
    }
}

/// Counts calls from a FileWatch.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }

    /// Waits up to `seconds` for a call after `before`.
    func waitPast(_ before: Int, seconds: Int = 2) async -> Bool {
        for _ in 0..<(seconds * 20) {
            if value > before { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

final class Readings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool?] = []

    func add(_ value: Bool?) { lock.withLock { values.append(value) } }
    var all: [Bool?] { lock.withLock { values } }
}

@Suite struct FileWatchTests {
    @Test func seesSavesEditsAndRemovals() async throws {
        let box = try Box()
        let counter = Counter()
        let watch = FileWatch(box.exposure.file) { counter.bump() }
        defer { watch.stop() }

        // Created by an atomic save, saved again (a new inode), edited in place, removed.
        try box.exposure.save(["read_a": false])
        #expect(await counter.waitPast(0))
        try await Task.sleep(for: .milliseconds(100))
        var before = counter.value
        try box.exposure.save(["read_a": true])
        #expect(await counter.waitPast(before))
        try await Task.sleep(for: .milliseconds(100))
        before = counter.value
        let handle = try FileHandle(forWritingTo: box.exposure.file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        #expect(await counter.waitPast(before))
        try await Task.sleep(for: .milliseconds(100))
        before = counter.value
        try FileManager.default.removeItem(at: box.exposure.file)
        #expect(await counter.waitPast(before))
    }

    @Test func seesAFileEmptiedInPlace() async throws {
        let box = try Box()
        try box.exposure.save(["read_a": false])
        let counter = Counter()
        let watch = FileWatch(box.exposure.file) { counter.bump() }
        defer { watch.stop() }
        let handle = try FileHandle(forWritingTo: box.exposure.file)
        try handle.truncate(atOffset: 0)
        try handle.close()
        #expect(await counter.waitPast(0))
    }

    @Test func letsASaveInPlaceSettle() async throws {
        let box = try Box()
        try box.exposure.save(["read_a": false])
        // What the file held at each call.
        let readings = Readings()
        let watch = FileWatch(box.exposure.file) { readings.add((try? box.exposure.choices())?["read_a"]) }
        defer { watch.stop() }
        // Emptied, then written a moment later, the way a shell redirect saves.
        for exposed in [true, false, true, false, true] {
            let descriptor = open(box.exposure.file.path, O_WRONLY | O_TRUNC)
            // Holding the thread, not Task.sleep: resuming on a busy cooperative pool (tests run
            // in parallel) can take longer than the watch's 50 ms, which no shell redirect does.
            usleep(3_000)
            let text = #"{"tools": {"read_a": \#(exposed)}}"#
            _ = text.withCString { write(descriptor, $0, strlen($0)) }
            close(descriptor)
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(!readings.all.isEmpty)
        #expect(!readings.all.contains(nil), "\(readings.all)")
        #expect(readings.all.last == true)
    }

    @Test func followsALinkToAFileNotThereYet() async throws {
        let box = try Box()
        let real = box.folder.appendingPathComponent("dotfiles/tools.json")
        try FileManager.default.createSymbolicLink(at: box.exposure.file, withDestinationURL: real)
        let counter = Counter()
        let watch = FileWatch(box.exposure.file) { counter.bump() }
        defer { watch.stop() }
        // The target's folder appears (seen once the watch looks again), then the file, which is
        // then removed and saved again.
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Task.sleep(for: .seconds(6))
        for step in 0..<3 {
            try await Task.sleep(for: .milliseconds(100))
            let before = counter.value
            if step == 1 { try FileManager.default.removeItem(at: real) } else { try box.exposure.save(["read_a": step == 0]) }
            #expect(await counter.waitPast(before), "step \(step)")
        }
    }

    @Test func keepsWatchingAFileItMayNotOpen() async throws {
        let box = try Box()
        try box.exposure.save(["read_a": false])
        let counter = Counter()
        let watch = FileWatch(box.exposure.file) { counter.bump() }
        defer { watch.stop() }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: box.exposure.file.path)
        #expect(await counter.waitPast(0))
        // Something else changes in the folder; the file's own source must survive it.
        try await Task.sleep(for: .milliseconds(100))
        try Data().write(to: box.folder.appendingPathComponent("other"))
        try await Task.sleep(for: .milliseconds(300))
        let before = counter.value
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: box.exposure.file.path)
        #expect(await counter.waitPast(before))
    }

    @Test func findsItsFolderAgain() async throws {
        let box = try Box()
        let counter = Counter()
        let watch = FileWatch(box.exposure.file) { counter.bump() }
        defer { watch.stop() }
        try FileManager.default.removeItem(at: box.folder)
        #expect(await counter.waitPast(0))
        try await Task.sleep(for: .milliseconds(100))
        // The folder comes back, then the file: seen once the watch has found the folder again.
        try FileManager.default.createDirectory(at: box.folder, withIntermediateDirectories: true)
        try await Task.sleep(for: .seconds(6))
        let before = counter.value
        try box.exposure.save(["read_a": false])
        #expect(await counter.waitPast(before))
    }

    @Test func followsAFileSavedThroughALink() async throws {
        let box = try Box()
        let real = box.folder.appendingPathComponent("dotfiles/tools.json")
        try FileManager.default.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
        try box.exposure.save(["read_a": false])
        try FileManager.default.moveItem(at: box.exposure.file, to: real)
        try FileManager.default.createSymbolicLink(at: box.exposure.file, withDestinationURL: real)
        let counter = Counter()
        let watch = FileWatch(box.exposure.file) { counter.bump() }
        defer { watch.stop() }

        // Each save replaces the file in the other folder; every one of them is still seen.
        for exposed in [true, false, true] {
            try await Task.sleep(for: .milliseconds(100))
            let before = counter.value
            try box.exposure.save(["read_a": exposed])
            #expect(await counter.waitPast(before))
        }
    }
}
