import { it, expect, describe, beforeAll, afterAll } from 'vitest';
import { OpenAI } from 'openai';
import { isTestingSyslm } from './client';
import { spawn, ChildProcess } from 'child_process';
import path from 'path';
import fs from 'fs';
import http from 'http';

describe('Socket HTTP Queue Limit', () => {
    if (!isTestingSyslm()) {
        it.skip('Socket tests are specific to afmbridge architecture', () => {});
        return;
    }

    let serverProcess: ChildProcess | null = null;
    let client: OpenAI;
    const SOCKET_PATH = path.resolve('/tmp', `afmbridge-test-${Date.now()}.sock`);

    // Find the server binary
    const projectRoot = path.resolve(__dirname, '../../');
    const debugPath = path.join(projectRoot, '.build/debug/afmbridge-server');
    const releasePath = path.join(projectRoot, '.build/release/afmbridge-server');
    const serverPath = fs.existsSync(debugPath) ? debugPath : releasePath;

    beforeAll(async () => {
        // Cleanup potential stale socket
        if (fs.existsSync(SOCKET_PATH)) {
            fs.unlinkSync(SOCKET_PATH);
        }

        return new Promise<void>((resolve, reject) => {
            console.log(`Spawning dedicated server on socket ${SOCKET_PATH} with max-queue-size 2...`);
            
            serverProcess = spawn(serverPath, [
                '--socket', SOCKET_PATH,
                '--max-queue-size', '2'
            ], {
                stdio: 'ignore'
            });

            serverProcess.on('error', (err) => {
                console.error('Failed to start server:', err);
                reject(err);
            });

            // Poll for socket file creation
            const start = Date.now();
            const checkSocket = () => {
                if (fs.existsSync(SOCKET_PATH)) {
                    // Configure OpenAI client to use Unix Socket
                    client = new OpenAI({
                        apiKey: 'test-key',
                        baseURL: 'http://localhost/v1', // Host doesn't matter for socket, but path /v1 does
                        httpAgent: new http.Agent({
                            socketPath: SOCKET_PATH
                        })
                    });
                    resolve();
                } else if (Date.now() - start > 5000) {
                    reject(new Error('Timed out waiting for socket file'));
                } else {
                    setTimeout(checkSocket, 100);
                }
            };
            checkSocket();
        });
    });

    afterAll(() => {
        if (serverProcess) {
            console.log('Killing dedicated server...');
            serverProcess.kill();
            serverProcess = null;
        }
        if (fs.existsSync(SOCKET_PATH)) {
            fs.unlinkSync(SOCKET_PATH);
        }
    });

    it('should reject requests when queue is full over unix socket', async () => {
        // Same logic as queue-limit.test.ts but over socket
        // Request 1: Active
        // Request 2: Queued
        // Request 3: Rejected (429)

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
        
        const fulfilled = results.filter(r => r.status === 'fulfilled');
        const rejected = results.filter(r => r.status === 'rejected');
        
        expect(fulfilled.length).toBe(2);
        expect(rejected.length).toBe(1);
        
        if (rejected[0].status === 'rejected') {
            const error = rejected[0].reason;
            expect(error.status).toBe(429);
            expect(error.error.type).toBe('rate_limit_error');
        }
    });
});
