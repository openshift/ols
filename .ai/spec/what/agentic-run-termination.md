# Agentic Run Termination

Product contract for stopping one `AgenticRun` and for hard-stopping sandbox workloads during cluster-wide suspension. Per-run cancellation spans the agentic operator and console; global suspension is initiated through `AgenticOLSConfig`. The two entry points share one teardown contract but retain distinct terminal outcomes.

Jira tracking: OLS-3298 (per-run cancellation), OLS-4018 (global kill-switch sandbox termination), OLS-4131 (confirmed-teardown stopping contract). See `decisions/0040-agentic-run-termination.md` for the design decision.

## Behavioral Rules

### Per-Run Cancellation [PLANNED: OLS-3298]

1. **Cancellation field**: `AgenticRun.spec.cancelled` MUST be an optional boolean with an effective default of `false`. Setting it to `true` requests permanent termination of that run.
2. **One-way transition**: CRD validation MUST allow `spec.cancelled` to change only from absent/`false` to `true`. Once true, it MUST NOT be cleared. The field is a third mutable-spec exception alongside `revisionFeedback` and (before first terminal transition only [PLANNED: OLS-4280]) `terminalTTL`; cancellation handling MUST run before generation-based revision handling.
3. **Authorization**: Any caller with effective Kubernetes RBAC permission to `patch` `agenticruns` in the run namespace MAY set `spec.cancelled=true`. The product MUST NOT add a cancellation-specific ClusterRole or inspect caller group names. Kubernetes RBAC cannot restrict `patch agenticruns` to this field alone.
4. **Valid run states**: A cancellation request MUST terminate any non-terminal run, including `Pending` and `Proposed` runs with no active sandbox. If the run was already terminal when cancellation is processed, its existing terminal outcome MUST remain unchanged.
5. **Reconcile precedence**: For a non-deleting run, the operator MUST evaluate global suspension before per-run cancellation, and cancellation before approval resolution, revision handling, terminal routing, or normal phase dispatch. A persisted cancellation request MUST prevent every later workflow stage from starting.
6. **Stopped outcome**: Per-run cancellation MUST NOT add a `Cancelled` phase. When the shared teardown contract (rules 14–20) confirms that the run's sandbox workloads and sandbox access are removed, the operator MUST set the phase-relevant workflow condition to `False`, with reason `CancelledByUser` and message `Run stopped by user`, so the existing phase derivation yields `Failed`:

   | Phase when the stop is accepted | Condition set to `False` |
   |---|---|
   | `Pending`, `Analyzing` | `Analyzed` |
   | `Proposed`, `Executing` | `Executed` |
   | `Verifying` | `Verified` |
   | `Escalating` | `Escalated` |

   The outcome condition and the completion of the run's `Stopping` condition (rule 14a) MUST be recorded in the same status update. [PLANNED: OLS-4131]
7. **Outcome at confirmed teardown**: A stop request blocks workflow progression immediately (rules 5 and 14a), but the operator MUST NOT write the `Failed / CancelledByUser` outcome until teardown is confirmed under rules 14–20. While teardown is pending, the run MUST remain non-terminal with `Stopping=True`. If a teardown operation fails or an active workload remains, the run MUST stay visibly stopping and cleanup MUST be retried; the outcome is recorded only once workloads and access are confirmed removed. When no sandbox workload or sandbox access exists (for example `Pending` or `Proposed` runs), teardown is already confirmed and the outcome follows without delay. [PLANNED: OLS-4131]
8. **Transition races**: Once `spec.cancelled=true` is accepted for a non-terminal run, it MUST also stop a next-stage sandbox created during an informer or reconcile race. No approval, Result CR, or revision observed afterward may resume or advance the run.
9. **Result integrity**: The operator MUST NOT synthesize an `AnalysisResult`, `ExecutionResult`, `VerificationResult`, or `EscalationResult` for cancellation. Existing Result CRs remain unchanged. A Result CR published after a stop request remains available for audit but MUST NOT advance the run or alter its stopped outcome.

### Global Suspension [PLANNED: OLS-4018]

10. **Existing control and outcome**: `AgenticOLSConfig.spec.suspended=true` remains the cluster-wide kill switch. It MUST block new runs at admission and block new workflow stages immediately. For each non-terminal run, it MUST set the run-level `Stopping` condition (rule 14a) and record `EmergencyStopped=True` only after that run's teardown is confirmed under rules 14–20, as defined by the agentic operator's system-configuration contract. [PLANNED: OLS-4131]
11. **Global precedence**: If global suspension and `spec.cancelled=true` are both pending when a non-terminal run is reconciled, global suspension MUST win: the run's final outcome MUST be `EmergencyStopped`, and the console MUST display that outcome once recorded. While teardown is pending, the shared `Stopping` presentation (rule 30) applies regardless of which signal wins. The persisted cancellation field may remain true for audit.
12. **Terminal history**: Global suspension MUST NOT rewrite a run that was already terminal before suspension was processed, including a run already recorded as `Failed / CancelledByUser`. The global workload sweep still applies to active managed sandboxes associated with terminal runs.
13. **Sweep scope**: Suspension MUST hard-stop every active operator-managed sandbox workload, not only workloads referenced by non-terminal AgenticRun status. The sweep MUST include active workloads associated with terminal runs and leaked or orphaned workloads whose run status reference is absent. Already-completed Pods need not be deleted because they cannot perform further actions.

### Shared Hard-Stop and Cleanup Contract [PLANNED: OLS-3298, OLS-4018, OLS-4133]

14. **Access revocation and workload termination**: Termination MUST attempt all applicable teardown operations even when one fails: remove sandbox ServiceAccounts from reader bindings, delete execution Roles/RoleBindings and ClusterRoles/ClusterRoleBindings, delete bare Pods with zero grace, delete SandboxClaims, and hard-delete active backing Pods where claim deletion alone is asynchronous.
14a. **Run Stopping condition**: Both stop paths MUST expose per-run teardown progress through a run-level `Stopping` condition in `status.conditions`. The operator MUST set `Stopping=True` when a stop signal is accepted for a non-terminal run, in the same reconcile that first blocks progression, and MUST keep it `True` while any teardown operation for that run is pending or retrying. A run with `Stopping=True` MUST NOT start later workflow stages and MUST NOT be treated as terminal. When teardown is confirmed, the operator MUST complete the `Stopping` condition (status `False`) in the same status update that records the final stopped outcome (rule 6 or rule 10). [PLANNED: OLS-4131]
15. **No cooperative delay**: The operator MUST NOT wait for sandbox acknowledgement, Result CR publication, or normal Pod termination grace before hard-stop. Durable run status, existing Result CRs, Kubernetes audit, and product audit storage are the evidence sources after termination.
16. **Dual discovery**: Per-run cleanup MUST discover resources through both `status.steps.*.sandbox` references and managed labels/owner identity tied to the AgenticRun UID. Global cleanup MUST list managed sandbox resources directly. A missing or stale status reference MUST NOT allow an active workload to escape termination.
17. **Idempotency**: Repeated teardown MUST be safe. Already-absent resources count as successfully removed. Duplicate run reconciliation and global sweeping MAY target the same resource without changing the outcome.
18. **Cleanup retries**: Run reconciliation and sandbox watch events MUST continue cleanup from the moment a stop signal is accepted — while `Stopping=True` and after the stopped outcome is recorded. Any failed operation or still-present active workload MUST cause another reconciliation; a pending or recorded stop outcome MUST NOT suppress cleanup retries. [PLANNED: OLS-4131]
19. **Sandbox reference as progress**: `status.steps.<step>.sandbox` MUST remain populated while that step's sandbox workload or associated RBAC still exists. The operator MUST clear the reference only after it confirms both workload removal and access revocation. The console MAY use the remaining reference to display shutdown progress.
19a. **Deletion with unverified access**: When a stopped `AgenticRun` targeting a gone or unreachable spoke is deleted, the operator MUST retry sandbox and RBAC cleanup for the bounded window. If access remains unverified after the window and the only failure is a degradeable spoke error, the operator MAY release its RBAC-cleanup finalizer with a Warning Event so deletion completes. A missing spoke kubeconfig is hard gone and MAY release immediately; an invalid kubeconfig or network failure retries for the window. A hub permission, API, or non-degradeable cleanup error MUST keep the finalizer. The global suspension sweep remains responsible for retrying labeled spoke access while suspension is active. Releasing the finalizer MUST NOT rewrite the run's `Stopping` condition to a terminal outcome.
20. **Late creation**: A managed sandbox that appears after a cancellation or suspension pass MUST be re-discovered by its watch or the next sweep and hard-stopped. A cancellation field or active global suspension MUST prevent replacement sandbox creation.
20a. **Outcome finality**: Once a stopped outcome is recorded under rule 6 or rule 10, it is final. A late workflow completion, Result CR, approval, or revision feedback observed afterward MUST NOT overwrite the stopped outcome or restart workflow progression. The terminal-history protections in rules 4 and 12 are unchanged. [PLANNED: OLS-4131]
20b. **Status-write concurrency**: The operator SHOULD use resourceVersion-checked status patches and, on conflict, reread and re-evaluate before reapplying, so a stale workflow-completion write cannot undo stop progress or a recorded stopped outcome. This is a recommendation; the contract does not require a separate controller queue or a specific concurrency mechanism. [PLANNED: OLS-4131]

### Suspension Completion [PLANNED: OLS-4018, OLS-4133]

21. **Stopping definition**: `AgenticOLSConfig` MUST remain `Suspended=True` with reason `Stopping` while any active managed sandbox workload or associated sandbox access remains, or while any AgenticRun remains non-terminal — including a run whose `Stopping` condition is `True` but whose stopped outcome is not yet recorded — except for a run whose only remaining blocker is an unverified spoke under rule 25a. If a non-terminal AgenticRun appears while suspended (for example an admission race), the condition MUST return to reason `Stopping` until that run's outcome is recorded, unless rule 25a applies. The reason reflects actual teardown state and recorded run outcomes together; neither alone is sufficient. [PLANNED: OLS-4131 renames this reason from `Draining`; the condition type `Suspended` is unchanged.]
22. **Stopping observability**: The `Suspended` condition message SHOULD report the remaining active sandbox count and the count of runs still awaiting their stopped outcome while the reason is `Stopping`. A list, deletion, or verification error MUST keep the reason `Stopping` and surface an actionable message or Event. When rule 25a applies, the message MUST name the unverified spokes and the runs still stopping.
23. **Activation completion**: The condition MAY transition to `Suspended=True`, reason `AdminActivated` only after the operator confirms both that no active managed sandbox or associated access remains and that no AgenticRun remains non-terminal — every run that was non-terminal when suspension was accepted has recorded its stopped outcome. The resource check alone is insufficient: a run with no sandbox workload or access (for example `Pending`) is trivially torn down, so that check can pass before the run's reconciler writes `Stopping` and the stopped outcome, and a resumption accepted in that window would let the run continue instead of being stopped. The suspension-activated Event is emitted when `spec.suspended` changes to `true`, regardless of whether the condition initially enters reason `Stopping`. [PLANNED: OLS-4131]
24. **Immediate blocking**: Reason `Stopping` does not weaken suspension. Admission blocking and reconcile guards MUST remain active from the moment `spec.suspended=true`, before teardown completion.
25. **Safe resumption**: An attempt to set `AgenticOLSConfig.spec.suspended=false`, or to delete the config while it is suspended, MUST be rejected at admission unless the `Suspended` condition is `True` with reason `AdminActivated` or `AdminActivatedWithErrors`. Rejection MUST also cover the window after `spec.suspended` becomes `true` but before the operator first records the `Suspended` condition — the status write can lag the spec change, so an absent, `False`, or `Stopping` condition MUST NOT be treated as permission to resume. This keeps create admission blocking and reconcile guards active until stopped sandbox workloads and access are confirmed removed and every run the suspension stops has recorded its outcome, except a run left `Stopping` under rule 25a.
25a. **Degraded completion**: If the only remaining unverified work is access on a gone or unreachable spoke, and every non-terminal AgenticRun either does not exist or has `Stopping=True` with that spoke as its target, the condition MAY transition to `Suspended=True`, reason `AdminActivatedWithErrors`. A missing or invalid spoke kubeconfig MAY degrade immediately; network failures MUST first retry for the bounded window (60s operator constant). The message MUST name the unverified spokes and the runs still stopping, and include the compact error. The operator MUST emit a Warning `SuspensionCompletedWithErrors` Event. Cleanup keeps retrying and MAY return the condition to clean `AdminActivated` if the spoke recovers before resume. The affected run MAY remain `Stopping`; this reason does not record a terminal run outcome. [PLANNED: OLS-4133]

### Console Behavior [PLANNED: OLS-3298]

26. **Stop control visibility**: The agentic console MUST show a danger-styled `Stop run` control only during active sandbox phases: `Analyzing`, `Executing`, `Verifying`, and `Escalating`. Direct API cancellation remains valid for every non-terminal phase under rule 4.
27. **Access review**: The console MUST call `useAccessReview` for `patch` on `agenticruns` in API group `agentic.openshift.io`, scoped to `run.metadata.namespace` (falling back to the run-watch namespace before the run loads). The effective permission controls whether the Stop control is shown or enabled. The console MUST NOT inspect groups or reuse the `patch agenticrunapprovals` approval check as a proxy. The API server remains authoritative for the patch.
28. **Confirmation**: Stopping requires confirmation that the action is irreversible. During `Executing`, the confirmation MUST warn that partial cluster changes may exist and require manual inspection.
29. **Mutation and errors**: Confirmation MUST send a JSON Patch `add` operation at `/spec/cancelled` with value `true` to that same namespaced AgenticRun. It changes no other field and succeeds whether `cancelled` is absent or already present; `spec` remains required. The console MUST NOT optimistically change phase; after a successful patch it waits for the operator to set the run's `Stopping` condition. A failed patch, including a stale-permission `403`, MUST leave the current phase visible and display the API error.
30. **Stopping and stopped presentation**: While the run's `Stopping` condition is `True`, the console MUST display `Stopping` prominently instead of the derived phase label in list and detail views; the run is not terminal and no outcome is shown yet. Once teardown is confirmed and the outcome is recorded, a cancelled run MUST retain the `Failed` phase badge and display `Stopped by user` as its cause in list and detail views. If a sandbox reference still remains under rule 19, the detail view MUST also display `Sandbox shutdown in progress`. [PLANNED: OLS-4131]
31. **Global presentation**: When rule 11 applies, the console MUST show `Emergency stopped` once the outcome is recorded, not `Failed / Stopped by user`. While the run is `Stopping`, the rule 30 `Stopping` presentation applies. [PLANNED: OLS-4131]

## Integration Contracts

### AgenticRun API Addition [PLANNED: OLS-3298]

| Field | Type | Mutability | Meaning |
|---|---|---|---|
| `spec.cancelled` | optional boolean, effective default `false` | one-way absent/`false` → `true` | Permanently request termination of a non-terminal run |

`spec.cancelled` is intent. An accepted stop first sets the run-level `Stopping` condition (rule 14a); the observed outcome is the phase-relevant condition with `status=False`, `reason=CancelledByUser`, and `message=Run stopped by user`, recorded once teardown is confirmed.

### Outcome Precedence

For termination signals and existing terminal state:

1. A terminal outcome already processed before a new stop signal remains unchanged.
2. Either stop path sets the run's `Stopping` condition and blocks workflow progression immediately, before any outcome is recorded.
3. For a non-terminal run with both pending signals, global suspension produces `EmergencyStopped` once teardown is confirmed.
4. Otherwise `spec.cancelled=true` produces `Failed / CancelledByUser` once teardown is confirmed.
5. Once recorded, a stopped outcome is final (rule 20a); late completions, Result CRs, or revisions cannot overwrite it or restart the workflow.

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-agentic-operator** | `spec.cancelled` API and CEL, reconcile precedence, run `Stopping` condition, condition mapping, hard deletion, RBAC revocation, resource discovery, cleanup retries, sandbox-reference clearing, global sweep, suspension Stopping completion, degraded completion, finalizer release, and safe resumption admission |
| **lightspeed-agentic-console** | `patch agenticruns` access review, Stop control and confirmation, partial-change warning, `Stopping` presentation, and failure-cause and shutdown-progress presentation |

## Child Spec Updates Required

| Repo | Spec Files | Required updates |
|---|---|---|
| lightspeed-agentic-operator | `what/crd-api.md`, `what/run-lifecycle.md` | Add the one-way cancellation field, mutable-spec exception, run `Stopping` condition, condition mapping, precedence, and terminal race rules. |
| lightspeed-agentic-operator | `what/system-config.md`, `what/sandbox-execution.md`, `how/reconciler.md` | Replace best-effort terminal-only suspension cleanup with hard deletion, direct discovery, terminal retries, sandbox-reference clearing, teardown-based Stopping completion, degraded completion, finalizer release, safe resumption admission, and reusable-template protection. |
| lightspeed-agentic-console | `what/run-lifecycle.md`, `how/k8s-data-layer.md` | Replace the execution-only planned stop rule with active-phase visibility, `patch agenticruns` access review, patch behavior, `Stopping` presentation, and failure/progress presentation. |

## Required Test Coverage

### Agentic Operator

- CRD validation accepts absent/`false` to true and rejects true to false.
- Every non-terminal phase maps to the condition in rule 6, the `Stopping` condition is set when the stop is accepted, and no later phase starts.
- The stopped outcome is written only after teardown is confirmed in both sandbox modes (bare Pod and SandboxClaim), including RBAC removal; the `Stopping` condition completes in the same status update.
- A stale workflow-completion status write cannot undo stop progress or a recorded stopped outcome (resourceVersion conflict causes reread and re-evaluation).
- A failed teardown operation keeps the run visibly `Stopping` and retries; the outcome is not recorded while an active workload or sandbox access remains.
- Pending and Proposed runs can be cancelled through the API; with no sandbox workload or access present, the outcome follows without delay.
- Global suspension wins when both stop signals are pending; an existing terminal outcome is preserved.
- Bare Pods receive zero-grace deletion; SandboxClaims and active backing workloads are terminated.
- Label/owner discovery finds workloads with missing status references and active leaked/orphaned workloads.
- Cleanup errors requeue, status references remain until complete, and successful retry clears them.
- Late Result CRs and late sandbox creation cannot advance or restart a stopped run, and a late completion cannot overwrite a recorded stopped outcome.
- Suspension remains Stopping until workloads and access are gone and no AgenticRun remains non-terminal, except a run whose only remaining blocker is an unverified spoke; a sandbox-less Pending run keeps the condition Stopping until its EmergencyStopped outcome is recorded and deactivation is rejected in that window, and a run appearing while suspended returns the condition to Stopping; then the condition reaches AdminActivated, or AdminActivatedWithErrors when the unverified-spoke exception applies. Deactivation attempted before the condition is first recorded (status-write lag) is also rejected; deactivation is accepted only once `AdminActivated` or `AdminActivatedWithErrors` is observed.
- A stopped run targeting a gone spoke permits AdminActivatedWithErrors while a run targeting a healthy spoke keeps Stopping.
- Deleting a stopped run on a gone spoke releases its RBAC finalizer after the bounded window; a hub cleanup error keeps the finalizer.

### Agentic Console

- Stop appears only in active sandbox phases and uses namespaced `patch agenticruns` access review.
- A denied access review makes the Stop control unavailable; the console does not inspect user groups.
- Confirmation targets the reviewed namespace and sends JSON Patch `add` at `/spec/cancelled` with value `true`; errors do not optimistically change phase.
- Execution confirmation includes the partial-change warning.
- Cancelled runs show `Failed` with `Stopped by user`; remaining sandbox status shows shutdown progress.
- While the run's `Stopping` condition is true, list and detail views show `Stopping` instead of the derived phase label; `Stopped by user` or `Emergency stopped` appears only after the outcome is recorded.
- Simultaneous pending signals render the global `EmergencyStopped` outcome.

## Constraints

- `patch agenticruns` is resource-wide. Stop-only delegation is impossible with this boolean field and would require a separate API design.
- Cancellation does not establish which sandbox actions completed. Operators must inspect existing results, audit records, and cluster state before further remediation.
- Hard-stop safety takes precedence over retaining an active Pod for forensics. Durable audit systems, not a running sandbox, own post-incident evidence.
