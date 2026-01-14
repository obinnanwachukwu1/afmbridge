/**
 * Usage tracking tests
 * Tests that token usage is properly returned in responses
 */

import { describe, it, expect, beforeAll } from 'vitest';
import { createClient, MODEL, isServerRunning, isTestingSyslm } from './client';

describe('Usage Tracking', () => {
  const client = createClient();

  beforeAll(async () => {
    const running = await isServerRunning();
    if (!running) {
      throw new Error(
        'afmbridge-server is not running. Start it with: swift run afmbridge-server --port 8765'
      );
    }
  });

  it('should return usage in non-streaming response', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Say "hello".' }],
    });

    // Usage should be present
    expect(response.usage).toBeDefined();
    expect(response.usage).not.toBeNull();
    
    // Check usage structure
    expect(response.usage!.prompt_tokens).toBeTypeOf('number');
    expect(response.usage!.completion_tokens).toBeTypeOf('number');
    expect(response.usage!.total_tokens).toBeTypeOf('number');
    
    // Values should be positive
    expect(response.usage!.prompt_tokens).toBeGreaterThan(0);
    expect(response.usage!.completion_tokens).toBeGreaterThan(0);
    expect(response.usage!.total_tokens).toBeGreaterThan(0);
    
    // Total should equal prompt + completion
    expect(response.usage!.total_tokens).toBe(
      response.usage!.prompt_tokens + response.usage!.completion_tokens
    );
  });

  it('should return usage in streaming response final chunk', async () => {
    const stream = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Say "world".' }],
      stream: true,
    });

    let lastChunk: any = null;
    let usageChunk: any = null;
    
    for await (const chunk of stream) {
      lastChunk = chunk;
      if (chunk.usage) {
        usageChunk = chunk;
      }
    }

    // Usage should be in the final chunk or a dedicated chunk
    expect(usageChunk).not.toBeNull();
    expect(usageChunk.usage).toBeDefined();
    expect(usageChunk.usage.prompt_tokens).toBeTypeOf('number');
    expect(usageChunk.usage.completion_tokens).toBeTypeOf('number');
    expect(usageChunk.usage.total_tokens).toBeTypeOf('number');
    
    // Values should be positive
    expect(usageChunk.usage.prompt_tokens).toBeGreaterThan(0);
    expect(usageChunk.usage.completion_tokens).toBeGreaterThan(0);
    expect(usageChunk.usage.total_tokens).toBeGreaterThan(0);
  });

  it('should estimate higher prompt tokens for longer messages', async () => {
    // Short message
    const shortResponse = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Hi' }],
    });

    // Long message
    const longResponse = await client.chat.completions.create({
      model: MODEL,
      messages: [
        { role: 'user', content: 'This is a much longer message with many more words and characters that should result in significantly more prompt tokens being counted by the token estimator.' }
      ],
    });

    expect(shortResponse.usage).toBeDefined();
    expect(longResponse.usage).toBeDefined();
    
    // Longer message should have more prompt tokens
    expect(longResponse.usage!.prompt_tokens).toBeGreaterThan(
      shortResponse.usage!.prompt_tokens
    );
  });

  it('should include system message tokens in prompt count', async () => {
    // Without system message
    const withoutSystem = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Say hi.' }],
    });

    // With system message
    const withSystem = await client.chat.completions.create({
      model: MODEL,
      messages: [
        { role: 'system', content: 'You are a helpful assistant that provides detailed explanations.' },
        { role: 'user', content: 'Say hi.' }
      ],
    });

    expect(withoutSystem.usage).toBeDefined();
    expect(withSystem.usage).toBeDefined();
    
    // With system message should have more prompt tokens
    expect(withSystem.usage!.prompt_tokens).toBeGreaterThan(
      withoutSystem.usage!.prompt_tokens
    );
  });

  it('should return usage with tool calls', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'What is the weather in Tokyo?' }],
      tools: [
        {
          type: 'function' as const,
          function: {
            name: 'get_weather',
            description: 'Get the current weather for a city',
            parameters: {
              type: 'object',
              properties: {
                city: { type: 'string', description: 'City name' }
              },
              required: ['city']
            }
          }
        }
      ],
      tool_choice: 'auto',
    });

    // Usage should still be present even with tool calls
    expect(response.usage).toBeDefined();
    expect(response.usage!.prompt_tokens).toBeGreaterThan(0);
    expect(response.usage!.completion_tokens).toBeGreaterThan(0);
    expect(response.usage!.total_tokens).toBeGreaterThan(0);
  });

  it('should return usage with structured output', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Generate a person with name "John" and age 30.' }],
      response_format: {
        type: 'json_schema',
        json_schema: {
          name: 'person',
          strict: true,
          schema: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              age: { type: 'number' }
            },
            required: ['name', 'age']
          }
        }
      }
    });

    // Usage should be present with structured output
    expect(response.usage).toBeDefined();
    expect(response.usage!.prompt_tokens).toBeGreaterThan(0);
    expect(response.usage!.completion_tokens).toBeGreaterThan(0);
    expect(response.usage!.total_tokens).toBeGreaterThan(0);
  });
});
