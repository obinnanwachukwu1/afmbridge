// afmbridge-core/Engine/ModelExecutor.swift
// Actor to manage sequential execution of Foundation Model tasks

import Foundation

/// A shared actor that ensures Foundation Model tasks are executed sequentially.
/// This prevents resource contention on the on-device Neural Engine and 
/// allows for predictable FIFO queuing of requests.
public actor ModelExecutor {
    
    /// Shared instance for the process
    public static let shared = ModelExecutor()
    
    /// The currently executing task, if any.
    private var currentTask: Task<Void, Error>?
    
    /// Maximum number of tasks allowed in the queue
    public var maxQueueDepth: Int = 100
    
    /// Current number of tasks in the queue (including the running one)
    private var currentQueueDepth: Int = 0
    
    public init() {}
    
    /// Execute a block of code sequentially.
    /// If another task is already running, this method will wait for it to finish.
    /// - Parameter block: The asynchronous block to execute.
    /// - Returns: The result of the block.
    public func execute<T: Sendable>(block: @escaping @Sendable () async throws -> T) async throws -> T {
        // Check queue depth
        guard currentQueueDepth < maxQueueDepth else {
            throw ModelExecutorError.queueFull
        }
        
        currentQueueDepth += 1
        
        // Capture the previous task to wait for it
        let previousTask = currentTask
        
        // Create a new task that waits for the previous one and then runs the block
        let newTask = Task { [previousTask] in
            // Wait for the previous task to complete (successfully or with error)
            if let previousTask = previousTask {
                _ = await previousTask.result
            }
            
            // Check for cancellation before starting the actual work
            if Task.isCancelled {
                throw CancellationError()
            }
            
            let result = try await block()
            return result
        }
        
        // Update the current task reference
        currentTask = Task {
            let _ = await newTask.result
            // Decrement queue depth when task finishes (success or failure)
            await self.decrementQueueDepth()
        }
        
        // Return the result of the new task, handling cancellation propagation
        return try await withTaskCancellationHandler {
            try await newTask.value
        } onCancel: {
            newTask.cancel()
        }
    }
    
    private func decrementQueueDepth() {
        currentQueueDepth -= 1
    }
    
    /// Set the maximum queue depth
    public func setMaxQueueDepth(_ depth: Int) {
        self.maxQueueDepth = depth
    }
    
    /// Cancel the currently executing task
    public func cancelAll() {
        // This cancels the tail of the queue. 
        // If the tail is waiting for previous tasks, they will cascade if structured correctly,
        // but here we might just be cancelling the wait. 
        // However, for the manual stop button, we want to stop EVERYTHING.
        currentTask?.cancel()
    }
}

/// Errors thrown by ModelExecutor
public enum ModelExecutorError: Error {
    case queueFull
}
