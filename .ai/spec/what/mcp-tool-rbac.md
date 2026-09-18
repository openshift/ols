# MCP Tool RBAC Resolution

How the agentic system derives least-privilege Kubernetes RBAC for remediation steps that are **MCP tool calls** (rather than `oc`/`kubectl` commands), so the operator can materialize the correct permissions onto a per-step ServiceAccount before execution. Extends the script-grounded RBAC model (`agentic-runs.md` Phase 4, decision [0033](../decisions/0033-script-grounded-rbac.md)) to the tool-call case. Motivated by [OLS-3680](https://redhat.atlassian.net/browse/OLS-3680). Design rationale: decision [0038](../decisions/0038-mcp-tool-rbac-resolution.md).

## Architecture

The **analysis agent** (running in the sandbox) is the MCP client — it calls `tools/list`, sees `_meta`, and interacts with MCP tools. The **operator** never communicates with MCP servers. RBAC derivation for MCP tool calls follows the same path as `oc`/`kubectl` steps:

1. The **analysis agent** derives RBAC (from `_meta` or by expressing the step as oc-IR) and reports it as standard `PolicyRule`s in the `RemediationOption` — the same RBAC field used for `oc`/`kubectl` steps.
2. The **operator** reads PolicyRules from the approved option and materializes them onto the per-step SA — unchanged from the existing pipeline.

The operator does not need to know whether the RBAC came from `_meta`, oc-IR, or tracing `oc` commands. It materializes whatever the agent reported. The enforcement boundary (per-step SA token passthrough to the API server) is also unchanged.

The gap this spec closes is **teaching the analysis agent how to derive RBAC for MCP tool calls** — via analysis instructions that direct the agent to read `_meta` from trusted servers or express tool steps as equivalent `oc` commands.

[PLANNED: OLS-4060] MCP server definitions are run-level only: `AgenticRun.spec.tools.mcpServers` is the single MCP server list for analysis, execution, verification, and escalation. Per-step tool overrides are removed, so analysis sees the same MCP servers that later steps may use and can derive remediation RBAC and validation requirements from the complete tool universe.

## Problem

For `oc`/`kubectl` steps, the analysis agent derives least-privilege RBAC by tracing the concrete commands. For MCP tool calls there is no command to trace, and the RBAC target is often invisible in the tool arguments:

- **Subresources** implied by the tool identity, not the arguments — `pods_exec` → `create pods/exec`, `pods_log` → `get pods/log`, `nodes_log`/`nodes_stats_summary` → `nodes/proxy`, `resources_scale` → `*/scale`.
- **Generic pass-throughs** whose group/resource come from `apiVersion`/`kind` arguments — `resources_get`/`resources_list`/`resources_delete`.
- **Manifest-embedded GVK** — `resources_create_or_update` carries the target inside a free-form manifest argument.
- **Unbounded effect** — `helm_install`/`helm_uninstall` apply whatever the chart contains; RBAC is not a function of the arguments.

The `_meta["openshift.io/rbac"]` contract gives the analysis agent an authoritative RBAC source published by the tool author, discoverable over the MCP protocol the agent already speaks.

## Behavioral Rules

### Resolution order (per tool-call step)

These rules govern what the **analysis agent** does when proposing a remediation that includes MCP tool calls. The agent derives RBAC and reports it as standard `PolicyRule`s in the `RemediationOption` — the same format used for `oc`/`kubectl` steps. The operator materializes whatever PolicyRules appear in the approved option; it does not participate in MCP-specific resolution.

1. **`_meta` contract (primary).** The analysis agent reads `tool._meta["openshift.io/rbac"]` from the MCP server's `tools/list` response and resolves the required RBAC from it. The contract and its schema are defined by the OLS-3680 RFE to the OpenShift MCP server team. [PLANNED: OLS-4060] Because MCP servers are defined only at `AgenticRun.spec.tools.mcpServers` and are shared by every step, the analysis agent can inspect `tools/list` for every MCP server that execution, verification, or escalation may use.
2. **oc-IR derivation (fallback).** When a tool has no `_meta` RBAC (server has not adopted the contract, or the server is not on the trusted list in the analysis instructions), the analysis agent MUST express the step's effect as equivalent `oc`/`kubectl` command intermediate representation, and RBAC is derived from it via the script-grounded pipeline (decision 0033). This is why the common ocp-mcp core tools remain resolvable even before the server adopts `_meta`.
3. **Fail-closed (terminal).** A step resolvable by neither path MUST cause the containing remediation **option** to be rejected — not the whole analysis. If every option is rejected, the run terminates in `Escalated` with a diagnosis naming the unresolvable tool(s) and, where applicable, which declaration would resolve it.

### `_meta` trust

4. **Operator-managed servers only.** The analysis instructions MUST direct the agent to use `_meta` RBAC **only** from MCP servers on the operator-managed list (the shipped `openshift-mcp-server`). `_meta` advertised by bring-your-own / third-party MCP servers is untrusted and MUST be ignored — those tools resolve via oc-IR (rule 2) or fail closed (rule 3). Trust enforcement is instruction-based (the agent is told which servers to trust), not operator-enforced (the operator never sees `_meta`).
5. **Derivation input, not enforcement.** `_meta` and oc-IR are inputs to RBAC derivation only. They never widen or replace the enforcement boundary, which remains the API server acting on the per-step SA's passed-through token. A too-narrow declaration therefore yields an honest 403 at execution; the risk the trust rule guards against is an over-broad or dishonest declaration.

### Declaration states

6. **Four distinct states.** The analysis instructions MUST direct the agent to distinguish, for each tool:
   - `noRbac: true` — authoritatively needs no cluster RBAC (e.g. local-kubeconfig tools) → report no RBAC for this step.
   - a resolvable form (`rules` / `deriveFromArgs` / `deriveFromManifest`) → resolve and report as PolicyRules.
   - `unbounded: true` — needs RBAC but cannot be bounded (e.g. Helm) → reject the option (fail closed).
   - key absent or empty → undeclared → fall back to oc-IR, else reject the option.
7. **Empty is not "none".** An absent or empty `_meta` RBAC declaration MUST NOT be treated as "needs no RBAC". Only an explicit `noRbac: true` means that. This prevents a server that has not adopted the contract from silently running with no grant.
8. **Mutation/`noRbac` invariant.** A tool that mutates the Kubernetes API — write verbs in its declaration, or `annotations.destructiveHint: true` / `readOnlyHint: false` — MUST NOT declare `noRbac: true`. The analysis agent MUST reject this contradiction as a mis-declaration and not propose the option.

### Resolution

9. **Argument-scoped resolution.** For `deriveFromArgs`/`deriveFromManifest` forms and for `rules` with argument references, the agent MUST resolve the rule against the **actual call arguments**, mapping `kind → resource` via the cluster's discovery/RESTMapper, and scope the reported PolicyRule to the specific namespace/object where the contract provides `namespaceFrom`/`resourceNamesFrom`.
10. **`resourceNames` limitation.** The agent MUST NOT rely on `resourceNames` to scope `list`/`watch` — Kubernetes RBAC cannot restrict those verbs to named objects. Read-listing tools resolve to namespace-wide read.

### Operator materialization

11. **Unchanged pipeline.** The operator materializes PolicyRules from the approved `RemediationOption` onto the per-step SA — the same code path used for `oc`/`kubectl` steps (`sandbox-execution.md` rule 21). It does not distinguish MCP-derived rules from oc-derived rules. No MCP-specific operator code is required.
12. **Server-side deny list.** The ocp-mcp TOML configuration denies `core/v1` `Secret` and all `rbac.authorization.k8s.io` resources server-side (`ocpmcp.md` rule 16), preventing those operations from reaching the LLM via the shipped server. The agent cannot derive RBAC for operations the server refuses to perform.
13. **Split by scope.** Namespaced rules materialize as Role/RoleBinding; cluster-scoped rules as ClusterRole/ClusterRoleBinding. Both bind to the per-step execution SA (`agentic-security.md` rule 7), never the shared `lightspeed-agent` SA.

## Integration Contracts

### `_meta["openshift.io/rbac"]` (MCP `tools/list`)

The MCP server publishes, per tool, a versioned RBAC document. Forms: `rules` (static, optionally argument-scoped), `deriveFromArgs` (target from named arguments), `deriveFromManifest` (target from a manifest argument), `unbounded: true`, `noRbac: true`. Full schema and examples are specified in the OLS-3680 RFE to the OpenShift MCP server team. This is an **external dependency** — the OpenShift MCP server must implement it (RFE pending); until then, tools resolve via oc-IR or fail closed.

### RemediationOption RBAC

The RBAC requirements attached to each `RemediationOption` (`agentic-runs.md` — AnalysisResult schema) are the union computed by rule 12, provenance-tagged. The operator materializes them in Phase 4 (`agentic-runs.md` rule 17) before provisioning the execution pod.

## Repo Ownership

| Repo | Owns |
|---|---|
| **lightspeed-operator** (ocp-mcp) | Publishing `_meta["openshift.io/rbac"]` on the shipped `openshift-mcp-server` (RFE target); the deny-list TOML that prevents Secret/RBAC access server-side |
| **lightspeed-agentic-operator** | Run-level `AgenticRun.spec.tools` semantics for MCP/skills/requiredSecrets; analysis instructions that direct the agent to read `_meta` from trusted servers, distinguish declaration states, resolve against call arguments, express oc-IR fallback, and fail closed. RBAC materialization is unchanged — the operator materializes whatever PolicyRules the agent reports, same as `oc`/`kubectl` steps |
| **lightspeed-agentic-sandbox** | Agent runtime that executes MCP tool calls and oc-IR commands; no RBAC derivation logic — the agent follows operator-provided analysis instructions |

## Child Spec Updates Required

These child specs describe behavior this file extends. Each MUST be updated (separate PRs in their repos):

| Repo | Spec File | Update |
|---|---|---|
| lightspeed-operator | `what/ocpmcp.md` | Add rule: shipped server publishes per-tool `_meta["openshift.io/rbac"]` (RFE); note the TOML deny-list prevents Secret/RBAC access server-side. |
| lightspeed-agentic-operator | `what/crd-api.md`, `what/sandbox-execution.md` rule 11 | Remove per-step tool definitions; make `AgenticRun.spec.tools` the single tools source for all steps. Analysis instructions direct agent to derive MCP-tool RBAC from trusted `_meta` first, oc-IR fallback otherwise. |
| lightspeed-agentic-sandbox | `what/configuration.md` | Note oc-IR expression of MCP tool steps for RBAC derivation when `_meta` is absent. |

## Constraints

- `_meta` is untrusted per the MCP specification; trust is instruction-directed (agent told which servers to use `_meta` from) and backstopped by the ocp-mcp server-side TOML deny-list.
- The `metrics` toolset (Thanos/Alertmanager, per `ocpmcp.md` rule 17) may authorize via monitoring routes / aggregated APIs rather than resource CRUD; expressing that RBAC (e.g. binding `cluster-monitoring-view`) is an open item raised in the RFE and not yet modeled here.
- The design cannot compute least-privilege RBAC for genuinely unbounded tools (Helm); those fail closed unless resolved by other means.
- The operator's RBAC materialization pipeline is generic — it does not distinguish MCP-derived from oc-derived PolicyRules. No MCP-specific operator code is needed.
- [PLANNED: OLS-4060] Run-level tools intentionally expose the same MCP servers, skills, and required secrets to every sandbox step. This simplifies API and operator behavior but removes per-step tool isolation; step behavior is constrained by instructions, approval gates, and per-step ServiceAccount RBAC.

## Planned Changes

| Ticket | Summary |
|---|---|
| [PLANNED: OLS-3680] | MCP tool RBAC resolution: analysis instructions for `_meta`-published contract (operator-managed servers) → oc-IR fallback → fail-closed. RFE to the OpenShift MCP server team for `_meta["openshift.io/rbac"]`. |
| [PLANNED: OLS-4060] | Simplify tool configuration to run-level only (`AgenticRun.spec.tools`) so analysis sees every MCP server used by later steps for RBAC derivation and validation planning. |
| [PLANNED] | Non-resource / aggregated-API RBAC form for the `metrics` toolset (Thanos/Alertmanager), pending alignment in the RFE. |
