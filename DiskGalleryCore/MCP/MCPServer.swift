import Foundation

/// Model Context Protocol server over stdio, so an external AI agent (Claude Desktop,
/// Claude Code, any MCP client) can read the catalog and propose an organization by
/// writing annotations.
///
/// Hand-rolled JSON-RPC 2.0: MCP is newline-delimited JSON over stdin/stdout, which is a
/// few dozen lines with `Codable` — not worth a dependency.
///
/// **Never writes to a drive.** The only mutation it performs is annotations in the
/// catalog DB; `MutationGuardTests` enforces that statically.
public struct MCPServer: Sendable {
    let tools: MCPTools

    /// The newest protocol revision we implement. We echo the client's version back when
    /// it sends one, since MCP clients negotiate by string.
    static let protocolVersion = "2025-06-18"

    public init(catalog: Catalog) {
        self.tools = MCPTools(catalog: catalog)
    }

    // MARK: stdio loop

    /// Reads request lines from stdin until EOF, writing one response line each.
    /// stdout carries protocol frames only — diagnostics go to stderr.
    public func runStdio() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let response = await handle(line: line) {
                print(response)
                fflush(stdout)
            }
        }
    }

    // MARK: Dispatch

    /// Handles one JSON-RPC line. Returns the response line, or nil for a notification
    /// (which by protocol gets no reply).
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(Request.self, from: data) else {
            return encode(Response(id: .null, error: .init(code: -32700, message: "Parse error")))
        }
        // A request without an id is a notification: act on it, answer nothing.
        guard let id = request.id else { return nil }

        switch request.method {
        case "initialize":
            let clientVersion = request.params?["protocolVersion"]?.stringValue
            return encode(Response(id: id, result: .of([
                "protocolVersion": .string(clientVersion ?? Self.protocolVersion),
                "capabilities": .of(["tools": .of(["listChanged": .bool(false)])]),
                "serverInfo": .of(["name": .string("diskgallery"), "version": .string("1.0.0")]),
            ])))

        case "ping":
            return encode(Response(id: id, result: .object([:])))

        case "tools/list":
            return encode(Response(id: id, result: .of(["tools": .array(MCPTools.definitions)])))

        case "tools/call":
            let name = request.params?["name"]?.stringValue ?? ""
            let args = request.params?["arguments"] ?? .object([:])
            let result = await tools.call(name: name, arguments: args)
            return encode(Response(id: id, result: result))

        default:
            return encode(Response(id: id, error: .init(code: -32601,
                                                        message: "Method not found: \(request.method)")))
        }
    }

    private func encode(_ response: Response) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(response), let text = String(data: data, encoding: .utf8) else {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Encoding failed"}}"#
        }
        return text
    }

    // MARK: Envelope

    struct Request: Decodable {
        var jsonrpc: String?
        var id: JSONValue?
        var method: String
        var params: JSONValue?
    }

    struct Response: Encodable {
        var jsonrpc = "2.0"
        var id: JSONValue
        var result: JSONValue?
        var error: RPCError?

        init(id: JSONValue, result: JSONValue) {
            self.id = id; self.result = result; self.error = nil
        }
        init(id: JSONValue, error: RPCError) {
            self.id = id; self.result = nil; self.error = error
        }
    }

    struct RPCError: Encodable {
        var code: Int
        var message: String
    }
}
