#!/bin/bash
# Stop hook — response-critic entry point.
#
# Responsibilities:
#   1. Recursion guard.
#   2. Parse session_id + transcript_path from hook stdin.
#   3. Spawn run_response_critic.sh in background (nohup + disown), exit immediately.
#
# The user sees Claude's response without any delay. The background worker
# produces a critique asynchronously; the next UserPromptSubmit consumes it from the queue.

set -u

# Recursion guard
if [ "${DEVILS_ADVOCATE_INNER:-0}" = "1" ]; then
  exit 0
fi

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi
# shellcheck source=../lib/common.sh
source "$CLAUDE_PLUGIN_ROOT/lib/common.sh"

# Component gate
if [ "$(get_config response_critic.enabled)" != "true" ]; then
  exit 0
fi

STDIN=$(cat)
SESSION_ID=$(printf '%s' "$STDIN" | jq -r '.session_id // ""' 2>/dev/null)
TRANSCRIPT=$(printf '%s' "$STDIN" | jq -r '.transcript_path // ""' 2>/dev/null)

if [ -z "$SESSION_ID" ] || [ -z "$TRANSCRIPT" ]; then
  debug_log "response-critic: missing session_id or transcript_path, skip"
  exit 0
fi

# Spawn background worker, detach
nohup bash "$DA_ROOT/lib/run_response_critic.sh" "$SESSION_ID" "$TRANSCRIPT" \
  > /dev/null 2>&1 &
disown

debug_log "response-critic: spawned background worker for session=$SESSION_ID"
exit 0
