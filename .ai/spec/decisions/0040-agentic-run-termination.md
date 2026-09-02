# 0040: Unified Hard-Stop Contract for Agentic Runs

**Status:** Accepted [PLANNED: OLS-3298, OLS-4018]
**Applies to:** lightspeed-agentic-operator, lightspeed-agentic-console

## Context

The cluster-wide `AgenticOLSConfig.spec.suspended` kill switch marks non-terminal runs `EmergencyStopped`, but its cleanup contract is best-effort and depends on sandbox references recorded in run status. A deletion error, a status-write race, or an orphaned workload can therefore leave a sandbox able to contact an LLM or the cluster after the system reports suspension complete. Clearing the kill switch before that teardown completes would also admit new work alongside the still-active sandbox.

There is also no way to stop one run without deleting its AgenticRun CR and its audit history. Approval denial prevents a stage from starting but cannot stop a stage already in progress. The console needs a per-run control, and both stop paths need the same reliable sandbox and access teardown behavior.

The design must preserve the condition-derived phase model, immutable sandbox-owned Result CRs, Kubernetes RBAC authorization, and durable audit evidence.

## Decision

### One-way cancellation intent on AgenticRun

Add an optional `AgenticRun.spec.cancelled` boolean with effective default `false`. CRD validation permits only absent/`false` to true. Any caller with effective `patch agenticruns` permission may set it; no cancellation-specific role or group check is added.

Cancellation applies to every non-terminal phase, although the console exposes `Stop run` only while a sandbox is active. The reconciliation guard runs before approval, revision, terminal routing, and normal phase dispatch, so a persisted request prevents subsequent stages.

### Failed outcome with a specific cause

Per-run cancellation uses the existing `Failed` phase. The operator sets the phase-relevant workflow condition to `False`, reason `CancelledByUser`, and message `Run stopped by user`. The console keeps the Failed badge and displays `Stopped by user` as the cause.

There is no `Cancelled` phase or synthetic Result CR. Existing Result CRs remain immutable; late results cannot advance a terminal run. Cancellation cannot report which actions completed, so execution-time confirmation warns about possible partial cluster changes.

### Global suspension has precedence

For a non-terminal run where global suspension and per-run cancellation are both pending, global suspension wins and produces `EmergencyStopped`. If the run was already terminal before a later stop signal was processed, its terminal history is not rewritten. Global sweeping still removes active managed sandboxes associated with terminal runs.

### Safe global resumption

`AgenticOLSConfig.spec.suspended` remains `true` while the `Suspended` condition is `Draining`. Admission rejects an attempt to clear the field until the operator verifies that teardown is complete and records `AdminActivated`. Therefore the existing create-admission policy and reconciliation guard remain authoritative while any stopped sandbox workload or access can still exist. The suspension-activated Event is emitted when the field first becomes true, rather than being delayed until draining finishes.

### Immediate status with mandatory asynchronous teardown

A run becomes `Failed / CancelledByUser` or `EmergencyStopped` without waiting for cleanup. Terminal state does not end cleanup work.

Both paths use one idempotent hard-stop contract:

1. revoke sandbox ServiceAccount reader access and execution RBAC;
2. delete bare Pods with zero grace;
3. delete SandboxClaims and hard-delete active backing Pods when claim cleanup is asynchronous;
4. discover resources from both run status and managed labels/owner identity;
5. retry after terminal status until workloads and access are confirmed absent.

Per-run release never deletes a derived SandboxTemplate because compatible live SandboxClaims can reuse one. Template garbage collection is a separate operation that first verifies no live claim or workload references the template.

Sandbox status references remain while teardown is incomplete and are cleared only after workload and access removal. This gives the console a progress signal without adding another condition or phase.

Global suspension directly lists active managed sandbox resources, including leaked or orphaned workloads and workloads attached to terminal runs. `AgenticOLSConfig` remains `Suspended=True / Draining` until no active managed sandbox or associated access remains; it reports `AdminActivated` only after confirmed completion.

## Alternatives Considered

- **Dedicated AgenticRunCancellation CRD** — rejected because current requirements do not need stop-only RBAC delegation, requester fields, or an independent lifecycle. Kubernetes audit records the caller.
- **Cancellation through AgenticRunApproval** — rejected because cancellation is not an approval stage and coupling it to approval permissions would make authorization checks inaccurate.
- **New Cancelled or Cancelling phase** — rejected because product behavior requires an immediate Failed outcome with a distinguishable cause. Cleanup progress is represented by the retained sandbox reference.
- **Synthetic Result CR with partial progress** — rejected because the operator cannot know which sandbox actions completed and Result CRs are sandbox-owned.
- **Cooperative shutdown before deletion** — rejected because an emergency control cannot trust the agent to respond or wait through a termination grace period.
- **Network isolation while retaining Pods** — rejected because it is more complex, may not terminate existing connections promptly, and keeps the untrusted process alive.
- **Stop only status-referenced non-terminal sandboxes** — rejected because status races, terminal cleanup failures, and orphaned workloads would preserve the safety gap in OLS-4018.
- **Use approval permission as the console stop gate** — rejected because `patch agenticrunapprovals` does not authorize the actual `patch agenticruns` operation.

## Consequences

- Per-run cancellation adds a mutable v1alpha1 field and CEL transition rule. Revision detection must not interpret that generation change as revision feedback.
- Users can distinguish ordinary failure from user cancellation through the normative `CancelledByUser` reason while retaining one Failed phase.
- Any user who can patch AgenticRuns can also set other mutable AgenticRun fields; field-only stop delegation remains unsupported.
- Global suspension completion now reflects actual sandbox and RBAC teardown rather than only terminal run conditions; it cannot be cleared while the system is Draining.
- The operator must continue reconciling cleanup after terminal status and must discover resources independently of status references.
- Per-run cleanup cannot remove a reusable derived SandboxTemplate that is referenced by another live claim or workload.
- Hard deletion can lose in-process logs and unpublished results. Durable Result CRs, Kubernetes audit, and product audit storage are the supported forensic sources.
- The agentic console needs a separate access review for `patch agenticruns`, active-phase Stop controls, partial-execution warning, failure-cause rendering, and shutdown-progress rendering.
- Operator tests must cover condition mapping, precedence, phase races, zero-grace deletion, both sandbox modes, orphan discovery, terminal cleanup retries, late resources/results, suspension Draining completion, rejection of premature deactivation, and preservation of reusable templates with live references.
