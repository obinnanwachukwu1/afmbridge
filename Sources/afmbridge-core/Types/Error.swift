// afmbridge-core/Types/Error.swift
// OpenRouter-compatible error types
// Reference: https://openrouter.ai/docs/api/reference/errors-and-debugging

import Foundation

// MARK: - Error Response

/// OpenRouter-compatible error response wrapper.
/// Reference: https://openrouter.ai/docs/api/reference/errors-and-debugging
public struct ErrorResponse: Codable, Sendable {
    /// The error details
    public let error: ErrorDetail
    
    public init(error: ErrorDetail) {
        self.error = error
    }
    
    public init(code: Int, message: String, type: String? = nil, param: String? = nil) {
        self.error = ErrorDetail(code: code, message: message, type: type, param: param)
    }
}

// MARK: - Error Detail

/// Details of an API error.
public struct ErrorDetail: Codable, Sendable {
    /// HTTP status code
    public let code: Int
    
    /// Human-readable error message
    public let message: String
    
    /// Error type classification
    public let type: String?
    
    /// Parameter that caused the error
    public let param: String?
    
    /// Additional metadata
    public let metadata: [String: String]?
    
    public init(
        code: Int,
        message: String,
        type: String? = nil,
        param: String? = nil,
        metadata: [String: String]? = nil
    ) {
        self.code = code
        self.message = message
        self.type = type
        self.param = param
        self.metadata = metadata
    }
}

// MARK: - API Error

/// High-level API error types.
/// Reference: https://openrouter.ai/docs/api/reference/errors-and-debugging
public enum APIError: Error, Sendable {
    /// 400 - Bad request (invalid parameters, malformed JSON, etc.)
    case badRequest(String, param: String? = nil)
    
    /// 401 - Unauthorized (invalid or missing API key)
    case unauthorized(String)
    
    /// 402 - Payment required (insufficient credits)
    case paymentRequired(String)
    
    /// 403 - Forbidden (access denied)
    case forbidden(String)
    
    /// 404 - Not found (invalid endpoint or model)
    case notFound(String)
    
    /// 429 - Rate limited (too many requests)
    case rateLimited(String, retryAfter: Int? = nil)
    
    /// 500 - Internal server error
    case internalError(String)
    
    /// 502 - Bad gateway (provider error)
    case providerError(String, provider: String? = nil)
    
    /// 503 - Service unavailable (model unavailable)
    case serviceUnavailable(String)
    
    /// 504 - Gateway timeout
    case timeout(String)
    
    /// Model-specific error
    case modelError(String, model: String)
    
    /// Validation error
    case validationError(String, field: String)
    
    /// Context window exceeded
    case contextWindowExceeded(String)
    
    /// Content filtered
    case contentFiltered(String)
    
    /// Streaming error
    case streamingError(String)
}

extension APIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badRequest(let msg, _): return msg
        case .unauthorized(let msg): return msg
        case .paymentRequired(let msg): return msg
        case .forbidden(let msg): return msg
        case .notFound(let msg): return msg
        case .rateLimited(let msg, _): return msg
        case .internalError(let msg): return msg
        case .providerError(let msg, _): return msg
        case .serviceUnavailable(let msg): return msg
        case .timeout(let msg): return msg
        case .modelError(let msg, _): return msg
        case .validationError(let msg, _): return msg
        case .contextWindowExceeded(let msg): return msg
        case .contentFiltered(let msg): return msg
        case .streamingError(let msg): return msg
        }
    }
}

extension APIError {
    /// HTTP status code for this error
    public var statusCode: Int {
        switch self {
        case .badRequest: return 400
        case .unauthorized: return 401
        case .paymentRequired: return 402
        case .forbidden: return 403
        case .notFound: return 404
        case .rateLimited: return 429
        case .internalError: return 500
        case .providerError: return 502
        case .serviceUnavailable: return 503
        case .timeout: return 504
        case .modelError: return 400
        case .validationError: return 400
        case .contextWindowExceeded: return 400
        case .contentFiltered: return 400
        case .streamingError: return 500
        }
    }
    
    /// Error type string
    public var errorType: String {
        switch self {
        case .badRequest: return "invalid_request_error"
        case .unauthorized: return "authentication_error"
        case .paymentRequired: return "insufficient_funds_error"
        case .forbidden: return "permission_denied_error"
        case .notFound: return "not_found_error"
        case .rateLimited: return "rate_limit_error"
        case .internalError: return "internal_error"
        case .providerError: return "provider_error"
        case .serviceUnavailable: return "service_unavailable_error"
        case .timeout: return "timeout_error"
        case .modelError: return "model_error"
        case .validationError: return "validation_error"
        case .contextWindowExceeded: return "context_length_exceeded"
        case .contentFiltered: return "content_filter_error"
        case .streamingError: return "streaming_error"
        }
    }
    
    /// Parameter that caused the error (if applicable)
    public var param: String? {
        switch self {
        case .badRequest(_, let param): return param
        case .validationError(_, let field): return field
        case .modelError(_, let model): return "model: \(model)"
        default: return nil
        }
    }
    
    /// Convert to ErrorResponse for JSON encoding
    public func toErrorResponse() -> ErrorResponse {
        ErrorResponse(error: ErrorDetail(
            code: statusCode,
            message: errorDescription ?? "Unknown error",
            type: errorType,
            param: param
        ))
    }
    
    /// Encode to JSON data
    public func toJSONData() -> Data? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try? encoder.encode(toErrorResponse())
    }
}

// MARK: - Chat Engine Error

/// Errors specific to the chat engine.
public enum ChatEngineError: Error, Sendable {
    /// Messages array is empty
    case emptyMessages
    
    /// Model is not available on this device
    case modelUnavailable(String)
    
    /// Last message must be from user or tool
    case lastMessageNotUser
    
    /// Invalid tool choice (tool not in tools array)
    case invalidToolChoice(String)
    
    /// Invalid JSON schema
    case invalidSchema(String)
    
    /// Streaming not supported for this request
    case streamingUnsupported(String)
    
    /// Invalid message format
    case invalidMessage(String)
    
    /// Tool call validation failed
    case invalidToolCall(String)
    
    /// Response parsing failed
    case responseParseFailed(String)
    
    /// Generation was refused by the model
    case refused(String)
    
    /// Context window exceeded
    case contextExceeded(used: Int, limit: Int)
    
    /// Queue is full
    case queueFull
}

extension ChatEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyMessages:
            return "messages[] is empty"
        case .modelUnavailable(let reason):
            return "SystemLanguageModel is unavailable: \(reason)"
        case .lastMessageNotUser:
            return "Last message must be from user or tool role"
        case .invalidToolChoice(let name):
            return "tool_choice requested function '\(name)' but it was not provided in tools[]"
        case .invalidSchema(let reason):
            return "response_format.json_schema is invalid: \(reason)"
        case .streamingUnsupported(let reason):
            return "Streaming is not supported: \(reason)"
        case .invalidMessage(let reason):
            return "Invalid message: \(reason)"
        case .invalidToolCall(let reason):
            return "Invalid tool call: \(reason)"
        case .responseParseFailed(let reason):
            return "Failed to parse response: \(reason)"
        case .refused(let reason):
            return "Request refused: \(reason)"
        case .contextExceeded(let used, let limit):
            return "Context window exceeded: \(used) tokens used, limit is \(limit)"
        case .queueFull:
            return "Server queue is full. Please try again later."
        }
    }
}

extension ChatEngineError {
    /// Convert to API error for HTTP responses
    public func toAPIError() -> APIError {
        switch self {
        case .emptyMessages:
            return .badRequest(errorDescription!, param: "messages")
        case .modelUnavailable:
            return .serviceUnavailable(errorDescription!)
        case .lastMessageNotUser:
            return .badRequest(errorDescription!, param: "messages")
        case .invalidToolChoice:
            return .badRequest(errorDescription!, param: "tool_choice")
        case .invalidSchema:
            return .badRequest(errorDescription!, param: "response_format")
        case .streamingUnsupported:
            return .badRequest(errorDescription!, param: "stream")
        case .invalidMessage:
            return .badRequest(errorDescription!, param: "messages")
        case .invalidToolCall:
            return .badRequest(errorDescription!, param: "tools")
        case .responseParseFailed:
            return .internalError(errorDescription!)
        case .refused:
            return .contentFiltered(errorDescription!)
        case .contextExceeded:
            return .contextWindowExceeded(errorDescription!)
        case .queueFull:
            return .rateLimited(errorDescription!)
        }
    }
}
