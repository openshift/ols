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

> **Status:** This document describes planned cross-repo test coverage, not an implementation inventory. Hub and remote-run code already exist; individual suites may have landed independently. OLS-4632 coverage below is planned and does not assert that the feature or its tests have been implemented.

## Design

Both tiers run against **real clusters** — cross-cluster RBAC, remote kube-api,
ephemeral SA lifecycle, cleanup, and spoke-failure tolerance all require a real
kubelet and a real second apiserver, which an in-process fake (envtest) cannot
provide. kind is cheap enough (~2–4 min setup/teardown for a hub + a couple of
spokes) to gate PRs, so there is no separate envtest tier — the single kind tier
covers the reconcile logic an envtest tier would have covered *and* the real
cross-cluster behavior on top.

The one axis that separates the tiers is the **LLM**: mock agent server vs. real
provider (the same split as agentic-operator `test-e2e` vs. `product-e2e`). The
key insight is that **most multicluster risk is LLM-independent** — cross-cluster
RBAC, remote kube-api, ephemeral SA creation/cleanup, and spoke-failure
tolerance are all exercised with the mock agent, at no LLM cost. Real LLM only
buys end-to-end behavioral fidelity, so it appears in the top tier alone.

## Tiers

| Tier | Spokes | LLM | Gate |
|---|---|---|---|
| **T1 — multicluster-e2e** | kind: 1 hub + N kind spokes | mock agent | per-PR when risk paths change, blocking when it runs |
| **T2 — multicluster-product-e2e** | self-managed hub + HyperShift hosted spokes | real provider | periodic |

## Coverage

### T1 — multicluster-e2e

Real cross-cluster coverage without LLM cost. One kind cluster is the hub;
N kind clusters are spokes, each with its own apiserver. The hub reaches spokes
over real remote kube-api. Owned primarily by `lightspeed-hub` and
`lightspeed-agentic-operator`.

**Reconcile / lifecycle:**

- **SpokeCluster reconcile**: registration drives `Connected` / `AdaptersReady`
  conditions; re-reconcile is idempotent (spoke-lifecycle rules 7, 8, 21).
- **Credential broker**: `SecretCredentialSource` returns a usable `rest.Config`
  from a referenced Secret; a `credentialSource` that mismatches the HubConfig
  mode is rejected (spoke-lifecycle rules 9–13).
- **HubConfig webhook**: a SpokeCluster whose mode disagrees with the HubConfig
  singleton is rejected (multicluster-ops CRD notes; decision 0028).
- **Decommission best-effort**: when the spoke is unreachable, the SpokeCluster
  CR still deletes with a warning condition rather than blocking
  (spoke-lifecycle rule 18).

**Real cross-cluster behavior:**

- **Real cross-cluster identity**: hub creates an ephemeral SA on a *separate*
  kind apiserver, obtains a 24h bound token via the TokenRequest API, and a
  sandbox pod on the hub targets the spoke using that token (multicluster-ops
  flow steps 4–6, Identity Model).
- **RBAC scoping**: distinguish cluster-wide baseline reads from approved execution grants. Namespace-scoped execution writes succeed only in the namespaces declared by the approved option; cluster-scoped writes require explicitly approved cluster-scoped RBAC (security invariant 2).
- **Configurable baseline [PLANNED: OLS-4632]**: cover fleet defaults, explicit empty/replacement lists, additive spoke roles, administrator-created seed bindings, and per-spoke isolation. Inspect a test custom resource with an added reader role; verify every phase receives baseline reads and only execution receives approved writes. Test missing/unsafe roles, discovery/authorization failures, no eligible roles, configuration changes without restart, concurrent runs, partial setup, and restart/configuration-independent cleanup without modifying source bindings. Detailed requirements: [multicluster-agent-rbac.md](multicluster-agent-rbac.md).
- **Full AgenticRun lifecycle with mock agent** against a real spoke reaches
  `Completed`.
- **Fleet visibility tolerates failure**: with one spoke's apiserver stopped,
  AgenticRuns targeting the other spokes still list and reconcile
  (fleet-coordination rule 6; spoke-lifecycle rule 15).
- **Cross-cluster cleanup**: finalizer removes spoke-side resources before
  release; resources carry `hub.openshift.io/spoke-cluster` and
  `hub.openshift.io/agentic-run` labels; the periodic stale-SA sweep runs
  (multicluster-ops "Cross-Cluster Cleanup").
- **alerts-adapter**: polls a spoke's mock AlertManager over remote kube-api and
  creates an AgenticRun with the correct `spec.targetCluster`
  (fleet-coordination rules 1, 9).

### T2 — multicluster-product-e2e

Full-fidelity fleet on real clusters with a real provider. Everything T1
asserts, plus:

- **Real troubleshooting run**: an AgenticRun against a real hosted spoke
  completes the full phase lifecycle (Pending → Analyzing → Proposed →
  Executing → Verifying → Completed) with a real provider. Reuses the
  agentic-operator phase-transition assertions from `product-e2e-testing.md`.
- **Multi-spoke fleet**: with 2+ hosted spokes, runs targeting different spokes
  complete independently.
- **Custom resource reads [PLANNED: OLS-4632]**: verify PerformanceProfile/Tuned inspection with administrator-installed eligible reader roles on an OpenShift-capable tier, and confirm the additions do not leak to another spoke.
- **Real ROSA-HCP identity path** end-to-end (hub on the management cluster,
  spokes as hosted clusters).
- **hub-ui** (T2; optionally T1 against a mock backend): the fleet dashboard
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

| Repo | T1 | T2 |
|---|---|---|
| `lightspeed-hub` | primary (SpokeCluster, broker, webhook, fleet, cross-cluster) | primary |
| `lightspeed-agentic-operator` | `targetCluster`, ephemeral SA, cleanup, sandbox wiring | yes (reuses phase-transition asserts) |
| `lightspeed-agentic-alerts-adapter` | remote poll → AgenticRun | — |
| `lightspeed-hub-ui` | optional (mock backend) | yes (Cypress against real hub) |

### Build Tags

New tags, distinct from the existing `e2e` / `product_e2e` tags:

```go
//go:build mc_e2e           // T1
//go:build mc_product_e2e   // T2
```

### Make Targets

Added to `lightspeed-hub` and `lightspeed-agentic-operator`; `lightspeed-hub-ui`
uses its JS test runner.

```bash
make mc-e2e            # T1: brings up kind hub + spokes, mock agent
make mc-product-e2e    # T2: expects hub + spoke kubeconfigs in env, real credentials
```

### Cluster Access Contract

Tests never provision clusters. CI hands them kubeconfigs; the test binary is
identical across T1 and T2 — only the source of the kubeconfigs differs.

- `MC_HUB_KUBECONFIG` — admin kubeconfig to the hub (management) cluster.
- `MC_SPOKE_KUBECONFIGS` — comma-separated paths to N spoke kubeconfigs. Test
  setup registers each as a SpokeCluster CR.
- T2 additionally consumes the existing `E2E_PROVIDER`, `E2E_MODEL`,
  `E2E_PROVIDER_KEY_PATH` variables.

For T1, `hack/mc-kind-up.sh` creates the kind topology and writes these
variables. For T2, CI populates them from the HyperShift steps (see below).

## CI Wiring

Each tier maps to a Prow job in `openshift/release`. The release-repo YAML
itself is authored when the code exists and lives in that repo; this section
records the target job shapes and the step-registry prior art to reuse.

### Gating Summary

| Tier | When it runs | Blocks merge? |
|---|---|---|
| T1 | per-PR, only when changed paths touch cross-cluster risk areas (`run_if_changed`) | yes, when it runs |
| T2 | periodic (nightly / weekly) | no (firewatch → Jira) |

> **Coverage gap, accepted:** a PR that touches no T1 risk path gets no
> multicluster CI at all. Reconcile-logic changes outside the risk paths rely on
> the periodic T2 tier as the safety net. This is the deliberate trade for
> dropping a separate always-on envtest tier — kept simple because the risk
> paths below cover the code that can actually break cross-cluster behavior.

### T1 — path-scoped presubmit

Single container/VM, no cloud profile. `make mc-e2e` brings up the kind hub +
N kind spokes via `hack/mc-kind-up.sh`, runs the `mc_e2e` suite with the mock
agent, and tears kind down. Prior art: `ocm/e2e/kind` workflow in
`openshift/release` (OCM is a hub / managed-cluster product using kind the same
way).

**T1 MUST run per-PR and block merge when a PR changes cross-cluster reconcile,
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

### T2 — periodic

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
infrastructure other jobs share. T2 therefore provisions its own management
cluster and installs HyperShift on it (`setup-root-management-cluster` /
`hypershift-install` prior art), so the hub is fully owned.

Provider credentials use the existing e2e credential mount. hub-ui T2 Cypress
runs as an additional test step against the deployed hub console. Failures use
the standard periodic firewatch reporting (as other OLS e2e jobs do) so
fleet-test failures raise Jira automatically.

## Constraints

- T1 requires a container/VM able to run nested kind clusters; no cloud
  credentials.
- T2 requires cloud credentials (hub provisioning + HyperShift) and real LLM
  provider credentials.
- The `mc_e2e` and `mc_product_e2e` test binaries MUST behave identically given
  the same `MC_HUB_KUBECONFIG` / `MC_SPOKE_KUBECONFIGS` — provisioning is the
  only difference between T1 and T2.
- Kubeconfig-registered SpokeCluster setup MUST be idempotent (re-running setup
  must converge).

## Future Work

- `[PLANNED]` Spoke-local mode tiers: MirrorAgenticRun sync and approval routing
  (multicluster-ops "Spoke-Local Mode").
- `[PLANNED]` Embedded adapter tiers: hub watches AgenticRun CRs created on the
  spoke (multicluster-ops "Embedded Adapter Path").
- `[PLANNED]` Fleet-wide alert deduplication tests (fleet-coordination rule 11).
