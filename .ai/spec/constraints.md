# Cross-Repo Constraints

Rules that apply across all repositories in the OLS workspace. Violating any of these means the system or process is wrong.

## Git Workflow

1. All repos use a fork-based workflow. Push to your fork, PR against `origin/main`.
2. All commit messages and PR titles start with `OLS-XXXX` (Jira ticket reference).
3. Squash commits before pushing — one logical commit per PR unless the PR explicitly tracks multiple independent changes.

## Jira

4. Project key is **OLS** on `redhat.atlassian.net`.

## Kubernetes

5. Classic OLS CRDs use API group `ols.openshift.io/v1alpha1`.
6. Agentic OLS CRDs use API group `agentic.openshift.io/v1alpha1`.
7. Multicluster Hub CRDs use API group `hub.openshift.io/v1alpha1`.
8. All components deploy into the `openshift-lightspeed` namespace.
9. Hub-managed spoke-side resources (per-step SAs, RBAC for multicluster) deploy into the `openshift-lightspeed-managed` namespace on the spoke. This avoids collisions with a spoke-local OLS installation in `openshift-lightspeed`.

## RAG

10. The embedding model used to build RAG indexes must be identical to the model used to query them at runtime. Model mismatch produces meaningless similarity scores.

## Version Support

11. After per-version catalog cutover, the unified OLM bundle installs the Classic and Agentic controllers, agentic CRDs, and static RBAC on every supported OCP version. On OCP 4.x Agentic workflows MUST remain inactive; [PLANNED: OLS-4350] AgenticRun execution requires both a matching completed supported OCP 5.0+ version and an explicitly created, unsuspended `AgenticOLSConfig`. Reaching OCP 5.0 alone MUST NOT opt a customer into workflow execution; Classic may still reconcile configured Agentic console/adapter operands on 5.0+. Explicit-disable cleanup on a supported completed version must remove active agentic work and handoff state before the feature is reported inactive. A known OCP 4.x version or an unknown upgrade state must not trigger destructive cleanup; downgrade safety requires separate validation. See decision `0042-unified-olm-bundle-runtime-gating.md`.
