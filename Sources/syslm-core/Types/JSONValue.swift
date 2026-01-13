// syslm-core/Types/JSONValue.swift
// Type-safe JSON value representation for dynamic JSON handling

import Foundation

/// A type-safe representation of any JSON value.
/// Used for handling dynamic JSON in requests and responses.
public enum JSONValue: Equatable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
            return
        }
        
        // Try bool first (before number, since Bool can be decoded as number)
        if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
            return
        }
        
        // Try integer before double for precision
        if let intValue = try? container.decode(Int.self) {
            self = .integer(intValue)
            return
        }
        
        if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
            return
        }
        
        if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
            return
        }
        
        if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
            return
        }
        
        if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
            return
        }
        
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Unable to decode JSON value"
        )
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - ExpressibleBy Literals

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .integer(value)
    }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .number(value)
    }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) {
        self = .array(elements)
    }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}

// MARK: - Accessors

extension JSONValue {
    /// Returns the string value if this is a `.string`, otherwise nil.
    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }
    
    /// Returns the double value, coercing from integer if needed.
    public var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        case .string(let value): return Double(value)
        default: return nil
        }
    }
    
    /// Returns the integer value if this is a `.integer` or `.number` with no fractional part.
    public var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return value.truncatingRemainder(dividingBy: 1) == 0 ? Int(value) : nil
        case .string(let value): return Int(value)
        default: return nil
        }
    }
    
    /// Returns the boolean value if this is a `.bool`.
    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value):
            switch value.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        case .integer(let value): return value != 0
        case .number(let value): return value != 0
        default: return nil
        }
    }
    
    /// Returns the array value if this is an `.array`.
    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
    
    /// Returns the object (dictionary) value if this is an `.object`.
    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    
    /// Returns true if this is `.null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Subscript Access

extension JSONValue {
    /// Access object properties by key.
    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let dict) = self else { return nil }
            return dict[key]
        }
    }
    
    /// Access array elements by index.
    public subscript(index: Int) -> JSONValue? {
        get {
            guard case .array(let arr) = self, index >= 0, index < arr.count else { return nil }
            return arr[index]
        }
    }
}

// MARK: - Conversion to/from Foundation Types

extension JSONValue {
    /// Initialize from any Foundation JSON-compatible value.
    public init?(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // Check if it's a boolean (CFBoolean)
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if number.doubleValue.truncatingRemainder(dividingBy: 1) == 0,
                      let intVal = Int(exactly: number) {
                self = .integer(intVal)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            let converted = array.compactMap { JSONValue(any: $0) }
            guard converted.count == array.count else { return nil }
            self = .array(converted)
        case let dict as [String: Any]:
            var converted: [String: JSONValue] = [:]
            for (key, val) in dict {
                guard let jsonVal = JSONValue(any: val) else { return nil }
                converted[key] = jsonVal
            }
            self = .object(converted)
        default:
            return nil
        }
    }
    
    /// Convert to Foundation-compatible Any type.
    public func toAny() -> Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .integer(let value): return value
        case .bool(let value): return value
        case .array(let value): return value.map { $0.toAny() }
        case .object(let value):
            var dict: [String: Any] = [:]
            for (key, val) in value {
                dict[key] = val.toAny()
            }
            return dict
        case .null: return NSNull()
        }
    }
}

// MARK: - JSON String Conversion

extension JSONValue {
    /// Convert to a compact JSON string.
    public func toJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Convert to a pretty-printed JSON string.
    public func toPrettyJSONString() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// Parse a JSON string into a JSONValue.
    public static func parse(_ jsonString: String) -> JSONValue? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - CustomStringConvertible

extension JSONValue: CustomStringConvertible {
    public var description: String {
        toJSONString() ?? "<invalid JSON>"
    }
}

// MARK: - CustomDebugStringConvertible

extension JSONValue: CustomDebugStringConvertible {
    public var debugDescription: String {
        toPrettyJSONString() ?? "<invalid JSON>"
    }
}
