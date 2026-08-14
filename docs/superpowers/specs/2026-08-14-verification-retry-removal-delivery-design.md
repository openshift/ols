# OLS-3816 — Verification retry removal: delivery design

**Epic:** [OLS-3816](https://redhat.atlassian.net/browse/OLS-3816) — Remove verification retry mechanism, escalate on failure
**Date:** 2026-08-14
**Status:** Design approved, pending implementation

## Context

The behavioral specification for this change is already merged into the specs:

- `ols/.ai/spec/what/agentic-runs.md`, `ols/.ai/spec/what/audit-logging.md` (via [openshift/ols#56](https://github.com/openshift/ols/pull/56))
- `lightspeed-agentic-operator/.ai/spec/what/{run-lifecycle,approval,crd-api,audit-logging,sandbox-execution}.md` (via [openshift/lightspeed-agentic-operator#421](https://github.com/openshift/lightspeed-agentic-operator/pull/421))

This document is therefore a **delivery plan**, not a fresh specification: how the epic's stories map to pull requests, the observable behavior each changes, cross-repo impact, and how the whole change is verified together on a live cluster.

### The change in one sentence

When verification fails, the operator escalates directly instead of re-executing the remediation; convergence-dependent checks (alerts clearing, pods becoming ready, metrics settling) are handled *inside* the verification agent's single sandbox call via prompt-guided wait-and-retry (already delivered by OLS-3818), so a slow-but-correct remediation is no longer falsely failed.

### Why

Re-executing remediation after a verification failure repeats potentially non-idempotent actions against a cluster in an unknown intermediate state. The retry mechanism also accumulated a cluster of defects it is cheaper to remove than to keep fixing (OLS-3793, OLS-3731, OLS-3552, OLS-3550, OLS-3554, OLS-3781). Removing it makes the lifecycle simpler and safer: execution runs exactly once per analysis iteration; a failed verification is a signal for a human, not a trigger for a blind retry.

## Story → PR map

The epic is four units of work across two repos (a fifth story, OLS-3818, is already closed and merged).

| Story | Repo | PR | Notes |
|---|---|---|---|
| **OLS-3817** — Remove retry from controller + CRDs | `lightspeed-agentic-operator` | PR A | The substantive change (3 SP) |
| **OLS-3819** — Remove retry audit events + span attributes | `lightspeed-agentic-operator` | PR B | Rebases on PR A |
| **OLS-3820** — Remove `maxAttempts` from console approval flow | `lightspeed-agentic-console` | PR C, commit 1 | As specced |
| **OLS-38xx (new)** — Sync console phase derivation | `lightspeed-agentic-console` | PR C, commit 2 | To be created in Jira; see below |
| OLS-3818 — Convergence-aware verification prompt | `lightspeed-agentic-operator` | — | ✅ Already merged/closed |

**Decisions baked in:**

- PR A and PR B are **separate PRs** (one per Jira story, per repo convention), even though both touch `handlers.go`/`audit.go`. PR B rebases on PR A.
- PR C is **one PR with two commits** — one per story — since both live in the same console file neighborhood and share a reviewer.
- The clean **breaking CRD change** is acceptable: this ships to a controlled test cluster, not a live upgrade path, so no in-flight `AgenticRun` retry state needs migration.

### The new console-sync story

The console's `src/models/agenticrun.ts` mirrors the operator's phase-derivation logic, including branches for the `RetryingExecution`/`RetriesExhausted` condition reasons and the `retryCount`/`retryIndex` fields. The operator's own `agenticrun_types.go` carries a comment requiring these two files stay in sync. Once OLS-3817 stops emitting those reasons and removes those fields, the console branches become dead code.

Cleaning this up is **out of OLS-3820's charter** (which is narrowly the `maxAttempts` approval input). Rather than smuggle it in, it is tracked as a **new story under OLS-3816** and delivered as the second commit of PR C. This keeps every story honest to its own acceptance criteria while the epic remains the complete unit of work.

## Observable behavior changes

What an operator or user sees differently after the epic ships. This is the acceptance surface.

### Run lifecycle (OLS-3817)

- A run whose **verification fails** transitions `Verifying → Escalating → Escalated` (or `Failed` when no escalation is configured). It **never** re-enters `Executing`. Previously it could bounce `Verifying → Executing → Verifying …` up to `maxAttempts`.
- Escalation is reached on the **first** verification failure. The escalation summary includes both the execution result and the failed verification result so a human can assess what happened.
- A slow-but-correct remediation (alert takes tens of seconds to clear, pod still rolling out) reports **Passed** via the verification agent's internal wait (OLS-3818), rather than a false failure that formerly triggered a retry.
- Trade-off, by design: a run that would previously have "succeeded on retry 2" now escalates on the first verification failure. This is intended — no blind re-execution of possibly-non-idempotent actions.

### CRD surface (OLS-3817)

The following fields are removed from the API and generated CRD manifests:

- `ApprovalPolicy.spec.maxAttempts`
- `AgenticRunApproval.spec.stages[].execution.maxAttempts` (and its immutability CEL rule)
- `AgenticRun.status.steps.execution.retryCount`
- `ExecutionResult.spec.retryIndex` and `VerificationResult.spec.retryIndex` (including the `Retry` printer column on both)

Applying a manifest that still sets any of these is rejected by the API server. That rejection is itself an acceptance check (see verification plan).

### Telemetry (OLS-3819)

- No `verification.retry` audit event is emitted.
- No `retry_index` / `retry_count` attributes appear on any operator span.
- No per-retry trace forests: one execution trace and one verification trace per run.

### Console (OLS-3820 + sync story)

- The "Max retry attempts" stepper is removed from the approval-policy configuration UI (field, PATCH payload, label copy, locale entry, dedicated CSS).
- Approval PATCH requests no longer carry `maxAttempts`.
- The phase display never derives a "retrying execution" state from the now-removed condition reasons.

## Cross-repo impact

### `lightspeed-agentic-alerts-adapter` — no changes required

The adapter creates `AgenticRun` CRs and reads their phases for deduplication and terminal detection. It does **not** manage `ApprovalPolicy` or `AgenticRunApproval`, and it references none of the removed fields (`maxAttempts`, `retryCount`, `retryIndex`). Its terminal-phase handling already treats `Escalated` and `Failed` as terminal and `Escalating` as in-flight, so the new escalate-on-first-failure behavior flows through its dedup logic unchanged.

The adapter depends on the operator's `api` Go module by pinned version. When it next bumps that dependency it will compile cleanly (no removed field is referenced). This is a routine, behavior-neutral dependency bump — **not** a story-blocking change and not part of this epic's critical path.

Because escalate-on-verification-failure is a property of the operator reconciling *any* `AgenticRun`, an alert-triggered run is not a special case for verification. A hand-created `AgenticRun` that fails verification and escalates is sufficient e2e coverage; routing through the adapter would test the adapter, not this change.

## Verification plan

Two layers. The manual cluster layer is the primary sign-off.

### Layer 1 — operator e2e suite (`make test-e2e`)

Runs against a live cluster and running operator using the mock agent. The key case to add/confirm, replacing the old retry expectations:

- **Verification-failure → escalation**: create an `AgenticRun` with execution + verification, drive the mock agent to return a failing verification, assert the run reaches `Escalating` → `Escalated` (escalation approved) and **never re-enters `Executing`**. Assert exactly **one** `ExecutionResult` CR exists — direct proof of no re-execution.

### Layer 2 — manual cluster confirmation (all deployables together)

All three deployables (operator from PR A+B, console from PR C) on the cluster:

1. **Behavior:** create a run that fails verification → observe `Escalated`, a single execution attempt, and an escalation summary containing both the execution and failed-verification results.
2. **CRD surface:** confirm `oc apply` of a manifest setting `maxAttempts` / `retryCount` / `retryIndex` is **rejected** by the API server.
3. **Telemetry:** confirm no `verification.retry` audit event and no `retry_index` span attribute appear in the collector for that run.
4. **Console:** confirm the "Max retry attempts" stepper is gone from the approval-policy config, approval still works, and the run's phase renders `Escalating` / `Escalated` correctly with no broken "retrying" state.
5. **Convergence sanity (ties in OLS-3818):** a correct-but-slow remediation (e.g. an alert that takes ~30s to clear) reports **Passed** via the verification agent's internal wait, not a false failure.

Operator behavior (checks 1–3) can be validated as soon as PR A+B are deployed, independent of the console. Check 4 requires the console (PR C) deployed simultaneously.

### Deployment sequencing for the cluster test

1. PR A → PR B (rebased on A) → merge, build and deploy the operator image.
2. PR C → build and deploy the console image.
3. All three present on the cluster for check 4; checks 1–3, 5 need only the operator.

## Out of scope

- Migration of in-flight `AgenticRun` retry state (clean test cluster; breaking CRD change accepted).
- Any change to the verification prompt itself (delivered separately by OLS-3818).
- Namespace-scoped approval policy or re-approval semantics (tracked under other planned changes).
