# Agentic Version Gating (OLS-3899) — Design

> **Historical proposal:** this design specifies the earlier v1/v2 version-split bundle approach. It is superseded by OLS-4007 and [decision 0045](../../../.ai/spec/decisions/0045-unified-olm-bundle-console-gate.md), which select one unified bundle and restrict only the agentic console on OCP 4.x. Retained for design history only; do not use as the current bundle specification.

**Status:** Draft for review
**Date:** 2026-08-25
**Jira:** OLS-3899
**Scope:** cross-repo (`ols/.ai/spec`), lightspeed-operator, lightspeed-agentic-operator, Konflux release tooling

## 1. Problem, Scope & Version Threshold

OLS ships as a single release stream. Today the operator bundle installs **classic
OLS only**: the shipped CSV (`lightspeed-operator.v1.1.3`) has one deployment
(`lightspeed-operator-controller-manager`), owns one CRD
(`olsconfigs.ols.openshift.io`), and `related_images.json` has no agentic entries.

OLS-3899 requires that the **agentic layer be installed only on OCP ≥ 5.0**, while
**every OCP 4.x continues to run classic OLS with no agentic features**. The
threshold is the new OCP versioning scheme: **OCP ≥ 5.0 gets agentic; every 4.x is
classic-only.** This is a fixed product constraint — not a runtime toggle or a
customer-facing feature flag.

**Gated set (everything "agentic"), absent on 4.x — not installed, not reconciled,
no inert CRDs/RBAC:**
- the agentic-operator controller,
- the agentic console plugin,
- the agentic sandbox,
- the alerts adapter,
- the classic operator's agentic operands/handoff: the
  `lightspeed-agentic-configuration` handoff ConfigMap and the agentic client-CA
  secrets.

**Explicitly NOT gated** (classic operands present on all versions): OTel collector
(always deployed), MCP server, RHOKP, PostgreSQL, and the chat console plugin.

**Out of scope:** no change to classic behavior on any version; no change to the
multicluster hub; no new customer-facing config surface; the agentic *runtime*
semantics (decisions 0022/0029) are unchanged. This spec governs only **where /
whether** the agentic layer is installed.

## 2. Topology — T4: two version-split bundles, one OLM package

Each OLS release produces **two bundles under the same OLM package**
(`lightspeed-operator`, same channels `stable`/`alpha`), partitioned by the
`com.redhat.openshift.versions` bundle annotation.

| | v1 bundle (classic) | v2 bundle (full/agentic) |
|---|---|---|
| Targets | OCP 4.x | OCP ≥ 5.0 |
| `com.redhat.openshift.versions` | 4.x only (upper-bounded to exclude 5.x) | `>=v5.0` |
| CSV deployments | 1 (`lightspeed-operator-controller-manager`) | 2 (classic controller **+** `lightspeed-agentic-operator-controller-manager`) |
| Owned CRDs | `ols.openshift.io` only | `ols.openshift.io` **+** `agentic.openshift.io` |
| Agentic operands | none | agentic console, alerts adapter, sandbox handoff, client-CA secrets |
| Version line | `1.x` | `2.x` |

**Why T4** (over alternatives evaluated during brainstorming):
- **T1** (single bundle, runtime gate): OLM owns the static CSV deployment set — you
  cannot cleanly stop the agentic controller pod on 4.x. Collapses into T3.
- **T2** (separate agentic *package*): truly nothing agentic on 4.x, but **reverses
  decision 0029** (re-homes alerts-adapter/agentic-console into agentic-operator) and
  needs a separate subscription (agentic never auto-arrives on cluster upgrade).
- **T3** (single bundle, agentic controller as an operand): one subscription, but
  agentic CRDs/RBAC are **present-but-inert on 4.x** — violates "nothing agentic on 4.x."
- **T4 (chosen):** truly nothing agentic on 4.x, **preserves decision 0029**
  (lightspeed-operator still owns the agentic operands, in the v2 bundle), static
  agentic RBAC lives in the v2 CSV (no escalation problem), still **one subscription**.

**Key invariant:** same package, same channels, one Subscription. A cluster only ever
sees the bundle whose `com.redhat.openshift.versions` matches its OCP version, because
each per-OCP-version FBC catalog includes only the matching bundle.

## 3. Versioning & Upgrade Edges

**Two partitioned version lines:** v1 bundle on the `1.x` line, v2 bundle on the `2.x`
line, range-partitioned so they never collide — within a release, `2.x > 1.x`. Version
ordering alone is not the gate; **catalog membership is** (a 4.x catalog contains only
`1.x`; a 5.x catalog contains only `2.x`).

**Two reconciliation loops — not to be conflated:**
1. **OLM's loop:** Subscription → resolves against the *cluster's* per-version FBC
   catalog → picks/upgrades the CSV. This selects classic-vs-full.
2. **The operator's loop:** OLSConfig → operand Deployments. Unchanged, except the v2
   CSV runs the extra agentic controller.

**Upgrade scenarios:**
- **4.x → newer 4.x:** normal `replaces` chain within `1.x` in the 4.x catalog. No agentic.
- **Fresh install on 5.0:** the 5.0 catalog resolves the Subscription to the v2 bundle.
- **Cluster upgrade 4.x → 5.0 (critical path):** when the cluster moves to 5.0, OLM
  re-resolves the *same* Subscription against the **5.0 catalog**, whose channel head is
  `v2.0.0` carrying **`olm.skipRange: ">=1.0.0 <2.0.0"`**. The installed `1.x` CSV falls
  in that range, so OLM upgrades it straight to `v2.0.0` and the agentic layer activates.

**Upgrade mechanism — `skipRange` is primary.** `skipRange` is a property of `v2` that
says "I can upgrade over anything in this range" and does **not** require the source
bundle to exist in the catalog. Therefore the **5.x catalog needs only the v2 bundle**
(no v1 entry to anchor an edge). `replaces` is optional and not used to cross the
4→5 boundary.

**Failure mode designed against — silent stay-on-classic.** If the edge/version is
wrong, a cluster upgrades to 5.0 but OLS silently stays on classic (OLM finds no
upgrade, no error). Guards:
- the 5.0 catalog head is `v2.0.0` with a valid `skipRange` covering the whole `1.x` range;
- `2.x` semver > the highest `1.x` ever shipped;
- `installPlanApproval: Automatic` so the upgrade happens unattended on cluster crossing;
- no `olm.maxOpenShiftVersion` on `1.x` CSVs that would *block* the cluster upgrade
  itself (we gate installation, not cluster upgrades);
- an e2e test asserts the edge (§7).

## 4. Agentic RBAC

The v2 bundle carries agentic RBAC in three distinct forms; the v1 bundle carries none.
Contents are sourced from `lightspeed-agentic-operator/config/rbac/`.

**A. Operator SA permissions → CSV `clusterPermissions` (OLM-generated).**
The `agentic-operator-manager-role` rules become the `clusterPermissions` block for the
`lightspeed-agentic-operator-controller-manager` SA in the **v2 CSV**. OLM generates the
ClusterRole + ClusterRoleBinding at install — **install-time exempt** from the
privilege-escalation check. These rules include `create/delete/get` on
`roles`/`rolebindings` and `create/delete/get/list/update` on
`clusterroles`/`clusterrolebindings` (the verbs the controller needs to provision per-run
sandbox RBAC). **No `escalate`, no `bind`** verbs — deliberate.

**B. Standalone RBAC objects → static bundle manifests (v2 only).**
The `agentic-run-approver` ClusterRole + ClusterRoleBinding (binds `system:cluster-admins`
so only cluster-admins can approve/deny runs) are not operator-SA permissions, so they
cannot live in `clusterPermissions`. They ship as their **own manifest files** in the v2
bundle's `bundle/manifests/`, exactly as the v1 bundle already ships standalone RBAC
(`…query-access_…clusterrole.yaml`, `…prometheus-k8s_…role.yaml`/`rolebinding.yaml`,
`…ols-metrics-reader_…clusterrolebinding.yaml`). OLM applies them at install.

**C. Per-run roles/rolebindings → created at runtime, not in the bundle.**
The running agentic controller creates scoped Role/RoleBinding (and ClusterRole/Binding)
objects for each sandbox run's ServiceAccount (decisions 0022/0033). Because the operator
SA holds `create/delete/get` on those RBAC resources but **not** `escalate`/`bind`, every
per-run grant is bounded to a **subset of the operator's own permissions** —
least-privilege by construction, no escalation.

**Source of truth & sync.** A and B originate in `lightspeed-agentic-operator/config/rbac/`
and are synced into the **v2 bundle** at a pinned ref (same mechanism used for the agentic
CRDs), never hand-edited. On 4.x (v1 bundle) none of A/B/C exists.

**Open sub-decision (non-blocking):** the `agentic-run-approver → system:cluster-admins`
ClusterRoleBinding is a broad cluster-wide grant that ships automatically with v2. Recorded
position: ship as-is per current agentic-operator design; revisit if security review objects.

## 5. Build & `related_images.json`

Today `related_images.json` is a single flat list (no agentic entries) and the build emits
one bundle via `hack/update_bundle.sh`. T4 emits **two bundle variants** from a shared image
manifest.

**Image manifest — tag entries by bundle membership.** Add a `bundles` field to each
`related_images.json` entry:
- shared (both): `service`, `console` (chat), `operator`, `postgres`, `mcp-server`,
  `rhokp`, `exporter`, OTel collector → `["v1","v2"]`;
- agentic (v2 only): new entries `lightspeed-agentic-operator`,
  `lightspeed-agentic-console-plugin`, `lightspeed-agentic-alerts-adapter`,
  `lightspeed-agentic-sandbox` → `["v2"]`;
- entries without the field default to `["v1","v2"]` (back-compat).

**`update_bundle.sh` becomes selector-driven** with the selector expressed as `v1` | `v2`
(replacing the separate `-v` version flag). Given `v1` or `v2` it:
- filters `related_images.json` to entries whose `bundles` includes that selector,
- selects the matching CSV template (v1 = 1 deployment; v2 = 2 deployments),
- sets the matching `com.redhat.openshift.versions` annotation,
- writes `spec.relatedImages` from only that selector's images,
- stamps the corresponding version line and `skipRange`.
Run once per selector → two bundle images.

**Two CSV templates.** Split today's single CSV into a shared base + two overlays: `v1`
(as shipped now) and `v2` (adds the agentic deployment, agentic CRD ownership, and the
agentic RBAC of §4). Agentic CRDs/RBAC are synced from the agentic-operator repo into the
v2 overlay only.

**Version bump.** The existing two-file bump (bundle.Dockerfile labels; CSV name/version)
becomes per-selector — bump both the `1.x` and `2.x` coordinates each release, keeping
`2.x > 1.x`.

**Pre-existing gap flagged, not fixed here:** the OTel collector image isn't in
`related_images.json` today; it ships in both bundles, so this is a follow-up rather than
silently omitted.

## 6. Konflux Layout — Model 2: two Applications

**Decision:** model the two bundle lines as **two separate Konflux Applications** (e.g. a
classic/`v1` Application carrying the shared components, and an agentic/`v2` Application).

Consequences:
- Each Application has its own Components, Snapshots, IntegrationTestScenarios, and
  ReleasePlans → independent build/test/release cadence for v1 and v2.
- **Shared component images** (operator controller, service, chat console, postgres, mcp,
  rhokp, otel) are built in one Application and **cross-referenced by digest** from the
  other — the pattern `related_images.json` already uses (`konflux_prefix` /
  `stable_prefix`). Shared digests must be kept in sync per release.
- **No single Snapshot spans both apps** → the v1→v2 upgrade test cannot co-test co-built
  bundles; it installs the **last-released v1 bundle by digest** and upgrades to the v2
  under test (see §7).
- The **5.x FBC references only the v2 bundle digest** (from the agentic app); thanks to
  the `skipRange` model (§3) no v1 digest is needed in the 5.x catalog, so there is no
  cross-app v1-digest sourcing for catalog build.
- More Konflux objects to own (two Applications, two sets of
  IntegrationTestScenarios/ReleasePlans/RBAC).

Model 1 (one Application, two bundle Components) was considered and rejected in favor of
decoupled cadence.

**Release plumbing.** The per-version FBC release dirs in `release-konflux/` extend to
cover 5.x: existing `stable-fbc-prod-4NN-*` carry v1 only; new `stable-fbc-prod-5NN-*`
carry v2 only. `hack/release-konflux/base/` gains 5.x `fbc-prod-v5-NN.yaml` files;
`components.yaml`/`bundle.yaml` gain the v2 bundle component in the agentic Application.

## 7. Integration & E2E Tests

Today `konflux-integration/pipeline.yaml` is a placeholder. T4 needs real per-bundle
assertions, split across the two Applications.

**v1 Application pipeline (runs on v1 Snapshots):**
1. v1 installs on a 4.x cluster/catalog; OLSConfig reconciles classic operands.
2. **Agentic-absent guard:** assert no `agentic.openshift.io` CRDs, no
   `lightspeed-agentic-operator-controller-manager` deployment, no agentic
   console/alerts-adapter/sandbox, no agentic RBAC (ClusterRole/approver
   binding/roles/rolebindings). Core OLS-3899 assertion for 4.x.
3. **Catalog-leakage guard:** the v1 bundle's `com.redhat.openshift.versions` excludes
   5.x, and v1 never appears in a 5.x catalog.

**v2 Application pipeline (runs on v2 Snapshots):**
4. v2 installs on a 5.x cluster/catalog; assert both deployments run, both CRD groups
   present, agentic operands (console, alerts-adapter, sandbox handoff) reconcile.
5. **Agentic-present guard:** mirror of #2.
6. **v1→v2 upgrade-edge test — a standard e2e test.** Lives in the operator repo's
   standard e2e suite (`test/e2e/`, `make test-e2e`) and runs as part of the v2
   Application's normal e2e run on each v2 Snapshot — same harness/fixtures/reporting as
   every other e2e case. Fixture: the **last-released v1 bundle is pulled by digest**
   (Model 2) and installed against a v1-style catalog. Act: repoint the Subscription at a
   5.x catalog carrying v2 (`skipRange ">=1.0.0 <2.0.0"`). Assert: OLM upgrades v1→v2
   **unattended**, both deployments come up, agentic CRDs/operands activate. Guards the
   silent stay-on-classic failure mode (§3). The "last-released v1 digest" is wired in as
   a normal test input produced by the release stream.
7. **RBAC realization:** on v2, assert the agentic controller's `clusterPermissions`
   (incl. the runtime roles/rolebindings verbs) and the standalone approver
   ClusterRole/Binding are created by OLM at install.

**Operator repo `make test` (envtest):**
8. Both CSV templates render validly (1-deployment vs 2-deployment); `update_bundle.sh
   v1|v2` emits the right image set + annotations.

## 8. Documentation Artifacts (downstream of this design)

This design doc is the brainstorming output. The following `.ai/spec/**` and ADR edits are
downstream of design-doc approval (via writing-plans → implementation), not part of this
brainstorm's write step:

*Cross-repo (`ols/.ai/spec/`):*
- `decisions/0037-agentic-version-gating.md` — new ADR recording T4, the `skipRange`
  upgrade model, and Model 2 Konflux layout; cross-refs 0004/0022/0029/0033.
- `decisions/README.md` — add the dated 0037 index line.
- `constraints.md` — new "Version Support" constraint (classic all versions; agentic ≥ 5.0).
- `what/system-overview.md` — OLS-3899 note + Planned Changes row.
- `what/deployment-lifecycle.md` — version-gating note + Planned Changes row.

*Operator repo (`lightspeed-operator/.ai/spec/`):*
- `what/bundle-composition.md` — reframe from "single bundle, two controllers" to two
  bundles (v1 1-deployment / v2 2-deployment), selector-driven build, per-bundle
  `com.redhat.openshift.versions`, v2-only agentic CRDs/RBAC/operands, `related_images.json`
  `bundles` tagging, `update_bundle.sh v1|v2` flow.
- `what/agentic-console-ui.md` — the "always reconciled, no CR toggle" rule holds only in
  the v2 bundle; the operand does not exist on 4.x.

Per `CLAUDE.md`, auto-push spec PRs cover only spec-only files (`.ai/spec/**`,
`docs/superpowers/specs/**`); `AGENTS.md`/`CLAUDE.md` and any tooling/code changes require
human-reviewed PRs.

## Open Items
- OTel collector image is not in `related_images.json` today (§5 follow-up).
- `agentic-run-approver → system:cluster-admins` grant breadth (§4) — ship as-is, revisit
  on security review.
