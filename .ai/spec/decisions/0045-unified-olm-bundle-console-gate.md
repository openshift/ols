# 0045: Unified OLM Bundle with an Agentic Console Version Gate

**Status:** Accepted design; console-only operator change and release migration pending
**Applies to:** lightspeed-operator, Konflux/FBC release configuration
**Jira:** OLS-4007 (epic); OLS-4348, OLS-4349, OLS-4351, OLS-4352 (implementation and migration)
**Supersedes:** [0037: Agentic Version Gating](0037-agentic-version-gating.md)

## Context

The earlier OLS-3899 design split Classic and Agentic into v1 and v2 OLM bundles, with the full Agentic layer absent on OCP 4.x. OLS-4007 replaces that release model with one unified bundle for supported OCP 4.x and 5.x catalogs. OLM therefore installs both controllers, agentic CRDs, and static RBAC on 4.x as well as 5.x.

The only OCP-version restriction is that the **agentic console plugin must not come up on 4.x**. The agentic backend must not be gated by cluster version or by the presence of `AgenticOLSConfig`: the agentic-operator's broad gate from PR #546 was reverted by PR #559. The Classic operator's existing broader gate still needs to be narrowed to console-only; this specification does not claim that work is merged.

## Decision

Use one unified `lightspeed-operator` OLM bundle and one bundle release stream for Classic and Agentic. The bundle contains one CSV with both controller deployments, their CRDs and static RBAC, required webhook resources, and the complete related-image set. Per-OCP-version FBC catalogs may remain, but each supported catalog must consume the same released unified bundle digest. The Classic-only v1 bundle remains a migration source until release validation and retirement are approved.

[PLANNED: OLS-4349] The Classic operator applies the completed-OCP-version check **only to agentic console resources** (including its Deployment, ConsolePlugin registration/activation, and supporting resources):

1. On a confirmed completed OCP 5.0+ version, reconcile the agentic console when its image is configured.
2. On a confirmed completed OCP 4.x version, do not deploy or activate the agentic console; remove any previously reconciled agentic console resources so the plugin is not visible. The Classic chat console is unaffected.
3. When the cluster version is unreadable, incomplete, or mismatched, do not introduce or activate the agentic console; retry the version check. Do not interpret uncertainty as a confirmed 4.x version or use it to gate the backend.

The version check MUST NOT prevent the agentic-operator from processing AgenticRuns or require `AgenticOLSConfig` as an opt-in. It MUST NOT gate the alerts adapter (when configured), Classic-to-Agentic handoff ConfigMap, agentic client CA Secrets, or other backend resources. Normal configuration opt-outs and explicit deletion cleanup still apply independently of cluster version. `AgenticOLSConfig.spec.suspended` retains its separate, explicit hard-stop semantics; an absent AgenticOLSConfig means `suspended=false`.

## Migration and release gates

- **OLS-4348:** product strategy and approval criteria for retiring Classic v1.
- **OLS-4349:** unified bundle composition and console-only OCP-version gating in the Classic operator; no backend version gate.
- **OLS-4351:** real-cluster install/upgrade/downgrade tests: on 4.x the agentic console is absent while backend workflows and configured supporting resources can run; on 5.x the console can activate. Validate v1→unified and prior full-bundle→unified migration where applicable.
- **OLS-4352:** FBC/Konflux cutover and v1 retirement after validating the same unified bundle digest in supported catalogs and documenting migration/rollback.

Do not infer release readiness or a supported downgrade path from bundle-generation tests alone.

## Alternatives considered

- **Keep separate v1/v2 bundles:** rejected for the consolidated release model because it duplicates bundle and catalog release paths.
- **Gate the whole Agentic runtime on OCP version or AgenticOLSConfig presence:** rejected; PR #546's backend gate was reverted. OCP 4.x must only hide the agentic console, not disable backend workflows.
- **Use catalog selection to hide the agentic console:** rejected because supported catalogs consume the same unified bundle; the console is an operator-reconciled operand.

## Consequences

- Agentic controller infrastructure, APIs, and static RBAC may be present on OCP 4.x, and backend runs are not blocked solely by OCP version.
- Agentic console absence on 4.x is a Classic-operator reconciliation and E2E invariant, not a bundle-membership invariant.
- Cross-version migration, console cleanup, and v1 retirement require real-cluster validation before release.
