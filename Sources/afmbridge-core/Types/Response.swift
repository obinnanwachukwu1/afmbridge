// afmbridge-core/Types/Response.swift
// OpenRouter-compatible chat completion response types
// Reference: https://openrouter.ai/docs/api/reference/overview

import Foundation

// MARK: - Chat Completion Response

/// OpenRouter-compatible chat completion response.
/// Reference: https://openrouter.ai/docs/api/reference/overview
public struct ChatCompletionResponse: Codable, Sendable {
    /// Unique identifier for this completion
    public let id: String
    
    /// Object type (always "chat.completion")
    public let object: String
    
    /// Unix timestamp of when the completion was created
    public let created: Int
    
    /// Model used for the completion
    public let model: String
    
    /// Array of completion choices
    public let choices: [Choice]
    
    /// Token usage statistics
    public let usage: Usage?
    
    /// System fingerprint (if supported by provider)
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
        object: String = "chat.completion",
        created: Int,
        model: String,
        choices: [Choice],
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
    
    /// Generate a unique completion ID
    public static func generateID() -> String {
        "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24)
    }
}

// MARK: - Choice

/// A completion choice from the model.
public struct Choice: Codable, Sendable {
    /// Index of this choice
    public let index: Int
    
    /// The generated message
    public let message: ResponseMessage
    
    /// Reason for finishing generation
    public let finishReason: FinishReason?
    
    /// Native finish reason from the provider (if different)
    public let nativeFinishReason: String?
    
    /// Log probabilities (if requested)
    public let logprobs: Logprobs?
    
    private enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
        case nativeFinishReason = "native_finish_reason"
        case logprobs
    }
    
    public init(
        index: Int,
        message: ResponseMessage,
        finishReason: FinishReason?,
        nativeFinishReason: String? = nil,
        logprobs: Logprobs? = nil
    ) {
        self.index = index
        self.message = message
        self.finishReason = finishReason
        self.nativeFinishReason = nativeFinishReason
        self.logprobs = logprobs
    }
}

// MARK: - Response Message

/// The assistant's response message.
public struct ResponseMessage: Codable, Sendable {
    /// Role (always "assistant" for responses)
    public let role: String
    
    /// Text content of the response
    public let content: String?
    
    /// Tool calls requested by the assistant
    public let toolCalls: [ResponseToolCall]?
    
    /// Refusal message (if the model refused the request)
    public let refusal: String?
    
    private enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
        case refusal
    }
    
    public init(
        role: String = "assistant",
        content: String? = nil,
        toolCalls: [ResponseToolCall]? = nil,
        refusal: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.refusal = refusal
    }
    
    /// Create a simple text response
    public static func text(_ content: String) -> ResponseMessage {
        ResponseMessage(content: content)
    }
    
    /// Create a tool calls response
    public static func toolCalls(_ calls: [ResponseToolCall]) -> ResponseMessage {
        ResponseMessage(content: nil, toolCalls: calls)
    }
}

// MARK: - Response Tool Call

/// A tool call in the response.
/// Note: This is separate from the request ToolCall to allow for different encoding.
public struct ResponseToolCall: Codable, Sendable {
    /// Unique identifier for this tool call
    public let id: String
    
    /// Type of tool (always "function")
    public let type: String
    
    /// The function call details
    public let function: ResponseFunctionCall
    
    public init(id: String, type: String = "function", function: ResponseFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
    
    /// Convenience initializer
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = ResponseFunctionCall(name: name, arguments: arguments)
    }
    
    /// Generate a unique tool call ID
    public static func generateID() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let suffix = String((0..<24).compactMap { _ in chars.randomElement() })
        return "call_" + suffix
    }
}

// MARK: - Response Function Call

/// Details of a function call in the response.
public struct ResponseFunctionCall: Codable, Sendable {
    /// Name of the function to call
    public let name: String
    
    /// Arguments as a JSON string
    public let arguments: String
    
    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

// MARK: - Finish Reason

/// Reason why the model stopped generating.
/// Reference: https://openrouter.ai/docs/api/reference/overview
public enum FinishReason: String, Codable, Sendable {
    /// Natural stop (end of response or stop sequence hit)
    case stop
    
    /// Model requested tool calls
    case toolCalls = "tool_calls"
    
    /// Max tokens limit reached
    case length
    
    /// Content was filtered
    case contentFilter = "content_filter"
    
    /// An error occurred during generation
    case error
    
    /// Function call (legacy, same as tool_calls)
    case functionCall = "function_call"
}

// MARK: - Usage

/// Token usage statistics.
public struct Usage: Codable, Sendable {
    /// Tokens in the prompt
    public let promptTokens: Int
    
    /// Tokens in the completion
    public let completionTokens: Int
    
    /// Total tokens used
    public let totalTokens: Int
    
    /// Cached prompt tokens (if applicable)
    public let cachedTokens: Int?
    
    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cachedTokens = "cached_tokens"
    }
    
    public init(
        promptTokens: Int,
        completionTokens: Int,
        totalTokens: Int? = nil,
        cachedTokens: Int? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens ?? (promptTokens + completionTokens)
        self.cachedTokens = cachedTokens
    }
}

// MARK: - Logprobs

/// Log probability information (placeholder - implement as needed).
public struct Logprobs: Codable, Sendable {
    public let content: [TokenLogprob]?
    
    public init(content: [TokenLogprob]? = nil) {
        self.content = content
    }
}

/// Log probability for a single token.
public struct TokenLogprob: Codable, Sendable {
    public let token: String
    public let logprob: Double
    public let bytes: [Int]?
    public let topLogprobs: [TopLogprob]?
    
    private enum CodingKeys: String, CodingKey {
        case token
        case logprob
        case bytes
        case topLogprobs = "top_logprobs"
    }
    
    public init(
        token: String,
        logprob: Double,
        bytes: [Int]? = nil,
        topLogprobs: [TopLogprob]? = nil
    ) {
        self.token = token
        self.logprob = logprob
        self.bytes = bytes
        self.topLogprobs = topLogprobs
    }
}

/// Alternative tokens with their log probabilities.
public struct TopLogprob: Codable, Sendable {
    public let token: String
    public let logprob: Double
    public let bytes: [Int]?
    
    public init(token: String, logprob: Double, bytes: [Int]? = nil) {
        self.token = token
        self.logprob = logprob
        self.bytes = bytes
    }
}
