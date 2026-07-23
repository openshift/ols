# OLS-0000: Agentic Sandbox Spec Grooming & Spec-First Reevaluation

## Problem Statement

`lightspeed-agentic-sandbox` specs have drifted from the code and from each other. Session evidence shows `## Module Map` tables in `how/` are maintained as ceremony but almost never used for navigation (agents use Glob/Grep). Meanwhile, real behavioral drift exists: bare MUST rules with no implementation, CodeRabbit-driven contract tightenings that never reached code or Jira, closed epics leaving orphan PLANNED sub-behaviors, and nav docs that omit modules shipped weeks ago (`config`, `audit`, `metrics`, `tracing`, partially `mcp`/`health`).

This grooming pass makes sandbox specs truthful for **current** behavior and correctly marked for **intentional** futures, without implementing missing code.

## Goals

1. Spec-only cleanup of `lightspeed-agentic-sandbox` (`.ai/spec/`, `AGENTS.md`, `ARCHITECTURE.md`).
2. Every MUST is either true in code today, or tagged `[PLANNED: OLS-XXXX]` with a real ticket.
3. Orphan promises (spec ahead of code, no ticket) are investigated and resolved by matching code — not left as silent MUST.
4. Kill Module Map duplication; one path inventory owner (`AGENTS.md`).
5. PR documents what was wrong, why, and how spec-first should work going forward.

## Non-Goals

- No changes under `src/`, `tests/`, Containerfile, or dependency locks.
- No implementing templog OTLP logs, MCP Secret path fix, R3 readiness, etc.
- No filing Jira tickets in the same change (orphans are listed in the PR for follow-up).
- No grooming of other repos in this pass.

## Decision Rules (Approach C)

| Situation | Action |
|---|---|
| Code ahead of spec | Update spec to match code |
| Spec ahead + tracked ticket | Keep rule; require `[PLANNED: OLS-XXXX]` |
| Spec ahead + **no** ticket | **Orphan** — rewrite to match code; call out in PR why the promise existed; recommend filing if product still wants the stricter contract |
| Specs contradict each other | Prefer shipped code; else newest intentional tracked contract |
| Path inventories | Single owner: `AGENTS.md` tree. Remove `## Module Map` from `how/` |

## Ahead-of-Code Matrix

| Spec claim | Ticket | Verdict | Spec action |
|---|---|---|---|
| Templog OTLP log emission (audit rules 22–25) | **OLS-3515** (Backlog), epic OLS-3505; related OLS-3328 / OLS-3696 | Intentional promise | Keep; mark `[PLANNED: OLS-3515]`; fix cross-ref to parent `templog.md` |
| MCP readiness R3 | **None** (OLS-3046 / OLS-3060 closed with R1/R2) | Orphan (stale “when MCP support lands”) | Remove MUST / demote to untracked note until a story exists |
| MCP Secret deterministic path + reject empty `secretName` | **None** (OLS-3185/3443/3444 Closed; CodeRabbit `1508589` tightened spec only) | Orphan | Match code: first file in `/var/secrets/mcp/<secretName>/`; missing `secretName` → warn/skip |
| `agenticrun.uid` hyphens stripped on spans | **None** | Orphan / overspec | Match code: raw header uid |
| Audit disabled ⇒ no telemetry | **None**; tests lock span creation | Code intentional | Match code; document what is actually gated |
| Ripgrep / hermetic binary lockfile | **None** | Stale packaging | Match Containerfile / empty `artifacts.lock.yaml` |

### Orphan root causes (for PR narrative)

1. **Review-on-spec-only** — CodeRabbit changed MCP Secret contract without code or follow-up ticket (`1508589`).
2. **Spec-ahead of stories** — templog MUST landed (OLS-3328) before sandbox story OLS-3515; markers never added.
3. **Leftover PLANNED after feature landed** — MCP R3 still says “when MCP support lands” after MCP shipped.
4. **Closed epic, open sub-behavior** — health epic closed without an R3 story.
5. **Multi-surface inventories** — `how/` ×2 + AGENTS + ARCHITECTURE with no single owner → lag on every feature.

## File Changes

### Navigation / structure

| File | Change |
|---|---|
| `how/project-structure.md` | Remove Module Map. Keep entry points (update for `config.resolve_sdk`, metrics route, tracer lifespan), naming, dependency extras (`langchain-anthropic`, `langchain-mcp-adapters`). Point to `AGENTS.md` for package tree. |
| `how/provider-architecture.md` | Remove Module Map. Keep Data Flow / Abstractions / Integration Points / Implementation Notes. Refresh for MCP + audit/metrics/tracing. Drop `ProviderName`; factory creates by SDK name from config. |
| `.ai/spec/README.md` | Stop describing how/ as “module map”. Align quick-start / cross-ref (audit, MCP). |
| `AGENTS.md` | Own the package tree (`config`, `health`, `mcp`, `audit`, `metrics`, `tracing`). Add `audit-logging.md` to read table. Env: `LIGHTSPEED_AUDIT_ENABLED`, `LIGHTSPEED_MCP_SERVERS`, `CLAUDE_CODE_USE_BEDROCK`. Soften overstated `tools.py` claim. |
| `ARCHITECTURE.md` | `LIGHTSPEED_AGENT_PROVIDER` → `LIGHTSPEED_PROVIDER`. Brief inventory update for config + observability. |

### Behavioral specs (`what/`)

| File | Change |
|---|---|
| `configuration.md` | MCP Secret → match code; Vertex Google project/location env vars; ripgrep/lockfile → match image reality. |
| `audit-logging.md` | Rules 22–25 → `[PLANNED: OLS-3515]`; uid raw; audit-disabled truth; thinking aligned with provider-contract; Prometheus underscore metric names; fix templog cross-ref; clear stale MCP-not-landed wording where MCP exists. |
| `provider-contract.md` | MCP header shape; reasoning unknown-key behavior per provider; OpenAI skills path accuracy. |
| `health-probes.md` | R3 orphan resolution (no bare MUST). |
| `e2e-testing.md` | MCP is implemented; add `mcp.feature`, `reasoning_config.feature` to verification map. |
| `system-overview.md` | Component inventory includes config/MCP/observability; canonical `LIGHTSPEED_MODEL`. |

## Spec-First Reevaluation (PR must state)

Spec-first (write the contract so other AI sessions know upcoming work) remains valuable **only if**:

1. Unimplemented MUST always carries `[PLANNED: OLS-XXXX]` with a real ticket — or the rule is not written yet.
2. Spec-only review feedback that tightens contracts must either update code in the same change or open a ticket and mark `[PLANNED]` — never leave a new bare MUST.
3. `how/` holds data flow, abstractions, integration points, gotchas — **not** path tables. `AGENTS.md` owns the tree.
4. Closing an epic requires either implementing or filing stories for every remaining PLANNED sub-behavior (or removing them).

Module Maps failed the cost/benefit test: ~high maintenance, near-zero navigation use in sessions, and they go stale first.

## Success Criteria

- No bare MUST in sandbox specs that current code violates (except explicitly `[PLANNED: ticket]`).
- No `## Module Map` sections in sandbox `how/`.
- `AGENTS.md` tree lists all first-class modules present under `src/lightspeed_agentic/`.
- `ARCHITECTURE.md` uses `LIGHTSPEED_PROVIDER`.
- PR body explains drift mechanisms, orphan findings, and the reevaluated spec-first rules.
- Zero `src/` / test diffs.

## Follow-ups (out of this PR)

- File bugs/stories if product still wants: MCP deterministic Secret path + reject missing `secretName`; MCP readiness R3; hyphen-stripped span uid (if still desired).
- Implement OLS-3515 (templog OTLP logs) in a later session reading the marked spec.
