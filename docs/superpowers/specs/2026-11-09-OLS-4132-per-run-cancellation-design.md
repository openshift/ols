# Per-Run Cancellation (Run Kill Switch) — Design

Date: 2026-11-09
Jira: OLS-3298 (epic), OLS-4132 (operator), OLS-4134 (console)
Repos: `openshift/ols` (parent spec), `lightspeed-agentic-operator`, `lightspeed-agentic-console`
Status: Approved (2026-11-10)

## Intent

A user must be able to stop one `AgenticRun` from the console and trust the result.
The console side exists as `lightspeed-agentic-console#375`: it patches `spec.cancelled=true` and renders the operator's conditions.
This design defines the operator backend that honors that request, built on the current operator `main`.

The run must never hang in an unbounded "stopping" state.
The user must see either a confirmed stop (`Stopped by user`) or an explicit failed stop (`Stop failed`).

## Background and current state

- `lightspeed-agentic-operator#573` implemented cancellation with its own teardown subsystem (`sandbox_stop.go`).
  It is 22 commits behind `main` and conflicts with it. It is **ignored and will be closed** when the new operator PR opens.
- The unpushed local branch `OLS-4132-cancellation-rebuild` is reference material only, not a starting point.
- Operator `main` contains the OLS-4133 global kill-switch work (operator ADR `decisions/0001-global-kill-switch-confirmation.md`):
  - `SandboxManager.CleanupSuspension(ctx, runUID, nil)`: one deletion-and-authoritative-confirmation pass scoped to one run. It covers hub Pods (zero grace), SandboxClaims, Sandboxes, run-owned warm pools, ServiceAccounts, Roles/RoleBindings, ClusterRoles/ClusterRoleBindings, and `sandbox-kubeconfig` Secrets.
  - `handleSuspensionAt` with `persistRunStop`, `writeSuspensionOutcome`, `clearRunSandboxInfo`: optimistic-lock status writes, the `Stopping` condition, a fixed 10-second window (`SuspensionStopWindow`), and a terminal failure outcome (`Stopping=False/TeardownFailed` plus `Failed/EmergencyStopFailed`) when cleanup stays unconfirmed.
  - `readRunnableRun` blocks workflow progression once a stop is accepted. It recognizes only the suspension stop today.
  - Spoke-side access is never confirmed: `RemoteExecutionEvidence` marks any spoke run as unverified. Suspension reports it as `AdminActivatedWithErrors`.
- Operator ADR 0001 rejected extracting a shared stop path as premature and noted that "later cancellation may require extracting common logic". This design performs that extraction.
- The parent spec `.ai/spec/what/agentic-run-termination.md` and parent ADR `decisions/0040-agentic-run-termination.md` still describe an unbounded `Stopping` state (rule 7) and do not reflect the bounded outcome that OLS-4133 shipped for suspension.

### Where spoke runs live

Sandbox Pods always run on the hub. For a run with `spec.targetCluster` set, the operator creates:

| Cluster | Object | Purpose |
|---|---|---|
| Hub | Sandbox Pod (default SA) | Runs the agent; writes Result CRs to the hub |
| Hub | `sandbox-kubeconfig` Secret per step | Holds a 24h bound token for the spoke SA |
| Spoke | ServiceAccount per step | Agent identity on the spoke |
| Spoke | Per-run reader ClusterRoleBindings (`perRunCRBName`) | Read access |
| Spoke | Execution Role/RoleBinding per namespace, ClusterRole/ClusterRoleBinding | Approved write access (execution step) |

Deleting the spoke ServiceAccount invalidates every bound token issued for it, including any copy the agent took.

## Goals

1. `spec.cancelled=true` stops any non-terminal run and blocks all later progression immediately.
2. Every accepted stop reaches a terminal outcome within a fixed deadline: confirmed (`CancelledByUser`) or failed (`CancellationFailed`).
3. A stop is confirmed only when workload and access are verified removed on the hub, and for spoke runs, also on the spoke.
4. Global suspension and cancellation share one stop path, and suspension gains the same spoke confirmation.
5. The console shows `Stop failed` for a cancellation whose teardown was not confirmed.
6. Parent and child specs describe the shipped behavior.

## Non-goals

- New run phases (`Cancelled`, `Cancelling`). The condition-derived phase model stays as is.
- Field-level RBAC for cancellation. `patch agenticruns` stays the authorization, as the parent spec already accepts.
- Proving which sandbox actions completed before the stop.
- Node fencing, a recovery framework, or a generic multi-trigger teardown framework beyond the two stop sources.
- Changes to the console presentation of `EmergencyStopFailed`.

## Anti-goals

- A run that stays `Stopping` indefinitely.
- A run marked `Stopped by user` while a hub workload, hub credential Secret, or spoke SA/RBAC still exists.
- Two state machines for stop handling that can drift or race.
- A regression in global suspension behavior.

## Approaches

| Approach | Tradeoff | Decision |
|---|---|---|
| **A. One shared stop path with a stop source** | Precedence, deadline, conflicts, finality, and spoke confirmation exist once. Reworks suspension code merged on 2026-10-27, so suspension regression risk must be controlled by keeping its tests green. | **Selected by the user.** |
| B. Separate cancellation handler next to suspension | Leaves suspension code almost untouched. Duplicates the stop state machine; suspension-vs-cancellation precedence becomes a cross-handler handoff, the likely race. | Rejected. |
| C. Separate controller for cancellation | Two controllers writing the same run status race each other. | Dropped. |

## Behavior (decided)

### API

- `AgenticRun.spec.cancelled`: optional boolean, effective default `false`.
- CRD CEL makes it one-way: absent/`false` → `true` only; it cannot be cleared or removed.
- It is the third mutable spec field alongside `revisionFeedback` and `terminalTTL`. Cancellation handling runs before generation-based revision handling.
- Authorization: ordinary `patch agenticruns` RBAC. No new ClusterRole.

### Stop sources and precedence

The shared stop handler takes a stop source: `suspension` or `cancellation`.

| Aspect | Suspension | Cancellation |
|---|---|---|
| Trigger | Current `AgenticOLSConfig` activation | `spec.cancelled=true` on a non-terminal run |
| `Stopping=True` reason | `SystemSuspended` (unchanged) | `CancelledByUser` |
| Deadline start | Activation time (unchanged) | `Stopping` acceptance `lastTransitionTime` |
| Deadline length | 10 s (unchanged) | 10 s |
| Confirmed outcome | `EmergencyStopped=True/SystemSuspended` (unchanged) | Phase-relevant condition `False`, reason `CancelledByUser`, message `Run stopped by user` |
| Failed outcome | Phase-relevant condition `False/EmergencyStopFailed` (unchanged) | Phase-relevant condition `False`, reason `CancellationFailed` |
| `Stopping` completion | `False/TeardownComplete` or `False/TeardownFailed` | Same |

Phase-relevant condition mapping is the existing one (`suspensionFailureCondition`): `Pending`/`Analyzing` → `Analyzed`, `Proposed`/`Executing` → `Executed`, `Verifying` → `Verified`, `Escalating` → `Escalated`.

Precedence for a non-deleting run:

1. A run already terminal before a stop signal is processed keeps its outcome.
2. Global suspension is evaluated before cancellation. If both are pending and no outcome is recorded, suspension wins and the final outcome is `EmergencyStopped` or `EmergencyStopFailed`. This includes a run already `Stopping/CancelledByUser`: suspension takes it over. `spec.cancelled` stays `true` for audit.
   The reverse never happens. A run already `Stopping/SystemSuspended` keeps the suspension source even if suspension was resumed or the config deleted and the user then sets `spec.cancelled=true`. It finishes as `EmergencyStopped` or `EmergencyStopFailed` from its persisted activation deadline. Cancellation never rewrites an existing `Stopping` reason or timestamp.
3. Cancellation is evaluated before approval, revision, terminal routing, and phase dispatch.
4. Once recorded, a stop outcome is final. Late completions, Result CRs, approvals, revisions, and late sandboxes cannot overwrite it or restart the run.

### Lifecycle of one cancellation

1. **Acceptance.** The operator persists `Stopping=True/CancelledByUser` (optimistic lock) in the same reconcile that first blocks progression. From then on, `readRunnableRun` and every async write path refuse to advance the run.
2. **Teardown pass.** The operator runs the shared cleanup: `CleanupSuspension(runUID)` on the hub, plus the spoke access cleanup for spoke runs (below). Teardown attempts every operation even when one fails.
3. **Confirmed within the deadline.** In one status update, the operator writes the `CancelledByUser` outcome, sets `Stopping=False/TeardownComplete`, and clears `status.steps.*.sandbox`.
4. **Unconfirmed at the deadline.** In one status update, the operator writes the `CancellationFailed` outcome and sets `Stopping=False/TeardownFailed`. It retains the unconfirmed sandbox references.
5. **After a failed outcome.** Cleanup keeps retrying on requeue and watch events. When a later pass confirms cleanup, the operator sets `Stopping=False/TeardownComplete` and clears the sandbox references in one status update. The `CancellationFailed` condition and the `Failed` phase never change.
6. **Nothing to tear down.** `Pending` and `Proposed` runs, or runs with no sandbox workload or access, confirm on the first pass and reach `CancelledByUser` without delay.

### Spoke confirmation (shared by both sources)

For a run with `spec.targetCluster`, a stop is confirmed only when both checks pass:

- **Hub:** the existing `CleanupSuspension` report is confirmed. The sandbox Pods and `sandbox-kubeconfig` Secrets are gone.
- **Spoke:** using the spoke client from `spokeAccessForRun`, the operator deletes and then confirms absent, through authoritative reads, every run-owned access object on the spoke:
  - per-step ServiceAccounts;
  - per-run reader ClusterRoleBindings;
  - execution Roles, RoleBindings, ClusterRole, and ClusterRoleBinding.

  Discovery uses the run's deterministic object names. The operator creates spoke objects only under these names:
  - `sandboxSAName` for each step, in the spoke namespace;
  - `perRunCRBName` for each reader binding and step;
  - `executionRoleName(runUID)` Role and RoleBinding in every namespace listed in the `rbac-namespaces` annotation;
  - `clusterRoleName(runUID)` ClusterRole and ClusterRoleBinding.

  The spoke pass makes no `List` calls. The standing spoke credential has `get` and `delete` on these kinds but no `list` (verified in `lightspeed-hub` `mce_discovery_controller.go`). After each delete, the operator confirms with an authoritative `Get`: `NotFound` means removed.

  **Annotation fix:** `ensureExecutionRBAC` currently overwrites `rbac-namespaces` on every execution, so after a revision it can lose namespaces that still hold execution RBAC. It must instead keep the union of existing and new namespaces, deduplicated and sorted. Then the names alone cover every spoke object the operator creates.

  Hub resources keep dual discovery (status references plus label/owner inventory), as `CleanupSuspension` already does. Name-based discovery applies to spoke access only.

A missing kubeconfig, an unreachable spoke, or any `Get`/`Delete` error other than `NotFound` (including forbidden) counts as unconfirmed, never as confirmation.

Suspension uses the same spoke check. **The run controller is the only component that performs spoke I/O.** The config controller performs no spoke reads. It derives spoke resolution from each run's recorded state:

- A run whose `Stopping` is not `True` and whose sandbox references are cleared is resolved. This includes a run that recorded a failed outcome and later confirmed cleanup (`Stopping=False/TeardownComplete`).
- A run with retained references or a pending `Stopping` is unresolved. This applies regardless of the run's stop source, so a `CancellationFailed` run with leftover access also keeps `SafeToResume=False` while suspended.
- `RemoteExecutionEvidence` stops being the resolution signal for runs the shared stop path handles. Its annotation-based evidence never clears today, which would block resumption permanently.

A reachable, cleaned spoke run therefore no longer forces `AdminActivatedWithErrors`. When background cleanup later confirms an unresolved run, `SafeToResume` can become `True`. The `AdminActivatedWithErrors` outcome of that activation stays unchanged.

Parent rule 25a ("the affected run MAY remain `Stopping`") and its 60 s constant are superseded by the bounded outcome. The parent spec update removes them.

### Console (update to `lightspeed-agentic-console#375`)

- A run in `Failed` whose effective failure condition has reason `CancellationFailed` shows the cause `Stop failed` in list and detail views.
- While sandbox references remain on such a run, the detail view keeps showing the sandbox shutdown indicator. It must not read as a clean stop.
- A recorded outcome takes precedence over the "stop pending" presentation, even though `spec.cancelled` stays `true`.
- Everything else in #375 stays as is: the Stop control, access review, confirmation, JSON Patch, `Stopping`, `Stopped by user`, and `Emergency stopped`.

### Spec updates

- **Parent (`openshift/ols`):**
  - `what/agentic-run-termination.md`: replace rule 7's unbounded `Stopping` with the bounded deadline and the `CancellationFailed` outcome. Add spoke confirmation to the shared contract. Align the suspension rules with the shipped OLS-4133 behavior (10-second deadline, `TeardownFailed`, `EmergencyStopFailed`, `AdminActivatedWithErrors`, `SafeToResume`). Add `Stop failed` to the console rules. Update the required tests.
  - `decisions/0040-agentic-run-termination.md`: record the revision.
  - `how/repo-map.md`: update the planned markers.
- **Operator:** `what/crd-api.md`, `what/run-lifecycle.md`, `what/sandbox-execution.md`, `what/system-config.md`, `how/reconciler.md`. Add an operator ADR, or amend ADR 0001, for the shared stop path and spoke confirmation.
- **Console:** `what/run-lifecycle.md`, `how/k8s-data-layer.md`.

### Delivery order

1. Parent spec PR in `openshift/ols` (this design plus the spec changes).
2. Operator PR on latest `main`. Close #573 with a pointer to it.
3. Console update to #375.

## Constraints

- Build on current operator `main`. Reuse `CleanupSuspension`, the optimistic-lock status helpers, and the existing condition mapping. Do not reintroduce #573's teardown subsystem.
- Suspension behavior must stay the same except for the added spoke confirmation. The existing suspension tests must pass unchanged, apart from expectations that encode spoke runs as always unverified.
- `patch agenticruns` is resource-wide. Stop-only delegation is impossible with this field.
- Hard-stop safety beats keeping an active Pod for forensics.
- Telemetry: `spec.cancelled` appears in serialized runs and the terminal `reason` gains new literals. The operator PR must carry the data-collection rule 41 classification (additive) as #573 did.

## Left to the builder

- Internal names and boundaries of the shared stop handler, the source type, and the spoke cleanup helper. Renaming `CleanupSuspension` or `handleSuspensionAt` is allowed.
- Whether spoke cleanup lives inside `CleanupSuspension`, in a sibling `SandboxManager` method, or in a wrapper. Both stop sources must use it.
- How `HasAcceptedStop`, `HasFinalStopOutcome`, and `readRunnableRun` learn the cancellation source. Callers in the config controller and on the deletion path must keep their current suspension semantics.
- Diagnostic message wording on `Stopping=False/TeardownFailed` and `CancellationFailed`. Keep it bounded and specific to the unresolved resources.
- Test layout, following repository conventions. Tests must cover consumer-visible behavior:
  - CEL one-way transitions;
  - each phase's mapping;
  - acceptance blocking;
  - confirmed vs. deadline-failed outcomes;
  - spoke confirmed vs. unreachable;
  - suspension-wins precedence, including takeover of a `Stopping/CancelledByUser` run;
  - outcome finality against late writes;
  - background cleanup after a failed outcome flipping `Stopping` to `TeardownComplete` and clearing references without changing the failure condition;
  - `rbac-namespaces` union across two executions with different namespace sets.

## Calls made during design (not explicitly decided by the user)

- Failure reason name `CancellationFailed`, mirroring `EmergencyStopFailed`.
- The cancellation deadline starts at `Stopping` acceptance.
- `EmergencyStopFailed` console presentation stays unchanged.
- Suspension takes over a run already `Stopping/CancelledByUser` with no outcome recorded.
- A failed outcome that later confirms cleanup flips `Stopping` from `TeardownFailed` to `TeardownComplete` and clears references; the failure condition stays.
- Only the run controller performs spoke I/O. The config controller derives spoke resolution from recorded run state and stops using `RemoteExecutionEvidence` as the signal.
- A `CancellationFailed` run with leftover access keeps `SafeToResume=False` during a suspension.
- An accepted suspension stop is never converted into a cancellation.

## Spoke discovery decision (user, 2026-11-10)

| Option | Tradeoff | Decision |
|---|---|---|
| Grant the standing spoke credential `list` (hub change) and use label inventory plus names | Keeps dual discovery on spokes; widens a cross-cluster credential, adds a security-reviewed hub PR, and spoke runs end `Stop failed` until spokes converge. | Rejected. |
| Name-based discovery plus an `rbac-namespaces` union fix | No new permission or hub change; closes the stale-annotation gap. Spoke objects outside the operator's deterministic names would go unnoticed; the operator creates none today. | **Selected by the user.** |
