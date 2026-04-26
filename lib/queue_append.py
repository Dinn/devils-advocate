#!/usr/bin/env python3
"""
Append a structured entry to <queue_dir>/<session_id>.jsonl.

Queue directory: $CLAUDE_PLUGIN_DATA/queue (falls back to ~/.claude/devils-advocate/queue).

Used by response-critic background worker (and optionally Skill) to enqueue
critique results that get consumed by the next UserPromptSubmit hook.

Writes atomically using fcntl file lock (POSIX). Safe for concurrent writers.

Usage:
    echo '{"source":"response-critic","severity":"medium","message":"..."}' \\
      | python3 queue_append.py --session <session_id>

    python3 queue_append.py --session <session_id> source=response-critic severity=medium message=...

The `ts` field is auto-injected (ISO-8601 UTC). Additional fields pass through.

Exit codes:
  0  appended
  2  bad input (no session_id or bad JSON)
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

_DA_DATA = os.environ.get("CLAUDE_PLUGIN_DATA")
if not _DA_DATA:
    sys.stderr.write(
        "CLAUDE_PLUGIN_DATA not set; queue_append must run in plugin context.\n"
    )
    sys.exit(2)
QUEUE_DIR = Path(_DA_DATA) / "queue"


def parse_kv_args(argv: list[str]) -> dict:
    out: dict = {}
    for a in argv:
        if "=" not in a:
            continue
        k, _, v = a.partition("=")
        if v.lower() in ("true", "false"):
            out[k] = v.lower() == "true"
        else:
            try:
                out[k] = int(v)
            except ValueError:
                try:
                    out[k] = float(v)
                except ValueError:
                    out[k] = v
    return out


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--session", required=True)
    parser.add_argument("kv", nargs="*")
    args, _ = parser.parse_known_args()

    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    entry: dict
    if raw.strip():
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError as e:
            print(f"invalid JSON on stdin: {e}", file=sys.stderr)
            return 2
        entry.update(parse_kv_args(args.kv))
    else:
        entry = parse_kv_args(args.kv)

    entry.setdefault("ts", datetime.now(timezone.utc).isoformat(timespec="seconds"))

    QUEUE_DIR.mkdir(parents=True, exist_ok=True)
    queue_file = QUEUE_DIR / f"{args.session}.jsonl"
    line = json.dumps(entry, ensure_ascii=False) + "\n"

    with queue_file.open("a", encoding="utf-8") as f:
        fcntl.flock(f.fileno(), fcntl.LOCK_EX)
        try:
            f.write(line)
            f.flush()
        finally:
            fcntl.flock(f.fileno(), fcntl.LOCK_UN)

    return 0


if __name__ == "__main__":
    sys.exit(main())
