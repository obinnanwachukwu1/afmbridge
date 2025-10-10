# syslm

`syslm` wraps Apple's on-device `SystemLanguageModel` APIs with a small Swift package, a command line entry point, and an HTTP server that mimics the OpenAI Chat Completions API. The repository also contains helper scripts for driving the server from Python, including a rich TUI that demonstrates streaming tool calls.

## Requirements
- macOS 26 (Tahoe) or newer with Apple Intelligence enabled; the `FoundationModels` framework is only available on those builds.
- Xcode 16 (or later) with Swift 6.2 toolchains.
- Python 3.10+ if you plan to use the helper scripts.

> Tip: run `xcode-select -p` to confirm you are using the Xcode that ships the `FoundationModels.framework`.

## Project Layout
- `Sources/syslm-core`: core plumbing that converts OpenAI-style payloads into `SystemLanguageModel` prompts, including tool calling and JSON schema support.
- `Sources/syslm-cli`: reads a chat-completions style request from STDIN and prints a JSON response; also exposes an `--availability` probe.
- `Sources/syslm-server`: SwiftNIO HTTP server that exposes `POST /v1/chat/completions` plus SSE streaming, designed to be drop-in compatible with the latest OpenAI SDKs.
- `scripts/interactive_agent.py`: interactive TUI client that calls the server, renders streamed chunks, and executes tool calls locally.
- `scripts/test_openai_server.py`: smoke tests that exercise completions, schema-constrained outputs, tool calls, and streaming.

## Building the Swift targets
```bash
swift build
```
The SwiftPM manifest links against `FoundationModels`, so the build must run on a machine that provides that framework.

## Using the CLI (`syslm-cli`)
The CLI reads the request from STDIN and writes the response JSON to STDOUT. Warnings are emitted on STDERR.

Probe availability:
```bash
echo "" | swift run syslm-cli --availability
```
Sample completion:
```bash
echo '{
  "messages": [
    {"role": "system", "content": "You are concise."},
    {"role": "user", "content": "Name a macOS release."}
  ],
  "temperature": 0.2
}' | swift run syslm-cli
```
Optional request fields:
- `temperature` or `temp`
- `top_k`
- `max_output_tokens`, `max_tokens`, or `maxTokens`
- `response_format` with a JSON schema (see below)
- `tools` (function tools only) and `tool_choice` (`auto`, `none`, or `{ "type": "function", "function": { "name": "..." } }`).

Exit codes:
- `0`: success
- `1`: general failure (parse errors, invalid input)
- `2`: model unavailable on this machine

## Running the server (`syslm-server`)
Start the OpenAI-compatible server (defaults to port 8000):
```bash
swift run syslm-server --port 8000
```
You should see "syslm-server listening on http://0.0.0.0:8000" once the `SystemLanguageModel` session is ready.

### Making requests
The server implements `POST /v1/chat/completions`. Example with `curl`:
```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ondevice",
    "messages": [
      {"role": "system", "content": "You are terse."},
      {"role": "user", "content": "Summarize WWDC in one sentence."}
    ]
  }'
```
The response mirrors OpenAI's payload, including `choices[0].message.role`, `content`, and the `id/model/created` metadata. Any server-side warnings (for example, unsupported tool definitions) are surfaced via `Warning` headers.

### Streaming responses
Set `"stream": true` to opt into server-sent events (SSE). The endpoint emits `data: ...` chunks and finishes with `data: [DONE]`. Streaming is currently disabled for requests that include `response_format.json_schema`.

### Tool calling
Only function tools are supported. When the model asks to call a tool, the response's `choices[0].message.tool_calls` array is populated and `finish_reason` becomes `"tool_calls"`. Supplying `"tool_choice": "none"` strips tools from the request. Supplying `{"type": "function", "function": {"name": "my_tool"}}` enforces a single function.

### JSON schema constrained outputs
Provide `response_format` as in the OpenAI API. The server normalizes schemas and returns both raw `content` (stringified JSON) and a `parsed` object when the schema can be satisfied. Allowed root types are `object`, `array`, `string`, `integer`, `number`, and `boolean`.

## Python helper scripts
Create a virtual environment and install dependencies:
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install openai==1.* prompt_toolkit rich
```

### Interactive agent
1. Start `syslm-server`.
2. Ensure `OPENAI_BASE_URL` points at `http://localhost:8000/v1` (default) and set `OPENAI_API_KEY` to any non-empty string.
3. Run the TUI:
   ```bash
   python3 scripts/interactive_agent.py
   ```
   The interface prints assistant tokens as they stream in, and renders tool invocations in a table. Tool calls are executed locally through helper functions (`get_current_time`, `calculate_expression`, `lookup_country_capital`).

### Smoke tests
With the server running, execute:
```bash
python3 scripts/test_openai_server.py
```
The script exercises:
- basic chat completions
- JSON schema responses (with `parsed` payloads)
- tool call emission and `tool_choice="none"`
- streaming completions
- rejection of unsupported schemas

Failures raise `AssertionError`s and dump the corresponding response objects.

### Local vs. GPT-4.1 Mini comparison
Once you have an OpenAI API key available, you can benchmark the local server
against OpenAI's hosted `gpt-4.1-mini` model:
```bash
python3 scripts/compare_chat_models.py
```
Place your credentials inside a `.env` file in the repository root (or pass
`--env-file path/to/.env`). The script exercises an expanded suite of chat
completion scenarios—covering JSON schemas, streaming, tool usage, and
failure cases—against both backends and prints a side-by-side summary. Use
`--skip-openai` or `--skip-local` to target one side only.

## Troubleshooting
- **`SystemLanguageModel is unavailable`**: Verify you are on macOS 26+ with Apple Intelligence enabled and that the active Xcode toolchain exposes the `FoundationModels` framework.
- **Unsupported schema or tool warnings**: The server logs details to STDERR and returns HTTP 400 when the request cannot be satisfied. Check the `Warning` headers and console output.
- **Python client fails to connect**: Confirm `OPENAI_BASE_URL` uses `http://` (not `https://`) when talking to the local server.

## License
This repository does not yet include an explicit license. Add one before distributing binaries or derivatives.
