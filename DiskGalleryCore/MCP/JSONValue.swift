import Foundation

/// A dynamic JSON value. MCP tool arguments are arbitrary JSON, so the dispatcher needs a
/// `Codable` value it can carry around and read loosely. Small on purpose — this is the
/// whole of our "JSON library".
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .double(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    // MARK: Loose accessors (handlers read arguments through these)

    public var objectValue: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var stringValue: String? { if case .string(let v) = self { return v }; return nil }
    public var boolValue: Bool? { if case .bool(let v) = self { return v }; return nil }

    public var intValue: Int? {
        switch self {
        case .int(let v):    return v
        case .double(let v): return Int(v)
        case .string(let v): return Int(v)      // clients sometimes send numbers as strings
        default:             return nil
        }
    }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Convenience builders, so handlers can compose results without a struct per shape.
    public static func of(_ dict: [String: JSONValue?]) -> JSONValue {
        .object(dict.compactMapValues { $0 })
    }
    public static func of(_ items: [JSONValue]) -> JSONValue { .array(items) }
    public static func string(_ v: String?) -> JSONValue { v.map { JSONValue.string($0) } ?? .null }
    public static func int(_ v: Int64?) -> JSONValue { v.map { JSONValue.int(Int($0)) } ?? .null }
    public static func date(_ v: Date?) -> JSONValue {
        guard let v else { return .null }
        return .string(ISO8601DateFormatter().string(from: v))
    }
}
