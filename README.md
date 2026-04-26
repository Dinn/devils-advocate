# devils-advocate

A multi-axis confirmation-bias guard for [Claude Code](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview).

When you work with an AI coding assistant, two biases compound silently:

1. **Your own confirmation bias** — the prompt you just typed may rest on assumptions you never verified.
2. **The assistant's author bias** — Claude tends to defend the reasoning of the answer it just produced.

This plugin pushes back on both. It runs three independent critics, each tuned for a different moment in the loop.

## Components

| Component | Trigger | Model | Mode | Tone | Output |
|---|---|---|---|---|---|
| **prompt-critic** | `UserPromptSubmit` hook | Haiku | Synchronous (≤5s) | Question form ("Have you verified X?") | `<system-reminder>` injected into the same turn |
| **response-critic** | `Stop` hook | Haiku → Opus auto-escalate | Asynchronous, queued | Declarative ("This skips Y; consider Z.") | Surfaces on the *next* `UserPromptSubmit` |
| **/devils-advocate** skill | Manual invocation | Opus + extended thinking | Foreground deep critique | Binary PASS/FAIL with concrete fixes | Inline report; dispatches `devils-advocate-critic` subagent when self-authored, to block author bias |

All three honor a strict **silence rule**: when uncertain, they default to no output. Forced objection is worse than no objection. Severity below `medium` is dropped; repeated reasoning hashes are deduped.

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview) with plugin support
- `bash` (4+)
- `python3`
- `jq`
- An Anthropic API account or Claude Code OAuth login (used by the hooks to invoke `claude -p`)

## Install

In a Claude Code session:

```
/plugin marketplace add Dinn/devils-advocate
/plugin install devils-advocate@devils-advocate
```

The hooks register automatically; you do not need to edit `~/.claude/settings.json` yourself.

To disable temporarily without uninstalling:

```
/plugin disable devils-advocate@devils-advocate
```

## How it works

```
[ User submits prompt ]
        │
        ▼
UserPromptSubmit hook ─────────────────────────────────┐
   1. Drain previous-turn response-critic queue        │
   2. Synchronous Haiku call (timeout-bounded)         │
   3. If severity ≥ medium and not duplicate,          │
      emit <system-reminder> with up to 3 questions    │
        │                                              │
        ▼                                              │
[ Claude's main response ]                             │
        │                                              │
        ▼                                              │
Stop hook                                              │
   1. Spawn background worker (nohup + disown)         │
   2. Worker extracts the last assistant message       │
   3. Heuristic picks Haiku or Opus                    │
   4. If severity ≥ medium, append to per-session      │
      queue file under $CLAUDE_PLUGIN_DATA/queue/      │
        │                                              │
        └──────────────────────────────────────────────┘
                 surfaces on the next UserPromptSubmit

[ User invokes /devils-advocate manually ]
        │
        ▼
Skill (Opus + extended thinking)
   ├─ Context Gate: must have read the target
   ├─ Independence Gate: dispatch devils-advocate-critic
   │  subagent if the target was authored by Claude in
   │  this same conversation
   └─ Binary PASS/FAIL across 20 (code) or 22 (plan)
      criteria, with a concrete Fix for every FAIL
```

## Configuration

`config.json` at the plugin root carries per-component defaults. The `/plugin install` step copies this into the read-only plugin directory; user overrides are not yet supported (planned for v0.2).

| Field | Default | Effect |
|---|---|---|
| `prompt_critic.enabled` | `true` | Master toggle for the synchronous critic |
| `prompt_critic.model` | `claude-haiku-4-5-20251001` | |
| `prompt_critic.timeout_seconds` | `5` | Synchronous budget; on timeout the hook silently skips |
| `prompt_critic.min_severity` | `medium` | `low` and `none` are never injected |
| `response_critic.enabled` | `true` | Master toggle for the async critic |
| `response_critic.escalate_triggers` | `["code_change", "architectural_decision", "migration", "security", "deployment"]` | Keywords that bump Haiku → Opus |
| `response_critic.queue_ttl_seconds` | `3600` | Queue entries older than this are dropped |
| `output_language` | unset | When set (e.g. `"Korean"`), forces all `questions`/`concerns` into that language. When unset, falls back to `$LC_ALL` / `$LANG`, then English |

The `output_language` priority chain is: `config.output_language` > `LC_ALL` > `LANG` > `English`.

## Privacy

This plugin sends data to the Anthropic API on **every** user turn and **every** Claude response, in the projects where it is enabled:

- `prompt-critic` sends your **prompt text** to Haiku (synchronous, every turn)
- `response-critic` sends Claude's **response text** to Haiku or Opus (asynchronous, every turn)
- `/devils-advocate` skill, when invoked, may send file contents and project structure to Opus

If you work on code that should not leave your environment, do not enable this plugin in those projects. There is currently no per-project disable option (planned for a future version); the recommended workaround is to disable the plugin globally and re-enable it only in non-sensitive workspaces.

## Development

```bash
git clone https://github.com/Dinn/devils-advocate.git
cd devils-advocate

# One-time: activate git hooks (pre-commit secret scan, pre-push preflight)
./scripts/install-hooks.sh

# Run preflight manually before tagging a release
./scripts/preflight.sh
```

See [CLAUDE.md](./CLAUDE.md) for plugin development conventions, path discipline, and the release procedure.

## Inspired by / differs from

- [brandonsimpson/devils-advocate](https://github.com/brandonsimpson/devils-advocate) — adopted the "Independence Gate" language and the binary PASS/FAIL critique pattern. This plugin differs by adding the two automatic hook-driven axes (prompt-critic and response-critic) on top of the manual deep-critique skill, and by enforcing a silence-first severity gate.
- [ljw1004's `<system-reminder>` injection pattern](https://gist.github.com/ljw1004/34b58090c16ee6d5e6f13fce07463a31) — used as the reference for safely injecting hook output into the main session.

## License

MIT — see [LICENSE](./LICENSE).
