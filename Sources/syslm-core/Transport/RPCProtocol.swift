// syslm-core/Transport/RPCProtocol.swift
// Wire protocol for Unix socket RPC communication

import Foundation

/// RPC message types
public enum RPCMessageType: UInt8, Sendable {
    case request = 1
    case response = 2
    case streamChunk = 3
    case streamEnd = 4
    case error = 5
    case ping = 6
    case pong = 7
}

/// RPC message header (fixed 16 bytes)
/// Layout: [type: 1][flags: 1][reserved: 2][requestId: 4][payloadLength: 4][checksum: 4]
public struct RPCHeader: Sendable {
    public let type: RPCMessageType
    public let flags: UInt8
    public let requestId: UInt32
    public let payloadLength: UInt32
    public let checksum: UInt32
    
    public static let size = 16
    
    /// Flags
    public static let flagStream: UInt8 = 0x01
    public static let flagCompressed: UInt8 = 0x02
    
    public init(
        type: RPCMessageType,
        flags: UInt8 = 0,
        requestId: UInt32,
        payloadLength: UInt32,
        checksum: UInt32 = 0
    ) {
        self.type = type
        self.flags = flags
        self.requestId = requestId
        self.payloadLength = payloadLength
        self.checksum = checksum
    }
    
    /// Serialize header to bytes
    public func toBytes() -> Data {
        var data = Data(capacity: Self.size)
        data.append(type.rawValue)
        data.append(flags)
        data.append(contentsOf: [0, 0]) // reserved
        data.append(contentsOf: withUnsafeBytes(of: requestId.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: payloadLength.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: checksum.bigEndian) { Array($0) })
        return data
    }
    
    /// Parse header from bytes
    public static func fromBytes(_ data: Data) -> RPCHeader? {
        guard data.count >= size else { return nil }
        
        guard let type = RPCMessageType(rawValue: data[0]) else { return nil }
        let flags = data[1]
        // bytes 2-3 are reserved
        
        let requestId = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let payloadLength = data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let checksum = data.subdata(in: 12..<16).withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        
        return RPCHeader(
            type: type,
            flags: flags,
            requestId: requestId,
            payloadLength: payloadLength,
            checksum: checksum
        )
    }
}

/// RPC request envelope
public struct RPCRequest: Codable, Sendable {
    public let method: String
    public let params: ChatCompletionRequest
    
    public init(method: String = "chat.completions", params: ChatCompletionRequest) {
        self.method = method
        self.params = params
    }
}

/// RPC response envelope
public struct RPCResponse: Codable, Sendable {
    public let result: ChatCompletionResponse?
    public let error: RPCError?
    
    public init(result: ChatCompletionResponse) {
        self.result = result
        self.error = nil
    }
    
    public init(error: RPCError) {
        self.result = nil
        self.error = error
    }
}

/// RPC error
public struct RPCError: Codable, Sendable, Error {
    public let code: Int
    public let message: String
    
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
    
    // Standard error codes
    public static let parseError = RPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = RPCError(code: -32600, message: "Invalid request")
    public static let methodNotFound = RPCError(code: -32601, message: "Method not found")
    public static let invalidParams = RPCError(code: -32602, message: "Invalid params")
    public static let internalError = RPCError(code: -32603, message: "Internal error")
    public static let serverError = RPCError(code: -32000, message: "Server error")
    public static let modelUnavailable = RPCError(code: -32001, message: "Model unavailable")
}

/// RPC codec for encoding/decoding messages
public enum RPCCodec {
    
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Don't use convertToSnakeCase - our types have explicit CodingKeys
        return encoder
    }()
    
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        // Don't use convertFromSnakeCase - our types have explicit CodingKeys
        return decoder
    }()
    
    /// Encode a request to wire format
    public static func encodeRequest(
        _ request: ChatCompletionRequest,
        requestId: UInt32,
        stream: Bool
    ) throws -> Data {
        let rpcRequest = RPCRequest(params: request)
        let payload = try encoder.encode(rpcRequest)
        
        var flags: UInt8 = 0
        if stream {
            flags |= RPCHeader.flagStream
        }
        
        let header = RPCHeader(
            type: .request,
            flags: flags,
            requestId: requestId,
            payloadLength: UInt32(payload.count),
            checksum: crc32(payload)
        )
        
        var data = header.toBytes()
        data.append(payload)
        return data
    }
    
    /// Encode a response to wire format
    public static func encodeResponse(
        _ response: ChatCompletionResponse,
        requestId: UInt32
    ) throws -> Data {
        let rpcResponse = RPCResponse(result: response)
        let payload = try encoder.encode(rpcResponse)
        
        let header = RPCHeader(
            type: .response,
            requestId: requestId,
            payloadLength: UInt32(payload.count),
            checksum: crc32(payload)
        )
        
        var data = header.toBytes()
        data.append(payload)
        return data
    }
    
    /// Encode an error to wire format
    public static func encodeError(
        _ error: RPCError,
        requestId: UInt32
    ) throws -> Data {
        let rpcResponse = RPCResponse(error: error)
        let payload = try encoder.encode(rpcResponse)
        
        let header = RPCHeader(
            type: .error,
            requestId: requestId,
            payloadLength: UInt32(payload.count),
            checksum: crc32(payload)
        )
        
        var data = header.toBytes()
        data.append(payload)
        return data
    }
    
    /// Encode a stream chunk to wire format
    public static func encodeStreamChunk(
        _ chunk: StreamChunk,
        requestId: UInt32
    ) throws -> Data {
        let payload = try encoder.encode(chunk)
        
        let header = RPCHeader(
            type: .streamChunk,
            flags: RPCHeader.flagStream,
            requestId: requestId,
            payloadLength: UInt32(payload.count),
            checksum: crc32(payload)
        )
        
        var data = header.toBytes()
        data.append(payload)
        return data
    }
    
    /// Encode stream end marker
    public static func encodeStreamEnd(requestId: UInt32) -> Data {
        let header = RPCHeader(
            type: .streamEnd,
            flags: RPCHeader.flagStream,
            requestId: requestId,
            payloadLength: 0,
            checksum: 0
        )
        return header.toBytes()
    }
    
    /// Decode a request from payload
    public static func decodeRequest(_ payload: Data) throws -> RPCRequest {
        try decoder.decode(RPCRequest.self, from: payload)
    }
    
    /// Decode a response from payload
    public static func decodeResponse(_ payload: Data) throws -> RPCResponse {
        try decoder.decode(RPCResponse.self, from: payload)
    }
    
    /// Decode a stream chunk from payload
    public static func decodeStreamChunk(_ payload: Data) throws -> StreamChunk {
        try decoder.decode(StreamChunk.self, from: payload)
    }
    
    /// Simple CRC32 checksum
    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB88320 * (crc & 1))
            }
        }
        return ~crc
    }
}

/// Default socket path
public enum RPCDefaults {
    public static let socketPath = "/tmp/syslm.sock"
    public static let maxPayloadSize: UInt32 = 10 * 1024 * 1024 // 10MB
}
