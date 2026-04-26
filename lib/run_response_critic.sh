#!/bin/bash
# run_response_critic.sh — background worker for response-critic.
# Spawned by hooks/response-critic.sh via nohup; runs detached from the hook.
#
# Usage: run_response_critic.sh <session_id> <transcript_path>
#
# Steps:
#   1. Extract the last assistant message from the transcript.
#   2. Decide model via escalate.sh (haiku vs opus).
#   3. Call claude -p with response-critic system prompt.
#   4. Parse severity; if >= min_severity, append to session queue via queue_append.py.
#   5. All failures are silent — debug log only.

set -u

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi
# shellcheck source=common.sh
source "$CLAUDE_PLUGIN_ROOT/lib/common.sh"

SESSION_ID="${1:-}"
TRANSCRIPT="${2:-}"

if [ -z "$SESSION_ID" ] || [ -z "$TRANSCRIPT" ] || [ ! -r "$TRANSCRIPT" ]; then
  debug_log "run_response_critic: missing args (session=$SESSION_ID transcript=$TRANSCRIPT)"
  exit 0
fi

# 1. Extract last assistant text message from transcript.
# Transcript is JSONL; each line is a turn. Assistant text is at .message.content[].text.
LAST_ASSISTANT=$(grep '"role":"assistant"' "$TRANSCRIPT" 2>/dev/null | tail -n 1)
if [ -z "$LAST_ASSISTANT" ]; then
  debug_log "run_response_critic: no assistant turn found"
  exit 0
fi

RESPONSE_TEXT=$(printf '%s' "$LAST_ASSISTANT" \
  | jq -r '[.message.content[]? | select(.type=="text") | .text] | join("\n\n")' 2>/dev/null)

if [ -z "$RESPONSE_TEXT" ]; then
  debug_log "run_response_critic: empty response text"
  exit 0
fi

# 2. Decide model via escalate.sh
MODEL=$(printf '%s' "$RESPONSE_TEXT" | bash "$DA_ROOT/lib/escalate.sh")
[ -z "$MODEL" ] && MODEL="claude-haiku-4-5-20251001"

# 3. Call claude -p with response-critic prompt
SYS_PROMPT_FILE="$DA_ROOT/prompts/response-critic.md"
TIMEOUT=$(get_config response_critic.timeout_seconds)
[ -z "$TIMEOUT" ] && TIMEOUT=30

debug_log "run_response_critic: model=$MODEL timeout=${TIMEOUT}s response_len=${#RESPONSE_TEXT}"

RESULT=$(call_claude "$MODEL" "$SYS_PROMPT_FILE" "$RESPONSE_TEXT" "$TIMEOUT") || {
  debug_log "run_response_critic: call_claude failed"
  exit 0
}

# 4. Parse severity and enqueue if above threshold
if ! should_inject "$RESULT" response_critic; then
  debug_log "run_response_critic: severity below min, skipping enqueue"
  exit 0
fi

# dedup check
if ! dedup_check "$SESSION_ID" "$RESULT"; then
  debug_log "run_response_critic: duplicate, skipping enqueue"
  exit 0
fi

# Build entry: severity, concerns, reasoning, source
ENTRY=$(printf '%s' "$RESULT" \
  | jq -c '{severity, concerns: (.concerns // .questions // []), reasoning: (.reasoning // ""), source: "response-critic"}' 2>/dev/null)

if [ -z "$ENTRY" ]; then
  debug_log "run_response_critic: failed to build queue entry"
  exit 0
fi

printf '%s' "$ENTRY" | python3 "$DA_ROOT/lib/queue_append.py" --session "$SESSION_ID" \
  && debug_log "run_response_critic: enqueued severity=$(parse_severity "$RESULT")"

exit 0
