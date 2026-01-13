// syslm-core/Types/Request.swift
// OpenRouter-compatible chat completion request types
// Reference: https://openrouter.ai/docs/api/reference/overview

import Foundation

// MARK: - Chat Completion Request

/// OpenRouter-compatible chat completion request.
/// Reference: https://openrouter.ai/docs/api/reference/overview
public struct ChatCompletionRequest: Codable, Sendable {
    /// Model identifier (optional, uses default if not specified)
    public let model: String?
    
    /// The messages to send to the model
    public let messages: [Message]
    
    /// Whether to stream the response
    public let stream: Bool?
    
    // MARK: - Generation Parameters
    
    /// Sampling temperature (0.0-2.0, default 1.0)
    /// Higher values = more random, lower = more deterministic
    public let temperature: Double?
    
    /// Nucleus sampling (0.0-1.0, default 1.0)
    /// Only consider tokens with cumulative probability up to top_p
    public let topP: Double?
    
    /// Top-K sampling (default disabled)
    /// Only consider the top K most likely tokens
    public let topK: Int?
    
    /// Maximum tokens to generate in the response
    public let maxTokens: Int?
    
    /// Stop sequences - generation stops when any of these are produced
    public let stop: StopSequence?
    
    /// Random seed for deterministic generation
    public let seed: Int?
    
    /// Frequency penalty (-2.0 to 2.0, default 0.0)
    /// Penalize tokens based on their frequency in the text so far
    public let frequencyPenalty: Double?
    
    /// Presence penalty (-2.0 to 2.0, default 0.0)
    /// Penalize tokens that have appeared in the text at all
    public let presencePenalty: Double?
    
    /// Repetition penalty (0.0-2.0, default 1.0)
    public let repetitionPenalty: Double?
    
    /// Min-P sampling (0.0-1.0, default 0.0)
    public let minP: Double?
    
    /// Top-A sampling (0.0-1.0, default 0.0)
    public let topA: Double?
    
    // MARK: - Tool Calling
    
    /// Available tools for the model to call
    public let tools: [Tool]?
    
    /// How the model should choose which tool to call
    public let toolChoice: ToolChoice?
    
    /// Whether to allow parallel tool calls (default true)
    public let parallelToolCalls: Bool?
    
    // MARK: - Structured Output
    
    /// Response format constraints
    public let responseFormat: ResponseFormat?
    
    // MARK: - Coding Keys
    
    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case maxTokens = "max_tokens"
        case stop
        case seed
        case frequencyPenalty = "frequency_penalty"
        case presencePenalty = "presence_penalty"
        case repetitionPenalty = "repetition_penalty"
        case minP = "min_p"
        case topA = "top_a"
        case tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
        case responseFormat = "response_format"
    }
    
    // MARK: - Initializer
    
    public init(
        model: String? = nil,
        messages: [Message],
        stream: Bool? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        maxTokens: Int? = nil,
        stop: StopSequence? = nil,
        seed: Int? = nil,
        frequencyPenalty: Double? = nil,
        presencePenalty: Double? = nil,
        repetitionPenalty: Double? = nil,
        minP: Double? = nil,
        topA: Double? = nil,
        tools: [Tool]? = nil,
        toolChoice: ToolChoice? = nil,
        parallelToolCalls: Bool? = nil,
        responseFormat: ResponseFormat? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
        self.stop = stop
        self.seed = seed
        self.frequencyPenalty = frequencyPenalty
        self.presencePenalty = presencePenalty
        self.repetitionPenalty = repetitionPenalty
        self.minP = minP
        self.topA = topA
        self.tools = tools
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.responseFormat = responseFormat
    }
}

// MARK: - Stop Sequence

/// Stop sequence can be a single string or an array of strings
public enum StopSequence: Codable, Equatable, Sendable {
    case single(String)
    case multiple([String])
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let single = try? container.decode(String.self) {
            self = .single(single)
        } else {
            self = .multiple(try container.decode([String].self))
        }
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .single(let value):
            try container.encode(value)
        case .multiple(let values):
            try container.encode(values)
        }
    }
    
    /// Get all stop sequences as an array
    public var sequences: [String] {
        switch self {
        case .single(let s): return [s]
        case .multiple(let arr): return arr
        }
    }
}

// MARK: - Message

/// A message in the conversation.
/// Reference: https://openrouter.ai/docs/api/reference/overview
public struct Message: Codable, Equatable, Sendable {
    /// The role of the message author
    public let role: Role
    
    /// The content of the message (can be text or multipart)
    public let content: MessageContent?
    
    /// Optional name for the participant
    public let name: String?
    
    /// Tool calls made by the assistant (only for assistant messages)
    public let toolCalls: [ToolCall]?
    
    /// ID of the tool call this message is responding to (only for tool messages)
    public let toolCallId: String?
    
    /// Message roles
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }
    
    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case name
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }
    
    public init(
        role: Role,
        content: MessageContent?,
        name: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolCallId: String? = nil
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
    
    // MARK: - Convenience Initializers
    
    /// Create a system message
    public static func system(_ content: String) -> Message {
        Message(role: .system, content: .text(content))
    }
    
    /// Create a user message
    public static func user(_ content: String) -> Message {
        Message(role: .user, content: .text(content))
    }
    
    /// Create an assistant message
    public static func assistant(_ content: String) -> Message {
        Message(role: .assistant, content: .text(content))
    }
    
    /// Create an assistant message with tool calls
    public static func assistant(toolCalls: [ToolCall]) -> Message {
        Message(role: .assistant, content: nil, toolCalls: toolCalls)
    }
    
    /// Create a tool result message
    public static func tool(callId: String, content: String) -> Message {
        Message(role: .tool, content: .text(content), toolCallId: callId)
    }
}

// MARK: - Message Content

/// Message content can be a simple string or an array of content parts.
public enum MessageContent: Codable, Equatable, Sendable {
    case text(String)
    case parts([ContentPart])
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([ContentPart].self))
        }
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let value):
            try container.encode(value)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
    
    /// Get the text content (concatenated if multipart)
    public var textValue: String? {
        switch self {
        case .text(let s): return s
        case .parts(let parts):
            let texts = parts.compactMap { part -> String? in
                if case .text(let t) = part { return t.text }
                return nil
            }
            return texts.isEmpty ? nil : texts.joined()
        }
    }
}

// MARK: - Content Part

/// A part of a multimodal message
public enum ContentPart: Codable, Equatable, Sendable {
    case text(TextContent)
    case imageUrl(ImageContent)
    
    public struct TextContent: Codable, Equatable, Sendable {
        public let type: String
        public let text: String
        
        public init(text: String) {
            self.type = "text"
            self.text = text
        }
    }
    
    public struct ImageContent: Codable, Equatable, Sendable {
        public let type: String
        public let imageUrl: ImageURL
        
        public struct ImageURL: Codable, Equatable, Sendable {
            public let url: String
            public let detail: String?
            
            public init(url: String, detail: String? = nil) {
                self.url = url
                self.detail = detail
            }
        }
        
        private enum CodingKeys: String, CodingKey {
            case type
            case imageUrl = "image_url"
        }
        
        public init(url: String, detail: String? = nil) {
            self.type = "image_url"
            self.imageUrl = ImageURL(url: url, detail: detail)
        }
    }
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: TypeCodingKey.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "text":
            self = .text(try TextContent(from: decoder))
        case "image_url":
            self = .imageUrl(try ImageContent(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown content part type: \(type)"
            )
        }
    }
    
    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .text(let content):
            try content.encode(to: encoder)
        case .imageUrl(let content):
            try content.encode(to: encoder)
        }
    }
    
    private enum TypeCodingKey: String, CodingKey {
        case type
    }
}

// MARK: - Tool

/// A tool that the model can call.
/// Reference: https://openrouter.ai/docs/guides/features/tool-calling
public struct Tool: Codable, Equatable, Sendable {
    /// The type of tool (always "function")
    public let type: String
    
    /// The function definition
    public let function: FunctionDefinition
    
    public init(function: FunctionDefinition) {
        self.type = "function"
        self.function = function
    }
    
    /// Convenience initializer
    public init(
        name: String,
        description: String? = nil,
        parameters: JSONSchema? = nil
    ) {
        self.type = "function"
        self.function = FunctionDefinition(
            name: name,
            description: description,
            parameters: parameters
        )
    }
}

// MARK: - Function Definition

/// Definition of a callable function tool.
public struct FunctionDefinition: Codable, Equatable, Sendable {
    /// The name of the function
    public let name: String
    
    /// Description of what the function does
    public let description: String?
    
    /// JSON Schema defining the function parameters
    public let parameters: JSONSchema?
    
    public init(
        name: String,
        description: String? = nil,
        parameters: JSONSchema? = nil
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

// MARK: - Tool Choice

/// Controls how the model chooses which tool to call.
/// Reference: https://openrouter.ai/docs/guides/features/tool-calling
public enum ToolChoice: Codable, Equatable, Sendable {
    /// Model will not call any tools
    case none
    
    /// Model decides whether to call tools
    case auto
    
    /// Model must call at least one tool
    case required
    
    /// Model must call the specified function
    case function(name: String)
    
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        // Try string values first
        if let stringValue = try? container.decode(String.self) {
            switch stringValue.lowercased() {
            case "none":
                self = .none
            case "auto":
                self = .auto
            case "required":
                self = .required
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown tool_choice string: \(stringValue)"
                )
            }
            return
        }
        
        // Try object form: {"type": "function", "function": {"name": "..."}}
        let object = try container.decode(ToolChoiceObject.self)
        if object.type == "function", let functionObj = object.function {
            self = .function(name: functionObj.name)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid tool_choice object"
            )
        }
    }
    
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .none:
            try container.encode("none")
        case .auto:
            try container.encode("auto")
        case .required:
            try container.encode("required")
        case .function(let name):
            try container.encode(ToolChoiceObject(
                type: "function",
                function: ToolChoiceObject.FunctionRef(name: name)
            ))
        }
    }
    
    private struct ToolChoiceObject: Codable {
        let type: String
        let function: FunctionRef?
        
        struct FunctionRef: Codable {
            let name: String
        }
    }
}

// MARK: - Tool Call (Request)

/// A tool call made by the assistant in a previous message.
/// Used when including assistant messages with tool calls in the request.
public struct ToolCall: Codable, Equatable, Sendable {
    /// Unique identifier for the tool call
    public let id: String
    
    /// The type of tool (always "function")
    public let type: String
    
    /// The function call details
    public let function: FunctionCall
    
    public init(id: String, type: String = "function", function: FunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
    
    /// Convenience initializer
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = FunctionCall(name: name, arguments: arguments)
    }
}

// MARK: - Function Call

/// Details of a function call.
public struct FunctionCall: Codable, Equatable, Sendable {
    /// The name of the function to call
    public let name: String
    
    /// The arguments as a JSON string
    public let arguments: String
    
    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
    
    /// Parse the arguments JSON string into a dictionary
    public func parseArguments() -> [String: JSONValue]? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let dict) = json else {
            return nil
        }
        return dict
    }
}

// MARK: - Response Format

/// Constraints on the response format.
/// Reference: https://openrouter.ai/docs/guides/features/structured-outputs
public struct ResponseFormat: Codable, Equatable, Sendable {
    /// The format type
    public let type: FormatType
    
    /// The JSON schema specification (for json_schema type)
    public let jsonSchema: JSONSchemaSpec?
    
    /// Format types
    public enum FormatType: String, Codable, Sendable {
        case jsonObject = "json_object"
        case jsonSchema = "json_schema"
        case text
    }
    
    private enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
    
    public init(type: FormatType, jsonSchema: JSONSchemaSpec? = nil) {
        self.type = type
        self.jsonSchema = jsonSchema
    }
    
    /// Create a JSON object format (model returns valid JSON)
    public static var jsonObject: ResponseFormat {
        ResponseFormat(type: .jsonObject)
    }
    
    /// Create a JSON schema format with strict validation
    public static func jsonSchema(
        name: String,
        schema: JSONSchema,
        strict: Bool = true
    ) -> ResponseFormat {
        ResponseFormat(
            type: .jsonSchema,
            jsonSchema: JSONSchemaSpec(name: name, strict: strict, schema: schema)
        )
    }
}

// MARK: - JSON Schema Spec

/// JSON Schema specification for structured outputs.
public struct JSONSchemaSpec: Codable, Equatable, Sendable {
    /// Name for the schema
    public let name: String
    
    /// Whether to enforce strict schema validation
    public let strict: Bool?
    
    /// The JSON Schema definition
    public let schema: JSONSchema
    
    public init(name: String, strict: Bool? = true, schema: JSONSchema) {
        self.name = name
        self.strict = strict
        self.schema = schema
    }
}
