# Agentic Security Model

Security constraints for the agentic proposal system. Covers approval authorization and execution-time permission isolation. Cross-references `agentic-proposals.md` for the overall workflow; this file governs *who may approve* and *how permissions are scoped per proposal*.

## Security Gaps Addressed

Two confirmed vulnerabilities in the current implementation motivate this spec:

1. **Approval privilege escalation.** Any user with `patch` permission on `proposalapprovals` can approve a proposal requesting arbitrary RBAC — including cluster-admin-level permissions — regardless of their own authorization level. No validation exists at the API server, operator, or console layer.

2. **Cross-proposal permission leakage.** All proposals share a single `lightspeed-agent` ServiceAccount. RBAC Roles created for one proposal's execution are bound to this shared SA, so concurrent proposals inherit each other's elevated permissions. An analysis step running concurrently with an execution step also inherits the execution's permissions via the same SA.

## Behavioral Rules

### Approval Authorization

1. **Cluster-admin gate.** Only users bound to the `cluster-admin` ClusterRole (or `kubeadmin`) MAY approve proposal execution. This is enforced by Kubernetes RBAC on the `proposalapprovals` resource — no additional webhook or operator-side check is required.

2. **Dedicated approver ClusterRole.** The operator MUST ship a ClusterRole named `agentic-proposal-approver` granting `get`, `list`, `watch`, and `patch` on `proposalapprovals` resources in API group `agentic.openshift.io`. This ClusterRole is the sole grant of `patch proposalapprovals` outside the operator's own manager role.

3. **ClusterRoleBinding to cluster-admin.** The operator MUST ship a ClusterRoleBinding that binds the `agentic-proposal-approver` ClusterRole to the `system:cluster-admins` group (the group that `cluster-admin` ClusterRoleBinding grants). No other ClusterRoleBinding or RoleBinding MAY grant `patch proposalapprovals` to human actors.

4. **Operator manager role.** The operator's own `agentic-operator-manager-role` ClusterRole retains `patch proposalapprovals` because the operator creates and seeds the `ProposalApproval` CR programmatically (see `approval.md` rule 2). This is a service account, not a human actor.

5. **Console UI gate.** The agentic console plugin MUST perform a `useAccessReview` check for `patch` on `proposalapprovals` before rendering the Approve/Deny buttons. If the user lacks the permission, the buttons MUST be hidden or disabled with a tooltip explaining the requirement. This is cosmetic — the API server enforces the real gate — but prevents confusing 403 errors.

6. **Read access for non-admins.** Non-cluster-admin users with `get`/`list`/`watch` on `proposals` and `proposalapprovals` MAY view proposal status and approval state. They MUST NOT be able to modify approval decisions.

### Per-Proposal ServiceAccount Isolation

7. **Ephemeral execution SA.** For each proposal entering the execution phase, the operator MUST create a dedicated ServiceAccount named `ls-exec-{proposal-namespace}-{proposal-name}` (truncated to 63 chars) in the operator namespace. This SA MUST be used as the subject for all execution RBAC bindings (Roles, RoleBindings, ClusterRoles, ClusterRoleBindings) instead of the shared `lightspeed-agent` SA.

8. **SA name truncation.** The per-proposal SA name MUST be truncated to 63 characters using the existing `truncateK8sName` function to comply with Kubernetes naming constraints.

9. **Execution pod assignment.** The execution sandbox pod (bare-pod or sandbox-claim mode) MUST run as the per-proposal SA (`ls-exec-{proposal-namespace}-{proposal-name}`), not as `lightspeed-agent`. The operator passes this SA name to pod spec construction or template derivation.

10. **Read-only SA scope.** Analysis and verification steps use the shared `lightspeed-agent` SA. Since execution RBAC is never bound to `lightspeed-agent` (rule 7), neither step can inherit execution-level permissions from concurrent proposals. The `lightspeed-agent` SA SHOULD be bound to a cluster-reader ClusterRole so that analysis and verification can query cluster state without write access.

11. **SA lifecycle — creation.** The per-proposal SA MUST be created before execution RBAC materialization, in the same reconcile pass as `ensureExecutionRBAC`. If creation fails, the step MUST fail with an error surfaced to proposal conditions.

12. **SA lifecycle — owner reference.** The per-proposal SA MUST carry an owner reference to the Proposal CR (`Controller: true`, `BlockOwnerDeletion: true`) so it is garbage-collected when the Proposal is deleted.

13. **SA lifecycle — cleanup.** On terminal phases (Completed, Denied, Escalated) or Proposal deletion, the operator MUST delete the per-proposal SA alongside the existing RBAC cleanup. This is defense-in-depth — the owner reference handles GC, but explicit cleanup ensures prompt removal of credentials.

14. **Verification SA.** Verification steps use the shared `lightspeed-agent` SA (same as analysis), not the per-proposal execution SA. Verification is a read-only check — it confirms whether the execution's changes took effect but MUST NOT have write access. Escalation steps also use the shared `lightspeed-agent` SA since escalation generates a human-readable summary and does not modify cluster state.

15. **Shared SA retention.** The `lightspeed-agent` SA MUST still be created at operator bootstrap (sandbox-execution.md rule 38) for analysis steps and as a fallback. It MUST NOT have any execution-level Roles or ClusterRoles bound to it.

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-agentic-operator** | ClusterRole/ClusterRoleBinding for approver (RBAC manifests), per-proposal SA creation/cleanup, RBAC binding to per-proposal SA, `defaultSandboxSA` replacement logic |
| **lightspeed-agentic-console** | `useAccessReview` gate on approve/deny buttons |

## Child Spec Updates Required

The following child repo specs describe behavior that this spec supersedes or augments. Each MUST be updated to reflect the new rules:

| Repo | Spec File | Update |
|---|---|---|
| lightspeed-agentic-operator | `what/sandbox-execution.md` rule 21 | RBAC bindings reference per-proposal SA, not shared SA. Update rule 22 to reference per-proposal SA. Add rule for SA creation/cleanup. |
| lightspeed-agentic-operator | `what/sandbox-execution.md` rule 38 | Clarify that `lightspeed-agent` bootstrap SA is for analysis only; execution uses per-proposal SA. |
| lightspeed-agentic-operator | `what/approval.md` | Add rule: `patch proposalapprovals` is restricted to cluster-admin via dedicated ClusterRole/ClusterRoleBinding. Reference this spec. |
| lightspeed-agentic-console | `what/proposal-lifecycle.md` rule 15-18 | Add rule: console MUST check `useAccessReview` before showing approval UI. |
| parent | `what/agentic-proposals.md` Phase 3 | Add note that approval is restricted to cluster-admin and reference this spec. |

## Constraints

- The cluster-admin gate is binary: either you have cluster-admin or you cannot approve. Namespace-scoped approval delegation is out of scope for the current release.
- Per-proposal SA names must be unique across concurrent proposals. Since all per-proposal SAs live in the single operator namespace, the naming convention MUST incorporate the proposal's namespace to avoid collisions when proposals in different namespaces share the same name: `ls-exec-{proposal-namespace}-{proposal-name}` (truncated to 63 chars). This mirrors how execution Role names already include namespace context.
- SA token propagation to an already-running pod is not instant. The SA MUST be created and RBAC MUST be bound before the execution pod is created, not after.

## Planned Changes

| Ticket | Summary |
|---|---|
| [PLANNED] | Namespace-scoped approval delegation: allow non-cluster-admins to approve proposals scoped to namespaces where they have equivalent RBAC. Requires either a ValidatingAdmissionWebhook with SubjectAccessReview or a more granular ClusterRole structure. |
| [PLANNED] | Analysis cluster-reader SA: a fixed `lightspeed-analyst` ClusterRoleBinding with read-only cluster access for analysis steps that need to query cluster state directly. Separate from per-proposal execution SA. |
