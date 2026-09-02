# Agentic Run Termination

Product contract for stopping one `AgenticRun` and for hard-stopping sandbox workloads during cluster-wide suspension. Per-run cancellation spans the agentic operator and console; global suspension is initiated through `AgenticOLSConfig`. The two entry points share one teardown contract but retain distinct terminal outcomes.

Jira tracking: OLS-3298 (per-run cancellation), OLS-4018 (global kill-switch sandbox termination). See `decisions/0040-agentic-run-termination.md` for the design decision.

## Behavioral Rules

### Per-Run Cancellation [PLANNED: OLS-3298]

1. **Cancellation field**: `AgenticRun.spec.cancelled` MUST be an optional boolean with an effective default of `false`. Setting it to `true` requests permanent termination of that run.
2. **One-way transition**: CRD validation MUST allow `spec.cancelled` to change only from absent/`false` to `true`. Once true, it MUST NOT be cleared. The field is a third mutable-spec exception alongside `revisionFeedback` and `ttlAfterTerminal`; cancellation handling MUST run before generation-based revision handling.
3. **Authorization**: Any caller with effective Kubernetes RBAC permission to `patch` `agenticruns` in the run namespace MAY set `spec.cancelled=true`. The product MUST NOT add a cancellation-specific ClusterRole or inspect caller group names. Kubernetes RBAC cannot restrict `patch agenticruns` to this field alone.
4. **Valid run states**: A cancellation request MUST terminate any non-terminal run, including `Pending` and `Proposed` runs with no active sandbox. If the run was already terminal when cancellation is processed, its existing terminal outcome MUST remain unchanged.
5. **Reconcile precedence**: For a non-deleting run, the operator MUST evaluate global suspension before per-run cancellation, and cancellation before approval resolution, revision handling, terminal routing, or normal phase dispatch. A persisted cancellation request MUST prevent every later workflow stage from starting.
6. **Failed outcome**: Per-run cancellation MUST NOT add a `Cancelled` phase. It MUST set the phase-relevant workflow condition to `False`, with reason `CancelledByUser` and message `Run stopped by user`, so the existing phase derivation yields `Failed`:

   | Phase when cancellation is handled | Condition set to `False` |
   |---|---|
   | `Pending`, `Analyzing` | `Analyzed` |
   | `Proposed`, `Executing` | `Executed` |
   | `Verifying` | `Verified` |
   | `Escalating` | `Escalated` |

7. **Immediate terminal status**: The operator MUST write the cancellation condition without waiting for sandbox or RBAC teardown to finish. Cleanup failure MUST NOT revert or delay the `Failed` outcome; cleanup remains mandatory and retryable under rules 16-20.
8. **Transition races**: Once `spec.cancelled=true` is accepted for a non-terminal run, it MUST also stop a next-stage sandbox created during an informer or reconcile race. No approval, Result CR, or revision observed afterward may resume or advance the run.
9. **Result integrity**: The operator MUST NOT synthesize an `AnalysisResult`, `ExecutionResult`, `VerificationResult`, or `EscalationResult` for cancellation. Existing Result CRs remain unchanged. A Result CR published after cancellation remains available for audit but MUST NOT advance the terminal run.

### Global Suspension [PLANNED: OLS-4018]

10. **Existing control and outcome**: `AgenticOLSConfig.spec.suspended=true` remains the cluster-wide kill switch. It MUST block new runs at admission, block new workflow stages, and set `EmergencyStopped=True` on non-terminal runs as defined by the agentic operator's system-configuration contract.
11. **Global precedence**: If global suspension and `spec.cancelled=true` are both pending when a non-terminal run is reconciled, global suspension MUST win. The run MUST derive as `EmergencyStopped`, and the console MUST display that outcome. The persisted cancellation field may remain true for audit.
12. **Terminal history**: Global suspension MUST NOT rewrite a run that was already terminal before suspension was processed, including a run already recorded as `Failed / CancelledByUser`. The global workload sweep still applies to active managed sandboxes associated with terminal runs.
13. **Sweep scope**: Suspension MUST hard-stop every active operator-managed sandbox workload, not only workloads referenced by non-terminal AgenticRun status. The sweep MUST include active workloads associated with terminal runs and leaked or orphaned workloads whose run status reference is absent. Already-completed Pods need not be deleted because they cannot perform further actions.

### Shared Hard-Stop and Cleanup Contract [PLANNED: OLS-3298, OLS-4018]

14. **Access revocation and workload termination**: Termination MUST attempt all applicable teardown operations even when one fails: remove sandbox ServiceAccounts from reader bindings, delete execution Roles/RoleBindings and ClusterRoles/ClusterRoleBindings, delete bare Pods with zero grace, delete SandboxClaims, and hard-delete active backing Pods where claim deletion alone is asynchronous.
15. **No cooperative delay**: The operator MUST NOT wait for sandbox acknowledgement, Result CR publication, or normal Pod termination grace before hard-stop. Durable run status, existing Result CRs, Kubernetes audit, and product audit storage are the evidence sources after termination.
16. **Dual discovery**: Per-run cleanup MUST discover resources through both `status.steps.*.sandbox` references and managed labels/owner identity tied to the AgenticRun UID. Global cleanup MUST list managed sandbox resources directly. A missing or stale status reference MUST NOT allow an active workload to escape termination.
17. **Idempotency**: Repeated teardown MUST be safe. Already-absent resources count as successfully removed. Duplicate run reconciliation and global sweeping MAY target the same resource without changing the outcome.
18. **Retry after terminal status**: Terminal reconciliation and sandbox watch events MUST continue cleanup after `Failed / CancelledByUser` or `EmergencyStopped` is written. Any failed operation or still-present active workload MUST cause another reconciliation; terminal status MUST NOT suppress cleanup retries.
19. **Sandbox reference as progress**: `status.steps.<step>.sandbox` MUST remain populated while that step's sandbox workload or associated RBAC still exists. The operator MUST clear the reference only after it confirms both workload removal and access revocation. The console MAY use the remaining reference to display shutdown progress.
20. **Late creation**: A managed sandbox that appears after a cancellation or suspension pass MUST be re-discovered by its watch or the next sweep and hard-stopped. A cancellation field or active global suspension MUST prevent replacement sandbox creation.

### Suspension Completion [PLANNED: OLS-4018]

21. **Draining definition**: `AgenticOLSConfig` MUST remain `Suspended=True` with reason `Draining` while any active managed sandbox workload or associated sandbox access remains. Draining is based on actual teardown state, not only whether AgenticRuns have terminal conditions.
22. **Draining observability**: The Draining condition message SHOULD report the remaining active sandbox count. A list, deletion, or verification error MUST keep the condition in Draining and surface an actionable message or Event.
23. **Activation completion**: The condition MAY transition to `Suspended=True`, reason `AdminActivated` only after the operator confirms that no active managed sandbox or associated access remains. The suspension-activated Event is emitted when `spec.suspended` changes to `true`, regardless of whether the condition initially enters `Draining`.
24. **Immediate blocking**: Draining does not weaken suspension. Admission blocking and reconcile guards MUST remain active from the moment `spec.suspended=true`, before teardown completion.
25. **Safe resumption**: An attempt to set `AgenticOLSConfig.spec.suspended=false` while the `Suspended` condition is `True` with reason `Draining` MUST be rejected at admission. The admission policy MUST allow deactivation only after the condition reaches `AdminActivated`. This keeps create admission blocking and reconcile guards active until stopped sandbox workloads and access are confirmed removed.

### Console Behavior [PLANNED: OLS-3298]

26. **Stop control visibility**: The agentic console MUST show a danger-styled `Stop run` control only during active sandbox phases: `Analyzing`, `Executing`, `Verifying`, and `Escalating`. Direct API cancellation remains valid for every non-terminal phase under rule 4.
27. **Access review**: The console MUST call `useAccessReview` for `patch` on `agenticruns` in API group `agentic.openshift.io`, scoped to `run.metadata.namespace` (falling back to the run-watch namespace before the run loads). The effective permission controls whether the Stop control is shown or enabled. The console MUST NOT inspect groups or reuse the `patch agenticrunapprovals` approval check as a proxy. The API server remains authoritative for the patch.
28. **Confirmation**: Stopping requires confirmation that the action is irreversible. During `Executing`, the confirmation MUST warn that partial cluster changes may exist and require manual inspection.
29. **Mutation and errors**: Confirmation MUST send a JSON Patch `add` operation at `/spec/cancelled` with value `true` to that same namespaced AgenticRun. It changes no other field and succeeds whether `cancelled` is absent or already present; `spec` remains required. The console MUST NOT optimistically change phase. A failed patch, including a stale-permission `403`, MUST leave the current phase visible and display the API error.
30. **Failed presentation**: A cancelled run MUST retain the `Failed` phase badge and display `Stopped by user` as its cause in list and detail views. While any sandbox reference remains under rule 19, the detail view MUST also display `Sandbox shutdown in progress`.
31. **Global presentation**: When rule 11 applies, the console MUST show `Emergency stopped`, not `Failed / Stopped by user`.

## Integration Contracts

### AgenticRun API Addition [PLANNED: OLS-3298]

| Field | Type | Mutability | Meaning |
|---|---|---|---|
| `spec.cancelled` | optional boolean, effective default `false` | one-way absent/`false` → `true` | Permanently request termination of a non-terminal run |

`spec.cancelled` is intent. The observed outcome is the phase-relevant condition with `status=False`, `reason=CancelledByUser`, and `message=Run stopped by user`.

### Outcome Precedence

For termination signals and existing terminal state:

1. A terminal outcome already processed before a new stop signal remains unchanged.
2. For a non-terminal run with both pending signals, global suspension produces `EmergencyStopped`.
3. Otherwise `spec.cancelled=true` produces `Failed / CancelledByUser`.
4. Either stop path prevents later workflow progression and invokes the shared hard-stop contract.

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-agentic-operator** | `spec.cancelled` API and CEL, reconcile precedence, condition mapping, hard deletion, RBAC revocation, resource discovery, cleanup retries, sandbox-reference clearing, global sweep, suspension Draining completion, and safe resumption admission |
| **lightspeed-agentic-console** | `patch agenticruns` access review, Stop control and confirmation, partial-change warning, failure-cause and shutdown-progress presentation |

## Child Spec Updates Required

| Repo | Spec Files | Required updates |
|---|---|---|
| lightspeed-agentic-operator | `what/crd-api.md`, `what/run-lifecycle.md` | Add the one-way cancellation field, mutable-spec exception, condition mapping, precedence, and terminal race rules. |
| lightspeed-agentic-operator | `what/system-config.md`, `what/sandbox-execution.md`, `how/reconciler.md` | Replace best-effort terminal-only suspension cleanup with hard deletion, direct discovery, terminal retries, sandbox-reference clearing, teardown-based Draining completion, safe resumption admission, and reusable-template protection. |
| lightspeed-agentic-console | `what/run-lifecycle.md`, `how/k8s-data-layer.md` | Replace the execution-only planned stop rule with active-phase visibility, `patch agenticruns` access review, patch behavior, and failure/progress presentation. |

## Required Test Coverage

### Agentic Operator

- CRD validation accepts absent/`false` to true and rejects true to false.
- Every non-terminal phase maps to the condition in rule 6 and no later phase starts.
- Pending and Proposed runs can be cancelled through the API.
- Global suspension wins when both stop signals are pending; an existing terminal outcome is preserved.
- Bare Pods receive zero-grace deletion; SandboxClaims and active backing workloads are terminated.
- Label/owner discovery finds workloads with missing status references and active leaked/orphaned workloads.
- Cleanup errors requeue, status references remain until complete, and successful retry clears them.
- Late Result CRs and late sandbox creation cannot advance or restart a stopped run.
- Suspension remains Draining until both workloads and access are gone, then reaches AdminActivated; an attempted deactivation is rejected before that transition.

### Agentic Console

- Stop appears only in active sandbox phases and uses namespaced `patch agenticruns` access review.
- A denied access review makes the Stop control unavailable; the console does not inspect user groups.
- Confirmation targets the reviewed namespace and sends JSON Patch `add` at `/spec/cancelled` with value `true`; errors do not optimistically change phase.
- Execution confirmation includes the partial-change warning.
- Cancelled runs show `Failed` with `Stopped by user`; remaining sandbox status shows shutdown progress.
- Simultaneous pending signals render the global `EmergencyStopped` outcome.

## Constraints

- `patch agenticruns` is resource-wide. Stop-only delegation is impossible with this boolean field and would require a separate API design.
- Cancellation does not establish which sandbox actions completed. Operators must inspect existing results, audit records, and cluster state before further remediation.
- Hard-stop safety takes precedence over retaining an active Pod for forensics. Durable audit systems, not a running sandbox, own post-incident evidence.
