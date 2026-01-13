// syslm-core/Engine/SchemaConverter.swift
// Converts OpenRouter JSON Schema to Apple's DynamicGenerationSchema

import Foundation
import FoundationModels

/// Converts OpenRouter-style JSON Schema to Apple's DynamicGenerationSchema for guided generation.
/// Reference: https://developer.apple.com/documentation/foundationmodels/dynamicgenerationschema
public struct SchemaConverter {
    
    /// Error during schema conversion
    public enum ConversionError: Error, LocalizedError {
        case unsupportedType(String)
        case missingType
        case invalidSchema(String)
        case nestedSchemaError(String, Error)
        
        public var errorDescription: String? {
            switch self {
            case .unsupportedType(let type):
                return "Unsupported schema type: \(type)"
            case .missingType:
                return "Schema is missing 'type' field"
            case .invalidSchema(let reason):
                return "Invalid schema: \(reason)"
            case .nestedSchemaError(let path, let error):
                return "Error at \(path): \(error.localizedDescription)"
            }
        }
    }
    
    /// Convert a JSONSchemaSpec to a GenerationSchema
    /// - Parameter spec: The OpenRouter JSON Schema specification
    /// - Returns: Apple's GenerationSchema for use with LanguageModelSession
    public static func convert(_ spec: JSONSchemaSpec) throws -> GenerationSchema {
        let dynamicSchema = try convertToDynamic(spec.schema, name: spec.name)
        return try GenerationSchema(root: dynamicSchema, dependencies: [])
    }
    
    /// Convert JSONSchema to DynamicGenerationSchema
    /// - Parameters:
    ///   - schema: The JSON Schema to convert
    ///   - name: Name for the schema (required for object types)
    /// - Returns: A DynamicGenerationSchema
    public static func convertToDynamic(_ schema: JSONSchema, name: String? = nil) throws -> DynamicGenerationSchema {
        guard let type = schema.type else {
            // Check for anyOf/oneOf/allOf
            if let anyOf = schema.anyOf {
                let schemas = try anyOf.map { try convertToDynamic($0) }
                return DynamicGenerationSchema(name: name ?? "AnyOf", description: schema.description, anyOf: schemas)
            }
            throw ConversionError.missingType
        }
        
        switch type {
        case .object:
            return try convertObject(schema, name: name ?? "Object")
        case .array:
            return try convertArray(schema)
        case .string:
            return convertString(schema)
        case .number:
            return convertNumber(schema)
        case .integer:
            return convertInteger(schema)
        case .boolean:
            return convertBoolean(schema)
        case .null:
            // Null is not directly representable in FoundationModels schemas
            // Treat as empty string placeholder
            return DynamicGenerationSchema(type: String.self)
        }
    }
    
    // MARK: - Type Converters
    
    private static func convertObject(_ schema: JSONSchema, name: String) throws -> DynamicGenerationSchema {
        var properties: [DynamicGenerationSchema.Property] = []
        let requiredFields = Set(schema.required ?? [])
        
        if let props = schema.properties {
            for (propName, propSchema) in props {
                let isOptional = !requiredFields.contains(propName)
                let propDynamic = try convertToDynamic(propSchema, name: propName.capitalized)
                
                let property = DynamicGenerationSchema.Property(
                    name: propName,
                    description: propSchema.description,
                    schema: propDynamic,
                    isOptional: isOptional
                )
                properties.append(property)
            }
        }
        
        return DynamicGenerationSchema(
            name: name,
            description: schema.description,
            properties: properties
        )
    }
    
    private static func convertArray(_ schema: JSONSchema) throws -> DynamicGenerationSchema {
        guard let itemsBox = schema.items else {
            // Array without items schema - default to string array
            return DynamicGenerationSchema(
                arrayOf: DynamicGenerationSchema(type: String.self),
                minimumElements: schema.minItems,
                maximumElements: schema.maxItems
            )
        }
        
        let itemSchema = try convertToDynamic(itemsBox.value, name: "Item")
        return DynamicGenerationSchema(
            arrayOf: itemSchema,
            minimumElements: schema.minItems,
            maximumElements: schema.maxItems
        )
    }
    
    private static func convertString(_ schema: JSONSchema) -> DynamicGenerationSchema {
        // Check for enum
        if let enumValues = schema.enum {
            let stringValues = enumValues.compactMap { value -> String? in
                if case .string(let s) = value { return s }
                return nil
            }
            if !stringValues.isEmpty {
                // Use anyOf guide to restrict to enum values
                return DynamicGenerationSchema(
                    type: String.self,
                    guides: [.anyOf(stringValues)]
                )
            }
        }
        
        // Regular string
        return DynamicGenerationSchema(type: String.self)
    }
    
    private static func convertNumber(_ schema: JSONSchema) -> DynamicGenerationSchema {
        if let min = schema.minimum, let max = schema.maximum {
            return DynamicGenerationSchema(
                type: Double.self,
                guides: [.range(min...max)]
            )
        } else if let min = schema.minimum {
            return DynamicGenerationSchema(
                type: Double.self,
                guides: [.range(min...Double.greatestFiniteMagnitude)]
            )
        } else if let max = schema.maximum {
            return DynamicGenerationSchema(
                type: Double.self,
                guides: [.range(-Double.greatestFiniteMagnitude...max)]
            )
        }
        return DynamicGenerationSchema(type: Double.self)
    }
    
    private static func convertInteger(_ schema: JSONSchema) -> DynamicGenerationSchema {
        if let min = schema.minimum, let max = schema.maximum {
            return DynamicGenerationSchema(
                type: Int.self,
                guides: [.range(Int(min)...Int(max))]
            )
        } else if let min = schema.minimum {
            return DynamicGenerationSchema(
                type: Int.self,
                guides: [.range(Int(min)...Int.max)]
            )
        } else if let max = schema.maximum {
            return DynamicGenerationSchema(
                type: Int.self,
                guides: [.range(Int.min...Int(max))]
            )
        }
        return DynamicGenerationSchema(type: Int.self)
    }
    
    private static func convertBoolean(_ schema: JSONSchema) -> DynamicGenerationSchema {
        DynamicGenerationSchema(type: Bool.self)
    }
}
