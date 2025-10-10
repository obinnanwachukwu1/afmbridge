#!/usr/bin/env python3
"""Run a multi-turn chat with optional tool execution against the local syslm-server.

The script uses the `openai` Python SDK to talk to the API exposed by syslm-server.
It demonstrates:
  * Supplying a system prompt.
  * Allowing the model to call real tools.
  * Looping until the model produces a final answer (without tool calls).
"""

import json
import os
from datetime import datetime
from typing import Any, Dict

from openai import OpenAI

BASE_URL = os.environ.get("OPENAI_BASE_URL", "http://localhost:8000/v1")
API_KEY = os.environ.get("OPENAI_API_KEY", "dummy-key")

client = OpenAI(base_url=BASE_URL, api_key=API_KEY)

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
            # Evaluate safely with Python's eval limited to arithmetic characters.
            # Using eval on trusted arithmetic (no letters) keeps things simple.
            if not expr or any(ch.isalpha() for ch in expr):
                raise ValueError("Expression must contain only numbers and arithmetic operators")
            value = eval(expr, {"__builtins__": {}}, {})
            return str(value)
        except Exception as exc:  # noqa: BLE001
            return f"Error evaluating expression: {exc}"

    if name == "lookup_country_capital":
        country = arguments.get("country", "").strip().lower()
        return CAPITALS.get(country, f"Unknown country: {arguments.get('country')}")

    return f"Unsupported tool: {name}"


def print_assistant_content(message: Dict[str, Any]) -> None:
    content = message.get("content")
    if content:
        print("Assistant:", content)


def main() -> None:
    messages: list[dict[str, Any]] = [
        {
            "role": "system",
            "content": (
                "You are a friendly productivity assistant. "
                "Use the provided tools whenever they can help."
            ),
        },
        {
            "role": "user",
            "content": (
                "Hi! I have two requests: "
                "(1) Tell me the current local time. "
                "(2) Compute 15 * (4 + 2). "
                "Also, remind me what the capital of Japan is."
            ),
        },
    ]

    while True:
        response = client.chat.completions.create(
            model="ondevice",
            messages=messages,
            tools=TOOLS,
            tool_choice="auto",
        )

        choice = response.choices[0]
        message = choice.message.model_dump()

        # Display assistant content if present.
        print_assistant_content(message)

        tool_calls = message.get("tool_calls")
        if tool_calls:
            # Append assistant tool call to history.
            messages.append(
                {
                    "role": "assistant",
                    "tool_calls": tool_calls,
                }
            )
            # Execute each tool call and append tool outputs.
            for call in tool_calls:
                function = call["function"]
                name = function["name"]
                arguments = json.loads(function["arguments"] or "{}")
                result = execute_tool(name, arguments)
                print(f"[tool {name}] -> {result}")
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call["id"],
                        "content": result,
                    }
                )
            # Continue loop to let the model incorporate tool results.
            continue

        # No tool calls -> final answer.
        break


if __name__ == "__main__":
    main()
