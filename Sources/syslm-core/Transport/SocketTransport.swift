// syslm-core/Transport/SocketTransport.swift
// Unix socket transport for RPC communication

import Foundation

/// Transport that connects to a syslm socket server via Unix domain socket.
/// This is ideal for CLI tools and local applications that want low-latency
/// communication without HTTP overhead.
public final class SocketTransport: ChatTransport, @unchecked Sendable {
    
    private let socketPath: String
    private let config: TransportConfig
    private var fileHandle: FileHandle?
    private var nextRequestId: UInt32 = 1
    private let lock = NSLock()
    
    /// Create a socket transport.
    /// - Parameters:
    ///   - socketPath: Path to the Unix socket (defaults to /tmp/syslm.sock)
    ///   - config: Transport configuration
    public init(
        socketPath: String = RPCDefaults.socketPath,
        config: TransportConfig = .default
    ) {
        self.socketPath = socketPath
        self.config = config
    }
    
    deinit {
        disconnect()
    }
    
    // MARK: - Connection Management
    
    /// Connect to the socket server.
    public func connect() throws {
        lock.lock()
        defer { lock.unlock() }
        
        guard fileHandle == nil else { return }
        
        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TransportError.connectionFailed("Failed to create socket: \(errno)")
        }
        
        // Connect to socket path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw TransportError.connectionFailed("Socket path too long")
        }
        
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }
        
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard connectResult == 0 else {
            close(fd)
            throw TransportError.connectionFailed("Failed to connect to \(socketPath): \(errno)")
        }
        
        fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    
    /// Disconnect from the socket server.
    public func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        
        try? fileHandle?.close()
        fileHandle = nil
    }
    
    /// Get the next request ID (thread-safe).
    private func getNextRequestId() -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextRequestId
        nextRequestId += 1
        return id
    }
    
    // MARK: - ChatTransport
    
    public var isAvailable: Bool {
        get async {
            // Check if socket file exists
            FileManager.default.fileExists(atPath: socketPath)
        }
    }
    
    public func send(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        // Ensure connected
        if fileHandle == nil {
            try connect()
        }
        
        guard let handle = fileHandle else {
            throw TransportError.notConnected
        }
        
        let requestId = getNextRequestId()
        
        // Encode request
        let requestData: Data
        do {
            requestData = try RPCCodec.encodeRequest(request, requestId: requestId, stream: false)
        } catch {
            throw TransportError.encodingFailed(error.localizedDescription)
        }
        
        // Send request
        do {
            try handle.write(contentsOf: requestData)
        } catch {
            disconnect()
            throw TransportError.connectionFailed("Write failed: \(error.localizedDescription)")
        }
        
        // Read response header
        guard let headerData = try? handle.read(upToCount: RPCHeader.size),
              headerData.count == RPCHeader.size,
              let header = RPCHeader.fromBytes(headerData) else {
            disconnect()
            throw TransportError.decodingFailed("Failed to read response header")
        }
        
        // Validate header
        guard header.requestId == requestId else {
            throw TransportError.decodingFailed("Request ID mismatch")
        }
        
        guard header.payloadLength <= RPCDefaults.maxPayloadSize else {
            throw TransportError.decodingFailed("Payload too large: \(header.payloadLength)")
        }
        
        // Read payload
        guard let payloadData = try? handle.read(upToCount: Int(header.payloadLength)),
              payloadData.count == Int(header.payloadLength) else {
            disconnect()
            throw TransportError.decodingFailed("Failed to read response payload")
        }
        
        // Handle response type
        switch header.type {
        case .response:
            let rpcResponse = try RPCCodec.decodeResponse(payloadData)
            if let error = rpcResponse.error {
                throw TransportError.serverError(code: error.code, message: error.message)
            }
            guard let result = rpcResponse.result else {
                throw TransportError.decodingFailed("Response missing result")
            }
            return result
            
        case .error:
            let rpcResponse = try RPCCodec.decodeResponse(payloadData)
            if let error = rpcResponse.error {
                throw TransportError.serverError(code: error.code, message: error.message)
            }
            throw TransportError.serverError(code: -1, message: "Unknown error")
            
        default:
            throw TransportError.decodingFailed("Unexpected message type: \(header.type)")
        }
    }
    
    public func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Ensure connected
                    if self.fileHandle == nil {
                        try self.connect()
                    }
                    
                    guard let handle = self.fileHandle else {
                        throw TransportError.notConnected
                    }
                    
                    let requestId = self.getNextRequestId()
                    
                    // Encode streaming request
                    let requestData = try RPCCodec.encodeRequest(request, requestId: requestId, stream: true)
                    
                    // Send request
                    try handle.write(contentsOf: requestData)
                    
                    // Read stream chunks
                    while true {
                        // Read header
                        guard let headerData = try? handle.read(upToCount: RPCHeader.size),
                              headerData.count == RPCHeader.size,
                              let header = RPCHeader.fromBytes(headerData) else {
                            throw TransportError.streamClosed
                        }
                        
                        // Check for stream end
                        if header.type == .streamEnd {
                            break
                        }
                        
                        // Check for error
                        if header.type == .error {
                            if header.payloadLength > 0,
                               let payloadData = try? handle.read(upToCount: Int(header.payloadLength)),
                               let rpcResponse = try? RPCCodec.decodeResponse(payloadData),
                               let error = rpcResponse.error {
                                throw TransportError.serverError(code: error.code, message: error.message)
                            }
                            throw TransportError.serverError(code: -1, message: "Unknown error")
                        }
                        
                        // Validate chunk header
                        guard header.type == .streamChunk else {
                            throw TransportError.decodingFailed("Unexpected message type: \(header.type)")
                        }
                        
                        guard header.payloadLength <= RPCDefaults.maxPayloadSize else {
                            throw TransportError.decodingFailed("Payload too large")
                        }
                        
                        // Read chunk payload
                        guard let payloadData = try? handle.read(upToCount: Int(header.payloadLength)),
                              payloadData.count == Int(header.payloadLength) else {
                            throw TransportError.streamClosed
                        }
                        
                        // Decode and yield chunk
                        let chunk = try RPCCodec.decodeStreamChunk(payloadData)
                        continuation.yield(chunk)
                    }
                    
                    continuation.finish()
                    
                } catch {
                    self.disconnect()
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
