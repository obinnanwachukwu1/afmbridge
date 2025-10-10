#!/usr/bin/env python3
import json
import os
import sys
from openai import OpenAI, BadRequestError

BASE_URL = os.environ.get("OPENAI_BASE_URL", "http://localhost:8000/v1")
API_KEY = os.environ.get("OPENAI_API_KEY", "dummy-key")

client = OpenAI(base_url=BASE_URL, api_key=API_KEY)

def pretty(obj):
    return json.dumps(obj, indent=2, ensure_ascii=False)

def assert_true(condition, message):
    if not condition:
        raise AssertionError(message)

def run_basic_completion():
    response = client.chat.completions.create(
        model="ondevice",
        messages=[
            {"role": "system", "content": "You are concise."},
            {"role": "user", "content": "Name a fruit."}
        ],
    )
    data = response.model_dump()
    print("\n=== Basic Completion ===")
    print(pretty(data))
    choice = data["choices"][0]
    assert_true(choice["finish_reason"] == "stop", "finish_reason should be stop")
    assert_true(choice["message"]["role"] == "assistant", "role should be assistant")
    assert_true(choice["message"]["content"], "assistant content should be present")


def run_structured_completion():
    response = client.chat.completions.create(
        model="ondevice",
        messages=[
            {"role": "system", "content": "You speak JSON only."},
            {"role": "user", "content": "Return a sandwich summary with name and ingredients list of two items."}
        ],
        response_format={
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
                            "maxItems": 5
                        }
                    },
                    "required": ["name", "ingredients"],
                    "additionalProperties": False
                }
            }
        }
    )
    data = response.model_dump()
    print("\n=== Structured Completion ===")
    print(pretty(data))
    choice = data["choices"][0]
    parsed = choice["message"].get("parsed")
    assert_true(parsed is not None, "parsed schema output should exist")
    # Flatten keys to ensure required fields exist somewhere in the structure.
    def flatten_keys(obj):
        keys = set()
        if isinstance(obj, dict):
            for k, v in obj.items():
                keys.add(k)
                keys.update(flatten_keys(v))
        elif isinstance(obj, list):
            for item in obj:
                keys.update(flatten_keys(item))
        return keys

    keys = flatten_keys(parsed)
    assert_true("name" in keys, "parsed JSON missing 'name'")
    assert_true("ingredients" in keys, "parsed JSON missing 'ingredients'")


def run_tool_call():
    response = client.chat.completions.create(
        model="ondevice",
        messages=[
            {"role": "system", "content": "You may call functions to help."},
            {"role": "user", "content": "Call the echo tool with message hello"}
        ],
        tools=[
            {
                "type": "function",
                "function": {
                    "name": "echo",
                    "description": "Echo a message",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "message": {"type": "string"}
                        },
                        "required": ["message"],
                        "additionalProperties": False
                    }
                }
            }
        ]
    )
    data = response.model_dump()
    print("\n=== Tool Call ===")
    print(pretty(data))
    choice = data["choices"][0]
    assert_true(choice["finish_reason"] == "tool_calls", "finish_reason should be tool_calls")
    tool_calls = choice["message"].get("tool_calls")
    assert_true(tool_calls and tool_calls[0]["function"]["name"] == "echo", "tool call not emitted")


def run_tool_choice_none():
    response = client.chat.completions.create(
        model="ondevice",
        messages=[
            {"role": "system", "content": "You may call functions to help."},
            {"role": "user", "content": "Explain why tool choice none means answer directly."}
        ],
        tool_choice="none",
        tools=[
            {
                "type": "function",
                "function": {
                    "name": "echo",
                    "description": "Echo a message",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "message": {"type": "string"}
                        },
                        "required": ["message"],
                        "additionalProperties": False
                    }
                }
            }
        ]
    )
    data = response.model_dump()
    print("\n=== Tool Choice None ===")
    print(pretty(data))
    choice = data["choices"][0]
    assert_true(choice["finish_reason"] == "stop", "finish_reason should be stop when tool choice none")
    assert_true(choice["message"]["content"], "assistant should provide text content")


def run_invalid_schema():
    try:
        client.chat.completions.create(
            model="ondevice",
            messages=[
                {"role": "user", "content": "Hi"}
            ],
            response_format={
                "type": "json_schema",
                "json_schema": {
                    "name": "BadSchema",
                    "schema": {"type": "unknown"}
                }
            }
        )
    except BadRequestError as exc:
        print("\n=== Invalid Schema ===")
        print(exc)
        return
    except Exception as exc:
        raise AssertionError(f"Unexpected error type for invalid schema: {exc}")
    raise AssertionError("Invalid schema request should have failed")


def run_streaming_completion():
    stream = client.chat.completions.create(
        model="ondevice",
        messages=[
            {"role": "system", "content": "You are concise."},
            {"role": "user", "content": "Summarize Apple in one short sentence."}
        ],
        stream=True
    )
    print("\n=== Streaming Completion ===")
    content_parts: list[str] = []
    content_events = 0
    finish_reason = None
    for chunk in stream:
        data = chunk.model_dump()
        print(pretty(data))
        delta = data["choices"][0]["delta"]
        if delta.get("content"):
            content_parts.append(delta["content"])
            content_events += 1
        if data["choices"][0].get("finish_reason"):
            finish_reason = data["choices"][0]["finish_reason"]

    full_content = "".join(content_parts).strip()
    assert_true(full_content != "", "Streaming content should not be empty")
    assert_true(content_events > 1, "Streaming should emit multiple content chunks")
    assert_true(finish_reason == "stop", "Streaming finish reason should be stop")


def main():
    print(f"Using OpenAI base URL: {BASE_URL}")
    run_basic_completion()
    run_structured_completion()
    run_tool_call()
    run_tool_choice_none()
    run_streaming_completion()
    run_invalid_schema()
    print("\nAll tests completed successfully.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Test failure: {error}")
        sys.exit(1)
