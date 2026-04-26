---
name: devils-advocate
description: Adversarial deep critique of the current plan, decision, or code change. Manually invoked when the user wants their judgment stress-tested before committing. Unlike the silent hooks (prompt-critic, response-critic), this runs on Opus + extended thinking. If the target was authored by Claude in this same conversation, dispatches the devils-advocate-critic subagent to block author bias.
---

# Devil's Advocate — Deep Critique Skill

This skill is invoked when the user explicitly asks to be challenged on a current decision.
It is heavier than the `UserPromptSubmit` / `Stop` hooks — Opus + extended thinking + subagent dispatch.

## Process

### Step 0: Context Gate

Before critiquing, verify all of the following. If any fails, output the block below and stop:

1. **Is the target clear?** — Has the user named a specific file, plan, or decision (or is it obvious from recent conversation)?
2. **Have you read the relevant files?** — Did you actually inspect the code or doc with Read/Grep?
3. **Do you understand the task precisely?** — Can you restate it?
4. **Is there something concrete to critique?** — Conversation alone, with no artifact, is not critiqueable.

If any check fails:

```
CONTEXT INSUFFICIENT
═══════════════════════════════════════
Cannot critique. Missing:
- [item]

Action required:
1. [step]
```

A critique produced from thin context is **worse than no critique** — it manufactures false confidence.

### Step 1: Independence Gate

If the target is **something you (Claude) wrote in this same conversation**, you MUST dispatch an independent subagent:

```
Agent({
  description: "Independent DA critique",
  subagent_type: "devils-advocate-critic",
  model: "opus",
  prompt: `Independent adversarial review of: <file path or description of target>

Read CLAUDE.md and AGENTS.md first to absorb project conventions.
Then read the target with Read; verify every claim against the actual code.

<criteria block per target type — CODE / PLAN / DECISION>

For each criterion: PASS with one-line evidence, or FAIL with file:line + Fix.
Return the result in this format:
(see Step 4 output format in SKILL.md)`
})
```

If the target was NOT authored by you in this conversation (an external PR, existing code, the user's own separate plan), inline critique is acceptable.

**Fallback**: if subagent dispatch fails, proceed inline but prefix the result with:

```
⚠️ Self-critique mode — author bias may be present
```

### Step 2: Discover project standards

- Read `CLAUDE.md`, `AGENTS.md`
- Glob and Read `docs/adr/*.md`, `docs/decisions/*.md`, `adr/*.md`, `**/ADR-*.md`
- Grep 3–5 occurrences of the dominant pattern for similar work in the target's domain (DB access, API calls, error handling, etc.)

### Step 3: Evaluate criteria

By target type:

**CODE** — 20 criteria across 8 dimensions:
- Correctness: tests-pass, logic-correct, edge-cases
- Security: no-secrets, input-validated, no-injection, auth-enforced
- Performance: no-n-plus-one, appropriate-datastructure
- Maintainability: naming-clear, no-dead-code, follows-dominant-pattern
- Error Handling: failures-caught, no-swallowed-errors, user-facing-messages
- Dependencies: no-unjustified-additions, versions-pinned
- Documentation: public-api-documented, non-obvious-why-commented
- Testing: coverage-changed-code, edge-cases-tested

**PLAN** — 22 criteria:
- Scope: problem-stated, success-defined, out-of-scope-listed
- Constraints: deadline-realistic, dependencies-identified, risks-named
- Decomposition: steps-ordered, each-step-verifiable, handoffs-clear
- Alternatives: other-approaches-considered, tradeoffs-explicit
- Verification: test-strategy, rollback-plan, observability
- Stakeholder: consumers-identified, communication-plan, sign-off-gate
- Resource: effort-estimated, team-capacity-checked
- Failure modes: known-failure-modes-listed, detection-strategy
- Rollout: staged-plan, cutover-criteria

**DECISION** — simplified:
- assumptions stated / alternatives compared / tradeoffs explicit / reversibility / verification metric

### Step 4: Output format

```
# Devil's Advocate Critique: <target>

## Target
[1–2 lines describing what is being critiqued]

## Verdict
[N PASS / M FAIL. Top concern: ...]

## Findings

### [Dimension]
- ✅ PASS criterion — evidence
- ❌ FAIL criterion — file:line
  - **Fix:** concrete proposal

## Top 3 Critical FAILs
1. ...

## Overall Recommendation
[adopt / revise / block] — one-line rationale
```

### Step 5: Enqueue (optional)

If at least one critical FAIL exists, append a single line to the response-critic queue so it surfaces again next turn:

```bash
SESSION=$(basename "$CLAUDE_SESSION_TRANSCRIPT_PATH" .jsonl)
echo '{"source":"deep-critique","severity":"high","concerns":["top FAIL summary"],"reasoning":"..."}' \
  | python3 "${CLAUDE_PLUGIN_ROOT}/lib/queue_append.py" --session "$SESSION"
```

## Rules

- **No FAIL without Fix** — if you cannot propose a concrete fix, downgrade to PASS
- **Binary** — no percentages, no "mostly", no wiggle room
- **No bikeshedding** — naming/formatting only when they violate a *documented* convention
- **Stay in scope** — critique only the target, do not bleed into adjacent code
- **No unverified claims** — no "probably", cite the actual file
