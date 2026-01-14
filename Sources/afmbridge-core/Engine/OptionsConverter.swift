// afmbridge-core/Engine/OptionsConverter.swift
// Converts OpenRouter parameters to FoundationModels GenerationOptions

import Foundation
import FoundationModels

/// Converts OpenRouter parameters to FoundationModels GenerationOptions.
/// Reference: https://developer.apple.com/documentation/foundationmodels/generationoptions/
struct OptionsConverter {
    
    /// Convert OpenRouter request parameters to FoundationModels GenerationOptions.
    /// - Parameter request: The chat completion request
    /// - Returns: Configured GenerationOptions
    static func convert(from request: ChatCompletionRequest) -> GenerationOptions {
        var options = GenerationOptions()
        
        // Temperature: OpenRouter range 0-2, FoundationModels expects similar
        if let temperature = request.temperature {
            options.temperature = temperature
        }
        
        // Max tokens
        // Reference: https://developer.apple.com/documentation/foundationmodels/generationoptions/maximumresponsetokens
        if let maxTokens = request.maxTokens {
            options.maximumResponseTokens = maxTokens
        }
        
        // Note: FoundationModels doesn't directly support these OpenRouter parameters:
        // - topP: Not available in GenerationOptions
        // - topK: Not available in current API
        // - frequencyPenalty: Not available
        // - presencePenalty: Not available
        // - seed: Not available for deterministic sampling
        // - stop: Not available for custom stop sequences
        
        return options
    }
}
