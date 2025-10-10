#!/usr/bin/env python3
"""Interactive CLI for syslm-server with optional streaming and live tool execution."""

import argparse
import asyncio
import json
import os
from collections import defaultdict
from datetime import datetime
from typing import Any, Dict, List

from openai import AsyncOpenAI
from prompt_toolkit import PromptSession
from prompt_toolkit.patch_stdout import patch_stdout
from rich.console import Console
from rich.markdown import Markdown
from rich.table import Table

BASE_URL = os.environ.get("OPENAI_BASE_URL", "http://localhost:8000/v1")
API_KEY = os.environ.get("OPENAI_API_KEY", "dummy-key")

client = AsyncOpenAI(base_url=BASE_URL, api_key=API_KEY)
console = Console()

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "get_current_time",
            "description": "Return the current time in ISO 8601 format.",
            "parameters": {
                "type": "object",
                "properties": {},
                "required": []
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "calculate_expression",
            "description": "Evaluate a basic arithmetic expression (supports +, -, *, /, parentheses).",
            "parameters": {
                "type": "object",
                "properties": {
                    "expression": {
                        "type": "string",
                        "description": "Arithmetic expression to evaluate, e.g. '15 * (4 + 2)'"
                    }
                },
                "required": ["expression"],
                "additionalProperties": False
            }
        }
    },
    {
        "type": "function",
        "function": {
            "name": "lookup_country_capital",
            "description": "Look up the capital city for a supported country.",
            "parameters": {
                "type": "object",
                "properties": {
                    "country": {
                        "type": "string",
                        "description": "Country name (e.g., 'France', 'Japan', 'Canada')."
                    }
                },
                "required": ["country"],
                "additionalProperties": False
            }
        }
    }
]

CAPITALS = {
    "france": "Paris",
    "japan": "Tokyo",
    "canada": "Ottawa",
    "germany": "Berlin",
    "nigeria": "Abuja",
    "brazil": "Brasília",
}


def execute_tool(name: str, arguments: Dict[str, Any]) -> str:
    """Execute supported tool calls locally."""
    if name == "get_current_time":
        return datetime.now().isoformat()

    if name == "calculate_expression":
        expr = arguments.get("expression", "")
        try:
            if not expr or any(ch.isalpha() for ch in expr):
                raise ValueError("Expression must contain only numbers and arithmetic operators")
            value = eval(expr, {"__builtins__": {}}, {})  # noqa: S307
            return str(value)
        except Exception as exc:  # noqa: BLE001
            return f"Error evaluating expression: {exc}"

    if name == "lookup_country_capital":
        country = arguments.get("country", "").strip().lower()
        return CAPITALS.get(country, f"Unknown country: {arguments.get('country')}")

    return f"Unsupported tool: {name}"


async def stream_completion(messages: List[Dict[str, Any]]) -> Dict[str, Any]:
    stream = await client.chat.completions.create(
        model="ondevice",
        messages=messages,
        tools=TOOLS,
        tool_choice="auto",
        stream=True,
    )

    content_parts: List[str] = []
    role: str | None = None
    finish_reason: str | None = None
    tool_buffers: Dict[int, Dict[str, Any]] = defaultdict(lambda: {"id": None, "type": "function", "function": {"name": "", "arguments": ""}})
    announced_tools: set[int] = set()

    async for chunk in stream:
        choice = chunk.choices[0]
        delta = choice.delta.model_dump()

        if delta.get("role"):
            role = delta["role"]

        if delta.get("content"):
            text = delta["content"]
            content_parts.append(text)
            console.print(text, style="bright_cyan", end="", soft_wrap=True)

        if delta.get("tool_calls"):
            for call in delta["tool_calls"]:
                idx = call.get("index", 0)
                entry = tool_buffers[idx]
                if call.get("id"):
                    entry["id"] = call["id"]
                func = call.get("function")
                if func:
                    name = func.get("name")
                    if name:
                        entry["function"]["name"] = name
                        if idx not in announced_tools:
                            console.print(f"\n[tool-call] {name}", style="yellow")
                            announced_tools.add(idx)
                    if func.get("arguments"):
                        entry["function"]["arguments"] += func["arguments"]
                        console.print(func["arguments"], style="yellow", end="")

        if choice.finish_reason:
            finish_reason = choice.finish_reason

    if content_parts:
        console.print()  # ensure newline after streaming text

    tool_calls = [tool_buffers[i] for i in sorted(tool_buffers)] if tool_buffers else []
    return {
        "role": role or "assistant",
        "content": "".join(content_parts),
        "tool_calls": tool_calls if tool_buffers else None,
        "finish_reason": finish_reason,
    }


async def chat_loop() -> None:
    session = PromptSession()
    messages: List[Dict[str, Any]] = [
        {
            "role": "system",
            "content": (
                "You are a concise, factual assistant that MUST use the available tools when appropriate. "
                "Three tools are available: "
                "get_current_time (no arguments) -> returns current time in ISO 8601; "
                "calculate_expression (argument 'expression' as a string) -> evaluates arithmetic expressions; "
                "lookup_country_capital (argument 'country' as a string) -> returns the capital. "
            ),
        }
    ]

    console.print("[bold green]Interactive agent ready. Type 'exit' to quit.\n")

    while True:
        try:
            console.print("[bold magenta]You[/]: ", end="")
            with patch_stdout():
                user_input = await session.prompt_async("")
        except (EOFError, KeyboardInterrupt):
            console.print("\n[bold red]Goodbye![/]")
            break

        if user_input.strip().lower() in {"exit", "quit"}:
            console.print("[bold red]Goodbye![/]")
            break

        if not user_input.strip():
            continue

        messages.append({"role": "user", "content": user_input})

        while True:
            console.print("[bold blue]\nAssistant:[/] ", end="")
            response = await stream_completion(messages)

            tool_calls = response.get("tool_calls")
            if tool_calls:
                messages.append({"role": "assistant", "tool_calls": tool_calls})
                for call in tool_calls:
                    name = call["function"]["name"]
                    args = call["function"].get("arguments", "")
                    args_dict = json.loads(args or "{}")
                    result = execute_tool(name, args_dict)
                    table = Table(title=f"Tool {name}", show_header=False)
                    table.add_row("Arguments", json.dumps(args_dict, indent=2))
                    table.add_row("Result", result)
                    console.print()
                    console.print(table, style="bright_yellow")
                    messages.append(
                        {
                            "role": "tool",
                            "tool_call_id": call["id"],
                            "content": result,
                        }
                    )
                continue

            content = response.get("content", "")
            if content.strip():
                messages.append({"role": response.get("role", "assistant"), "content": content})
            break


def main() -> None:
    asyncio.run(chat_loop())


if __name__ == "__main__":
    main()
