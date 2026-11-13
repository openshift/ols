# 0046: HubConfig-Driven Multicluster Lifecycle

**Status:** Accepted lifecycle design, delivered by PR #120 (OLS-4665); implementation planned. Packaging aligned with PR #121 / ADR 0042 through OLS-4432. Exact shared interfaces and OLM permission packaging still require validation.
**Superseded in part:** [ADR 0048](0048-unified-configuration-surface.md) [PLANNED] moves Hub activation and fleet settings from a separate `HubConfig` resource to the presence of an `OLSConfig.spec.hub` section. The drain-before-decommission lifecycle below is retained as intent; its mapping to section removal is not yet designed.
**Date:** 2026-10-29
**Applies to:** lightspeed-operator, lightspeed-hub, lightspeed-agentic-operator, lightspeed-agentic-alerts-adapter

## Context

Multicluster must be explicitly enabled without running a hub controller before opt-in. OLS-4665 originally requires an OLSConfig activation property and leaves controller packaging undecided. The design discussion instead selected HubConfig presence as activation intent and the OLS-operator-managed operand model.

## Decision

- The unified OLS bundle installs hub CRDs, image references, ServiceAccount, and static roles/bindings on supported OCP 4.x and 5.x installations. OLM/bundle solely owns those permissions and retains them while multicluster is inactive. [ADR 0042](0042-unified-olm-bundle-runtime-gating.md) supersedes version-split packaging: OCP 5.0+ is a runtime capability boundary, not a bundle selector. HubConfig does not bypass platform safety or independent, unsuspended AgenticOLSConfig workflow opt-in; Unknown is not unsupported or cleanup intent.
- Do not add the hub as a CSV-managed Deployment. The always-running OLS operator watches HubConfig and deploys/reconciles the hub only when needed for activation or protected shutdown.
- Creating the singleton HubConfig explicitly selects registration mode and activates the hub. No OLSConfig activation property is introduced.
- Secret-mode registrations can be staged before activation but remain inactive. MCE mode discovers all managed clusters by default, with an optional selector limiting ongoing discovery.
- Deleting HubConfig closes new fleet activity, drains existing workflows, decommissions registrations, deletes generated credentials, and removes the hub runtime. Administrator credential Secrets and install-time APIs/RBAC remain.
- Approval-waiting workflows block drain until completed or explicitly cancelled. Never automatically cancel or abandon active workflows for fleet disablement.
- After draining, remote cleanup is best-effort: unreachable spokes do not block decommissioning indefinitely; incomplete cleanup must be reported.
- Individual spoke deletion also drains its existing workflows before removing credentials. Local single-cluster operations remain unaffected.

The [design spec](../../../docs/superpowers/specs/2026-10-29-OLS-4665-on-demand-multicluster-design.md) defines the UX, ownership, failure behavior, verification, and technical follow-ups. The shutdown acknowledgement protocol and exact OLM permission packaging require validation before production implementation; this ADR does not invent existing APIs for them.

## Alternatives considered

1. **OLM-managed hub Deployment:** follows the existing multi-controller CSV pattern, but runs an idle hub process before opt-in. Rejected for the selected no-process-before-activation model.
2. **OLSConfig boolean plus HubConfig:** separates enablement from fleet configuration but adds two-resource activation coordination. Superseded by HubConfig creation as explicit intent.
3. **Runtime installation of hub RBAC:** reduces static resources while inactive but complicates grant authority and ownership. Rejected in favor of installation-owned bounded permissions; no blanket bind/escalate grants.
4. **Retain fleet registrations/configuration on disable:** simpler re-enable, but selected semantics are decommissioning, not pause. Rejected; GitOps must stop reapplying deleted fleet objects when disablement is intended.
5. **Automatic cancellation or indefinite remote-cleanup blocking:** rejected. Drain active workflows first; then use best-effort spoke cleanup.

## Consequences

The OLS operator takes responsibility for hub operand upgrades, self-healing, and lifecycle protection. HubConfig deletion is a destructive fleet operation and must be documented accordingly. The workflow gate spans multiple controllers and must survive crashes, races, and deletion during startup. Static installation permissions remain without a hub pod. Staged registrations do not require activation-aware creation admission.

This amends [ADR 0028](0028-multicluster-architecture.md) for activation/delivery/decommissioning, without changing its hub-managed execution model. It does not replace [ADR 0040](0040-agentic-run-termination.md): graceful fleet draining is not global hard suspension. OLS-4432 aligns the parent and child specifications; behavior remains planned until implemented. Registry-mode changes separately follow OLS-4781: drain affected registrations before unmanagement cleanup, retaining registration CRs and source Secrets. Prerequisite configuration deletion (OLS-4782), durable individual MCE exclusion, and selector/removal policy are outside this phase.
