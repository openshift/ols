# Agentic Security Model

Security constraints for the agentic run system. Covers approval authorization, cancellation authorization, execution-time permission isolation, and access revocation during termination. Cross-references `agentic-runs.md` for the overall workflow and `agentic-run-termination.md` for stop behavior. For how MCP tools are admitted and how RBAC for admitted mutating Kubernetes tools is derived before binding it to the per-run execution SA, see `mcp-tool-rbac.md` (OLS-4059).

## Security Gaps Addressed

Two confirmed vulnerabilities in the current implementation motivate this spec:

1. **Approval privilege escalation.** Any user with `patch` permission on `agenticrunapprovals` can approve a run requesting arbitrary RBAC — including cluster-admin-level permissions — regardless of their own authorization level. No validation exists at the API server, operator, or console layer.

2. **Cross-run permission leakage.** All runs share a single `lightspeed-agent` ServiceAccount. RBAC Roles created for one run's execution are bound to this shared SA, so concurrent runs inherit each other's elevated permissions. An analysis step running concurrently with an execution step also inherits the execution's permissions via the same SA.

## Behavioral Rules

### Approval Authorization

1. **Cluster-admin gate.** Only users bound to the `cluster-admin` ClusterRole (or `kubeadmin`) MAY approve run execution. This is enforced by Kubernetes RBAC on the `agenticrunapprovals` resource — no additional webhook or operator-side check is required.

2. **Dedicated approver ClusterRole.** The operator MUST ship a ClusterRole named `agentic-run-approver` granting `get`, `list`, `watch`, and `patch` on `agenticrunapprovals` resources in API group `agentic.openshift.io`. This ClusterRole is the sole grant of `patch agenticrunapprovals` outside the operator's own manager role.

3. **ClusterRoleBinding to cluster-admin.** The operator MUST ship a ClusterRoleBinding that binds the `agentic-run-approver` ClusterRole to the `system:cluster-admins` group (the group that `cluster-admin` ClusterRoleBinding grants). No other ClusterRoleBinding or RoleBinding MAY grant `patch agenticrunapprovals` to human actors.

4. **Operator manager role.** The operator's own `agentic-operator-manager-role` ClusterRole retains `patch agenticrunapprovals` because the operator creates and seeds the `AgenticRunApproval` CR programmatically (see `approval.md` rule 2). This is a service account, not a human actor.

5. **Console UI gate.** The agentic console plugin MUST perform a `useAccessReview` check for `patch` on `agenticrunapprovals` before rendering the Approve/Deny buttons. If the user lacks the permission, the buttons MUST be hidden or disabled with a tooltip explaining the requirement. This is cosmetic — the API server enforces the real gate — but prevents confusing 403 errors.

6. **Read access for non-admins.** Non-cluster-admin users with `get`/`list`/`watch` on `agenticruns` and `agenticrunapprovals` MAY view run status and approval state. They MUST NOT be able to modify approval decisions.

### Per-Run ServiceAccount Isolation

1. **Ephemeral execution SA.** For each run entering the execution phase, the operator MUST create a dedicated ServiceAccount named `ls-exec-{run-namespace}-{run-name}` (truncated to 63 chars) in the operator namespace. This SA MUST be used as the subject for all execution RBAC bindings (Roles, RoleBindings, ClusterRoles, ClusterRoleBindings) instead of the shared `lightspeed-agent` SA.

2. **SA name truncation.** The per-run SA name MUST be truncated to 63 characters using the existing `truncateK8sName` function to comply with Kubernetes naming constraints.

3. **Execution pod assignment.** The execution sandbox pod (bare-pod or sandbox-claim mode) MUST run as the per-run SA (`ls-exec-{run-namespace}-{run-name}`), not as `lightspeed-agent`. The operator passes this SA name to pod spec construction or template derivation.

4. **Read-only SA scope.** Analysis and verification steps use the shared `lightspeed-agent` SA. Since execution RBAC is never bound to `lightspeed-agent` (rule 7), neither step can inherit execution-level permissions from concurrent runs. The `lightspeed-agent` SA SHOULD be bound to a cluster-reader ClusterRole so that analysis and verification can query cluster state without write access.

5. **SA lifecycle — creation.** The per-run SA MUST be created before execution RBAC materialization, in the same reconcile pass as `ensureExecutionRBAC`. If creation fails, the step MUST fail with an error surfaced to run conditions.

6. **SA lifecycle — owner reference.** The per-run SA MUST NOT carry an owner reference — cross-namespace owner references are not honored by the Kubernetes garbage collector. Cleanup is instead handled by the operator's run reconciler when the run reaches a terminal phase.

7. **SA lifecycle — cleanup.** On terminal phases (Completed, Failed, Denied, Escalated, EmergencyStopped, NoActionRequired) or AgenticRun deletion, the operator MUST delete the per-run SA alongside the existing RBAC cleanup. This is defense-in-depth — explicit cleanup ensures prompt removal of credentials.

8. **Verification SA.** Verification steps use the shared `lightspeed-agent` SA (same as analysis), not the per-run execution SA. Verification is a read-only check — it confirms whether the execution's changes took effect but MUST NOT have write access. Escalation steps also use the shared `lightspeed-agent` SA since escalation generates a human-readable summary and does not modify cluster state.

9. **Shared SA retention.** The `lightspeed-agent` SA MUST still be created at operator bootstrap (sandbox-execution.md rule 38) for analysis steps and as a fallback. It MUST NOT have any execution-level Roles or ClusterRoles bound to it.

### Run Cancellation and Termination [PLANNED: OLS-3298, OLS-4018]

 1. **Cancellation authorization.** Any caller with effective Kubernetes RBAC permission to `patch` namespaced `agenticruns` MAY set the one-way `spec.cancelled=true` field. The operator MUST NOT add a cancellation-specific ClusterRole or require membership in a named group. The API server's authorization of the patch is the enforcement boundary.

 2. **Console access review.** The agentic console MUST check `patch` on `agenticruns` in the run namespace before showing or enabling `Stop run`. It MUST NOT inspect group membership or use `patch agenticrunapprovals` as a proxy. The actual patch remains independently authorized by the API server.

 3. **Termination revocation.** Per-run cancellation and global suspension MUST revoke all sandbox access associated with the targeted workload, including sandbox ServiceAccount reader bindings and execution Roles/RoleBindings and ClusterRoles/ClusterRoleBindings. Revocation errors MUST remain retryable after terminal status; the system MUST NOT report global suspension fully activated while sandbox access remains. See `agentic-run-termination.md`.

## Repo Ownership

| Repo | Owns |
| --- | --- |
| **lightspeed-agentic-operator** | ClusterRole/ClusterRoleBinding for approver (RBAC manifests), per-run SA creation/cleanup, RBAC binding to per-run SA, `defaultSandboxSA` replacement logic; stop-time access revocation [PLANNED: OLS-3298, OLS-4018] |
| **lightspeed-agentic-console** | `useAccessReview` gate on approve/deny buttons; separate `patch agenticruns` review for Stop [PLANNED: OLS-3298] |

## Child Spec Updates Required

The following child repo specs describe behavior that this spec supersedes or augments. Each MUST be updated to reflect the new rules:

| Repo | Spec File | Update |
| --- | --- | --- |
| lightspeed-agentic-operator | `what/sandbox-execution.md` rule 21 | RBAC bindings reference per-run SA, not shared SA. Update rule 22 to reference per-run SA. Add rule for SA creation/cleanup. |
| lightspeed-agentic-operator | `what/sandbox-execution.md` rule 38 | Clarify that `lightspeed-agent` bootstrap SA is for analysis only; execution uses per-run SA. |
| lightspeed-agentic-operator | `what/approval.md` | Add rule: `patch agenticrunapprovals` is restricted to cluster-admin via dedicated ClusterRole/ClusterRoleBinding. Reference this spec. |
| lightspeed-agentic-console | `what/run-lifecycle.md` rule 15-18 | Add rule: console MUST check `useAccessReview` before showing approval UI. |
| lightspeed-agentic-operator | `what/crd-api.md`, `what/run-lifecycle.md`, `what/system-config.md`, `what/sandbox-execution.md` | Add cancellation authorization and complete stop-time RBAC revocation/retry requirements from `agentic-run-termination.md`. |
| lightspeed-agentic-console | `what/run-lifecycle.md` | Add a distinct `patch agenticruns` access review for Stop; do not reuse approval permission or inspect groups. |
| parent | `what/agentic-runs.md` Phase 3 | Add note that approval is restricted to cluster-admin and reference this spec. |

## Constraints

- The cluster-admin gate is binary: either you have cluster-admin or you cannot approve. Namespace-scoped approval delegation is out of scope for the current release.
- Per-run SA names must be unique across concurrent runs. Since all per-run SAs live in the single operator namespace, the naming convention MUST incorporate the run's namespace to avoid collisions when runs in different namespaces share the same name: `ls-exec-{run-namespace}-{run-name}` (truncated to 63 chars). This mirrors how execution Role names already include namespace context.
- SA token propagation to an already-running pod is not instant. The SA MUST be created and RBAC MUST be bound before the execution pod is created, not after.
- Kubernetes RBAC grants `patch` at resource scope, not individual-field scope. A caller allowed to cancel through `patch agenticruns` can also modify other mutable AgenticRun fields. Stop-only delegation requires a separate future API design.

## Planned Changes

| Ticket | Summary |
| --- | --- |
| [DONE: OLS-3295] | Rename `Proposal` → `AgenticRun`, `ProposalApproval` → `AgenticRunApproval` across CRDs, RBAC resources, and SA naming |
| [PLANNED: OLS-3298] | Authorize per-run cancellation through effective `patch agenticruns`; add a separate console access review and revoke sandbox access until confirmed complete. |
| [PLANNED: OLS-4018] | Revoke access for every active managed sandbox during global suspension and keep suspension Draining while revocation is incomplete. |
| [PLANNED] | Namespace-scoped approval delegation: allow non-cluster-admins to approve runs scoped to namespaces where they have equivalent RBAC. Requires either a ValidatingAdmissionWebhook with SubjectAccessReview or a more granular ClusterRole structure. |
| [PLANNED] | Analysis cluster-reader SA: a fixed `lightspeed-analyst` ClusterRoleBinding with read-only cluster access for analysis steps that need to query cluster state directly. Separate from per-run execution SA. |
