// AnyJSON.swift
// RunnerBarCore
import Foundation

// MARK: - AnyJSON

/// A type-erased `Codable` value that round-trips arbitrary JSON without `JSONSerialization`.
///
/// Used in two places:
/// - `RunnerConfigStore`: read-modify-write merge of the `.runner` config file, preserving
///   agent-managed keys not modelled by `RunnerConfig`.
/// - `GitHubURLSessionTransport`: accumulates paginated GitHub API responses and
///   re-encodes them as a single concatenated array.
///
/// The `.int` case exists specifically to support integer fields — such as `agentId` — that
/// may exceed `2^53` and would lose precision if round-tripped through `Double`.
public enum AnyJSON: Codable {
    /// A JSON object (`{ ... }`).
    case object([String: AnyJSON])
    /// A JSON array (`[ ... ]`).
    case array([AnyJSON])
    /// A JSON string value.
    case string(String)
    /// A JSON floating-point number value.
    case number(Double)
    /// A JSON integer number value.
    ///
    /// Stored separately from `.number` to avoid precision loss for large integers
    /// (e.g. `agentId`) that exceed the 53-bit mantissa of `Double`.
    case int(Int)
    /// A JSON boolean value.
    case bool(Bool)
    /// A JSON null value.
    case null

    /// Decodes a single JSON value into the appropriate `AnyJSON` case.
    ///
    /// Decode order is intentional and must not be changed without care:
    /// - `object` and `array` are tried first because a `singleValueContainer` for a plain
    ///   string or number will simply fail to decode as `[String: AnyJSON]` or `[AnyJSON]`,
    ///   keeping the fast-path correct; placing them first makes the intent explicit.
    ///   This relies on `JSONDecoder`'s current behaviour and the `try?` fallthrough below.
    /// - `Bool` is tried before `Int`, `Double`, and `String` — on Apple platforms
    ///   `JSONDecoder` decodes `true`/`false` as `Bool`, but trying numeric or string types
    ///   first could silently succeed on some JSON tokens and misclassify booleans.
    ///   This matches the ordering used by every canonical `AnyCodable` implementation.
    /// - `Int` is tried before `Double` so that integer-valued fields (e.g. `agentId`) are
    ///   stored losslessly as `.int` rather than being coerced to a `Double` mantissa.
    /// - `String` is tried last among scalar types so it cannot shadow earlier cases.
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
        if let v = try? c.decode([AnyJSON].self)          { self = .array(v);  return }
        if let v = try? c.decode(Bool.self)               { self = .bool(v);   return }
        if let v = try? c.decode(Int.self)                { self = .int(v);    return }
        if let v = try? c.decode(Double.self)             { self = .number(v); return }
        if let v = try? c.decode(String.self)             { self = .string(v); return }
        if c.decodeNil()                                  { self = .null;      return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "AnyJSON: unrecognised value")
    }

    /// Encodes this `AnyJSON` value into the given encoder.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
}
