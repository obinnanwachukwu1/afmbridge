import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    globals: true,
    environment: 'node',
    testTimeout: 60000, // 60s timeout for LLM responses
    hookTimeout: 30000,
    include: ['src/**/*.test.ts'],
    reporters: ['verbose'],
    setupFiles: ['./src/setup.ts'],
    globalSetup: ['./src/global-setup.ts'],
  },
});
