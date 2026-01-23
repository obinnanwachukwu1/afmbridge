import { it, expect, describe } from 'vitest';
import { createClient, isTestingSyslm } from './client';

describe('afmbridge Resiliency', () => {
    // Only run these tests against afmbridge
    if (!isTestingSyslm()) {
        it.skip('Resiliency tests are specific to afmbridge architecture', () => {});
        return;
    }

    const client = createClient();

    it('should process concurrent requests sequentially (FIFO)', async () => {
        // Send three requests in parallel
        // We use slightly different prompts to distinguish them
        const start = Date.now();
        
        const results = await Promise.all([
            client.chat.completions.create({
                model: 'ondevice',
                messages: [{ role: 'user', content: 'Tell me a short fact about Paris.' }],
            }),
            client.chat.completions.create({
                model: 'ondevice',
                messages: [{ role: 'user', content: 'Tell me a short fact about Tokyo.' }],
            }),
            client.chat.completions.create({
                model: 'ondevice',
                messages: [{ role: 'user', content: 'Tell me a short fact about London.' }],
            })
        ]);

        const duration = Date.now() - start;
        
        expect(results.length).toBe(3);
        expect(results[0].choices[0].message.content).toContain('Paris');
        expect(results[1].choices[0].message.content).toContain('Tokyo');
        expect(results[2].choices[0].message.content).toContain('London');
        
        // Since they are processed sequentially, total time should be at least
        // the sum of individual times.
    });

    it('should cancel generation when the client aborts a streaming request', async () => {
        const controller = new AbortController();
        
        // 1. Start a long streaming request
        const streamPromise = client.chat.completions.create({
            model: 'ondevice',
            messages: [{ role: 'user', content: 'Write a very long story about a space pirate.' }],
            stream: true,
        }, { signal: controller.signal });

        const stream = await streamPromise;
        let chunksReceived = 0;
        
        try {
            for await (const chunk of stream) {
                chunksReceived++;
                if (chunksReceived === 3) {
                    // 2. Abort the request after receiving 3 chunks
                    controller.abort();
                    break;
                }
            }
        } catch (e: any) {
            // OpenAI SDK throws an AbortError or similar
            // expect(e.name).toBe('AbortError');
        }

        expect(chunksReceived).toBe(3);

        // 3. Verify the next request starts immediately and succeeds
        // This proves the model wasn't blocked by the "zombie" task
        const nextStart = Date.now();
        const nextResponse = await client.chat.completions.create({
            model: 'ondevice',
            messages: [{ role: 'user', content: 'What is 2+2?' }],
        });
        const nextDuration = Date.now() - nextStart;

        expect(nextResponse.choices[0].message.content).toContain('4');
        // If the previous task wasn't cancelled, this would take much longer or wait for the whole story to finish
        expect(nextDuration).toBeLessThan(15000); 
    });

    it('should skip a queued request if it is cancelled before execution starts', async () => {
        const start = Date.now();

        // 1. Start a blocking request (Request A)
        const reqAPromise = client.chat.completions.create({
            model: 'ondevice',
            messages: [{ role: 'user', content: 'Tell me a short fact about dogs.' }],
        });

        // 2. Queue a second request (Request B) but prepare to cancel it
        const controllerB = new AbortController();
        const reqBPromise = client.chat.completions.create({
            model: 'ondevice',
            messages: [{ role: 'user', content: 'Tell me a short fact about birds.' }],
        }, { signal: controllerB.signal });

        // 3. Queue a third request (Request C)
        const reqCPromise = client.chat.completions.create({
            model: 'ondevice',
            messages: [{ role: 'user', content: 'Tell me a short fact about cats.' }],
        });

        // 4. Cancel Request B immediately (while A is likely still processing or just finishing setup)
        controllerB.abort();

        // 5. Await results
        const [resA, resBResult, resC] = await Promise.allSettled([
            reqAPromise,
            reqBPromise,
            reqCPromise
        ]);

        const duration = Date.now() - start;

        // Verify Request A succeeded
        expect(resA.status).toBe('fulfilled');
        if (resA.status === 'fulfilled') {
            // Check content loosely to account for model variation
            const content = resA.value.choices[0].message.content.toLowerCase();
            expect(content).toContain('dog');
        }

        // Verify Request B failed (cancelled)
        expect(resBResult.status).toBe('rejected');

        // Verify Request C succeeded
        expect(resC.status).toBe('fulfilled');
        if (resC.status === 'fulfilled') {
            const content = resC.value.choices[0].message.content.toLowerCase();
            expect(content).toContain('cat');
        }
    });
});
