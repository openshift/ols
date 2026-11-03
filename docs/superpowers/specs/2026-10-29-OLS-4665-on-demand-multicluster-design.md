# OLS-4665: On-demand multicluster installation experience

## Status and scope

Approved in design discussion on 2026-10-29; all behavior below is **planned**, not a claim of implementation or broader team approval. Tracking: [OLS-4665](https://redhat.atlassian.net/browse/OLS-4665), under OLS-4428. Decision: [ADR 0046](../../../.ai/spec/decisions/0046-hubconfig-driven-multicluster-lifecycle.md).

This design covers the administrator experience through OperatorHub, standard console resource/YAML views, and `oc`. It does not add a hub console plugin or custom setup wizard. Packaging is aligned by OLS-4432 with PR #121 / [ADR 0042](../../../.ai/spec/decisions/0042-unified-olm-bundle-runtime-gating.md): one unified bundle/static API, permission and image set on supported OCP 4.x and 5.x clusters. Completed OCP 5.0+ remains the runtime capability boundary. HubConfig does not bypass platform gating or independent unsuspended AgenticOLSConfig workflow opt-in. Unknown platform state is retryable, not unsupported or cleanup intent.

**Requirement change:** creating the singleton HubConfig is the explicit multicluster opt-in. There is no OLSConfig multicluster activation property. This supersedes the OLSConfig activation requirement currently written in OLS-4665 and the earlier discussion proposal to enable first and configure second. PR #120 delivered this lifecycle decision; OLS-4432 aligns component specifications and delivery contracts without claiming runtime completion.

## Goals and boundaries

- No hub controller process before activation.
- Explicit administrator choice of registration mode.
- Observable startup, configuration failures, draining, and decommissioning.
- No credential or connectivity removal while existing workflows still require them.
- Reversible product installation but destructive fleet disablement: re-enable requires a new HubConfig and new registration/discovery.
- Single-cluster OLS continues operating during fleet activation and shutdown.

The hub remains a fleet-management layer; the existing agentic operator remains the workflow execution engine. This design does not change provider configuration, approval authorization, baseline reader restrictions, or approved execution RBAC.

## Administrator journey

### 1. Install OLS

Install the unified OLS operator bundle and complete normal OLS/LLM-provider configuration. The existing OLS and agentic operator controllers run. The hub APIs and static permissions exist, but the hub controller Deployment does not.

SpokeCluster resources may be staged before HubConfig exists. They cause no provisioning, generated credentials, adapter polling, or fleet workflow execution. No activation-aware admission webhook is required merely to enforce creation order. Existing credential-mode/schema checks remain separate concerns.

### 2. Create HubConfig to activate and configure

Create the cluster-scoped singleton HubConfig named `cluster`, explicitly selecting `spec.clusterRegistryMode`:

- `secret`: supply administrator-owned credential Secrets and create individual SpokeCluster resources.
- `mce`: continuously discover all MCE ManagedClusters by default. An optional `spec.mce.selector.matchLabels` restricts discovery to matching clusters, including future matches.

Documentation and field descriptions must warn that selecting MCE mode without a selector authorizes enrollment of the entire MCE-managed fleet, including future additions. Installing OLS alone never authorizes discovery.

The OLS operator watches HubConfig even when no hub pod exists. It protects the HubConfig lifecycle before creating runtime resources, then creates the hub Deployment. Configuration and spoke processing begin when the controller is available and configuration is accepted.

There is no separate "Waiting for fleet configuration" activation step: HubConfig supplies both activation intent and fleet configuration. Required OLS/agentic prerequisites remain necessary; missing prerequisites are reported rather than bypassed.

### 3. Observe readiness

Use HubConfig status for hub lifecycle progress and SpokeCluster status for individual registrations. Hub readiness means the controller is operational and fleet configuration accepted, not that every spoke is healthy. A fleet with no registered spokes can have a ready hub.

Secret-mode registrations reference supplied credentials. MCE-mode registrations are discovered by the hub. A failed spoke does not make healthy spokes unusable.

### 4. Remove an individual spoke

Deleting a SpokeCluster requests removal, not immediate credential destruction:

1. Stop new enrollment/workflow activity for that deleting registration and stop its adapter polling.
2. Drain workflows already targeting that spoke, retaining access for their remaining phases.
3. Report references to blocking workflows, including those awaiting approval; administrators complete or explicitly cancel them.
4. After draining, attempt spoke-side deprovisioning, delete generated hub credentials, and finalize registration deletion.

Other spokes continue operating. For an MCE-discovered cluster, deleting its registration alone is not a permanent exclusion while it remains eligible for discovery. Durable individual MCE exclusion is a separate follow-up; this design does not promise an exclusion API or remove a cluster from MCE itself.

### 5. Delete HubConfig to disable and decommission

Deleting HubConfig requests fleet-wide shutdown:

1. Stop discovery/enrollment, adapter-generated new work, and execution of newly submitted multicluster workflows.
2. Drain existing multicluster workflows. Do not automatically cancel them. Retain hub/controller resources, credentials, permissions, and connectivity required by their remaining phases.
3. Workflows awaiting human approval remain blockers until completed or explicitly cancelled. There is no automatic drain deadline that abandons them.
4. Decommission all SpokeCluster registrations, including staged registrations present during shutdown, and attempt cleanup of owned spoke-side resources.
5. Remove generated hub-side credentials and complete registration deletion. Preserve administrator-provided credential Secrets.
6. After shutdown acknowledgement, remove hub runtime resources and complete HubConfig deletion. The OLS operator's lifecycle finalizer must keep the request observable until runtime teardown completes.

Deletion is irreversible in the Kubernetes object lifecycle. Updating the terminating HubConfig does not cancel shutdown. Re-creation is possible after deletion completes.

Best-effort remote cleanup applies **only after draining**: unreachable spokes do not block fleet decommissioning indefinitely. Record incomplete remote cleanup, complete hub-side decommissioning, and allow shutdown to finish. This is not permission to abandon active workflows. Hub-side API/permission failures must remain visible and be retried rather than falsely acknowledged as successful cleanup.

Retain the bundle-installed APIs, ServiceAccount, and static RBAC. Remove HubConfig, fleet registrations, generated credentials, and hub runtime resources. Do not delete historical AgenticRuns or their result records as part of this design.

Re-enable by creating a new HubConfig with an explicit mode and discovery scope. No prior fleet configuration automatically resumes. GitOps must stop continuously reapplying HubConfig/registrations if the administrator intends them to stay deleted.

## Packaging and ownership

| Resource or responsibility | Owner | Lifetime |
|---|---|---|
| HubConfig/SpokeCluster CRDs, CSV owned-CRD entries | OLM/bundle; source is lightspeed-hub | OLS installation |
| Hub ServiceAccount, ClusterRoles/ClusterRoleBindings, required namespace Roles/RoleBindings | OLM/bundle | OLS installation; retained while disabled |
| Pinned hub and required adapter image references | Unified OLS bundle | Release |
| Hub image startup argument/environment on OLS operator | CSV OLS deployment configuration | OLS installation |
| Hub Deployment and supporting runtime configuration, NetworkPolicies, applicable Services/monitoring | OLS operator | Activation through shutdown |
| HubConfig lifecycle finalizer and controller availability reporting | OLS operator | HubConfig lifecycle |
| Fleet configuration, discovery, provisioning, generated credentials, dedicated multicluster adapter, drain/decommission coordination | Hub controller | Active fleet and shutdown |
| Workflow admission/execution gate and per-run resource cleanup | Agentic operator, coordinated with hub | Activation and workflow lifetime |
| Polling/new-event suppression during drain | Adapters, coordinated with hub | Active fleet and shutdown |

The CSV must not list the hub Deployment among its install deployments. OLM starts/upgrades the OLS and agentic operators; the OLS operator reconciles hub operand image/configuration updates and self-heals its runtime resources.

Hub CRDs and RBAC definitions are synced from lightspeed-hub at a pinned revision. Images belong in the unified related-image set for disconnected mirroring, and must also be passed to their runtime deployer; `relatedImages` alone is not runtime wiring. Honor existing image override conventions.

Prefer namespace-scoped grants for credentials and adapter Deployments; reserve cluster permissions for cluster-scoped APIs and necessary discovery. Review generated hub RBAC rather than copying every grant unquestioningly. Do not introduce blanket `bind`, `escalate`, or `cluster-admin` to make runtime role creation work. Exact MCE permissions require validation. Hub-cluster RBAC does not grant remote spoke authority; Secret/MCE credential identities supply that authority.

OLM/bundle is the sole owner of static hub RBAC; the OLS operator must not also reconcile or delete it. Validate CSV `clusterPermissions`/`permissions` handling of a ServiceAccount not used by a CSV-managed Deployment. If necessary, use a supported explicit bundle resource arrangement with the same ownership/lifetime.

## Status, errors, and recovery

These are user-facing lifecycle concepts, not finalized condition identifiers:

| State | Meaning and action |
|---|---|
| Starting | OLS operator is deploying the hub; inspect deployment diagnostics if startup fails |
| Configuration blocked | Configuration/prerequisites cannot be used, for example missing MCE services; correct the cause without recreating HubConfig |
| Ready | Controller available and configuration accepted; inspect individual SpokeCluster conditions separately |
| Draining | New fleet work stopped; status names blocking workflow references, including approval waits |
| Decommissioning | Workflows drained; registration and generated-resource cleanup underway |
| Cleanup incomplete | Remote resources may remain; record spoke identity and failure details before best-effort completion |

The OLS operator owns deployment-availability conditions; the hub owns fleet/drain/decommission conditions. Use non-overlapping condition ownership and conflict-safe status writes. Preserve existing spoke connection/provisioning/adapter condition distinctions.

Startup/configuration errors are retried and remain actionable. During deletion, reconcile only shutdown work; do not resume enrollment after a controller restart. Keep/recreate the controller when needed to complete shutdown, including deletion requested during startup. Do not attach an unprotected garbage-collection dependency that destroys the hub before draining completes.

Logs and Warning Events must identify incomplete remote cleanup before registrations/HubConfig disappear. Events have limited retention; deleted resource status is not a permanent cleanup record. This design does not claim a durable cleanup report API.

## Cross-controller safety contract

A finalizer alone does not drain workflows. Implementation must provide a gate and completion acknowledgement across the OLS operator, hub, agentic operator, and adapters:

- Cover manual submissions as well as adapter-generated AgenticRuns; controller-side enforcement must prevent new execution even if submission races the gate.
- Distinguish previously admitted workflows that may finish from new work that may not start; treat pending, approval-waiting, and later-phase transitions consistently.
- Preserve remaining phases and necessary credentials for existing workflows. Finalize drain only when their workload and credential-consuming cleanup is complete, not merely from a terminal phase label.
- Individual spoke deletion gates only its target; HubConfig deletion gates the fleet. Single-cluster execution is unaffected.
- Coordinate completion using identity-aware, restart-safe evidence so stale acknowledgement from an earlier object incarnation cannot authorize teardown.
- Missing configuration while inactive never authorizes fleet execution. A terminating configuration never authorizes enrollment or new work.

Graceful drain is distinct from [global suspension/per-run cancellation](../../../.ai/spec/what/agentic-run-termination.md). Do not implement it by globally suspending AgenticOLSConfig: that hard-stops workloads and affects single-cluster work. Explicit administrator cancellation continues to use its existing termination contract; drain does not weaken confirmed-teardown requirements.

## Verification

Hub-only integration/E2E checks:

1. Unified installation creates APIs/static RBAC on supported OCP 4.x/5.x but no hub Deployment. Validate completed-version gating, Unknown preservation/retry, and independent workflow opt-in; static API presence is not activation.
2. Staged registrations cause no provisioning or fleet execution.
3. HubConfig creation deploys the hub; startup/configuration failures recover after correction.
4. Explicit modes and MCE default-all/selector behavior include ongoing discovery.
5. Status ownership remains consistent under concurrent reconciliation.
6. Deletion during startup, repeated reconciliation, restarts, and upgrades cannot bypass finalizers, restart enrollment, or prematurely remove the controller.
7. Completed teardown removes runtime resources and user fleet CRs but preserves static RBAC and administrator Secrets; re-creation requires fresh HubConfig intent.
8. Validate permission-only OLM ServiceAccount packaging, image wiring/mirroring, image overrides, and upgrade rollouts.

Real-spoke lifecycle checks:

9. Manual and adapter run races cannot start new fleet workflows after the gate closes; existing workflows can complete all phases.
10. Approval-waiting workflows block drain and are named; explicit cancellation follows confirmed teardown before credentials disappear.
11. Individual deletion drains its spoke without disrupting other spokes or local workflows.
12. After draining, unreachable-spoke cleanup completes best-effort with warnings; reachable-spoke resources are actually removed.
13. Hub-side cleanup failures are retried, not hidden by remote best-effort policy.
14. Generated credentials remain available through run cleanup, then are removed; source credential Secrets remain.

Use the existing [multicluster testing split](../../../.ai/spec/what/multicluster-testing.md): OLS-4639 owns installed-bundle/hub-only checks; OLS-4788 owns real-spoke lifecycle checks. Fake-client/hub-only tests do not prove real cross-cluster drain or cleanup safety.

## Delivery contracts and mode-change refinement [PLANNED]

OLS-4659 owns APIs; OLS-4784 static permissions; OLS-4429/4430 images/pinned CRDs; OLS-4661 protected runtime and final removal. OLS-4660 defines and implements shared tested coordination, with S0 review of admitted-run boundaries, condition writers, identity/freshness, cleanup completion and restart-safe acknowledgement before dependent execution. OLS-4785 implements new-work gates, OLS-4786 individual drain, and OLS-4787 fleet decommission/completion. These are not approved wire identifiers or evidence of implementation; validate configuration/status examples against finalized APIs and S0–S4 evidence.

OLS-4781 refines registry-mode changes: gate/drain newly ineligible registrations with old-source access intact, then clean generated resources and report unmanagement while retaining SpokeCluster CRs/source Secrets. Matching spokes continue and a later matching mode can reprovision retained registrations. Repeated changes, readoption and discovery must reject stale cleanup. Do not replace this with ignore-without-cleanup, fleet replacement, or a requirement to delete all registrations first.

OLS-4782 prerequisite OLSConfig/AgenticOLSConfig deletion is outside this phase, not a blocker or approval of cascading shutdown. General uninstall/recovery, credential migration, selector narrowing, ManagedCluster removal and durable individual MCE exclusion remain separate scope.

## Implementation gaps and follow-up responsibilities

These are explicit technical follow-ups, not claims of approved wire protocols or assigned individual owners:

| Follow-up | Responsible component/team | Required outcome |
|---|---|---|
| Align component specs (OLS-4432) | Respective repo maintainers | Reference delivered PR #120/#121 decisions and approved task decomposition; retain historical context with explicit superseding corrections |
| Validate install-time RBAC and unified assets (OLS-4784) | OLS operator packaging maintainers | Supported OLM resource layout, bounded permissions, pinned asset sync, disconnected-image tests |
| Specify shutdown gate/acknowledgement and run boundary | Hub and agentic operator maintainers | Reviewable API/condition ownership, identity/freshness rules, race/restart tests before production implementation |
| Implement HubConfig-driven operand reconciliation | OLS operator maintainers | Watches, lifecycle protection, availability/status, upgrades, self-healing, runtime teardown |
| Replace immediate cleanup with drain-first behavior | Hub, agentic operator, adapter maintainers | Individual and fleet drain, safe credential ordering, admission/execution guards |
| Verify/extend remote cleanup diagnostics | Hub maintainers | Reuse delivered OLS-4158 error/Event propagation; cover drain/decommission warnings before CR deletion and remaining diagnostic gaps |
| Align child specs | Respective repo maintainers | Replace Helm delivery and immediate HubConfig unmanage assumptions; document MCE/default-all support and workflow guards |
| Define durable individual MCE exclusion separately | Hub maintainers | Avoid promising permanent removal by deleting an auto-discovered registration |

Implementation inventory must distinguish checkout age from delivered upstream work. Upstream `internal/controller/spokecluster_controller.go` still calls cleanup directly on deletion/unmanagement without shared drain; this is the ordering to replace. OLS-4158 is closed and upstream propagates Deprovision/DeprovisionAdapter errors into cleanup warnings; do not describe all diagnostics as missing because an older checkout retains an obsolete follow-up comment. OLS-4263/4264 image build/release work is closed; bundle inclusion/runtime propagation is separate. OLS-4283 gone-spoke run-deletion fallback is closed and must be reused/verified, not treated as a substitute for drain. MCE discovery (OLS-3954) remains a target requirement rather than assumed shipped support.
