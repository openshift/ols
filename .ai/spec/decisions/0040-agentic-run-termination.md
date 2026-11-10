# 0040: Unified Hard-Stop Contract for Agentic Runs

**Status:** Accepted [PLANNED: OLS-3298, OLS-4018]; outcome timing revised by OLS-4131; bounded shared-path and spoke-confirmation contract revised by OLS-4132
**Applies to:** lightspeed-agentic-operator, lightspeed-agentic-console

## Context

The cluster-wide `AgenticOLSConfig.spec.suspended` kill switch marks non-terminal runs `EmergencyStopped`, but its cleanup contract is best-effort and depends on sandbox references recorded in run status. A deletion error, a status-write race, or an orphaned workload can therefore leave a sandbox able to contact an LLM or the cluster after the system reports suspension complete. Clearing the kill switch before that teardown completes would also admit new work alongside the still-active sandbox.

There is also no way to stop one run without deleting its AgenticRun CR and its audit history. Approval denial prevents a stage from starting but cannot stop a stage already in progress. The console needs a per-run control, and both stop paths need the same reliable sandbox and access teardown behavior.

The design must preserve the condition-derived phase model, immutable sandbox-owned Result CRs, Kubernetes RBAC authorization, and durable audit evidence.

The original form of this decision wrote the terminal outcome immediately and performed cleanup asynchronously. That let a run report `Failed` or `EmergencyStopped` while its sandbox was still active, and left no signal between the stop request and the final outcome. OLS-4131 revises the timing: blocking stays immediate, the outcome is recorded only after teardown is confirmed, and a run-level `Stopping` condition exposes the interim.

## Decision

### One-way cancellation intent on AgenticRun

Add an optional `AgenticRun.spec.cancelled` boolean with effective default `false`. CRD validation permits only absent/`false` to true. Any caller with effective `patch agenticruns` permission may set it; no cancellation-specific role or group check is added.

Cancellation applies to every non-terminal phase, although the console exposes `Stop run` only while a sandbox is active. The reconciliation guard runs before approval, revision, terminal routing, and normal phase dispatch, so a persisted request prevents subsequent stages.

### Failed outcome with a specific cause

Per-run cancellation uses the existing `Failed` phase. If hub cleanup and, for a spoke run, spoke cleanup are confirmed within ten seconds, the operator sets the phase-relevant workflow condition to `False`, reason `CancelledByUser`, and message `Run stopped by user`, and completes `Stopping=False/TeardownComplete` while clearing sandbox references in the same status update. If cleanup remains unconfirmed at the deadline, the operator records `Failed/CancellationFailed` with `Stopping=False/TeardownFailed` and retains references. The phase-relevant `CancellationFailed` condition and `Failed` phase are final; background cleanup continues. A later confirmed pass MUST set `Stopping=False/TeardownComplete` and clear references in one update without changing that condition or phase. The console displays `Stopped by user` for confirmed cancellation and `Stop failed` for `CancellationFailed`.

### Global suspension has precedence

For a non-terminal run where global suspension and per-run cancellation are both pending, global suspension wins, including taking over `Stopping/CancelledByUser` when no outcome is recorded. An accepted `Stopping/SystemSuspended` is never converted to cancellation, even if suspension is resumed or the config is deleted. A run already terminal before a stop signal is processed keeps its historical outcome; global cleanup may still remove its active managed sandbox.

### Safe global resumption

`AgenticOLSConfig.spec.suspended` remains `true` while its `Suspended` condition is `Stopping`. The run controller alone performs spoke I/O; the config controller resolves a run only when sandbox references are cleared AND either no `Stopping` condition is present or the condition is `Stopping=False/TeardownComplete`. `Stopping=True` or `Stopping=False/TeardownFailed` remains unresolved even with cleared references; resolution does not use `RemoteExecutionEvidence`. An unresolved stop may produce `AdminActivatedWithErrors`, but resumption or config deletion is allowed only when the current-generation `Suspended` outcome is `AdminActivated` or `AdminActivatedWithErrors` AND current-generation `SafeToResume=True`. Later cleanup may resolve `SafeToResume` without changing the activation's `AdminActivatedWithErrors` outcome.

### Bounded shared stop path [PLANNED: OLS-4132]

Both stop sources use one run-controller stop path parameterized by `suspension` or `cancellation`. Its source-specific acceptance, ten-second deadline, hub-and-spoke confirmation, success/failure outcomes, cleanup retries, and config-controller resolution are defined in the **Revision: OLS-4132 — Bounded shared stop path and spoke confirmation** section below. No accepted run may remain in `Stopping` beyond its applicable deadline.

## Alternatives Considered

- **Dedicated AgenticRunCancellation CRD** — rejected because current requirements do not need stop-only RBAC delegation, requester fields, or an independent lifecycle. Kubernetes audit records the caller.
- **Cancellation through AgenticRunApproval** — rejected because cancellation is not an approval stage and coupling it to approval permissions would make authorization checks inaccurate.
- **New Cancelled or Cancelling phase** — rejected because a stop must not change the condition-derived phase model. The distinguishable cause is the `CancelledByUser` reason, and interim progress is exposed through the run-level `Stopping` condition rather than a `Cancelling` phase.
- **Synthetic Result CR with partial progress** — rejected because the operator cannot know which sandbox actions completed and Result CRs are sandbox-owned.
- **Cooperative shutdown before deletion** — rejected because an emergency control cannot trust the agent to respond or wait through a termination grace period.
- **Network isolation while retaining Pods** — rejected because it is more complex, may not terminate existing connections promptly, and keeps the untrusted process alive.
- **Stop only status-referenced non-terminal sandboxes** — rejected because status races, terminal cleanup failures, and orphaned workloads would preserve the safety gap in OLS-4018.
- **Use approval permission as the console stop gate** — rejected because `patch agenticrunapprovals` does not authorize the actual `patch agenticruns` operation.

## Consequences

- Per-run cancellation adds a mutable v1alpha1 field and CEL transition rule. Revision detection must not interpret that generation change as revision feedback.
- Users can distinguish ordinary failure from user cancellation through the normative `CancelledByUser` reason while retaining one Failed phase.
- Any user who can patch AgenticRuns can also set other mutable AgenticRun fields; field-only stop delegation remains unsupported.
- Global suspension records `AdminActivated` only after all affected runs are resolved (sandbox references cleared AND either no `Stopping` condition or `Stopping=False/TeardownComplete`; `Stopping=True` or `Stopping=False/TeardownFailed` is unresolved even if references are clear). Unconfirmed deadline failures may produce `AdminActivatedWithErrors`, but resumption and config deletion remain blocked until current-generation `SafeToResume=True`; a sandbox-less Pending run still requires its stop outcome before suspension can complete.
- The operator must expose the run `Stopping` condition, must continue reconciling cleanup from stop acceptance through the recorded outcome, and must discover resources independently of status references.
- Per-run cleanup cannot remove a reusable derived SandboxTemplate that is referenced by another live claim or workload.
- Hard deletion can lose in-process logs and unpublished results. Durable Result CRs, Kubernetes audit, and product audit storage are the supported forensic sources.
- The agentic console needs a separate access review for `patch agenticruns`, active-phase Stop controls, partial-execution warning, prominent `Stopping` presentation while the condition is true, failure-cause rendering, and shutdown-progress rendering.
- Operator tests must cover condition mapping, precedence, phase races, zero-grace deletion, both sandbox modes, orphan discovery, cleanup retries while stopping and after the outcome, stale-completion overwrite protection, late resources/results, suspension Stopping completion including the sandbox-less Pending-run race, rejection of premature deactivation (including before the `Suspended` condition is first recorded), and preservation of reusable templates with live references.

## Revision: OLS-4132 — Bounded shared stop path and spoke confirmation

This revision supersedes the earlier confirmed-teardown-only outcome wording in this ADR and the hub-local/spoke-unverified baseline documented in operator ADR 0001. The operator MUST use one stop path parameterized by `suspension` or `cancellation`, so precedence, deadlines, cleanup confirmation, and finality cannot drift between stop sources.

Cancellation acceptance records `Stopping=True/CancelledByUser`; suspension acceptance records `Stopping=True/SystemSuspended` with the persisted suspension activation time. Cancellation's ten-second deadline begins at the accepted `Stopping` condition's `lastTransitionTime`; suspension retains its ten-second activation-based deadline. Confirmed cancellation records the phase-relevant `False/CancelledByUser` condition with message `Run stopped by user`, `Stopping=False/TeardownComplete`, and cleared sandbox references in one update. Unconfirmed cancellation at its deadline records the phase-relevant `False/CancellationFailed` condition and `Stopping=False/TeardownFailed`, retains references, and continues cleanup. Confirmed suspension records `EmergencyStopped=True/SystemSuspended`; an unconfirmed suspension at its deadline records the phase-relevant `False/EmergencyStopFailed` condition and `Stopping=False/TeardownFailed`, retains references, and continues cleanup. After a later confirmed cleanup pass, the operator MUST set `Stopping=False/TeardownComplete` and clear the sandbox references in the same status update; the phase-relevant `CancellationFailed` or `EmergencyStopFailed` condition and `Failed` phase MUST remain unchanged.

A stop is confirmed only when the hub `CleanupSuspension` report is confirmed and, for a spoke run, the run controller has deleted and confirmed absent through authoritative `Get` every per-step spoke ServiceAccount, per-run reader ClusterRoleBinding, execution Role/RoleBinding in every namespace from the run's `rbac-namespaces` annotation, and execution ClusterRole/ClusterRoleBinding. The operator maintains that annotation as a union across executions and never drops a namespace. Spoke discovery uses deterministic names only, not label inventory or list calls. `Get` `NotFound` means removed; any other error, including missing kubeconfig, unreachable spoke, or forbidden access, is unconfirmed. The standing spoke credential has `get`/`delete` but not `list`; no hub credential change is required. The run controller alone performs spoke I/O. The config controller resolves a run only when sandbox references are cleared AND either no `Stopping` condition is present or it is `Stopping=False/TeardownComplete`; `Stopping=True` or `Stopping=False/TeardownFailed` remains unresolved even if references are clear, and `RemoteExecutionEvidence` MUST NOT be used as the resolution signal.

Global suspension wins over pending cancellation, including taking over `Stopping/CancelledByUser` when no outcome is recorded. An accepted `Stopping/SystemSuspended` is never converted to cancellation. Historical terminal outcomes remain unchanged, and every recorded stop outcome is final against late workflow writes, results, approvals, revisions, and cleanup retries.
