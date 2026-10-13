# 0037: Agentic Version Gating

**Status:** Superseded by [0045: Unified OLM Bundle with an Agentic Console Version Gate](0045-unified-olm-bundle-console-gate.md)
**Applies to:** lightspeed-operator, lightspeed-agentic-operator
**Jira:** OLS-3899

> Historical decision: this records the version-split bundle strategy adopted for OLS-3899. The later OLS-4007 consolidation replaces that release model with one unified bundle and restricts only the agentic console on OCP 4.x; this record is retained to explain the earlier design and migration context.

## Context

OLS ships as a single release stream. Today the operator bundle installs classic
OLS only: the shipped CSV has one deployment (`lightspeed-operator-controller-manager`),
owns one CRD (`olsconfigs.ols.openshift.io`), and `related_images.json` has no agentic
entries.

OLS-3899 requires that the agentic layer install only on OCP ≥ 5.0 (the new OCP
versioning scheme), while every OCP 4.x continues to run classic OLS with no agentic
features present — not installed, not reconciled, no inert CRDs or RBAC. This is a fixed
product constraint, not a runtime toggle or customer-facing feature flag.

The gated set is the entire agentic layer: the agentic-operator controller, the agentic
console plugin, the agentic sandbox, the alerts adapter, and the classic operator's
agentic operands/handoff (the `lightspeed-agentic-configuration` handoff ConfigMap and
the agentic client-CA secrets). Classic operands (OTel collector, MCP server, RHOKP,
PostgreSQL, chat console plugin) are not gated and run on all versions.

## Decision

Gate the agentic layer with **two version-split OLM bundles per release under one
package** (`lightspeed-operator`, same channels `stable`/`alpha`), partitioned by the
`com.redhat.openshift.versions` bundle annotation:

- **v1 bundle** (`1.x` line): classic only, one controller deployment, owns
  `ols.openshift.io` CRDs, `com.redhat.openshift.versions` upper-bounded to 4.x.
- **v2 bundle** (`2.x` line): classic + agentic, two controller deployments (adds
  `lightspeed-agentic-operator-controller-manager`), owns `ols.openshift.io` +
  `agentic.openshift.io` CRDs, agentic operands and RBAC, `com.redhat.openshift.versions`
  `>=v5.0`.

Same package, same channels, one Subscription. A cluster only ever resolves the bundle
whose `com.redhat.openshift.versions` matches its OCP version, because each per-OCP-version
FBC catalog includes only the matching bundle. The 4.x → 5.0 upgrade is expressed with
`olm.skipRange: ">=1.0.0 <2.0.0"` on the v2 channel head, so the 5.x catalog needs only
the v2 bundle (no v1 entry to anchor an edge).

Agentic RBAC is static in the v2 bundle: the agentic controller's cluster permissions live
in the v2 CSV `clusterPermissions` (OLM-generated, install-time exempt from the
privilege-escalation check), and standalone RBAC objects (the `agentic-run-approver`
ClusterRole/Binding) ship as static bundle manifests. Per-run sandbox RBAC is created at
runtime, bounded to a subset of the operator's own permissions (no `escalate`/`bind`).

Konflux models the two bundle lines as **two separate Applications**; shared component
images are built in one Application and cross-referenced by digest from the other.

## Alternatives Considered

- **Single bundle, runtime gate (T1)** — rejected: OLM owns the static CSV deployment set,
  so the agentic controller pod cannot be cleanly stopped on 4.x.
- **Separate agentic OLM package (T2)** — rejected: reverses decision 0029 (re-homes
  alerts-adapter/agentic-console into agentic-operator) and needs a separate subscription,
  so agentic never auto-arrives on cluster upgrade.
- **Single bundle, agentic controller as operand (T3)** — rejected: agentic CRDs/RBAC are
  present-but-inert on 4.x, violating "nothing agentic on 4.x."
- **One Konflux Application, two bundle Components** — rejected in favor of decoupled
  release cadence for the agentic line.

## Consequences

- Truly nothing agentic on 4.x (no controller, CRDs, operands, or RBAC).
- Decision 0029 preserved: lightspeed-operator still owns the agentic operands, in the v2
  bundle.
- One subscription; catalog membership (not version ordering alone) is the gate.
- Build tooling emits two bundle variants from a shared `related_images.json` (entries
  tagged by bundle membership); `update_bundle.sh` becomes selector-driven (`v1` | `v2`).
- Two version lines must stay range-partitioned (`2.x > 1.x`) with a correct `skipRange`
  edge, or a cluster that upgrades to 5.0 silently stays on classic. Guarded by a standard
  e2e upgrade test.
- New 5.x FBC catalogs and disconnected mirroring for 5.0; doubled bundle certification.
- Agentic CRDs and RBAC are synced into the v2 bundle from the lightspeed-agentic-operator
  repo at a pinned ref; never hand-edited.
