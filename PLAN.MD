# Resiliency Implementation Plan

Implement mid-stream cancellation and sequential request queuing (FIFO) for `afmbridge` to handle multiple concurrent requests gracefully on the single-threaded on-device Neural Engine.

## Tasks

- [ ] **Core Engine Enhancements**
    - [ ] Create `ModelExecutor` actor in `afmbridge-core` to manage a FIFO task queue.
    - [ ] Update `ChatEngine.complete` to use `ModelExecutor` for serial execution.
    - [ ] Update `ChatEngine.stream` to use `ModelExecutor` and implement `onTermination` for task cancellation.
- [ ] **Transport Enhancements**
    - [ ] Update `afmbridge-server` to propagate client disconnects as task cancellations.
    - [ ] Ensure `afmbridge-socket` correctly handles client disconnection mid-stream.
- [ ] **Testing & Validation**
    - [ ] Create `tests/src/resiliency.test.ts` to test queuing and cancellation.
    - [ ] Run existing vitest suite to ensure no regressions in basic/streaming/tool functionality.
    - [ ] Verify manual CLI behavior with parallel prompts.

## Design Notes

- **Concurrency Strategy**: FIFO Queueing. New requests wait for the current one to finish.
- **Cancellation**: If a client disconnects, the Swift `Task` is cancelled, signaling the model to stop generating tokens immediately.
- **No API Changes**: Public method signatures in `ChatEngine` and `DirectTransport` remain the same.
