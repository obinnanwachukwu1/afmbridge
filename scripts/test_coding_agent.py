#!/usr/bin/env python3
"""Mini end-to-end test that exercises the local coding agent via multi-turn edits.

The flow mimics a lightweight "Cursor" interaction:

1. Create a temporary workspace containing a stub Python module.
2. Start a chat session with the local syslm-server model.
3. Provide ``read_file`` and ``apply_patch`` tools so the agent can inspect/modify files.
4. Loop until the agent returns a natural-language answer (no tool calls).
5. Run predefined tests against the edited module.

The task is intentionally simple so it fits under a 4K-token context window.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import textwrap
from pathlib import Path
from typing import Any, Dict

from openai import OpenAI

BASE_URL = os.environ.get("OPENAI_BASE_URL", "http://localhost:8000/v1")
API_KEY = os.environ.get("OPENAI_API_KEY", "dummy-key")

client = OpenAI(base_url=BASE_URL, api_key=API_KEY)


def normalize_relative_path(path: str) -> str:
    """Normalize absolute-style tool paths back to workspace-relative."""
    normalized = path.strip()
    if not normalized:
        return path
    normalized = normalized.lstrip("/")
    for prefix in ("workspace/", "tmp/", "home/", "Users/"):
        if normalized.startswith(prefix):
            normalized = normalized[len(prefix) :]
            break
    return normalized


TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "read_file",
            "description": "Return the UTF-8 contents of a source file relative to the workspace.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative file path to read, e.g. 'calculator.py'",
                    }
                },
                "required": ["path"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "apply_patch",
            "description": (
                "Apply a unified diff (‘diff -u’ format) to a file. "
                "The diff must reference the same relative path as provided in the call."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {
                        "type": "string",
                        "description": "Relative file path to patch, e.g. 'calculator.py'",
                    },
                    "diff": {
                        "type": "string",
                        "description": (
                            "Unified diff covering ONLY the requested file. "
                            "Include context lines and terminate with a newline."
                        ),
                    },
                },
                "required": ["path", "diff"],
                "additionalProperties": False,
            },
        },
    },
]


def make_workspace() -> Path:
    """Create the temporary workspace with the starter Python module."""
    temp_dir = Path(tempfile.mkdtemp(prefix="agent-workspace-"))
    initial_source = textwrap.dedent(
        '''
        """Simple math helpers."""

        from __future__ import annotations


        def factorial(n: int) -> int:
            """Return n! for non-negative integers.

            Args:
                n: Non-negative integer.

            Returns:
                Factorial of n.

            Raises:
                ValueError: If n is negative.
            """
            # TODO: implement the function.
            raise NotImplementedError("factorial is not implemented yet")
        '''
    ).lstrip()
    (temp_dir / "calculator.py").write_text(initial_source, encoding="utf-8")
    return temp_dir


def run_tests(workspace: Path) -> bool:
    """Run the predefined checks against the edited module."""
    test_code = f"""
import importlib.util
import sys
from pathlib import Path

workspace = Path({workspace.as_posix()!r})
sys.path.insert(0, str(workspace))

import calculator

assert calculator.factorial(0) == 1
assert calculator.factorial(1) == 1
assert calculator.factorial(5) == 120
assert calculator.factorial(6) == 720

try:
    calculator.factorial(-1)
except ValueError:
    pass
else:
    raise AssertionError("factorial should raise ValueError for negative input")
"""

    proc = subprocess.run(
        [sys.executable, "-c", test_code],
        cwd=workspace,
        capture_output=True,
        text=True,
    )
    if proc.returncode == 0:
        print("✅ Tests passed")
        return True

    print("❌ Tests failed")
    if proc.stdout:
        print(proc.stdout)
    if proc.stderr:
        print(proc.stderr)
    return False


def handle_read_file(workspace: Path, args: Dict[str, Any]) -> str:
    path = args.get("path")
    if not isinstance(path, str):
        return "read_file error: 'path' must be a string"

    rel_path = normalize_relative_path(path)
    target = workspace / rel_path
    if not target.is_file():
        return f"read_file error: file '{rel_path}' not found"

    content = target.read_text(encoding="utf-8")
    # Cap large responses to avoid bloating the model context.
    if len(content) > 3000:
        content = content[:3000] + "\n... (truncated)"
    return content


def handle_apply_patch(workspace: Path, args: Dict[str, Any]) -> str:
    path = args.get("path")
    diff = args.get("diff")
    if not isinstance(path, str) or not isinstance(diff, str):
        return "apply_patch error: 'path' and 'diff' must be strings"

    rel_path = normalize_relative_path(path)
    target = workspace / rel_path
    if not target.exists():
        return f"apply_patch error: file '{rel_path}' not found"

    # Ensure the diff references the same relative path to avoid surprise edits.
    def diff_mentions_path(text: str) -> bool:
        for line in text.splitlines():
            if line.startswith(("+++", "---")):
                tokens = line.split()
                if len(tokens) >= 2:
                    candidate = tokens[1]
                    candidate = candidate.lstrip("ab/")
                    if candidate.endswith(rel_path):
                        return True
        return False

    if not diff_mentions_path(diff):
        # Fallback: support simple replacement snippets for the common scenario where
        # the agent only returns the updated line(s).
        stripped = diff.strip()
        if "\n" not in stripped and stripped.startswith("return") and "NotImplementedError" in target.read_text(encoding="utf-8"):
            original = target.read_text(encoding="utf-8")
            new_content = original.replace(
                'raise NotImplementedError("factorial is not implemented yet")',
                stripped,
            )
            target.write_text(new_content, encoding="utf-8")
            return "Applied simple one-line replacement."
        return "apply_patch error: diff must reference the exact file path"

    proc = subprocess.run(
        ["patch", "-p0", "--directory", str(workspace)],
        input=diff if diff.endswith("\n") else diff + "\n",
        capture_output=True,
        text=True,
    )

    if proc.returncode != 0:
        return (
            "apply_patch error: failed to apply diff\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )

    return proc.stdout.strip() or "Patch applied successfully."


def log_heading(title: str) -> None:
    print(f"\n=== {title} ===")


def main() -> None:
    workspace = make_workspace()
    print(f"🧪 Workspace root: {workspace}")

    messages: list[dict[str, Any]] = [
        {
            "role": "system",
                "content": (
                    "You are a diligent coding agent working in a temporary repo. Keep every reply under 120 tokens and avoid chit-chat.\n\n"
                    "TOOL PROTOCOL\n"
                    "- Never call a tool without the required arguments. Empty {} is forbidden.\n"
                    "- read_file arguments: {\"path\": \"calculator.py\"}.\n"
                    "- apply_patch arguments: {\"path\": \"calculator.py\", \"diff\": \"...\"}. Provide a unified diff only for that file.\n"
                    "  Example diff:\n"
                    "  ```diff\n"
                    "  --- calculator.py\n"
                    "  +++ calculator.py\n"
                    "  @@\n"
                    "  -raise NotImplementedError(...)\n"
                    "  +return 1\n"
                    "  ```\n"
                    "- Example tool_calls payload you should emit:\n"
                    "  {\"tool_calls\":[{\"id\":\"call_read\",\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"calculator.py\\\"}\"}}]}\n"
                    "- Always read_file -> apply_patch -> read_file (if verification needed) in that order.\n\n"
                    "EXAMPLE SESSION\n"
                    "Assistant: Plan: inspect factorial.\n"
                    "Assistant tool_calls -> read_file with {\"path\":\"calculator.py\"}.\n"
                    "Assistant: Plan: implement factorial iteratively.\n"
                    "Assistant tool_calls -> apply_patch with {\"path\":\"calculator.py\",\"diff\":\"--- calculator.py\\n+++ calculator.py\\n@@\\n-raise NotImplementedError(...)\\n+...new code...\\n\"}.\n"
                    "Assistant tool_calls -> read_file with {\"path\":\"calculator.py\"} to verify.\n"
                    "Assistant: Summary + tests checkbox.\n\n"
                    "WORKFLOW\n"
                    "1. State the planned change in one sentence before calling a tool.\n"
                    "2. Use the tools with proper JSON arguments.\n"
                    "3. When finished, reply with: (a) a one-sentence summary, (b) a short Python code block showing the final factorial implementation, (c) a checklist of tests with [x] or [ ]."
                ),
        },
        {
            "role": "user",
            "content": (
                "We created a workspace with calculator.py. Implement factorial according"
                " to the docstring: support non-negative ints, raise ValueError for negatives,"
                " and use an efficient iterative or recursive approach. After updating the"
                " file, stop making tool calls and summarize the change."
            ),
        },
    ]

    tool_handlers = {
        "read_file": handle_read_file,
        "apply_patch": handle_apply_patch,
    }

    turn = 1
    while True:
        log_heading(f"Turn {turn}: sending request to coding agent")
        print(f"Messages so far: {len(messages)}")
        response = client.chat.completions.create(
            model="ondevice",
            messages=messages,  # type: ignore[arg-type]
            tools=TOOLS,  # type: ignore[arg-type]
            tool_choice="auto",
        )

        choice = response.choices[0]
        message = choice.message.model_dump()

        print("--- Assistant metadata ---")
        print(json.dumps({k: v for k, v in message.items() if k != "tool_calls"}, indent=2))

        if message.get("content"):
            print("Assistant:", message["content"])

        tool_calls = message.get("tool_calls") or []
        if tool_calls:
            print("--- Tool calls requested ---")
            for call in tool_calls:
                print(json.dumps(call, indent=2))

            messages.append({"role": "assistant", "content": "", "tool_calls": tool_calls})

            for call in tool_calls:
                name = call["function"]["name"]
                raw_arguments = call["function"].get("arguments") or "{}"
                try:
                    arguments = json.loads(raw_arguments)
                except json.JSONDecodeError as exc:  # noqa: TRY003
                    result = f"arguments JSON decode error: {exc}"
                    print(f"[tool {name}] -> {result}")
                    messages.append(
                        {
                            "role": "tool",
                            "tool_call_id": call["id"],
                            "name": name,
                            "content": result,
                        }
                    )
                    continue
                handler = tool_handlers.get(name)
                if not handler:
                    result = f"error: unsupported tool '{name}'"
                else:
                    result = handler(workspace, arguments)

                if name == "apply_patch":
                    print("[tool apply_patch] diff:\n" + arguments.get("diff", ""))
                print(
                    f"[tool {name} args={arguments}] -> {result[:400]}"
                    + ("..." if len(result) > 400 else "")
                )

                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": call["id"],
                        "name": name,
                        "content": result,
                    }
                )

            turn += 1
            continue

        break

    success = run_tests(workspace)
    sys.exit(0 if success else 1)


if __name__ == "__main__":
    main()
