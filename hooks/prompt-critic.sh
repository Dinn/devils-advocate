#!/bin/bash
# UserPromptSubmit hook — prompt-critic entry point.
#
# Responsibilities:
#   1. Recursion guard (exit if called from inside claude -p).
#   2. Consume any pending response-critic entries from session queue.
#   3. Synchronously call prompt-critic Haiku; inject if severity >= min_severity.
#
# All failures are silent (exit 0 with no stdout). The user's work is NEVER blocked.

set -u

# Recursion guard: if we're already inside a claude -p spawned by a hook, exit immediately.
if [ "${DEVILS_ADVOCATE_INNER:-0}" = "1" ]; then
  exit 0
fi

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi
# shellcheck source=../lib/common.sh
source "$CLAUDE_PLUGIN_ROOT/lib/common.sh"

# Component gate
if [ "$(get_config prompt_critic.enabled)" != "true" ]; then
  exit 0
fi

STDIN=$(cat)
SESSION_ID=$(printf '%s' "$STDIN" | jq -r '.session_id // ""' 2>/dev/null)
USER_PROMPT=$(printf '%s' "$STDIN" | jq -r '.prompt // ""' 2>/dev/null)

# === Step 1: Consume queue (previous turn's response-critic results) ===
if [ -n "$SESSION_ID" ]; then
  QUEUE_FILE="$DA_QUEUE_DIR/${SESSION_ID}.jsonl"
  if [ -s "$QUEUE_FILE" ]; then
    consume_queue "$QUEUE_FILE"
  fi
fi

# === Step 2: Synchronous prompt-critic call ===
if [ -z "$USER_PROMPT" ]; then
  debug_log "prompt-critic: empty user prompt, skip"
  exit 0
fi

MODEL=$(get_config prompt_critic.model)
[ -z "$MODEL" ] && MODEL="claude-haiku-4-5-20251001"

TIMEOUT=$(get_config prompt_critic.timeout_seconds)
[ -z "$TIMEOUT" ] && TIMEOUT=5

SYS_FILE="$DA_ROOT/prompts/prompt-critic.md"

debug_log "prompt-critic: calling model=$MODEL timeout=${TIMEOUT}s prompt_len=${#USER_PROMPT}"

RESULT=$(call_claude "$MODEL" "$SYS_FILE" "$USER_PROMPT" "$TIMEOUT") || {
  debug_log "prompt-critic: call_claude failed, skip"
  exit 0
}

# === Step 3: Severity filter + inject ===
if ! should_inject "$RESULT" prompt_critic; then
  exit 0
fi

# dedup
if ! dedup_check "${SESSION_ID:-default}" "$RESULT"; then
  exit 0
fi

format_reminder "prompt-critic" "$RESULT"
exit 0
