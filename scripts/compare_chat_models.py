#!/usr/bin/env python3
"""Compare responses between the local syslm server and OpenAI's GPT-4.1 Mini.

This script exercises a suite of rich chat-completions scenarios (basic replies,
structured JSON, tool calling, forced tool-choice, streaming, invalid schema,
and multi-turn dialogues). Each scenario is executed against:

* The local syslm server (default: http://localhost:8000/v1)
* OpenAI's GPT-4.1 Mini (or another configurable OpenAI model)

It produces a concise side-by-side summary for every scenario to help you gauge
parity between the local implementation and OpenAI's hosted models.

Environment Variables
=====================
The script reads configuration from the environment. To keep things simple, it
can load a `.env` file in the repository root (use `--env-file` to choose a
custom location). The following variables are recognised:

* ``LOCAL_OPENAI_BASE_URL`` (optional) – base URL for the local server.
* ``LOCAL_OPENAI_API_KEY`` (optional) – API key for the local server (default: ``dummy-key``).
* ``OPENAI_API_KEY`` – key for OpenAI's public endpoint (required unless ``--skip-openai``).

Usage examples
==============

* Run full comparison (requires OpenAI API key)::

    ./scripts/compare_chat_models.py

* Only hit the local server::

    ./scripts/compare_chat_models.py --skip-openai

* Only hit OpenAI::

    ./scripts/compare_chat_models.py --skip-local

* Change the OpenAI model::

    ./scripts/compare_chat_models.py --openai-model gpt-4o-mini

The script exits with a non-zero status if any invariant check fails on the
local server responses. OpenAI responses are never treated as authoritative;
they are printed for manual inspection.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import sys
from collections.abc import Iterable
from pathlib import Path
from typing import Any, Dict, Optional

from openai import APIError, BadRequestError, OpenAI

###############################################################################
# Utilities
###############################################################################


def load_env_file(path: Optional[Path]) -> None:
    """Minimal ``.env`` loader that ignores comments and blank lines."""
    if not path:
        return
    if not path.exists():
        return

    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            print(f"[WARN] Ignoring malformed .env line: {raw_line}", file=sys.stderr)
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if key and value and key not in os.environ:
            os.environ[key] = value


@dataclasses.dataclass(slots=True)
class Scenario:
    name: str
    description: str
    request: Dict[str, Any]
    expect_failure: bool = False


@dataclasses.dataclass(slots=True)
class ScenarioResult:
    ok: bool
    summary: Dict[str, Any]
    error: Optional[str] = None


###############################################################################
# Scenario definitions
###############################################################################


def _system_message(content: str) -> Dict[str, str]:
    return {"role": "system", "content": content}


def _user_message(content: str) -> Dict[str, str]:
    return {"role": "user", "content": content}


def build_scenarios() -> list[Scenario]:
    """Construct the suite of chat completion scenarios."""
    return [
        Scenario(
            name="basic_completion",
            description="Simple text response",
            request={
                "messages": [
                    _system_message("You reply with one concise sentence."),
                    _user_message("Give me a random fruit."),
                ],
            },
        ),
        Scenario(
            name="structured_json",
            description="JSON schema enforced response",
            request={
                "messages": [
                    _system_message("You speak JSON"),
                    _user_message("Return sandwich info."),
                ],
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {
                        "name": "SandwichSummary",
                        "schema": {
                            "type": "object",
                            "properties": {
                                "name": {"type": "string"},
                                "ingredients": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                    "minItems": 2,
                                },
                                "vegetarian": {"type": "boolean"},
                            },
                            "required": ["name", "ingredients"],
                            "additionalProperties": False,
                        },
                    },
                },
            },
        ),
        Scenario(
            name="tool_call",
            description="Allow the model to request a tool call",
            request={
                "messages": [
                    _system_message("Call tools when necessary."),
                    _user_message("Use the echo tool to repeat hello world."),
                ],
                "tools": [
                    {
                        "type": "function",
                        "function": {
                            "name": "echo",
                            "description": "Return the same message",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "message": {"type": "string"}
                                },
                                "required": ["message"],
                            },
                        },
                    }
                ],
            },
        ),
        Scenario(
            name="tool_choice_none",
            description="Forbid tool usage, expect a direct answer",
            request={
                "messages": [
                    _system_message("You may *not* call any tools."),
                    _user_message("Explain, briefly, what tool_choice none means."),
                ],
                "tools": [
                    {
                        "type": "function",
                        "function": {
                            "name": "echo",
                            "description": "Return the same message",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "message": {"type": "string"}
                                },
                                "required": ["message"],
                            },
                        },
                    }
                ],
                "tool_choice": "none",
            },
        ),
        Scenario(
            name="streaming",
            description="Streaming chat completion (capture aggregated text)",
            request={
                "messages": [
                    _system_message("Be poetic."),
                    _user_message("Describe the ocean in five short phrases."),
                ],
                "stream": True,
            },
        ),
        Scenario(
            name="invalid_schema",
            description="Send an invalid schema and expect a failure",
            request={
                "messages": [_user_message("Hello")],
                "response_format": {
                    "type": "json_schema",
                    "json_schema": {
                        "name": "Bad",
                        "schema": {"type": "whoops"},
                    },
                },
            },
            expect_failure=True,
        ),
        Scenario(
            name="multi_turn_with_tool",
            description="Conversation requiring tool output integration",
            request={
                "messages": [
                    _system_message(
                        "You are a task assistant. Use tools when helpful and cite results."
                    ),
                    _user_message(
                        "What's 32 * 14? After you know the number, say if it is even."
                    ),
                ],
                "tools": [
                    {
                        "type": "function",
                        "function": {
                            "name": "calculate_expression",
                            "description": "Evaluate arithmetic expressions",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "expression": {"type": "string"}
                                },
                                "required": ["expression"],
                            },
                        },
                    }
                ],
            },
        ),
    ]

###############################################################################
# Scenario execution helpers
###############################################################################


def sanitize_arguments(args: str | Dict[str, Any]) -> str:
    if isinstance(args, str):
        return args
    try:
        return json.dumps(args, sort_keys=True, ensure_ascii=False)
    except TypeError:
        return str(args)


def summarise_response(result: Any, *, streamed: bool) -> Dict[str, Any]:
    """Pull out the bits we care about for comparison."""
    if streamed:
        text = result.get("content", "")
        chunks = result.get("chunks", [])
        return {
            "finish_reason": result.get("finish_reason"),
            "content_preview": text[:120],
            "content_length": len(text),
            "chunk_count": len(chunks),
        }

    choice = result.choices[0]
    message = choice.message
    tool_calls = []
    if getattr(message, "tool_calls", None):
        for call in message.tool_calls:
            tool_calls.append(
                {
                    "id": call.id,
                    "type": call.type,
                    "function": {
                        "name": call.function.name,
                        "arguments": sanitize_arguments(call.function.arguments),
                    },
                }
            )

    return {
        "finish_reason": choice.finish_reason,
        "role": message.role,
        "has_content": bool(message.content),
        "parsed": getattr(message, "parsed", None),
        "tool_calls": tool_calls or None,
        "content_preview": (message.content or "")[:120],
    }


def run_single_request(client: OpenAI, scenario: Scenario, *, model: str) -> ScenarioResult:
    request = dict(scenario.request)
    request.setdefault("model", model)
    if request.pop("stream", False):
        try:
            stream = client.chat.completions.create(stream=True, **request)
            chunks: list[str] = []
            finish_reason: Optional[str] = None
            for chunk in stream:  # type: ignore[var-annotated]
                delta = chunk.choices[0].delta
                if delta.content:
                    chunks.append(delta.content)
                if chunk.choices[0].finish_reason:
                    finish_reason = chunk.choices[0].finish_reason
            summary = {
                "content": "".join(chunks).strip(),
                "chunks": chunks,
                "finish_reason": finish_reason,
            }
            return ScenarioResult(ok=finish_reason == "stop", summary=summarise_response(summary, streamed=True))
        except Exception as exc:  # noqa: BLE001
            return ScenarioResult(ok=False, summary={}, error=str(exc))

    try:
        response = client.chat.completions.create(**request)
        summary = summarise_response(response, streamed=False)
        return ScenarioResult(ok=True, summary=summary)
    except BadRequestError as exc:
        if scenario.expect_failure:
            return ScenarioResult(ok=True, summary={}, error=str(exc))
        return ScenarioResult(ok=False, summary={}, error=str(exc))
    except APIError as exc:  # Server-side OpenAI error
        return ScenarioResult(ok=False, summary={}, error=f"APIError: {exc}")
    except Exception as exc:  # noqa: BLE001 broad – diagnostic purposes
        return ScenarioResult(ok=False, summary={}, error=str(exc))


###############################################################################
# Entry point
###############################################################################


def build_client(base_url: str | None, api_key: str, timeout: float) -> OpenAI:
    kwargs: Dict[str, Any] = {"api_key": api_key, "timeout": timeout}
    if base_url:
        sanitized = base_url.rstrip("/")
        if not sanitized.endswith("/v1"):
            sanitized = f"{sanitized}/v1"
        kwargs["base_url"] = sanitized
    return OpenAI(**kwargs)


def print_header(title: str) -> None:
    print("\n" + title)
    print("=" * len(title))


def print_scenario_table(
    scenario: Scenario,
    local_result: ScenarioResult | None,
    openai_result: ScenarioResult | None,
) -> bool:
    """Print a human-friendly summary and return success of local run."""
    print_header(f"Scenario: {scenario.name} — {scenario.description}")

    def fmt_block(label: str, result: ScenarioResult | None) -> None:
        print(f"[{label}]")
        if result is None:
            print("  (skipped)")
            return
        if result.error:
            print(f"  error: {result.error}")
        if result.summary:
            pretty = json.dumps(result.summary, indent=2, ensure_ascii=False)
            print("  summary:")
            for line in pretty.splitlines():
                print(f"    {line}")
        print()

    fmt_block("local", local_result)
    fmt_block("openai", openai_result)

    return bool(local_result is None or local_result.ok)


def parse_args(argv: Iterable[str]) -> argparse.Namespace:
    # Parse --env-file first so that we can make environment defaults available
    # while processing the remaining arguments.
    env_parser = argparse.ArgumentParser(add_help=False)
    env_parser.add_argument(
        "--env-file",
        type=Path,
        default=None,
        help="Path to a .env file (default: repo root .env if present)",
    )
    env_args, remaining = env_parser.parse_known_args(list(argv))

    default_env_path = (
        env_args.env_file
        if env_args.env_file is not None
        else Path(__file__).resolve().parent.parent / ".env"
    )
    load_env_file(default_env_path)

    parser = argparse.ArgumentParser(description=__doc__, parents=[env_parser])
    parser.set_defaults(env_file=default_env_path)
    parser.add_argument(
        "--local-base-url",
        default=os.environ.get("LOCAL_OPENAI_BASE_URL", "http://localhost:8000"),
        help="Base URL for the local syslm server (default: http://localhost:8000)",
    )
    parser.add_argument(
        "--local-api-key",
        default=os.environ.get("LOCAL_OPENAI_API_KEY", "dummy-key"),
        help="API key for the local syslm server (default: dummy-key)",
    )
    parser.add_argument(
        "--local-model",
        default=os.environ.get("LOCAL_MODEL", "ondevice"),
        help="Model name exposed by the local server (default: ondevice)",
    )
    parser.add_argument(
        "--openai-model",
        default=os.environ.get("OPENAI_MODEL", "gpt-4.1-mini"),
        help="OpenAI model to compare against (default: gpt-4.1-mini)",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=30.0,
        help="Client timeout in seconds (default: 30)",
    )
    parser.add_argument(
        "--skip-local",
        action="store_true",
        help="Skip talking to the local server",
    )
    parser.add_argument(
        "--skip-openai",
        action="store_true",
        help="Skip talking to OpenAI",
    )

    return parser.parse_args(list(argv))


def main(argv: Iterable[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])

    scenarios = build_scenarios()

    local_client: Optional[OpenAI] = None
    openai_client: Optional[OpenAI] = None

    if not args.skip_local:
        local_client = build_client(args.local_base_url, args.local_api_key, args.timeout)

    if not args.skip_openai:
        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            print("[ERROR] OPENAI_API_KEY is required unless --skip-openai is used", file=sys.stderr)
            return 2
        openai_client = build_client(None, api_key, args.timeout)

    success = True
    for scenario in scenarios:
        local_result = (
            run_single_request(local_client, scenario, model=args.local_model)
            if local_client
            else None
        )
        openai_result = (
            run_single_request(openai_client, scenario, model=args.openai_model)
            if openai_client
            else None
        )
        success &= print_scenario_table(scenario, local_result, openai_result)

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
