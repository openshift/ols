# Multicluster Testing

Cross-repo specification for the **multicluster test suite** — the tests that
validate hub-managed fleet operations across `lightspeed-hub`,
`lightspeed-agentic-operator`, `lightspeed-agentic-alerts-adapter`, and
`lightspeed-hub-ui`.

This suite is **separate** from each repo's existing `product-e2e`
(`lightspeed-agentic-operator/.ai/spec/what/product-e2e-testing.md`). It exists
because multicluster behavior spans repos and clusters, and most of its risk —
cross-cluster RBAC, remote kube-api, ephemeral SA lifecycle, cleanup,
spoke-failure tolerance — is not covered by any single-repo test.

Behavioral rules for the feature under test live in
[multicluster-ops.md](multicluster-ops.md),
[lightspeed-hub/.ai/spec/what/spoke-lifecycle.md](../../../lightspeed-hub/.ai/spec/what/spoke-lifecycle.md),
and
[lightspeed-hub/.ai/spec/what/fleet-coordination.md](../../../lightspeed-hub/.ai/spec/what/fleet-coordination.md).
This document specifies **how those rules are tested**, not the rules
themselves.

> **Status:** All rules are `[PLANNED]`. The multicluster feature is
> specification-only across every repo — no hub, agentic-operator
> `spec.targetCluster`, or adapter code exists yet. This spec defines the target
> test architecture so tests can be written alongside the code.

## Design Axes

Multicluster tests vary along **two orthogonal mock/real axes**:

1. **LLM** — mock agent server vs. real provider (same split as agentic-operator
   `test-e2e` vs. `product-e2e`).
2. **Spokes** — fake spokes (envtest control planes) vs. real remote clusters
   (kind, or HyperShift hosted clusters).

The key insight: **most multicluster risk is LLM-independent.** Cross-cluster
RBAC, remote kube-api, ephemeral SA creation/cleanup, and spoke-failure
tolerance are exercised without any LLM cost. Real LLM only buys end-to-end
behavioral fidelity, so it appears in the top tier alone.

These axes collapse into three tiers.

## Tiers

| Tier | Spokes | LLM | Gate |
|---|---|---|---|
| **T1 — multicluster-integration** | envtest (fake) | mock agent | every PR, blocking |
| **T2 — multicluster-e2e** | kind: 1 hub + N kind spokes | mock agent | per-PR when risk paths change, blocking when it runs |
| **T3 — multicluster-product-e2e** | self-managed hub + HyperShift hosted spokes | real provider | periodic |

## Coverage

### T1 — multicluster-integration

Runs on envtest (no real kubelet). Fake spokes are additional envtest
apiservers. Owned primarily by `lightspeed-hub` and
`lightspeed-agentic-operator`.

- **SpokeCluster reconcile**: registration drives `Connected` / `AdaptersReady`
  conditions; re-reconcile is idempotent (spoke-lifecycle rules 7, 8, 21).
- **Credential broker**: `SecretCredentialSource` returns a usable `rest.Config`
  from a referenced Secret; a `credentialSource` that mismatches the HubConfig
  mode is rejected (spoke-lifecycle rules 9–13).
- **`spec.targetCluster` reconcile**: ephemeral SA + namespace-scoped
  Role/RoleBinding created on the fake spoke; kubeconfig Secret created on the
  hub; sandbox pod started (multicluster-ops flow steps 4–6).
- **Cleanup**: finalizer removes spoke-side resources before release; resources
  carry `hub.openshift.io/spoke-cluster` and `hub.openshift.io/agentic-run`
  labels (multicluster-ops "Cross-Cluster Cleanup").
- **Decommission best-effort**: when the spoke is unreachable, the SpokeCluster
  CR still deletes with a warning condition rather than blocking
  (spoke-lifecycle rule 18).
- **HubConfig webhook**: a SpokeCluster whose mode disagrees with the HubConfig
  singleton is rejected (multicluster-ops CRD notes; decision 0028).

### T2 — multicluster-e2e

Real remote-kube-api coverage without LLM cost. One kind cluster is the hub;
N kind clusters are spokes, each with its own apiserver. The hub reaches spokes
over real remote kube-api.

- **Real cross-cluster identity**: hub creates an ephemeral SA on a *separate*
  kind apiserver, obtains a 24h bound token via the TokenRequest API, and a
  sandbox pod on the hub targets the spoke using that token (multicluster-ops
  flow steps 4–6, Identity Model).
- **RBAC scoping**: the ephemeral token succeeds inside `targetNamespaces` and
  is denied outside them (security invariant 2).
- **Full AgenticRun lifecycle with mock agent** against a real spoke reaches
  `Completed`.
- **Fleet visibility tolerates failure**: with one spoke's apiserver stopped,
  AgenticRuns targeting the other spokes still list and reconcile
  (fleet-coordination rule 6; spoke-lifecycle rule 15).
- **Cross-cluster cleanup** verified against a real second apiserver, including
  the periodic stale-SA sweep (multicluster-ops "Cross-Cluster Cleanup").
- **alerts-adapter**: polls a spoke's mock AlertManager over remote kube-api and
  creates an AgenticRun with the correct `spec.targetCluster`
  (fleet-coordination rules 1, 9).

### T3 — multicluster-product-e2e

Full-fidelity fleet on real clusters with a real provider. Everything T2
asserts, plus:

- **Real troubleshooting run**: an AgenticRun against a real hosted spoke
  completes the full phase lifecycle (Pending → Analyzing → Proposed →
  Executing → Verifying → Completed) with a real provider. Reuses the
  agentic-operator phase-transition assertions from `product-e2e-testing.md`.
- **Multi-spoke fleet**: with 2+ hosted spokes, runs targeting different spokes
  complete independently.
- **Real ROSA-HCP identity path** end-to-end (hub on the management cluster,
  spokes as hosted clusters).
- **hub-ui** (T3; optionally T2 against a mock backend): the fleet dashboard
  renders spoke health with an unreachable spoke visually distinguished
  (fleet-dashboard rule 1; hub-ui system-overview rule 7); an approval action on
  a fleet AgenticRun drives it to execution (fleet-coordination rule 7).

### Out of Scope

Matching the existing product-e2e boundary:

- Sandbox output quality — `lightspeed-agentic-sandbox`'s responsibility via LLM
  judge.
- Behavioral correctness of proposed fixes.
- Spoke-local mode, embedded adapters, and MirrorAgenticRun CRs — all `[PLANNED]`
  in multicluster-ops. Future tiers, not covered here.

## Mechanics

Follows the agentic-operator convention: build-tag-gated Go tests, `make`
targets, one behavioral spec.

### Ownership

| Repo | T1 | T2 | T3 |
|---|---|---|---|
| `lightspeed-hub` | primary (SpokeCluster, broker, webhook) | primary (fleet, cross-cluster, adapter orchestration) | primary |
| `lightspeed-agentic-operator` | `targetCluster`, ephemeral SA, cleanup | yes | yes (reuses phase-transition asserts) |
| `lightspeed-agentic-alerts-adapter` | remote poll → AgenticRun | yes | — |
| `lightspeed-hub-ui` | — | optional (mock backend) | yes (Cypress against real hub) |

### Build Tags

New tags, distinct from the existing `e2e` / `product_e2e` tags:

```go
//go:build mc_integration   // T1
//go:build mc_e2e           // T2
//go:build mc_product_e2e   // T3
```

### Make Targets

Added to `lightspeed-hub` and `lightspeed-agentic-operator`; `lightspeed-hub-ui`
uses its JS test runner.

```bash
make mc-integration    # T1: envtest, no cluster, no credentials
make mc-e2e            # T2: brings up kind hub + spokes, mock agent
make mc-product-e2e    # T3: expects hub + spoke kubeconfigs in env, real credentials
```

### Cluster Access Contract

Tests never provision clusters. CI hands them kubeconfigs; the test binary is
identical across T2 and T3 — only the source of the kubeconfigs differs.

- `MC_HUB_KUBECONFIG` — admin kubeconfig to the hub (management) cluster.
- `MC_SPOKE_KUBECONFIGS` — comma-separated paths to N spoke kubeconfigs. Test
  setup registers each as a SpokeCluster CR.
- Real-LLM tiers additionally consume the existing `E2E_PROVIDER`,
  `E2E_MODEL`, `E2E_PROVIDER_KEY_PATH` variables.

For T2, `hack/mc-kind-up.sh` creates the kind topology and writes these
variables. For T3, CI populates them from the HyperShift steps (see below).

## CI Wiring

Each tier maps to a Prow job in `openshift/release`. The release-repo YAML
itself is authored when the code exists and lives in that repo; this section
records the target job shapes and the step-registry prior art to reuse.

### Gating Summary

| Tier | When it runs | Blocks merge? |
|---|---|---|
| T1 | every PR | yes |
| T2 | per-PR, only when changed paths touch cross-cluster risk areas (`run_if_changed`) | yes, when it runs |
| T3 | periodic (nightly / weekly) | no (firewatch → Jira) |

### T1 — presubmit

Unit-style job, no cluster profile. Runs `make mc-integration` in the build
container. Fast, always-on, blocking.

### T2 — path-scoped presubmit

Single container/VM, no cloud profile. `make mc-e2e` brings up the kind hub +
N kind spokes via `hack/mc-kind-up.sh`, runs the `mc_e2e` suite with the mock
agent, and tears kind down. Prior art: `ocm/e2e/kind` workflow in
`openshift/release` (OCM is a hub / managed-cluster product using kind the same
way).

**T2 MUST run per-PR and block merge when a PR changes cross-cluster reconcile,
credential-broker, ephemeral-SA/cleanup, remote-client, or the `mc_e2e`
harness/tests. It MAY be skipped otherwise** (Prow `run_if_changed`). Risk
paths per repo:

- `lightspeed-hub`: credential broker, SpokeCluster controller, fleet
  coordination, cross-cluster / remote-client code, and the `mc_e2e` tests.
- `lightspeed-agentic-operator`: `targetCluster` reconcile, ephemeral-SA and
  cross-cluster-cleanup code, sandbox wiring, and the `mc_e2e` tests.
- `lightspeed-agentic-alerts-adapter`: remote-poll / AgenticRun-creation code.
- Always: any change to the `mc_e2e`-tagged tests or `hack/mc-kind-up.sh`.

The exact `run_if_changed` regex lives in `openshift/release`.

### T3 — periodic

Self-managed hub + HyperShift hosted spokes. Reuses existing HyperShift
step-registry chains:

```
pre:
  - <ipi-aws install>                    # provision the hub (management) cluster
  - ref:   hypershift-install            #   install HyperShift on it (self-managed webhooks)
  - chain: hypershift-aws-create-guests  #   create N hosted spokes (HYPERSHIFT_NODE_COUNT per guest)
  - <deploy hub stack on mgmt>           #   OLS step: install hub + agentic-operator, register SpokeClusters
test:
  - ref:   <ols-mc-product-e2e>          # make mc-product-e2e
                                         #   MC_HUB_KUBECONFIG + MC_SPOKE_KUBECONFIGS + E2E_PROVIDER*
post:
  - chain: hypershift-aws-destroy-guests
  - <destroy hub cluster>
```

The shared Test-Platform HyperShift management cluster
(`hypershift-hostedcluster-workflow`) is **not** suitable as the hub: installing
cluster-scoped SpokeCluster CRDs, webhooks, and the hub operator would mutate
infrastructure other jobs share. T3 therefore provisions its own management
cluster and installs HyperShift on it (`setup-root-management-cluster` /
`hypershift-install` prior art), so the hub is fully owned.

Provider credentials use the existing e2e credential mount. hub-ui T3 Cypress
runs as an additional test step against the deployed hub console. Failures use
the standard periodic firewatch reporting (as other OLS e2e jobs do) so
fleet-test failures raise Jira automatically.

## Constraints

- T1 requires no cluster and no credentials.
- T2 requires a container/VM able to run nested kind clusters; no cloud
  credentials.
- T3 requires cloud credentials (hub provisioning + HyperShift) and real LLM
  provider credentials.
- The `mc_e2e` and `mc_product_e2e` test binaries MUST behave identically given
  the same `MC_HUB_KUBECONFIG` / `MC_SPOKE_KUBECONFIGS` — provisioning is the
  only difference between T2 and T3.
- Kubeconfig-registered SpokeCluster setup MUST be idempotent (re-running setup
  must converge).

## Future Work

- `[PLANNED]` Spoke-local mode tiers: MirrorAgenticRun sync and approval routing
  (multicluster-ops "Spoke-Local Mode").
- `[PLANNED]` Embedded adapter tiers: hub watches AgenticRun CRs created on the
  spoke (multicluster-ops "Embedded Adapter Path").
- `[PLANNED]` Fleet-wide alert deduplication tests (fleet-coordination rule 11).
