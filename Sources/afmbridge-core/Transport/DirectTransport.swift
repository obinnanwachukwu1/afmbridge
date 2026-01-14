// afmbridge-core/Transport/DirectTransport.swift
// In-process transport that wraps ChatEngine directly

import Foundation

/// Direct transport that uses ChatEngine in-process.
/// This is the most efficient transport for embedded use cases
/// where the client and engine run in the same process.
public struct DirectTransport: ChatTransport, Sendable {
    
    private let engine: ChatEngine
    
    /// Create a direct transport with a new ChatEngine instance.
    public init() {
        self.engine = ChatEngine()
    }
    
    /// Create a direct transport with an existing ChatEngine.
    /// - Parameter engine: The ChatEngine to use
    public init(engine: ChatEngine) {
        self.engine = engine
    }
    
    // MARK: - ChatTransport
    
    public var isAvailable: Bool {
        get async {
            engine.isAvailable
        }
    }
    
    public func send(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        guard engine.isAvailable else {
            throw TransportError.notConnected
        }
        
        do {
            return try await engine.complete(request)
        } catch let error as ChatEngineError {
            let apiError = error.toAPIError()
            throw TransportError.serverError(code: apiError.statusCode, message: error.localizedDescription)
        } catch {
            throw TransportError.other(error.localizedDescription)
        }
    }
    
    public func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<StreamChunk, Error> {
        guard engine.isAvailable else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: TransportError.notConnected)
            }
        }
        
        return engine.stream(request)
    }
}
