// afmbridge-core/Transport/ChatTransport.swift
// Transport-agnostic protocol for chat completions

import Foundation

/// Protocol for transport-agnostic communication with afmbridge.
/// Implementations can use different underlying transports:
/// - DirectTransport: In-process, no network (for embedded use)
/// - SocketTransport: Unix socket RPC (for CLI tools)
/// - HTTPTransport: HTTP client (for remote servers)
public protocol ChatTransport: Sendable {
    
    /// Send a chat completion request and receive a complete response.
    /// - Parameter request: The chat completion request
    /// - Returns: The complete chat completion response
    /// - Throws: TransportError if the request fails
    func send(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse
    
    /// Stream a chat completion response.
    /// - Parameter request: The chat completion request
    /// - Returns: An async stream of chunks
    func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<StreamChunk, Error>
    
    /// Check if the transport is connected/available.
    var isAvailable: Bool { get async }
}

/// Errors that can occur during transport operations.
public enum TransportError: Error, Sendable, CustomStringConvertible {
    /// The transport is not connected or available
    case notConnected
    
    /// Connection to the server failed
    case connectionFailed(String)
    
    /// The server returned an error
    case serverError(code: Int, message: String)
    
    /// Failed to encode the request
    case encodingFailed(String)
    
    /// Failed to decode the response
    case decodingFailed(String)
    
    /// The request timed out
    case timeout
    
    /// The stream was unexpectedly closed
    case streamClosed
    
    /// Generic transport error
    case other(String)
    
    public var description: String {
        switch self {
        case .notConnected:
            return "Transport not connected"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .encodingFailed(let reason):
            return "Encoding failed: \(reason)"
        case .decodingFailed(let reason):
            return "Decoding failed: \(reason)"
        case .timeout:
            return "Request timed out"
        case .streamClosed:
            return "Stream closed unexpectedly"
        case .other(let message):
            return message
        }
    }
}

/// Configuration for transports
public struct TransportConfig: Sendable {
    /// Request timeout in seconds
    public let timeout: TimeInterval
    
    /// Whether to automatically reconnect on failure
    public let autoReconnect: Bool
    
    /// Maximum number of retry attempts
    public let maxRetries: Int
    
    public init(
        timeout: TimeInterval = 60,
        autoReconnect: Bool = true,
        maxRetries: Int = 3
    ) {
        self.timeout = timeout
        self.autoReconnect = autoReconnect
        self.maxRetries = maxRetries
    }
    
    /// Default configuration
    public static let `default` = TransportConfig()
}
