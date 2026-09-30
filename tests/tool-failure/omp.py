#!/usr/bin/env python3
"""Report failed-tool-call ratios from omp session logs.

Usage: report.py [SESSIONS_DIR] [--tool NAME]

Reads every *.jsonl under SESSIONS_DIR (default ~/.omp/agent/sessions),
joins each toolResult to the assistant toolCall that produced it (for the
model name), and prints failure ratios by tool and by model. With --tool,
also prints a per-model breakdown and the top error prefixes for that tool.
Only hard errors (isError=true) are counted.
"""
import argparse
import collections
import glob
import json
import os
import re


def records(root):
    for path in glob.glob(os.path.join(root, "**", "*.jsonl"), recursive=True):
        owner = {}  # toolCallId -> model, scoped to one session file
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                msg = rec.get("message") if rec.get("type") == "message" else None
                if not msg:
                    continue
                if msg.get("role") == "assistant":
                    for c in msg.get("content") or []:
                        if isinstance(c, dict) and c.get("type") == "toolCall":
                            owner[c.get("id")] = msg.get("model")
                elif msg.get("role") == "toolResult":
                    text = "".join(
                        c.get("text", "")
                        for c in msg.get("content") or []
                        if isinstance(c, dict)
                    )
                    yield (
                        owner.get(msg.get("toolCallId"), "?"),
                        msg.get("toolName"),
                        bool(msg.get("isError")),
                        text,
                    )


def table(title, rows):
    print(title)
    for key, (bad, total) in sorted(rows.items(), key=lambda kv: -kv[1][1]):
        print(f"  {str(key):40} {bad:4}/{total:<5} {100 * bad / total:5.1f}%")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=os.path.expanduser("~/.omp/agent/sessions"))
    ap.add_argument("--tool")
    args = ap.parse_args()

    by_tool, by_model, by_model_tool = ({} for _ in range(3))
    reasons = collections.Counter()

    def bump(d, k, bad):
        b, t = d.get(k, (0, 0))
        d[k] = (b + bad, t + 1)

    for model, tool, bad, text in records(args.root):
        bump(by_tool, tool, bad)
        bump(by_model, model, bad)
        if tool == args.tool:
            bump(by_model_tool, model, bad)
            if bad:
                reasons[re.sub(r"\d+", "N", text)[:100]] += 1

    table("by tool", by_tool)
    table("by model", by_model)
    if args.tool:
        table(f"{args.tool} by model", by_model_tool)
        print(f"{args.tool} error prefixes")
        for text, n in reasons.most_common(10):
            print(f"  {n:3} {text!r}")


if __name__ == "__main__":
    main()
