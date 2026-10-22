"""A Claude Code stream-json run (`claude -p --output-format stream-json --verbose`) as a readable transcript:
the prompt, what Claude says, each tool call (→ name and arguments) and the start of its answer (←), and the final
reply. The home folder is written as ~ and the test's library as <library>; images as [image]. Nothing else is
changed. argv: stream file, home folder, library folder."""

import json
import sys

stream, home, library = sys.argv[1:4]


def clean(text):
    return text.replace(library, "<library>").replace(home, "~")


def answer(content):
    if isinstance(content, str):
        return content
    parts = []
    for part in content or []:
        if part.get("type") == "text":
            parts.append(part.get("text", ""))
        elif part.get("type") == "image":
            parts.append("[image]")
    return " ".join(parts)


for line in open(stream, encoding="utf-8"):
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    kind = event.get("type")
    if kind == "assistant":
        for part in event["message"].get("content", []):
            if part.get("type") == "text" and part.get("text", "").strip():
                print(clean("Claude: " + part["text"].strip()))
            elif part.get("type") == "tool_use":
                name = part.get("name", "").replace("mcp__vmpane__", "")
                print(clean(f"→ {name} {json.dumps(part.get('input', {}), ensure_ascii=False)}"))
    elif kind == "user":
        content = event.get("message", {}).get("content", [])
        if isinstance(content, str):
            print(clean("You: " + content.strip()))
            continue
        for part in content:
            if part.get("type") == "tool_result":
                text = " ".join(answer(part.get("content")).split())
                print(clean("← " + (text[:400] + " …" if len(text) > 400 else text)))
            elif part.get("type") == "text":
                print(clean("You: " + part.get("text", "").strip()))
    elif kind == "result":
        print(clean(f"[done: {event.get('num_turns', '?')} turns, {round(event.get('duration_ms', 0) / 1000)} s]"))
