# Multicluster Agent Baseline RBAC

**Status:** All requirements below are [PLANNED: OLS-4632]; this document does not assert implementation.
**Decision:** [ADR 0045](../decisions/0045-multicluster-agent-baseline-rbac.md).

## Purpose and Scope

Allow fleet administrators to configure read-only baseline ClusterRoles for hub-managed agentic runs, with additive spoke-specific roles. PerformanceProfile and Tuned inspection are motivating examples: administrators can supply reader roles for resources not covered by the built-in baseline.

This cross-repo contract augments [multicluster operations](multicluster-ops.md). For remote baseline permissions, it supersedes descriptions of a fixed two-binding list or mutation of shared reader binding subjects. Local-run behavior is unchanged.

## API and Inheritance

1. `HubConfig.spec.agentRBAC.defaultClusterRoles` is an optional list of existing spoke ClusterRole names. Omission selects `cluster-reader` and `cluster-monitoring-view`. An explicit list replaces those defaults; an explicit empty list selects no fleet baseline roles. The API MUST preserve the omitted-versus-empty distinction; defaulting MUST NOT turn an explicit empty list into the built-in defaults.
2. `SpokeCluster.spec.agentRBAC.additionalClusterRoles` is an optional list of existing spoke ClusterRole names. Omission or an empty list adds nothing. Spokes cannot subtract fleet defaults.
3. The effective configured roles for a spoke are the deduplicated union of fleet defaults and spoke additions. Ordering MUST NOT change the effective grants or make cleanup dependent on list positions. Entries MUST be valid ClusterRole object names; empty names are rejected. Duplicate names MUST NOT create duplicate grants.
4. Fields reference ClusterRoles, not ClusterRoleBindings or inline policy rules. Administrators MUST install custom ClusterRoles on each applicable spoke. Operators MUST NOT create, edit, or delete those role definitions through this feature.

```yaml
# Fleet configuration fragment
spec:
  agentRBAC:
    defaultClusterRoles:
      - cluster-reader
      - cluster-monitoring-view
```

```yaml
# Spoke configuration fragment
spec:
  agentRBAC:
    additionalClusterRoles:
      - performance-profile-reader
      - tuned-reader
```

## Hub Responsibilities

5. Using the standing spoke credentials, the hub resolves the effective configured roles and provisions baseline ClusterRoleBindings on that spoke. Each binding references one effective ClusterRole and names ServiceAccount `openshift-lightspeed-managed/lightspeed-agent` as its subject. That SA is a discovery seed, not a sandbox or controller identity.
6. Baseline bindings MUST have deterministic, collision-safe identities and ownership metadata. Existing default source binding names (`lightspeed-hub:cluster-reader` and `lightspeed-hub:cluster-monitoring-view`) SHOULD remain stable. An administrator-owned binding collision MUST surface an error, not be silently adopted or overwritten. Reconciliation MUST converge, repair owned binding drift, add missing owned bindings, and delete obsolete owned baseline bindings. It MUST NOT alter administrator-owned bindings or ClusterRoles.
7. HubConfig changes MUST trigger reconciliation of all managed spokes; SpokeCluster changes MUST reconcile that spoke. This applies to both supported registration sources; auto-discovery MUST preserve administrator-configured spoke additions. No operator restart is required.
8. The hub MUST validate all effective configured roles, including the built-in defaults when the fleet list is omitted, against the reader policy below. A missing or unsafe configured role MUST set `Provisioned=False` with an actionable reason/message naming the role and cause. Successful baseline provisioning MUST NOT be reported for a partial or invalid configured role set. API or authorization failures MUST also be surfaced and retried through existing reconciliation handling. This is not an atomic fleet-wide update or a revocation guarantee for existing runs.
9. Spoke decommission and HubConfig deletion MUST clean up all hub-owned baseline bindings, including custom-role bindings, without deleting administrator-owned bindings or role definitions.

## Agentic Operator Responsibilities

10. For every remote phase (analysis, execution, verification, escalation), discover ClusterRoleBindings on the target spoke whose subjects include the exact seed SA name and namespace. Replace the hardcoded remote source-binding list; do not use the process-global local-cluster discovery cache. Read discovery and eligibility at step provisioning; no new long-lived cache or watch is required.
11. Discovery MUST include eligible administrator-created seed bindings as well as hub-owned bindings. The CR fields therefore define the hub-managed baseline, not an exclusive allowlist of effective sandbox access. Bindings to a same-named SA in another namespace MUST NOT qualify.
12. Before granting access, read each referenced ClusterRole's current effective rules and apply the reader policy. Eligibility MUST NOT rely on a stale cached verdict, including for aggregated ClusterRoles. An unsafe discovered role MUST be skipped with a log naming the source binding and disqualifying permission. API/read failures or a missing referenced role MUST fail setup rather than be treated as an empty or safe policy.
13. For each distinct eligible RoleRef discovered through the source bindings, create a dedicated per-step ClusterRoleBinding with that RoleRef and only the phase's ephemeral SA as subject. Source bindings MUST NOT be modified. Bindings MUST be isolated by run UID and step, with ownership labels sufficient for cleanup; binding identities MUST NOT rely on the current list length/order. Duplicate effective role references MUST NOT produce redundant grants. Existing deterministic objects MUST be checked for the expected role and subject before reuse; a collision MUST NOT be accepted as successful provisioning.
14. Complete baseline provisioning before launching the phase sandbox. Discovery, role-read, or binding-creation failures MUST prevent sandbox launch and use existing run error/retry handling. Partial setup MUST be rolled back or remain discoverable for retryable cleanup. No eligible baseline bindings MUST produce an actionable setup error; an explicitly empty fleet list is valid but requires an eligible spoke addition or administrator-created seed binding for a run to start.
15. Cleanup MUST delete the dedicated bindings actually associated with the run/step, independently of current HubConfig, SpokeCluster, source-binding existence, or source ordering. Ownership labels or durable tracking MUST support cleanup after controller restart, including legacy dedicated bindings from the fixed-list path. Treat NotFound as success; retry other cleanup failures. Never delete another run's bindings or source bindings. Terminal/deletion and stop-triggered revocation retain the existing [termination contract](agentic-run-termination.md).

## Reader Security Policy

16. Baseline grants MUST be read-only: every effective rule grants only `get`, `list`, or `watch`. Any other verb, including `*`, disqualifies the whole role. Roles MUST NOT grant access to core Secrets or any `rbac.authorization.k8s.io` resource. Wildcard API-group/resource matches that cover those resources MUST also be rejected; normalizing the core API group MUST NOT permit bypasses. Reuse the reader-policy boundary specified in agentic-operator `what/sandbox-execution.md` rule 21a rather than introducing a weaker remote policy.
17. Hub validation and independent step-time validation are both required. Invalid configured roles are provisioning errors; unsafe manually discovered bindings are skipped. These checks are preflight validation, not continuous enforcement: an administrator changing a referenced ClusterRole can change permissions of existing bindings through normal Kubernetes RBAC. Custom role administration remains a privileged action.
18. The standing identity is separate from the baseline seed and ephemeral SAs. In secret registration mode it retains the administrator-supplied kubeconfig identity. It needs list/get access for source bindings and referenced roles, permission to manage the required bindings/SAs and request tokens, and authority to grant the requested roles under Kubernetes bind/escalation prevention. This feature MUST NOT automatically grant cluster-admin or otherwise widen the standing identity. Insufficient authority MUST surface as an actionable error.

## Updates and Execution Boundary

19. Baseline bindings are discovered at each new phase setup, not snapshotted for the whole run. Changes can therefore affect later phases of an existing run. Removing a source binding affects future setup but does not revoke an already-created per-step binding. Immediate revocation on configuration changes is out of scope. A transient reconciliation gap MUST NOT be represented as an atomic update guarantee.
20. Execution receives the same eligible baseline reads plus the existing approved remediation RBAC. Existing namespace-scoped Roles/RoleBindings and cluster-scoped ClusterRoles/ClusterRoleBindings generated from the approved option remain unchanged. Analysis, verification, and escalation MUST NOT inherit those execution-only grants.
21. Future execution-role selection MAY reuse dedicated-binding lifecycle mechanics but MUST use a separate permission-selection and authorization policy. Write roles MUST NOT be routed through this all-phase reader seed. No execution-role fields, new CRDs, resolved-role ConfigMaps, sandbox changes, approval changes, or UI controls are introduced by OLS-4632.

## Acceptance and Verification

22. Hub API/reconciliation tests MUST cover omission versus explicit empty/default replacement, additive spoke roles, duplicates, deterministic identities, configuration updates without restart, custom role absence/unsafety, ownership collisions, drift repair, and cleanup without deleting administrator resources. Cover preservation of additions on auto-discovered spokes.
23. Agentic-operator tests MUST cover per-spoke discovery isolation; exact seed matching; administrator-created bindings; reader restrictions including wildcard and aggregated-role changes; read/list/create authorization errors; no eligible roles; partial setup; concurrent runs; restart-safe and configuration-independent cleanup; legacy fixed-list bindings; and unchanged local/execution behavior.
24. Cross-cluster tests MUST demonstrate custom-resource inspection using an eligible role on one spoke without granting that access to another spoke; baseline access for every phase; execution-only writes after approval; and removal of each step's dedicated bindings without modifying sources. PerformanceProfile/Tuned read access SHOULD be verified on an OpenShift-capable tier; the mock-agent tier can use a test CRD and reader role. See [multicluster testing](multicluster-testing.md).

## Ownership and Implementation Navigation

| Repo | Responsibility | Existing navigation / child specs to align during implementation |
| --- | --- | --- |
| lightspeed-hub | API inheritance, validation, owned baseline reconciliation and decommission | `api/v1alpha1/{hubconfig,spokecluster}_types.go`, `internal/provisioner/spoke.go`; `.ai/spec/what/system-overview.md`, `what/spoke-lifecycle.md` |
| lightspeed-agentic-operator | Remote discovery, eligibility, per-step grants and cleanup | `controller/agenticrun/rbac.go`, `sandbox_manager.go`; `.ai/spec/what/sandbox-execution.md`, `how/reconciler.md` |

The child specs' fixed-list and shared-subject-mutation descriptions are superseded for this planned remote contract; they MUST be aligned when implementation lands. This change adds no implementation code or implementation plan.
