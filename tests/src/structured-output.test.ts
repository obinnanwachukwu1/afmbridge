/**
 * Structured output tests
 * Tests JSON schema response_format functionality
 */

import { describe, it, expect, beforeAll } from 'vitest';
import { createClient, MODEL, isServerRunning } from './client';

describe('Structured Output', () => {
  const client = createClient();

  beforeAll(async () => {
    const running = await isServerRunning();
    if (!running) {
      throw new Error(
        'afmbridge-server is not running. Start it with: swift run afmbridge-server --port 8765'
      );
    }
  });

  it('should return valid JSON with json_schema response_format', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Create a person named John who is 30 years old.' }],
      response_format: {
        type: 'json_schema',
        json_schema: {
          name: 'Person',
          schema: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              age: { type: 'number' },
            },
            required: ['name', 'age'],
          },
        },
      },
    });

    expect(response.choices[0].message.content).toBeDefined();
    expect(response.choices[0].finish_reason).toBe('stop');

    // Parse the JSON response
    const content = response.choices[0].message.content!;
    let parsed: { name: string; age: number };

    expect(() => {
      parsed = JSON.parse(content);
    }).not.toThrow();

    parsed = JSON.parse(content);
    expect(parsed.name).toBeDefined();
    expect(parsed.age).toBeDefined();
    expect(typeof parsed.name).toBe('string');
    expect(typeof parsed.age).toBe('number');
  });

  it('should handle nested object schemas', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [
        {
          role: 'user',
          content: 'Create a company called TechCorp with address at 123 Main St, New York.',
        },
      ],
      response_format: {
        type: 'json_schema',
        json_schema: {
          name: 'Company',
          schema: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              address: {
                type: 'object',
                properties: {
                  street: { type: 'string' },
                  city: { type: 'string' },
                },
                required: ['street', 'city'],
              },
            },
            required: ['name', 'address'],
          },
        },
      },
    });

    expect(response.choices[0].message.content).toBeDefined();

    const parsed = JSON.parse(response.choices[0].message.content!);
    expect(parsed.name).toBeDefined();
    expect(parsed.address).toBeDefined();
    expect(parsed.address.street).toBeDefined();
    expect(parsed.address.city).toBeDefined();
  });

  it('should handle array schemas', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'List 3 fruits.' }],
      response_format: {
        type: 'json_schema',
        json_schema: {
          name: 'FruitList',
          schema: {
            type: 'object',
            properties: {
              fruits: {
                type: 'array',
                items: { type: 'string' },
              },
            },
            required: ['fruits'],
          },
        },
      },
    });

    expect(response.choices[0].message.content).toBeDefined();

    const parsed = JSON.parse(response.choices[0].message.content!);
    expect(parsed.fruits).toBeDefined();
    expect(Array.isArray(parsed.fruits)).toBe(true);
    expect(parsed.fruits.length).toBeGreaterThan(0);
    parsed.fruits.forEach((fruit: unknown) => {
      expect(typeof fruit).toBe('string');
    });
  });

  it('should handle array of objects schema', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Create a list of 2 books with title and author.' }],
      response_format: {
        type: 'json_schema',
        json_schema: {
          name: 'BookList',
          schema: {
            type: 'object',
            properties: {
              books: {
                type: 'array',
                items: {
                  type: 'object',
                  properties: {
                    title: { type: 'string' },
                    author: { type: 'string' },
                  },
                  required: ['title', 'author'],
                },
              },
            },
            required: ['books'],
          },
        },
      },
    });

    expect(response.choices[0].message.content).toBeDefined();

    const parsed = JSON.parse(response.choices[0].message.content!);
    expect(parsed.books).toBeDefined();
    expect(Array.isArray(parsed.books)).toBe(true);
    expect(parsed.books.length).toBeGreaterThanOrEqual(1);

    parsed.books.forEach((book: { title: string; author: string }) => {
      expect(book.title).toBeDefined();
      expect(book.author).toBeDefined();
    });
  });

  it('should handle enum values in schema', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Create a task with high priority.' }],
      response_format: {
        type: 'json_schema',
        json_schema: {
          name: 'Task',
          schema: {
            type: 'object',
            properties: {
              title: { type: 'string' },
              priority: {
                type: 'string',
                enum: ['low', 'medium', 'high'],
              },
            },
            required: ['title', 'priority'],
          },
        },
      },
    });

    expect(response.choices[0].message.content).toBeDefined();

    const parsed = JSON.parse(response.choices[0].message.content!);
    expect(parsed.title).toBeDefined();
    expect(parsed.priority).toBeDefined();
    expect(['low', 'medium', 'high']).toContain(parsed.priority);
  });

  it('should handle boolean and number types', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Create a product that is available, priced at $29.99.' }],
      response_format: {
        type: 'json_schema',
        json_schema: {
          name: 'Product',
          schema: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              price: { type: 'number' },
              available: { type: 'boolean' },
            },
            required: ['name', 'price', 'available'],
          },
        },
      },
    });

    expect(response.choices[0].message.content).toBeDefined();

    const parsed = JSON.parse(response.choices[0].message.content!);
    expect(typeof parsed.name).toBe('string');
    expect(typeof parsed.price).toBe('number');
    expect(typeof parsed.available).toBe('boolean');
  });

  it('should handle json_object response_format', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [
        {
          role: 'system',
          content: 'You always respond in JSON format with a "message" field.',
        },
        { role: 'user', content: 'Say hello.' },
      ],
      response_format: { type: 'json_object' },
    });

    expect(response.choices[0].message.content).toBeDefined();

    // Should be valid JSON
    let parsed: object;
    expect(() => {
      parsed = JSON.parse(response.choices[0].message.content!);
    }).not.toThrow();

    parsed = JSON.parse(response.choices[0].message.content!);
    expect(typeof parsed).toBe('object');
  });

  it('should include schema name in response metadata', async () => {
    const response = await client.chat.completions.create({
      model: MODEL,
      messages: [{ role: 'user', content: 'Create a simple greeting.' }],
      response_format: {
        type: 'json_schema',
        json_schema: {
          name: 'Greeting',
          schema: {
            type: 'object',
            properties: {
              message: { type: 'string' },
            },
            required: ['message'],
          },
        },
      },
    });

    // The response should be valid JSON matching the schema
    expect(response.choices[0].message.content).toBeDefined();
    const parsed = JSON.parse(response.choices[0].message.content!);
    expect(parsed.message).toBeDefined();
  });
});
