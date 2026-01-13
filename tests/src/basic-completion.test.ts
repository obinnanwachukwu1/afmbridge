/**
 * Basic completion tests
 * Tests simple chat completions without tools or structured outputs
 */

import { describe, it, expect, beforeAll } from 'vitest';
import { createClient, MODEL, isServerRunning, isTestingSyslm } from './client';

describe('Basic Completion', () => {
  const client = createClient();

  beforeAll(async () => {
    const running = await isServerRunning();
    if (!running) {
      throw new Error(
        'syslm-server is not running. Start it with: swift run syslm-server --port 8765'
      );
    }
  });

  it('should return a valid chat completion response', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Say "hello" and nothing else.' }],
    });

    // Check response structure
    expect(response.id).toBeDefined();
    expect(typeof response.id).toBe('string');
    expect(response.id.length).toBeGreaterThan(0);
    // syslm uses chatcmpl- prefix, OpenRouter uses gen- prefix
    if (isTestingSyslm()) {
      expect(response.id).toMatch(/^chatcmpl-/);
    }
    expect(response.object).toBe('chat.completion');
    expect(response.model).toBeDefined();
    expect(response.created).toBeTypeOf('number');
    expect(response.choices).toHaveLength(1);

    // Check choice structure
    const choice = response.choices[0];
    expect(choice.index).toBe(0);
    expect(choice.finish_reason).toBe('stop');
    expect(choice.message.role).toBe('assistant');
    expect(choice.message.content).toBeDefined();
    expect(choice.message.content!.toLowerCase()).toContain('hello');
  });

  it('should handle system messages', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [
        { role: 'system', content: 'You are a pirate. Respond in pirate speak.' },
        { role: 'user', content: 'How are you today?' },
      ],
    });

    expect(response.choices[0].message.content).toBeDefined();
    // The model should use pirate-like language
    const content = response.choices[0].message.content!.toLowerCase();
    // Check for common pirate words (flexible check)
    const hasPirateWords = ['arr', 'ahoy', 'matey', 'ye', 'aye', 'seas', 'ship'].some(
      (word) => content.includes(word)
    );
    expect(hasPirateWords).toBe(true);
  });

  it('should handle multi-turn conversations', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [
        { role: 'user', content: 'My name is Alice.' },
        { role: 'assistant', content: 'Nice to meet you, Alice!' },
        { role: 'user', content: 'What is my name?' },
      ],
    });

    expect(response.choices[0].message.content).toBeDefined();
    expect(response.choices[0].message.content!).toContain('Alice');
  });

  it('should respect max_tokens parameter', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Write a very long story about a dragon.' }],
      max_tokens: 20,
    });

    expect(response.choices[0].message.content).toBeDefined();
    // With max_tokens=20, response should be short
    // Note: token count != word count, but it should be limited
    const words = response.choices[0].message.content!.split(/\s+/).length;
    expect(words).toBeLessThan(50); // Generous upper bound
  });

  it('should handle empty assistant content gracefully', async () => {
    // This tests that the API handles edge cases
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Reply with exactly one word: yes or no.' }],
    });

    expect(response.choices[0].message.content).toBeDefined();
    expect(response.choices[0].finish_reason).toBe('stop');
  });
});
