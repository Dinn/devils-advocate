#!/bin/bash
# Devil's Advocate common library — sourced by hook scripts and workers.
#
# Provides:
#   get_config <dot.path>                   — read a value from config.json
#   locale_to_language <locale>             — POSIX locale code → language name
#   get_output_language                     — config > LC_ALL > LANG > English
#   call_claude <model> <sys_file> <input> <timeout>  — invoke claude -p with recursion guard
#   parse_severity <json>                   — extract severity from model JSON output
#   should_inject <json>                    — check severity >= min_severity
#   format_reminder <source> <json>         — wrap questions/concerns in <system-reminder>
#   consume_queue <queue_file>              — emit + clear queue entries
#   debug_log <message>                     — append to debug log if enabled
#
# Recursion guard: all claude -p invocations prefix DEVILS_ADVOCATE_INNER=1.
# Hooks check this at entry and exit early to prevent infinite loops.

if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ] || [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
  # Not in plugin context. Honor the hook policy (fail-silent) and exit quietly.
  return 0 2>/dev/null || exit 0
fi

DA_ROOT="$CLAUDE_PLUGIN_ROOT"
DA_DATA="$CLAUDE_PLUGIN_DATA"
DA_CONFIG="$DA_ROOT/config.json"
# shellcheck disable=SC2034  # consumed by hook scripts that source this file
DA_QUEUE_DIR="$DA_DATA/queue"
DA_DEDUP_DIR="$DA_DATA/dedup"

get_config() {
  local path="$1"
  local jq_path=".${path}"
  jq -r "$jq_path // empty" "$DA_CONFIG" 2>/dev/null
}

# locale_to_language LOCALE -> human-readable language name.
# Accepts POSIX locale codes (ko_KR.UTF-8, ko, en, etc.).
# Unknown codes fall back to English.
locale_to_language() {
  case "${1%%[._]*}" in
    ko) echo "Korean" ;;
    ja) echo "Japanese" ;;
    zh) echo "Chinese" ;;
    es) echo "Spanish" ;;
    fr) echo "French" ;;
    de) echo "German" ;;
    pt) echo "Portuguese" ;;
    ru) echo "Russian" ;;
    en|"") echo "English" ;;
    *) echo "English" ;;
  esac
}

# get_output_language -> language name for hook output.
# Priority: config.output_language > $LC_ALL > $LANG > English.
get_output_language() {
  local cfg
  cfg=$(get_config output_language)
  if [ -n "$cfg" ]; then
    printf '%s' "$cfg"
    return
  fi
  locale_to_language "${LC_ALL:-${LANG:-en_US.UTF-8}}"
}

debug_log() {
  local msg="$1"
  local enabled
  enabled=$(get_config debug)
  [ "$enabled" = "true" ] || return 0
  local log_file
  log_file=$(get_config debug_log)
  [ -z "$log_file" ] && log_file="/tmp/devils-advocate-debug.log"
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >> "$log_file"
}

# call_claude MODEL SYS_PROMPT_FILE USER_INPUT TIMEOUT
# Echoes the model's stdout (should be JSON). Returns non-zero on failure.
# Appends a runtime OUTPUT LANGUAGE instruction so user-facing strings
# render in the user's locale.
call_claude() {
  local model="$1"
  local sys_file="$2"
  local user_input="$3"
  local timeout_s="${4:-10}"

  [ -r "$sys_file" ] || { debug_log "call_claude: missing sys_file=$sys_file"; return 1; }

  local sys_prompt lang
  sys_prompt=$(cat "$sys_file")
  lang=$(get_output_language)
  sys_prompt="${sys_prompt}

=== OUTPUT LANGUAGE ===

Render all user-facing strings (questions, concerns) in ${lang}.
The reasoning field stays in English regardless of this setting."

  local output
  output=$(printf '%s' "$user_input" \
    | DEVILS_ADVOCATE_INNER=1 timeout "$timeout_s" claude -p \
        --model "$model" \
        --append-system-prompt "$sys_prompt" \
        2>/dev/null)
  local rc=$?

  if [ $rc -ne 0 ]; then
    debug_log "call_claude: rc=$rc model=$model timeout=$timeout_s"
    return $rc
  fi

  printf '%s' "$output"
  return 0
}

# parse_severity JSON_STRING -> one of: none|low|medium|high|""
parse_severity() {
  local json="$1"
  printf '%s' "$json" | jq -r '.severity // empty' 2>/dev/null
}

# severity_rank LEVEL -> integer (higher = more severe)
severity_rank() {
  case "$1" in
    none)   echo 0 ;;
    low)    echo 1 ;;
    medium) echo 2 ;;
    high)   echo 3 ;;
    *)      echo -1 ;;
  esac
}

# should_inject JSON_STRING COMPONENT — returns 0 (inject) or 1 (skip)
should_inject() {
  local json="$1"
  local component="$2"  # prompt_critic or response_critic
  local sev
  sev=$(parse_severity "$json")
  [ -z "$sev" ] && { debug_log "should_inject: missing severity"; return 1; }

  local min_sev
  min_sev=$(get_config "${component}.min_severity")
  [ -z "$min_sev" ] && min_sev="medium"

  local sev_rank min_rank
  sev_rank=$(severity_rank "$sev")
  min_rank=$(severity_rank "$min_sev")

  if [ "$sev_rank" -lt "$min_rank" ]; then
    debug_log "should_inject: skip (sev=$sev min=$min_sev)"
    return 1
  fi
  return 0
}

# format_reminder SOURCE JSON_STRING — emit <system-reminder> block to stdout
format_reminder() {
  local source="$1"
  local json="$2"
  # questions field for prompt-critic, concerns for response-critic — try both
  local items
  items=$(printf '%s' "$json" | jq -r '(.questions // .concerns // [])[]' 2>/dev/null \
    | sed 's/^/- /')
  [ -z "$items" ] && return 0
  # truncate each line to 80 chars
  items=$(printf '%s\n' "$items" | awk '{ if (length > 82) print substr($0,1,82); else print }')

  printf '<system-reminder>\n'
  printf 'Devil'"'"'s advocate (%s) — consider the following:\n' "$source"
  printf '%s\n' "$items"
  printf '</system-reminder>\n'
}

# dedup check: return 0 if novel (should inject), 1 if duplicate
dedup_check() {
  local session="$1"
  local json="$2"
  mkdir -p "$DA_DEDUP_DIR"
  local cache="$DA_DEDUP_DIR/${session}.txt"
  local reasoning
  reasoning=$(printf '%s' "$json" | jq -r '.reasoning // ""' 2>/dev/null)
  [ -z "$reasoning" ] && return 0
  local hash
  hash=$(printf '%s' "$reasoning" | shasum -a 256 | cut -c1-16)
  if [ -f "$cache" ] && grep -q "^$hash$" "$cache" 2>/dev/null; then
    debug_log "dedup_check: duplicate reasoning hash=$hash"
    return 1
  fi
  # keep last 5 hashes
  {
    echo "$hash"
    [ -f "$cache" ] && head -n 4 "$cache"
  } > "${cache}.tmp" && mv "${cache}.tmp" "$cache"
  return 0
}

# consume_queue QUEUE_FILE — emit <system-reminder> for each valid entry, then clear
# Entries older than queue_ttl_seconds are silently dropped.
consume_queue() {
  local queue_file="$1"
  [ -f "$queue_file" ] || return 0

  local ttl now
  ttl=$(get_config response_critic.queue_ttl_seconds)
  [ -z "$ttl" ] && ttl=3600
  now=$(date -u +%s)

  local any_emitted=0
  local line ts_epoch entry_age items

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # parse ts (ISO-8601) -> epoch. macOS `date -j -f` handles ISO.
    local ts_iso
    ts_iso=$(printf '%s' "$line" | jq -r '.ts // empty' 2>/dev/null)
    if [ -n "$ts_iso" ]; then
      # strip fractional seconds / timezone for macOS date parser
      local ts_clean="${ts_iso%+*}"
      ts_clean="${ts_clean%Z}"
      ts_clean="${ts_clean%.*}"
      ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null || echo 0)
      entry_age=$((now - ts_epoch))
      if [ "$ts_epoch" -gt 0 ] && [ "$entry_age" -gt "$ttl" ]; then
        debug_log "consume_queue: drop stale entry age=${entry_age}s"
        continue
      fi
    fi

    items=$(printf '%s' "$line" | jq -r '(.concerns // .questions // [])[]' 2>/dev/null)
    [ -z "$items" ] && continue

    if [ $any_emitted -eq 0 ]; then
      printf '<system-reminder>\n'
      printf 'Devil'"'"'s advocate (previous turn) — re-examination of the last response:\n'
      any_emitted=1
    fi
    printf '%s\n' "$items" | sed 's/^/- /' | awk '{ if (length > 82) print substr($0,1,82); else print }'
  done < "$queue_file"

  [ $any_emitted -eq 1 ] && printf '</system-reminder>\n'

  # clear queue after consuming
  : > "$queue_file"
}
