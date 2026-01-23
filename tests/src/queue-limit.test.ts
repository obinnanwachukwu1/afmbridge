import { it, expect, describe, beforeAll, afterAll } from 'vitest';
import { OpenAI } from 'openai';
import { isTestingSyslm } from './client';
import { spawn, ChildProcess } from 'child_process';
import path from 'path';
import fs from 'fs';

describe('Queue Limit', () => {
    if (!isTestingSyslm()) {
        it.skip('Queue limit tests are specific to afmbridge architecture', () => {});
        return;
    }

    let serverProcess: ChildProcess | null = null;
    let client: OpenAI;
    const TEST_PORT = 8766;

    // Find the server binary
    const projectRoot = path.resolve(__dirname, '../../');
    // Try debug path first, then release
    const debugPath = path.join(projectRoot, '.build/debug/afmbridge-server');
    const releasePath = path.join(projectRoot, '.build/release/afmbridge-server');
    const serverPath = fs.existsSync(debugPath) ? debugPath : releasePath;

    beforeAll(async () => {
        // Start a dedicated server instance with a small queue limit
        return new Promise<void>((resolve, reject) => {
            console.log(`Spawning dedicated server on port ${TEST_PORT} with max-queue-size 2...`);
            
            serverProcess = spawn(serverPath, [
                '--port', TEST_PORT.toString(),
                '--max-queue-size', '2'
            ], {
                stdio: 'ignore' // Ignore output to keep test logs clean
            });

            serverProcess.on('error', (err) => {
                console.error('Failed to start server:', err);
                reject(err);
            });

            // Give it a moment to start up
            setTimeout(() => {
                client = new OpenAI({
                    baseURL: `http://localhost:${TEST_PORT}/v1`,
                    apiKey: 'test-key',
                });
                resolve();
            }, 2000);
        });
    });

    afterAll(() => {
        if (serverProcess) {
            console.log('Killing dedicated server...');
            serverProcess.kill();
            serverProcess = null;
        }
    });

    it('should reject requests when queue is full', async () => {
        // Send 3 requests. 
        // With --max-queue-size 2:
        // Request 1: Active
        // Request 2: Queued
        // Request 3: Rejected (429)

        const start = Date.now();
        
        // Use promises to send requests concurrently with longer generation to ensure overlap
        const req1 = client.chat.completions.create({
            model: 'ondevice',
            messages: [{ role: 'user', content: 'Write a long paragraph about the history of the internet.' }],
            max_tokens: 100
        });
        
        const req2 = client.chat.completions.create({
            model: 'ondevice',
            messages: [{ role: 'user', content: 'Write a long paragraph about the history of computing.' }],
            max_tokens: 100
        });
        
        const req3 = client.chat.completions.create({
            model: 'ondevice',
            messages: [{ role: 'user', content: 'Write a long paragraph about the history of AI.' }],
            max_tokens: 100
        });

        const results = await Promise.allSettled([req1, req2, req3]);
        
        // Count fulfilled and rejected
        const fulfilled = results.filter(r => r.status === 'fulfilled');
        const rejected = results.filter(r => r.status === 'rejected');
        
        expect(fulfilled.length).toBe(2);
        expect(rejected.length).toBe(1);
        
        if (rejected[0].status === 'rejected') {
            const error = rejected[0].reason;
            expect(error.status).toBe(429); // 429 Too Many Requests
            expect(error.error.type).toBe('rate_limit_error');
        }
    });
});
