/**
 * Test client setup for syslm conformance tests
 * 
 * Environment variables:
 * - TEST_TARGET: 'syslm' (default) or 'openrouter'
 * - SYSLM_BASE_URL: Base URL for syslm server (default: http://localhost:8765/v1)
 * - OPENROUTER_API_KEY: API key for OpenRouter (required when TEST_TARGET=openrouter)
 * - OPENROUTER_MODEL: Model to use on OpenRouter (default: meta-llama/llama-3.2-3b-instruct:free)
 */

import OpenAI from 'openai';

const TEST_TARGET = process.env.TEST_TARGET ?? 'syslm';

// syslm configuration
const SYSLM_BASE_URL = process.env.SYSLM_BASE_URL ?? 'http://localhost:8765/v1';

// OpenRouter configuration
const OPENROUTER_BASE_URL = 'https://openrouter.ai/api/v1';
const OPENROUTER_API_KEY = process.env.OPENROUTER_API_KEY ?? '';
const OPENROUTER_MODEL = process.env.OPENROUTER_MODEL ?? 'qwen/qwen3-4b:free';

/**
 * Create an OpenAI client configured based on TEST_TARGET
 */
export function createClient(): OpenAI {
  if (TEST_TARGET === 'openrouter') {
    if (!OPENROUTER_API_KEY) {
      throw new Error('OPENROUTER_API_KEY environment variable is required when TEST_TARGET=openrouter');
    }
    return new OpenAI({
      baseURL: OPENROUTER_BASE_URL,
      apiKey: OPENROUTER_API_KEY,
      defaultHeaders: {
        'HTTP-Referer': 'https://github.com/syslm/conformance-tests',
        'X-Title': 'syslm Conformance Tests',
      },
    });
  }

  // Default: syslm
  return new OpenAI({
    baseURL: SYSLM_BASE_URL,
    apiKey: 'test-key', // syslm doesn't require auth, but SDK needs a value
  });
}

/**
 * Get the model to use based on TEST_TARGET
 */
export function getModel(): string {
  if (TEST_TARGET === 'openrouter') {
    return OPENROUTER_MODEL;
  }
  return 'ondevice';
}

/**
 * Default model to use in tests (for backward compatibility)
 */
export const MODEL = getModel();

/**
 * Check if we're testing against syslm or OpenRouter
 */
export function isTestingOpenRouter(): boolean {
  return TEST_TARGET === 'openrouter';
}

/**
 * Check if we're testing against syslm
 */
export function isTestingSyslm(): boolean {
  return TEST_TARGET === 'syslm';
}

/**
 * Helper to check if server is running (only relevant for syslm)
 */
export async function isServerRunning(): Promise<boolean> {
  if (TEST_TARGET === 'openrouter') {
    // For OpenRouter, just verify we have an API key
    return !!OPENROUTER_API_KEY;
  }

  try {
    const response = await fetch(`${SYSLM_BASE_URL.replace('/v1', '')}/health`);
    return response.ok;
  } catch {
    return false;
  }
}

/**
 * Get a description of the current test target for logging
 */
export function getTestTargetDescription(): string {
  if (TEST_TARGET === 'openrouter') {
    return `OpenRouter (${OPENROUTER_MODEL})`;
  }
  return `syslm (${SYSLM_BASE_URL})`;
}
