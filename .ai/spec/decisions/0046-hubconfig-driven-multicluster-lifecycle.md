# 0046: HubConfig-Driven Multicluster Lifecycle

**Status:** Accepted in design discussion; implementation planned (OLS-4665). Broader team review and Jira requirement alignment remain necessary.
**Date:** 2026-10-29
**Applies to:** lightspeed-operator, lightspeed-hub, lightspeed-agentic-operator, lightspeed-agentic-alerts-adapter

## Context

Multicluster must be explicitly enabled without running a hub controller before opt-in. OLS-4665 originally requires an OLSConfig activation property and leaves controller packaging undecided. The design discussion instead selected HubConfig presence as activation intent and the OLS-operator-managed operand model.

## Decision

- The OCP 5.0+ v2 bundle installs hub CRDs, image references, ServiceAccount, and static roles/bindings. OLM/bundle owns those permissions and retains them while multicluster is inactive.
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

This amends [ADR 0028](0028-multicluster-architecture.md) for activation/delivery/decommissioning, without changing its hub-managed execution model. It does not replace [ADR 0040](0040-agentic-run-termination.md): graceful fleet draining is not global hard suspension. Existing child specs and Jira wording need alignment; behavior remains planned until implemented.
