import Foundation

/// A JSON document. Parsing and printing go through JSONSerialization; this type only gives the
/// values a Sendable, pattern-matchable shape. Integers stay integers, so request ids and counts
/// round-trip unchanged.
public enum JSON: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Reading

    public subscript(key: String) -> JSON? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Whole numbers, including ones a client sent as 3.0.
    public var int: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value) where value.rounded() == value && abs(value) < 1e15: return Int(value)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    public var array: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: [String: JSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    // MARK: Foundation bridge

    /// From what JSONSerialization produces (or any plist-like value).
    public init(any value: Any) {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let text as String: self = .string(text)
        case let items as [Any]: self = .array(items.map(JSON.init(any:)))
        case let fields as [String: Any]: self = .object(fields.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    /// For JSONSerialization.
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .array(let items): return items.map(\.any)
        case .object(let fields): return fields.mapValues(\.any)
        }
    }

    public static func parse(_ text: String) -> JSON? {
        guard let data = text.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        return JSON(any: value)
    }

    /// One line of compact JSON with sorted keys; JSONSerialization escapes newlines in strings.
    public var text: String {
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
        else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension JSON: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var fields: [String: JSON] = [:]
        for (key, value) in elements { fields[key] = value }
        self = .object(fields)
    }
}
