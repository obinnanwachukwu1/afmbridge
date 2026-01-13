// syslm-core/Types/StreamChunk.swift
// OpenRouter-compatible SSE streaming types
// Reference: https://openrouter.ai/docs/api/reference/streaming

import Foundation

// MARK: - Stream Chunk

/// A streaming chunk for SSE responses.
/// Reference: https://openrouter.ai/docs/api/reference/streaming
public struct StreamChunk: Codable, Sendable {
    /// Unique identifier for this completion
    public let id: String
    
    /// Object type (always "chat.completion.chunk")
    public let object: String
    
    /// Unix timestamp of when the chunk was created
    public let created: Int
    
    /// Model used for the completion
    public let model: String
    
    /// Array of choice deltas
    public let choices: [StreamChoice]
    
    /// Token usage (only in final chunk)
    public let usage: Usage?
    
    /// System fingerprint (if supported)
    public let systemFingerprint: String?
    
    private enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case model
        case choices
        case usage
        case systemFingerprint = "system_fingerprint"
    }
    
    public init(
        id: String,
        object: String = "chat.completion.chunk",
        created: Int,
        model: String,
        choices: [StreamChoice],
        usage: Usage? = nil,
        systemFingerprint: String? = nil
    ) {
        self.id = id
        self.object = object
        self.created = created
        self.model = model
        self.choices = choices
        self.usage = usage
        self.systemFingerprint = systemFingerprint
    }
}

// MARK: - Stream Choice

/// A streaming choice containing a delta update.
public struct StreamChoice: Codable, Sendable {
    /// Index of this choice
    public let index: Int
    
    /// The delta update
    public let delta: Delta
    
    /// Reason for finishing (only in final chunk)
    public let finishReason: FinishReason?
    
    /// Log probabilities (if requested)
    public let logprobs: Logprobs?
    
    private enum CodingKeys: String, CodingKey {
        case index
        case delta
        case finishReason = "finish_reason"
        case logprobs
    }
    
    public init(
        index: Int,
        delta: Delta,
        finishReason: FinishReason? = nil,
        logprobs: Logprobs? = nil
    ) {
        self.index = index
        self.delta = delta
        self.finishReason = finishReason
        self.logprobs = logprobs
    }
}

// MARK: - Delta

/// A delta update in a streaming chunk.
public struct Delta: Codable, Sendable {
    /// Role (only in first chunk)
    public let role: String?
    
    /// Content fragment
    public let content: String?
    
    /// Tool call fragments
    public let toolCalls: [StreamToolCall]?
    
    /// Refusal fragment
    public let refusal: String?
    
    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case refusal
    }
    
    public init(
        role: String? = nil,
        content: String? = nil,
        toolCalls: [StreamToolCall]? = nil,
        refusal: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.refusal = refusal
    }
    
    /// Create a role delta (first chunk)
    public static func role(_ role: String) -> Delta {
        Delta(role: role)
    }
    
    /// Create a content delta
    public static func text(_ content: String) -> Delta {
        Delta(content: content)
    }
    
    /// Create a tool call delta
    public static func toolCall(_ call: StreamToolCall) -> Delta {
        Delta(toolCalls: [call])
    }
    
    /// Create an empty delta (for finish chunks)
    public static var empty: Delta {
        Delta()
    }
}

// MARK: - Stream Tool Call

/// A tool call fragment in a streaming delta.
public struct StreamToolCall: Codable, Sendable {
    /// Index of this tool call (for parallel tool calls)
    public let index: Int
    
    /// Tool call ID (only in first chunk for this tool)
    public let id: String?
    
    /// Type (only in first chunk)
    public let type: String?
    
    /// Function call fragment
    public let function: StreamFunctionCall?
    
    public init(
        index: Int,
        id: String? = nil,
        type: String? = nil,
        function: StreamFunctionCall? = nil
    ) {
        self.index = index
        self.id = id
        self.type = type
        self.function = function
    }
    
    /// Create an initial tool call chunk (with ID and name)
    public static func initial(
        index: Int,
        id: String,
        name: String
    ) -> StreamToolCall {
        StreamToolCall(
            index: index,
            id: id,
            type: "function",
            function: StreamFunctionCall(name: name, arguments: nil)
        )
    }
    
    /// Create an arguments chunk
    public static func arguments(
        index: Int,
        arguments: String
    ) -> StreamToolCall {
        StreamToolCall(
            index: index,
            function: StreamFunctionCall(name: nil, arguments: arguments)
        )
    }
}

// MARK: - Stream Function Call

/// A function call fragment in a streaming tool call.
public struct StreamFunctionCall: Codable, Sendable {
    /// Function name (only in first chunk)
    public let name: String?
    
    /// Arguments fragment (accumulated across chunks)
    public let arguments: String?
    
    public init(name: String? = nil, arguments: String? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Stream Event

/// High-level stream event for easier handling.
public enum StreamEvent: Sendable {
    /// Role assignment (first chunk)
    case role(String)
    
    /// Text content fragment
    case content(String)
    
    /// Tool call update
    case toolCall(StreamToolCall)
    
    /// Stream finished
    case finish(FinishReason)
    
    /// Usage statistics (final chunk)
    case usage(Usage)
    
    /// Error during streaming
    case error(StreamError)
}

// MARK: - Stream Error

/// Error that can occur during streaming.
public struct StreamError: Codable, Sendable, Error {
    /// Error code
    public let code: String
    
    /// Error message
    public let message: String
    
    /// Additional metadata
    public let metadata: [String: JSONValue]?
    
    public init(code: String, message: String, metadata: [String: JSONValue]? = nil) {
        self.code = code
        self.message = message
        self.metadata = metadata
    }
}

// MARK: - Chunk Builder

/// Helper for building stream chunks.
public struct ChunkBuilder: Sendable {
    public let id: String
    public let created: Int
    public let model: String
    
    public init(id: String, created: Int? = nil, model: String) {
        self.id = id
        self.created = created ?? Int(Date().timeIntervalSince1970)
        self.model = model
    }
    
    /// Build a chunk with the given delta
    public func chunk(delta: Delta, finishReason: FinishReason? = nil, index: Int = 0) -> StreamChunk {
        StreamChunk(
            id: id,
            created: created,
            model: model,
            choices: [
                StreamChoice(index: index, delta: delta, finishReason: finishReason)
            ]
        )
    }
    
    /// Build a role chunk
    public func roleChunk(_ role: String) -> StreamChunk {
        chunk(delta: .role(role))
    }
    
    /// Build a content chunk
    public func contentChunk(_ content: String) -> StreamChunk {
        chunk(delta: .text(content))
    }
    
    /// Build a finish chunk
    public func finishChunk(_ reason: FinishReason, usage: Usage? = nil) -> StreamChunk {
        StreamChunk(
            id: id,
            created: created,
            model: model,
            choices: [
                StreamChoice(index: 0, delta: .empty, finishReason: reason)
            ],
            usage: usage
        )
    }
}

// MARK: - SSE Formatting

extension StreamChunk {
    /// Format as an SSE data line
    public func toSSELine() -> String? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return "data: \(json)\n\n"
    }
    
    /// The SSE done marker
    public static var doneMarker: String {
        "data: [DONE]\n\n"
    }
}
