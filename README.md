# syslm

OpenRouter-compatible API layer for Apple's on-device FoundationModels framework. Exposes a `POST /v1/chat/completions` endpoint that works as a drop-in replacement for OpenAI/OpenRouter APIs.

## Features

- **Full OpenRouter API compatibility** — Works with OpenAI SDKs via base URL override
- **Tool calling** — Function calling with proper `tool_calls` array and `finish_reason`
- **Structured outputs** — JSON schema-constrained generation using Apple's guided generation
- **Streaming** — Server-sent events (SSE) for real-time streaming
- **Multiple transports** — HTTP server, Unix socket RPC, or direct in-process
- **CLI tool** — Interactive REPL and one-shot queries

## Requirements

- macOS 26 (Tahoe) or newer with Apple Intelligence enabled
- Xcode 26+ with Swift 6.2 toolchain
- The `FoundationModels` framework (ships with macOS 26)

## Quick Start

### Build

```bash
swift build
```

### HTTP Server

```bash
swift run syslm-server --port 8765
```

```bash
curl http://localhost:8765/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages": [{"role": "user", "content": "Hello!"}]}'
```

### CLI Tool

```bash
# One-shot query (direct mode)
swift run syslm-cli "What is the capital of France?"

# Streaming output
swift run syslm-cli -s "Tell me a story"

# Interactive REPL
swift run syslm-cli -i

# Connect via Unix socket (requires syslm-socket running)
swift run syslm-cli --socket "Hello"
```

### Unix Socket Server

For lower-latency IPC without HTTP overhead:

```bash
# Start socket server (default: /tmp/syslm.sock)
swift run syslm-socket

# Or specify a custom path
swift run syslm-socket --socket /path/to/syslm.sock --verbose
```

### Use with OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8765/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="ondevice",
    messages=[{"role": "user", "content": "What is the capital of France?"}]
)
print(response.choices[0].message.content)
```

## API Reference

### `POST /v1/chat/completions`

OpenRouter-compatible chat completions endpoint.

#### Request Body

```json
{
  "model": "ondevice",
  "messages": [
    {"role": "system", "content": "You are helpful."},
    {"role": "user", "content": "Hello!"}
  ],
  "stream": false,
  "temperature": 0.7,
  "max_tokens": 1024,
  "tools": [...],
  "tool_choice": "auto",
  "response_format": {"type": "json_schema", "json_schema": {...}}
}
```

#### Supported Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `model` | string | Model name (ignored, always uses on-device model) |
| `messages` | array | Chat messages (system, user, assistant, tool) |
| `stream` | boolean | Enable SSE streaming |
| `temperature` | number | Sampling temperature (0.0-2.0) |
| `max_tokens` | integer | Maximum response tokens |
| `tools` | array | Function tool definitions |
| `tool_choice` | string/object | "auto", "none", "required", or specific function |
| `response_format` | object | "json_object" or "json_schema" with schema |

### `GET /health`

Health check endpoint.

```json
{
  "status": "ok",
  "availability": "available",
  "model": "ondevice"
}
```

## Tool Calling

syslm supports OpenRouter-style function calling:

```python
tools = [{
    "type": "function",
    "function": {
        "name": "get_weather",
        "description": "Get weather for a city",
        "parameters": {
            "type": "object",
            "properties": {"city": {"type": "string"}},
            "required": ["city"]
        }
    }
}]

response = client.chat.completions.create(
    model="ondevice",
    messages=[{"role": "user", "content": "What's the weather in Tokyo?"}],
    tools=tools
)

if response.choices[0].finish_reason == "tool_calls":
    tool_call = response.choices[0].message.tool_calls[0]
    print(f"Call {tool_call.function.name} with {tool_call.function.arguments}")
```

## Structured Outputs

Generate JSON constrained to a schema:

```python
response = client.chat.completions.create(
    model="ondevice",
    messages=[{"role": "user", "content": "Give me info about Paris"}],
    response_format={
        "type": "json_schema",
        "json_schema": {
            "name": "city_info",
            "strict": True,
            "schema": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "country": {"type": "string"},
                    "population": {"type": "integer"}
                },
                "required": ["name", "country"]
            }
        }
    }
)
```

## Streaming

Enable real-time streaming with SSE:

```python
stream = client.chat.completions.create(
    model="ondevice",
    messages=[{"role": "user", "content": "Tell me a story"}],
    stream=True
)

for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)
```

> **Note:** Apple's FoundationModels streams in batched chunks (roughly 6-8 tokens per chunk), not token-by-token. This is a platform limitation, not a bug.

## Project Structure

```
Sources/
├── syslm-core/              # Core library
│   ├── Types/               # OpenRouter-compatible request/response types
│   │   ├── Request.swift
│   │   ├── Response.swift
│   │   ├── StreamChunk.swift
│   │   ├── JSONSchema.swift
│   │   ├── JSONValue.swift
│   │   └── Error.swift
│   ├── Engine/              # Chat engine and converters
│   │   ├── ChatEngine.swift
│   │   ├── ToolCallParser.swift
│   │   ├── SchemaConverter.swift
│   │   └── OptionsConverter.swift
│   └── Transport/           # Transport abstractions
│       ├── ChatTransport.swift   # Protocol
│       ├── DirectTransport.swift # In-process (wraps ChatEngine)
│       ├── SocketTransport.swift # Unix socket client
│       └── RPCProtocol.swift     # Binary wire protocol
├── syslm-server/            # HTTP server (SwiftNIO)
├── syslm-socket/            # Unix socket RPC server
└── syslm-cli/               # Command-line interface

tests/                       # TypeScript conformance test suite
├── src/
│   ├── basic-completion.test.ts
│   ├── tool-calling.test.ts
│   ├── structured-output.test.ts
│   ├── streaming.test.ts
│   ├── error-handling.test.ts
│   └── usage-tracking.test.ts
└── package.json
```

## Transport Architecture

syslm supports multiple transports for different use cases:

| Transport | Use Case | Latency |
|-----------|----------|---------|
| `DirectTransport` | In-process, library usage | Lowest |
| `SocketTransport` | IPC, CLI tools | Low |
| HTTP Server | Network, SDK compatibility | Higher |

```swift
import syslm_core

// Direct (in-process)
let direct = try DirectTransport()
let response = try await direct.send(request)

// Socket (connects to syslm-socket server)
let socket = try await SocketTransport(path: "/tmp/syslm.sock")
let response = try await socket.send(request)
```

## Running Tests

The test suite validates OpenRouter API compatibility:

```bash
# Start the server
swift run syslm-server --port 8765

# Run tests (in another terminal)
cd tests
npm install
npm test
```

Current status: **46/46 tests passing**

## Known Limitations

- **Streaming granularity:** Apple's FoundationModels streams in batched chunks (~6-8 tokens), not individual tokens
- **Content filters:** Apple's on-device model may reject some prompts
- **Context window:** Limited context size (see Apple's TN3193)
- **Token counts:** Usage stats are estimated (Apple doesn't expose actual token counts)
- **Not implemented:** logprobs, n>1 completions, seed (deterministic sampling)

## References

- [OpenRouter API Reference](https://openrouter.ai/docs/api/reference/overview)
- [Apple FoundationModels Framework](https://developer.apple.com/documentation/foundationmodels/)
- [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/)
- [TN3193: Managing the Context Window](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window/)

## License

MIT
