# 0045: Configurable Multicluster Baseline Roles via Seed-SA Discovery

**Status:** Accepted for planned implementation
**Applies to:** lightspeed-hub, lightspeed-agentic-operator
**Tracking:** OLS-4632

## Context

Remote agentic runs currently copy role references from two hardcoded spoke ClusterRoleBindings. Administrators cannot extend that baseline through the discovery mechanism used by local runs. Resources such as PerformanceProfile and Tuned may require additional reader roles. Configuration belongs at fleet and spoke scope, without a new handoff resource or changes to approval and phase execution.

## Decision

Add optional `HubConfig.spec.agentRBAC.defaultClusterRoles` and `SpokeCluster.spec.agentRBAC.additionalClusterRoles`. The hub resolves their deduplicated union and reconciles owned baseline bindings to the existing spoke seed SA `openshift-lightspeed-managed/lightspeed-agent`. Omitted fleet defaults retain today's two roles; explicit lists replace them, including an empty list. Spoke additions cannot subtract defaults. Referenced ClusterRoles remain administrator-owned.

Replace the agentic operator's hardcoded remote source list with per-spoke discovery of all bindings referencing the exact seed SA, including administrator-created bindings. Independently validate current role rules against the read-only reader policy, then preserve the existing dedicated per-step binding and cleanup flow. No sandbox runs as the seed SA and source bindings are not mutated.

Configured missing/unsafe roles are hub provisioning errors. Unsafe discovered roles are skipped; discovery/read/create failures or no eligible roles prevent phase launch. Cleanup identifies the bindings actually created, not the current configuration. Existing approved execution RBAC is unchanged. Role discovery/eligibility is separate from binding lifecycle so future execution-only role selection can reuse lifecycle mechanics without weakening the reader boundary.

Normative behavior, update limitations, ownership, and acceptance criteria are in [multicluster-agent-rbac.md](../what/multicluster-agent-rbac.md).

## Alternatives Considered

- **Publish resolved roles in a new handoff resource:** explicit, but adds another synchronization contract and entity when existing source bindings already express the grant.
- **Have the agentic operator resolve HubConfig and SpokeCluster:** avoids remote discovery but couples it to hub APIs and duplicates inheritance/validation responsibility.
- **Discover only hub-owned seed bindings:** makes CR configuration exclusive, but introduces a different discovery policy from local mode and removes the administrator-created seed-binding extension.
- **Add phase SAs to shared source bindings:** fewer objects, but changes the existing remote isolation model and introduces concurrent shared-subject mutations.
- **Allow write roles in the all-phase baseline:** rejected because analysis and verification would gain mutation authority outside approved execution.

## Consequences

- No new CRD kinds, handoff ConfigMaps, approval flow, or sandbox contract. Additional roles naturally create additional baseline and dedicated per-step bindings of existing kinds.
- The hub owns fleet/spoke inheritance; the agentic operator owns discovery, phase grants, and cleanup. The standing spoke identity needs discovery and grant authority; this feature does not widen it automatically.
- CR configuration is not an exclusive allowlist because administrator-created seed bindings are supported.
- Configuration removal affects future phase provisioning, not existing dedicated grants. Role edits can change existing permissions through ordinary Kubernetes RBAC; validation is not continuous revocation.
- Remote discovery cannot reuse the process-global local-cluster cache. Cleanup must no longer depend on the hardcoded two-binding count, including during upgrades with legacy bindings.
- Child implementation specs must be aligned when the planned behavior is implemented; this record does not claim that the code has changed.
