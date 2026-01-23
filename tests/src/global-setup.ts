import { spawn, ChildProcess } from 'child_process';
import path from 'path';
import fs from 'fs';

let serverProcess: ChildProcess | undefined;

export async function setup() {
  if (process.env.TEST_TARGET === 'openrouter') {
    return;
  }

  console.log('\n[Global Setup] Checking/Starting afmbridge-server...');

  const projectRoot = path.resolve(__dirname, '../../');
  const debugPath = path.join(projectRoot, '.build/debug/afmbridge-server');
  
  // Check if binary exists
  if (!fs.existsSync(debugPath)) {
    console.log('[Global Setup] Binary not found. Building afmbridge-server...');
    // We run swift build synchronously to ensure it's done before we start
    const build = spawn('swift', ['build'], { 
        cwd: projectRoot, 
        stdio: 'inherit' 
    });
    
    await new Promise<void>((resolve, reject) => {
        build.on('close', (code) => {
            if (code === 0) resolve();
            else reject(new Error(`Build failed with code ${code}`));
        });
        build.on('error', (err) => reject(err));
    });
  }

  const port = 8765; // Default test port used by client.ts
  
  // Check if server is already running
  try {
      const resp = await fetch(`http://localhost:${port}/health`);
      if (resp.ok) {
          console.log('[Global Setup] Server already running. Using existing instance.');
          return; // Don't manage this process
      }
  } catch (e) {
      // Not running, proceed to spawn
  }

  console.log(`[Global Setup] Spawning server on port ${port}...`);
  serverProcess = spawn(debugPath, ['--port', port.toString(), '--quiet'], {
      // We ignore stdout to keep test output clean, but keep stderr for errors
      stdio: ['ignore', 'ignore', 'inherit'] 
  });

  serverProcess.on('error', (err) => {
      console.error('[Global Setup] Failed to spawn server:', err);
  });

  // Wait for health check to pass
  let attempts = 0;
  const maxAttempts = 20;
  
  while (attempts < maxAttempts) {
      try {
          const resp = await fetch(`http://localhost:${port}/health`);
          if (resp.ok) {
              console.log('[Global Setup] Server is ready.');
              return;
          }
      } catch (e) {
          // ignore
      }
      await new Promise(r => setTimeout(r, 500));
      attempts++;
  }
  
  // If we get here, server didn't start
  if (serverProcess) {
      serverProcess.kill();
  }
  throw new Error(`Server failed to become ready after ${maxAttempts} attempts`);
}

export async function teardown() {
    if (serverProcess) {
        console.log('[Global Teardown] Stopping server...');
        serverProcess.kill();
        serverProcess = null;
    }
}
