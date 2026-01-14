/**
 * Streaming tests
 * Tests SSE streaming responses
 */

import { describe, it, expect, beforeAll } from 'vitest';
import type { ChatCompletionTool } from 'openai/resources/chat/completions';
import { createClient, MODEL, isServerRunning, isTestingSyslm } from './client';

describe('Streaming', () => {
  const client = createClient();

  beforeAll(async () => {
    const running = await isServerRunning();
    if (!running) {
      throw new Error(
        'afmbridge-server is not running. Start it with: swift run afmbridge-server --port 8765'
      );
    }
  });

  it('should stream text content in chunks', async () => {
    const stream = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Count from 1 to 5.' }],
      stream: true,
    });

    const chunks: string[] = [];
    let finishReason: string | null = null;
    let hasRoleChunk = false;

    for await (const chunk of stream) {
      expect(chunk.id).toBeDefined();
      expect(chunk.object).toBe('chat.completion.chunk');
      expect(chunk.model).toBeDefined();
      expect(chunk.choices).toHaveLength(1);

      const choice = chunk.choices[0];
      expect(choice.index).toBe(0);

      if (choice.delta.role) {
        hasRoleChunk = true;
        expect(choice.delta.role).toBe('assistant');
      }

      if (choice.delta.content) {
        chunks.push(choice.delta.content);
      }

      if (choice.finish_reason) {
        finishReason = choice.finish_reason;
      }
    }

    expect(hasRoleChunk).toBe(true);
    expect(chunks.length).toBeGreaterThan(0);
    expect(finishReason).toBe('stop');

    // Assembled content should contain numbers
    const fullContent = chunks.join('');
    expect(fullContent.length).toBeGreaterThan(0);
  });

  it('should have correct chunk structure', async () => {
    const stream = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Say hello.' }],
      stream: true,
    });

    let chunkCount = 0;
    let firstChunkCreated: number | undefined;

    for await (const chunk of stream) {
      chunkCount++;

      // All chunks should have these fields
      expect(chunk.id).toBeDefined();
      if (isTestingSyslm()) {
        expect(chunk.id).toMatch(/^chatcmpl-/);
      }
      expect(chunk.created).toBeTypeOf('number');

      if (!firstChunkCreated) {
        firstChunkCreated = chunk.created;
      } else {
        // All chunks should have the same created timestamp
        expect(chunk.created).toBe(firstChunkCreated);
      }

      // All chunks should have the same ID
      expect(chunk.choices[0].delta).toBeDefined();
    }

    expect(chunkCount).toBeGreaterThan(1);
  });

  it('should stream tool calls', async () => {
    const weatherTool: ChatCompletionTool = {
      type: 'function',
      function: {
        name: 'get_weather',
        description: 'Get the current weather for a city',
        parameters: {
          type: 'object',
          properties: {
            city: { type: 'string', description: 'The city name' },
          },
          required: ['city'],
        },
      },
    };

    const stream = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: "What's the weather in Tokyo?" }],
      tools: [weatherTool],
      stream: true,
    });

    let finishReason: string | null = null;
    let hasToolCallChunks = false;
    const toolCallParts: { name?: string; arguments?: string; id?: string }[] = [];

    for await (const chunk of stream) {
      const choice = chunk.choices[0];

      if (choice.delta.tool_calls) {
        hasToolCallChunks = true;

        for (const toolCallDelta of choice.delta.tool_calls) {
          const index = toolCallDelta.index;

          // Initialize if needed
          if (!toolCallParts[index]) {
            toolCallParts[index] = {};
          }

          if (toolCallDelta.id) {
            toolCallParts[index].id = toolCallDelta.id;
          }
          if (toolCallDelta.function?.name) {
            toolCallParts[index].name = toolCallDelta.function.name;
          }
          if (toolCallDelta.function?.arguments) {
            toolCallParts[index].arguments =
              (toolCallParts[index].arguments ?? '') + toolCallDelta.function.arguments;
          }
        }
      }

      if (choice.finish_reason) {
        finishReason = choice.finish_reason;
      }
    }

    expect(hasToolCallChunks).toBe(true);
    expect(finishReason).toBe('tool_calls');
    expect(toolCallParts.length).toBeGreaterThan(0);

    // Verify the assembled tool call
    const toolCall = toolCallParts[0];
    expect(toolCall.id).toBeDefined();
    expect(toolCall.id).toMatch(/^call_/);
    expect(toolCall.name).toBe('get_weather');
    expect(toolCall.arguments).toBeDefined();

    // Parse the assembled arguments
    const args = JSON.parse(toolCall.arguments!);
    expect(args.city).toBeDefined();
  });

  it('should handle long streaming responses', async () => {
    const stream = await client.chat.completions.create({
      model: MODEL,
      messages: [
        {
          role: 'user',
          content: 'Write a short paragraph about the ocean.',
        },
      ],
      stream: true,
    });

    let totalContent = '';
    let chunkCount = 0;

    for await (const chunk of stream) {
      chunkCount++;
      if (chunk.choices[0].delta.content) {
        totalContent += chunk.choices[0].delta.content;
      }
    }

    expect(chunkCount).toBeGreaterThan(5); // Should have multiple chunks
    expect(totalContent.length).toBeGreaterThan(50); // Should have substantial content
  });

  it('should handle system messages in streaming', async () => {
    const stream = await client.chat.completions.create({
      model: MODEL,
      messages: [
        { role: 'system', content: 'You are a helpful assistant that speaks in haikus.' },
        { role: 'user', content: 'Describe the moon.' },
      ],
      stream: true,
    });

    let totalContent = '';

    for await (const chunk of stream) {
      if (chunk.choices[0].delta.content) {
        totalContent += chunk.choices[0].delta.content;
      }
    }

    expect(totalContent.length).toBeGreaterThan(0);
  });

  it('should respect max_tokens in streaming', async () => {
    const stream = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Write a very long story about dragons.' }],
      stream: true,
      max_tokens: 30,
    });

    let totalContent = '';

    for await (const chunk of stream) {
      if (chunk.choices[0].delta.content) {
        totalContent += chunk.choices[0].delta.content;
      }
    }

    // With max_tokens=30, content should be limited
    const words = totalContent.split(/\s+/).length;
    expect(words).toBeLessThan(100); // Generous upper bound
  });

  it('should have consistent IDs across all chunks', async () => {
    const stream = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Hello!' }],
      stream: true,
    });

    const ids: string[] = [];

    for await (const chunk of stream) {
      ids.push(chunk.id);
    }

    // All chunks should have the same ID
    const uniqueIds = [...new Set(ids)];
    expect(uniqueIds).toHaveLength(1);
  });
});
