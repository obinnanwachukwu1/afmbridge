/**
 * Status flag tests
 * Verifies afmbridge-cli --status output and exit codes
 */

import { describe, it, expect, beforeAll } from 'vitest';
import { spawnSync } from 'child_process';
import path from 'path';
import fs from 'fs';
import { isTestingOpenRouter } from './client';

const projectRoot = path.resolve(__dirname, '../../');
const cliPath = path.join(projectRoot, '.build/debug/afmbridge-cli');

const describeIfLocal = isTestingOpenRouter() ? describe.skip : describe;

describeIfLocal('Status flag', () => {
  beforeAll(() => {
    if (fs.existsSync(cliPath)) {
      return;
    }

    const build = spawnSync('swift', ['build'], {
      cwd: projectRoot,
      stdio: 'inherit',
    });

    if (build.status !== 0) {
      throw new Error(`swift build failed with code ${build.status}`);
    }
  });

  it('prints JSON status and exits with expected code', () => {
    const result = spawnSync(cliPath, ['--status'], {
      encoding: 'utf8',
    });

    expect(result.error).toBeUndefined();
    expect(result.status).not.toBeNull();
    expect(result.stdout).toBeDefined();

    const line = result.stdout.trim();
    expect(line.length).toBeGreaterThan(0);

    const payload = JSON.parse(line) as { status: string; detail: string };
    expect(['available', 'unavailable', 'unknown']).toContain(payload.status);
    expect(typeof payload.detail).toBe('string');

    if (payload.status === 'available') {
      expect(result.status).toBe(0);
    } else if (payload.status === 'unavailable') {
      expect(result.status).toBe(2);
    } else {
      expect(result.status).toBe(1);
    }
  });
});
