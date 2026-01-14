/**
 * Tool calling tests
 * Tests function/tool calling capabilities
 */

import { describe, it, expect, beforeAll } from 'vitest';
import type { ChatCompletionTool, ChatCompletionMessageParam } from 'openai/resources/chat/completions';
import { createClient, MODEL, isServerRunning } from './client';

describe('Tool Calling', () => {
  const client = createClient();

  const weatherTool: ChatCompletionTool = {
    type: 'function',
    function: {
      name: 'get_weather',
      description: 'Get the current weather for a city',
      parameters: {
        type: 'object',
        properties: {
          city: {
            type: 'string',
            description: 'The city name',
          },
          unit: {
            type: 'string',
            enum: ['celsius', 'fahrenheit'],
            description: 'Temperature unit',
          },
        },
        required: ['city'],
      },
    },
  };

  const calculatorTool: ChatCompletionTool = {
    type: 'function',
    function: {
      name: 'calculate',
      description: 'Perform a mathematical calculation',
      parameters: {
        type: 'object',
        properties: {
          expression: {
            type: 'string',
            description: 'The mathematical expression to evaluate',
          },
        },
        required: ['expression'],
      },
    },
  };

  beforeAll(async () => {
    const running = await isServerRunning();
    if (!running) {
      throw new Error(
        'afmbridge-server is not running. Start it with: swift run afmbridge-server --port 8765'
      );
    }
  });

  it('should emit tool_calls when tools are provided', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: "What's the weather in Tokyo?" }],
      tools: [weatherTool],
    });

    expect(response.choices[0].finish_reason).toBe('tool_calls');
    expect(response.choices[0].message.tool_calls).toBeDefined();
    expect(response.choices[0].message.tool_calls!.length).toBeGreaterThanOrEqual(1);

    const toolCall = response.choices[0].message.tool_calls![0];
    expect(toolCall.id).toBeDefined();
    expect(toolCall.id).toMatch(/^call_/);
    expect(toolCall.type).toBe('function');
    expect(toolCall.function.name).toBe('get_weather');

    // Parse and validate arguments
    const args = JSON.parse(toolCall.function.arguments);
    // The city could be at args.city or the arguments string could contain "tokyo"
    const argsStr = toolCall.function.arguments.toLowerCase();
    expect(argsStr).toContain('tokyo');
  });

  it('should respect tool_choice=none', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: "What's the weather in Paris?" }],
      tools: [weatherTool],
      tool_choice: 'none',
    });

    expect(response.choices[0].finish_reason).toBe('stop');
    expect(response.choices[0].message.tool_calls).toBeUndefined();
    expect(response.choices[0].message.content).toBeDefined();
  });

  it('should handle tool_choice=auto (default behavior)', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: "What's the weather like in London?" }],
      tools: [weatherTool],
      tool_choice: 'auto',
    });

    // With auto, model should choose to call the weather tool
    expect(response.choices[0].finish_reason).toBe('tool_calls');
    expect(response.choices[0].message.tool_calls).toBeDefined();
  });

  it('should handle tool results in conversation', async () => {
    // First, get the tool call
    const firstResponse = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: "What's the weather in New York?" }],
      tools: [weatherTool],
    });

    expect(firstResponse.choices[0].message.tool_calls).toBeDefined();
    const toolCall = firstResponse.choices[0].message.tool_calls![0];

    // Now send the tool result back
    const messages: ChatCompletionMessageParam[] = [
      { role: 'user', content: "What's the weather in New York?" },
      {
        role: 'assistant',
        content: null,
        tool_calls: [
          {
            id: toolCall.id,
            type: 'function',
            function: {
              name: toolCall.function.name,
              arguments: toolCall.function.arguments,
            },
          },
        ],
      },
      {
        role: 'tool',
        tool_call_id: toolCall.id,
        content: JSON.stringify({ temperature: 72, condition: 'sunny', humidity: 45 }),
      },
    ];

    const secondResponse = await client.chat.completions.create({
      model: MODEL,
      messages,
      tools: [weatherTool],
    });

    expect(secondResponse.choices[0].finish_reason).toBe('stop');
    expect(secondResponse.choices[0].message.content).toBeDefined();
    // Response should mention the weather details
    const content = secondResponse.choices[0].message.content!.toLowerCase();
    expect(content).toMatch(/72|sunny|weather/i);
  });

  it('should handle multiple tools', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Can you calculate the sum of 25 and 17 for me?' }],
      tools: [weatherTool, calculatorTool],
    });

    expect(response.choices[0].finish_reason).toBe('tool_calls');
    expect(response.choices[0].message.tool_calls).toBeDefined();

    const toolCall = response.choices[0].message.tool_calls![0];
    expect(toolCall.function.name).toBe('calculate');

    const args = JSON.parse(toolCall.function.arguments);
    expect(args.expression).toBeDefined();
  });

  it('should generate unique tool call IDs', async () => {
    const response1 = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: "What's the weather in Berlin?" }],
      tools: [weatherTool],
    });

    const response2 = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: "What's the weather in Madrid?" }],
      tools: [weatherTool],
    });

    const id1 = response1.choices[0].message.tool_calls?.[0]?.id;
    const id2 = response2.choices[0].message.tool_calls?.[0]?.id;

    expect(id1).toBeDefined();
    expect(id2).toBeDefined();
    expect(id1).not.toBe(id2);
  });
});
