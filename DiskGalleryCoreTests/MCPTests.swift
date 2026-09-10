import XCTest
import GRDB
@testable import DiskGalleryCore

/// Exercises the MCP server the way a client does: one JSON-RPC line in, one line out.
final class MCPTests: XCTestCase {

    // MARK: Fixtures

    /// A drive with a small tree: root.jpg, 2024/a.jpg, 2024/trip/b.jpg, notes.txt.
    private func seedDrive(_ catalog: Catalog) async throws -> Int64 {
        try await catalog.database.writer.write { db in
            var volume = Volume(uuid: "UUID-A", name: "Alpha", createdAt: Date())
            try volume.insert(db)
            var snapshot = Snapshot(volumeId: volume.id!, scannedAt: Date(),
                                    totalCapacity: 1_000_000, freeCapacity: 400_000, isComplete: true)
            try snapshot.insert(db)
            let sid = snapshot.id!

            // (relPath, isDir, parentRelPath, ext, size)
            let rows: [(String, Bool, String?, String?, Int64)] = [
                ("",             true,  nil,      nil,   0),
                ("root.jpg",     false, "",       "jpg", 100),
                ("notes.txt",    false, "",       "txt", 10),
                ("2024",         true,  "",       nil,   0),
                ("2024/a.jpg",   false, "2024",   "jpg", 200),
                ("2024/trip",    true,  "2024",   nil,   0),
                ("2024/trip/b.jpg", false, "2024/trip", "jpg", 300),
            ]
            var idByPath: [String: Int64] = [:]
            var nextId: Int64 = 1
            for (relPath, isDir, parent, ext, size) in rows {
                let id = nextId; nextId += 1
                idByPath[relPath] = id
                try Entry(id: id, snapshotId: sid, parentId: parent.flatMap { idByPath[$0] },
                          name: relPath.isEmpty ? "Alpha" : (relPath as NSString).lastPathComponent,
                          relPath: relPath, isDir: isDir, logicalSize: size, allocSize: size,
                          ext: ext).insert(db)
            }
            try db.execute(sql: "UPDATE snapshot SET rootEntryId = ? WHERE id = ?",
                           arguments: [idByPath[""]!, sid])
            return volume.id!
        }
    }

    /// Sends one request and returns the decoded response object.
    private func send(_ server: MCPServer, _ method: String,
                      _ params: [String: JSONValue] = [:], id: Int = 1) async throws -> JSONValue {
        var request: [String: JSONValue] = [
            "jsonrpc": .string("2.0"), "id": .int(id), "method": .string(method),
        ]
        if !params.isEmpty { request["params"] = .object(params) }
        let line = String(data: try JSONEncoder().encode(JSONValue.object(request)), encoding: .utf8)!
        guard let response = await server.handle(line: line) else {
            throw TestError.noSnapshot   // a request with an id must produce a response
        }
        return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    }

    /// The JSON payload a tool call returns (its text content, re-parsed).
    private func toolResult(_ response: JSONValue) throws -> JSONValue {
        let result = try XCTUnwrap(response["result"])
        XCTAssertEqual(result["isError"]?.boolValue, false, "tool reported an error: \(result)")
        let text = try XCTUnwrap(result["content"]?.arrayValue?.first?["text"]?.stringValue)
        return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    private func toolCall(_ server: MCPServer, _ name: String,
                          _ args: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await send(server, "tools/call", ["name": .string(name), "arguments": .object(args)])
    }

    // MARK: Protocol

    func testInitializeAndToolsList() async throws {
        let server = MCPServer(catalog: try Fixture.makeCatalog())

        let initialize = try await send(server, "initialize", ["protocolVersion": .string("2025-06-18")])
        XCTAssertEqual(initialize["result"]?["protocolVersion"]?.stringValue, "2025-06-18")
        XCTAssertEqual(initialize["result"]?["serverInfo"]?["name"]?.stringValue, "diskgallery")

        let list = try await send(server, "tools/list")
        let names = try XCTUnwrap(list["result"]?["tools"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        XCTAssertEqual(Set(names), ["list_drives", "browse_folder", "search", "get_file",
                                    "list_duplicates", "get_thumbnail", "list_annotations",
                                    "set_annotations"])
        // Every tool advertises an object schema, or clients can't call it.
        for tool in try XCTUnwrap(list["result"]?["tools"]?.arrayValue) {
            XCTAssertEqual(tool["inputSchema"]?["type"]?.stringValue, "object")
        }
    }

    func testUnknownMethodAndMalformedLine() async throws {
        let server = MCPServer(catalog: try Fixture.makeCatalog())

        let unknown = try await send(server, "resources/list")
        XCTAssertEqual(unknown["error"]?["code"]?.intValue, -32601)

        let parseLine = await server.handle(line: "{not json")
        let parseError = try XCTUnwrap(parseLine)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(parseError.utf8))
        XCTAssertEqual(decoded["error"]?["code"]?.intValue, -32700)

        // A notification (no id) gets no reply at all.
        let notification = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notification)
    }

    // MARK: Read tools

    func testListDrivesAndBrowseFolderWalksTheTree() async throws {
        let catalog = try Fixture.makeCatalog()
        let volumeId = try await seedDrive(catalog)
        let server = MCPServer(catalog: catalog)

        let drives = try toolResult(try await toolCall(server, "list_drives"))
        let drive = try XCTUnwrap(drives["drives"]?.arrayValue?.first)
        XCTAssertEqual(drive["name"]?.stringValue, "Alpha")
        XCTAssertEqual(drive["volumeId"]?.intValue, Int(volumeId))
        XCTAssertEqual(drive["scanned"]?.boolValue, true)

        // Root: its own two files, and 2024 counted with all three photos beneath it.
        let root = try toolResult(try await toolCall(server, "browse_folder", ["volumeId": .int(Int(volumeId))]))
        XCTAssertEqual(root["files"]?.arrayValue?.compactMap { $0["name"]?.stringValue },
                       ["notes.txt", "root.jpg"])
        let subfolders = try XCTUnwrap(root["subfolders"]?.arrayValue)
        XCTAssertEqual(subfolders.compactMap { $0["name"]?.stringValue }, ["2024"])
        XCTAssertEqual(subfolders.first?["mediaCount"]?.intValue, 2)   // a.jpg + trip/b.jpg

        // One level down.
        let inside = try toolResult(try await toolCall(server, "browse_folder", [
            "volumeId": .int(Int(volumeId)), "relPath": .string("2024"),
        ]))
        XCTAssertEqual(inside["files"]?.arrayValue?.compactMap { $0["relPath"]?.stringValue }, ["2024/a.jpg"])
        XCTAssertEqual(inside["subfolders"]?.arrayValue?.compactMap { $0["relPath"]?.stringValue }, ["2024/trip"])
    }

    func testBrowseFolderPaginatesAndRejectsUnknownIds() async throws {
        let catalog = try Fixture.makeCatalog()
        let volumeId = try await seedDrive(catalog)
        let server = MCPServer(catalog: catalog)

        let firstPage = try toolResult(try await toolCall(server, "browse_folder", [
            "volumeId": .int(Int(volumeId)), "limit": .int(1),
        ]))
        XCTAssertEqual(firstPage["files"]?.arrayValue?.count, 1)
        XCTAssertEqual(firstPage["fileCount"]?.intValue, 2)
        XCTAssertEqual(firstPage["hasMore"]?.boolValue, true)

        let secondPage = try toolResult(try await toolCall(server, "browse_folder", [
            "volumeId": .int(Int(volumeId)), "limit": .int(1), "offset": .int(1),
        ]))
        XCTAssertEqual(secondPage["files"]?.arrayValue?.first?["name"]?.stringValue, "root.jpg")
        XCTAssertEqual(secondPage["hasMore"]?.boolValue, false)

        // Errors come back as isError content, never as a thrown/dropped response.
        let badCall = try await toolCall(server, "browse_folder", ["volumeId": .int(999)])
        let bad = try XCTUnwrap(badCall["result"])
        XCTAssertEqual(bad["isError"]?.boolValue, true)
        XCTAssertTrue((bad["content"]?.arrayValue?.first?["text"]?.stringValue ?? "").contains("999"))

        let missingArgCall = try await toolCall(server, "get_file", ["volumeId": .int(Int(volumeId))])
        let missingArg = try XCTUnwrap(missingArgCall["result"])
        XCTAssertEqual(missingArg["isError"]?.boolValue, true)

        let unknownToolCall = try await toolCall(server, "delete_everything")
        let unknownTool = try XCTUnwrap(unknownToolCall["result"])
        XCTAssertEqual(unknownTool["isError"]?.boolValue, true)
    }

    func testGetFileReportsAnnotationAndThumbnailMissIsAnError() async throws {
        let catalog = try Fixture.makeCatalog()
        let volumeId = try await seedDrive(catalog)
        let server = MCPServer(catalog: catalog)

        let file = try toolResult(try await toolCall(server, "get_file", [
            "volumeId": .int(Int(volumeId)), "relPath": .string("2024/a.jpg"),
        ]))
        XCTAssertEqual(file["name"]?.stringValue, "a.jpg")
        XCTAssertEqual(file["size"]?.intValue, 200)
        XCTAssertEqual(file["tag"]?.stringValue, "none")
        XCTAssertEqual(file["hasThumbnail"]?.boolValue, false)

        let thumbCall = try await toolCall(server, "get_thumbnail", [
            "volumeId": .int(Int(volumeId)), "relPath": .string("2024/a.jpg"),
        ])
        let thumb = try XCTUnwrap(thumbCall["result"])
        XCTAssertEqual(thumb["isError"]?.boolValue, true)
    }

    // MARK: Write tool

    func testSetAnnotationsRoundTripsAndReportsPerItemErrors() async throws {
        let catalog = try Fixture.makeCatalog()
        let volumeId = try await seedDrive(catalog)
        let server = MCPServer(catalog: catalog)

        let write = try toolResult(try await toolCall(server, "set_annotations", ["items": .of([
            .of(["volumeId": .int(Int(volumeId)), "relPath": .string("2024/a.jpg"),
                 "tag": .string("review"), "note": .string("looks like a duplicate shoot")]),
            .of(["volumeId": .int(Int(volumeId)), "relPath": .string("root.jpg"),
                 "tag": .string("delete"), "color": .string("red")]),
            .of(["volumeId": .int(Int(volumeId)), "relPath": .string("notes.txt"),
                 "tag": .string("obliterate")]),                       // invalid → per-item error
        ])]))
        XCTAssertEqual(write["applied"]?.intValue, 2)
        XCTAssertEqual(write["failed"]?.intValue, 1)
        let failure = try XCTUnwrap(write["results"]?.arrayValue?.last)
        XCTAssertEqual(failure["ok"]?.boolValue, false)
        XCTAssertTrue((failure["error"]?.stringValue ?? "").contains("obliterate"))

        // Visible through the read tool…
        let listed = try toolResult(try await toolCall(server, "list_annotations"))
        let rows = try XCTUnwrap(listed["annotations"]?.arrayValue)
        XCTAssertEqual(rows.count, 2)
        let review = try XCTUnwrap(rows.first { $0["tag"]?.stringValue == "review" })
        XCTAssertEqual(review["note"]?.stringValue, "looks like a duplicate shoot")
        XCTAssertEqual(review["relPath"]?.stringValue, "2024/a.jpg")

        // …and through the app's own store, with the color preserved alongside the tag.
        let stored = try await catalog.annotations.annotation(volumeKey: "UUID-A", relPath: "root.jpg")
        XCTAssertEqual(stored?.tag, .delete)
        XCTAssertEqual(stored?.color, .red)

        // Filtering by tag.
        let deletes = try toolResult(try await toolCall(server, "list_annotations", ["tag": .string("delete")]))
        XCTAssertEqual(deletes["annotations"]?.arrayValue?.count, 1)
    }

    func testSetAnnotationsRejectsOversizeBatch() async throws {
        let catalog = try Fixture.makeCatalog()
        let volumeId = try await seedDrive(catalog)
        let server = MCPServer(catalog: catalog)

        let items = (0...MCPTools.maxBatch).map { i in
            JSONValue.of(["volumeId": .int(Int(volumeId)), "relPath": .string("f\(i).jpg"),
                          "tag": .string("keep")])
        }
        let oversize = try await toolCall(server, "set_annotations", ["items": .of(items)])
        let result = try XCTUnwrap(oversize["result"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
    }

    // MARK: Change counter (how the app notices an agent's writes)

    func testAnnotationWritesBumpTheChangeCounter() async throws {
        let catalog = try Fixture.makeCatalog()
        let initial = try await catalog.annotations.changeCounter()
        XCTAssertEqual(initial, 0)

        try await catalog.annotations.setDecision(.keep, volumeKey: "UUID-A", relPath: "a.jpg")
        let afterFirst = try await catalog.annotations.changeCounter()
        XCTAssertEqual(afterFirst, 1)

        try await catalog.annotations.setNote("why", volumeKey: "UUID-A", relPath: "a.jpg")
        let afterSecond = try await catalog.annotations.changeCounter()
        XCTAssertGreaterThan(afterSecond, afterFirst)

        // Reads leave it alone.
        _ = try await catalog.annotations.all()
        let afterRead = try await catalog.annotations.changeCounter()
        XCTAssertEqual(afterRead, 2)

        // Clearing an annotation is a change too.
        try await catalog.annotations.set(tag: .none, color: .none, note: nil,
                                          volumeKey: "UUID-A", relPath: "a.jpg")
        let afterClear = try await catalog.annotations.changeCounter()
        XCTAssertEqual(afterClear, 3)
    }
}
