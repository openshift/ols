# OLS-4665: On-demand multicluster installation experience

## Status and scope

Approved in design discussion on 2026-10-29; all behavior below is **planned**, not a claim of implementation or broader team approval. Tracking: [OLS-4665](https://redhat.atlassian.net/browse/OLS-4665), under OLS-4428. Decision: [ADR 0046](../../../.ai/spec/decisions/0046-hubconfig-driven-multicluster-lifecycle.md).

This design covers the administrator experience through OperatorHub, standard console resource/YAML views, and `oc`. It does not add a hub console plugin or custom setup wizard. Delivery is through the OLS v2 bundle for OCP 5.0+, retaining the v1/v2 boundary in [ADR 0037](../../../.ai/spec/decisions/0037-agentic-version-gating.md).

**Requirement change:** creating the singleton HubConfig is the explicit multicluster opt-in. There is no OLSConfig multicluster activation property. This supersedes the OLSConfig activation requirement currently written in OLS-4665 and the earlier discussion proposal to enable first and configure second. The Jira ticket has not been updated by this document.

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

Install the v2 OLS operator bundle and complete normal OLS/LLM-provider configuration. The existing OLS and agentic operator controllers run. The hub APIs and static permissions exist, but the hub controller Deployment does not.

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
| Pinned hub and required adapter image references | OLS v2 bundle | Release |
| Hub image startup argument/environment on OLS operator | CSV OLS deployment configuration | OLS installation |
| Hub Deployment and supporting runtime configuration, NetworkPolicies, applicable Services/monitoring | OLS operator | Activation through shutdown |
| HubConfig lifecycle finalizer and controller availability reporting | OLS operator | HubConfig lifecycle |
| Fleet configuration, discovery, provisioning, generated credentials, dedicated multicluster adapter, drain/decommission coordination | Hub controller | Active fleet and shutdown |
| Workflow admission/execution gate and per-run resource cleanup | Agentic operator, coordinated with hub | Activation and workflow lifetime |
| Polling/new-event suppression during drain | Adapters, coordinated with hub | Active fleet and shutdown |

The CSV must not list the hub Deployment among its install deployments. OLM starts/upgrades the OLS and agentic operators; the OLS operator reconciles hub operand image/configuration updates and self-heals its runtime resources.

Hub CRDs and RBAC definitions are synced from lightspeed-hub at a pinned revision. Images belong in the v2 related-image set for disconnected mirroring, and must also be passed to their runtime deployer; `relatedImages` alone is not runtime wiring. Honor existing image override conventions.

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

1. v2 installation creates APIs/static RBAC but no hub Deployment; v1 contains no new multicluster assets.
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

Use the existing [multicluster testing split](../../../.ai/spec/what/multicluster-testing.md): fake-client tests do not replace real cross-cluster lifecycle checks.

## Implementation gaps and follow-up responsibilities

These are explicit technical follow-ups, not claims of approved wire protocols or assigned individual owners:

| Follow-up | Responsible component/team | Required outcome |
|---|---|---|
| Align OLS-4665 and related packaging/lifecycle tasks | Spike/product maintainers | Replace OLSConfig activation requirement, record this design and team decision status; revisit OLS-4638/4661 assumptions |
| Validate install-time RBAC and v2 assets | OLS operator packaging maintainers | Supported OLM resource layout, bounded permissions, pinned asset sync, disconnected-image tests |
| Specify shutdown gate/acknowledgement and run boundary | Hub and agentic operator maintainers | Reviewable API/condition ownership, identity/freshness rules, race/restart tests before production implementation |
| Implement HubConfig-driven operand reconciliation | OLS operator maintainers | Watches, lifecycle protection, availability/status, upgrades, self-healing, runtime teardown |
| Replace immediate cleanup with drain-first behavior | Hub, agentic operator, adapter maintainers | Individual and fleet drain, safe credential ordering, admission/execution guards |
| Complete remote cleanup diagnostics | Hub maintainers | Surface deprovision errors beyond current log-only paths; warn before deleting CRs |
| Align child specs | Respective repo maintainers | Replace Helm delivery and immediate HubConfig unmanage assumptions; document MCE/default-all support and workflow guards |
| Define durable individual MCE exclusion separately | Hub maintainers | Avoid promising permanent removal by deleting an auto-discovered registration |

Current local code deletes spoke credentials directly during decommission without checking active workflows. The child hub spec also describes preserving SpokeCluster CRs on HubConfig deletion; this planned design deliberately replaces that behavior with fleet decommissioning. The current local reconciler supports Secret registration and rejects unsupported modes; this document's MCE journey is a target requirement, not evidence that MCE discovery is shipped.
