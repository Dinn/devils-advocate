# devils-advocate

A complementary confirmation-bias guard for [Claude Code](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview). Three reviewers — two automatic hooks (best-effort, model-judgment-driven) and one manual skill (foreground deep critique) — push back on the user's unverified assumptions and the assistant's author bias.

## Components

| Component | Trigger | Mechanism | Model | Tone | Output |
|---|---|---|---|---|---|
| **prompt-critic** | `UserPromptSubmit` hook | Injects an instruction asking the main Claude to dispatch the `devils-advocate-critic` subagent when the prompt carries decision content | Subagent runs on Opus | Whatever the subagent decides | Subagent findings flow into the main response context (best-effort: dispatch is subject to the model's judgment) |
| **response-critic** | `Stop` hook | Background worker calls `claude -p` on the last assistant turn; severity-gated enqueue | Haiku → Opus auto-escalate | Declarative ("This skips Y; consider Z.") | Surfaces on the *next* `UserPromptSubmit` via the queue |
| **/devils-advocate** skill | Manual invocation | Foreground critique with Context Gate + Independence Gate | Opus + extended thinking | Binary PASS/FAIL with concrete fixes | Inline report; dispatches `devils-advocate-critic` subagent when the target is self-authored, to block author bias |

All three honor a strict **silence rule**: when uncertain, stay silent. The response-critic drops severity below `medium` and dedups by reasoning hash. The prompt-critic delegates silence to the main Claude (skip dispatch on trivial prompts) and the subagent (own silence rule) — dispatch is best-effort, not a hard gate.

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/agents-and-tools/claude-code/overview) with plugin support
- `bash` (4+)
- `python3`
- `jq`
- An authenticated Claude Code session (OAuth or `ANTHROPIC_API_KEY`) — used by the response-critic background worker to invoke `claude -p`. The prompt-critic does not call the API directly; it injects an instruction, and the main Claude (already authenticated) handles any subagent dispatch.

The development setup additionally requires `shellcheck` for `scripts/preflight.sh`. End users do not need it.

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
UserPromptSubmit hook
   1. Drain previous-turn response-critic queue (if any)
   2. Inject a system-reminder asking the main Claude to judge whether
      the prompt carries decision content. If yes, dispatch the
      `devils-advocate-critic` subagent (Agent tool) before responding.
   3. Exit immediately — no synchronous wait, no claude -p call
        │
        ▼
[ Main Claude reads the instruction ]
   ├─ Trivial prompt (file read, lookup, etc.): skip dispatch, respond normally
   └─ Decision content: dispatch devils-advocate-critic subagent
                        │
                        ▼
                  [ Subagent reviews the user's prompt; silence rule applies ]
                        │
                        ▼
                  [ Main Claude weaves findings into its response ]
        │
        ▼
[ Claude's main response ]
        │
        ▼
Stop hook                                              ┐
   1. Spawn background worker (nohup + disown)         │
   2. Worker extracts the last assistant message       │
   3. Heuristic picks Haiku or Opus                    │
   4. If severity ≥ medium, append to per-session      │
      queue file under $CLAUDE_PLUGIN_DATA/queue/      │
                                                       │
                  surfaces on the next UserPromptSubmit ┘

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
| `prompt_critic.enabled` | `true` | Master toggle for the prompt-critic instruction injection |
| `response_critic.enabled` | `true` | Master toggle for the async response review |
| `response_critic.model` | `claude-haiku-4-5-20251001` | Default model for the background worker |
| `response_critic.escalate_model` | `claude-opus-4-7` | Model used when an escalate trigger keyword matches |
| `response_critic.escalate_triggers` | `["code_change", "architectural_decision", "migration", "security", "deployment"]` | Keywords that bump Haiku → Opus |
| `response_critic.min_severity` | `medium` | `low` and `none` are never enqueued |
| `response_critic.timeout_seconds` | `30` | Background worker `claude -p` budget |
| `response_critic.queue_ttl_seconds` | `3600` | Queue entries older than this are dropped on consume |
| `skill.enabled` | `true` | Master toggle for the `/devils-advocate` skill |
| `output_language` | unset | See [Output language](#output-language) below |

## Output language

The response-critic emits user-facing strings (`concerns`) in a runtime-chosen language. Priority: `config.output_language` > `$LC_ALL` > `$LANG` > English.

Mapped: English, Korean, Japanese, Chinese, Spanish, French, German, Portuguese, Russian. Unknown locales fall back to English. To add a language, extend `locale_to_language` in `lib/common.sh`.

The `reasoning` field stays English regardless. The prompt-critic does not honor this setting — its output follows the main Claude's conversational language.

## Privacy

This plugin sends data to the Anthropic API on **every assistant turn** (response-critic, always) and on **prompts where the main Claude opts to dispatch the subagent** (prompt-critic, sometimes). The `/devils-advocate` skill sends file contents and project structure when manually invoked.

Do not enable this plugin in projects whose contents must not leave your environment. There is no per-project disable yet (planned); disable globally and re-enable only in non-sensitive workspaces.

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
