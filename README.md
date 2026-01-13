# syslm

OpenRouter-compatible API layer for Apple's on-device FoundationModels framework. Exposes a `POST /v1/chat/completions` endpoint that works as a drop-in replacement for OpenAI/OpenRouter APIs.

## Features

- **Full OpenRouter API compatibility** — Works with OpenAI SDKs via base URL override
- **Tool calling** — Function calling with proper `tool_calls` array and `finish_reason`
- **Structured outputs** — JSON schema-constrained generation using Apple's guided generation
- **Streaming** — Server-sent events (SSE) for real-time token streaming
- **Multi-turn conversations** — Proper transcript handling for chat history

## Requirements

- macOS 26 (Tahoe) or newer with Apple Intelligence enabled
- Xcode 26+ with Swift 6.2 toolchain
- The `FoundationModels` framework (ships with macOS 26)

> Tip: Run `xcode-select -p` to confirm you're using the correct Xcode.

## Quick Start

### Build and run the server

```bash
swift build
swift run syslm-server --port 8765
```

### Test with curl

```bash
curl http://localhost:8765/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ondevice",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Use with OpenAI SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://localhost:8765/v1",
    api_key="not-needed"  # syslm doesn't require auth
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
| `model` | string | Model name (use "ondevice") |
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

# Response includes tool_calls when model wants to use a tool
if response.choices[0].finish_reason == "tool_calls":
    tool_call = response.choices[0].message.tool_calls[0]
    # Execute the tool and send result back
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
# Response content is valid JSON matching the schema
```

## Streaming

Enable real-time token streaming with SSE:

```python
stream = client.chat.completions.create(
    model="ondevice",
    messages=[{"role": "user", "content": "Tell me a story"}],
    stream=True
)

for chunk in stream:
    if chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="")
```

## Project Structure

```
Sources/
├── syslm-core/           # Core library
│   ├── Types/            # Request/Response types (OpenRouter-compatible)
│   └── Engine/           # ChatEngine, converters, parsers
└── syslm-server/         # HTTP server (SwiftNIO)

tests/                    # TypeScript conformance test suite
├── src/
│   ├── basic-completion.test.ts
│   ├── tool-calling.test.ts
│   ├── structured-output.test.ts
│   ├── streaming.test.ts
│   └── error-handling.test.ts
└── package.json
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

Current status: **40/40 tests passing**

## Known Limitations

- Apple's on-device model has content filters that may reject some prompts
- Context window is limited (see Apple's TN3193)
- Some advanced OpenRouter features not yet implemented (logprobs, n>1, etc.)

## References

- [OpenRouter API Reference](https://openrouter.ai/docs/api/reference/overview)
- [Apple FoundationModels Framework](https://developer.apple.com/documentation/foundationmodels/)
- [LanguageModelSession](https://developer.apple.com/documentation/foundationmodels/languagemodelsession/)

## License

This repository does not yet include an explicit license. Add one before distributing.
