// afmbridge-core/Engine/ToolCallParser.swift
// Parses tool calls from model text output

import Foundation

/// Parses tool calls from model text output.
/// This handles the case where the model outputs JSON with tool_calls.
struct ToolCallParser {
    
    /// Parse model output and extract tool calls if present.
    /// - Parameters:
    ///   - text: The raw model output text
    ///   - declaredTools: The tools that were declared in the request
    /// - Returns: A ParseResult with extracted tool calls or text content
    static func parse(
        _ text: String,
        declaredTools: [Tool]
    ) -> ParseResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Try to parse as JSON with tool_calls
        if let toolCalls = extractToolCalls(from: trimmed, declaredTools: declaredTools) {
            return ParseResult(
                content: nil,
                toolCalls: toolCalls,
                finishReason: .toolCalls
            )
        }
        
        // No tool calls found — return as regular content
        return ParseResult(
            content: trimmed.isEmpty ? nil : trimmed,
            toolCalls: nil,
            finishReason: .stop
        )
    }
    
    /// Extract tool_calls from JSON response.
    private static func extractToolCalls(
        from text: String,
        declaredTools: [Tool]
    ) -> [ToolCall]? {
        // Strip code fences if present
        let cleaned = stripCodeFences(text)
        
        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let callsArray = json["tool_calls"] as? [[String: Any]] else {
            return nil
        }
        
        var toolCalls: [ToolCall] = []
        let toolNames = Set(declaredTools.map { $0.function.name })
        
        for callDict in callsArray {
            guard let functionDict = callDict["function"] as? [String: Any],
                  let name = functionDict["name"] as? String,
                  toolNames.contains(name) else {
                continue
            }
            
            // Always generate a unique ID (don't use model-provided IDs as they're often templates)
            let id = "call_\(generateCallID())"
            
            // Get type, default to "function"
            let type = (callDict["type"] as? String) ?? "function"
            
            // Serialize arguments back to JSON string
            let arguments: String
            if let args = functionDict["arguments"] {
                if var argsDict = args as? [String: Any] {
                    // Unwrap "properties" wrapper if the model incorrectly used schema format
                    // e.g., {"properties":{"city":"Tokyo"}} -> {"city":"Tokyo"}
                    if let properties = argsDict["properties"] as? [String: Any], argsDict.count == 1 {
                        argsDict = properties
                    }
                    if let argsData = try? JSONSerialization.data(withJSONObject: argsDict),
                       let argsString = String(data: argsData, encoding: .utf8) {
                        arguments = argsString
                    } else {
                        arguments = "{}"
                    }
                } else if let argsString = args as? String {
                    // If it's already a string, try to unwrap properties from it
                    if let data = argsString.data(using: .utf8),
                       var parsedArgs = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let properties = parsedArgs["properties"] as? [String: Any],
                       parsedArgs.count == 1,
                       let unwrappedData = try? JSONSerialization.data(withJSONObject: properties),
                       let unwrappedString = String(data: unwrappedData, encoding: .utf8) {
                        arguments = unwrappedString
                    } else {
                        arguments = argsString
                    }
                } else {
                    arguments = "{}"
                }
            } else {
                arguments = "{}"
            }
            
            toolCalls.append(ToolCall(
                id: id,
                type: type,
                function: FunctionCall(name: name, arguments: arguments)
            ))
        }
        
        return toolCalls.isEmpty ? nil : toolCalls
    }
    
    /// Strip markdown code fences from text.
    private static func stripCodeFences(_ text: String) -> String {
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
    
    /// Generate a unique call ID.
    private static func generateCallID() -> String {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        return String((0..<24).map { _ in chars.randomElement()! })
    }
}
