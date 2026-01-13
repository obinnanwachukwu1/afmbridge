// syslm-cli/main.swift
// Command-line interface for syslm

import Foundation
import syslm_core

/// Command-line interface for syslm.
/// Supports both direct (in-process) and socket (RPC) modes.
@main
struct CLI {
    
    enum Mode {
        case direct     // Use ChatEngine directly (default)
        case socket     // Connect via Unix socket
    }
    
    static func main() async {
        // Parse arguments
        let args = Arguments.parse()
        
        if args.help {
            printUsage()
            return
        }
        
        if args.version {
            print("syslm-cli 1.0.0")
            return
        }
        
        // Create transport based on mode
        let transport: any ChatTransport
        
        switch args.mode {
        case .direct:
            transport = DirectTransport()
        case .socket:
            transport = SocketTransport(socketPath: args.socketPath)
        }
        
        // Check availability
        let available = await transport.isAvailable
        guard available else {
            if args.mode == .socket {
                fputs("ERROR: Socket server not running at \(args.socketPath)\n", stderr)
                fputs("Start it with: swift run syslm-socket\n", stderr)
            } else {
                fputs("ERROR: Model not available\n", stderr)
            }
            exit(2)
        }
        
        // Handle different modes
        if args.interactive {
            await runInteractive(transport: transport, args: args)
        } else if let prompt = args.prompt {
            await runSinglePrompt(transport: transport, prompt: prompt, args: args)
        } else if args.prompt == nil && !args.interactive {
            // Read from stdin
            await runFromStdin(transport: transport, args: args)
        }
    }
    
    /// Run in interactive mode (REPL)
    static func runInteractive(transport: any ChatTransport, args: Arguments) async {
        print("syslm interactive mode (type 'exit' or Ctrl+D to quit)")
        if let system = args.system {
            print("System: \(system)")
        }
        print("")
        
        var messages: [Message] = []
        
        // Add system message if provided
        if let system = args.system {
            messages.append(Message(role: .system, content: .text(system)))
        }
        
        while true {
            print("> ", terminator: "")
            fflush(stdout)
            
            guard let line = readLine() else {
                print("")
                break
            }
            
            let input = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if input.isEmpty {
                continue
            }
            
            if input.lowercased() == "exit" || input.lowercased() == "quit" {
                break
            }
            
            // Special commands
            if input.hasPrefix("/") {
                handleCommand(input, messages: &messages)
                continue
            }
            
            // Add user message
            messages.append(Message(role: .user, content: .text(input)))
            
            // Create request
            let request = ChatCompletionRequest(
                model: args.model,
                messages: messages,
                stream: args.stream,
                temperature: args.temperature,
                maxTokens: args.maxTokens
            )
            
            // Get response
            do {
                if args.stream {
                    var fullContent = ""
                    for try await chunk in transport.stream(request) {
                        if let content = chunk.choices.first?.delta.content {
                            print(content, terminator: "")
                            fflush(stdout)
                            fullContent += content
                        }
                    }
                    print("")
                    
                    // Add assistant message to history
                    if !fullContent.isEmpty {
                        messages.append(Message(role: .assistant, content: .text(fullContent)))
                    }
                } else {
                    let response = try await transport.send(request)
                    if let content = response.choices.first?.message.content {
                        print(content)
                        messages.append(Message(role: .assistant, content: .text(content)))
                    }
                }
            } catch {
                fputs("Error: \(error)\n", stderr)
                // Remove the failed user message
                messages.removeLast()
            }
            
            print("")
        }
    }
    
    /// Run a single prompt
    static func runSinglePrompt(transport: any ChatTransport, prompt: String, args: Arguments) async {
        var messages: [Message] = []
        
        if let system = args.system {
            messages.append(Message(role: .system, content: .text(system)))
        }
        
        messages.append(Message(role: .user, content: .text(prompt)))
        
        let request = ChatCompletionRequest(
            model: args.model,
            messages: messages,
            stream: args.stream,
            temperature: args.temperature,
            maxTokens: args.maxTokens
        )
        
        do {
            if args.stream {
                for try await chunk in transport.stream(request) {
                    if let content = chunk.choices.first?.delta.content {
                        print(content, terminator: "")
                        fflush(stdout)
                    }
                }
                print("")
            } else {
                let response = try await transport.send(request)
                if let content = response.choices.first?.message.content {
                    print(content)
                }
            }
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }
    
    /// Run from stdin
    static func runFromStdin(transport: any ChatTransport, args: Arguments) async {
        var input = ""
        while let line = readLine() {
            input += line + "\n"
        }
        
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            fputs("Error: No input provided\n", stderr)
            exit(1)
        }
        
        await runSinglePrompt(transport: transport, prompt: prompt, args: args)
    }
    
    /// Handle special commands
    static func handleCommand(_ command: String, messages: inout [Message]) {
        let parts = command.split(separator: " ", maxSplits: 1)
        let cmd = String(parts[0]).lowercased()
        
        switch cmd {
        case "/clear":
            // Keep system message if present
            messages = messages.filter { $0.role == .system }
            print("Conversation cleared.")
            
        case "/history":
            print("History (\(messages.count) messages):")
            for (i, msg) in messages.enumerated() {
                let role = msg.role.rawValue
                let content = msg.content?.textValue ?? ""
                let preview = content.prefix(50)
                print("  \(i + 1). [\(role)] \(preview)\(content.count > 50 ? "..." : "")")
            }
            
        case "/help":
            print("Commands:")
            print("  /clear   - Clear conversation history")
            print("  /history - Show conversation history")
            print("  /help    - Show this help")
            print("  exit     - Exit the CLI")
            
        default:
            print("Unknown command: \(cmd)")
            print("Type /help for available commands")
        }
    }
    
    /// Print usage information
    static func printUsage() {
        print("""
        syslm-cli - Command-line interface for syslm
        
        USAGE:
            syslm-cli [OPTIONS] [PROMPT]
            echo "prompt" | syslm-cli [OPTIONS]
        
        OPTIONS:
            -i, --interactive    Interactive mode (REPL)
            -s, --stream         Stream the response
            --system <TEXT>      System message
            --model <NAME>       Model name (default: ondevice)
            --temperature <NUM>  Temperature (0.0-2.0)
            --max-tokens <NUM>   Maximum response tokens
            
            --socket [PATH]      Use socket transport (default: /tmp/syslm.sock)
            --direct             Use direct transport (default)
            
            -h, --help           Show this help
            -v, --version        Show version
        
        EXAMPLES:
            # Single prompt
            syslm-cli "What is the capital of France?"
            
            # Interactive mode
            syslm-cli -i
            
            # With system message
            syslm-cli --system "You are a pirate" "Greet me"
            
            # Streaming
            syslm-cli -s "Tell me a story"
            
            # From stdin
            echo "Hello" | syslm-cli
            
            # Using socket server
            syslm-cli --socket "Hello"
        """)
    }
}

/// Parsed command-line arguments
struct Arguments {
    var mode: CLI.Mode = .direct
    var socketPath: String = RPCDefaults.socketPath
    var interactive: Bool = false
    var stream: Bool = false
    var system: String? = nil
    var model: String = "ondevice"
    var temperature: Double? = nil
    var maxTokens: Int? = nil
    var prompt: String? = nil
    var help: Bool = false
    var version: Bool = false
    
    static func parse() -> Arguments {
        var args = Arguments()
        var i = 1
        
        while i < CommandLine.arguments.count {
            let arg = CommandLine.arguments[i]
            
            switch arg {
            case "-i", "--interactive":
                args.interactive = true
                
            case "-s", "--stream":
                args.stream = true
                
            case "--system":
                i += 1
                if i < CommandLine.arguments.count {
                    args.system = CommandLine.arguments[i]
                }
                
            case "--model":
                i += 1
                if i < CommandLine.arguments.count {
                    args.model = CommandLine.arguments[i]
                }
                
            case "--temperature":
                i += 1
                if i < CommandLine.arguments.count {
                    args.temperature = Double(CommandLine.arguments[i])
                }
                
            case "--max-tokens":
                i += 1
                if i < CommandLine.arguments.count {
                    args.maxTokens = Int(CommandLine.arguments[i])
                }
                
            case "--socket":
                args.mode = .socket
                // Check if next arg is a path (starts with / or .)
                if i + 1 < CommandLine.arguments.count {
                    let nextArg = CommandLine.arguments[i + 1]
                    if nextArg.hasPrefix("/") || nextArg.hasPrefix(".") {
                        i += 1
                        args.socketPath = nextArg
                    }
                }
                
            case "--direct":
                args.mode = .direct
                
            case "-h", "--help":
                args.help = true
                
            case "-v", "--version":
                args.version = true
                
            default:
                if !arg.hasPrefix("-") && args.prompt == nil {
                    args.prompt = arg
                }
            }
            
            i += 1
        }
        
        return args
    }
}
