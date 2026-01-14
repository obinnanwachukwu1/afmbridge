// afmbridge-core/Types/JSONSchema.swift
// JSON Schema representation for structured outputs and tool parameters

import Foundation

/// Represents a JSON Schema object.
/// Used for defining tool parameters and structured output schemas.
/// Reference: https://json-schema.org/understanding-json-schema/
public struct JSONSchema: Codable, Equatable, Hashable, Sendable {
    public let type: SchemaType?
    public let description: String?
    public let properties: [String: JSONSchema]?
    public let required: [String]?
    public let additionalProperties: AdditionalProperties?
    public let items: Box<JSONSchema>?
    public let `enum`: [JSONValue]?
    public let const: JSONValue?
    public let format: String?
    public let minimum: Double?
    public let maximum: Double?
    public let minLength: Int?
    public let maxLength: Int?
    public let minItems: Int?
    public let maxItems: Int?
    public let uniqueItems: Bool?
    public let pattern: String?
    public let `default`: JSONValue?
    public let title: String?
    public let anyOf: [JSONSchema]?
    public let oneOf: [JSONSchema]?
    public let allOf: [JSONSchema]?
    public let not: Box<JSONSchema>?
    
    /// The JSON Schema type
    public enum SchemaType: String, Codable, Sendable {
        case string
        case number
        case integer
        case boolean
        case object
        case array
        case null
    }
    
    /// Additional properties can be a boolean or a schema
    public indirect enum AdditionalProperties: Codable, Equatable, Hashable, Sendable {
        case bool(Bool)
        case schema(JSONSchema)
        
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let boolValue = try? container.decode(Bool.self) {
                self = .bool(boolValue)
            } else {
                self = .schema(try container.decode(JSONSchema.self))
            }
        }
        
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .bool(let value):
                try container.encode(value)
            case .schema(let value):
                try container.encode(value)
            }
        }
    }
    
    /// Box wrapper for recursive schema references
    public final class Box<T: Codable & Equatable & Hashable & Sendable>: Codable, Equatable, Hashable, Sendable {
        public let value: T
        
        public init(_ value: T) {
            self.value = value
        }
        
        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.value = try container.decode(T.self)
        }
        
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
        
        public static func == (lhs: Box<T>, rhs: Box<T>) -> Bool {
            lhs.value == rhs.value
        }
        
        public func hash(into hasher: inout Hasher) {
            hasher.combine(value)
        }
    }
    
    // MARK: - Coding Keys
    
    private enum CodingKeys: String, CodingKey {
        case type
        case description
        case properties
        case required
        case additionalProperties
        case items
        case `enum`
        case const
        case format
        case minimum
        case maximum
        case minLength
        case maxLength
        case minItems
        case maxItems
        case uniqueItems
        case pattern
        case `default`
        case title
        case anyOf
        case oneOf
        case allOf
        case not
    }
    
    // MARK: - Initializers
    
    public init(
        type: SchemaType? = nil,
        description: String? = nil,
        properties: [String: JSONSchema]? = nil,
        required: [String]? = nil,
        additionalProperties: AdditionalProperties? = nil,
        items: JSONSchema? = nil,
        enum: [JSONValue]? = nil,
        const: JSONValue? = nil,
        format: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        uniqueItems: Bool? = nil,
        pattern: String? = nil,
        default: JSONValue? = nil,
        title: String? = nil,
        anyOf: [JSONSchema]? = nil,
        oneOf: [JSONSchema]? = nil,
        allOf: [JSONSchema]? = nil,
        not: JSONSchema? = nil
    ) {
        self.type = type
        self.description = description
        self.properties = properties
        self.required = required
        self.additionalProperties = additionalProperties
        self.items = items.map { Box($0) }
        self.enum = `enum`
        self.const = const
        self.format = format
        self.minimum = minimum
        self.maximum = maximum
        self.minLength = minLength
        self.maxLength = maxLength
        self.minItems = minItems
        self.maxItems = maxItems
        self.uniqueItems = uniqueItems
        self.pattern = pattern
        self.default = `default`
        self.title = title
        self.anyOf = anyOf
        self.oneOf = oneOf
        self.allOf = allOf
        self.not = not.map { Box($0) }
    }
}

// MARK: - Convenience Builders

extension JSONSchema {
    /// Create a string schema
    public static func string(
        description: String? = nil,
        enum: [String]? = nil,
        minLength: Int? = nil,
        maxLength: Int? = nil,
        pattern: String? = nil,
        format: String? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: .string,
            description: description,
            enum: `enum`?.map { .string($0) },
            format: format,
            minLength: minLength,
            maxLength: maxLength,
            pattern: pattern
        )
    }
    
    /// Create a number schema
    public static func number(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: .number,
            description: description,
            minimum: minimum,
            maximum: maximum
        )
    }
    
    /// Create an integer schema
    public static func integer(
        description: String? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: .integer,
            description: description,
            minimum: minimum,
            maximum: maximum
        )
    }
    
    /// Create a boolean schema
    public static func boolean(description: String? = nil) -> JSONSchema {
        JSONSchema(type: .boolean, description: description)
    }
    
    /// Create an object schema
    public static func object(
        description: String? = nil,
        properties: [String: JSONSchema],
        required: [String]? = nil,
        additionalProperties: Bool = false
    ) -> JSONSchema {
        JSONSchema(
            type: .object,
            description: description,
            properties: properties,
            required: required ?? Array(properties.keys),
            additionalProperties: .bool(additionalProperties)
        )
    }
    
    /// Create an array schema
    public static func array(
        description: String? = nil,
        items: JSONSchema,
        minItems: Int? = nil,
        maxItems: Int? = nil,
        uniqueItems: Bool? = nil
    ) -> JSONSchema {
        JSONSchema(
            type: .array,
            description: description,
            items: items,
            minItems: minItems,
            maxItems: maxItems,
            uniqueItems: uniqueItems
        )
    }
    
    /// Create a null schema
    public static var null: JSONSchema {
        JSONSchema(type: .null)
    }
}

// MARK: - Debug Description

extension JSONSchema {
    /// Returns a pretty-printed JSON representation of the schema
    public var schemaDescription: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "<invalid schema>"
        }
        return string
    }
}
