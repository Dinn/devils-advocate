# CLAUDE.md — devils-advocate plugin development conventions

This file is automatically pulled into context when you open a Claude Code session in this plugin repo. All work in this repo follows the rules below.

## Project overview

A multi-axis confirmation-bias guard for Claude Code. Three components:

- **prompt-critic** (UserPromptSubmit hook, Haiku, synchronous): challenges unverified assumptions in the user's prompt, in question form
- **response-critic** (Stop hook, Haiku → Opus auto-escalate, asynchronous): identifies hidden risks in the assistant's last response, in declarative form, and queues them for injection on the next turn
- **/devils-advocate** (manual skill, Opus + extended thinking): explicit deep critique. The Independence Gate dispatches the `devils-advocate-critic` subagent when the target was authored by Claude in the same session

## Directory layout

```
.claude-plugin/plugin.json      plugin metadata
hooks/
  hooks.json                    hook registration manifest (UserPromptSubmit / Stop)
  prompt-critic.sh              UserPromptSubmit entrypoint
  response-critic.sh            Stop entrypoint
skills/devils-advocate/         /devils-advocate skill
agents/                         devils-advocate-critic subagent
lib/                            common.sh, escalate.sh, run_response_critic.sh, queue_append.py
prompts/                        system prompts (prompt-critic.md, response-critic.md)
scripts/
  preflight.sh                  release-readiness check (tool presence + syntax + secret grep)
  git-hooks/{pre-commit,pre-push}
  install-hooks.sh              configures core.hooksPath
config.json                     default component settings (enabled, model, severity)
```

## External tool dependencies

System tools required on the developer's machine, installed once after clone.

- `bash` (4+) — hook script runtime
- `python3` — atomic jsonl append in `lib/queue_append.py` (uses fcntl)
- `jq` — JSON parsing (config, hook stdin)
- `shellcheck` — static analysis in preflight (release gate)

Install:
- macOS: `brew install jq shellcheck` (bash and python3 are usually preinstalled)
- Ubuntu/Debian: `sudo apt-get install jq shellcheck python3`
- Other OSes: use the distribution's package manager or install official binaries (preflight emits an explicit error and install hint when a tool is missing)

When you add a new tool dependency, also add it to the verification list in `scripts/preflight.sh`.

## Path conventions — non-negotiable

- **Read-only resources** (skill, prompts, lib code): use `${CLAUDE_PLUGIN_ROOT}`. Scripts must abort silently when this variable is unset (the plugin is not installed in this context).
- **Writable runtime data** (queue, dedup cache): use `${CLAUDE_PLUGIN_DATA}`. Same abort rule.
- **Absolute paths** like `/Users/...` are forbidden — preflight grep blocks them.
- **API keys / tokens** must never be hard-coded — only via environment variables or keychain. Preflight + GitHub secret scanning provide double defense.

There is no fallback to `$HOME/.claude/devils-advocate`. Scripts run only in a valid plugin context.

## Hook behavior

- Every hook is **fail-silent and exits 0**. The user's work must never be blocked.
- Recursion guard: any `claude -p` invocation from inside a hook must be prefixed with `DEVILS_ADVOCATE_INNER=1`. Hook entrypoints check this at the top and exit immediately to break loops.
- Silence first: only inject when severity ≥ medium. A reasoning-hash dedup cache suppresses repeated noise.

## Output language (locale)

Hook output (the `questions` / `concerns` arrays surfaced to the user) follows a runtime locale:

1. `config.json` field `output_language` — explicit override (e.g. `"Korean"`, `"Japanese"`, `"English"`). Optional.
2. Environment variable `LC_ALL`, then `LANG` — auto-detected from the user's POSIX locale.
3. Falls back to `English` if neither is set.

The `reasoning` field is always English regardless. Prompts in `prompts/*.md` are locale-agnostic; the runtime instruction is appended in `lib/common.sh::call_claude` via `get_output_language`.

To support a new language, extend `locale_to_language` in `lib/common.sh` with the ISO 639-1 code mapping.

## Git workflow

After cloning, **you must** activate hooks once:

```bash
./scripts/install-hooks.sh
```

After that, every commit and push runs verification automatically:
- pre-commit: fast secret scan over staged changes (lightweight; blocks history entry)
- pre-push: full preflight (shellcheck, syntax, secret grep) — release gate

`--no-verify` bypasses both. Use it deliberately and own the consequences.

## Release procedure

1. Commit and push the changes (auto-verification must pass).
2. Run `./scripts/preflight.sh` once more by hand for a clean confirmation.
3. `git tag v0.x.y && git push --tags`
4. Write release notes on GitHub Releases.

## Working notes

- When you add a new hook script, register it in `hooks/hooks.json` as well — Claude Code does not discover hooks otherwise.
- When you add a new external tool dependency, update the verification list in `scripts/preflight.sh`.
- Changes to `prompts/*.md` or `lib/*` propagate to the developer's environment via `/plugin update` (or whatever update path was configured at install time). Do not assume hot-reload.
- The Independence Gate dispatch pattern lives in `skills/devils-advocate/SKILL.md`. Do not bypass it.
