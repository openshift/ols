# 0042: Unified OLM Bundle with Runtime Agentic Gating

**Status:** Accepted design; release migration in progress
**Applies to:** lightspeed-operator, lightspeed-agentic-operator, Konflux/FBC release configuration
**Jira:** OLS-4007 (epic); OLS-4348–OLS-4352 (implementation and migration)
**Supersedes:** [0037: Agentic Version Gating](0037-agentic-version-gating.md)

## Context

The earlier OLS-3899 design split Classic and Agentic into v1 and v2 OLM bundles, selected by OCP-version compatibility and published through separate release paths. The unified-bundle work in OLS-4007 replaces that design. The operator source on upstream main generates one bundle containing both controllers, their combined CRDs/RBAC, and all required related images. The same unified bundle digest is the target for supported OCP 4.x and 5.x catalogs after migration; existing catalog history may still contain Classic-only releases.

A single bundle means OLM no longer removes the agentic controller, CRDs, or static RBAC from 4.x clusters. Compatibility is therefore enforced at runtime. Installing the bundle must not by itself enable AgenticRun workflow execution: that requires an explicitly created, unsuspended `AgenticOLSConfig` and an independently validated agentic-controller version gate. The Classic operator may still deploy configured Agentic console/adapter operands and publish the handoff on a matching completed OCP 5.0+ version without checking for `AgenticOLSConfig`. OCP-version gating selects runtime capability; it does not select a different bundle.

The operator source on upstream main generates a unified bundle and has a Classic-side tri-state runtime gate. This does not by itself prove that the Agentic controller's runtime gate, cross-version migration, release catalog cutover, or downgrade cleanup have been validated. Do not infer release readiness or a supported downgrade path from bundle-generation tests alone.

## Decision

Use one unified `lightspeed-operator` OLM bundle and one bundle release stream for Classic and Agentic. The bundle contains one CSV with the Classic and Agentic controller deployments, the union of their CRDs and static RBAC, required webhook resources, and the complete related-image set. Do not introduce a second bundle variant, package, or version-partitioned bundle release Application.

Retain per-OCP-version FBC catalogs where the product release process requires them, but have each supported catalog consume the same released unified bundle digest. The compatibility metadata and catalog contents must be validated for every supported OCP version before publication. The old Classic-only v1 bundle remains a migration source until the product validation and retirement gates are met; no retirement date is implied by this decision.

At runtime:

1. The unified bundle may be installed on supported OCP 4.x and 5.x clusters. OLM installs the same CSV and static API/RBAC surface on each.
2. The operator derives an explicit three-state gate from the `config.openshift.io/v1` `Version`/`ClusterVersion` resource and its completed update history:
   - **Enabled**: the latest update is `Completed`, its version matches `status.desired.version`, and the completed version is OCP 5.0 or newer. Classic-side Agentic operand reconciliation proceeds according to configured images and CR fields; AgenticRun workflow execution separately requires explicit `AgenticOLSConfig` creation and an independently validated agentic-controller gate.
   - **Disabled**: the same completed-version checks succeed, but the completed OCP version is earlier than 5.0. During normal reconciliation, the operator MUST NOT create, update, or delete Agentic operands or Agentic CA Secrets. Existing Agentic resources are left as-is (although their presence on OCP 4.x is unexpected), and the operator may report the known `UnsupportedOCPVersion` state. The gate prevents introducing new operands.
   - **Unknown**: the Version resource cannot be read, is missing, or does not establish a matching completed version (including an in-progress upgrade or invalid/incomplete status). During normal reconciliation, the operator MUST NOT create, update, or delete Agentic operands or Agentic CA Secrets, MUST NOT report `UnsupportedOCPVersion` based only on this uncertainty, and MUST requeue to retry. Existing Agentic resources and their status are preserved while the state is Unknown. Explicit OLSConfig deletion is handled by the finalizer before this gate is read; deletion cleanup is not blocked by Unknown.
3. Agentic controller processes and admission infrastructure may be present on OCP 4.x, but agentic workflows and agentic operands MUST remain inactive there. A successfully read, matching completed OCP 5.0+ version is necessary but not sufficient for AgenticRun workflow execution. An explicitly created, unsuspended `AgenticOLSConfig` is the workflow opt-in; reaching OCP 5.0 alone does not opt the customer into workflow execution, although Classic may reconcile configured Agentic console/adapter operands and the handoff on 5.0+.
4. Version-read failures and incomplete/mismatched update status MUST NOT be collapsed into Disabled. Unknown is a retryable state, not evidence that the cluster is unsupported. Normal reconciliation uses one Version snapshot per OLSConfig reconcile so all Agentic decisions are consistent; explicit finalizer cleanup runs first and does not depend on this snapshot.
5. When the gate is Enabled, explicitly disabling Agentic configuration may trigger the applicable cleanup path. Cleanup requirements include AgenticRun workloads/access/finalizers and Classic-to-Agentic handoff resources. Neither Disabled nor Unknown may trigger version-gate cleanup; Disabled preserves existing operands, while Unknown also requeues because the version is not established. Explicit OLSConfig deletion remains a separate finalizer-driven cleanup. Preserving operands on a known OCP 4.x version does not establish a supported or safe downgrade path.

## Migration and release gates

- **OLS-4348:** product strategy, validation gates, and approval criteria for retiring Classic v1.
- **OLS-4349:** unified bundle composition plus Classic and Agentic runtime gating.
- **OLS-4350:** idempotent cleanup on explicit Agentic disable, including active AgenticRun resources, finalizers, and handoff state; version-gate Disabled/Unknown states must not mutate existing Agentic resources.
- **OLS-4351:** real cross-version install, upgrade, downgrade, and migration testing, including v1→unified and prior full-bundle→unified paths where applicable.
- **OLS-4352:** FBC/Konflux cutover and v1 retirement. Verify the same new bundle digest is referenced by all supported catalogs, catalog validation succeeds, and migration/rollback instructions are documented.

Do not treat a generated or published unified bundle as evidence that the release migration gates are satisfied, or retire v1 without the required validations. Successful local bundle validation is not evidence that cross-version upgrade/downgrade or real-cluster cleanup is safe.

## Alternatives considered

- **Keep separate v1/v2 bundles:** rejected for the consolidated release model because it preserves duplicate bundle build/release and catalog-membership complexity.
- **Gate solely by OCP-version catalog selection:** rejected because there is one bundle artifact for the supported catalogs; runtime behavior is gated inside the controllers.
- **Enable AgenticRun execution solely because the cluster is OCP 5.0+:** rejected because an explicit, unsuspended `AgenticOLSConfig` is required.
- **Treat CR creation as sufficient without a version safety gate:** rejected because unsupported or partially upgraded clusters must fail closed.

## Consequences

- One bundle source, CSV, image set, and bundle release stream replace the v1/v2 bundle variants.
- Agentic CRDs/RBAC and controller infrastructure are present in the unified bundle even on OCP 4.x; the old invariant that OCP 4.x has no agentic APIs/RBAC no longer applies.
- Runtime gates and cleanup paths become compatibility-critical security and lifecycle controls.
- OCP-version-specific FBC Applications may remain, but they must resolve to the identical unified bundle digest after cutover.
- Migration, downgrade cleanup, cross-version e2e testing, and v1 retirement remain release blockers until validated.
