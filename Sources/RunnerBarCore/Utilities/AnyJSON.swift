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
    /// - `Bool` is tried before `Double` because on Apple platforms `JSONDecoder` decodes
    ///   `true`/`false` as `Bool` — but if `Double` were tried first it would succeed for
    ///   any valid number, causing booleans to be misidentified as `.number(1.0)` / `.number(0.0)`.
    /// - `Int` is tried before `Double` so that integer-valued fields (e.g. `agentId`) are
    ///   stored losslessly as `.int` rather than being coerced to a `Double` mantissa.
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
        if let v = try? c.decode([AnyJSON].self)          { self = .array(v);  return }
        if let v = try? c.decode(String.self)             { self = .string(v); return }
        if let v = try? c.decode(Bool.self)               { self = .bool(v);   return }
        if let v = try? c.decode(Int.self)                { self = .int(v);    return }
        if let v = try? c.decode(Double.self)             { self = .number(v); return }
        if c.decodeNil()                                  { self = .null;      return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "AnyJSON: unrecognised value")
    }

    /// Encodes this `AnyJSON` value into the given encoder.
    func encode(to encoder: Encoder) throws {
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
