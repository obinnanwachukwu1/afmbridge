// afmbridge-socket/main.swift
// Unix socket server for afmbridge RPC

import Foundation
import afmbridge_core

// Global configuration
nonisolated(unsafe) var isQuiet = false

/// Socket server that handles RPC requests from Unix socket clients.
@main
struct SocketServer {
    
    static func main() async {
        // Parse arguments
        if CommandLine.arguments.contains("--help") || CommandLine.arguments.contains("-h") {
            printHelp()
            exit(0)
        }
        
        let socketPath = parseSocketPath()
        let verbose = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v")
        isQuiet = CommandLine.arguments.contains("--quiet") || CommandLine.arguments.contains("-q")
        let maxQueueSize = parseMaxQueueSize() ?? 100
        
        // Configure executor
        await ModelExecutor.shared.setMaxQueueDepth(maxQueueSize)
        
        // Create engine
        let engine = ChatEngine()
        
        // Check model availability
        guard engine.isAvailable else {
            if !isQuiet {
                fputs("ERROR: SystemLanguageModel is not available.\n", stderr)
                fputs("Reason: \(engine.availabilityDescription)\n", stderr)
            }
            exit(2)
        }
        
        if verbose && !isQuiet {
            print("afmbridge-socket starting...")
            print("Socket path: \(socketPath)")
            print("Model: available")
            fflush(stdout)
        }
        
        // Remove existing socket file
        try? FileManager.default.removeItem(atPath: socketPath)
        
        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            if !isQuiet {
                fputs("ERROR: Failed to create socket: \(errno)\n", stderr)
            }
            exit(1)
        }
        
        // Bind to socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            if !isQuiet {
                fputs("ERROR: Socket path too long\n", stderr)
            }
            exit(1)
        }
        
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }
        
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard bindResult == 0 else {
            if !isQuiet {
                fputs("ERROR: Failed to bind socket: \(errno)\n", stderr)
            }
            exit(1)
        }
        
        // Listen for connections
        guard listen(fd, 10) == 0 else {
            if !isQuiet {
                fputs("ERROR: Failed to listen: \(errno)\n", stderr)
            }
            exit(1)
        }
        
        if !isQuiet {
            print("Listening on \(socketPath)")
            fflush(stdout)
        }
        
        // Handle SIGINT for graceful shutdown
        signal(SIGINT) { _ in
            if !isQuiet {
                print("\nShutting down...")
            }
            try? FileManager.default.removeItem(atPath: RPCDefaults.socketPath)
            exit(0)
        }
        
        // Accept connections
        while true {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(fd, sockPtr, &clientAddrLen)
                }
            }
            
            guard clientFd >= 0 else {
                if verbose && !isQuiet {
                    fputs("WARN: Failed to accept connection: \(errno)\n", stderr)
                }
                continue
            }
            
            if verbose && !isQuiet {
                print("Client connected (fd: \(clientFd))")
                fflush(stdout)
            }
            
            // Handle client synchronously in a detached task to avoid blocking
            Task.detached {
                await handleClient(fd: clientFd, engine: engine, verbose: verbose && !isQuiet)
            }
            
            // Yield to allow tasks to run
            await Task.yield()
        }
    }
    
    /// Handle a client connection
    static func handleClient(fd: Int32, engine: ChatEngine, verbose: Bool) async {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        
        defer {
            try? handle.close()
            if verbose {
                print("Client disconnected (fd: \(fd))")
                fflush(stdout)
            }
        }
        
        while true {
            // Read header
            guard let headerData = try? handle.read(upToCount: RPCHeader.size),
                  headerData.count == RPCHeader.size,
                  let header = RPCHeader.fromBytes(headerData) else {
                break
            }
            
            // Validate header
            guard header.type == .request else {
                if verbose {
                    print("Unexpected message type: \(header.type)")
                }
                continue
            }
            
            guard header.payloadLength <= RPCDefaults.maxPayloadSize else {
                if verbose {
                    print("Payload too large: \(header.payloadLength)")
                }
                await sendError(handle: handle, requestId: header.requestId, error: .invalidRequest)
                continue
            }
            
            // Read payload
            guard let payloadData = try? handle.read(upToCount: Int(header.payloadLength)),
                  payloadData.count == Int(header.payloadLength) else {
                break
            }
            
            // Decode request
            let rpcRequest: RPCRequest
            do {
                rpcRequest = try RPCCodec.decodeRequest(payloadData)
            } catch {
                if verbose {
                    print("Failed to decode request: \(error)")
                }
                await sendError(handle: handle, requestId: header.requestId, error: .parseError)
                continue
            }
            
            if verbose {
                print("Request \(header.requestId): \(rpcRequest.method) (stream: \(header.flags & RPCHeader.flagStream != 0))")
            }
            
            // Handle request
            let isStreaming = header.flags & RPCHeader.flagStream != 0
            
            if isStreaming {
                await handleStreamingRequest(
                    handle: handle,
                    requestId: header.requestId,
                    request: rpcRequest.params,
                    engine: engine,
                    verbose: verbose
                )
            } else {
                await handleRequest(
                    handle: handle,
                    requestId: header.requestId,
                    request: rpcRequest.params,
                    engine: engine,
                    verbose: verbose
                )
            }
        }
    }
    
    /// Handle a non-streaming request
    static func handleRequest(
        handle: FileHandle,
        requestId: UInt32,
        request: ChatCompletionRequest,
        engine: ChatEngine,
        verbose: Bool
    ) async {
        do {
            let response = try await engine.complete(request)
            let responseData = try RPCCodec.encodeResponse(response, requestId: requestId)
            try handle.write(contentsOf: responseData)
            
            if verbose {
                print("Response \(requestId): success")
            }
        } catch let error as ChatEngineError {
            if verbose {
                print("Response \(requestId): error - \(error.localizedDescription)")
            }
            await sendError(handle: handle, requestId: requestId, error: RPCError(
                code: error.toAPIError().statusCode,
                message: error.localizedDescription
            ))
        } catch {
            if verbose {
                print("Response \(requestId): error - \(error)")
            }
            await sendError(handle: handle, requestId: requestId, error: .internalError)
        }
    }
    
    /// Handle a streaming request
    static func handleStreamingRequest(
        handle: FileHandle,
        requestId: UInt32,
        request: ChatCompletionRequest,
        engine: ChatEngine,
        verbose: Bool
    ) async {
        do {
            let stream = engine.stream(request)
            var chunkCount = 0
            
            for try await chunk in stream {
                if Task.isCancelled { break }
                let chunkData = try RPCCodec.encodeStreamChunk(chunk, requestId: requestId)
                try handle.write(contentsOf: chunkData)
                chunkCount += 1
            }
            
            // Send stream end
            let endData = RPCCodec.encodeStreamEnd(requestId: requestId)
            try handle.write(contentsOf: endData)
            
            if verbose {
                print("Stream \(requestId): complete (\(chunkCount) chunks)")
            }
        } catch {
            if verbose {
                print("Stream \(requestId): error - \(error)")
            }
            await sendError(handle: handle, requestId: requestId, error: RPCError(
                code: -32000,
                message: error.localizedDescription
            ))
        }
    }
    
    /// Send an error response
    static func sendError(handle: FileHandle, requestId: UInt32, error: RPCError) async {
        do {
            let errorData = try RPCCodec.encodeError(error, requestId: requestId)
            try handle.write(contentsOf: errorData)
        } catch {
            // Ignore write errors during error sending
        }
    }
    
    /// Parse socket path from arguments
    static func parseSocketPath() -> String {
        for (i, arg) in CommandLine.arguments.enumerated() {
            if arg == "--socket" || arg == "-s" {
                if i + 1 < CommandLine.arguments.count {
                    return CommandLine.arguments[i + 1]
                }
            }
            if arg.hasPrefix("--socket=") {
                return String(arg.dropFirst("--socket=".count))
            }
        }
        return RPCDefaults.socketPath
    }
    
    static func parseMaxQueueSize() -> Int? {
        guard let index = CommandLine.arguments.firstIndex(of: "--max-queue-size") else { return nil }
        let valueIndex = CommandLine.arguments.index(after: index)
        guard valueIndex < CommandLine.arguments.endIndex else {
            fputs("ERROR: --max-queue-size requires a value\n", stderr)
            exit(1)
        }
        let value = CommandLine.arguments[valueIndex]
        guard let size = Int(value), size > 0 else {
            fputs("ERROR: Invalid queue size: \(value)\n", stderr)
            exit(1)
        }
        return size
    }
    
    static func printHelp() {
        print("""
        afmbridge-socket - Unix socket server for Apple Foundation Models
        
        Usage: afmbridge-socket [OPTIONS]
        
        Options:
          --socket <path>           Unix socket path (default: /tmp/afmbridge.sock)
          --max-queue-size <size>   Maximum number of queued requests (default: 100)
          -v, --verbose             Enable verbose logging
          -h, --help                Show this help message
        
        Examples:
          afmbridge-socket
          afmbridge-socket --socket /tmp/mysocket.sock
          afmbridge-socket --max-queue-size 10
        """)
    }
}
