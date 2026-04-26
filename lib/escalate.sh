#!/bin/bash
# escalate.sh — analyze AI response text and decide Haiku vs Opus for response-critic.
#
# Usage:
#   echo "<response text>" | bash escalate.sh
#   Output: "haiku" or "opus" on stdout.
#
# Heuristic: if the response contains keywords suggesting consequential decisions,
# use Opus for deeper critique. Otherwise stay on Haiku.

set -u

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi
DA_ROOT="$CLAUDE_PLUGIN_ROOT"
CONFIG="$DA_ROOT/config.json"

INPUT=$(cat)

HAIKU_MODEL=$(jq -r '.response_critic.model // "claude-haiku-4-5-20251001"' "$CONFIG" 2>/dev/null)
OPUS_MODEL=$(jq -r '.response_critic.escalate_model // "claude-opus-4-7"' "$CONFIG" 2>/dev/null)

# Load escalation triggers from config
TRIGGERS=$(jq -r '.response_critic.escalate_triggers[]? // empty' "$CONFIG" 2>/dev/null)

# Keyword groups per trigger
escalate=0
for trigger in $TRIGGERS; do
  case "$trigger" in
    code_change)
      # Heuristic: diff markers, file extension mentions, code fence patterns
      if printf '%s' "$INPUT" | grep -qE '(```[a-z]+|diff --git|^\+\+\+|\bfunction\b|\bclass\b|\bdef \b)'; then
        escalate=1; break
      fi
      ;;
    architectural_decision)
      if printf '%s' "$INPUT" | grep -iqE '\b(architecture|refactor|should|recommend|instead|approach|pattern|design)\b'; then
        escalate=1; break
      fi
      ;;
    migration)
      if printf '%s' "$INPUT" | grep -iqE '\b(migrate|migration|upgrade|breaking change|backwards[- ]?compat)\b'; then
        escalate=1; break
      fi
      ;;
    security)
      if printf '%s' "$INPUT" | grep -iqE '\b(security|auth|authentication|authorization|credential|secret|token|injection|sql|xss|csrf)\b'; then
        escalate=1; break
      fi
      ;;
    deployment)
      if printf '%s' "$INPUT" | grep -iqE '\b(deploy|production|prod\b|rollout|release|canary|rollback)\b'; then
        escalate=1; break
      fi
      ;;
  esac
done

if [ "$escalate" -eq 1 ]; then
  printf '%s\n' "$OPUS_MODEL"
else
  printf '%s\n' "$HAIKU_MODEL"
fi
