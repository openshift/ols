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

11. [PLANNED: OLS-4007] The unified OLM bundle installs Classic and Agentic controllers, agentic CRDs, and static RBAC on supported OCP versions. [PLANNED: OLS-4349] On OCP 4.x, the agentic console plugin MUST NOT be deployed or activated; only the console is version-gated. The Agentic backend, configured alerts adapter, handoff, and client CA Secrets MUST NOT be blocked solely by OCP version or by the absence of AgenticOLSConfig. See decision `0045-unified-olm-bundle-console-gate.md`.
