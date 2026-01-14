// afmbridge-cli/main.swift
// Command-line interface for afmbridge

import Foundation
import afmbridge_core

/// Command-line interface for afmbridge.
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
            print("afmbridge-cli 1.0.0")
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
                fputs("Start it with: swift run afmbridge-socket\n", stderr)
            } else {
                fputs("ERROR: Model not available\n", stderr)
            }
            exit(2)
        }
        
        // Handle different modes
        if args.interactive {
            // Interactive mode always streams by default
            var interactiveArgs = args
            if !args.noStream {
                interactiveArgs.stream = true
            }
            await runInteractive(transport: transport, args: interactiveArgs)
        } else if let prompt = args.prompt {
            await runSinglePrompt(transport: transport, prompt: prompt, args: args)
        } else if args.prompt == nil && !args.interactive {
            // Read from stdin
            await runFromStdin(transport: transport, args: args)
        }
    }
    
    /// Run in interactive mode (REPL)
    static func runInteractive(transport: any ChatTransport, args: Arguments) async {
        print("afmbridge interactive mode (type 'exit' or Ctrl+D to quit, /help for commands)")
        if let system = args.system {
            print("System: \(system)")
        }
        print("")
        
        var messages: [Message] = []
        var debugMode = false
        
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
                handleCommand(input, messages: &messages, debugMode: &debugMode)
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
            
            // Debug: show what we're sending
            if debugMode {
                print("[DEBUG] Sending \(messages.count) messages:")
                for (i, msg) in messages.enumerated() {
                    let content = msg.content?.textValue ?? "(nil)"
                    let preview = content.count > 80 ? String(content.prefix(80)) + "..." : content
                    print("  \(i+1). [\(msg.role.rawValue)] \(preview)")
                }
                print("")
            }
            
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
    static func handleCommand(_ command: String, messages: inout [Message], debugMode: inout Bool) {
        let parts = command.split(separator: " ", maxSplits: 1)
        let cmd = String(parts[0]).lowercased()
        
        switch cmd {
        case "/clear":
            // Keep system message if present
            messages = messages.filter { $0.role == .system }
            print("Conversation cleared.")
            
        case "/system":
            if parts.count > 1 {
                let newSystem = String(parts[1])
                // Remove existing system message
                messages.removeAll { $0.role == .system }
                // Add new system message at the beginning
                messages.insert(Message(role: .system, content: .text(newSystem)), at: 0)
                print("System prompt set: \(newSystem)")
            } else {
                // Show current system prompt
                if let systemMsg = messages.first(where: { $0.role == .system }) {
                    print("Current system: \(systemMsg.content?.textValue ?? "(empty)")")
                } else {
                    print("No system prompt set. Use: /system <prompt>")
                }
            }
            
        case "/reset":
            // Clear everything including system message
            messages.removeAll()
            print("Conversation fully reset (including system prompt).")
            
        case "/debug":
            debugMode.toggle()
            print("Debug mode: \(debugMode ? "ON" : "OFF")")
            
        case "/history":
            print("History (\(messages.count) messages):")
            for (i, msg) in messages.enumerated() {
                let role = msg.role.rawValue
                let content = msg.content?.textValue ?? ""
                let preview = content.prefix(60)
                print("  \(i + 1). [\(role)] \(preview)\(content.count > 60 ? "..." : "")")
            }
            
        case "/help":
            print("Commands:")
            print("  /system <prompt> - Set system prompt (guides model behavior)")
            print("  /system          - Show current system prompt")
            print("  /clear           - Clear conversation (keeps system prompt)")
            print("  /reset           - Clear everything including system prompt")
            print("  /history         - Show conversation history")
            print("  /debug           - Toggle debug mode (shows messages sent)")
            print("  /help            - Show this help")
            print("  exit             - Exit the CLI")
            
        default:
            print("Unknown command: \(cmd)")
            print("Type /help for available commands")
        }
    }
    
    /// Print usage information
    static func printUsage() {
        print("""
        afmbridge-cli - Command-line interface for afmbridge
        
        USAGE:
            afmbridge-cli [OPTIONS] [PROMPT]
            echo "prompt" | afmbridge-cli [OPTIONS]
        
        OPTIONS:
            -i, --interactive    Interactive mode (REPL) - streams by default
            -s, --stream         Stream the response
            --no-stream          Disable streaming (for interactive mode)
            --system <TEXT>      System message
            --model <NAME>       Model name (default: ondevice)
            --temperature <NUM>  Temperature (0.0-2.0)
            --max-tokens <NUM>   Maximum response tokens
            
            --socket [PATH]      Use socket transport (default: /tmp/afmbridge.sock)
            --direct             Use direct transport (default)
            
            -h, --help           Show this help
            -v, --version        Show version
        
        EXAMPLES:
            # Single prompt
            afmbridge-cli "What is the capital of France?"
            
            # Interactive mode (streams by default)
            afmbridge-cli -i
            
            # With system message
            afmbridge-cli --system "You are a pirate" "Greet me"
            
            # Streaming
            afmbridge-cli -s "Tell me a story"
            
            # From stdin
            echo "Hello" | afmbridge-cli
            
            # Using socket server
            afmbridge-cli --socket "Hello"
        """)
    }
}

/// Parsed command-line arguments
struct Arguments {
    var mode: CLI.Mode = .direct
    var socketPath: String = RPCDefaults.socketPath
    var interactive: Bool = false
    var stream: Bool = false
    var noStream: Bool = false  // Explicitly disable streaming in interactive mode
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
                
            case "--no-stream":
                args.noStream = true
                
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
