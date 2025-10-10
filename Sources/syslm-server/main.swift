// syslm-server/main.swift

import Foundation
import FoundationModels
import NIO
import NIOHTTP1
import syslm_core

final class HTTPHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private var requestHead: HTTPRequestHead?
  private var bodyBuffer: ByteBuffer?

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
      if let bodyString = String(data: data, encoding: .utf8) {
        serverLog("POST /v1/chat/completions body: \(bodyString)")
      } else {
        serverLog("POST /v1/chat/completions received non-UTF8 body of size \(data.count)")
      }
      let eventLoop = context.eventLoop
      let contextHolder = ContextHolder(context: context)
      Task {
        await respondToChatCompletion(body: data, context: contextHolder, eventLoop: eventLoop)
      }
    default:
      sendError(status: .notFound, message: "Not Found", context: context)
    }
  }

  private func respondToChatCompletion(body: Data, context: ContextHolder, eventLoop: EventLoop) async {
    do {
      var jsonObject = (try JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

      if let responseFormat = jsonObject["response_format"] as? [String: Any],
         let jsonSchema = responseFormat["json_schema"] as? [String: Any],
         let schemaDict = jsonSchema["schema"] as? [String: Any],
         let typeValue = schemaDict["type"] as? String {
        let allowed = ["object", "array", "string", "integer", "number", "boolean"]
        if !allowed.contains(typeValue.lowercased()) {
          let message = "response_format.json_schema type \(typeValue) is unsupported"
          serverLog(message)
          eventLoop.execute {
            self.sendError(status: .badRequest, message: message, type: "invalid_request_error", param: "response_format", context: context.context)
          }
          return
        }
      }

      if let toolChoice = (jsonObject["tool_choice"] as? String)?.lowercased(), toolChoice == "none" {
        jsonObject.removeValue(forKey: "tools")
      }

      let payloadData = try JSONSerialization.data(withJSONObject: jsonObject, options: [])
      let payload = try JSONDecoder().decode(InputPayload.self, from: payloadData)

      if let schema = payload.responseFormat?.jsonSchema?.schema,
         case let .object(dict) = schema,
         let typeValue = dict["type"],
         case let .string(typeName) = typeValue {
        let allowed = ["object", "array", "string", "integer", "number", "boolean"]
        if !allowed.contains(typeName.lowercased()) {
          serverLog("Rejecting unsupported schema type: \(typeName)")
          eventLoop.execute {
            self.sendError(status: .badRequest, message: "response_format.json_schema type \(typeName) is unsupported", type: "invalid_request_error", param: "response_format", context: context.context)
          }
          return
        }
      }

      if payload.stream == true {
        let streamResult = try ChatEngine.stream(payload: payload)
        let contextHolder = context
        eventLoop.execute {
        self.sendStream(stream: streamResult, contextHolder: contextHolder)
      }
      serverLog("Streaming response started with id=\(streamResult.id)")
      return
    }

    let result = try await ChatEngine.process(payload: payload)

      let encoder = JSONEncoder()
      encoder.outputFormatting = [.withoutEscapingSlashes]
      encoder.keyEncodingStrategy = .convertToSnakeCase
      let responseData = try encoder.encode(result.response)

      var headers = HTTPHeaders()
      headers.add(name: "Content-Type", value: "application/json")
      headers.add(name: "X-Model", value: result.response.model)
      for warning in result.warnings {
        headers.add(name: "Warning", value: warning)
      }
      let responseHeaders = headers
      let contextHolder = context
      eventLoop.execute {
        self.sendResponse(status: .ok, headers: responseHeaders, body: responseData, context: contextHolder.context)
      }
      serverLog("Completed response id=\(result.response.id)")
    } catch let error as DecodingError {
      serverLog("Decoding error: \(error)")
      let contextHolder = context
      eventLoop.execute {
        self.sendError(status: .badRequest, message: "Invalid JSON: \(error)", type: "invalid_request_error", context: contextHolder.context)
      }
    } catch let error as ChatEngineError {
      serverLog("ChatEngine error: \(error)")
      let contextHolder = context
      eventLoop.execute {
        self.sendError(status: .badRequest, message: error.description, type: "invalid_request_error", param: self.openAIParam(for: error), context: contextHolder.context)
      }
    } catch {
      serverLog("Unexpected error: \(error)")
      let contextHolder = context
      eventLoop.execute {
        self.sendError(status: .internalServerError, message: "Internal error: \(error)", context: contextHolder.context)
      }
    }
  }

  private func sendResponse(status: HTTPResponseStatus, headers: HTTPHeaders, body: Data, context: ChannelHandlerContext) {
    var headers = headers
    headers.add(name: "Content-Length", value: "\(body.count)")

    context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
    var buffer = context.channel.allocator.buffer(capacity: body.count)
    buffer.writeBytes(body)
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
  }

  private func sendError(status: HTTPResponseStatus, message: String, type: String? = nil, param: String? = nil, code: String? = nil, context: ChannelHandlerContext) {
    var errorBody: [String: Any] = ["message": message]
    errorBody["type"] = type ?? NSNull()
    errorBody["param"] = param ?? NSNull()
    errorBody["code"] = code ?? NSNull()

    let payload: [String: Any] = ["error": errorBody]
    let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "application/json")
    let bodyData = data ?? Data()
    sendResponse(status: status, headers: headers, body: bodyData, context: context)
  }

  private func sendStream(stream: ChatEngine.StreamResponse, contextHolder: ContextHolder) {
    let context = contextHolder.context
    var headers = HTTPHeaders()
    headers.add(name: "Content-Type", value: "text/event-stream")
    headers.add(name: "Cache-Control", value: "no-cache")
    headers.add(name: "Connection", value: "keep-alive")
    headers.add(name: "X-Model", value: stream.model)
    for warning in stream.warnings {
      headers.add(name: "Warning", value: warning)
    }

    context.write(wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    encoder.keyEncodingStrategy = .convertToSnakeCase

    let chunkInfo = StreamChunkInfo(
      id: stream.id,
      created: stream.created,
      model: stream.model,
      index: 0
    )

    let eventLoop = context.eventLoop
    let events = stream.events

    Task {
      do {
        for try await event in events {
          eventLoop.execute {
            switch event {
            case .role(let role):
              let chunk = StreamChunk(info: chunkInfo, delta: .init(role: role, content: nil, toolCalls: nil), finishReason: nil)
              self.sendStreamChunk(chunk, encoder: encoder, context: contextHolder.context)
            case .content(let content):
              let chunk = StreamChunk(info: chunkInfo, delta: .init(role: nil, content: content, toolCalls: nil), finishReason: nil)
              self.sendStreamChunk(chunk, encoder: encoder, context: contextHolder.context)
            case .finish(let finish):
              let chunk = StreamChunk(info: chunkInfo, delta: .init(role: nil, content: nil, toolCalls: nil), finishReason: finish)
              self.sendStreamChunk(chunk, encoder: encoder, context: contextHolder.context)
            }
          }
        }
        eventLoop.execute {
          var doneBuffer = contextHolder.context.channel.allocator.buffer(capacity: 0)
          doneBuffer.writeString("data: [DONE]\n\n")
          contextHolder.context.write(self.wrapOutboundOut(.body(.byteBuffer(doneBuffer))), promise: nil)
          contextHolder.context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
      } catch {
        eventLoop.execute {
          contextHolder.context.close(promise: nil)
        }
      }
    }
  }

  private func openAIParam(for error: ChatEngineError) -> String? {
    switch error {
    case .emptyMessages, .lastMessageNotUser, .invalidMessage:
      return "messages"
    case .modelUnavailable:
      return "model"
    case .invalidToolChoice:
      return "tool_choice"
    case .invalidSchema:
      return "response_format"
    case .streamingUnsupported:
      return "stream"
    }
  }

  private func sendStreamChunk(_ chunk: StreamChunk, encoder: JSONEncoder, context: ChannelHandlerContext) {
    guard let data = try? encoder.encode(chunk) else { return }
    var buffer = context.channel.allocator.buffer(capacity: data.count + 7)
    buffer.writeString("data: ")
    buffer.writeBytes(data)
    buffer.writeString("\n\n")
    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    context.flush()
  }
}

@main
struct ServerApp {
  static func main() async {
    guard SystemLanguageModel.default.isAvailable else {
      fputs("ERROR: SystemLanguageModel is unavailable: \(SystemLanguageModel.default.availability)\n", stderr)
      exit(2)
    }

    let port = parsePort(from: CommandLine.arguments) ?? 8000

    let threads = max(1, ProcessInfo.processInfo.activeProcessorCount)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: threads)
    defer {
      group.shutdownGracefully { error in
        if let error {
          fputs("WARN: Failed to shut down event loop group cleanly: \(error)\n", stderr)
        }
      }
    }

    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 256)
      .serverChannelOption(ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR), value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().flatMap {
          channel.pipeline.addHandler(HTTPHandler())
        }
      }
      .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
      .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

    do {
      let channel = try await bootstrap.bind(host: "0.0.0.0", port: port).get()
      print("syslm-server listening on http://0.0.0.0:\(port)")
      try await channel.closeFuture.get()
    } catch {
      fputs("ERROR: Failed to start server: \(error)\n", stderr)
      exit(1)
    }
  }
}

extension HTTPHandler: @unchecked Sendable {}

struct ContextHolder: @unchecked Sendable {
  let context: ChannelHandlerContext
}

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

@inline(__always)
func serverLog(_ message: String) {
  fputs("[syslm-server] \(message)\n", stderr)
}

struct StreamChunkInfo {
  let id: String
  let created: Int
  let model: String
  let index: Int
}

struct StreamChunk: Encodable {
  struct Choice: Encodable {
    struct Delta: Encodable {
      struct ToolCall: Encodable {
        struct Function: Encodable {
          let name: String?
          let arguments: String?
        }

        let index: Int
        let id: String?
        let type: String?
        let function: Function?
      }

      let role: String?
      let content: String?
      let toolCalls: [ToolCall]?

      enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCalls = "tool_calls"
      }
    }

    let index: Int
    let delta: Delta
    let logprobs: String? = nil
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
      case index
      case delta
      case logprobs
      case finishReason = "finish_reason"
    }
  }

  let id: String
  let object: String = "chat.completion.chunk"
  let created: Int
  let model: String
  let choices: [Choice]

  init(info: StreamChunkInfo, delta: Choice.Delta, finishReason: String?) {
    self.id = info.id
    self.created = info.created
    self.model = info.model
    self.choices = [Choice(index: info.index, delta: delta, finishReason: finishReason)]
  }
}
