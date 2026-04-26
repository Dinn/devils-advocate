#!/bin/bash
# UserPromptSubmit hook — prompt-critic entry point.
#
# This hook does NOT call `claude -p` directly. Instead it:
#   1. Drains the previous-turn response-critic queue (if any)
#   2. Injects an instruction asking the main Claude to judge whether the
#      user's prompt carries decision content; if so, to dispatch the
#      devils-advocate-critic subagent (Agent tool) before responding.
#
# Why this design (vs. the earlier `claude -p` synchronous call):
#   - claude -p cold start in this environment is roughly 5 seconds, so
#     even a 10-second timeout was unreliable and produced 100 percent
#     silent failures in practice.
#   - The main Claude has natural-language judgment to filter decision
#     content vs. trivial queries far more accurately than bash regex.
#   - The subagent runs in the same Claude Code session (no fork/cold-start),
#     and its findings flow naturally into the main response context.
#
# All failures are silent (exit 0 with no stdout). The user's work is never blocked.

set -u

# Recursion guard — kept for safety even though this hook no longer calls claude -p.
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

# === Step 1: Drain previous-turn queue (response-critic results) ===
if [ -n "$SESSION_ID" ]; then
  QUEUE_FILE="$DA_QUEUE_DIR/${SESSION_ID}.jsonl"
  if [ -s "$QUEUE_FILE" ]; then
    consume_queue "$QUEUE_FILE"
  fi
fi

# === Step 2: Inject judgment instruction ===
cat <<'EOF'
<system-reminder>
A devil's-advocate review may be warranted on the user's prompt above.

Before producing your main response, judge whether the prompt carries decision
content that benefits from independent review:

- Data loss risk (DROP/DELETE or other destructive operations)
- Architecture, design, or refactoring choice
- Security or auth implication
- Production, deployment, or migration step
- Breaking change to a public surface
- Any case where an unverified assumption could be costly

If YES: dispatch the `devils-advocate-critic` subagent (Agent tool, model: opus)
to review this exact user prompt. Pass the user's prompt verbatim as the target.
Incorporate the subagent's findings into your reasoning before producing your main
response.

If NO (file read, simple lookup, clarifying question, code explanation, formatting,
mechanical translation, etc.): proceed normally. Do not dispatch the subagent.

The subagent enforces a strict silence rule — if it finds nothing substantive it
returns a no-op result, and you proceed as if no critique existed. Forced
objection is worse than no objection.
</system-reminder>
EOF

debug_log "prompt-critic: injected judgment instruction (session=$SESSION_ID)"
exit 0
