# Operand Network Policies [PLANNED: OLS-4171]

Cross-repository network-access contract for OLS-managed operands. OLS-4171 covers operands, not the operator's policy in the OLM bundle (OCPSTRAT-3087). The confirmed monitoring-ingress defect for RHOKP and MCP is tracked separately by OLS-3943. This document describes intended changes alongside the current exceptions; it does not claim full HPSTRAT-104 compliance while egress exceptions and the policy-type acceptance check remain open. See [decision 0044](../decisions/0044-operand-network-policy-scope.md).

## Behavioral Rules

### Monitoring ingress

1. [PLANNED: OLS-3943] When standalone RHOKP is enabled, its operator-managed NetworkPolicy MUST allow cluster Prometheus pods in `openshift-monitoring` to scrape HTTPS metrics on TCP 8443. The rule MUST preserve same-namespace client access, including app-server and sandbox clients. When `byokRAGOnly` disables RHOKP, the operator removes its policy with the operand.
2. [PLANNED: OLS-3943] When the standalone OpenShift MCP server is enabled, its operator-managed NetworkPolicy MUST allow the same Prometheus source to scrape HTTPS `/metrics` on TCP 8443. The rule MUST preserve same-namespace app-server and sandbox-client access. When introspection is disabled, the operator removes its policy with the operand. This is the standalone server, not the obsolete port-8080 sidecar.
3. [PLANNED: OLS-3943] Monitoring ingress MUST match both the `openshift-monitoring` namespace and cluster Prometheus pods, not all pods in the namespace. It MUST NOT create a broader ingress allowance. App-server, OTel Collector, and operator metrics ingress already have Prometheus rules; their monitoring policies are not changed by OLS-3943.

### Egress candidates

4. [PLANNED: OLS-4171] The operator-managed PostgreSQL policy MUST select only the PostgreSQL pods and deny pod-initiated egress. Existing ingress from app-server and OTel Collector pods remains unchanged; the operator's Kubernetes API calls to reconcile PostgreSQL are not connections from the database pod.
5. [PLANNED: OLS-4171] The classic and agentic console-plugin pod policies MUST each deny pod-initiated egress while retaining their existing ingress from OpenShift Console. Classic API requests use the ConsolePlugin's Console-side proxy, not an outbound connection from the plugin's static-file nginx pod. Agentic UI cluster API and retained-log requests use OpenShift Console and the Kubernetes API service-proxy path, not an outbound connection from its nginx pod. Agentic console rules apply only where that operand is deployed (OCP 5.0+).
6. [PLANNED: OLS-4171] The standalone RHOKP policy MUST deny pod-initiated egress. RHOKP's image contains its search corpus; requests from app-server and sandbox agents, and replies to them, are not RHOKP-initiated connections. Its monitoring-ingress change is governed separately by rules 1 and 3.
7. [PLANNED: OLS-4171] The local, operator-managed alerts-adapter policy MUST retain ingress denial and allow only the egress necessary for cluster DNS, local AlertManager (`alertmanager-main` in `openshift-monitoring`, HTTPS TCP 9094), and the local Kubernetes API (AgenticRun list/get/create). The policy MUST be present only while the opt-in local adapter is enabled and MUST be removed with that operand. A Kubernetes API Service name is not a NetworkPolicy peer; the implementation MUST not assume that a ClusterIP `ipBlock` alone works across network-plugin service translation. Before enabling egress isolation, a target-cluster test MUST prove API, DNS, and AlertManager connectivity and AgenticRun creation under the proposed policy. If the rule fails that test, revise it and retest; do not enforce a policy that stops the adapter.
8. [PLANNED: OLS-4171] These egress rules apply to the selected **pod**, including init containers and sidecars. Required reply traffic to permitted inbound connections is not a new outbound connection. Standard NetworkPolicies are additive: another policy that selects the same pod and permits egress can expand effective access. OLS does not claim exclusive namespace-wide enforcement.

### Explicit egress exceptions

9. The app-server pod remains without an **OLS-managed egress restriction**. Administrator-configured LLM providers, external MCP servers, and proxy endpoints vary; its optional Dataverse exporter sidecar also uploads outside the cluster. A static pod-level allow-list could break supported configurations. The pod still initiates known in-cluster connections to PostgreSQL, RHOKP, MCP, OTel Collector, Kubernetes API, and DNS.
10. The standalone OpenShift MCP server remains without an OLS-managed egress restriction. Its Kubernetes API, Thanos Querier, AlertManager, and DNS connections are known, but custom Helm repositories and evolving MCP tools can require destinations and ports the operator cannot enumerate. It still requires the separate Prometheus **ingress** rule in rule 2.
11. The OTel Collector remains without an OLS-managed egress restriction. Its PostgreSQL connection is known, but `spec.audit.tracingEndpoint` can identify an administrator-chosen external backend; a fixed allow-list would break tracing. [PLANNED: OLS-4493] Its `dataverse` exporter also calls the Kubernetes API and uploads to the Red Hat ingress service, directly or through the cluster-wide proxy. Collector metrics ingress is already covered.
12. Agentic sandbox pods remain without an OLS-managed egress restriction. LLM providers, configured MCP servers, tool commands, and optional RHOKP/OTel use vary by run. The agentic operator's sandbox-claim template explicitly uses `networkPolicyManagement: Unmanaged`; its bare-pod path also does not generate a sandbox NetworkPolicy. Cluster-admin policies may still apply.
13. The hub-managed multicluster alerts-adapter pod remains without a hub-managed egress restriction. It calls the hub Kubernetes API and dynamically configured external spoke AlertManager Routes. Spoke Route hostnames and possibly ports change as spokes register; standard NetworkPolicy cannot match destinations by hostname. The hub deployment disables local AlertManager polling. This exception does not apply to the local adapter in rule 7.
14. [PLANNED: OLS-4171] These exceptions are deliberate **non-coverage**, not proof of HPSTRAT-104 completion or a guarantee of unrestricted connectivity in the presence of administrator policies. Tightening an exception requires a separately approved strategy for variable external destinations (for example, an enforced proxy or administrator-managed destinations), with tests for supported configurations. No broad allow rule is added solely to make an exception appear restricted.

### Policy type and boundaries

15. [PLANNED: OLS-4171] OLS continues to use namespace-scoped standard `NetworkPolicy` for operator-managed operand rules. `AdminNetworkPolicy` is cluster-scoped and can make higher-priority Allow/Deny/Pass decisions that namespace policies cannot override. OLS MUST obtain confirmation that standard NetworkPolicy is acceptable for the operand portion of HPSTRAT-104; this document does not assert that the preference for AdminNetworkPolicy has been satisfied. The operator-in-OLM-bundle scope is separate (OCPSTRAT-3087).
16. [PLANNED: OLS-4171] No new user-facing CRD field or cross-repo handoff API is required. An existing cluster administrator policy may constrain any listed flow; OLS-managed policies cannot override a higher-priority administrative Deny. Feature-gated policies are reconciled and removed with their owning operands under existing lifecycle and resource-error reporting.

## Verification

- Generator and reconciliation tests MUST assert correct pod selection, namespace/pod source selectors, ports, policy types, feature-gated creation/removal, and unchanged ingress for the egress candidates. Tests MUST confirm that RHOKP and MCP allow only the intended Prometheus source in addition to their existing clients.
- Target-cluster tests MUST confirm RHOKP/MCP metrics scraping and existing client access; startup, UI behavior, and denied pod-initiated egress for PostgreSQL, both console plugins, and RHOKP; and successful local adapter API, DNS, AlertManager, and AgenticRun flows with unrelated egress denied. Policy-object unit tests alone cannot prove data-plane behavior.
- The local adapter connectivity test in rule 7 is an implementation prerequisite **before enforcing its egress restriction**, not a prerequisite for this design or spec. If it fails, implementation must correct the proposed policy and retest rather than deploy it unchanged.
- Existing variable-destination scenarios for exception pods MUST remain functional; no OLS-managed egress policy is added for those pods by this change.

## Repository Ownership

| Repository | Responsibility |
| --- | --- |
| `lightspeed-operator` | RHOKP/MCP monitoring ingress; PostgreSQL, both console plugins, RHOKP, and local alerts-adapter egress behavior; feature-gated policy lifecycle and reconciliation. |
| `lightspeed-hub` | Hub-managed alerts-adapter deployment; documents its dynamic-spoke egress exception. No hub adapter egress policy is introduced here. |
| `lightspeed-agentic-operator` | Sandbox pod creation; documents the per-run egress exception. No sandbox policy is introduced here. |
| `lightspeed-agentic-console` | Uses Console/Kubernetes API for cluster resources and retained logs via the Kubernetes Service proxy; does not originate these requests from the plugin nginx pod. No frontend change is required here. |

## Out of Scope and Follow-Up

- Changing PostgreSQL's existing ingress from named app-server/Collector sources to every pod in `openshift-lightspeed`.
- Replacing standard NetworkPolicy with AdminNetworkPolicy without the HPSTRAT-104 operand-scope acceptance decision.
- Restricting the operator-in-OLM-bundle or broadening coverage to all external-destination workloads; the former is OCPSTRAT-3087.
- A proxy/CIDR/FQDN-control architecture for exception pods. The exceptions in rules 9–13 remain open work if complete operand egress restriction is required.

## Child Specs

- `lightspeed-operator/.ai/spec/what/security.md`, `what/ocpmcp.md`, `what/rhokp.md`, `what/reconciliation.md`, and `what/observability.md` — operator-owned policy behavior and monitored endpoints; child changes to be discussed separately.
- `lightspeed-hub/.ai/spec/what/system-overview.md` — hub-managed adapter deployment and its exception; child changes to be discussed separately.
- `lightspeed-agentic-operator/.ai/spec/what/sandbox-execution.md` — sandbox networking exception; child changes to be discussed separately.
