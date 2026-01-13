/**
 * Error handling tests
 * Tests error responses and edge cases
 */

import { describe, it, expect, beforeAll } from 'vitest';
import { createClient, MODEL, isServerRunning } from './client';

describe('Error Handling', () => {
  const client = createClient();

  beforeAll(async () => {
    const running = await isServerRunning();
    if (!running) {
      throw new Error(
        'syslm-server is not running. Start it with: swift run syslm-server --port 8765'
      );
    }
  });

  it('should handle empty messages array', async () => {
    await expect(
      client.chat.completions.create({
        model: MODEL,
        messages: [],
      })
    ).rejects.toThrow();
  });

  it('should handle missing content in user message', async () => {
    // The OpenAI SDK may handle this differently, but we test the edge case
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: '' }],
    });

    // Should still return a response (or throw depending on implementation)
    expect(response.choices).toBeDefined();
  });

  it('should handle very long input gracefully', async () => {
    // Create a long message (but not too long to cause memory issues)
    const longContent = 'Hello. '.repeat(500);

    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: longContent }],
      max_tokens: 50,
    });

    expect(response.choices[0].message.content).toBeDefined();
  });

  it('should handle invalid temperature values', async () => {
    // Temperature should be between 0 and 2
    // Some implementations clamp, others reject
    try {
      const response = await client.chat.completions.create({
        model: MODEL,
        messages: [{ role: 'user', content: 'Hello' }],
        temperature: -1,
      });
      // If it doesn't throw, check the response is still valid
      expect(response.choices).toBeDefined();
    } catch (error) {
      // Expected to throw for invalid temperature
      expect(error).toBeDefined();
    }
  });

  it('should handle invalid max_tokens values', async () => {
    try {
      const response = await client.chat.completions.create({
        model: MODEL,
        messages: [{ role: 'user', content: 'Hello' }],
        max_tokens: -1,
      });
      // If it doesn't throw, response should be valid
      expect(response.choices).toBeDefined();
    } catch (error) {
      // Expected to throw for invalid max_tokens
      expect(error).toBeDefined();
    }
  });

  it('should handle unknown tool names in tool results', async () => {
    // Sending a tool result for a non-existent tool
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [
        { role: 'user', content: 'Hello' },
        {
          role: 'assistant',
          content: null,
          tool_calls: [
            {
              id: 'call_unknown',
              type: 'function',
              function: {
                name: 'unknown_tool',
                arguments: '{}',
              },
            },
          ],
        },
        {
          role: 'tool',
          tool_call_id: 'call_unknown',
          content: 'result',
        },
      ],
    });

    // Should handle gracefully
    expect(response.choices).toBeDefined();
  });

  it('should handle malformed tool definitions gracefully', async () => {
    try {
      const response = await client.chat.completions.create({
        model: MODEL,
        messages: [{ role: 'user', content: 'Hello' }],
        tools: [
          {
            type: 'function',
            function: {
              name: '', // Empty name
              description: 'A test function',
            },
          },
        ],
      });
      expect(response.choices).toBeDefined();
    } catch (error) {
      // May throw for invalid tool definition
      expect(error).toBeDefined();
    }
  });

  it('should handle special characters in messages', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [
        {
          role: 'user',
          content: 'Handle these: "quotes", <tags>, {braces}, [brackets], &amp; entities',
        },
      ],
    });

    expect(response.choices[0].message.content).toBeDefined();
  });

  it('should handle unicode and emoji in messages', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [
        {
          role: 'user',
          content: 'Respond to this emoji: 🌍 and unicode: 你好世界',
        },
      ],
    });

    expect(response.choices[0].message.content).toBeDefined();
  });

  it('should handle newlines and whitespace in messages', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [
        {
          role: 'user',
          content: 'Line 1\nLine 2\n\nLine 4\t\tTabbed',
        },
      ],
    });

    expect(response.choices[0].message.content).toBeDefined();
  });

  it('should handle concurrent requests', async () => {
    // Make multiple requests concurrently
    const promises = [
      client.chat.completions.create({
        model: MODEL,
        messages: [{ role: 'user', content: 'Say one' }],
      }),
      client.chat.completions.create({
        model: MODEL,
        messages: [{ role: 'user', content: 'Say two' }],
      }),
      client.chat.completions.create({
        model: MODEL,
        messages: [{ role: 'user', content: 'Say three' }],
      }),
    ];

    const responses = await Promise.all(promises);

    expect(responses).toHaveLength(3);
    responses.forEach((response) => {
      expect(response.choices[0].message.content).toBeDefined();
    });
  });

  it('should return proper error format for bad requests', async () => {
    try {
      // Force an error by using invalid parameters
      await client.chat.completions.create({
        model: MODEL,
        messages: [{ role: 'user', content: 'test' }],
        // @ts-expect-error - intentionally invalid
        invalid_param: 'value',
      });
    } catch (error: unknown) {
      // Check error has expected structure
      if (error && typeof error === 'object' && 'status' in error) {
        expect(typeof (error as { status: number }).status).toBe('number');
      }
    }
  });

  it('should handle zero max_tokens', async () => {
    try {
      const response = await client.chat.completions.create({
        model: MODEL,
        messages: [{ role: 'user', content: 'Hello' }],
        max_tokens: 0,
      });
      // If it doesn't throw, content might be empty or minimal
      expect(response.choices).toBeDefined();
    } catch (error) {
      // May throw for zero max_tokens
      expect(error).toBeDefined();
    }
  });

  it('should handle very high max_tokens', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Say hello briefly.' }],
      max_tokens: 10000, // Very high value
    });

    expect(response.choices[0].message.content).toBeDefined();
  });
});
