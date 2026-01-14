// afmbridge-core/Engine/ChatEngine.swift
// Main engine that processes OpenRouter-style requests using FoundationModels

import Foundation
import FoundationModels

/// Main engine that processes OpenRouter-style requests using FoundationModels.
/// Reference: https://developer.apple.com/documentation/foundationmodels/languagemodelsession/
public struct ChatEngine: Sendable {
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Model Access
    
    /// Get the model with permissive guardrails to minimize refusals.
    /// Note: Even with permissive guardrails, the model may still refuse some requests
    /// due to its internal safety training. This is an Apple limitation.
    /// Reference: https://developer.apple.com/documentation/foundationmodels/improving-the-safety-of-generative-model-output/
    private var model: SystemLanguageModel {
        SystemLanguageModel(guardrails: .permissiveContentTransformations)
    }
    
    // MARK: - Availability
    
    /// Check if the on-device model is available
    public var isAvailable: Bool {
        if case .available = model.availability {
            return true
        }
        return false
    }
    
    /// Get the availability status description
    public var availabilityDescription: String {
        switch model.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable: \(reason)"
        @unknown default:
            return "unknown"
        }
    }
    
    // MARK: - Chat Completion (Non-Streaming)
    
    /// Process a chat completion request and return a complete response.
    public func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        // Validate request
        guard !request.messages.isEmpty else {
            throw ChatEngineError.emptyMessages
        }
        
        // Check model availability
        guard case .available = model.availability else {
            throw ChatEngineError.modelUnavailable(availabilityDescription)
        }
        
        // Extract the last message as the prompt
        let lastMessage = request.messages.last!
        guard lastMessage.role == .user || lastMessage.role == .tool else {
            throw ChatEngineError.lastMessageNotUser
        }
        
        let promptContent = lastMessage.content?.textValue ?? ""
        
        // Build instructions from system messages and tool catalog
        let instructions = buildInstructions(from: request)
        
        // Build transcript from conversation history (excluding last message)
        let transcript = buildTranscript(from: Array(request.messages.dropLast()), tools: request.tools)
        
        // Create session
        let session = LanguageModelSession(model: model, tools: [], transcript: transcript)
        
        // Build generation options
        let options = buildOptions(from: request)
        
        // Build full prompt with instructions
        let fullPrompt: String
        if let instructionText = instructions, !instructionText.isEmpty {
            fullPrompt = "\(instructionText)\n\n\(promptContent)"
        } else {
            fullPrompt = promptContent
        }
        
        // Generate response - handle structured output if requested
        var response: String
        if let responseFormat = request.responseFormat,
           responseFormat.type == .jsonSchema,
           let schemaSpec = responseFormat.jsonSchema {
            // Use structured output generation with schema
            response = try await generateWithSchema(
                session: session,
                prompt: fullPrompt,
                schemaSpec: schemaSpec,
                options: options
            )
        } else if let responseFormat = request.responseFormat,
                  responseFormat.type == .jsonObject {
            // For json_object, add instruction to return JSON and strip any fences
            let jsonPrompt = fullPrompt + "\n\nYou MUST respond with ONLY valid JSON. No markdown, no explanation, just the JSON object."
            let rawResponse = try await session.respond(to: jsonPrompt, options: options).content
            response = stripMarkdownFences(rawResponse)
        } else {
            // Regular text generation
            response = try await session.respond(to: fullPrompt, options: options).content
        }
        
        // Parse the response for tool calls if tools were provided
        let parseResult = parseResponse(
            content: response,
            tools: request.tools,
            toolChoice: request.toolChoice
        )
        
        // Calculate token usage
        let promptTokens = TokenEstimator.estimatePromptTokens(
            messages: request.messages,
            instructions: instructions
        )
        let completionTokens = TokenEstimator.estimateCompletionTokens(
            content: parseResult.content,
            toolCalls: parseResult.toolCalls
        )
        let usage = TokenEstimator.buildUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
        
        // Build the final response
        return buildChatCompletionResponse(
            parseResult: parseResult,
            model: request.model ?? "ondevice",
            usage: usage
        )
    }
    
    // MARK: - Chat Completion (Streaming)
    
    /// Stream a chat completion response.
    public func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let capturedRequest = request
            let engine = self
            
            Task {
                do {
                    // Validate request
                    guard !capturedRequest.messages.isEmpty else {
                        throw ChatEngineError.emptyMessages
                    }
                    
                    let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
                    guard case .available = model.availability else {
                        throw ChatEngineError.modelUnavailable(engine.availabilityDescription)
                    }
                    
                    let lastMessage = capturedRequest.messages.last!
                    guard lastMessage.role == .user || lastMessage.role == .tool else {
                        throw ChatEngineError.lastMessageNotUser
                    }
                    
                    let promptContent = lastMessage.content?.textValue ?? ""
                    let instructions = engine.buildInstructions(from: capturedRequest)
                    let transcript = engine.buildTranscript(from: Array(capturedRequest.messages.dropLast()), tools: capturedRequest.tools)
                    let session = LanguageModelSession(model: model, tools: [], transcript: transcript)
                    let options = engine.buildOptions(from: capturedRequest)
                    
                    let responseId = engine.generateResponseId()
                    let created = Int(Date().timeIntervalSince1970)
                    let modelName = capturedRequest.model ?? "ondevice"
                    
                    // Build full prompt
                    let fullPrompt: String
                    if let instructionText = instructions, !instructionText.isEmpty {
                        fullPrompt = "\(instructionText)\n\n\(promptContent)"
                    } else {
                        fullPrompt = promptContent
                    }
                    
                    // Stream the response
                    let stream = session.streamResponse(to: fullPrompt, options: options)
                    
                    var previousContent = ""
                    var chunkIndex = 0
                    var fullContent = ""
                    
                    for try await snapshot in stream {
                        let currentContent = snapshot.content
                        let delta: String
                        if currentContent.hasPrefix(previousContent) {
                            delta = String(currentContent.dropFirst(previousContent.count))
                        } else {
                            delta = currentContent
                        }
                        previousContent = currentContent
                        fullContent = currentContent
                        
                        if !delta.isEmpty {
                            let chunk = StreamChunk(
                                id: responseId,
                                object: "chat.completion.chunk",
                                created: created,
                                model: modelName,
                                choices: [
                                    StreamChoice(
                                        index: 0,
                                        delta: Delta(
                                            role: chunkIndex == 0 ? "assistant" : nil,
                                            content: delta,
                                            toolCalls: nil
                                        ),
                                        finishReason: nil
                                    )
                                ],
                                usage: nil
                            )
                            continuation.yield(chunk)
                            chunkIndex += 1
                        }
                    }
                    
                    // After streaming completes, check if the full content contains tool calls
                    let hasTools = capturedRequest.tools != nil && !capturedRequest.tools!.isEmpty
                    let toolChoiceIsNone = {
                        if case .some(.none) = capturedRequest.toolChoice {
                            return true
                        }
                        return false
                    }()
                    
                    var finishReason: FinishReason = .stop
                    var parsedToolCalls: [ToolCall]? = nil
                    
                    if hasTools && !toolChoiceIsNone {
                        let parseResult = ToolCallParser.parse(fullContent, declaredTools: capturedRequest.tools!)
                        if let toolCalls = parseResult.toolCalls {
                            parsedToolCalls = toolCalls
                            // Stream tool call chunks
                            for (index, toolCall) in toolCalls.enumerated() {
                                let streamToolCall = StreamToolCall(
                                    index: index,
                                    id: toolCall.id,
                                    type: toolCall.type,
                                    function: StreamFunctionCall(
                                        name: toolCall.function.name,
                                        arguments: toolCall.function.arguments
                                    )
                                )
                                let toolChunk = StreamChunk(
                                    id: responseId,
                                    object: "chat.completion.chunk",
                                    created: created,
                                    model: modelName,
                                    choices: [
                                        StreamChoice(
                                            index: 0,
                                            delta: Delta(
                                                role: nil,
                                                content: nil,
                                                toolCalls: [streamToolCall]
                                            ),
                                            finishReason: nil
                                        )
                                    ],
                                    usage: nil
                                )
                                continuation.yield(toolChunk)
                            }
                            finishReason = .toolCalls
                        }
                    }
                    
                    // Calculate usage for final chunk
                    let promptTokens = TokenEstimator.estimatePromptTokens(
                        messages: capturedRequest.messages,
                        instructions: instructions
                    )
                    let completionTokens = TokenEstimator.estimateCompletionTokens(
                        content: finishReason == .toolCalls ? nil : fullContent,
                        toolCalls: parsedToolCalls
                    )
                    let usage = TokenEstimator.buildUsage(
                        promptTokens: promptTokens,
                        completionTokens: completionTokens
                    )
                    
                    // Send final chunk with finish_reason and usage
                    let finalChunk = StreamChunk(
                        id: responseId,
                        object: "chat.completion.chunk",
                        created: created,
                        model: modelName,
                        choices: [
                            StreamChoice(
                                index: 0,
                                delta: Delta(role: nil, content: nil, toolCalls: nil),
                                finishReason: finishReason
                            )
                        ],
                        usage: usage
                    )
                    continuation.yield(finalChunk)
                    continuation.finish()
                    
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Private Helpers
    
    /// Build instructions string from system messages and tool definitions
    private func buildInstructions(from request: ChatCompletionRequest) -> String? {
        var parts: [String] = []
        
        // Collect system messages
        for message in request.messages where message.role == .system {
            if let content = message.content?.textValue, !content.isEmpty {
                parts.append(content)
            }
        }
        
        // Check if the last message is a tool result - if so, don't add tool catalog
        // The model should use the result, not call more tools
        let lastMessage = request.messages.last
        let isToolResult = lastMessage?.role == .tool
        
        // Add tool catalog if tools are provided and not disabled and not responding to a tool result
        if let tools = request.tools, !tools.isEmpty, !isToolResult {
            if case .some(.none) = request.toolChoice {
                parts.append("Tool calling is disabled. Answer directly without using tools.")
            } else {
                let catalog = buildToolCatalog(tools: tools, toolChoice: request.toolChoice)
                parts.append(catalog)
            }
        } else if isToolResult {
            // Explicitly tell the model to use the tool result
            parts.append("A tool was called and the result is provided. Use this result to answer the user's question. Do NOT call any tools - just provide your answer based on the tool result.")
        }
        
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }
    
    /// Build tool catalog text
    private func buildToolCatalog(tools: [Tool], toolChoice: ToolChoice?) -> String {
        var lines: [String] = []
        
        lines.append("## Available Tools")
        lines.append("")
        lines.append("You have access to the following tools. When you need to use a tool, respond with a JSON object containing a `tool_calls` array.")
        lines.append("")
        
        for tool in tools {
            lines.append("### \(tool.function.name)")
            if let description = tool.function.description {
                lines.append(description)
            }
            if let parameters = tool.function.parameters {
                lines.append("**Parameters:** \(parameters.schemaDescription)")
            }
            lines.append("")
        }
        
        // Tool choice guidance
        switch toolChoice {
        case .some(.required):
            lines.append("**Important:** You MUST use at least one tool in your response.")
        case .some(.function(let name)):
            lines.append("**Important:** You MUST use the `\(name)` tool.")
        case .some(.auto), .some(.none), nil:
            break
        }
        
        lines.append("")
        lines.append("""
        ## Tool Call Format
        When calling a tool, respond with valid JSON:
        ```json
        {
          "tool_calls": [
            {
              "id": "call_<unique_id>",
              "type": "function",
              "function": {
                "name": "<tool_name>",
                "arguments": { <arguments_object> }
              }
            }
          ]
        }
        ```
        """)
        
        return lines.joined(separator: "\n")
    }
    
    /// Build transcript from conversation history
    private func buildTranscript(from messages: [Message], tools: [Tool]?) -> Transcript {
        var entries: [Transcript.Entry] = []
        
        for message in messages where message.role != .system {
            switch message.role {
            case .user:
                let content = message.content?.textValue ?? ""
                let segment = Transcript.TextSegment(content: content)
                let prompt = Transcript.Prompt(segments: [.text(segment)])
                entries.append(.prompt(prompt))
                
            case .assistant:
                let content = message.content?.textValue ?? ""
                if !content.isEmpty {
                    let segment = Transcript.TextSegment(content: content)
                    let response = Transcript.Response(assetIDs: [], segments: [.text(segment)])
                    entries.append(.response(response))
                }
                
            case .tool:
                // Tool results are added as prompts
                let toolResult = formatToolResult(message)
                let segment = Transcript.TextSegment(content: toolResult)
                let prompt = Transcript.Prompt(segments: [.text(segment)])
                entries.append(.prompt(prompt))
                
            case .system:
                break
            }
        }
        
        return Transcript(entries: entries)
    }
    
    /// Format a tool result message
    private func formatToolResult(_ message: Message) -> String {
        let toolCallId = message.toolCallId ?? "unknown"
        let name = message.name ?? "tool"
        let content = message.content?.textValue ?? ""
        return """
        [Tool Result]
        Tool: \(name)
        Call ID: \(toolCallId)
        Result: \(content)
        
        Use this tool result to answer the user's question. Do NOT call tools again - provide your final answer based on this result.
        """
    }
    
    /// Build generation options from request
    private func buildOptions(from request: ChatCompletionRequest) -> GenerationOptions {
        var options = GenerationOptions()
        
        if let temperature = request.temperature {
            options.temperature = temperature
        }
        
        if let maxTokens = request.maxTokens {
            options.maximumResponseTokens = maxTokens
        }
        
        return options
    }
    
    /// Parse the response for tool calls
    private func parseResponse(
        content: String,
        tools: [Tool]?,
        toolChoice: ToolChoice?
    ) -> ParseResult {
        // If tool_choice is none, don't look for tool calls
        if case .some(.none) = toolChoice {
            return ParseResult(
                content: content.isEmpty ? nil : content,
                toolCalls: nil,
                finishReason: .stop
            )
        }
        
        guard let tools = tools, !tools.isEmpty else {
            return ParseResult(
                content: content.isEmpty ? nil : content,
                toolCalls: nil,
                finishReason: .stop
            )
        }
        
        // Try to parse tool calls from the response
        return ToolCallParser.parse(content, declaredTools: tools)
    }
    
    /// Build the final chat completion response
    private func buildChatCompletionResponse(
        parseResult: ParseResult,
        model: String,
        usage: Usage?
    ) -> ChatCompletionResponse {
        let responseId = generateResponseId()
        let created = Int(Date().timeIntervalSince1970)
        
        // Convert ToolCall to ResponseToolCall
        let responseToolCalls: [ResponseToolCall]? = parseResult.toolCalls?.map { call in
            ResponseToolCall(
                id: call.id,
                type: call.type,
                function: ResponseFunctionCall(
                    name: call.function.name,
                    arguments: call.function.arguments
                )
            )
        }
        
        let message = ResponseMessage(
            role: "assistant",
            content: parseResult.content,
            toolCalls: responseToolCalls
        )
        
        let choice = Choice(
            index: 0,
            message: message,
            finishReason: parseResult.finishReason
        )
        
        return ChatCompletionResponse(
            id: responseId,
            object: "chat.completion",
            created: created,
            model: model,
            choices: [choice],
            usage: usage
        )
    }
    
    /// Generate a unique response ID
    private func generateResponseId() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        let randomPart = String((0..<24).map { _ in chars.randomElement()! })
        return "chatcmpl-\(randomPart)"
    }
    
    /// Strip markdown code fences from text (e.g., ```json...```)
    private func stripMarkdownFences(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle ```json or ``` at the start
        if result.hasPrefix("```") {
            if let newlineIndex = result.firstIndex(of: "\n") {
                result = String(result[result.index(after: newlineIndex)...])
            }
        }
        
        // Handle ``` at the end
        if result.hasSuffix("```") {
            if let fenceStart = result.range(of: "```", options: .backwards) {
                result = String(result[..<fenceStart.lowerBound])
            }
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Structured Output
    
    /// Generate a response constrained by a JSON schema using Apple's guided generation.
    /// Reference: https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation
    private func generateWithSchema(
        session: LanguageModelSession,
        prompt: String,
        schemaSpec: JSONSchemaSpec,
        options: GenerationOptions
    ) async throws -> String {
        // Convert OpenRouter schema to Apple's GenerationSchema
        let generationSchema: GenerationSchema
        do {
            generationSchema = try SchemaConverter.convert(schemaSpec)
        } catch {
            // Fall back to prompt-based generation if schema conversion fails
            let schemaDescription = schemaSpec.schema.schemaDescription
            let enhancedPrompt = """
            \(prompt)
            
            You MUST respond with ONLY valid JSON matching this schema (no other text):
            Schema name: \(schemaSpec.name)
            \(schemaDescription)
            
            Output ONLY the JSON object, nothing else.
            """
            return try await session.respond(to: enhancedPrompt, options: options).content
        }
        
        // Use Apple's guided generation with the schema
        do {
            let response = try await session.respond(
                to: Prompt(prompt),
                schema: generationSchema,
                includeSchemaInPrompt: true,
                options: options
            )
            
            // Return the JSON string from the generated content
            return response.content.jsonString
        } catch {
            // Fall back to prompt-based if guided generation fails
            let schemaDescription = schemaSpec.schema.schemaDescription
            let enhancedPrompt = """
            \(prompt)
            
            You MUST respond with ONLY valid JSON matching this schema (no other text):
            Schema name: \(schemaSpec.name)
            \(schemaDescription)
            
            Output ONLY the JSON object, nothing else.
            """
            return try await session.respond(to: enhancedPrompt, options: options).content
        }
    }
}

// MARK: - Parse Result

/// Result of parsing a model response
struct ParseResult: Sendable {
    let content: String?
    let toolCalls: [ToolCall]?
    let finishReason: FinishReason
}

// MARK: - Token Estimation

/// Estimates token counts for usage tracking.
/// Apple's FoundationModels doesn't expose exact token counts, so we estimate.
/// Approximation: ~4 characters per token for English text (conservative estimate).
enum TokenEstimator {
    
    /// Characters per token ratio (conservative for English)
    private static let charsPerToken: Double = 4.0
    
    /// Estimate tokens for a string
    static func estimateTokens(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(text.count) / charsPerToken)))
    }
    
    /// Estimate tokens for messages (prompt tokens)
    static func estimatePromptTokens(messages: [Message], instructions: String?) -> Int {
        var totalChars = 0
        
        // Count message content
        for message in messages {
            // Role overhead (~4 tokens per message for role/formatting)
            totalChars += 16
            
            // Content
            if let content = message.content?.textValue {
                totalChars += content.count
            }
            
            // Tool calls in assistant messages
            if let toolCalls = message.toolCalls {
                for call in toolCalls {
                    totalChars += call.id.count
                    totalChars += call.function.name.count
                    totalChars += call.function.arguments.count
                    totalChars += 40 // JSON structure overhead
                }
            }
            
            // Tool call ID for tool messages
            if let toolCallId = message.toolCallId {
                totalChars += toolCallId.count
            }
            
            // Name field
            if let name = message.name {
                totalChars += name.count
            }
        }
        
        // Instructions (system prompt + tool catalog)
        if let instructions = instructions {
            totalChars += instructions.count
        }
        
        return max(1, Int(ceil(Double(totalChars) / charsPerToken)))
    }
    
    /// Estimate tokens for completion (response tokens)
    static func estimateCompletionTokens(content: String?, toolCalls: [ToolCall]?) -> Int {
        var totalChars = 0
        
        // Text content
        if let content = content {
            totalChars += content.count
        }
        
        // Tool calls
        if let toolCalls = toolCalls {
            for call in toolCalls {
                totalChars += call.id.count
                totalChars += call.function.name.count
                totalChars += call.function.arguments.count
                totalChars += 40 // JSON structure overhead
            }
        }
        
        return max(1, Int(ceil(Double(totalChars) / charsPerToken)))
    }
    
    /// Build a Usage object from prompt and completion token counts
    static func buildUsage(promptTokens: Int, completionTokens: Int) -> Usage {
        Usage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens
        )
    }
}
