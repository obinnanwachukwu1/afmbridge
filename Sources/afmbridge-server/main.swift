// afmbridge-server/main.swift
// OpenRouter-compatible HTTP server for Apple's on-device FoundationModels

import Foundation
import FoundationModels
import NIO
import NIOHTTP1
import afmbridge_core

// MARK: - HTTP Handler

final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    private let engine: ChatEngine
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    
    init(engine: ChatEngine) {
        self.engine = engine
    }
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
        case .body(var part):
            bodyBuffer?.writeBuffer(&part)
        case .end:
            handleRequest(context: context)
            requestHead = nil
            bodyBuffer = nil
        }
    }
    
    private func handleRequest(context: ChannelHandlerContext) {
        guard let head = requestHead else { return }
        
        switch (head.method, head.uri) {
        case (.POST, "/v1/chat/completions"):
            let data = bodyBuffer.map { Data($0.readableBytesView) } ?? Data()
            serverLog("POST /v1/chat/completions (\(data.count) bytes)")
            
            let eventLoop = context.eventLoop
            let contextHolder = ContextHolder(context: context)
            let engine = self.engine
            
            Task {
                await self.handleChatCompletion(
                    body: data,
                    engine: engine,
                    contextHolder: contextHolder,
                    eventLoop: eventLoop
                )
            }
            
        case (.GET, "/health"), (.GET, "/"):
            sendHealthCheck(context: context)
            
        case (.GET, "/v1/models"):
            sendModelsResponse(context: context)
            
        default:
            sendError(
                status: .notFound,
                message: "Not Found",
                type: "not_found_error",
                context: context
            )
        }
    }
    
    // MARK: - Chat Completion Handler
    
    private func handleChatCompletion(
        body: Data,
        engine: ChatEngine,
        contextHolder: ContextHolder,
        eventLoop: EventLoop
    ) async {
        do {
            // Decode the request
            // NOTE: Do NOT use .convertFromSnakeCase - our types have explicit CodingKeys
            let decoder = JSONDecoder()
            let request = try decoder.decode(ChatCompletionRequest.self, from: body)
            
            // Check if streaming
            if request.stream == true {
                await handleStreamingRequest(request, engine: engine, contextHolder: contextHolder, eventLoop: eventLoop)
            } else {
                await handleNonStreamingRequest(request, engine: engine, contextHolder: contextHolder, eventLoop: eventLoop)
            }
            
        } catch let error as DecodingError {
            serverLog("Decoding error: \(error)")
            eventLoop.execute {
                self.sendError(
                    status: .badRequest,
                    message: "Invalid JSON: \(self.formatDecodingError(error))",
                    type: "invalid_request_error",
                    context: contextHolder.context
                )
            }
        } catch let error as ChatEngineError {
            serverLog("ChatEngine error: \(error)")
            let apiError = error.toAPIError()
            eventLoop.execute {
                self.sendAPIError(apiError, context: contextHolder.context)
            }
        } catch {
            serverLog("Unexpected error: \(error)")
            eventLoop.execute {
                self.sendError(
                    status: .internalServerError,
                    message: "Internal error: \(error.localizedDescription)",
                    type: "internal_error",
                    context: contextHolder.context
                )
            }
        }
    }
    
    // MARK: - Non-Streaming Request
    
    private func handleNonStreamingRequest(
        _ request: ChatCompletionRequest,
        engine: ChatEngine,
        contextHolder: ContextHolder,
        eventLoop: EventLoop
    ) async {
        do {
            let response = try await engine.complete(request)
            
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let responseData = try encoder.encode(response)
            
            var headers = HTTPHeaders()
            headers.add(name: "Content-Type", value: "application/json")
            headers.add(name: "X-Model", value: response.model)
            let finalHeaders = headers
            
            eventLoop.execute {
                self.sendResponse(status: .ok, headers: finalHeaders, body: responseData, context: contextHolder.context)
            }
            serverLog("Completed response id=\(response.id)")
            
        } catch let error as ChatEngineError {
            let apiError = error.toAPIError()
            eventLoop.execute {
                self.sendAPIError(apiError, context: contextHolder.context)
            }
        } catch {
            eventLoop.execute {
                self.sendError(
                    status: .internalServerError,
                    message: "Generation failed: \(error.localizedDescription)",
                    type: "internal_error",
                    context: contextHolder.context
                )
            }
        }
    }
    
    // MARK: - Streaming Request
    
    private func handleStreamingRequest(
        _ request: ChatCompletionRequest,
        engine: ChatEngine,
        contextHolder: ContextHolder,
        eventLoop: EventLoop
    ) async {
        // Send SSE headers
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        headers.add(name: "Connection", value: "keep-alive")
        headers.add(name: "X-Model", value: request.model ?? "ondevice")
        let sseHeaders = headers
        
        eventLoop.execute {
            contextHolder.context.write(
                self.wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: sseHeaders))),
                promise: nil
            )
        }
        
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes]
        
        do {
            let stream = engine.stream(request)
            
            for try await chunk in stream {
                guard let data = try? encoder.encode(chunk),
                      let json = String(data: data, encoding: .utf8) else {
                    continue
                }
                
                eventLoop.execute {
                    var buffer = contextHolder.context.channel.allocator.buffer(capacity: json.count + 10)
                    buffer.writeString("data: \(json)\n\n")
                    contextHolder.context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    contextHolder.context.flush()
                }
            }
            
            // Send [DONE] marker
            eventLoop.execute {
                var doneBuffer = contextHolder.context.channel.allocator.buffer(capacity: 16)
                doneBuffer.writeString("data: [DONE]\n\n")
                contextHolder.context.write(self.wrapOutboundOut(.body(.byteBuffer(doneBuffer))), promise: nil)
                contextHolder.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
            serverLog("Streaming completed")
            
        } catch {
            serverLog("Streaming error: \(error)")
            eventLoop.execute {
                contextHolder.context.close(promise: nil)
            }
        }
    }
    
    // MARK: - Health Check
    
    private func sendHealthCheck(context: ChannelHandlerContext) {
        let health: [String: Any] = [
            "status": engine.isAvailable ? "ok" : "unavailable",
            "model": "ondevice",
            "availability": engine.availabilityDescription
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: health) else {
            sendError(status: .internalServerError, message: "Failed to encode health", context: context)
            return
        }
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        sendResponse(status: engine.isAvailable ? .ok : .serviceUnavailable, headers: headers, body: data, context: context)
    }
    
    // MARK: - Models Endpoint
    
    private func sendModelsResponse(context: ChannelHandlerContext) {
        let models: [String: Any] = [
            "object": "list",
            "data": [
                [
                    "id": "ondevice",
                    "object": "model",
                    "created": Int(Date().timeIntervalSince1970),
                    "owned_by": "apple",
                    "permission": [],
                    "root": "apple/foundationmodels",
                    "parent": NSNull()
                ]
            ]
        ]
        
        guard let data = try? JSONSerialization.data(withJSONObject: models) else {
            sendError(status: .internalServerError, message: "Failed to encode models", context: context)
            return
        }
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        sendResponse(status: .ok, headers: headers, body: data, context: context)
    }
    
    // MARK: - Response Helpers
    
    private func sendResponse(status: HTTPResponseStatus, headers: HTTPHeaders, body: Data, context: ChannelHandlerContext) {
        var headers = headers
        headers.add(name: "Content-Length", value: "\(body.count)")
        
        context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    
    private func sendError(
        status: HTTPResponseStatus,
        message: String,
        type: String? = nil,
        param: String? = nil,
        context: ChannelHandlerContext
    ) {
        var errorBody: [String: Any] = ["message": message]
        errorBody["type"] = type ?? NSNull()
        errorBody["param"] = param ?? NSNull()
        errorBody["code"] = NSNull()
        
        let payload: [String: Any] = ["error": errorBody]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        sendResponse(status: status, headers: headers, body: data, context: context)
    }
    
    private func sendAPIError(_ error: APIError, context: ChannelHandlerContext) {
        let status = HTTPResponseStatus(statusCode: error.statusCode)
        sendError(
            status: status,
            message: error.errorDescription ?? "Unknown error",
            type: error.errorType,
            param: error.param,
            context: context
        )
    }
    
    private func formatDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            return "Missing required field: \(key.stringValue)"
        case .typeMismatch(let type, let context):
            return "Type mismatch for \(context.codingPath.map(\.stringValue).joined(separator: ".")): expected \(type)"
        case .valueNotFound(let type, let context):
            return "Missing value for \(context.codingPath.map(\.stringValue).joined(separator: ".")): expected \(type)"
        case .dataCorrupted(let context):
            return "Data corrupted: \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }
}

extension HTTPHandler: @unchecked Sendable {}

// MARK: - Context Holder

struct ContextHolder: @unchecked Sendable {
    let context: ChannelHandlerContext
}

// MARK: - Main Entry Point

@main
struct ServerApp {
    static func main() async {
        let engine = ChatEngine()
        
        guard engine.isAvailable else {
            fputs("ERROR: SystemLanguageModel is unavailable: \(engine.availabilityDescription)\n", stderr)
            exit(2)
        }
        
        let socketPath = parseSocket(from: CommandLine.arguments)
        let port = parsePort(from: CommandLine.arguments) ?? 8000
        
        // Warn if both are specified
        if socketPath != nil && CommandLine.arguments.contains("--port") {
            fputs("WARN: Both --socket and --port specified; using --socket\n", stderr)
        }
        
        let threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: threads)
        
        // Clean up socket file if it exists (from previous run)
        if let socketPath = socketPath {
            cleanupSocketFile(socketPath)
        }
        
        // Build base bootstrap with common options
        var bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler(engine: engine))
                }
            }
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
        
        // Only add TCP_NODELAY for TCP connections (not applicable to Unix sockets)
        if socketPath == nil {
            bootstrap = bootstrap.childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
        }
        
        do {
            let channel: Channel
            
            if let socketPath = socketPath {
                // Bind to Unix Domain Socket
                channel = try await bootstrap.bind(unixDomainSocketPath: socketPath).get()
                print("afmbridge-server listening on unix:\(socketPath)")
            } else {
                // Bind to TCP port
                channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
                print("afmbridge-server listening on http://0.0.0.0:\(port)")
            }
            
            print("Model: ondevice (Apple FoundationModels)")
            print("Status: \(engine.availabilityDescription)")
            
            // Set up signal handling for graceful shutdown
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)  // Ignore default handler
            signalSource.setEventHandler {
                print("\nShutting down...")
                if let socketPath = socketPath {
                    cleanupSocketFile(socketPath)
                }
                channel.close(promise: nil)
            }
            signalSource.resume()
            
            // Also handle SIGTERM
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            signal(SIGTERM, SIG_IGN)
            termSource.setEventHandler {
                print("\nShutting down...")
                if let socketPath = socketPath {
                    cleanupSocketFile(socketPath)
                }
                channel.close(promise: nil)
            }
            termSource.resume()
            
            try await channel.closeFuture.get()
            
            // Final cleanup
            if let socketPath = socketPath {
                cleanupSocketFile(socketPath)
            }
            
            try await group.shutdownGracefully()
            
        } catch {
            // Cleanup on error
            if let socketPath = socketPath {
                cleanupSocketFile(socketPath)
            }
            fputs("ERROR: Failed to start server: \(error)\n", stderr)
            exit(1)
        }
    }
}

// MARK: - Helpers

func parsePort(from arguments: [String]) -> Int? {
    guard let index = arguments.firstIndex(of: "--port") else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else {
        fputs("ERROR: --port requires a value\n", stderr)
        exit(1)
    }
    let value = arguments[valueIndex]
    guard let port = Int(value), (1...65535).contains(port) else {
        fputs("ERROR: Invalid port number: \(value)\n", stderr)
        exit(1)
    }
    return port
}

func parseSocket(from arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--socket") else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else {
        fputs("ERROR: --socket requires a path\n", stderr)
        exit(1)
    }
    return arguments[valueIndex]
}

func cleanupSocketFile(_ path: String) {
    unlink(path)
}

@inline(__always)
func serverLog(_ message: String) {
    fputs("[afmbridge-server] \(message)\n", stderr)
}
